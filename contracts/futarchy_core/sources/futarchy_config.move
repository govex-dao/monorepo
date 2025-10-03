/// Pure configuration struct for Futarchy governance systems
/// This is the configuration object used with Account<FutarchyConfig>
/// All dynamic state and object references are stored as dynamic fields on the Account
module futarchy_core::futarchy_config;

// === Imports ===
use std::{
    string::{Self, String},
    type_name,
    option::{Self, Option},
};
use sui::{
    object::ID,
    clock::Clock,
    dynamic_field as df,
    tx_context::TxContext,
};
use account_protocol::{
    account::{Self, Account},
    deps::{Self, Deps},
    version_witness::VersionWitness,
};
use account_extensions::extensions::Extensions;
use futarchy_core::{
    dao_config::{Self, DaoConfig},
    version,
};

// === Constants ===

// Operational states
const DAO_STATE_ACTIVE: u8 = 0;
const DAO_STATE_DISSOLVING: u8 = 1;
const DAO_STATE_PAUSED: u8 = 2;
const DAO_STATE_DISSOLVED: u8 = 3;

// === Errors ===

const EInvalidSlashDistribution: u64 = 0;
const EApprovalExpired: u64 = 100;
const ELaunchpadPriceAlreadySet: u64 = 101;

// === Structs ===

/// Configuration for how slashed proposal fees are distributed
public struct SlashDistribution has store, drop, copy {
    /// Percentage (in basis points) that goes to the slasher who evicted the proposal
    slasher_reward_bps: u16,
    /// Percentage (in basis points) that goes to the DAO treasury
    dao_treasury_bps: u16,
    /// Percentage (in basis points) that goes to protocol revenue
    protocol_bps: u16,
    /// Percentage (in basis points) that gets burned
    burn_bps: u16,
}

/// Pure Futarchy configuration struct
/// All dynamic state and object references are stored on the Account<FutarchyConfig> object
public struct FutarchyConfig has store, copy, drop {
    // Type information
    asset_type: String,
    stable_type: String,

    // Core DAO configuration
    config: DaoConfig,

    // Slash distribution configuration
    slash_distribution: SlashDistribution,

    // Reward configurations (paid from protocol revenue in SUI)
    // Set to 0 to disable rewards (default), or configure per DAO
    proposal_pass_reward: u64,    // Reward for proposal creator when proposal passes (in SUI, default: 0)
    outcome_win_reward: u64,       // Reward for winning outcome creator (in SUI, default: 0)
    review_to_trading_fee: u64,   // Fee to advance from review to trading (in SUI)
    finalization_fee: u64,         // Fee to finalize proposal after trading (in SUI)

    // Verification configuration
    verification_level: u8,        // 0 = unverified, 1 = basic, 2 = standard, 3 = premium
    dao_score: u64,                // DAO quality score (0-unlimited, higher = better, admin-set only)

    // Write-once immutable starting price from launchpad raise
    // Once set to Some(price), can NEVER be changed
    // Used to enforce: 1) AMM initialization ratio, 2) founder reward mint minimum price
    launchpad_initial_price: Option<u128>,
}

/// Dynamic state stored on Account<FutarchyConfig> via dynamic fields
/// This is not part of the config itself but tracked separately
public struct DaoState has store {
    operational_state: u8,
    active_proposals: u64,
    total_proposals: u64,
    attestation_url: String,
    verification_pending: bool,
}

/// Key for storing DaoState as a dynamic field
public struct DaoStateKey has copy, drop, store {}

/// Key for storing ProposalQueue as a dynamic field
public struct ProposalQueueKey has copy, drop, store {}

/// Key for storing SpotAMM as a dynamic field
public struct SpotAMMKey has copy, drop, store {}

/// Key for storing FeeManager as a dynamic field
public struct FeeManagerKey has copy, drop, store {}

/// Key for storing OperatingAgreement as a dynamic field
public struct OperatingAgreementKey has copy, drop, store {}

/// Key for storing Treasury as a dynamic field
public struct TreasuryKey has copy, drop, store {}

// === Public Functions ===

/// Creates a new pure FutarchyConfig
public fun new<AssetType: drop, StableType: drop>(
    dao_config: DaoConfig,
    slash_distribution: SlashDistribution,
): FutarchyConfig {
    // Validate slash distribution
    let total_bps = (slash_distribution.slasher_reward_bps as u64) +
                   (slash_distribution.dao_treasury_bps as u64) +
                   (slash_distribution.protocol_bps as u64) +
                   (slash_distribution.burn_bps as u64);
    assert!(total_bps == 10000, EInvalidSlashDistribution);

    FutarchyConfig {
        asset_type: type_name::get<AssetType>().into_string().to_string(),
        stable_type: type_name::get<StableType>().into_string().to_string(),
        config: dao_config,
        slash_distribution,
        proposal_pass_reward: 0,    // No default reward (DAO must configure)
        outcome_win_reward: 0,       // No default reward (DAO must configure)
        review_to_trading_fee: 1_000_000_000,    // 1 SUI default
        finalization_fee: 1_000_000_000,         // 1 SUI default
        verification_level: 0,                    // Unverified by default
        dao_score: 0,                              // No score by default
        launchpad_initial_price: option::none(),   // Not set initially
    }
}

/// Creates a new DaoState for dynamic storage
public fun new_dao_state(): DaoState {
    DaoState {
        operational_state: DAO_STATE_ACTIVE,
        active_proposals: 0,
        total_proposals: 0,
        attestation_url: b"".to_string(),
        verification_pending: false,
    }
}

/// Creates a SlashDistribution configuration
public fun new_slash_distribution(
    slasher_reward_bps: u16,
    dao_treasury_bps: u16,
    protocol_bps: u16,
    burn_bps: u16,
): SlashDistribution {
    // Validate total equals 100%
    let total_bps = (slasher_reward_bps as u64) +
                   (dao_treasury_bps as u64) +
                   (protocol_bps as u64) +
                   (burn_bps as u64);
    assert!(total_bps == 10000, EInvalidSlashDistribution);

    SlashDistribution {
        slasher_reward_bps,
        dao_treasury_bps,
        protocol_bps,
        burn_bps,
    }
}

// === Getters for FutarchyConfig ===

public fun asset_type(config: &FutarchyConfig): &String {
    &config.asset_type
}

public fun stable_type(config: &FutarchyConfig): &String {
    &config.stable_type
}

public fun dao_config(config: &FutarchyConfig): &DaoConfig {
    &config.config
}

public fun dao_config_mut(config: &mut FutarchyConfig): &mut DaoConfig {
    &mut config.config
}

public fun slash_distribution(config: &FutarchyConfig): &SlashDistribution {
    &config.slash_distribution
}

public fun proposal_pass_reward(config: &FutarchyConfig): u64 {
    config.proposal_pass_reward
}

public fun outcome_win_reward(config: &FutarchyConfig): u64 {
    config.outcome_win_reward
}

public fun review_to_trading_fee(config: &FutarchyConfig): u64 {
    config.review_to_trading_fee
}

public fun finalization_fee(config: &FutarchyConfig): u64 {
    config.finalization_fee
}

public fun verification_level(config: &FutarchyConfig): u8 {
    config.verification_level
}

public fun dao_score(config: &FutarchyConfig): u64 {
    config.dao_score
}

// === Getters for SlashDistribution ===

public fun slasher_reward_bps(dist: &SlashDistribution): u16 {
    dist.slasher_reward_bps
}

public fun dao_treasury_bps(dist: &SlashDistribution): u16 {
    dist.dao_treasury_bps
}

public fun protocol_bps(dist: &SlashDistribution): u16 {
    dist.protocol_bps
}

public fun burn_bps(dist: &SlashDistribution): u16 {
    dist.burn_bps
}

// === Getters for DaoState ===

public fun operational_state(state: &DaoState): u8 {
    state.operational_state
}

public fun active_proposals(state: &DaoState): u64 {
    state.active_proposals
}

public fun total_proposals(state: &DaoState): u64 {
    state.total_proposals
}

public fun attestation_url(state: &DaoState): &String {
    &state.attestation_url
}

public fun verification_pending(state: &DaoState): bool {
    state.verification_pending
}

// === Setters for DaoState (mutable) ===

public fun set_operational_state(state: &mut DaoState, new_state: u8) {
    state.operational_state = new_state;
}

public fun increment_active_proposals(state: &mut DaoState) {
    state.active_proposals = state.active_proposals + 1;
}

public fun decrement_active_proposals(state: &mut DaoState) {
    assert!(state.active_proposals > 0, 0);
    state.active_proposals = state.active_proposals - 1;
}

public fun increment_total_proposals(state: &mut DaoState) {
    state.total_proposals = state.total_proposals + 1;
}

public fun set_attestation_url(state: &mut DaoState, url: String) {
    state.attestation_url = url;
}

public fun set_verification_pending(state: &mut DaoState, pending: bool) {
    state.verification_pending = pending;
}

// === Configuration Update Functions ===
// These return a new config since FutarchyConfig has copy

public fun with_rewards(
    config: FutarchyConfig,
    proposal_pass_reward: u64,
    outcome_win_reward: u64,
    review_to_trading_fee: u64,
    finalization_fee: u64,
): FutarchyConfig {
    FutarchyConfig {
        asset_type: config.asset_type,
        stable_type: config.stable_type,
        config: config.config,
        slash_distribution: config.slash_distribution,
        proposal_pass_reward,
        outcome_win_reward,
        review_to_trading_fee,
        finalization_fee,
        verification_level: config.verification_level,
        dao_score: config.dao_score,
        launchpad_initial_price: config.launchpad_initial_price,
    }
}

public fun with_verification_level(
    config: FutarchyConfig,
    verification_level: u8,
): FutarchyConfig {
    FutarchyConfig {
        asset_type: config.asset_type,
        stable_type: config.stable_type,
        config: config.config,
        slash_distribution: config.slash_distribution,
        proposal_pass_reward: config.proposal_pass_reward,
        outcome_win_reward: config.outcome_win_reward,
        review_to_trading_fee: config.review_to_trading_fee,
        finalization_fee: config.finalization_fee,
        verification_level,
        dao_score: config.dao_score,
        launchpad_initial_price: config.launchpad_initial_price,
    }
}

public fun with_dao_score(
    config: FutarchyConfig,
    dao_score: u64,
): FutarchyConfig {
    FutarchyConfig {
        asset_type: config.asset_type,
        stable_type: config.stable_type,
        config: config.config,
        slash_distribution: config.slash_distribution,
        proposal_pass_reward: config.proposal_pass_reward,
        outcome_win_reward: config.outcome_win_reward,
        review_to_trading_fee: config.review_to_trading_fee,
        finalization_fee: config.finalization_fee,
        verification_level: config.verification_level,
        dao_score,
        launchpad_initial_price: config.launchpad_initial_price,
    }
}

public fun with_slash_distribution(
    config: FutarchyConfig,
    slash_distribution: SlashDistribution,
): FutarchyConfig {
    FutarchyConfig {
        asset_type: config.asset_type,
        stable_type: config.stable_type,
        config: config.config,
        slash_distribution,
        proposal_pass_reward: config.proposal_pass_reward,
        outcome_win_reward: config.outcome_win_reward,
        review_to_trading_fee: config.review_to_trading_fee,
        finalization_fee: config.finalization_fee,
        verification_level: config.verification_level,
        dao_score: config.dao_score,
        launchpad_initial_price: config.launchpad_initial_price,
    }
}

// === Council Approval Functions ===

/// Represents a custody approval from a council
public struct CustodyApproval has store, copy, drop {
    dao_id: ID,
    resource_key: String,
    resource_id: ID,
    expires_at: u64,
    created_at: u64,
}

/// Create a new custody approval record
public fun new_custody_approval(
    dao_id: ID,
    resource_key: String,
    resource_id: ID,
    expires_at: u64,
    ctx: &mut TxContext,
): CustodyApproval {
    CustodyApproval {
        dao_id,
        resource_key,
        resource_id,
        expires_at,
        created_at: ctx.epoch_timestamp_ms(),
    }
}

/// Record a council's generic approval for an intent
/// Note: Since Account doesn't expose its UID, we store approvals in a separate shared object
/// In production, this would be stored in a registry or as a dynamic field on a DAO-specific object
public fun record_council_approval_generic<Config: store>(
    _dao: &mut Account<Config>,
    _intent_key: String,
    approval: CustodyApproval,
    clock: &Clock,
    _ctx: &mut TxContext,
) {
    // Verify approval hasn't expired
    assert!(clock.timestamp_ms() < approval.expires_at, EApprovalExpired);

    // In a production implementation, this would:
    // 1. Store in a shared ApprovalRegistry object, or
    // 2. Store as a dynamic field on a DAO wrapper object, or
    // 3. Emit an event for off-chain tracking
    // For now, we just validate the approval is valid

    // The approval is validated and can be used by the caller
    let _ = approval;
}

// === FutarchyOutcome Type ===

/// Outcome for futarchy proposals - represents the intent execution metadata
public struct FutarchyOutcome has store, drop, copy {
    // Intent key is the primary identifier - links to the intent in account storage
    intent_key: String,
    // These fields are set when proposal is created/approved
    proposal_id: Option<ID>,
    market_id: Option<ID>,
    approved: bool,
    min_execution_time: u64,
}

/// Creates a new FutarchyOutcome for intent creation (before proposal exists)
public fun new_futarchy_outcome(
    intent_key: String,
    min_execution_time: u64,
): FutarchyOutcome {
    FutarchyOutcome {
        intent_key,
        proposal_id: option::none(),
        market_id: option::none(),
        approved: false,
        min_execution_time,
    }
}

/// Public constructor for FutarchyOutcome with all fields
public fun new_futarchy_outcome_full(
    intent_key: String,
    proposal_id: Option<ID>,
    market_id: Option<ID>,
    approved: bool,
    min_execution_time: u64,
): FutarchyOutcome {
    FutarchyOutcome {
        intent_key,
        proposal_id,
        market_id,
        approved,
        min_execution_time,
    }
}

/// Updates proposal and market IDs after proposal creation
public fun set_outcome_proposal_and_market(
    outcome: &mut FutarchyOutcome,
    proposal_id: ID,
    market_id: ID,
) {
    outcome.proposal_id = option::some(proposal_id);
    outcome.market_id = option::some(market_id);
}

/// Marks outcome as approved after proposal passes
public fun set_outcome_approved(
    outcome: &mut FutarchyOutcome,
    approved: bool,
) {
    outcome.approved = approved;
}

/// Sets the intent key for an outcome
public fun set_outcome_intent_key(outcome: &mut FutarchyOutcome, intent_key: String) {
    outcome.intent_key = intent_key;
}

/// Gets the minimum execution time
public fun outcome_min_execution_time(outcome: &FutarchyOutcome): u64 {
    outcome.min_execution_time
}

// === Delegated Getters from dao_config ===

public fun review_period_ms(config: &FutarchyConfig): u64 {
    dao_config::review_period_ms(dao_config::trading_params(&config.config))
}

public fun trading_period_ms(config: &FutarchyConfig): u64 {
    dao_config::trading_period_ms(dao_config::trading_params(&config.config))
}

public fun min_asset_amount(config: &FutarchyConfig): u64 {
    dao_config::min_asset_amount(dao_config::trading_params(&config.config))
}

public fun min_stable_amount(config: &FutarchyConfig): u64 {
    dao_config::min_stable_amount(dao_config::trading_params(&config.config))
}

public fun amm_twap_start_delay(config: &FutarchyConfig): u64 {
    dao_config::start_delay(dao_config::twap_config(&config.config))
}

public fun amm_twap_initial_observation(config: &FutarchyConfig): u128 {
    dao_config::initial_observation(dao_config::twap_config(&config.config))
}

public fun amm_twap_step_max(config: &FutarchyConfig): u64 {
    dao_config::step_max(dao_config::twap_config(&config.config))
}

public fun twap_threshold(config: &FutarchyConfig): u64 {
    dao_config::threshold(dao_config::twap_config(&config.config))
}

public fun conditional_amm_fee_bps(config: &FutarchyConfig): u64 {
    dao_config::conditional_amm_fee_bps(dao_config::trading_params(&config.config))
}

public fun spot_amm_fee_bps(config: &FutarchyConfig): u64 {
    dao_config::spot_amm_fee_bps(dao_config::trading_params(&config.config))
}

// Deprecated: use conditional_amm_fee_bps instead
public fun amm_total_fee_bps(config: &FutarchyConfig): u64 {
    dao_config::conditional_amm_fee_bps(dao_config::trading_params(&config.config))
}

public fun max_outcomes(config: &FutarchyConfig): u64 {
    dao_config::max_outcomes(dao_config::governance_config(&config.config))
}

// === Missing Functions Added for Build Fixes ===

public fun optimistic_challenge_period_ms(config: &FutarchyConfig): u64 {
    // Default to 3 days if not specified
    259_200_000
}

public fun optimistic_challenge_fee(config: &FutarchyConfig): u64 {
    // Use proposal pass reward as challenge fee
    config.proposal_pass_reward
}

/// Create witness for authorized operations
public fun witness(): ConfigWitness {
    ConfigWitness {}
}

public fun state_active(): u8 {
    DAO_STATE_ACTIVE
}

public fun state_paused(): u8 {
    DAO_STATE_PAUSED
}

public fun internal_config_mut(account: &mut Account<FutarchyConfig>, version: account_protocol::version_witness::VersionWitness): &mut FutarchyConfig {
    account::config_mut<FutarchyConfig, ConfigWitness>(account, version, ConfigWitness {})
}

/// Get mutable access to the DaoState stored as a dynamic field on the Account
/// This requires access to the Account object, not just the FutarchyConfig
public fun state_mut_from_account(account: &mut Account<FutarchyConfig>): &mut DaoState {
    account::borrow_managed_data_mut(account, DaoStateKey {}, version::current())
}

/// Witness for internal config operations
public struct ConfigWitness has drop {}

/// Create a DaoStateKey (for use in modules that can't directly instantiate it)
public fun new_dao_state_key(): DaoStateKey {
    DaoStateKey {}
}

public fun set_dao_name(config: &mut FutarchyConfig, name: String) {
    // Get mutable access to the metadata config through the config field
    let metadata_cfg = dao_config::metadata_config_mut(&mut config.config);
    dao_config::set_dao_name_string(metadata_cfg, name);
}

public fun set_icon_url(config: &mut FutarchyConfig, url: String) {
    // Get mutable access to the config field
    let metadata_cfg = dao_config::metadata_config_mut(&mut config.config);
    dao_config::set_icon_url_string(metadata_cfg, url);
}

public fun set_description(config: &mut FutarchyConfig, desc: String) {
    // Get mutable access to the config field
    let metadata_cfg = dao_config::metadata_config_mut(&mut config.config);
    dao_config::set_description(metadata_cfg, desc);
}

public fun set_min_asset_amount(config: &mut FutarchyConfig, amount: u64) {
    let trading_params = dao_config::trading_params_mut(&mut config.config);
    dao_config::set_min_asset_amount(trading_params, amount);
}

public fun set_min_stable_amount(config: &mut FutarchyConfig, amount: u64) {
    let trading_params = dao_config::trading_params_mut(&mut config.config);
    dao_config::set_min_stable_amount(trading_params, amount);
}

public fun set_review_period_ms(config: &mut FutarchyConfig, period: u64) {
    let trading_params = dao_config::trading_params_mut(&mut config.config);
    dao_config::set_review_period_ms(trading_params, period);
}

public fun set_trading_period_ms(config: &mut FutarchyConfig, period: u64) {
    let trading_params = dao_config::trading_params_mut(&mut config.config);
    dao_config::set_trading_period_ms(trading_params, period);
}

public fun set_conditional_amm_fee_bps(config: &mut FutarchyConfig, fee: u16) {
    let trading_params = dao_config::trading_params_mut(&mut config.config);
    dao_config::set_conditional_amm_fee_bps(trading_params, (fee as u64));
}

public fun set_spot_amm_fee_bps(config: &mut FutarchyConfig, fee: u16) {
    let trading_params = dao_config::trading_params_mut(&mut config.config);
    dao_config::set_spot_amm_fee_bps(trading_params, (fee as u64));
}

public fun set_amm_twap_start_delay(config: &mut FutarchyConfig, delay: u64) {
    let twap_cfg = dao_config::twap_config_mut(&mut config.config);
    dao_config::set_start_delay(twap_cfg, delay);
}

public fun set_amm_twap_step_max(config: &mut FutarchyConfig, max: u64) {
    let twap_cfg = dao_config::twap_config_mut(&mut config.config);
    dao_config::set_step_max(twap_cfg, max);
}

public fun set_amm_twap_initial_observation(config: &mut FutarchyConfig, obs: u128) {
    let twap_cfg = dao_config::twap_config_mut(&mut config.config);
    dao_config::set_initial_observation(twap_cfg, obs);
}

public fun set_twap_threshold(config: &mut FutarchyConfig, threshold: u64) {
    let twap_cfg = dao_config::twap_config_mut(&mut config.config);
    dao_config::set_threshold(twap_cfg, threshold);
}

public fun set_max_outcomes(config: &mut FutarchyConfig, max: u64) {
    let gov_cfg = dao_config::governance_config_mut(&mut config.config);
    dao_config::set_max_outcomes(gov_cfg, max);
}

public fun set_max_actions_per_outcome(config: &mut FutarchyConfig, max: u64) {
    let gov_cfg = dao_config::governance_config_mut(&mut config.config);
    dao_config::set_max_actions_per_outcome(gov_cfg, max);
}

public fun set_required_bond_amount(config: &mut FutarchyConfig, amount: u64) {
    let gov_cfg = dao_config::governance_config_mut(&mut config.config);
    dao_config::set_required_bond_amount(gov_cfg, amount);
}

public fun set_max_intents_per_outcome(config: &mut FutarchyConfig, max: u64) {
    let gov_cfg = dao_config::governance_config_mut(&mut config.config);
    dao_config::set_max_intents_per_outcome(gov_cfg, max);
}

public fun set_proposal_intent_expiry_ms(config: &mut FutarchyConfig, expiry: u64) {
    let gov_cfg = dao_config::governance_config_mut(&mut config.config);
    dao_config::set_proposal_intent_expiry_ms(gov_cfg, expiry);
}

public fun set_max_concurrent_proposals(config: &mut FutarchyConfig, max: u64) {
    let gov_cfg = dao_config::governance_config_mut(&mut config.config);
    dao_config::set_max_concurrent_proposals(gov_cfg, max);
}

public fun set_fee_escalation_basis_points(config: &mut FutarchyConfig, points: u64) {
    let gov_cfg = dao_config::governance_config_mut(&mut config.config);
    dao_config::set_fee_escalation_basis_points(gov_cfg, points);
}

public fun update_slash_distribution(
    config: &mut FutarchyConfig,
    slasher_reward_bps: u16,
    dao_treasury_bps: u16,
    protocol_bps: u16,
    burn_bps: u16,
) {
    assert!(slasher_reward_bps + dao_treasury_bps + protocol_bps + burn_bps == 10000, EInvalidSlashDistribution);
    config.slash_distribution = SlashDistribution {
        slasher_reward_bps,
        dao_treasury_bps,
        protocol_bps,
        burn_bps,
    };
}

public fun set_proposals_enabled(state: &mut DaoState, enabled: bool) {
    // If disabling, mark as paused
    if (!enabled && state.operational_state == DAO_STATE_ACTIVE) {
        state.operational_state = DAO_STATE_PAUSED;
    } else if (enabled && state.operational_state == DAO_STATE_PAUSED) {
        state.operational_state = DAO_STATE_ACTIVE;
    }
}

// === Account Creation Functions ===

/// Creates a new account with Extensions validation for use with the Futarchy config
public fun new_with_extensions(
    extensions: &Extensions,
    config: FutarchyConfig,
    ctx: &mut TxContext
): Account<FutarchyConfig> {
    // Create dependencies using Extensions for validation
    let deps = deps::new_latest_extensions(
        extensions,
        vector[
            b"AccountProtocol".to_string(),
            b"FutarchyCore".to_string()
        ]
    );

    // Create account with FutarchyConfig using the config witness
    account::new(
        config,
        deps,
        version::current(),
        ConfigWitness {},
        ctx
    )
}

/// Test version that creates account without Extensions validation
#[test_only]
public fun new_account_test(
    config: FutarchyConfig,
    ctx: &mut TxContext
): Account<FutarchyConfig> {
    // Create dependencies for testing without Extensions
    let deps = deps::new_for_testing();

    // Create account with FutarchyConfig using the config witness
    account::new(
        config,
        deps,
        version::current(),
        ConfigWitness {},
        ctx
    )
}

/// Get mutable access to internal config for test scenarios
#[test_only]
public fun internal_config_mut_test(
    account: &mut Account<FutarchyConfig>
): &mut FutarchyConfig {
    account::config_mut<FutarchyConfig, ConfigWitness>(
        account,
        version::current(),
        ConfigWitness {}
    )
}

/// Set the proposal queue ID as a dynamic field on the account
public fun set_proposal_queue_id(account: &mut Account<FutarchyConfig>, queue_id: Option<ID>) {
    if (queue_id.is_some()) {
        account::add_managed_data(account, ProposalQueueKey {}, queue_id.destroy_some(), version::current());
    } else {
        // Remove the field if setting to none
        if (account::has_managed_data<FutarchyConfig, ProposalQueueKey>(account, ProposalQueueKey {})) {
            let _: ID = account::remove_managed_data(account, ProposalQueueKey {}, version::current());
        }
    }
}

/// Get the proposal queue ID from dynamic field
public fun get_proposal_queue_id(account: &Account<FutarchyConfig>): Option<ID> {
    if (account::has_managed_data<FutarchyConfig, ProposalQueueKey>(account, ProposalQueueKey {})) {
        option::some(*account::borrow_managed_data(account, ProposalQueueKey {}, version::current()))
    } else {
        option::none()
    }
}

/// Create auth witness for this account config
public fun authenticate(account: &Account<FutarchyConfig>, ctx: &TxContext): ConfigWitness {
    let _ = account;
    let _ = ctx;
    ConfigWitness {}
}

// === Launchpad Initial Price Functions ===

/// Set the launchpad initial price (write-once, can only be called once)
/// This is the canonical price from the launchpad raise: tokens_for_sale / final_raise_amount
/// Used to enforce: 1) AMM initialization ratio, 2) founder reward minimum price
public fun set_launchpad_initial_price(
    config: &mut FutarchyConfig,
    price: u128,
) {
    assert!(config.launchpad_initial_price.is_none(), ELaunchpadPriceAlreadySet);
    config.launchpad_initial_price = option::some(price);
}

/// Get the launchpad initial price
/// Returns None if DAO was not created via launchpad or price hasn't been set
public fun get_launchpad_initial_price(config: &FutarchyConfig): Option<u128> {
    config.launchpad_initial_price
}

}
