/// Secure storage for configuration update proposals
/// Stores the exact config changes that were voted on to prevent execution-time manipulation
module futarchy::config_actions;

// === Imports ===
use std::string::String;
use std::ascii::String as AsciiString;
use sui::{
    table::{Self, Table},
    bag::{Self, Bag},
    url::Url,
};

// === Errors ===
const EActionsAlreadyStored: u64 = 0;
const ENoActionsFound: u64 = 1;
const EAlreadyExecuted: u64 = 2;
const EInvalidOutcome: u64 = 3;

// === Constants ===
const CONFIG_TYPE_TRADING_PARAMS: u8 = 0;
const CONFIG_TYPE_METADATA: u8 = 1;
const CONFIG_TYPE_TWAP: u8 = 2;
const CONFIG_TYPE_GOVERNANCE: u8 = 3;

// === Structs ===

/// Registry to store config actions for proposals
public struct ConfigActionRegistry has key {
    id: UID,
    // Map proposal_id -> ConfigProposalActions
    actions: Table<ID, ConfigProposalActions>,
}

/// Config actions for a proposal
public struct ConfigProposalActions has store {
    // Map outcome -> ConfigAction (stored at proposal creation)
    outcome_actions: Table<u64, ConfigAction>,
    // Track execution status
    executed: bool,
}

/// Wrapper for different config action types
public struct ConfigAction has store, drop {
    config_type: u8,
    // Only one of these will be Some
    trading_params: Option<TradingParamsUpdate>,
    metadata: Option<MetadataUpdate>,
    twap_config: Option<TwapConfigUpdate>,
    governance: Option<GovernanceUpdate>,
}

/// Trading parameters update action
public struct TradingParamsUpdate has store, drop {
    min_asset_amount: Option<u64>,
    min_stable_amount: Option<u64>,
    review_period_ms: Option<u64>,
    trading_period_ms: Option<u64>,
}

/// DAO metadata update action
public struct MetadataUpdate has store, drop {
    dao_name: Option<AsciiString>,
    icon_url: Option<Url>,
    description: Option<String>,
}

/// TWAP configuration update action
public struct TwapConfigUpdate has store, drop {
    start_delay: Option<u64>,
    step_max: Option<u64>,
    initial_observation: Option<u128>,
    threshold: Option<u64>,
}

/// Governance settings update action
public struct GovernanceUpdate has store, drop {
    proposal_creation_enabled: Option<bool>,
    max_outcomes: Option<u64>,
}

// === Public Functions ===

/// Create a ConfigAction for trading params update
public fun create_trading_params_action(
    min_asset_amount: Option<u64>,
    min_stable_amount: Option<u64>,
    review_period_ms: Option<u64>,
    trading_period_ms: Option<u64>,
): ConfigAction {
    ConfigAction {
        config_type: CONFIG_TYPE_TRADING_PARAMS,
        trading_params: option::some(TradingParamsUpdate {
            min_asset_amount,
            min_stable_amount,
            review_period_ms,
            trading_period_ms,
        }),
        metadata: option::none(),
        twap_config: option::none(),
        governance: option::none(),
    }
}

/// Create a ConfigAction for metadata update
public fun create_metadata_action(
    dao_name: Option<AsciiString>,
    icon_url: Option<Url>,
    description: Option<String>,
): ConfigAction {
    ConfigAction {
        config_type: CONFIG_TYPE_METADATA,
        trading_params: option::none(),
        metadata: option::some(MetadataUpdate {
            dao_name,
            icon_url,
            description,
        }),
        twap_config: option::none(),
        governance: option::none(),
    }
}

/// Create a ConfigAction for TWAP config update
public fun create_twap_config_action(
    start_delay: Option<u64>,
    step_max: Option<u64>,
    initial_observation: Option<u128>,
    threshold: Option<u64>,
): ConfigAction {
    ConfigAction {
        config_type: CONFIG_TYPE_TWAP,
        trading_params: option::none(),
        metadata: option::none(),
        twap_config: option::some(TwapConfigUpdate {
            start_delay,
            step_max,
            initial_observation,
            threshold,
        }),
        governance: option::none(),
    }
}

/// Create a ConfigAction for governance update
public fun create_governance_action(
    proposal_creation_enabled: Option<bool>,
    max_outcomes: Option<u64>,
): ConfigAction {
    ConfigAction {
        config_type: CONFIG_TYPE_GOVERNANCE,
        trading_params: option::none(),
        metadata: option::none(),
        twap_config: option::none(),
        governance: option::some(GovernanceUpdate {
            proposal_creation_enabled,
            max_outcomes,
        }),
    }
}

/// Create a no-op ConfigAction
public fun create_no_op_action(): ConfigAction {
    ConfigAction {
        config_type: CONFIG_TYPE_TRADING_PARAMS, // Type doesn't matter for no-op
        trading_params: option::none(),
        metadata: option::none(),
        twap_config: option::none(),
        governance: option::none(),
    }
}

/// Create the config action registry (called once at initialization)
public fun create_registry(ctx: &mut TxContext) {
    let registry = ConfigActionRegistry {
        id: object::new(ctx),
        actions: table::new(ctx),
    };
    transfer::share_object(registry);
}

/// Initialize storage for a new proposal
public fun init_proposal_actions(
    registry: &mut ConfigActionRegistry,
    proposal_id: ID,
    ctx: &mut TxContext,
) {
    assert!(!registry.actions.contains(proposal_id), EActionsAlreadyStored);
    
    registry.actions.add(
        proposal_id,
        ConfigProposalActions {
            outcome_actions: table::new(ctx),
            executed: false,
        }
    );
}

/// Generic function to add any config action
public fun add_config_action(
    registry: &mut ConfigActionRegistry,
    proposal_id: ID,
    outcome: u64,
    action: ConfigAction,
) {
    assert!(registry.actions.contains(proposal_id), ENoActionsFound);
    let actions = &mut registry.actions[proposal_id];
    assert!(!actions.outcome_actions.contains(outcome), EActionsAlreadyStored);
    
    actions.outcome_actions.add(outcome, action);
}

/// Add trading params update for a specific outcome
public fun add_trading_params_update(
    registry: &mut ConfigActionRegistry,
    proposal_id: ID,
    outcome: u64,
    min_asset_amount: Option<u64>,
    min_stable_amount: Option<u64>,
    review_period_ms: Option<u64>,
    trading_period_ms: Option<u64>,
) {
    let update = TradingParamsUpdate {
        min_asset_amount,
        min_stable_amount,
        review_period_ms,
        trading_period_ms,
    };
    
    let action = ConfigAction {
        config_type: CONFIG_TYPE_TRADING_PARAMS,
        trading_params: option::some(update),
        metadata: option::none(),
        twap_config: option::none(),
        governance: option::none(),
    };
    
    add_config_action(registry, proposal_id, outcome, action);
}

/// Add metadata update for a specific outcome
public fun add_metadata_update(
    registry: &mut ConfigActionRegistry,
    proposal_id: ID,
    outcome: u64,
    dao_name: Option<AsciiString>,
    icon_url: Option<Url>,
    description: Option<String>,
) {
    let update = MetadataUpdate {
        dao_name,
        icon_url,
        description,
    };
    
    let action = ConfigAction {
        config_type: CONFIG_TYPE_METADATA,
        trading_params: option::none(),
        metadata: option::some(update),
        twap_config: option::none(),
        governance: option::none(),
    };
    
    add_config_action(registry, proposal_id, outcome, action);
}

/// Store TWAP config update for a proposal
public fun add_twap_config_update(
    registry: &mut ConfigActionRegistry,
    proposal_id: ID,
    outcome: u64,
    start_delay: Option<u64>,
    step_max: Option<u64>,
    initial_observation: Option<u128>,
    threshold: Option<u64>,
) {
    let update = TwapConfigUpdate {
        start_delay,
        step_max,
        initial_observation,
        threshold,
    };
    
    let action = ConfigAction {
        config_type: CONFIG_TYPE_TWAP,
        trading_params: option::none(),
        metadata: option::none(),
        twap_config: option::some(update),
        governance: option::none(),
    };
    
    add_config_action(registry, proposal_id, outcome, action);
}

/// Store governance update for a proposal
public fun add_governance_update(
    registry: &mut ConfigActionRegistry,
    proposal_id: ID,
    outcome: u64,
    proposal_creation_enabled: Option<bool>,
    max_outcomes: Option<u64>,
) {
    let update = GovernanceUpdate {
        proposal_creation_enabled,
        max_outcomes,
    };
    
    let action = ConfigAction {
        config_type: CONFIG_TYPE_GOVERNANCE,
        trading_params: option::none(),
        metadata: option::none(),
        twap_config: option::none(),
        governance: option::some(update),
    };
    
    add_config_action(registry, proposal_id, outcome, action);
}

/// Add a no-op action for reject outcomes
public fun add_no_op_action(
    registry: &mut ConfigActionRegistry,
    proposal_id: ID,
    outcome: u64,
) {
    let action = ConfigAction {
        config_type: CONFIG_TYPE_TRADING_PARAMS, // Type doesn't matter for no-op
        trading_params: option::none(),
        metadata: option::none(),
        twap_config: option::none(),
        governance: option::none(),
    };
    
    add_config_action(registry, proposal_id, outcome, action);
}

/// Get config action for execution (marks as executed)
public fun get_and_mark_executed(
    registry: &mut ConfigActionRegistry,
    proposal_id: ID,
    winning_outcome: u64,
): ConfigAction {
    assert!(registry.actions.contains(proposal_id), ENoActionsFound);
    let actions = &mut registry.actions[proposal_id];
    assert!(!actions.executed, EAlreadyExecuted);
    assert!(actions.outcome_actions.contains(winning_outcome), EInvalidOutcome);
    
    actions.executed = true;
    actions.outcome_actions.remove(winning_outcome)
}

/// Extract trading params from config action
public fun extract_trading_params(action: &ConfigAction): &TradingParamsUpdate {
    assert!(action.config_type == CONFIG_TYPE_TRADING_PARAMS, EInvalidOutcome);
    action.trading_params.borrow()
}

/// Extract metadata from config action
public fun extract_metadata(action: &ConfigAction): &MetadataUpdate {
    assert!(action.config_type == CONFIG_TYPE_METADATA, EInvalidOutcome);
    action.metadata.borrow()
}

/// Extract TWAP config from config action
public fun extract_twap_config(action: &ConfigAction): &TwapConfigUpdate {
    assert!(action.config_type == CONFIG_TYPE_TWAP, EInvalidOutcome);
    action.twap_config.borrow()
}

/// Extract governance settings from config action
public fun extract_governance(action: &ConfigAction): &GovernanceUpdate {
    assert!(action.config_type == CONFIG_TYPE_GOVERNANCE, EInvalidOutcome);
    action.governance.borrow()
}

/// Check if actions exist for a proposal
public fun has_actions(registry: &ConfigActionRegistry, proposal_id: ID): bool {
    registry.actions.contains(proposal_id)
}

/// Check if actions have been executed
public fun is_executed(registry: &ConfigActionRegistry, proposal_id: ID): bool {
    if (!registry.actions.contains(proposal_id)) return false;
    registry.actions[proposal_id].executed
}

// === Getter Functions ===

/// Get trading params update fields
public fun get_trading_params_fields(update: &TradingParamsUpdate): (
    &Option<u64>,
    &Option<u64>,
    &Option<u64>,
    &Option<u64>
) {
    (
        &update.min_asset_amount,
        &update.min_stable_amount,
        &update.review_period_ms,
        &update.trading_period_ms
    )
}

/// Get metadata update fields
public fun get_metadata_fields(update: &MetadataUpdate): (
    &Option<AsciiString>,
    &Option<Url>,
    &Option<String>
) {
    (
        &update.dao_name,
        &update.icon_url,
        &update.description
    )
}

/// Get TWAP config update fields
public fun get_twap_config_fields(update: &TwapConfigUpdate): (
    &Option<u64>,
    &Option<u64>,
    &Option<u128>,
    &Option<u64>
) {
    (
        &update.start_delay,
        &update.step_max,
        &update.initial_observation,
        &update.threshold
    )
}

/// Get governance update fields
public fun get_governance_fields(update: &GovernanceUpdate): (
    &Option<bool>,
    &Option<u64>
) {
    (
        &update.proposal_creation_enabled,
        &update.max_outcomes
    )
}

// === Test Functions ===

#[test_only]
public fun create_registry_for_testing(ctx: &mut TxContext) {
    create_registry(ctx);
}