/// Early resolution system for futarchy proposals
///
/// This module handles flip tracking and eligibility checks for proposals
/// that can be resolved early when market consensus is clear and stable.
///
/// ## Architecture
/// - Metrics stored in Proposal struct (proposal.move owns storage)
/// - Logic centralized here (single responsibility principle)
/// - Called from swap_core::finalize_swap_session for flip detection
///
/// ## Flip Detection
/// Uses instant prices (not TWAP) for fast flip detection during trading.
/// TWAP is used for final resolution to prevent manipulation.
module futarchy_markets::early_resolve;

use futarchy_markets::proposal::{Self, Proposal};
use futarchy_markets::conditional_amm;
use futarchy_markets::market_state::{Self, MarketState};
use futarchy_core::futarchy_config::{Self, EarlyResolveConfig};
use std::string::{Self, String};
use sui::clock::Clock;
use sui::event;
use sui::object::ID;

// === Errors ===
const EInvalidOutcome: u64 = 0;

// === Structs ===

// Note: EarlyResolveMetrics is defined in proposal.move to avoid circular dependencies.
// This module provides logic to manipulate the metrics, but the struct lives where it's stored.

// === Events ===

public struct WinnerFlipped has copy, drop {
    proposal_id: ID,
    old_winner: u64,
    new_winner: u64,
    spread: u128,
    winning_price: u128,  // Actually instant price, not TWAP
    timestamp: u64,
}

public struct MetricsUpdated has copy, drop {
    proposal_id: ID,
    current_winner: u64,
    flip_count: u64,
    total_trades: u64,
    total_fees: u64,
    eligible_for_early_resolve: bool,
    timestamp: u64,
}

public struct ProposalEarlyResolved has copy, drop {
    proposal_id: ID,
    winning_outcome: u64,
    proposal_age_ms: u64,
    flips_in_window: u64,
    keeper: address,
    keeper_reward: u64,
    timestamp: u64,
}

// === Public Functions ===

/// Initialize early resolution metrics for a proposal
/// Called when proposal enters TRADING state
/// Delegates to proposal module to construct the struct
public fun new_metrics(
    initial_winner: u64,
    current_time_ms: u64,
): proposal::EarlyResolveMetrics {
    proposal::new_early_resolve_metrics(initial_winner, current_time_ms)
}

/// Update early resolve metrics (keeper-triggered or swap-triggered)
/// Tracks winner changes - simple design with no exponential decay
/// Does nothing if early resolution is not enabled for this proposal
///
/// This is called from swap_core::finalize_swap_session() to ensure flip
/// detection happens exactly once per transaction AFTER all swaps complete.
///
/// NOTE: This now works with MarketState directly for pool access,
/// but still needs Proposal for metrics storage (until we refactor that too)
public fun update_metrics<AssetType, StableType>(
    proposal: &mut Proposal<AssetType, StableType>,
    market_state: &mut futarchy_markets::market_state::MarketState,
    clock: &Clock,
) {
    // If early resolution not enabled, do nothing
    if (!proposal::has_early_resolve_metrics(proposal)) {
        return
    };

    let current_time_ms = clock.timestamp_ms();
    let proposal_id = proposal::get_id(proposal);

    // Calculate current winner from MarketState pools (no Proposal dependency!)
    let (winner_idx, winner_price, spread) = calculate_current_winner_by_price(market_state);

    // Now borrow metrics mutably from proposal
    let metrics = proposal::borrow_early_resolve_metrics_mut(proposal);

    // Check if winner has flipped
    let current_winner_idx = proposal::metrics_current_winner(metrics);
    let has_flipped = winner_idx != current_winner_idx;

    if (has_flipped) {
        let old_winner = current_winner_idx;

        // Winner changed - update tracking
        proposal::metrics_set_current_winner(metrics, winner_idx);
        proposal::metrics_set_last_flip_time_ms(metrics, current_time_ms);

        // Emit WinnerFlipped event
        event::emit(WinnerFlipped {
            proposal_id,
            old_winner,
            new_winner: winner_idx,
            spread,
            winning_price: winner_price,
            timestamp: current_time_ms,
        });
    };

    // Emit MetricsUpdated event (simplified - no flip count or revenue tracking)
    event::emit(MetricsUpdated {
        proposal_id,
        current_winner: proposal::metrics_current_winner(metrics),
        flip_count: 0,  // Removed exponential decay tracking
        total_trades: 0,  // Removed trade tracking
        total_fees: 0,  // Removed revenue tracking
        eligible_for_early_resolve: false,  // Computed in check_eligibility
        timestamp: current_time_ms,
    });
}

/// Check if proposal is eligible for early resolution
/// Returns (is_eligible, reason_if_not)
/// Simplified design: just check time bounds and stability
public fun check_eligibility<AssetType, StableType>(
    proposal: &Proposal<AssetType, StableType>,
    config: &EarlyResolveConfig,
    clock: &Clock,
): (bool, String) {
    // Check if early resolution is enabled (min < max)
    if (!futarchy_config::early_resolve_enabled(config)) {
        return (false, string::utf8(b"Early resolution not enabled"))
    };

    // Check if proposal has metrics initialized
    if (!proposal::has_early_resolve_metrics(proposal)) {
        return (false, string::utf8(b"Early resolve metrics not initialized"))
    };

    let metrics = proposal::borrow_early_resolve_metrics(proposal);
    let current_time_ms = clock.timestamp_ms();

    // Get proposal start time (use market_initialized_at if available, else created_at)
    let start_time = proposal::get_start_time_for_early_resolve(proposal);
    let proposal_age_ms = current_time_ms - start_time;

    // Check minimum proposal duration
    let min_duration = futarchy_config::early_resolve_min_duration(config);
    if (proposal_age_ms < min_duration) {
        return (false, string::utf8(b"Proposal too young for early resolution"))
    };

    // Check maximum proposal duration (should resolve by now)
    let max_duration = futarchy_config::early_resolve_max_duration(config);
    if (proposal_age_ms > max_duration) {
        return (false, string::utf8(b"Proposal exceeded max duration"))
    };

    // Check time since last flip (simple stability check)
    let last_flip_time = proposal::metrics_last_flip_time_ms(metrics);
    let time_since_last_flip_ms = current_time_ms - last_flip_time;
    let min_time_since_flip = futarchy_config::early_resolve_min_time_since_flip(config);
    if (time_since_last_flip_ms < min_time_since_flip) {
        return (false, string::utf8(b"Winner changed too recently"))
    };

    // Note: Spread check happens in try_early_resolve (requires &mut for TWAP calculation)

    // All checks passed
    (true, string::utf8(b"Eligible for early resolution"))
}

/// Get time until proposal is eligible for early resolution (in milliseconds)
/// Returns 0 if already eligible or if early resolution not enabled
public fun time_until_eligible<AssetType, StableType>(
    proposal: &Proposal<AssetType, StableType>,
    config: &EarlyResolveConfig,
    clock: &Clock,
): u64 {
    // If not enabled or no metrics, return 0
    if (!futarchy_config::early_resolve_enabled(config) || !proposal::has_early_resolve_metrics(proposal)) {
        return 0
    };

    let metrics = proposal::borrow_early_resolve_metrics(proposal);
    let current_time_ms = clock.timestamp_ms();

    // Get proposal start time
    let start_time = proposal::get_start_time_for_early_resolve(proposal);
    let proposal_age_ms = current_time_ms - start_time;

    // Check minimum duration requirement
    let min_duration = futarchy_config::early_resolve_min_duration(config);
    if (proposal_age_ms < min_duration) {
        return min_duration - proposal_age_ms
    };

    // Check time since last flip requirement
    let last_flip_time = proposal::metrics_last_flip_time_ms(metrics);
    let time_since_last_flip_ms = current_time_ms - last_flip_time;
    let min_time_since_flip = futarchy_config::early_resolve_min_time_since_flip(config);
    if (time_since_last_flip_ms < min_time_since_flip) {
        return min_time_since_flip - time_since_last_flip_ms
    };

    // Already eligible (or other conditions not met - would need full check)
    0
}

// === Getter Functions ===

/// Get current winner index from metrics
public fun current_winner(metrics: &proposal::EarlyResolveMetrics): u64 {
    proposal::metrics_current_winner(metrics)
}

/// Get last flip timestamp from metrics
public fun last_flip_time_ms(metrics: &proposal::EarlyResolveMetrics): u64 {
    proposal::metrics_last_flip_time_ms(metrics)
}

// === Internal Helper Functions ===

/// Calculate current winner by INSTANT PRICE from MarketState pools
/// Returns (winner_index, winner_price, spread)
/// Used for flip detection - works directly with market infrastructure
fun calculate_current_winner_by_price(
    market_state: &mut MarketState,
): (u64, u128, u128) {
    let pools = market_state::borrow_amm_pools_mut(market_state);
    let outcome_count = pools.length();

    assert!(outcome_count >= 2, EInvalidOutcome);

    // Get instant prices from all pools
    let mut winner_idx = 0u64;
    let mut winner_price = conditional_amm::get_current_price(&pools[0]);
    let mut second_price = 0u128;

    let mut i = 1u64;
    while (i < outcome_count) {
        let current_price = conditional_amm::get_current_price(&pools[i]);

        if (current_price > winner_price) {
            // New winner found
            second_price = winner_price;
            winner_price = current_price;
            winner_idx = i;
        } else if (current_price > second_price) {
            // Update second place
            second_price = current_price;
        };

        i = i + 1;
    };

    // Calculate spread between winner and second place
    let spread = if (winner_price > second_price) {
        winner_price - second_price
    } else {
        0u128
    };

    (winner_idx, winner_price, spread)
}
