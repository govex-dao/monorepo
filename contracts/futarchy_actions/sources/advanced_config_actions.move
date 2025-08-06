/// Advanced configuration actions for futarchy DAOs
/// This module defines action structs and execution logic for advanced configuration changes
module futarchy_actions::advanced_config_actions;

// === Imports ===
use std::string::String;
use std::ascii::String as AsciiString;
use std::option;
use sui::url::Url;
use account_protocol::{
    account::{Self, Account, Auth},
    executable::Executable,
    intents::{Expired, Intent},
    version_witness::VersionWitness,
};
use sui::tx_context::TxContext;

// === Aliases ===
use account_protocol::intents as protocol_intents;
use fun protocol_intents::add_action as Intent.add_action;

// === Errors ===
const EInvalidParameter: u64 = 1;
const EEmptyString: u64 = 2;
const EMismatchedKeyValueLength: u64 = 3;
const EInvalidConfigType: u64 = 4;
const ENotImplemented: u64 = 5;

// === Constants ===
const CONFIG_TYPE_TRADING_PARAMS: u8 = 0;
const CONFIG_TYPE_METADATA: u8 = 1;
const CONFIG_TYPE_TWAP: u8 = 2;
const CONFIG_TYPE_GOVERNANCE: u8 = 3;
const CONFIG_TYPE_METADATA_TABLE: u8 = 4;
const CONFIG_TYPE_QUEUE_PARAMS: u8 = 5;

// === Action Structs ===

/// Trading parameters update action
public struct TradingParamsUpdateAction has store, drop {
    min_asset_amount: Option<u64>,
    min_stable_amount: Option<u64>,
    review_period_ms: Option<u64>,
    trading_period_ms: Option<u64>,
    amm_total_fee_bps: Option<u64>,
}

/// DAO metadata update action
public struct MetadataUpdateAction has store, drop {
    dao_name: Option<AsciiString>,
    icon_url: Option<Url>,
    description: Option<String>,
}

/// TWAP configuration update action
public struct TwapConfigUpdateAction has store, drop {
    start_delay: Option<u64>,
    step_max: Option<u64>,
    initial_observation: Option<u128>,
    threshold: Option<u64>,
}

/// Governance settings update action
public struct GovernanceUpdateAction has store, drop {
    proposal_creation_enabled: Option<bool>,
    max_outcomes: Option<u64>,
    required_bond_amount: Option<u64>,
}

/// Metadata table update action
public struct MetadataTableUpdateAction has store, drop {
    keys: vector<String>,
    values: vector<String>,
    keys_to_remove: vector<String>,
}

/// Queue parameters update action
public struct QueueParamsUpdateAction has store, drop {
    max_proposer_funded: Option<u64>,
    max_concurrent_proposals: Option<u64>,
    max_queue_size: Option<u64>,
}

/// Wrapper for different config action types (for batch operations)
public struct ConfigAction has store, drop {
    config_type: u8,
    // Only one of these will be populated
    trading_params: Option<TradingParamsUpdateAction>,
    metadata: Option<MetadataUpdateAction>,
    twap_config: Option<TwapConfigUpdateAction>,
    governance: Option<GovernanceUpdateAction>,
    metadata_table: Option<MetadataTableUpdateAction>,
    queue_params: Option<QueueParamsUpdateAction>,
}

// === Execution Functions ===

/// Execute a trading params update action
public fun do_update_trading_params<Config, Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<Config>,
    version: VersionWitness,
    intent_witness: IW,
    ctx: &mut TxContext,
) {
    let action: &TradingParamsUpdateAction = executable.next_action(intent_witness);
    
    // Validate parameters
    validate_trading_params_update(action);
    
    // Extract and validate the parameters
    let (
        min_asset_amount,
        min_stable_amount,
        review_period_ms,
        trading_period_ms,
        amm_total_fee_bps
    ) = get_trading_params_fields(action);
    
    // This needs to be implemented by the futarchy_config module which has ConfigWitness
    // to access config_mut. For now we just validate and prepare the data.
    let _ = min_asset_amount;
    let _ = min_stable_amount;
    let _ = review_period_ms;
    let _ = trading_period_ms;
    let _ = amm_total_fee_bps;
    let _ = account;
    let _ = version;
    let _ = ctx;
    
    // The actual implementation would be:
    // futarchy_config::update_trading_params(account, action, version, config_witness)
    abort ENotImplemented
}

/// Execute a metadata update action
public fun do_update_metadata<Config, Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<Config>,
    version: VersionWitness,
    intent_witness: IW,
    ctx: &mut TxContext,
) {
    let action: &MetadataUpdateAction = executable.next_action(intent_witness);
    
    // Validate parameters
    validate_metadata_update(action);
    
    // Extract and validate the parameters
    let (
        dao_name,
        icon_url,
        description
    ) = get_metadata_fields(action);
    
    // This needs to be implemented by the futarchy_config module
    let _ = dao_name;
    let _ = icon_url;
    let _ = description;
    let _ = account;
    let _ = version;
    let _ = ctx;
    
    // The actual implementation would be:
    // futarchy_config::update_metadata(account, action, version, config_witness)
    abort ENotImplemented
}

/// Execute a TWAP config update action
public fun do_update_twap_config<Config, Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<Config>,
    version: VersionWitness,
    intent_witness: IW,
    ctx: &mut TxContext,
) {
    let action: &TwapConfigUpdateAction = executable.next_action(intent_witness);
    
    // Validate parameters
    validate_twap_config_update(action);
    
    // Extract parameters
    let (
        start_delay,
        step_max,
        initial_observation,
        threshold
    ) = get_twap_config_fields(action);
    
    // This needs futarchy_config module implementation
    let _ = start_delay;
    let _ = step_max;
    let _ = initial_observation;
    let _ = threshold;
    let _ = account;
    let _ = version;
    let _ = ctx;
    
    abort ENotImplemented
}

/// Execute a governance update action
public fun do_update_governance<Config, Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<Config>,
    version: VersionWitness,
    intent_witness: IW,
    ctx: &mut TxContext,
) {
    let action: &GovernanceUpdateAction = executable.next_action(intent_witness);
    
    // Validate parameters
    validate_governance_update(action);
    
    // The implementing module should handle the actual config update
    let _ = action;
    let _ = account;
    let _ = version;
    let _ = ctx;
    abort ENotImplemented
}

/// Execute a metadata table update action
public fun do_update_metadata_table<Config, Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<Config>,
    version: VersionWitness,
    intent_witness: IW,
    ctx: &mut TxContext,
) {
    let action: &MetadataTableUpdateAction = executable.next_action(intent_witness);
    
    // Validate parameters
    assert!(action.keys.length() == action.values.length(), EMismatchedKeyValueLength);
    
    // The implementing module should handle the actual config update
    let _ = action;
    let _ = account;
    let _ = version;
    let _ = ctx;
    abort ENotImplemented
}

/// Execute a queue params update action
public fun do_update_queue_params<Config, Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<Config>,
    version: VersionWitness,
    intent_witness: IW,
    ctx: &mut TxContext,
) {
    let action: &QueueParamsUpdateAction = executable.next_action(intent_witness);
    
    // Validate parameters
    validate_queue_params_update(action);
    
    // The implementing module should handle the actual config update
    let _ = action;
    let _ = account;
    let _ = version;
    let _ = ctx;
    abort ENotImplemented
}

// === Cleanup Functions ===

/// Delete a trading params update action from an expired intent
public fun delete_trading_params_update(expired: &mut Expired) {
    let TradingParamsUpdateAction {
        min_asset_amount: _,
        min_stable_amount: _,
        review_period_ms: _,
        trading_period_ms: _,
        amm_total_fee_bps: _,
    } = expired.remove_action();
}

/// Delete a metadata update action from an expired intent
public fun delete_metadata_update(expired: &mut Expired) {
    let MetadataUpdateAction {
        dao_name: _,
        icon_url: _,
        description: _,
    } = expired.remove_action();
}

/// Delete a TWAP config update action from an expired intent
public fun delete_twap_config_update(expired: &mut Expired) {
    let TwapConfigUpdateAction {
        start_delay: _,
        step_max: _,
        initial_observation: _,
        threshold: _,
    } = expired.remove_action();
}

/// Delete a governance update action from an expired intent
public fun delete_governance_update(expired: &mut Expired) {
    let GovernanceUpdateAction {
        proposal_creation_enabled: _,
        max_outcomes: _,
        required_bond_amount: _,
    } = expired.remove_action();
}

/// Delete a metadata table update action from an expired intent
public fun delete_metadata_table_update(expired: &mut Expired) {
    let MetadataTableUpdateAction {
        keys: _,
        values: _,
        keys_to_remove: _,
    } = expired.remove_action();
}

/// Delete a queue params update action from an expired intent
public fun delete_queue_params_update(expired: &mut Expired) {
    let QueueParamsUpdateAction {
        max_proposer_funded: _,
        max_concurrent_proposals: _,
        max_queue_size: _,
    } = expired.remove_action();
}

/// Delete a config action from an expired intent
public fun delete_config_action(expired: &mut Expired) {
    let ConfigAction {
        config_type: _,
        trading_params: _,
        metadata: _,
        twap_config: _,
        governance: _,
        metadata_table: _,
        queue_params: _,
    } = expired.remove_action();
}

// === Helper Functions ===

/// Create a trading params update action
public fun new_trading_params_update_action(
    min_asset_amount: Option<u64>,
    min_stable_amount: Option<u64>,
    review_period_ms: Option<u64>,
    trading_period_ms: Option<u64>,
    amm_total_fee_bps: Option<u64>,
): TradingParamsUpdateAction {
    // Validate parameters if they are Some
    if (min_asset_amount.is_some()) {
        assert!(*min_asset_amount.borrow() > 0, EInvalidParameter);
    };
    if (min_stable_amount.is_some()) {
        assert!(*min_stable_amount.borrow() > 0, EInvalidParameter);
    };
    if (review_period_ms.is_some()) {
        assert!(*review_period_ms.borrow() > 0, EInvalidParameter);
    };
    if (trading_period_ms.is_some()) {
        assert!(*trading_period_ms.borrow() > 0, EInvalidParameter);
    };
    if (amm_total_fee_bps.is_some()) {
        assert!(*amm_total_fee_bps.borrow() <= 10000, EInvalidParameter); // Max 100%
    };
    
    TradingParamsUpdateAction {
        min_asset_amount,
        min_stable_amount,
        review_period_ms,
        trading_period_ms,
        amm_total_fee_bps,
    }
}

/// Create a metadata update action
public fun new_metadata_update_action(
    dao_name: Option<AsciiString>,
    icon_url: Option<Url>,
    description: Option<String>,
): MetadataUpdateAction {
    // Validate non-empty strings
    if (dao_name.is_some()) {
        assert!(dao_name.borrow().length() > 0, EEmptyString);
    };
    if (description.is_some()) {
        assert!(description.borrow().length() > 0, EEmptyString);
    };
    
    MetadataUpdateAction {
        dao_name,
        icon_url,
        description,
    }
}

/// Create a TWAP config update action
public fun new_twap_config_update_action(
    start_delay: Option<u64>,
    step_max: Option<u64>,
    initial_observation: Option<u128>,
    threshold: Option<u64>,
): TwapConfigUpdateAction {
    // Validate parameters if they are Some
    if (step_max.is_some()) {
        assert!(*step_max.borrow() > 0, EInvalidParameter);
    };
    
    TwapConfigUpdateAction {
        start_delay,
        step_max,
        initial_observation,
        threshold,
    }
}

/// Create a governance update action
public fun new_governance_update_action(
    proposal_creation_enabled: Option<bool>,
    max_outcomes: Option<u64>,
    required_bond_amount: Option<u64>,
): GovernanceUpdateAction {
    // Validate parameters if they are Some
    if (max_outcomes.is_some()) {
        assert!(*max_outcomes.borrow() >= 2, EInvalidParameter); // At least YES/NO
    };
    
    GovernanceUpdateAction {
        proposal_creation_enabled,
        max_outcomes,
        required_bond_amount,
    }
}

/// Create a metadata table update action
public fun new_metadata_table_update_action(
    keys: vector<String>,
    values: vector<String>,
    keys_to_remove: vector<String>,
): MetadataTableUpdateAction {
    // Validate key-value pairs match
    assert!(keys.length() == values.length(), EMismatchedKeyValueLength);
    
    MetadataTableUpdateAction {
        keys,
        values,
        keys_to_remove,
    }
}

/// Create a queue params update action
public fun new_queue_params_update_action(
    max_proposer_funded: Option<u64>,
    max_concurrent_proposals: Option<u64>,
    max_queue_size: Option<u64>,
): QueueParamsUpdateAction {
    // Validate parameters if they are Some
    if (max_proposer_funded.is_some()) {
        assert!(*max_proposer_funded.borrow() > 0, EInvalidParameter);
    };
    if (max_concurrent_proposals.is_some()) {
        assert!(*max_concurrent_proposals.borrow() > 0, EInvalidParameter);
    };
    if (max_queue_size.is_some()) {
        assert!(*max_queue_size.borrow() > 0, EInvalidParameter);
    };
    
    QueueParamsUpdateAction {
        max_proposer_funded,
        max_concurrent_proposals,
        max_queue_size,
    }
}

/// Create a ConfigAction for trading params update
public fun create_trading_params_action(update: TradingParamsUpdateAction): ConfigAction {
    ConfigAction {
        config_type: CONFIG_TYPE_TRADING_PARAMS,
        trading_params: option::some(update),
        metadata: option::none(),
        twap_config: option::none(),
        governance: option::none(),
        metadata_table: option::none(),
        queue_params: option::none(),
    }
}

/// Create a ConfigAction for metadata update
public fun create_metadata_action(update: MetadataUpdateAction): ConfigAction {
    ConfigAction {
        config_type: CONFIG_TYPE_METADATA,
        trading_params: option::none(),
        metadata: option::some(update),
        twap_config: option::none(),
        governance: option::none(),
        metadata_table: option::none(),
        queue_params: option::none(),
    }
}

/// Create a ConfigAction for TWAP config update
public fun create_twap_config_action(update: TwapConfigUpdateAction): ConfigAction {
    ConfigAction {
        config_type: CONFIG_TYPE_TWAP,
        trading_params: option::none(),
        metadata: option::none(),
        twap_config: option::some(update),
        governance: option::none(),
        metadata_table: option::none(),
        queue_params: option::none(),
    }
}

/// Create a ConfigAction for governance update
public fun create_governance_action(update: GovernanceUpdateAction): ConfigAction {
    ConfigAction {
        config_type: CONFIG_TYPE_GOVERNANCE,
        trading_params: option::none(),
        metadata: option::none(),
        twap_config: option::none(),
        governance: option::some(update),
        metadata_table: option::none(),
        queue_params: option::none(),
    }
}

/// Create a ConfigAction for metadata table update
public fun create_metadata_table_action(update: MetadataTableUpdateAction): ConfigAction {
    ConfigAction {
        config_type: CONFIG_TYPE_METADATA_TABLE,
        trading_params: option::none(),
        metadata: option::none(),
        twap_config: option::none(),
        governance: option::none(),
        metadata_table: option::some(update),
        queue_params: option::none(),
    }
}

/// Create a ConfigAction for queue params update
public fun create_queue_params_action(update: QueueParamsUpdateAction): ConfigAction {
    ConfigAction {
        config_type: CONFIG_TYPE_QUEUE_PARAMS,
        trading_params: option::none(),
        metadata: option::none(),
        twap_config: option::none(),
        governance: option::none(),
        metadata_table: option::none(),
        queue_params: option::some(update),
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
        metadata_table: option::none(),
        queue_params: option::none(),
    }
}

// === Getter Functions ===

/// Get trading params update fields
public fun get_trading_params_fields(update: &TradingParamsUpdateAction): (
    &Option<u64>,
    &Option<u64>,
    &Option<u64>,
    &Option<u64>,
    &Option<u64>
) {
    (
        &update.min_asset_amount,
        &update.min_stable_amount,
        &update.review_period_ms,
        &update.trading_period_ms,
        &update.amm_total_fee_bps
    )
}

/// Get metadata update fields
public fun get_metadata_fields(update: &MetadataUpdateAction): (
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
public fun get_twap_config_fields(update: &TwapConfigUpdateAction): (
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
public fun get_governance_fields(update: &GovernanceUpdateAction): (
    &Option<bool>,
    &Option<u64>,
    &Option<u64>
) {
    (
        &update.proposal_creation_enabled,
        &update.max_outcomes,
        &update.required_bond_amount
    )
}

/// Get metadata table update fields
public fun get_metadata_table_fields(update: &MetadataTableUpdateAction): (
    &vector<String>,
    &vector<String>,
    &vector<String>
) {
    (
        &update.keys,
        &update.values,
        &update.keys_to_remove
    )
}

/// Get queue params update fields
public fun get_queue_params_fields(update: &QueueParamsUpdateAction): (
    &Option<u64>,
    &Option<u64>,
    &Option<u64>
) {
    (
        &update.max_proposer_funded,
        &update.max_concurrent_proposals,
        &update.max_queue_size
    )
}

/// Get config action type and extract specific action
public fun get_config_action_params(action: &ConfigAction): u8 {
    action.config_type
}

/// Extract trading params from config action
public fun extract_trading_params(action: &ConfigAction): &TradingParamsUpdateAction {
    assert!(action.config_type == CONFIG_TYPE_TRADING_PARAMS, EInvalidConfigType);
    action.trading_params.borrow()
}

/// Extract metadata from config action
public fun extract_metadata(action: &ConfigAction): &MetadataUpdateAction {
    assert!(action.config_type == CONFIG_TYPE_METADATA, EInvalidConfigType);
    action.metadata.borrow()
}

/// Extract TWAP config from config action
public fun extract_twap_config(action: &ConfigAction): &TwapConfigUpdateAction {
    assert!(action.config_type == CONFIG_TYPE_TWAP, EInvalidConfigType);
    action.twap_config.borrow()
}

/// Extract governance settings from config action
public fun extract_governance(action: &ConfigAction): &GovernanceUpdateAction {
    assert!(action.config_type == CONFIG_TYPE_GOVERNANCE, EInvalidConfigType);
    action.governance.borrow()
}

/// Extract metadata table from config action
public fun extract_metadata_table(action: &ConfigAction): &MetadataTableUpdateAction {
    assert!(action.config_type == CONFIG_TYPE_METADATA_TABLE, EInvalidConfigType);
    action.metadata_table.borrow()
}

/// Extract queue params from config action
public fun extract_queue_params(action: &ConfigAction): &QueueParamsUpdateAction {
    assert!(action.config_type == CONFIG_TYPE_QUEUE_PARAMS, EInvalidConfigType);
    action.queue_params.borrow()
}

// === Helper Functions for Intent Integration ===

/// Helper to add metadata update to intent
public fun new_update_metadata<Outcome: store, IW: drop>(
    intent: &mut Intent<Outcome>,
    name: AsciiString,
    icon_url: Url,
    description: String,
    iw: IW
) {
    let action = new_metadata_update_action(
        option::some(name), 
        option::some(icon_url), 
        option::some(description)
    );
    let config_action = create_metadata_action(action);
    intent.add_action(config_action, iw);
}

/// Helper to add trading params update to intent
public fun new_update_trading_params<Outcome: store, IW: drop>(
    intent: &mut Intent<Outcome>,
    review_period_ms: u64,
    trading_period_ms: u64,
    proposal_fee_per_outcome: u64,
    max_concurrent_proposals: u64,
    iw: IW
) {
    let action = new_trading_params_update_action(
        option::none(), // min_asset_amount
        option::none(), // min_stable_amount
        option::some(review_period_ms),
        option::some(trading_period_ms),
        option::some(proposal_fee_per_outcome) // Using this as amm_total_fee_bps
    );
    let config_action = create_trading_params_action(action);
    intent.add_action(config_action, iw);
}

/// Helper to add TWAP params update to intent
public fun new_update_twap_params<Outcome: store, IW: drop>(
    intent: &mut Intent<Outcome>,
    twap_start_delay: u64,
    twap_step_max: u64,
    twap_initial_observation: u128,
    twap_threshold: u64,
    iw: IW
) {
    let action = new_twap_config_update_action(
        option::some(twap_start_delay),
        option::some(twap_step_max),
        option::some(twap_initial_observation),
        option::some(twap_threshold)
    );
    let config_action = create_twap_config_action(action);
    intent.add_action(config_action, iw);
}

/// Helper to add fee params update to intent
public fun new_update_fee_params<Outcome: store, IW: drop>(
    intent: &mut Intent<Outcome>,
    amm_total_fee_bps: u64,
    fee_manager_address: address,
    activator_reward_bps: u64,
    iw: IW
) {
    // Fee params don't map directly to any existing action
    // Using trading params for fee-related updates
    let action = new_trading_params_update_action(
        option::none(), // min_asset_amount
        option::none(), // min_stable_amount
        option::none(), // review_period_ms
        option::none(), // trading_period_ms
        option::some(amm_total_fee_bps)
    );
    let config_action = create_trading_params_action(action);
    intent.add_action(config_action, iw);
}

/// Alias for do_update_twap_config for compatibility
public fun do_update_twap_params<Config, Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<Config>,
    version: VersionWitness,
    iw: IW,
    ctx: &mut TxContext
) {
    do_update_twap_config<Config, Outcome, IW>(executable, account, version, iw, ctx);
}

/// Alias for queue params update (was called fee params)
public fun do_update_fee_params<Config, Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<Config>,
    version: VersionWitness,
    iw: IW,
    ctx: &mut TxContext
) {
    do_update_queue_params<Config, Outcome, IW>(executable, account, version, iw, ctx);
}

// === Internal Validation Functions ===

/// Validate trading params update
fun validate_trading_params_update(action: &TradingParamsUpdateAction) {
    if (action.min_asset_amount.is_some()) {
        assert!(*action.min_asset_amount.borrow() > 0, EInvalidParameter);
    };
    if (action.min_stable_amount.is_some()) {
        assert!(*action.min_stable_amount.borrow() > 0, EInvalidParameter);
    };
    if (action.review_period_ms.is_some()) {
        assert!(*action.review_period_ms.borrow() > 0, EInvalidParameter);
    };
    if (action.trading_period_ms.is_some()) {
        assert!(*action.trading_period_ms.borrow() > 0, EInvalidParameter);
    };
    if (action.amm_total_fee_bps.is_some()) {
        assert!(*action.amm_total_fee_bps.borrow() <= 10000, EInvalidParameter); // Max 100%
    };
}

/// Validate metadata update
fun validate_metadata_update(action: &MetadataUpdateAction) {
    if (action.dao_name.is_some()) {
        assert!(action.dao_name.borrow().length() > 0, EEmptyString);
    };
    if (action.description.is_some()) {
        assert!(action.description.borrow().length() > 0, EEmptyString);
    };
    // URL validation is handled by the Url type itself
}

/// Validate TWAP config update
fun validate_twap_config_update(action: &TwapConfigUpdateAction) {
    if (action.step_max.is_some()) {
        assert!(*action.step_max.borrow() > 0, EInvalidParameter);
    };
    // Other TWAP parameters can be 0 or any value
}

/// Validate governance update
fun validate_governance_update(action: &GovernanceUpdateAction) {
    if (action.max_outcomes.is_some()) {
        assert!(*action.max_outcomes.borrow() >= 2, EInvalidParameter); // At least YES/NO
    };
    // Other governance parameters are validated by their types
}

/// Validate queue params update
fun validate_queue_params_update(action: &QueueParamsUpdateAction) {
    if (action.max_proposer_funded.is_some()) {
        assert!(*action.max_proposer_funded.borrow() > 0, EInvalidParameter);
    };
    if (action.max_concurrent_proposals.is_some()) {
        assert!(*action.max_concurrent_proposals.borrow() > 0, EInvalidParameter);
    };
    if (action.max_queue_size.is_some()) {
        assert!(*action.max_queue_size.borrow() > 0, EInvalidParameter);
    };
}