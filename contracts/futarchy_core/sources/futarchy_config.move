/// Pure configuration struct for Futarchy governance systems
/// This is the configuration object used with Account<FutarchyConfig>
/// All dynamic state and object references are stored as dynamic fields on the Account
module futarchy_core::futarchy_config;

// === Imports ===
use std::{
    string::{Self, String},
    type_name,
};
use futarchy_core::dao_config::{Self, DaoConfig};

// === Constants ===

// Operational states
const DAO_STATE_ACTIVE: u8 = 0;
const DAO_STATE_DISSOLVING: u8 = 1;
const DAO_STATE_PAUSED: u8 = 2;
const DAO_STATE_DISSOLVED: u8 = 3;

// === Errors ===

const EInvalidSlashDistribution: u64 = 0;

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

    // Reward configurations
    proposal_pass_reward: u64,    // Reward for proposal creator when proposal passes (in SUI)
    outcome_win_reward: u64,       // Reward for outcome creator when their outcome wins (in SUI)
    review_to_trading_fee: u64,   // Fee to advance from review to trading (in SUI)
    finalization_fee: u64,         // Fee to finalize proposal after trading (in SUI)

    // Verification configuration
    verification_level: u8,        // 0 = unverified, 1 = basic, 2 = standard, 3 = premium
    dao_score: u64,                // DAO quality score (0-unlimited, higher = better, admin-set only)
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
        proposal_pass_reward: 10_000_000_000,    // 10 SUI default
        outcome_win_reward: 5_000_000_000,       // 5 SUI default
        review_to_trading_fee: 1_000_000_000,    // 1 SUI default
        finalization_fee: 1_000_000_000,         // 1 SUI default
        verification_level: 0,                    // Unverified by default
        dao_score: 0,                              // No score by default
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
        proposal_pass_reward,
        outcome_win_reward,
        review_to_trading_fee,
        finalization_fee,
        ..config
    }
}

public fun with_verification_level(
    config: FutarchyConfig,
    verification_level: u8,
): FutarchyConfig {
    FutarchyConfig {
        verification_level,
        ..config
    }
}

public fun with_dao_score(
    config: FutarchyConfig,
    dao_score: u64,
): FutarchyConfig {
    FutarchyConfig {
        dao_score,
        ..config
    }
}

public fun with_slash_distribution(
    config: FutarchyConfig,
    slash_distribution: SlashDistribution,
): FutarchyConfig {
    FutarchyConfig {
        slash_distribution,
        ..config
    }
}