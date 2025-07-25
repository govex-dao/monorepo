/// Configuration update proposals for futarchy DAOs
/// Integrates with existing proposal system for governance-based config changes
module futarchy::config_proposals;

// === Imports ===
use std::string::String;
use std::ascii::String as AsciiString;
use sui::{
    coin::Coin,
    clock::Clock,
    sui::SUI,
    url::{Self, Url},
    event,
};
use futarchy::{
    dao::{Self, DAO},
    fee,
    config_actions::{Self, ConfigActionRegistry, ConfigAction},
    proposal,
    coin_escrow::{Self, TokenEscrow},
    market_state,
};

// === Errors ===
const EInvalidMinAmount: u64 = 0;
const EInvalidTwapDelay: u64 = 2;
const ENoChangesSpecified: u64 = 3;
const EInvalidMaxOutcomes: u64 = 4;
const ETradingPeriodTooShort: u64 = 5;
const EReviewPeriodTooShort: u64 = 6;
const EActionMismatch: u64 = 7;

// === Constants ===
const MIN_REVIEW_PERIOD: u64 = 3600000; // 1 hour minimum
const MIN_TRADING_PERIOD: u64 = 86400000; // 24 hours minimum
const MIN_AMM_SAFE_AMOUNT: u64 = 1000;

// === Events ===

public struct ConfigUpdateExecuted has copy, drop {
    dao_id: ID,
    proposal_id: ID,
    update_type: String,
    changes_count: u64,
    timestamp: u64,
}

// === Config Update Actions ===

/// Trading parameters update action
public struct TradingParamsUpdate has store, drop {
    min_asset_amount: Option<u64>,
    min_stable_amount: Option<u64>,
    review_period_ms: Option<u64>,
    trading_period_ms: Option<u64>,
}

/// TWAP configuration update action
public struct TwapConfigUpdate has store, drop {
    start_delay: Option<u64>,
    step_max: Option<u64>,
    initial_observation: Option<u128>,
    threshold: Option<u64>,
}

/// DAO metadata update action
public struct MetadataUpdate has store, drop {
    dao_name: Option<AsciiString>,
    icon_url: Option<Url>,
    description: Option<String>,
}

/// Governance settings update action
public struct GovernanceUpdate has store, drop {
    proposal_creation_enabled: Option<bool>,
    max_outcomes: Option<u64>,
}

// === Unified Multi-Outcome Proposal Creation ===

/// Create a config proposal with arbitrary number of outcomes and associated actions
/// 
/// IMPORTANT CONVENTION: 
/// - Outcome 0 MUST always be the "Reject" option with a no-op action (use config_actions::create_no_op_action())
/// - For binary proposals (2 outcomes): Outcome 1 MUST be "Accept" 
/// - For multi-outcome proposals (3+ outcomes): Outcomes 1+ can be any meaningful options
/// 
/// The system enforces that binary proposals will have outcome_messages set to ["Reject", "Accept"]
/// automatically, but the caller must ensure outcome 0's action is a no-op.
public fun create_config_proposal<AssetType, StableType>(
    dao: &mut DAO<AssetType, StableType>,
    fee_manager: &mut fee::FeeManager,
    config_registry: &mut ConfigActionRegistry,
    payment: Coin<SUI>,
    dao_fee_payment: Coin<StableType>,
    title: String,
    metadata: String,
    mut outcome_descriptions: vector<String>,
    mut outcome_messages: vector<String>,
    initial_outcome_amounts: vector<u64>,
    // A vector of ConfigAction structs, one for each outcome
    mut actions: vector<ConfigAction>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let outcome_count = outcome_descriptions.length();
    
    // Ensure all vectors have matching lengths
    assert!(outcome_messages.length() == outcome_count, EActionMismatch);
    assert!(actions.length() == outcome_count, EActionMismatch);
    assert!(initial_outcome_amounts.length() == outcome_count * 2, EActionMismatch);
    
    // Special handling for binary proposals
    if (outcome_count == 2) {
        // Override messages for binary proposals
        *vector::borrow_mut(&mut outcome_messages, 0) = b"Reject".to_string();
        *vector::borrow_mut(&mut outcome_messages, 1) = b"Accept".to_string();
        
        // Optionally update descriptions if they're generic
        if (*vector::borrow(&outcome_descriptions, 0) == b"".to_string()) {
            *vector::borrow_mut(&mut outcome_descriptions, 0) = b"No change".to_string();
        };
        if (*vector::borrow(&outcome_descriptions, 1) == b"".to_string()) {
            *vector::borrow_mut(&mut outcome_descriptions, 1) = b"Apply changes".to_string();
        };
    };
    
    // Split initial_outcome_amounts into asset and stable vectors
    let mut asset_amounts = vector[];
    let mut stable_amounts = vector[];
    let mut i = 0;
    while (i < outcome_count) {
        vector::push_back(&mut asset_amounts, initial_outcome_amounts[i * 2]);
        vector::push_back(&mut stable_amounts, initial_outcome_amounts[i * 2 + 1]);
        i = i + 1;
    };
    
    // Create the proposal
    let (proposal_id, _market_state_id, _state) = dao::create_proposal_internal<AssetType, StableType>(
        dao,
        fee_manager,
        payment,
        dao_fee_payment,
        title,
        metadata,
        outcome_messages,
        outcome_descriptions,
        asset_amounts,
        stable_amounts,
        false, // uses_dao_liquidity
        clock,
        ctx
    );
    
    // Initialize config storage for this proposal
    config_actions::init_proposal_actions(config_registry, proposal_id, ctx);
    
    // Register each action for its corresponding outcome
    // Reverse the vector to consume from the back in correct order
    vector::reverse(&mut actions);
    let mut i = 0;
    while (i < outcome_count) {
        let action = vector::pop_back(&mut actions);
        config_actions::add_config_action(config_registry, proposal_id, i, action);
        i = i + 1;
    };
}

// === Binary Proposal Helper Functions ===
// These are convenience functions for common binary (reject/accept) proposals

/// Create a binary trading parameters update proposal
public entry fun create_trading_params_proposal<AssetType, StableType>(
    dao: &mut DAO<AssetType, StableType>,
    fee_manager: &mut fee::FeeManager,
    config_registry: &mut ConfigActionRegistry,
    payment: Coin<SUI>,
    dao_fee_payment: Coin<StableType>,
    title: String,
    metadata: String,
    initial_outcome_amounts: vector<u64>,
    min_asset_amount: Option<u64>,
    min_stable_amount: Option<u64>,
    review_period_ms: Option<u64>,
    trading_period_ms: Option<u64>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Validate at least one change is specified
    assert!(
        option::is_some(&min_asset_amount) || 
        option::is_some(&min_stable_amount) ||
        option::is_some(&review_period_ms) ||
        option::is_some(&trading_period_ms),
        ENoChangesSpecified
    );
    
    // Validate parameters
    validate_trading_params(
        min_asset_amount,
        min_stable_amount,
        review_period_ms,
        trading_period_ms
    );
    
    // Create actions vector for binary proposal
    let mut actions = vector::empty<ConfigAction>();
    // Outcome 0: Reject (no-op)
    vector::push_back(&mut actions, config_actions::create_no_op_action());
    // Outcome 1: Accept (apply changes)
    vector::push_back(&mut actions, config_actions::create_trading_params_action(
        min_asset_amount,
        min_stable_amount,
        review_period_ms,
        trading_period_ms
    ));
    
    // Call the unified function with binary setup
    create_config_proposal<AssetType, StableType>(
        dao,
        fee_manager,
        config_registry,
        payment,
        dao_fee_payment,
        title,
        metadata,
        vector[b"No change".to_string(), b"Apply changes".to_string()],
        vector[b"".to_string(), b"".to_string()], // Will be auto-filled as Reject/Accept
        initial_outcome_amounts,
        actions,
        clock,
        ctx
    );
}

/// Create a binary metadata update proposal
public entry fun create_metadata_proposal<AssetType, StableType>(
    dao: &mut DAO<AssetType, StableType>,
    fee_manager: &mut fee::FeeManager,
    config_registry: &mut ConfigActionRegistry,
    payment: Coin<SUI>,
    dao_fee_payment: Coin<StableType>,
    title: String,
    metadata: String,
    initial_outcome_amounts: vector<u64>,
    dao_name: AsciiString,
    icon_url_str: AsciiString,
    description: String,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Convert parameters to options
    let dao_name_opt = if (dao_name.length() > 0) {
        option::some(dao_name)
    } else {
        option::none()
    };
    
    let icon_url_opt = if (icon_url_str.length() > 0) {
        option::some(url::new_unsafe(icon_url_str))
    } else {
        option::none()
    };
    
    let description_opt = if (description.length() > 0) {
        option::some(description)
    } else {
        option::none()
    };
    
    // Validate at least one change
    assert!(
        option::is_some(&dao_name_opt) || 
        option::is_some(&icon_url_opt) ||
        option::is_some(&description_opt),
        ENoChangesSpecified
    );
    
    // Create actions vector for binary proposal
    let mut actions = vector::empty<ConfigAction>();
    // Outcome 0: Reject (no-op)
    vector::push_back(&mut actions, config_actions::create_no_op_action());
    // Outcome 1: Accept (apply changes)
    vector::push_back(&mut actions, config_actions::create_metadata_action(
        dao_name_opt,
        icon_url_opt,
        description_opt
    ));
    
    // Call the unified function with binary setup
    create_config_proposal<AssetType, StableType>(
        dao,
        fee_manager,
        config_registry,
        payment,
        dao_fee_payment,
        title,
        metadata,
        vector[b"No change".to_string(), b"Apply changes".to_string()],
        vector[b"".to_string(), b"".to_string()], // Will be auto-filled as Reject/Accept
        initial_outcome_amounts,
        actions,
        clock,
        ctx
    );
}

/// Create a governance settings update proposal (convenience function)
/// Updates DAO governance parameters including proposal creation, max outcomes, and bond requirements
public entry fun create_governance_proposal<AssetType, StableType>(
    dao: &mut DAO<AssetType, StableType>,
    fee_manager: &mut fee::FeeManager,
    config_registry: &mut ConfigActionRegistry,
    payment: Coin<SUI>,
    dao_fee_payment: Coin<StableType>,
    title: String,
    metadata: String,
    initial_outcome_amounts: vector<u64>,
    proposal_creation_enabled: Option<bool>,
    max_outcomes: Option<u64>,
    required_bond_amount: Option<u64>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Validate that at least one setting is being changed
    assert!(
        option::is_some(&proposal_creation_enabled) || 
        option::is_some(&max_outcomes) ||
        option::is_some(&required_bond_amount),
        ENoChangesSpecified
    );
    
    // Create binary outcome setup
    let mut outcome_descriptions = vector[
        b"Reject the governance update".to_string(),
        b"Accept the governance update".to_string()
    ];
    
    // Create config actions for each outcome
    let mut actions = vector::empty<ConfigAction>();
    // Outcome 0: Reject (no-op)
    vector::push_back(&mut actions, config_actions::create_no_op_action());
    // Outcome 1: Accept (apply changes)
    vector::push_back(&mut actions, config_actions::create_governance_action(
        proposal_creation_enabled,
        max_outcomes,
        required_bond_amount
    ));
    
    // Call the unified function with binary setup
    create_config_proposal(
        dao,
        fee_manager,
        config_registry,
        payment,
        dao_fee_payment,
        title,
        metadata,
        outcome_descriptions,
        vector[b"".to_string(), b"".to_string()], // Will be auto-filled as Reject/Accept
        initial_outcome_amounts,
        actions,
        clock,
        ctx
    );
}

// === Execution Functions (called after proposal passes) ===

/// Execute trading parameters update after proposal passes
/// This reads the exact config that was voted on from the registry
public entry fun execute_trading_params_update<AssetType, StableType>(
    dao: &mut DAO<AssetType, StableType>,
    config_registry: &mut ConfigActionRegistry,
    escrow: &coin_escrow::TokenEscrow<AssetType, StableType>,
    proposal_id: ID,
    clock: &Clock,
    _ctx: &mut TxContext,
) {
    // Verify proposal passed and is for this DAO
    let proposal_info = dao::get_proposal_info(dao, proposal_id);
    assert!(dao::is_executed(proposal_info), EProposalNotExecuted);
    
    // Get winning outcome from the market state
    let market_state = coin_escrow::get_market_state(escrow);
    let winning_outcome = market_state::get_winning_outcome(market_state);
    
    // Get the config action from registry (this also marks it as executed)
    let config_action = config_actions::get_and_mark_executed(config_registry, proposal_id, winning_outcome);
    let update = config_actions::extract_trading_params(&config_action);
    
    // Get the fields from the update
    let (min_asset_amount, min_stable_amount, review_period_ms, trading_period_ms) = 
        config_actions::get_trading_params_fields(update);
    
    // Validate parameters from the stored config
    validate_trading_params(
        *min_asset_amount,
        *min_stable_amount,
        *review_period_ms,
        *trading_period_ms
    );
    
    // Apply updates from the stored config
    dao::update_trading_params(
        dao,
        *min_asset_amount,
        *min_stable_amount,
        *review_period_ms,
        *trading_period_ms
    );
    
    event::emit(ConfigUpdateExecuted {
        dao_id: object::id(dao),
        proposal_id,
        update_type: b"trading_params".to_string(),
        changes_count: count_options(&vector[
            option::is_some(min_asset_amount),
            option::is_some(min_stable_amount),
            option::is_some(review_period_ms),
            option::is_some(trading_period_ms)
        ]),
        timestamp: clock.timestamp_ms(),
    });
}

/// Execute metadata update after proposal passes
/// This reads the exact config that was voted on from the registry
public entry fun execute_metadata_update<AssetType, StableType>(
    dao: &mut DAO<AssetType, StableType>,
    config_registry: &mut ConfigActionRegistry,
    escrow: &coin_escrow::TokenEscrow<AssetType, StableType>,
    proposal_id: ID,
    clock: &Clock,
    _ctx: &mut TxContext,
) {
    // Verify proposal passed
    let proposal_info = dao::get_proposal_info(dao, proposal_id);
    assert!(dao::is_executed(proposal_info), EProposalNotExecuted);
    
    // Get winning outcome from the market state
    let market_state = coin_escrow::get_market_state(escrow);
    let winning_outcome = market_state::get_winning_outcome(market_state);
    
    // Get the config action from registry (this also marks it as executed)
    let config_action = config_actions::get_and_mark_executed(config_registry, proposal_id, winning_outcome);
    let update = config_actions::extract_metadata(&config_action);
    
    // Get the fields from the update
    let (dao_name, icon_url, description) = config_actions::get_metadata_fields(update);
    
    // Apply updates from the stored config
    dao::update_metadata(dao, *dao_name, *icon_url, *description);
    
    event::emit(ConfigUpdateExecuted {
        dao_id: object::id(dao),
        proposal_id,
        update_type: b"metadata".to_string(),
        changes_count: count_options(&vector[
            option::is_some(dao_name),
            option::is_some(icon_url),
            option::is_some(description)
        ]),
        timestamp: clock.timestamp_ms(),
    });
}

/// Execute TWAP config update after proposal passes
/// This reads the exact config that was voted on from the registry
public entry fun execute_twap_config_update<AssetType, StableType>(
    dao: &mut DAO<AssetType, StableType>,
    config_registry: &mut ConfigActionRegistry,
    escrow: &coin_escrow::TokenEscrow<AssetType, StableType>,
    proposal_id: ID,
    clock: &Clock,
    _ctx: &mut TxContext,
) {
    // Verify proposal passed
    let proposal_info = dao::get_proposal_info(dao, proposal_id);
    assert!(dao::is_executed(proposal_info), EProposalNotExecuted);
    
    // Get winning outcome from the market state
    let market_state = coin_escrow::get_market_state(escrow);
    let winning_outcome = market_state::get_winning_outcome(market_state);
    
    // Get the config action from registry (this also marks it as executed)
    let config_action = config_actions::get_and_mark_executed(config_registry, proposal_id, winning_outcome);
    let update = config_actions::extract_twap_config(&config_action);
    
    // Get the fields from the update
    let (start_delay, step_max, initial_observation, threshold) = 
        config_actions::get_twap_config_fields(update);
    
    // Validate TWAP config from the stored values
    validate_twap_config(*start_delay, *threshold);
    
    // Apply updates from the stored config
    dao::update_twap_config(
        dao,
        *start_delay,
        *step_max,
        *initial_observation,
        *threshold
    );
    
    event::emit(ConfigUpdateExecuted {
        dao_id: object::id(dao),
        proposal_id,
        update_type: b"twap_config".to_string(),
        changes_count: count_options(&vector[
            option::is_some(start_delay),
            option::is_some(step_max),
            option::is_some(initial_observation),
            option::is_some(threshold)
        ]),
        timestamp: clock.timestamp_ms(),
    });
}

/// Execute governance settings update after proposal passes
/// This reads the exact config that was voted on from the registry
public entry fun execute_governance_update<AssetType, StableType>(
    dao: &mut DAO<AssetType, StableType>,
    config_registry: &mut ConfigActionRegistry,
    escrow: &coin_escrow::TokenEscrow<AssetType, StableType>,
    proposal_id: ID,
    clock: &Clock,
    _ctx: &mut TxContext,
) {
    // Verify proposal passed
    let proposal_info = dao::get_proposal_info(dao, proposal_id);
    assert!(dao::is_executed(proposal_info), EProposalNotExecuted);
    
    // Get winning outcome from the market state
    let market_state = coin_escrow::get_market_state(escrow);
    let winning_outcome = market_state::get_winning_outcome(market_state);
    
    // Get the config action from registry (this also marks it as executed)
    let config_action = config_actions::get_and_mark_executed(config_registry, proposal_id, winning_outcome);
    let update = config_actions::extract_governance(&config_action);
    
    // Get the fields from the update
    let (proposal_creation_enabled, max_outcomes, required_bond_amount) = config_actions::get_governance_fields(update);
    
    // Validate governance settings from the stored values
    validate_governance_settings(*proposal_creation_enabled, *max_outcomes);
    
    // Apply updates from the stored config
    dao::update_governance(
        dao,
        *proposal_creation_enabled,
        *max_outcomes,
        option::none() // proposal_fee_per_outcome not updated through this config
    );
    
    // Apply bond amount update if specified
    if (option::is_some(required_bond_amount)) {
        dao::set_required_bond_amount(dao, *option::borrow(required_bond_amount));
    };
    
    event::emit(ConfigUpdateExecuted {
        dao_id: object::id(dao),
        proposal_id,
        update_type: b"governance".to_string(),
        changes_count: count_options(&vector[
            option::is_some(proposal_creation_enabled),
            option::is_some(max_outcomes),
            option::is_some(required_bond_amount)
        ]),
        timestamp: clock.timestamp_ms(),
    });
}

// === Helper Functions ===

fun validate_trading_params(
    min_asset_amount: Option<u64>,
    min_stable_amount: Option<u64>,
    review_period_ms: Option<u64>,
    trading_period_ms: Option<u64>,
) {
    if (option::is_some(&min_asset_amount)) {
        assert!(*option::borrow(&min_asset_amount) >= MIN_AMM_SAFE_AMOUNT, EInvalidMinAmount);
    };
    if (option::is_some(&min_stable_amount)) {
        assert!(*option::borrow(&min_stable_amount) >= MIN_AMM_SAFE_AMOUNT, EInvalidMinAmount);
    };
    if (option::is_some(&review_period_ms)) {
        assert!(*option::borrow(&review_period_ms) >= MIN_REVIEW_PERIOD, EReviewPeriodTooShort);
    };
    if (option::is_some(&trading_period_ms)) {
        assert!(*option::borrow(&trading_period_ms) >= MIN_TRADING_PERIOD, ETradingPeriodTooShort);
    };
}

fun count_options(options: &vector<bool>): u64 {
    let mut count = 0;
    let mut i = 0;
    while (i < vector::length(options)) {
        if (*vector::borrow(options, i)) {
            count = count + 1;
        };
        i = i + 1;
    };
    count
}

/// Validate TWAP configuration parameters
fun validate_twap_config(
    start_delay: Option<u64>,
    threshold: Option<u64>,
) {
    if (option::is_some(&start_delay)) {
        let delay = *option::borrow(&start_delay);
        assert!(delay >= 1000, EInvalidTwapDelay); // At least 1 second
    };
    
    if (option::is_some(&threshold)) {
        let thresh = *option::borrow(&threshold);
        assert!(thresh > 0, EInvalidTwapDelay);
    };
}

/// Validate governance settings
fun validate_governance_settings(
    _proposal_creation_enabled: Option<bool>,
    max_outcomes: Option<u64>,
) {
    if (option::is_some(&max_outcomes)) {
        let max = *option::borrow(&max_outcomes);
        assert!(max >= 2 && max <= 100, EInvalidMaxOutcomes); // Reasonable bounds
    };
}

// === Constants ===
const EProposalNotExecuted: u64 = 100;