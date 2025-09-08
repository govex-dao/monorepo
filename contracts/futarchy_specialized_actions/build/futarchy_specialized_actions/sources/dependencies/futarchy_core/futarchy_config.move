/// Configuration struct for Futarchy governance systems
/// Replaces the old DAO god object pattern with a focused configuration struct
/// for use with Account<FutarchyConfig>
module futarchy_core::futarchy_config;

// === Imports ===
use std::{
    string::{Self, String},
    ascii::String as AsciiString,
    option::{Self, Option},
    type_name,
};
use sui::{
    clock::Clock,
    url::{Self, Url},
    coin::TreasuryCap,
    table::{Self, Table},
    object::{Self, ID},
};
use account_protocol::{
    account::{Self, Account, Auth},
    executable::{Self, Executable},
    deps::{Self, Deps},
    intents::{Self, Intents, Intent},
    version_witness::VersionWitness,
};
use account_extensions::extensions::Extensions;
use futarchy_core::dao_config::{Self, DaoConfig, TradingParams, TwapConfig, GovernanceConfig, MetadataConfig, SecurityConfig};
use futarchy_core::version;
use futarchy_core::events;

// === Constants ===
const DAO_STATE_ACTIVE: u8 = 0;
const DAO_STATE_DISSOLVING: u8 = 1;
const DAO_STATE_PAUSED: u8 = 2;
const DAO_STATE_DISSOLVED: u8 = 3;

const OUTCOME_ACCEPTED: u8 = 0;
const OUTCOME_REJECTED: u8 = 1;

// === Errors ===
const EProposalNotApproved: u64 = 1;
const EInvalidAdmin: u64 = 2;
const EInvalidSlashDistribution: u64 = 3;
const EIntentNotFound: u64 = 4;

// === Events ===

/// Emitted when proposals are enabled or disabled
public struct ProposalsEnabledChanged has copy, drop {
    account_id: ID,
    enabled: bool,
    timestamp: u64,
}

/// Emitted when DAO name is updated
public struct DaoNameChanged has copy, drop {
    account_id: ID,
    old_name: AsciiString,
    new_name: AsciiString,
    timestamp: u64,
}

/// Emitted when trading parameters are updated
public struct TradingParamsChanged has copy, drop {
    account_id: ID,
    timestamp: u64,
}

/// Emitted when metadata is updated
public struct MetadataChanged has copy, drop {
    account_id: ID,
    timestamp: u64,
}

/// Emitted when governance settings are updated
public struct GovernanceSettingsChanged has copy, drop {
    account_id: ID,
    timestamp: u64,
}

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

/// Core Futarchy DAO configuration
/// Contains composed configuration from dao_config module plus state tracking
public struct FutarchyConfig has store {
    // Type information (still belongs at top level)
    asset_type: String,
    stable_type: String,
    
    // Composed configuration from dao_config module
    config: DaoConfig,
    
    // State tracking (does not belong in dao_config)
    operational_state: u8,
    active_proposals: u64,
    total_proposals: u64,
    
    // References to other objects (does not belong in dao_config)
    treasury_id: Option<ID>,
    operating_agreement_id: Option<ID>,
    
    // Slash distribution configuration
    slash_distribution: SlashDistribution,
    
    // Proposal queue ID
    proposal_queue_id: Option<ID>,
    
    
    // Fee manager ID for proposal fee management
    fee_manager_id: Option<ID>,
    
    // Spot AMM pool ID for the DAO's liquidity pool
    spot_pool_id: Option<ID>,
    
    // Verification
    attestation_url: String,
    verification_pending: bool,
    verification_level: u8, // 0 = unverified, 1 = basic, 2 = standard, 3 = premium, etc.
    
    // Reward configurations
    proposal_pass_reward: u64, // Reward for proposal creator when proposal passes (in SUI)
    outcome_win_reward: u64,   // Reward for outcome creator when their outcome wins (in SUI)
    review_to_trading_fee: u64, // Fee to advance from review to trading (in SUI)
    finalization_fee: u64,      // Fee to finalize proposal after trading (in SUI)
}

/// Helper struct for creating FutarchyConfig with default values
/// Now simplified as we use DaoConfig for most parameters
public struct ConfigParams has store, copy, drop {
    dao_config: DaoConfig,
    slash_distribution: SlashDistribution,
}

/// Witness struct for authentication and operations
public struct Witness has drop {}

// === Public Functions ===

/// Creates a new FutarchyConfig with specified parameters
public fun new<AssetType: drop, StableType>(
    params: ConfigParams,
    _ctx: &mut TxContext,
): FutarchyConfig {
    FutarchyConfig {
        asset_type: type_name::get<AssetType>().into_string().to_string(),
        stable_type: type_name::get<StableType>().into_string().to_string(),
        config: params.dao_config,
        operational_state: DAO_STATE_ACTIVE,
        active_proposals: 0,
        total_proposals: 0,
        treasury_id: option::none(),
        operating_agreement_id: option::none(),
        slash_distribution: params.slash_distribution,
        proposal_queue_id: option::none(),
        fee_manager_id: option::none(),
        spot_pool_id: option::none(),
        attestation_url: b"".to_string(),
        verification_pending: false,
        verification_level: 0, // 0 = unverified
        // Default reward configurations (can be updated later)
        proposal_pass_reward: 10_000_000_000, // 10 SUI default
        outcome_win_reward: 5_000_000_000,    // 5 SUI default  
        review_to_trading_fee: 1_000_000_000, // 1 SUI default
        finalization_fee: 1_000_000_000,      // 1 SUI default
    }
}

/// Creates configuration parameters from structured config objects
public fun new_config_params(
    dao_config: DaoConfig,
    slash_distribution: SlashDistribution,
): ConfigParams {
    ConfigParams {
        dao_config,
        slash_distribution,
    }
}

/// Creates configuration parameters from individual values
public fun new_config_params_from_values(
    min_asset_amount: u64,
    min_stable_amount: u64,
    review_period_ms: u64,
    trading_period_ms: u64,
    amm_twap_start_delay: u64,
    amm_twap_step_max: u64,
    amm_twap_initial_observation: u128,
    twap_threshold: u64,
    amm_total_fee_bps: u64,
    max_outcomes: u64,
    proposal_fee_per_outcome: u64,
    max_concurrent_proposals: u64,
    required_bond_amount: u64,
    proposal_recreation_window_ms: u64,
    max_proposal_chain_depth: u64,
    fee_escalation_basis_points: u64,
    dao_name: AsciiString,
    icon_url: Url,
    description: String,
): ConfigParams {
    // Create structured configs
    let trading_params = dao_config::new_trading_params(
        min_asset_amount,
        min_stable_amount,
        review_period_ms,
        trading_period_ms,
        amm_total_fee_bps,
    );
    
    let twap_config = dao_config::new_twap_config(
        amm_twap_start_delay,
        amm_twap_step_max,
        amm_twap_initial_observation,
        twap_threshold,
    );
    
    let governance_config = dao_config::new_governance_config(
        max_outcomes,
        5,    // max_actions_per_outcome (default 5 actions per outcome)
        proposal_fee_per_outcome,
        required_bond_amount,
        max_concurrent_proposals,
        proposal_recreation_window_ms,
        max_proposal_chain_depth,
        fee_escalation_basis_points,
        true,  // proposal_creation_enabled (default)
        true,  // accept_new_proposals (default)
        10,    // max_intents_per_outcome (default)
        1000000000, // optimistic_challenge_fee (1 billion MIST = 1 token, default)
        864000000, // optimistic_challenge_period_ms (10 days default)
        7200000, // eviction_grace_period_ms (2 hours default)
        2592000000, // proposal_intent_expiry_ms (30 days default)
    );
    
    let metadata_config = dao_config::new_metadata_config(
        dao_name,
        icon_url,
        description,
    );
    
    let dao_config = dao_config::new_dao_config(
        trading_params,
        twap_config,
        governance_config,
        metadata_config,
        dao_config::default_security_config(),  // Use default security config
    );
    
    ConfigParams {
        dao_config,
        slash_distribution: default_slash_distribution(),
    }
}

/// Creates default configuration parameters with sensible defaults
public fun default_config_params(): ConfigParams {
    ConfigParams {
        dao_config: dao_config::new_dao_config(
            dao_config::default_trading_params(),
            dao_config::default_twap_config(),
            dao_config::default_governance_config(),
            dao_config::new_metadata_config(
                b"Default DAO".to_ascii_string(),
                url::new_unsafe_from_bytes(b"https://example.com/icon.png"),
                b"A default DAO configuration".to_string()
            ),
            dao_config::default_security_config(),
        ),
        slash_distribution: default_slash_distribution(),
    }
}

// === Slash Distribution Functions ===

/// Creates default slash distribution configuration
public fun default_slash_distribution(): SlashDistribution {
    SlashDistribution {
        slasher_reward_bps: 3000,  // 30% to the slasher
        dao_treasury_bps: 5000,     // 50% to DAO treasury
        protocol_bps: 1500,         // 15% to protocol
        burn_bps: 500,              // 5% burned
    }
}

/// Creates custom slash distribution configuration with validation
public fun new_slash_distribution(
    slasher_reward_bps: u16,
    dao_treasury_bps: u16,
    protocol_bps: u16,
    burn_bps: u16,
): SlashDistribution {
    // Ensure they sum to 10000 (100%)
    assert!(
        (slasher_reward_bps as u64) + (dao_treasury_bps as u64) + 
        (protocol_bps as u64) + (burn_bps as u64) == 10000,
        EInvalidSlashDistribution
    );
    
    SlashDistribution {
        slasher_reward_bps,
        dao_treasury_bps,
        protocol_bps,
        burn_bps,
    }
}

// === Accessor Functions ===

// Slash distribution
public fun slash_distribution(config: &FutarchyConfig): &SlashDistribution {
    &config.slash_distribution
}

// Reward configurations
public fun proposal_pass_reward(config: &FutarchyConfig): u64 { config.proposal_pass_reward }
public fun outcome_win_reward(config: &FutarchyConfig): u64 { config.outcome_win_reward }
public fun review_to_trading_fee(config: &FutarchyConfig): u64 { config.review_to_trading_fee }
public fun finalization_fee(config: &FutarchyConfig): u64 { config.finalization_fee }

// Security config getters (delegated to dao_config)
public fun deadman_enabled(config: &FutarchyConfig): bool { 
    dao_config::deadman_enabled(dao_config::security_config(&config.config)) 
}
public fun recovery_liveness_ms(config: &FutarchyConfig): u64 { 
    dao_config::recovery_liveness_ms(dao_config::security_config(&config.config)) 
}
public fun require_deadman_council(config: &FutarchyConfig): bool { 
    dao_config::require_deadman_council(dao_config::security_config(&config.config)) 
}

public fun slasher_reward_bps(slash_config: &SlashDistribution): u16 {
    slash_config.slasher_reward_bps
}

public fun dao_treasury_bps(slash_config: &SlashDistribution): u16 {
    slash_config.dao_treasury_bps
}

public fun protocol_bps(slash_config: &SlashDistribution): u16 {
    slash_config.protocol_bps
}

public fun burn_bps(slash_config: &SlashDistribution): u16 {
    slash_config.burn_bps
}

// Type information
public fun asset_type(config: &FutarchyConfig): &String { &config.asset_type }
public fun stable_type(config: &FutarchyConfig): &String { &config.stable_type }

// Trading parameters
public fun min_asset_amount(config: &FutarchyConfig): u64 { dao_config::min_asset_amount(dao_config::trading_params(&config.config)) }
public fun min_stable_amount(config: &FutarchyConfig): u64 { dao_config::min_stable_amount(dao_config::trading_params(&config.config)) }
public fun review_period_ms(config: &FutarchyConfig): u64 { dao_config::review_period_ms(dao_config::trading_params(&config.config)) }
public fun trading_period_ms(config: &FutarchyConfig): u64 { dao_config::trading_period_ms(dao_config::trading_params(&config.config)) }
public fun proposal_recreation_window_ms(config: &FutarchyConfig): u64 { dao_config::proposal_recreation_window_ms(dao_config::governance_config(&config.config)) }
public fun max_proposal_chain_depth(config: &FutarchyConfig): u64 { dao_config::max_proposal_chain_depth(dao_config::governance_config(&config.config)) }
public fun eviction_grace_period_ms(config: &FutarchyConfig): u64 { dao_config::eviction_grace_period_ms(dao_config::governance_config(&config.config)) }
public fun proposal_intent_expiry_ms(config: &FutarchyConfig): u64 { dao_config::proposal_intent_expiry_ms(dao_config::governance_config(&config.config)) }

// AMM configuration
public fun amm_twap_start_delay(config: &FutarchyConfig): u64 { dao_config::start_delay(dao_config::twap_config(&config.config)) }
public fun amm_twap_step_max(config: &FutarchyConfig): u64 { dao_config::step_max(dao_config::twap_config(&config.config)) }
public fun amm_twap_initial_observation(config: &FutarchyConfig): u128 { dao_config::initial_observation(dao_config::twap_config(&config.config)) }
public fun twap_threshold(config: &FutarchyConfig): u64 { dao_config::threshold(dao_config::twap_config(&config.config)) }
public fun amm_total_fee_bps(config: &FutarchyConfig): u64 { dao_config::amm_total_fee_bps(dao_config::trading_params(&config.config)) }

// Metadata
public fun dao_name(config: &FutarchyConfig): &AsciiString { dao_config::dao_name(dao_config::metadata_config(&config.config)) }
public fun icon_url(config: &FutarchyConfig): &Url { dao_config::icon_url(dao_config::metadata_config(&config.config)) }
public fun description(config: &FutarchyConfig): &String { dao_config::description(dao_config::metadata_config(&config.config)) }

// Governance parameters
public fun max_outcomes(config: &FutarchyConfig): u64 { dao_config::max_outcomes(dao_config::governance_config(&config.config)) }
public fun max_actions_per_outcome(config: &FutarchyConfig): u64 { dao_config::max_actions_per_outcome(dao_config::governance_config(&config.config)) }
public fun proposal_fee_per_outcome(config: &FutarchyConfig): u64 { dao_config::proposal_fee_per_outcome(dao_config::governance_config(&config.config)) }
public fun operational_state(config: &FutarchyConfig): u8 { config.operational_state }
public fun max_concurrent_proposals(config: &FutarchyConfig): u64 { dao_config::max_concurrent_proposals(dao_config::governance_config(&config.config)) }
public fun required_bond_amount(config: &FutarchyConfig): u64 { dao_config::required_bond_amount(dao_config::governance_config(&config.config)) }
public fun optimistic_challenge_fee(config: &FutarchyConfig): u64 { dao_config::optimistic_challenge_fee(dao_config::governance_config(&config.config)) }
public fun optimistic_challenge_period_ms(config: &FutarchyConfig): u64 { dao_config::optimistic_challenge_period_ms(dao_config::governance_config(&config.config)) }

// State tracking
public fun active_proposals(config: &FutarchyConfig): u64 { config.active_proposals }
public fun total_proposals(config: &FutarchyConfig): u64 { config.total_proposals }

// References
public fun spot_pool_id(config: &FutarchyConfig): &Option<ID> { &config.spot_pool_id }
public fun treasury_id(config: &FutarchyConfig): &Option<ID> { &config.treasury_id }
public fun operating_agreement_id(config: &FutarchyConfig): &Option<ID> { &config.operating_agreement_id }

// Queue management (deprecated - using priority_queue module now)
public fun fee_escalation_basis_points(config: &FutarchyConfig): u64 { dao_config::fee_escalation_basis_points(dao_config::governance_config(&config.config)) }
public fun proposal_queue_id(config: &FutarchyConfig): &Option<ID> { &config.proposal_queue_id }
// Removed - using statically-typed actions pattern
public fun fee_manager_id(config: &FutarchyConfig): &Option<ID> { &config.fee_manager_id }

// Verification
public fun attestation_url(config: &FutarchyConfig): &String { &config.attestation_url }
public fun verification_pending(config: &FutarchyConfig): bool { config.verification_pending }
public fun verification_level(config: &FutarchyConfig): u8 { config.verification_level }
public fun is_verified(config: &FutarchyConfig): bool { config.verification_level > 0 }

// State constants
public fun state_active(): u8 { DAO_STATE_ACTIVE }
public fun state_dissolving(): u8 { DAO_STATE_DISSOLVING }
public fun state_paused(): u8 { DAO_STATE_PAUSED }
public fun state_dissolved(): u8 { DAO_STATE_DISSOLVED }

// === Package-Level Mutators ===

// Trading parameters
public fun set_min_asset_amount(config: &mut FutarchyConfig, amount: u64) {
    // Use direct mutable reference for efficient in-place update
    let trading_params = dao_config::trading_params_mut(&mut config.config);
    dao_config::set_min_asset_amount(trading_params, amount);
}

public fun set_min_stable_amount(config: &mut FutarchyConfig, amount: u64) {
    // Use direct mutable reference for efficient in-place update
    let trading_params = dao_config::trading_params_mut(&mut config.config);
    dao_config::set_min_stable_amount(trading_params, amount);
}

public fun set_review_period_ms(config: &mut FutarchyConfig, period: u64) {
    // Use direct mutable reference for efficient in-place update
    let trading_params = dao_config::trading_params_mut(&mut config.config);
    dao_config::set_review_period_ms(trading_params, period);
}

public fun set_trading_period_ms(config: &mut FutarchyConfig, period: u64) {
    // Use direct mutable reference for efficient in-place update
    let trading_params = dao_config::trading_params_mut(&mut config.config);
    dao_config::set_trading_period_ms(trading_params, period);
}

public fun set_proposal_recreation_window_ms(config: &mut FutarchyConfig, window: u64) {
    // Use direct mutable reference for efficient in-place update
    let governance_config = dao_config::governance_config_mut(&mut config.config);
    dao_config::set_proposal_recreation_window_ms(governance_config, window);
}

public fun set_max_proposal_chain_depth(config: &mut FutarchyConfig, depth: u64) {
    // Use direct mutable reference for efficient in-place update
    let governance_config = dao_config::governance_config_mut(&mut config.config);
    dao_config::set_max_proposal_chain_depth(governance_config, depth);
}

// AMM configuration
public fun set_amm_twap_start_delay(config: &mut FutarchyConfig, delay: u64) {
    // Use direct mutable reference for efficient in-place update
    let twap_config = dao_config::twap_config_mut(&mut config.config);
    dao_config::set_start_delay(twap_config, delay);
}

public fun set_amm_twap_step_max(config: &mut FutarchyConfig, max: u64) {
    // Use direct mutable reference for efficient in-place update
    let twap_config = dao_config::twap_config_mut(&mut config.config);
    dao_config::set_step_max(twap_config, max);
}

public fun set_amm_twap_initial_observation(config: &mut FutarchyConfig, obs: u128) {
    // Use direct mutable reference for efficient in-place update
    let twap_config = dao_config::twap_config_mut(&mut config.config);
    dao_config::set_initial_observation(twap_config, obs);
}

public fun set_twap_threshold(config: &mut FutarchyConfig, threshold: u64) {
    // Use direct mutable reference for efficient in-place update
    let twap_config = dao_config::twap_config_mut(&mut config.config);
    dao_config::set_threshold(twap_config, threshold);
}

public fun set_amm_total_fee_bps(config: &mut FutarchyConfig, fee_bps: u64) {
    // Use direct mutable reference for efficient in-place update
    let trading_params = dao_config::trading_params_mut(&mut config.config);
    dao_config::set_amm_total_fee_bps(trading_params, fee_bps);
}

// Metadata
public fun set_dao_name(config: &mut FutarchyConfig, name: AsciiString) {
    // Use direct mutable reference for efficient in-place update
    let metadata_config = dao_config::metadata_config_mut(&mut config.config);
    dao_config::set_dao_name(metadata_config, name);
}

public fun set_icon_url(config: &mut FutarchyConfig, url: Url) {
    // Use direct mutable reference for efficient in-place update
    let metadata_config = dao_config::metadata_config_mut(&mut config.config);
    dao_config::set_icon_url(metadata_config, url);
}

public fun set_description(config: &mut FutarchyConfig, desc: String) {
    // Use direct mutable reference for efficient in-place update
    let metadata_config = dao_config::metadata_config_mut(&mut config.config);
    dao_config::set_description(metadata_config, desc);
}

// Governance parameters
public fun set_max_outcomes(config: &mut FutarchyConfig, max: u64) {
    // Use direct mutable reference for efficient in-place update
    let governance_config = dao_config::governance_config_mut(&mut config.config);
    dao_config::set_max_outcomes(governance_config, max);
}

public fun set_max_actions_per_outcome(config: &mut FutarchyConfig, max: u64) {
    // Use direct mutable reference for efficient in-place update
    let governance_config = dao_config::governance_config_mut(&mut config.config);
    dao_config::set_max_actions_per_outcome(governance_config, max);
}

public fun set_proposal_fee_per_outcome(config: &mut FutarchyConfig, fee: u64) {
    // Use direct mutable reference for efficient in-place update
    let governance_config = dao_config::governance_config_mut(&mut config.config);
    dao_config::set_proposal_fee_per_outcome(governance_config, fee);
}

public fun set_operational_state(config: &mut FutarchyConfig, new_state: u8) {
    config.operational_state = new_state;
}

public fun set_max_concurrent_proposals(config: &mut FutarchyConfig, max: u64) {
    // Use direct mutable reference for efficient in-place update
    let governance_config = dao_config::governance_config_mut(&mut config.config);
    dao_config::set_max_concurrent_proposals(governance_config, max);
}

public fun set_required_bond_amount(config: &mut FutarchyConfig, amount: u64) {
    // Use direct mutable reference for efficient in-place update
    let governance_config = dao_config::governance_config_mut(&mut config.config);
    dao_config::set_required_bond_amount(governance_config, amount);
}

public fun set_optimistic_challenge_fee(config: &mut FutarchyConfig, amount: u64) {
    // Use direct mutable reference for efficient in-place update
    let governance_config = dao_config::governance_config_mut(&mut config.config);
    dao_config::set_optimistic_challenge_fee(governance_config, amount);
}

public fun set_optimistic_challenge_period_ms(config: &mut FutarchyConfig, period: u64) {
    // Use direct mutable reference for efficient in-place update
    let governance_config = dao_config::governance_config_mut(&mut config.config);
    dao_config::set_optimistic_challenge_period_ms(governance_config, period);
}

// State tracking
public fun increment_active_proposals(config: &mut FutarchyConfig) {
    config.active_proposals = config.active_proposals + 1;
}

public fun decrement_active_proposals(config: &mut FutarchyConfig) {
    config.active_proposals = config.active_proposals - 1;
}

public fun increment_total_proposals(config: &mut FutarchyConfig) {
    config.total_proposals = config.total_proposals + 1;
}

// References
public fun set_treasury_id(config: &mut FutarchyConfig, id: Option<ID>) {
    config.treasury_id = id;
}

public fun set_operating_agreement_id(config: &mut FutarchyConfig, id: Option<ID>) {
    config.operating_agreement_id = id;
}

// Queue management (deprecated - removed, using priority_queue module now)

public fun set_proposal_queue_id(config: &mut FutarchyConfig, id: Option<ID>) {
    config.proposal_queue_id = id;
}

// Removed - using statically-typed actions pattern

// Verification
public fun set_attestation_url(config: &mut FutarchyConfig, url: String) {
    config.attestation_url = url;
}

public fun set_verification_pending(config: &mut FutarchyConfig, pending: bool) {
    config.verification_pending = pending;
}

public fun set_verification_level(config: &mut FutarchyConfig, level: u8) {
    config.verification_level = level;
}

// Metadata setters
public fun set_name(config: &mut FutarchyConfig, name: AsciiString) {
    // Use direct mutable reference for efficient in-place update
    let metadata_config = dao_config::metadata_config_mut(&mut config.config);
    dao_config::set_dao_name(metadata_config, name);
}

public fun set_admin(_config: &mut FutarchyConfig, admin: address) {
    // In the account protocol architecture, admin is managed through the account's
    // authorization system rather than a field in the config.
    // This function is kept for API compatibility but doesn't modify the config.
    // 
    // To change admin/authorization in the account protocol:
    // 1. Use account protocol's role/member management functions
    // 2. Or implement custom authorization logic via Auth objects
    //
    // Since this is called internally during setup, we'll just validate the address
    assert!(admin != @0x0, EInvalidAdmin);
}

public fun set_config_params(config: &mut FutarchyConfig, params: ConfigParams) {
    config.config = params.dao_config;
    config.slash_distribution = params.slash_distribution;
}

public fun set_proposals_enabled_internal(config: &mut FutarchyConfig, enabled: bool) {
    if (enabled) {
        config.operational_state = DAO_STATE_ACTIVE;
    } else {
        config.operational_state = DAO_STATE_PAUSED;
    }
}

public fun set_fee_manager_id(config: &mut FutarchyConfig, id: ID) {
    config.fee_manager_id = option::some(id);
}

public fun set_fee_escalation_basis_points(config: &mut FutarchyConfig, points: u64) {
    // Use direct mutable reference for efficient in-place update
    let governance_config = dao_config::governance_config_mut(&mut config.config);
    dao_config::set_fee_escalation_basis_points(governance_config, points);
}

public fun set_max_intents_per_outcome(config: &mut FutarchyConfig, max: u64) {
    // Use direct mutable reference for efficient in-place update
    let governance_config = dao_config::governance_config_mut(&mut config.config);
    dao_config::set_max_intents_per_outcome(governance_config, max);
}

public fun set_eviction_grace_period_ms(config: &mut FutarchyConfig, period: u64) {
    // Use direct mutable reference for efficient in-place update
    let governance_config = dao_config::governance_config_mut(&mut config.config);
    dao_config::set_eviction_grace_period_ms(governance_config, period);
}

public fun set_proposal_intent_expiry_ms(config: &mut FutarchyConfig, period: u64) {
    // Use direct mutable reference for efficient in-place update
    let governance_config = dao_config::governance_config_mut(&mut config.config);
    dao_config::set_proposal_intent_expiry_ms(governance_config, period);
}

public fun set_spot_pool_id(config: &mut FutarchyConfig, id: ID) {
    config.spot_pool_id = option::some(id);
}

/// Update the slash distribution configuration
public fun update_slash_distribution(
    config: &mut FutarchyConfig,
    slasher_reward_bps: u16,
    dao_treasury_bps: u16,
    protocol_bps: u16,
    burn_bps: u16,
) {
    config.slash_distribution = new_slash_distribution(
        slasher_reward_bps,
        dao_treasury_bps,
        protocol_bps,
        burn_bps
    );
}

// Setters for reward configurations
public fun set_proposal_pass_reward(config: &mut FutarchyConfig, amount: u64) {
    config.proposal_pass_reward = amount;
}

public fun set_outcome_win_reward(config: &mut FutarchyConfig, amount: u64) {
    config.outcome_win_reward = amount;
}

public fun set_review_to_trading_fee(config: &mut FutarchyConfig, amount: u64) {
    config.review_to_trading_fee = amount;
}

public fun set_finalization_fee(config: &mut FutarchyConfig, amount: u64) {
    config.finalization_fee = amount;
}

// Security config setters (use direct mutable references)
public fun set_deadman_enabled(config: &mut FutarchyConfig, val: bool) {
    // Use direct mutable reference for efficient in-place update
    let security_config = dao_config::security_config_mut(&mut config.config);
    dao_config::set_deadman_enabled(security_config, val);
}

public fun set_recovery_liveness_ms(config: &mut FutarchyConfig, ms: u64) {
    // Use direct mutable reference for efficient in-place update
    let security_config = dao_config::security_config_mut(&mut config.config);
    dao_config::set_recovery_liveness_ms(security_config, ms);
}

public fun set_require_deadman_council(config: &mut FutarchyConfig, val: bool) {
    // Use direct mutable reference for efficient in-place update
    let security_config = dao_config::security_config_mut(&mut config.config);
    dao_config::set_require_deadman_council(security_config, val);
}

// Removed authorized_members_mut - auth is managed by account protocol

// === Account Creation ===
#[test_only]
public fun new_account_test(
    config: FutarchyConfig,
    ctx: &mut TxContext,
): Account<FutarchyConfig> {
    create_test_account(config, ctx)
}

/// Create a new Account with Extensions (production version)
public fun new_account_with_extensions(
    extensions: &Extensions,
    config: FutarchyConfig,
    ctx: &mut TxContext,
): Account<FutarchyConfig> {
    use account_protocol::{
        account_interface,
        deps,
    };
    
    // Include AccountProtocol, Futarchy AND AccountActions as deps.
    // This is required because we call account_actions::* modules (e.g. package_upgrade, owned...).
    account_interface::create_account!(
        config,
        version::current(),
        GovernanceWitness {},
        ctx,
        || deps::new_latest_extensions(
            extensions, 
            vector[
                b"AccountProtocol".to_string(),
                b"Futarchy".to_string(),
                b"AccountActions".to_string(), // <--- added
            ]
        )
    )
}

/// Create a new Account that allows unverified packages (for production use)
/// IMPORTANT: @futarchy_core must be the real deployed address, not 0x0
public fun new_account_unverified(
    extensions: &Extensions,
    config: FutarchyConfig,
    ctx: &mut TxContext,
): Account<FutarchyConfig> {
    use account_protocol::{
        account_interface,
        deps,
    };
    
    // Create deps with futarchy included
    // unverified_allowed = true bypasses Extensions registry check
    // but the address still needs to be in the deps list for deps::check()
    account_interface::create_account!(
        config,
        version::current(), // Use the real futarchy version witness
        GovernanceWitness {},
        ctx,
        || deps::new(
            extensions,
            true, // unverified_allowed = true to bypass Extensions registry
            vector[
                b"AccountProtocol".to_string(),
                b"Futarchy".to_string(),
            ],
            vector[
                @account_protocol,
                @futarchy_core, // MUST be the real deployed address, not 0x0
            ],
            vector[1, version::get()] // versions
        )
    )
}

#[test_only]
/// Create a test account without Extensions
/// IMPORTANT: Uses @account_protocol witness because @futarchy_core (0x0) is not deployed
fun create_test_account(
    config: FutarchyConfig,
    ctx: &mut TxContext,
): Account<FutarchyConfig> {
    use account_protocol::{
        account_interface,
        deps,
        version_witness,
    };
    
    // Must use @account_protocol witness for testing because:
    // 1. deps::check() always validates the address is in deps (ignores unverified_allowed)
    // 2. @futarchy_core is 0x0 (not deployed) so can't be in deps
    // 3. @account_protocol IS in the test deps
    let account = account_interface::create_account!(
        config,
        version_witness::new_for_testing(@account_protocol),
        GovernanceWitness {},
        ctx,
        || deps::new_for_testing()
    );
    
    account
}

// === Package-level Account Access ===

/// Get mutable access to config (package-level only)
public fun internal_config_mut(
    account: &mut Account<FutarchyConfig>
): &mut FutarchyConfig {
    account::config_mut(account, version::current(), GovernanceWitness {})
}

#[test_only]
/// Get mutable access to config for tests (package-level only)
public fun internal_config_mut_test(
    account: &mut Account<FutarchyConfig>
): &mut FutarchyConfig {
    use account_protocol::version_witness;
    account::config_mut(account, version_witness::new_for_testing(@account_protocol), GovernanceWitness {})
}

/// Set DAO pool ID (package-level only)  
public fun set_dao_pool_id(
    config: &mut FutarchyConfig,
    pool_id: ID,
) {
    config.spot_pool_id = option::some(pool_id);
}


// === Governance Core Functions ===

/// Authenticate and get an Auth token
/// INTERNAL USE ONLY - must be called through action dispatcher
public fun authenticate(
    account: &Account<FutarchyConfig>,
    _ctx: &mut TxContext,
): Auth {
    account::new_auth(
        account,
        version::current(),
        GovernanceWitness {}
    )
}

/// Simple outcome type for approved proposals
/// This is intentionally minimal to maximize compatibility with standard intents
public struct ApprovedProposal has store, drop, copy {
    proposal_id: ID,
    market_id: ID,
    outcome_index: u64,
}

/// Primary outcome type for futarchy intents
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
public fun new_outcome_for_intent(
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
public fun new_futarchy_outcome(
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

/// Updates the outcome with proposal and market IDs once proposal is created
public fun set_proposal_info(
    outcome: &mut FutarchyOutcome,
    proposal_id: ID,
    market_id: ID,
) {
    outcome.proposal_id = option::some(proposal_id);
    outcome.market_id = option::some(market_id);
}

/// Marks the outcome as approved when proposal passes
public fun approve_outcome(
    outcome: &mut FutarchyOutcome,
) {
    outcome.approved = true;
}

/// Updates the intent key for an outcome
public fun set_outcome_intent_key(outcome: &mut FutarchyOutcome, intent_key: String) {
    outcome.intent_key = intent_key;
}

/// Gets the min execution time from an outcome
public fun outcome_min_execution_time(outcome: &FutarchyOutcome): u64 {
    outcome.min_execution_time
}

/// Witness for governance operations
public struct GovernanceWitness has drop {}

/// Witness for FutarchyConfig creation
public struct FutarchyConfigWitness has drop {}

// === Council Approval System (Generic Only) ===

/// Generic approval for all council actions
public struct GenericApproval has store, drop, copy {
    dao_id: ID,
    action_type: String,  // "policy_remove", "policy_set", "custody_accept", etc.
    resource_key: String,  // The resource being acted upon
    metadata: vector<String>,  // Key-value pairs as flat vector [k1, v1, k2, v2, ...]
    expires_at: u64,
}

// === Helper Functions for Generic Approvals ===

/// Create a generic approval for policy removal
public fun new_policy_removal_approval(
    dao_id: ID,
    resource_key: String,
    expires_at: u64,
    ctx: &mut TxContext
): GenericApproval {
    let mut metadata = vector::empty<String>();
    metadata.push_back(b"resource_key".to_string());
    metadata.push_back(resource_key);
    
    GenericApproval {
        dao_id,
        action_type: b"policy_remove".to_string(),
        resource_key,
        metadata,
        expires_at,
    }
}

/// Create a generic approval for policy set
public fun new_policy_set_approval(
    dao_id: ID,
    resource_key: String,
    policy_account_id: ID,
    intent_key_prefix: String,
    expires_at: u64,
    ctx: &mut TxContext
): GenericApproval {
    let mut metadata = vector::empty<String>();
    // For now, store ID as hex string (in production, would need proper serialization)
    let id_bytes = object::id_to_bytes(&policy_account_id);
    let id_hex = sui::hex::encode(id_bytes);
    metadata.push_back(b"policy_account_id".to_string());
    metadata.push_back(std::string::utf8(id_hex));
    metadata.push_back(b"intent_key_prefix".to_string());
    metadata.push_back(intent_key_prefix);
    
    GenericApproval {
        dao_id,
        action_type: b"policy_set".to_string(),
        resource_key,
        metadata,
        expires_at,
    }
}

/// Create a generic approval for custody operations
public fun new_custody_approval(
    dao_id: ID,
    resource_key: String,
    asset_id: ID,
    expires_at: u64,
    ctx: &mut TxContext
): GenericApproval {
    let mut metadata = vector::empty<String>();
    // For now, store ID as hex string (in production, would need proper serialization)
    let id_bytes = object::id_to_bytes(&asset_id);
    let id_hex = sui::hex::encode(id_bytes);
    metadata.push_back(b"asset_id".to_string());
    metadata.push_back(std::string::utf8(id_hex));
    
    GenericApproval {
        dao_id,
        action_type: b"custody_accept".to_string(),
        resource_key,
        metadata,
        expires_at,
    }
}

/// Create a generic approval for cross-DAO bundle operations
public fun new_bundle_approval(
    dao_id: ID,
    bundle_id: String,
    bundle_type: String,
    expires_at: u64,
    ctx: &mut TxContext
): GenericApproval {
    let mut metadata = vector::empty<String>();
    metadata.push_back(b"bundle_type".to_string());
    metadata.push_back(bundle_type);
    
    GenericApproval {
        dao_id,
        action_type: b"cross_dao_bundle".to_string(),
        resource_key: bundle_id,
        metadata,
        expires_at,
    }
}

/// Managed-data key and container for council approvals
public struct CouncilApprovalKey has copy, drop, store {}
public struct CouncilApprovalBook has store {
    // Maps intent_key -> approval record
    approvals: Table<String, GenericApproval>,
}

/// Initialize the council approval book for a DAO (package-level only)
public fun init_approval_book(
    account: &mut Account<FutarchyConfig>,
    ctx: &mut TxContext
) {
    let book = CouncilApprovalBook {
        approvals: table::new<String, GenericApproval>(ctx),
    };
    account::add_managed_data(
        account,
        CouncilApprovalKey {},
        book,
        version::current()
    );
}

/// Get the approval book (or initialize if not present)
fun get_or_init_approval_book(
    account: &mut Account<FutarchyConfig>,
    ctx: &mut TxContext
): &mut CouncilApprovalBook {
    // Try to borrow, if it doesn't exist, initialize it
    // In production, this should be initialized during DAO creation
    // For now, we'll initialize on first use
    init_approval_book_if_needed(account, ctx);
    account::borrow_managed_data_mut(
        account,
        CouncilApprovalKey {},
        version::current()
    )
}

/// Initialize approval book if it doesn't exist
fun init_approval_book_if_needed(
    account: &mut Account<FutarchyConfig>,
    ctx: &mut TxContext
) {
    // Properly initialize the approval book if it doesn't exist
    ensure_approval_book(account, ctx);
}

/// Execute permit - minted by config module after verifying approval
public struct ExecutePermit has copy, drop {
    intent_key: String,
    dao_address: address,
    issued_at: u64,
    expires_at: u64,
    /// The actual council approval (if any) that authorized this permit
    council_approval: Option<GenericApproval>,
}

/// Information about a proposal
public struct ProposalInfo has store {
    intent_key: Option<String>,
    approved: bool,
    executed: bool,
}

/// Store proposal info when a proposal is created
/// The actual proposal creation happens through the queue submission process
public fun register_proposal(
    account: &mut Account<FutarchyConfig>,
    proposal_id: ID,
    intent_key: String,
    ctx: &mut TxContext,
) {
    let config = internal_config_mut(account);
    
    // Store the intent key associated with this proposal
    let info = ProposalInfo {
        intent_key: option::some(intent_key),
        approved: false,
        executed: false,
    };
    
    // Note: Proposal info would need to be stored in account metadata
    // For now, this is a no-op - consume the struct
    let ProposalInfo { intent_key: _, approved: _, executed: _ } = info;
    
    // Increment active proposals
    increment_active_proposals(config);
}

/// Execute a proposal's intent with generic outcome type
/// Execute a proposal's intent with generic outcome type
/// This allows standard intents to work with any outcome type
// Note: execute_proposal_intent function moved to futarchy package
// as it depends on Proposal and MarketState types from futarchy_markets

// Note: cancel_losing_intent_scoped function moved to futarchy package
// as it depends on proposal module from futarchy_markets

// Note: cancel_losing_intent_scoped_test function moved to futarchy package
// as it depends on proposal module from futarchy_markets

// === Council Approval Book Management ===

/// Ensure the approval book exists (idempotent)
fun ensure_approval_book(
    account: &mut Account<FutarchyConfig>,
    ctx: &mut TxContext
) {
    if (!account::has_managed_data(account, CouncilApprovalKey {})) {
        account::add_managed_data(
            account,
            CouncilApprovalKey {},
            CouncilApprovalBook { approvals: table::new<String, GenericApproval>(ctx) },
            version::current()
        );
    };
}

/// Record a council approval for an intent
public fun record_council_approval_generic(
    account: &mut Account<FutarchyConfig>,
    intent_key: String,
    approval: GenericApproval,
    ctx: &mut TxContext
) {
    let book = get_or_init_approval_book(account, ctx);
    table::add(&mut book.approvals, intent_key, approval);
}


/// Check if a council approval exists for an intent
public fun has_council_approval(
    account: &Account<FutarchyConfig>,
    intent_key: &String,
    clock: &Clock
): bool {
    if (!account::has_managed_data(account, CouncilApprovalKey {})) return false;
    
    let book: &CouncilApprovalBook = account::borrow_managed_data(
        account, CouncilApprovalKey {}, version::current()
    );
    
    if (!table::contains(&book.approvals, *intent_key)) return false;
    
    let approval = table::borrow(&book.approvals, *intent_key);
    let now = clock.timestamp_ms();
    
    // Check expiry
    now < approval.expires_at
}

/// Get the council approval for an intent (if exists)
public fun get_council_approval(
    account: &Account<FutarchyConfig>,
    intent_key: &String
): Option<GenericApproval> {
    // Check if the approval book exists
    if (!account::has_managed_data(account, CouncilApprovalKey {})) {
        return option::none()
    };
    
    let book: &CouncilApprovalBook = account::borrow_managed_data(
        account, CouncilApprovalKey {}, version::current()
    );
    
    if (!table::contains(&book.approvals, *intent_key)) {
        return option::none()
    };
    
    option::some(*table::borrow(&book.approvals, *intent_key))
}

/// Consume a council approval (single-use)
public fun consume_council_approval(
    account: &mut Account<FutarchyConfig>,
    intent_key: &String,
    ctx: &mut TxContext
): Option<GenericApproval> {
    // Ensure the approval book exists
    ensure_approval_book(account, ctx);
    
    let book: &mut CouncilApprovalBook = account::borrow_managed_data_mut(
        account, CouncilApprovalKey {}, version::current()
    );
    
    if (!table::contains(&book.approvals, *intent_key)) {
        return option::none()
    };
    
    option::some(table::remove(&mut book.approvals, *intent_key))
}

// === Permit Functions for Cross-DAO Execution ===

/// Issue an execute permit after checking gates and council approval
public fun issue_execute_permit_for_intent(
    account: &Account<FutarchyConfig>,
    intent_key: &String,
    clock: &Clock,
): ExecutePermit {
    let now = clock.timestamp_ms();
    let expires_at = now + 5 * 60_000; // 5 minute default TTL
    
    // Check for council approval and include it in the permit if present
    let council_approval = get_council_approval(account, intent_key);
    
    // If there's a council approval, use its expiry time if sooner
    let permit_expires = if (option::is_some(&council_approval)) {
        let approval = option::borrow(&council_approval);
        let approval_expires = approval.expires_at;
        if (approval_expires < expires_at) { approval_expires } else { expires_at }
    } else {
        expires_at
    };
    
    ExecutePermit {
        intent_key: *intent_key,
        dao_address: account::addr(account),
        issued_at: now,
        expires_at: permit_expires,
        council_approval,
    }
}

/// Verify a permit is valid
public fun verify_permit(
    permit: &ExecutePermit,
    account: &Account<FutarchyConfig>,
    intent_key: &String,
    clock: &Clock
): bool {
    // Basic checks
    if (permit.dao_address != account::addr(account)) return false;
    if (permit.intent_key != *intent_key) return false;
    if (clock.timestamp_ms() >= permit.expires_at) return false;
    
    // If permit has council approval, verify it matches what's in the book
    if (option::is_some(&permit.council_approval)) {
        let book_approval = get_council_approval(account, intent_key);
        if (option::is_none(&book_approval)) return false;
        
        // The approvals must match exactly
        *option::borrow(&permit.council_approval) == *option::borrow(&book_approval)
    } else {
        true
    }
}

/// Accessor for permit's intent_key
public fun permit_intent_key(permit: &ExecutePermit): String {
    permit.intent_key
}

/// Accessor for permit's dao_address
public fun permit_dao_address(permit: &ExecutePermit): address {
    permit.dao_address
}

/// Accessor for permit's issued_at timestamp
public fun permit_issued_at(permit: &ExecutePermit): u64 {
    permit.issued_at
}

/// Accessor for permit's expires_at timestamp
public fun permit_expires_at(permit: &ExecutePermit): u64 {
    permit.expires_at
}

/// Accessor for permit's council approval
public fun permit_council_approval(permit: &ExecutePermit): &Option<GenericApproval> {
    &permit.council_approval
}

// === Proposal Execution Functions ===
// Note: execute_proposal_intent has been moved to futarchy_governance package
// since it requires access to futarchy_markets types which are not dependencies
// of futarchy_core. The function signature is preserved for compatibility.

// === Config Action Execution Functions ===
// NOTE: These functions have been moved to the action modules themselves
// The action modules now contain the full execution logic using direct config access
// This follows the principle of having actions be self-contained command handlers

// === Note on execute_proposal_intent ===
// The execute_proposal_intent function has been moved to:
//   futarchy_governance::governance_intents::execute_proposal_intent
// 
// This function executes approved proposals by converting stored intents to executables.
// It requires access to both futarchy_markets (Proposal type) and governance logic,
// so it lives in the futarchy_governance package which has both dependencies.
//
// Usage from proposal_lifecycle or other modules:
//   use futarchy_specialized_actions::governance_intents;
//   let executable = governance_intents::execute_proposal_intent(...);
//
// The function signature is:
//   public fun execute_proposal_intent<AssetType, StableType, Outcome: store + drop + copy>(
//       account: &mut Account<FutarchyConfig>,
//       proposal: &Proposal<AssetType, StableType>,
//       market: &MarketState,
//       outcome_index: u64,
//       clock: &Clock,
//       ctx: &mut TxContext
//   ): Executable<Outcome>
