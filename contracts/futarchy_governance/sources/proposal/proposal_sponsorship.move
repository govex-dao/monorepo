// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

/// Proposal sponsorship module - allows team members with quota to sponsor proposals
/// Sponsorship reduces the TWAP threshold, making proposals easier to pass
module futarchy_governance::proposal_sponsorship;

use account_protocol::account::{Self, Account};
use futarchy_core::futarchy_config::{Self, FutarchyConfig};
use futarchy_core::proposal_quota_registry::{Self, ProposalQuotaRegistry};
use futarchy_core::dao_config;
use futarchy_markets_core::proposal::{Self, Proposal};
use futarchy_types::signed;
use std::string::String;
use sui::clock::Clock;
use sui::event;

// === Errors ===
const ESponsorshipNotEnabled: u64 = 1;
const EAlreadySponsored: u64 = 2;
const ENoSponsorQuota: u64 = 3;
const EInvalidProposalState: u64 = 4;
const EDaoMismatch: u64 = 6;
const ETwapDelayPassed: u64 = 7;

// === Constants ===
const STATE_PREMARKET: u8 = 0;
const STATE_REVIEW: u8 = 1;
const STATE_TRADING: u8 = 2;
const STATE_FINALIZED: u8 = 3;

// === Events ===

public struct ProposalSponsored has copy, drop {
    proposal_id: ID,
    dao_id: ID,
    sponsor: address,
    threshold_reduction_magnitude: u128,
    threshold_reduction_is_negative: bool,
    timestamp: u64,
}

public struct SponsorshipRefunded has copy, drop {
    proposal_id: ID,
    dao_id: ID,
    sponsor: address,
    reason: String,
    timestamp: u64,
}

// === Public Entry Functions ===

/// Sponsor a proposal using quota to apply the DAO's configured threshold
/// This makes the proposal easier to pass by applying the DAO's sponsored_threshold
///
/// Requirements:
/// - Sponsorship must be enabled in DAO config
/// - Sponsor must have available sponsor quota
/// - Proposal must not be finalized
/// - Proposal must not already be sponsored
public entry fun sponsor_proposal<AssetType, StableType>(
    proposal: &mut Proposal<AssetType, StableType>,
    account: &Account,
    quota_registry: &mut ProposalQuotaRegistry,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let sponsor = ctx.sender();
    let dao_id = proposal::get_dao_id(proposal);
    let proposal_id = proposal::get_id(proposal);

    // Validation 0: Verify DAO consistency (prevent quota bypass attack)
    // All three objects must belong to the same DAO
    let account_dao_id = object::id(account);
    let registry_dao_id = proposal_quota_registry::dao_id(quota_registry);
    assert!(dao_id == account_dao_id, EDaoMismatch);
    assert!(dao_id == registry_dao_id, EDaoMismatch);

    // Get DAO config and sponsorship settings
    let config = account::config(account);
    let dao_cfg = futarchy_config::dao_config(config);
    let sponsor_config = dao_config::sponsorship_config(dao_cfg);

    // Validation 1: Check sponsorship is enabled
    assert!(dao_config::sponsorship_enabled(sponsor_config), ESponsorshipNotEnabled);

    // Validation 2: Check proposal not already sponsored
    assert!(!proposal::is_sponsored(proposal), EAlreadySponsored);

    // Validation 3: Check proposal is not finalized
    let state = proposal::get_state(proposal);
    assert!(state != STATE_FINALIZED, EInvalidProposalState);

    // Validation 4: Check sponsor has available quota
    let (has_quota, remaining) = proposal_quota_registry::check_sponsor_quota_available(
        quota_registry,
        dao_id,
        sponsor,
        clock,
    );
    assert!(has_quota, ENoSponsorQuota);

    // Validation 5: Check sponsorship timing - cannot sponsor after TWAP delay if in trading period
    // This prevents manipulation after TWAP starts recording prices
    validate_sponsorship_timing(proposal, clock);

    // Get sponsored threshold from config
    let sponsored_threshold = dao_config::sponsored_threshold(sponsor_config);

    // Apply sponsorship to proposal
    proposal::set_sponsorship(proposal, sponsor, sponsored_threshold);

    // Use sponsor quota
    proposal_quota_registry::use_sponsor_quota(
        quota_registry,
        dao_id,
        sponsor,
        proposal_id,
        clock,
    );

    // Emit event
    event::emit(ProposalSponsored {
        proposal_id,
        dao_id,
        sponsor,
        threshold_reduction_magnitude: signed::magnitude(&sponsored_threshold),
        threshold_reduction_is_negative: signed::is_negative(&sponsored_threshold),
        timestamp: clock.timestamp_ms(),
    });
}

/// Sponsor a proposal to zero threshold (FREE - no quota cost)
/// Any team member can use this to set proposal threshold to 0%
///
/// Requirements:
/// - Sponsorship must be enabled in DAO config
/// - Sponsor must be a team member (have any entry in quota registry)
/// - Proposal must not be finalized
/// - Proposal must not already be sponsored
public entry fun sponsor_proposal_to_zero<AssetType, StableType>(
    proposal: &mut Proposal<AssetType, StableType>,
    account: &Account,
    quota_registry: &ProposalQuotaRegistry,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let sponsor = ctx.sender();
    let dao_id = proposal::get_dao_id(proposal);
    let proposal_id = proposal::get_id(proposal);

    // Validation 0: Verify DAO consistency (prevent quota bypass attack)
    let account_dao_id = object::id(account);
    let registry_dao_id = proposal_quota_registry::dao_id(quota_registry);
    assert!(dao_id == account_dao_id, EDaoMismatch);
    assert!(dao_id == registry_dao_id, EDaoMismatch);

    // Get DAO config and sponsorship settings
    let config = account::config(account);
    let dao_cfg = futarchy_config::dao_config(config);
    let sponsor_config = dao_config::sponsorship_config(dao_cfg);

    // Validation 1: Check sponsorship is enabled
    assert!(dao_config::sponsorship_enabled(sponsor_config), ESponsorshipNotEnabled);

    // Validation 2: Check proposal not already sponsored
    assert!(!proposal::is_sponsored(proposal), EAlreadySponsored);

    // Validation 3: Check proposal is not finalized
    let state = proposal::get_state(proposal);
    assert!(state != STATE_FINALIZED, EInvalidProposalState);

    // Validation 4: Check sponsor is a team member (has any quota entry)
    assert!(proposal_quota_registry::has_quota(quota_registry, sponsor), ENoSponsorQuota);

    // Validation 5: Check sponsorship timing - cannot sponsor after TWAP delay if in trading period
    // This prevents manipulation after TWAP starts recording prices
    validate_sponsorship_timing(proposal, clock);

    // Set threshold to zero
    let zero_threshold = futarchy_types::signed::from_u64(0);

    // Apply sponsorship to proposal
    proposal::set_sponsorship(proposal, sponsor, zero_threshold);

    // NO quota usage - this is free for team members

    // Emit event
    event::emit(ProposalSponsored {
        proposal_id,
        dao_id,
        sponsor,
        threshold_reduction_magnitude: signed::magnitude(&zero_threshold),
        threshold_reduction_is_negative: signed::is_negative(&zero_threshold),
        timestamp: clock.timestamp_ms(),
    });
}

// === Package Functions ===

/// Refund sponsorship quota when a proposal is evicted or cancelled
/// This is called by proposal lifecycle management
public(package) fun refund_sponsorship_on_eviction<AssetType, StableType>(
    proposal: &mut Proposal<AssetType, StableType>,
    quota_registry: &mut ProposalQuotaRegistry,
    reason: String,
    clock: &Clock,
) {
    // Only refund if proposal is sponsored
    if (!proposal::is_sponsored(proposal)) {
        return
    };

    let dao_id = proposal::get_dao_id(proposal);
    let proposal_id = proposal::get_id(proposal);
    let sponsor_opt = proposal::get_sponsored_by(proposal);

    if (sponsor_opt.is_some()) {
        let sponsor = *sponsor_opt.borrow();

        // Refund quota
        proposal_quota_registry::refund_sponsor_quota(
            quota_registry,
            dao_id,
            sponsor,
            proposal_id,
            clock,
        );

        // Clear sponsorship from proposal
        proposal::clear_sponsorship(proposal);

        // Emit refund event
        event::emit(SponsorshipRefunded {
            proposal_id,
            dao_id,
            sponsor,
            reason,
            timestamp: clock.timestamp_ms(),
        });
    };
}

// NOTE: The refund_sponsorship_on_eviction() function above handles refunds for ALL proposal evictions
// This includes PREMARKET proposals (queue evictions) since sponsorship is now allowed at any time before FINALIZED
// Queue managers should call this function when evicting proposals to ensure sponsor quota is properly refunded

// === Internal Helper Functions ===

/// Validates that sponsorship is being applied before the TWAP delay has passed in trading period
/// This prevents sponsors from manipulating the threshold after price discovery has begun
///
/// SAFETY: Sponsorship is allowed:
/// - Anytime in PREMARKET or REVIEW states (before trading begins)
/// - During TRADING state, but ONLY before (trading_start + twap_start_delay)
///
/// After the TWAP delay period, the TWAP oracle begins recording prices, so the threshold
/// must be locked to prevent manipulation
fun validate_sponsorship_timing<AssetType, StableType>(
    proposal: &Proposal<AssetType, StableType>,
    clock: &Clock,
) {
    let state = proposal::get_state(proposal);

    // PREMARKET and REVIEW states - always allowed
    if (state == STATE_PREMARKET || state == STATE_REVIEW) {
        return
    };

    // TRADING state - check if TWAP delay has passed
    if (state == STATE_TRADING) {
        let twap_start_time = calculate_twap_start_time(proposal);
        let current_time = clock.timestamp_ms();

        // Cannot sponsor after TWAP has started recording prices
        assert!(current_time < twap_start_time, ETwapDelayPassed);
    };

    // FINALIZED state is already blocked by earlier validation
}

/// Calculate when TWAP starts recording prices for a proposal
/// Returns: timestamp_ms when TWAP begins
fun calculate_twap_start_time<AssetType, StableType>(
    proposal: &Proposal<AssetType, StableType>
): u64 {
    let market_init_time = proposal::get_market_initialized_at(proposal);
    let review_period = proposal::get_review_period_ms(proposal);
    let twap_delay = proposal::get_twap_start_delay(proposal);

    // trading_start + twap_delay = when TWAP actually starts
    market_init_time + review_period + twap_delay
}

// === View Functions ===

/// Check if a user can sponsor a proposal
/// Returns (can_sponsor, reason)
public fun can_sponsor_proposal<AssetType, StableType>(
    proposal: &Proposal<AssetType, StableType>,
    account: &Account,
    quota_registry: &ProposalQuotaRegistry,
    potential_sponsor: address,
    clock: &Clock,
): (bool, String) {
    use std::string;

    let dao_id = proposal::get_dao_id(proposal);

    // Get DAO config and sponsorship settings
    let config = account::config(account);
    let dao_cfg = futarchy_config::dao_config(config);
    let sponsor_config = dao_config::sponsorship_config(dao_cfg);

    // Check 1: Sponsorship enabled
    if (!dao_config::sponsorship_enabled(sponsor_config)) {
        return (false, string::utf8(b"Sponsorship not enabled"))
    };

    // Check 2: Not already sponsored (cheaper check - do this before state check)
    if (proposal::is_sponsored(proposal)) {
        return (false, string::utf8(b"Proposal already sponsored"))
    };

    // Check 3: Valid state (not finalized)
    let state = proposal::get_state(proposal);
    if (state == STATE_FINALIZED) {
        return (false, string::utf8(b"Proposal already finalized"))
    };

    // Check 4: Timing - cannot sponsor after TWAP delay in trading period
    if (state == STATE_TRADING) {
        let twap_start_time = calculate_twap_start_time(proposal);
        let current_time = clock.timestamp_ms();

        if (current_time >= twap_start_time) {
            return (false, string::utf8(b"TWAP delay has passed"))
        };
    };

    // Check 5: Has quota
    let (has_quota, _remaining) = proposal_quota_registry::check_sponsor_quota_available(
        quota_registry,
        dao_id,
        potential_sponsor,
        clock,
    );
    if (!has_quota) {
        return (false, string::utf8(b"No sponsor quota available"))
    };

    (true, string::utf8(b""))
}
