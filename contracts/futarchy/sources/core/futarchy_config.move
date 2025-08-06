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

/// Core Futarchy DAO configuration
/// Contains all the configuration fields from the original DAO state
/// but excludes id, metadata, and deps which are handled by Account wrapper
public struct FutarchyConfig has store {
    // Type information
    asset_type: String,
    stable_type: String,
    
    // Trading parameters
    min_asset_amount: u64,
    min_stable_amount: u64,
    review_period_ms: u64,
    trading_period_ms: u64,
    
    // AMM configuration
    amm_twap_start_delay: u64,
    amm_twap_step_max: u64,
    amm_twap_initial_observation: u128,
    twap_threshold: u64,
    amm_total_fee_bps: u64,
    
    // Metadata
    dao_name: AsciiString,
    icon_url: Url,
    description: String,
    
    // Governance parameters
    max_outcomes: u64,
    proposal_fee_per_outcome: u64,
    operational_state: u8,
    max_concurrent_proposals: u64,
    required_bond_amount: u64,
    
    // State tracking
    active_proposals: u64,
    total_proposals: u64,
    
    // References to other objects
    liquidity_pool_id: Option<ID>,
    treasury_id: Option<ID>,
    operating_agreement_id: Option<ID>,
    
    // Queue management (deprecated - using priority_queue module now)
    queue_size: u64,
    queue_head: Option<ID>,
    queue_tail: Option<ID>,
    fee_escalation_basis_points: u64,
    
    // Proposal queue ID
    proposal_queue_id: Option<ID>,
    
    // Action registry ID for unified action system
    action_registry_id: Option<ID>,
    
    // Verification
    attestation_url: String,
    verification_pending: bool,
    verified: bool,
}

/// Helper struct for creating FutarchyConfig with default values
public struct ConfigParams has store, copy, drop {
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
    fee_escalation_basis_points: u64,
}

/// Witness struct for authentication and operations
public struct Witness has drop {}

// === Public Functions ===

/// Creates a new FutarchyConfig with specified parameters
public fun new<AssetType: drop, StableType>(
    params: ConfigParams,
    dao_name: AsciiString,
    icon_url: Url,
    description: String,
    ctx: &mut TxContext,
): FutarchyConfig {
    FutarchyConfig {
        asset_type: type_name::get<AssetType>().into_string().to_string(),
        stable_type: type_name::get<StableType>().into_string().to_string(),
        min_asset_amount: params.min_asset_amount,
        min_stable_amount: params.min_stable_amount,
        review_period_ms: params.review_period_ms,
        trading_period_ms: params.trading_period_ms,
        amm_twap_start_delay: params.amm_twap_start_delay,
        amm_twap_step_max: params.amm_twap_step_max,
        amm_twap_initial_observation: params.amm_twap_initial_observation,
        twap_threshold: params.twap_threshold,
        amm_total_fee_bps: params.amm_total_fee_bps,
        dao_name,
        icon_url,
        description,
        max_outcomes: params.max_outcomes,
        proposal_fee_per_outcome: params.proposal_fee_per_outcome,
        operational_state: DAO_STATE_ACTIVE,
        max_concurrent_proposals: params.max_concurrent_proposals,
        required_bond_amount: params.required_bond_amount,
        active_proposals: 0,
        total_proposals: 0,
        liquidity_pool_id: option::none(),
        treasury_id: option::none(),
        operating_agreement_id: option::none(),
        queue_size: 0,
        queue_head: option::none(),
        queue_tail: option::none(),
        fee_escalation_basis_points: params.fee_escalation_basis_points,
        proposal_queue_id: option::none(),
        action_registry_id: option::none(),
        attestation_url: b"".to_string(),
        verification_pending: false,
        verified: false,
    }
}

/// Creates default configuration parameters
public fun new_config_params(
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
    fee_escalation_basis_points: u64,
): ConfigParams {
    ConfigParams {
        min_asset_amount,
        min_stable_amount,
        review_period_ms,
        trading_period_ms,
        amm_twap_start_delay,
        amm_twap_step_max,
        amm_twap_initial_observation,
        twap_threshold,
        amm_total_fee_bps,
        max_outcomes,
        proposal_fee_per_outcome,
        max_concurrent_proposals,
        required_bond_amount,
        fee_escalation_basis_points,
    }
}

/// Creates default configuration parameters with sensible defaults
public fun default_config_params(): ConfigParams {
    ConfigParams {
        min_asset_amount: 100_000_000_000, // 100 tokens
        min_stable_amount: 100_000_000_000, // 100 stable
        review_period_ms: 604_800_000, // 7 days
        trading_period_ms: 604_800_000, // 7 days
        amm_twap_start_delay: 60_000, // 1 minute
        amm_twap_step_max: 10,
        amm_twap_initial_observation: 1_000_000_000_000, // 1x price
        twap_threshold: 100_000, // 1x
        amm_total_fee_bps: 30, // 0.3%
        max_outcomes: 10,
        proposal_fee_per_outcome: 1_000_000, // 1 token per outcome
        max_concurrent_proposals: 50,
        required_bond_amount: 100_000_000, // 100 USDC default
        fee_escalation_basis_points: 100, // 1% default
    }
}

// === Accessor Functions ===

// Type information
public fun asset_type(config: &FutarchyConfig): &String { &config.asset_type }
public fun stable_type(config: &FutarchyConfig): &String { &config.stable_type }

// Trading parameters
public fun min_asset_amount(config: &FutarchyConfig): u64 { config.min_asset_amount }
public fun min_stable_amount(config: &FutarchyConfig): u64 { config.min_stable_amount }
public fun review_period_ms(config: &FutarchyConfig): u64 { config.review_period_ms }
public fun trading_period_ms(config: &FutarchyConfig): u64 { config.trading_period_ms }

// AMM configuration
public fun amm_twap_start_delay(config: &FutarchyConfig): u64 { config.amm_twap_start_delay }
public fun amm_twap_step_max(config: &FutarchyConfig): u64 { config.amm_twap_step_max }
public fun amm_twap_initial_observation(config: &FutarchyConfig): u128 { config.amm_twap_initial_observation }
public fun twap_threshold(config: &FutarchyConfig): u64 { config.twap_threshold }
public fun amm_total_fee_bps(config: &FutarchyConfig): u64 { config.amm_total_fee_bps }

// Metadata
public fun dao_name(config: &FutarchyConfig): &AsciiString { &config.dao_name }
public fun icon_url(config: &FutarchyConfig): &Url { &config.icon_url }
public fun description(config: &FutarchyConfig): &String { &config.description }

// Governance parameters
public fun max_outcomes(config: &FutarchyConfig): u64 { config.max_outcomes }
public fun proposal_fee_per_outcome(config: &FutarchyConfig): u64 { config.proposal_fee_per_outcome }
public fun operational_state(config: &FutarchyConfig): u8 { config.operational_state }
public fun max_concurrent_proposals(config: &FutarchyConfig): u64 { config.max_concurrent_proposals }
public fun required_bond_amount(config: &FutarchyConfig): u64 { config.required_bond_amount }

// State tracking
public fun active_proposals(config: &FutarchyConfig): u64 { config.active_proposals }
public fun total_proposals(config: &FutarchyConfig): u64 { config.total_proposals }

// References
public fun liquidity_pool_id(config: &FutarchyConfig): &Option<ID> { &config.liquidity_pool_id }
public fun treasury_id(config: &FutarchyConfig): &Option<ID> { &config.treasury_id }
public fun operating_agreement_id(config: &FutarchyConfig): &Option<ID> { &config.operating_agreement_id }

// Queue management
public fun queue_size(config: &FutarchyConfig): u64 { config.queue_size }
public fun queue_head(config: &FutarchyConfig): &Option<ID> { &config.queue_head }
public fun queue_tail(config: &FutarchyConfig): &Option<ID> { &config.queue_tail }
public fun fee_escalation_basis_points(config: &FutarchyConfig): u64 { config.fee_escalation_basis_points }
public fun proposal_queue_id(config: &FutarchyConfig): &Option<ID> { &config.proposal_queue_id }
public fun action_registry_id(config: &FutarchyConfig): &Option<ID> { &config.action_registry_id }

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
    config.min_asset_amount = amount;
}

public(package) fun set_min_stable_amount(config: &mut FutarchyConfig, amount: u64) {
    config.min_stable_amount = amount;
}

public(package) fun set_review_period_ms(config: &mut FutarchyConfig, period: u64) {
    config.review_period_ms = period;
}

public(package) fun set_trading_period_ms(config: &mut FutarchyConfig, period: u64) {
    config.trading_period_ms = period;
}

// AMM configuration
public(package) fun set_amm_twap_start_delay(config: &mut FutarchyConfig, delay: u64) {
    config.amm_twap_start_delay = delay;
}

public(package) fun set_amm_twap_step_max(config: &mut FutarchyConfig, max: u64) {
    config.amm_twap_step_max = max;
}

public(package) fun set_amm_twap_initial_observation(config: &mut FutarchyConfig, obs: u128) {
    config.amm_twap_initial_observation = obs;
}

public(package) fun set_twap_threshold(config: &mut FutarchyConfig, threshold: u64) {
    config.twap_threshold = threshold;
}

public(package) fun set_amm_total_fee_bps(config: &mut FutarchyConfig, fee_bps: u64) {
    config.amm_total_fee_bps = fee_bps;
}

// Metadata
public(package) fun set_dao_name(config: &mut FutarchyConfig, name: AsciiString) {
    config.dao_name = name;
}

public(package) fun set_icon_url(config: &mut FutarchyConfig, url: Url) {
    config.icon_url = url;
}

public(package) fun set_description(config: &mut FutarchyConfig, desc: String) {
    config.description = desc;
}

// Governance parameters
public(package) fun set_max_outcomes(config: &mut FutarchyConfig, max: u64) {
    config.max_outcomes = max;
}

public(package) fun set_proposal_fee_per_outcome(config: &mut FutarchyConfig, fee: u64) {
    config.proposal_fee_per_outcome = fee;
}

public(package) fun set_operational_state(config: &mut FutarchyConfig, new_state: u8) {
    config.operational_state = new_state;
}

public(package) fun set_max_concurrent_proposals(config: &mut FutarchyConfig, max: u64) {
    config.max_concurrent_proposals = max;
}

public(package) fun set_required_bond_amount(config: &mut FutarchyConfig, amount: u64) {
    config.required_bond_amount = amount;
}

// State tracking
public(package) fun increment_active_proposals(config: &mut FutarchyConfig) {
    increment_active_proposals(config);
}

public(package) fun decrement_active_proposals(config: &mut FutarchyConfig) {
    config.active_proposals = config.active_proposals - 1;
}

public(package) fun increment_total_proposals(config: &mut FutarchyConfig) {
    config.total_proposals = config.total_proposals + 1;
}

// References
public(package) fun set_liquidity_pool_id(config: &mut FutarchyConfig, id: Option<ID>) {
    config.liquidity_pool_id = id;
}

public(package) fun set_treasury_id(config: &mut FutarchyConfig, id: Option<ID>) {
    config.treasury_id = id;
}

public(package) fun set_operating_agreement_id(config: &mut FutarchyConfig, id: Option<ID>) {
    config.operating_agreement_id = id;
}

// Queue management
public(package) fun set_queue_head(config: &mut FutarchyConfig, head: Option<ID>) {
    config.queue_head = head;
}

public(package) fun set_queue_tail(config: &mut FutarchyConfig, tail: Option<ID>) {
    config.queue_tail = tail;
}

public(package) fun increment_queue_size(config: &mut FutarchyConfig) {
    config.queue_size = config.queue_size + 1;
}

public(package) fun decrement_queue_size(config: &mut FutarchyConfig) {
    config.queue_size = config.queue_size - 1;
}

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
    config.dao_name = name;
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
    config.min_asset_amount = params.min_asset_amount;
    config.min_stable_amount = params.min_stable_amount;
    config.review_period_ms = params.review_period_ms;
    config.trading_period_ms = params.trading_period_ms;
    config.amm_twap_start_delay = params.amm_twap_start_delay;
    config.amm_twap_step_max = params.amm_twap_step_max;
    config.amm_twap_initial_observation = params.amm_twap_initial_observation;
    config.twap_threshold = params.twap_threshold;
    config.amm_total_fee_bps = params.amm_total_fee_bps;
    config.max_outcomes = params.max_outcomes;
    config.proposal_fee_per_outcome = params.proposal_fee_per_outcome;
    config.max_concurrent_proposals = params.max_concurrent_proposals;
    config.required_bond_amount = params.required_bond_amount;
    config.fee_escalation_basis_points = params.fee_escalation_basis_points;
}

public(package) fun set_proposals_enabled_internal(config: &mut FutarchyConfig, enabled: bool) {
    if (enabled) {
        config.operational_state = DAO_STATE_ACTIVE;
    } else {
        config.operational_state = DAO_STATE_PAUSED;
    }
}

public(package) fun set_fee_manager_id(config: &mut FutarchyConfig, id: ID) {
    // This would typically be stored in a separate field if needed
    // For now, we can use action_registry_id as a placeholder
    config.action_registry_id = option::some(id);
}

public(package) fun set_spot_pool_id(config: &mut FutarchyConfig, id: ID) {
    config.liquidity_pool_id = option::some(id);
}

// Removed authorized_members_mut - auth is managed by account protocol

// === Account Creation ===

/// Create a new Account with FutarchyConfig
/// NOTE: This function requires Extensions to be passed in production
/// For now, it aborts to indicate Extensions are required
public fun new_account(
    config: FutarchyConfig,
    _ctx: &mut TxContext,
): Account<FutarchyConfig> {
    // This function exists for backward compatibility
    // In production, Extensions must be obtained from the shared object
    // and passed to new_account_with_extensions
    abort 0 // Extensions required - use new_account_with_extensions
}

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
                b"FutarchyActions".to_string(),
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
    config.liquidity_pool_id = option::some(pool_id);
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
// These functions implement the actual state modifications for config actions
// They use FutarchyConfigWitness to access config_mut

/// Execute a SetProposalsEnabledAction 
public fun execute_set_proposals_enabled<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    version: VersionWitness,
    intent_witness: IW,
    ctx: &mut TxContext,
) {
    use futarchy_actions::config_actions;
    use sui::event;
    use sui::clock;
    
    // Extract the action from the executable
    let action: &config_actions::SetProposalsEnabledAction = executable.next_action(intent_witness);
    let enabled = config_actions::get_proposals_enabled(action);
    
    // Get mutable config using our witness
    let config = account.config_mut(version, FutarchyConfigWitness {});
    
    // Apply the state change
    set_proposals_enabled_internal(config, enabled);
    
    // Emit event for audit trail
    event::emit(ProposalsEnabledChanged {
        account_id: object::id(account),
        enabled,
        timestamp: ctx.epoch_timestamp_ms(),
    });
}

/// Execute an UpdateNameAction
public fun execute_update_name<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    version: VersionWitness,
    intent_witness: IW,
    _ctx: &mut TxContext,
) {
    use futarchy_actions::config_actions;
    
    // Extract the action from the executable
    let action: &config_actions::UpdateNameAction = executable.next_action(intent_witness);
    let new_name = config_actions::get_new_name(action);
    
    // Get mutable config using our witness
    let config = account.config_mut(version, FutarchyConfigWitness {});
    
    // Convert String to AsciiString if needed
    // For now, assuming the name is ASCII-compatible
    let ascii_name = new_name.to_ascii();
    
    // Apply the state change
    set_dao_name(config, ascii_name);
    
    // Event emission could go here
}

/// Execute a TradingParamsUpdateAction
public fun execute_update_trading_params<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    version: VersionWitness,
    intent_witness: IW,
    _ctx: &mut TxContext,
) {
    use futarchy_actions::advanced_config_actions;
    
    // Extract the action from the executable
    let action: &advanced_config_actions::TradingParamsUpdateAction = executable.next_action(intent_witness);
    
    // Get the fields from the action
    let (min_asset_opt, min_stable_opt, review_period_opt, trading_period_opt, fee_bps_opt) = 
        advanced_config_actions::get_trading_params_fields(action);
    
    // Get mutable config using our witness
    let config = account.config_mut(version, FutarchyConfigWitness {});
    
    // Apply each update if provided
    if (min_asset_opt.is_some()) {
        set_min_asset_amount(config, *min_asset_opt.borrow());
    };
    if (min_stable_opt.is_some()) {
        set_min_stable_amount(config, *min_stable_opt.borrow());
    };
    if (review_period_opt.is_some()) {
        set_review_period_ms(config, *review_period_opt.borrow());
    };
    if (trading_period_opt.is_some()) {
        set_trading_period_ms(config, *trading_period_opt.borrow());
    };
    if (fee_bps_opt.is_some()) {
        set_amm_total_fee_bps(config, *fee_bps_opt.borrow());
    };
}

/// Execute a MetadataUpdateAction
public fun execute_update_metadata<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    version: VersionWitness,
    intent_witness: IW,
    _ctx: &mut TxContext,
) {
    use futarchy_actions::advanced_config_actions;
    
    // Extract the action from the executable
    let action: &advanced_config_actions::MetadataUpdateAction = executable.next_action(intent_witness);
    
    // Get the fields from the action
    let (name_opt, icon_url_opt, description_opt) = 
        advanced_config_actions::get_metadata_fields(action);
    
    // Get mutable config using our witness
    let config = account.config_mut(version, FutarchyConfigWitness {});
    
    // Apply each update if provided
    if (name_opt.is_some()) {
        set_dao_name(config, *name_opt.borrow());
    };
    if (icon_url_opt.is_some()) {
        set_icon_url(config, *icon_url_opt.borrow());
    };
    if (description_opt.is_some()) {
        set_description(config, *description_opt.borrow());
    };
}

/// Execute a GovernanceUpdateAction
public fun execute_update_governance<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    version: VersionWitness,
    intent_witness: IW,
    _ctx: &mut TxContext,
) {
    use futarchy_actions::advanced_config_actions;
    
    // Extract the action from the executable
    let action: &advanced_config_actions::GovernanceUpdateAction = executable.next_action(intent_witness);
    
    // Get the fields from the action
    let (proposals_enabled_opt, max_outcomes_opt, bond_amount_opt) = 
        advanced_config_actions::get_governance_fields(action);
    
    // Get mutable config using our witness
    let config = account.config_mut(version, FutarchyConfigWitness {});
    
    // Apply each update if provided
    if (proposals_enabled_opt.is_some()) {
        set_proposals_enabled_internal(config, *proposals_enabled_opt.borrow());
    };
    if (max_outcomes_opt.is_some()) {
        set_max_outcomes(config, *max_outcomes_opt.borrow());
    };
    if (bond_amount_opt.is_some()) {
        set_required_bond_amount(config, *bond_amount_opt.borrow());
    };
}

