/// Configuration struct for Futarchy governance systems
/// Replaces the old DAO god object pattern with a focused configuration struct
/// for use with Account<FutarchyConfig>
module futarchy::futarchy_config;

// === Imports ===
use std::{
    string::String,
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
    intents::{Self, Intents},
    version_witness::VersionWitness,
};
use account_extensions::extensions::Extensions;
use futarchy::{
    version,
    proposal::{Self, Proposal},
    market_state::{Self, MarketState},
    dao_config::{Self, DaoConfig, TradingParams, TwapConfig, GovernanceConfig, MetadataConfig},
};

// === Constants ===
const DAO_STATE_ACTIVE: u8 = 0;
const DAO_STATE_DISSOLVING: u8 = 1;
const DAO_STATE_PAUSED: u8 = 2;

const OUTCOME_YES: u8 = 0;
const OUTCOME_NO: u8 = 1;

// === Errors ===
const EProposalNotApproved: u64 = 1;
const EInvalidAdmin: u64 = 2;
const EInvalidSlashDistribution: u64 = 3;

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
    
    // Action registry ID for unified action system
    action_registry_id: Option<ID>,
    
    // Fee manager ID for proposal fee management
    fee_manager_id: Option<ID>,
    
    // Spot AMM pool ID for the DAO's liquidity pool
    spot_pool_id: Option<ID>,
    
    // Verification
    attestation_url: String,
    verification_pending: bool,
    verified: bool,
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
        action_registry_id: option::none(),
        fee_manager_id: option::none(),
        spot_pool_id: option::none(),
        attestation_url: b"".to_string(),
        verification_pending: false,
        verified: false,
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

/// Creates configuration parameters from individual values (legacy support)
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
        proposal_fee_per_outcome,
        required_bond_amount,
        max_concurrent_proposals,
        proposal_recreation_window_ms,
        max_proposal_chain_depth,
        fee_escalation_basis_points,
        true,  // proposal_creation_enabled (default)
        true,  // accept_new_proposals (default)
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
            )
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
public fun proposal_fee_per_outcome(config: &FutarchyConfig): u64 { dao_config::proposal_fee_per_outcome(dao_config::governance_config(&config.config)) }
public fun operational_state(config: &FutarchyConfig): u8 { config.operational_state }
public fun max_concurrent_proposals(config: &FutarchyConfig): u64 { dao_config::max_concurrent_proposals(dao_config::governance_config(&config.config)) }
public fun required_bond_amount(config: &FutarchyConfig): u64 { dao_config::required_bond_amount(dao_config::governance_config(&config.config)) }

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
public fun action_registry_id(config: &FutarchyConfig): &Option<ID> { &config.action_registry_id }
public fun fee_manager_id(config: &FutarchyConfig): &Option<ID> { &config.fee_manager_id }

// Verification
public fun attestation_url(config: &FutarchyConfig): &String { &config.attestation_url }
public fun verification_pending(config: &FutarchyConfig): bool { config.verification_pending }
public fun verified(config: &FutarchyConfig): bool { config.verified }

// State constants
public fun state_active(): u8 { DAO_STATE_ACTIVE }
public fun state_dissolving(): u8 { DAO_STATE_DISSOLVING }
public fun state_paused(): u8 { DAO_STATE_PAUSED }

// === Package-Level Mutators ===

// Trading parameters
public(package) fun set_min_asset_amount(config: &mut FutarchyConfig, amount: u64) {
    let current_trading = dao_config::trading_params(&config.config);
    let new_trading = dao_config::new_trading_params(
        amount,
        dao_config::min_stable_amount(current_trading),
        dao_config::review_period_ms(current_trading),
        dao_config::trading_period_ms(current_trading),
        dao_config::amm_total_fee_bps(current_trading),
    );
    config.config = dao_config::update_trading_params(&config.config, new_trading);
}

public(package) fun set_min_stable_amount(config: &mut FutarchyConfig, amount: u64) {
    let current_trading = dao_config::trading_params(&config.config);
    let new_trading = dao_config::new_trading_params(
        dao_config::min_asset_amount(current_trading),
        amount,
        dao_config::review_period_ms(current_trading),
        dao_config::trading_period_ms(current_trading),
        dao_config::amm_total_fee_bps(current_trading),
    );
    config.config = dao_config::update_trading_params(&config.config, new_trading);
}

public(package) fun set_review_period_ms(config: &mut FutarchyConfig, period: u64) {
    let current_trading = dao_config::trading_params(&config.config);
    let new_trading = dao_config::new_trading_params(
        dao_config::min_asset_amount(current_trading),
        dao_config::min_stable_amount(current_trading),
        period,
        dao_config::trading_period_ms(current_trading),
        dao_config::amm_total_fee_bps(current_trading),
    );
    config.config = dao_config::update_trading_params(&config.config, new_trading);
}

public(package) fun set_trading_period_ms(config: &mut FutarchyConfig, period: u64) {
    let current_trading = dao_config::trading_params(&config.config);
    let new_trading = dao_config::new_trading_params(
        dao_config::min_asset_amount(current_trading),
        dao_config::min_stable_amount(current_trading),
        dao_config::review_period_ms(current_trading),
        period,
        dao_config::amm_total_fee_bps(current_trading),
    );
    config.config = dao_config::update_trading_params(&config.config, new_trading);
}

public(package) fun set_proposal_recreation_window_ms(config: &mut FutarchyConfig, window: u64) {
    let current_gov = dao_config::governance_config(&config.config);
    let new_gov = dao_config::new_governance_config(
        dao_config::max_outcomes(current_gov),
        dao_config::proposal_fee_per_outcome(current_gov),
        dao_config::required_bond_amount(current_gov),
        dao_config::max_concurrent_proposals(current_gov),
        window,
        dao_config::max_proposal_chain_depth(current_gov),
        dao_config::fee_escalation_basis_points(current_gov),
        dao_config::proposal_creation_enabled(current_gov),
        dao_config::accept_new_proposals(current_gov),
    );
    config.config = dao_config::update_governance_config(&config.config, new_gov);
}

public(package) fun set_max_proposal_chain_depth(config: &mut FutarchyConfig, depth: u64) {
    let current_gov = dao_config::governance_config(&config.config);
    let new_gov = dao_config::new_governance_config(
        dao_config::max_outcomes(current_gov),
        dao_config::proposal_fee_per_outcome(current_gov),
        dao_config::required_bond_amount(current_gov),
        dao_config::max_concurrent_proposals(current_gov),
        dao_config::proposal_recreation_window_ms(current_gov),
        depth,
        dao_config::fee_escalation_basis_points(current_gov),
        dao_config::proposal_creation_enabled(current_gov),
        dao_config::accept_new_proposals(current_gov),
    );
    config.config = dao_config::update_governance_config(&config.config, new_gov);
}

// AMM configuration
public(package) fun set_amm_twap_start_delay(config: &mut FutarchyConfig, delay: u64) {
    let current_twap = dao_config::twap_config(&config.config);
    let new_twap = dao_config::new_twap_config(
        delay,
        dao_config::step_max(current_twap),
        dao_config::initial_observation(current_twap),
        dao_config::threshold(current_twap),
    );
    config.config = dao_config::update_twap_config(&config.config, new_twap);
}

public(package) fun set_amm_twap_step_max(config: &mut FutarchyConfig, max: u64) {
    let current_twap = dao_config::twap_config(&config.config);
    let new_twap = dao_config::new_twap_config(
        dao_config::start_delay(current_twap),
        max,
        dao_config::initial_observation(current_twap),
        dao_config::threshold(current_twap),
    );
    config.config = dao_config::update_twap_config(&config.config, new_twap);
}

public(package) fun set_amm_twap_initial_observation(config: &mut FutarchyConfig, obs: u128) {
    let current_twap = dao_config::twap_config(&config.config);
    let new_twap = dao_config::new_twap_config(
        dao_config::start_delay(current_twap),
        dao_config::step_max(current_twap),
        obs,
        dao_config::threshold(current_twap),
    );
    config.config = dao_config::update_twap_config(&config.config, new_twap);
}

public(package) fun set_twap_threshold(config: &mut FutarchyConfig, threshold: u64) {
    let current_twap = dao_config::twap_config(&config.config);
    let new_twap = dao_config::new_twap_config(
        dao_config::start_delay(current_twap),
        dao_config::step_max(current_twap),
        dao_config::initial_observation(current_twap),
        threshold,
    );
    config.config = dao_config::update_twap_config(&config.config, new_twap);
}

public(package) fun set_amm_total_fee_bps(config: &mut FutarchyConfig, fee_bps: u64) {
    let current_trading = dao_config::trading_params(&config.config);
    let new_trading = dao_config::new_trading_params(
        dao_config::min_asset_amount(current_trading),
        dao_config::min_stable_amount(current_trading),
        dao_config::review_period_ms(current_trading),
        dao_config::trading_period_ms(current_trading),
        fee_bps,
    );
    config.config = dao_config::update_trading_params(&config.config, new_trading);
}

// Metadata
public(package) fun set_dao_name(config: &mut FutarchyConfig, name: AsciiString) {
    let current_meta = dao_config::metadata_config(&config.config);
    let new_meta = dao_config::new_metadata_config(
        name,
        *dao_config::icon_url(current_meta),
        *dao_config::description(current_meta),
    );
    config.config = dao_config::update_metadata_config(&config.config, new_meta);
}

public(package) fun set_icon_url(config: &mut FutarchyConfig, url: Url) {
    let current_meta = dao_config::metadata_config(&config.config);
    let new_meta = dao_config::new_metadata_config(
        *dao_config::dao_name(current_meta),
        url,
        *dao_config::description(current_meta),
    );
    config.config = dao_config::update_metadata_config(&config.config, new_meta);
}

public(package) fun set_description(config: &mut FutarchyConfig, desc: String) {
    let current_meta = dao_config::metadata_config(&config.config);
    let new_meta = dao_config::new_metadata_config(
        *dao_config::dao_name(current_meta),
        *dao_config::icon_url(current_meta),
        desc,
    );
    config.config = dao_config::update_metadata_config(&config.config, new_meta);
}

// Governance parameters
public(package) fun set_max_outcomes(config: &mut FutarchyConfig, max: u64) {
    let current_gov = dao_config::governance_config(&config.config);
    let new_gov = dao_config::new_governance_config(
        max,
        dao_config::proposal_fee_per_outcome(current_gov),
        dao_config::required_bond_amount(current_gov),
        dao_config::max_concurrent_proposals(current_gov),
        dao_config::proposal_recreation_window_ms(current_gov),
        dao_config::max_proposal_chain_depth(current_gov),
        dao_config::fee_escalation_basis_points(current_gov),
        dao_config::proposal_creation_enabled(current_gov),
        dao_config::accept_new_proposals(current_gov),
    );
    config.config = dao_config::update_governance_config(&config.config, new_gov);
}

public(package) fun set_proposal_fee_per_outcome(config: &mut FutarchyConfig, fee: u64) {
    let current_gov = dao_config::governance_config(&config.config);
    let new_gov = dao_config::new_governance_config(
        dao_config::max_outcomes(current_gov),
        fee,
        dao_config::required_bond_amount(current_gov),
        dao_config::max_concurrent_proposals(current_gov),
        dao_config::proposal_recreation_window_ms(current_gov),
        dao_config::max_proposal_chain_depth(current_gov),
        dao_config::fee_escalation_basis_points(current_gov),
        dao_config::proposal_creation_enabled(current_gov),
        dao_config::accept_new_proposals(current_gov),
    );
    config.config = dao_config::update_governance_config(&config.config, new_gov);
}

public(package) fun set_operational_state(config: &mut FutarchyConfig, new_state: u8) {
    config.operational_state = new_state;
}

public(package) fun set_max_concurrent_proposals(config: &mut FutarchyConfig, max: u64) {
    let current_gov = dao_config::governance_config(&config.config);
    let new_gov = dao_config::new_governance_config(
        dao_config::max_outcomes(current_gov),
        dao_config::proposal_fee_per_outcome(current_gov),
        dao_config::required_bond_amount(current_gov),
        max,
        dao_config::proposal_recreation_window_ms(current_gov),
        dao_config::max_proposal_chain_depth(current_gov),
        dao_config::fee_escalation_basis_points(current_gov),
        dao_config::proposal_creation_enabled(current_gov),
        dao_config::accept_new_proposals(current_gov),
    );
    config.config = dao_config::update_governance_config(&config.config, new_gov);
}

public(package) fun set_required_bond_amount(config: &mut FutarchyConfig, amount: u64) {
    let current_gov = dao_config::governance_config(&config.config);
    let new_gov = dao_config::new_governance_config(
        dao_config::max_outcomes(current_gov),
        dao_config::proposal_fee_per_outcome(current_gov),
        amount,
        dao_config::max_concurrent_proposals(current_gov),
        dao_config::proposal_recreation_window_ms(current_gov),
        dao_config::max_proposal_chain_depth(current_gov),
        dao_config::fee_escalation_basis_points(current_gov),
        dao_config::proposal_creation_enabled(current_gov),
        dao_config::accept_new_proposals(current_gov),
    );
    config.config = dao_config::update_governance_config(&config.config, new_gov);
}

// State tracking
public(package) fun increment_active_proposals(config: &mut FutarchyConfig) {
    config.active_proposals = config.active_proposals + 1;
}

public(package) fun decrement_active_proposals(config: &mut FutarchyConfig) {
    config.active_proposals = config.active_proposals - 1;
}

public(package) fun increment_total_proposals(config: &mut FutarchyConfig) {
    config.total_proposals = config.total_proposals + 1;
}

// References
public(package) fun set_treasury_id(config: &mut FutarchyConfig, id: Option<ID>) {
    config.treasury_id = id;
}

public(package) fun set_operating_agreement_id(config: &mut FutarchyConfig, id: Option<ID>) {
    config.operating_agreement_id = id;
}

// Queue management (deprecated - removed, using priority_queue module now)

public(package) fun set_proposal_queue_id(config: &mut FutarchyConfig, id: Option<ID>) {
    config.proposal_queue_id = id;
}

public(package) fun set_action_registry_id(config: &mut FutarchyConfig, id: Option<ID>) {
    config.action_registry_id = id;
}

// Verification
public(package) fun set_attestation_url(config: &mut FutarchyConfig, url: String) {
    config.attestation_url = url;
}

public(package) fun set_verification_pending(config: &mut FutarchyConfig, pending: bool) {
    config.verification_pending = pending;
}

public(package) fun set_verified(config: &mut FutarchyConfig, verified: bool) {
    config.verified = verified;
}

// Metadata setters
public(package) fun set_name(config: &mut FutarchyConfig, name: AsciiString) {
    let current_meta = dao_config::metadata_config(&config.config);
    let new_meta = dao_config::new_metadata_config(
        name,
        *dao_config::icon_url(current_meta),
        *dao_config::description(current_meta),
    );
    config.config = dao_config::update_metadata_config(&config.config, new_meta);
}

public(package) fun set_admin(_config: &mut FutarchyConfig, admin: address) {
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

public(package) fun set_config_params(config: &mut FutarchyConfig, params: ConfigParams) {
    config.config = params.dao_config;
    config.slash_distribution = params.slash_distribution;
}

public(package) fun set_proposals_enabled_internal(config: &mut FutarchyConfig, enabled: bool) {
    if (enabled) {
        config.operational_state = DAO_STATE_ACTIVE;
    } else {
        config.operational_state = DAO_STATE_PAUSED;
    }
}

public(package) fun set_fee_manager_id(config: &mut FutarchyConfig, id: ID) {
    config.fee_manager_id = option::some(id);
}

public(package) fun set_fee_escalation_basis_points(config: &mut FutarchyConfig, points: u64) {
    let current_gov = dao_config::governance_config(&config.config);
    let new_gov = dao_config::new_governance_config(
        dao_config::max_outcomes(current_gov),
        dao_config::proposal_fee_per_outcome(current_gov),
        dao_config::required_bond_amount(current_gov),
        dao_config::max_concurrent_proposals(current_gov),
        dao_config::proposal_recreation_window_ms(current_gov),
        dao_config::max_proposal_chain_depth(current_gov),
        points,
        dao_config::proposal_creation_enabled(current_gov),
        dao_config::accept_new_proposals(current_gov),
    );
    config.config = dao_config::update_governance_config(&config.config, new_gov);
}

public(package) fun set_spot_pool_id(config: &mut FutarchyConfig, id: ID) {
    config.spot_pool_id = option::some(id);
}

/// Update the slash distribution configuration
public(package) fun update_slash_distribution(
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
    
    // Create the account using the macro
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
            ]
        )
    )
}

/// Create a new Account that allows unverified packages (for production use)
/// IMPORTANT: @futarchy must be the real deployed address, not 0x0
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
                @futarchy, // MUST be the real deployed address, not 0x0
            ],
            vector[1, version::get()] // versions
        )
    )
}

#[test_only]
/// Create a test account without Extensions
/// IMPORTANT: Uses @account_protocol witness because @futarchy (0x0) is not deployed
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
    // 2. @futarchy is 0x0 (not deployed) so can't be in deps
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
public(package) fun internal_config_mut(
    account: &mut Account<FutarchyConfig>
): &mut FutarchyConfig {
    account::config_mut(account, version::current(), GovernanceWitness {})
}

#[test_only]
/// Get mutable access to config for tests (package-level only)
public(package) fun internal_config_mut_test(
    account: &mut Account<FutarchyConfig>
): &mut FutarchyConfig {
    use account_protocol::version_witness;
    account::config_mut(account, version_witness::new_for_testing(@account_protocol), GovernanceWitness {})
}

/// Set DAO pool ID (package-level only)  
public(package) fun set_dao_pool_id(
    config: &mut FutarchyConfig,
    pool_id: ID,
) {
    config.spot_pool_id = option::some(pool_id);
}


// === Governance Core Functions ===

/// Authenticate and get an Auth token
/// For now, this is permissionless - anyone can get one
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

/// Legacy outcome type - kept for backwards compatibility
/// New intents should use ApprovedProposal or their own outcome types
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
/// This allows standard intents to work with any outcome type
public fun execute_proposal_intent_v2<AssetType, StableType, Outcome: store + drop + copy>(
    account: &mut Account<FutarchyConfig>,
    proposal: &Proposal<AssetType, StableType>,
    market: &MarketState,
    outcome_index: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Executable<Outcome> {
    // Verify the outcome won
    assert!(market_state::is_finalized(market), EProposalNotApproved);
    let winning_outcome = market_state::get_winning_outcome(market);
    assert!((winning_outcome as u64) == outcome_index, EProposalNotApproved);
    
    // Get the intent key for the winning outcome
    let intent_key_opt = proposal::get_intent_key_for_outcome(proposal, outcome_index);
    assert!(intent_key_opt.is_some(), EProposalNotApproved);
    let intent_key = *intent_key_opt.borrow();
    
    // Execute the intent - the caller provides the outcome type
    let (_outcome, executable) = account::create_executable<FutarchyConfig, Outcome, FutarchyConfigWitness>(
        account,
        intent_key,
        clock,
        version::current(),
        FutarchyConfigWitness {},
    );
    
    executable
}

/// Legacy - Execute a proposal's intent after it has been approved
public fun execute_proposal_intent<AssetType, StableType>(
    account: &mut Account<FutarchyConfig>,
    proposal: &Proposal<AssetType, StableType>,
    market: &MarketState,
    clock: &Clock,
    ctx: &mut TxContext,
): Executable<FutarchyOutcome> {
    // Verify the proposal was approved (YES outcome won)
    // Convert u8 to u64 for comparison
    assert!(market_state::get_winning_outcome(market) == (OUTCOME_YES as u64), EProposalNotApproved);
    
    // Get the intent key for the winning outcome (YES = 0)
    let intent_key_opt = proposal::get_intent_key_for_outcome(proposal, (OUTCOME_YES as u64));
    assert!(intent_key_opt.is_some(), EProposalNotApproved);
    let intent_key = *intent_key_opt.borrow();
    
    // Create the outcome object
    let outcome = FutarchyOutcome {
        intent_key,
        proposal_id: option::some(object::id(proposal)),
        market_id: option::some(object::id(market)),
        approved: true,
        min_execution_time: clock.timestamp_ms(),
    };
    
    // Execute the intent by creating an executable from the stored intent
    // The intent should have been previously stored when the proposal was created
    let (_outcome, executable) = account::create_executable<FutarchyConfig, FutarchyOutcome, FutarchyConfigWitness>(
        account,
        intent_key,
        clock,
        version::current(),
        FutarchyConfigWitness {},
    );
    
    // Return the executable for the caller to process the actions
    executable
}

// === Config Action Execution Functions ===
// NOTE: These functions have been moved to the action modules themselves
// The action modules now contain the full execution logic using direct config access
// This follows the principle of having actions be self-contained command handlers

