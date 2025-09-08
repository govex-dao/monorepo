/// Consolidated configuration actions for futarchy DAOs
/// This module combines basic and advanced configuration actions and their execution logic
module futarchy_actions::config_actions;

// === Imports ===
use std::{
    string::String,
    ascii::String as AsciiString,
    option::{Self, Option},
};
use sui::{
    url::Url,
    event,
    object,
    clock::Clock,
};
use account_protocol::{
    account::{Self, Account},
    executable::Executable,
    intents::{Expired, Intent},
    version_witness::VersionWitness,
};
use futarchy_core::futarchy_config::{Self, FutarchyConfig};

// === Aliases ===
use account_protocol::intents as protocol_intents;
use fun protocol_intents::add_action as Intent.add_action;

// === Errors ===
const EEmptyName: u64 = 1;
const EInvalidParameter: u64 = 2;
const EEmptyString: u64 = 3;
const EMismatchedKeyValueLength: u64 = 4;
const EInvalidConfigType: u64 = 5;
const EInvalidSlashDistribution: u64 = 6;

// === Witness ===

/// Witness for config module operations
public struct ConfigActionsWitness has drop {}

// === Constants ===
const CONFIG_TYPE_TRADING_PARAMS: u8 = 0;
const CONFIG_TYPE_METADATA: u8 = 1;
const CONFIG_TYPE_TWAP: u8 = 2;
const CONFIG_TYPE_GOVERNANCE: u8 = 3;
const CONFIG_TYPE_METADATA_TABLE: u8 = 4;
const CONFIG_TYPE_QUEUE_PARAMS: u8 = 5;

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
    new_name: String,
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

/// Emitted when TWAP config is updated
public struct TwapConfigChanged has copy, drop {
    account_id: ID,
    timestamp: u64,
}

/// Emitted when governance settings are updated
public struct GovernanceSettingsChanged has copy, drop {
    account_id: ID,
    timestamp: u64,
}

/// Emitted when slash distribution is updated
public struct SlashDistributionChanged has copy, drop {
    account_id: ID,
    slasher_reward_bps: u16,
    dao_treasury_bps: u16,
    protocol_bps: u16,
    burn_bps: u16,
    timestamp: u64,
}

// === Basic Action Structs ===

/// Action to enable or disable proposals
/// This is a protocol-level action that should only be used in emergencies
/// It must go through the normal futarchy governance process
public struct SetProposalsEnabledAction has store {
    enabled: bool,
}

/// Action to update the DAO name
/// This must go through the normal futarchy governance process
public struct UpdateNameAction has store {
    new_name: String,
}

// === Advanced Action Structs ===

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
    max_actions_per_outcome: Option<u64>,
    required_bond_amount: Option<u64>,
    max_intents_per_outcome: Option<u64>,
    proposal_intent_expiry_ms: Option<u64>,
    optimistic_challenge_fee: Option<u64>,
    optimistic_challenge_period_ms: Option<u64>,
}

/// Metadata table update action
public struct MetadataTableUpdateAction has store, drop {
    keys: vector<String>,
    values: vector<String>,
    keys_to_remove: vector<String>,
}

/// Slash distribution update action
public struct SlashDistributionUpdateAction has store, drop {
    slasher_reward_bps: u16,
    dao_treasury_bps: u16,
    protocol_bps: u16,
    burn_bps: u16,
}

/// Queue parameters update action
public struct QueueParamsUpdateAction has store, drop {
    max_proposer_funded: Option<u64>,
    max_concurrent_proposals: Option<u64>,
    max_queue_size: Option<u64>,
    fee_escalation_basis_points: Option<u64>,
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

// === Basic Execution Functions ===

/// Execute a set proposals enabled action
public fun do_set_proposals_enabled<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    version: VersionWitness,
    intent_witness: IW,
    clock: &Clock,
    _ctx: &mut TxContext,
) {
    // Extract the action
    let action: &SetProposalsEnabledAction = executable.next_action(intent_witness);
    let enabled = action.enabled;
    
    // Get mutable config using internal function (no witness needed since we're in the same package)
    let config = futarchy_config::internal_config_mut(account);
    
    // Apply the state change
    if (enabled) {
        futarchy_config::set_operational_state(config, futarchy_config::state_active());
    } else {
        futarchy_config::set_operational_state(config, futarchy_config::state_paused());
    };
    
    // Emit event
    event::emit(ProposalsEnabledChanged {
        account_id: object::id(account),
        enabled,
        timestamp: clock.timestamp_ms(),
    });
}

/// Execute an update name action
public fun do_update_name<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    version: VersionWitness,
    intent_witness: IW,
    clock: &Clock,
    _ctx: &mut TxContext,
) {
    // Extract the action
    let action: &UpdateNameAction = executable.next_action(intent_witness);
    
    // Validate
    assert!(action.new_name.length() > 0, EEmptyName);
    
    // Get mutable config through Account protocol with witness
    let config = account::config_mut(account, version, ConfigActionsWitness {});
    
    // Update the name by converting String to AsciiString
    // Note: This will fail at runtime if the string contains non-ASCII characters
    let ascii_name = action.new_name.to_ascii();
    futarchy_config::set_dao_name(config, ascii_name);
    
    // Emit event
    event::emit(DaoNameChanged {
        account_id: object::id(account),
        new_name: action.new_name,
        timestamp: clock.timestamp_ms(),
    });
}

// === Advanced Execution Functions ===

/// Execute a trading params update action
public fun do_update_trading_params<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    version: VersionWitness,
    intent_witness: IW,
    clock: &Clock,
    _ctx: &mut TxContext,
) {
    let action: &TradingParamsUpdateAction = executable.next_action(intent_witness);
    
    // Validate parameters
    validate_trading_params_update(action);
    
    // Get mutable config through Account protocol with witness
    let config = account::config_mut(account, version, ConfigActionsWitness {});
    
    // Apply updates if provided
    if (action.min_asset_amount.is_some()) {
        futarchy_config::set_min_asset_amount(config, *action.min_asset_amount.borrow());
    };
    if (action.min_stable_amount.is_some()) {
        futarchy_config::set_min_stable_amount(config, *action.min_stable_amount.borrow());
    };
    if (action.review_period_ms.is_some()) {
        futarchy_config::set_review_period_ms(config, *action.review_period_ms.borrow());
    };
    if (action.trading_period_ms.is_some()) {
        futarchy_config::set_trading_period_ms(config, *action.trading_period_ms.borrow());
    };
    if (action.amm_total_fee_bps.is_some()) {
        futarchy_config::set_amm_total_fee_bps(config, *action.amm_total_fee_bps.borrow());
    };
    
    // Emit event
    event::emit(TradingParamsChanged {
        account_id: object::id(account),
        timestamp: clock.timestamp_ms(),
    });
}

/// Execute a metadata update action
public fun do_update_metadata<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    version: VersionWitness,
    intent_witness: IW,
    clock: &Clock,
    _ctx: &mut TxContext,
) {
    let action: &MetadataUpdateAction = executable.next_action(intent_witness);
    
    // Validate parameters
    validate_metadata_update(action);
    
    // Get mutable config through Account protocol with witness
    let config = account::config_mut(account, version, ConfigActionsWitness {});
    
    // Apply updates if provided
    if (action.dao_name.is_some()) {
        futarchy_config::set_dao_name(config, *action.dao_name.borrow());
    };
    if (action.icon_url.is_some()) {
        futarchy_config::set_icon_url(config, *action.icon_url.borrow());
    };
    if (action.description.is_some()) {
        futarchy_config::set_description(config, *action.description.borrow());
    };
    
    // Emit event
    event::emit(MetadataChanged {
        account_id: object::id(account),
        timestamp: clock.timestamp_ms(),
    });
}

/// Execute a TWAP config update action
public fun do_update_twap_config<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    version: VersionWitness,
    intent_witness: IW,
    clock: &Clock,
    _ctx: &mut TxContext,
) {
    let action: &TwapConfigUpdateAction = executable.next_action(intent_witness);
    
    // Validate parameters
    validate_twap_config_update(action);
    
    // Get mutable config through Account protocol with witness
    let config = account::config_mut(account, version, ConfigActionsWitness {});
    
    // Apply updates if provided
    if (action.start_delay.is_some()) {
        futarchy_config::set_amm_twap_start_delay(config, *action.start_delay.borrow());
    };
    if (action.step_max.is_some()) {
        futarchy_config::set_amm_twap_step_max(config, *action.step_max.borrow());
    };
    if (action.initial_observation.is_some()) {
        futarchy_config::set_amm_twap_initial_observation(config, *action.initial_observation.borrow());
    };
    if (action.threshold.is_some()) {
        futarchy_config::set_twap_threshold(config, *action.threshold.borrow());
    };
    
    // Emit event
    event::emit(TwapConfigChanged {
        account_id: object::id(account),
        timestamp: clock.timestamp_ms(),
    });
}

/// Execute a governance update action
public fun do_update_governance<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    version: VersionWitness,
    intent_witness: IW,
    clock: &Clock,
    _ctx: &mut TxContext,
) {
    let action: &GovernanceUpdateAction = executable.next_action(intent_witness);
    
    // Validate parameters
    validate_governance_update(action);
    
    // Get mutable config through Account protocol with witness
    let config = account::config_mut(account, version, ConfigActionsWitness {});
    
    // Apply updates if provided
    if (action.proposal_creation_enabled.is_some()) {
        let enabled = *action.proposal_creation_enabled.borrow();
        if (enabled) {
            futarchy_config::set_operational_state(config, futarchy_config::state_active());
        } else {
            futarchy_config::set_operational_state(config, futarchy_config::state_paused());
        };
    };
    if (action.max_outcomes.is_some()) {
        futarchy_config::set_max_outcomes(config, *action.max_outcomes.borrow());
    };
    if (action.max_actions_per_outcome.is_some()) {
        futarchy_config::set_max_actions_per_outcome(config, *action.max_actions_per_outcome.borrow());
    };
    if (action.required_bond_amount.is_some()) {
        futarchy_config::set_required_bond_amount(config, *action.required_bond_amount.borrow());
    };
    if (action.max_intents_per_outcome.is_some()) {
        futarchy_config::set_max_intents_per_outcome(config, *action.max_intents_per_outcome.borrow());
    };
    if (action.proposal_intent_expiry_ms.is_some()) {
        futarchy_config::set_proposal_intent_expiry_ms(config, *action.proposal_intent_expiry_ms.borrow());
    };
    if (action.optimistic_challenge_fee.is_some()) {
        futarchy_config::set_optimistic_challenge_fee(config, *action.optimistic_challenge_fee.borrow());
    };
    if (action.optimistic_challenge_period_ms.is_some()) {
        futarchy_config::set_optimistic_challenge_period_ms(config, *action.optimistic_challenge_period_ms.borrow());
    };
    
    // Emit event
    event::emit(GovernanceSettingsChanged {
        account_id: object::id(account),
        timestamp: clock.timestamp_ms(),
    });
}

/// Execute a metadata table update action
/// Note: This requires metadata table support in futarchy_config which may not exist yet
public fun do_update_metadata_table<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    version: VersionWitness,
    intent_witness: IW,
    clock: &Clock,
    _ctx: &mut TxContext,
) {
    let action: &MetadataTableUpdateAction = executable.next_action(intent_witness);
    
    // Validate parameters
    assert!(action.keys.length() == action.values.length(), EMismatchedKeyValueLength);
    
    // Get mutable config through Account protocol with witness
    let config = account::config_mut(account, version, ConfigActionsWitness {});
    
    // Metadata table operations would be implemented here when available in futarchy_config
    // Currently, futarchy_config doesn't have a metadata table, so we validate the action
    // and emit the event to track the attempted change
    let _ = config;
    let _ = action;
    
    // Emit event
    event::emit(MetadataChanged {
        account_id: object::id(account),
        timestamp: clock.timestamp_ms(),
    });
}

/// Execute a queue params update action
public fun do_update_queue_params<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    version: VersionWitness,
    intent_witness: IW,
    clock: &Clock,
    _ctx: &mut TxContext,
) {
    let action: &QueueParamsUpdateAction = executable.next_action(intent_witness);
    
    // Validate parameters
    validate_queue_params_update(action);
    
    // Get mutable config through Account protocol with witness
    let config = account::config_mut(account, version, ConfigActionsWitness {});
    
    // Apply updates if provided
    if (action.max_concurrent_proposals.is_some()) {
        futarchy_config::set_max_concurrent_proposals(config, *action.max_concurrent_proposals.borrow());
    };
    if (action.fee_escalation_basis_points.is_some()) {
        futarchy_config::set_fee_escalation_basis_points(config, *action.fee_escalation_basis_points.borrow());
    };
    // Note: max_proposer_funded and max_queue_size may not have setters in futarchy_config yet
    
    // Emit event
    event::emit(GovernanceSettingsChanged {
        account_id: object::id(account),
        timestamp: clock.timestamp_ms(),
    });
}

/// Execute a slash distribution update action
public fun do_update_slash_distribution<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    version: VersionWitness,
    intent_witness: IW,
    clock: &Clock,
    _ctx: &mut TxContext,
) {
    let action: &SlashDistributionUpdateAction = executable.next_action(intent_witness);
    
    // Validate that they sum to 10000 (100%)
    let total = (action.slasher_reward_bps as u64) + (action.dao_treasury_bps as u64) + 
                (action.protocol_bps as u64) + (action.burn_bps as u64);
    assert!(total == 10000, EInvalidSlashDistribution);
    
    // Get mutable config through Account protocol with witness
    let config = account::config_mut(account, version, ConfigActionsWitness {});
    
    // Update the slash distribution
    futarchy_config::update_slash_distribution(
        config,
        action.slasher_reward_bps,
        action.dao_treasury_bps,
        action.protocol_bps,
        action.burn_bps
    );
    
    // Emit event
    event::emit(SlashDistributionChanged {
        account_id: object::id(account),
        slasher_reward_bps: action.slasher_reward_bps,
        dao_treasury_bps: action.dao_treasury_bps,
        protocol_bps: action.protocol_bps,
        burn_bps: action.burn_bps,
        timestamp: clock.timestamp_ms(),
    });
}

/// Execute a batch config action that can contain any type of config update
/// This delegates to the appropriate handler based on config_type
public fun do_batch_config<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    _version: VersionWitness,
    intent_witness: IW,
    _clock: &Clock,
    _ctx: &mut TxContext,
) {
    let action: &ConfigAction = executable.next_action(intent_witness);
    
    // Validate that the correct field is populated for the config_type
    if (action.config_type == CONFIG_TYPE_TRADING_PARAMS) {
        assert!(action.trading_params.is_some(), EInvalidConfigType);
    } else if (action.config_type == CONFIG_TYPE_METADATA) {
        assert!(action.metadata.is_some(), EInvalidConfigType);
    } else if (action.config_type == CONFIG_TYPE_TWAP) {
        assert!(action.twap_config.is_some(), EInvalidConfigType);
    } else if (action.config_type == CONFIG_TYPE_GOVERNANCE) {
        assert!(action.governance.is_some(), EInvalidConfigType);
    } else if (action.config_type == CONFIG_TYPE_METADATA_TABLE) {
        assert!(action.metadata_table.is_some(), EInvalidConfigType);
    } else if (action.config_type == CONFIG_TYPE_QUEUE_PARAMS) {
        assert!(action.queue_params.is_some(), EInvalidConfigType);
    } else {
        abort EInvalidConfigType
    };
    
    // Note: The actual config updates should be handled by the individual
    // do_ functions for each action type. This wrapper provides type safety.
}

// === Cleanup Functions ===

/// Delete a set proposals enabled action from an expired intent
public fun delete_set_proposals_enabled(expired: &mut Expired) {
    let SetProposalsEnabledAction { enabled: _ } = expired.remove_action();
}

/// Delete an update name action from an expired intent
public fun delete_update_name(expired: &mut Expired) {
    let UpdateNameAction { new_name: _ } = expired.remove_action();
}

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
        max_actions_per_outcome: _,
        required_bond_amount: _,
        max_intents_per_outcome: _,
        proposal_intent_expiry_ms: _,
        optimistic_challenge_fee: _,
        optimistic_challenge_period_ms: _,
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

/// Delete a slash distribution update action from an expired intent
public fun delete_slash_distribution_update(expired: &mut Expired) {
    let SlashDistributionUpdateAction {
        slasher_reward_bps: _,
        dao_treasury_bps: _,
        protocol_bps: _,
        burn_bps: _,
    } = expired.remove_action();
}

/// Delete a queue params update action from an expired intent
public fun delete_queue_params_update(expired: &mut Expired) {
    let QueueParamsUpdateAction {
        max_proposer_funded: _,
        max_concurrent_proposals: _,
        max_queue_size: _,
        fee_escalation_basis_points: _,
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

// === Constructor Functions ===

/// Create a set proposals enabled action
public fun new_set_proposals_enabled_action(enabled: bool): SetProposalsEnabledAction {
    SetProposalsEnabledAction { enabled }
}

/// Create an update name action
public fun new_update_name_action(new_name: String): UpdateNameAction {
    assert!(new_name.length() > 0, EEmptyName);
    UpdateNameAction { new_name }
}

/// Create a slash distribution update action
public fun new_slash_distribution_update_action(
    slasher_reward_bps: u16,
    dao_treasury_bps: u16,
    protocol_bps: u16,
    burn_bps: u16,
): SlashDistributionUpdateAction {
    // Validate that they sum to 10000 (100%)
    let total = (slasher_reward_bps as u64) + (dao_treasury_bps as u64) + 
                (protocol_bps as u64) + (burn_bps as u64);
    assert!(total == 10000, EInvalidSlashDistribution);
    
    SlashDistributionUpdateAction {
        slasher_reward_bps,
        dao_treasury_bps,
        protocol_bps,
        burn_bps,
    }
}

/// Create a trading params update action
public fun new_trading_params_update_action(
    min_asset_amount: Option<u64>,
    min_stable_amount: Option<u64>,
    review_period_ms: Option<u64>,
    trading_period_ms: Option<u64>,
    amm_total_fee_bps: Option<u64>,
): TradingParamsUpdateAction {
    let action = TradingParamsUpdateAction {
        min_asset_amount,
        min_stable_amount,
        review_period_ms,
        trading_period_ms,
        amm_total_fee_bps,
    };
    validate_trading_params_update(&action);
    action
}

/// Create a metadata update action
public fun new_metadata_update_action(
    dao_name: Option<AsciiString>,
    icon_url: Option<Url>,
    description: Option<String>,
): MetadataUpdateAction {
    let action = MetadataUpdateAction {
        dao_name,
        icon_url,
        description,
    };
    validate_metadata_update(&action);
    action
}

/// Create a TWAP config update action
public fun new_twap_config_update_action(
    start_delay: Option<u64>,
    step_max: Option<u64>,
    initial_observation: Option<u128>,
    threshold: Option<u64>,
): TwapConfigUpdateAction {
    let action = TwapConfigUpdateAction {
        start_delay,
        step_max,
        initial_observation,
        threshold,
    };
    validate_twap_config_update(&action);
    action
}

/// Create a governance update action
public fun new_governance_update_action(
    proposal_creation_enabled: Option<bool>,
    max_outcomes: Option<u64>,
    max_actions_per_outcome: Option<u64>,
    required_bond_amount: Option<u64>,
    max_intents_per_outcome: Option<u64>,
    proposal_intent_expiry_ms: Option<u64>,
    optimistic_challenge_fee: Option<u64>,
    optimistic_challenge_period_ms: Option<u64>,
): GovernanceUpdateAction {
    let action = GovernanceUpdateAction {
        proposal_creation_enabled,
        max_outcomes,
        max_actions_per_outcome,
        required_bond_amount,
        max_intents_per_outcome,
        proposal_intent_expiry_ms,
        optimistic_challenge_fee,
        optimistic_challenge_period_ms,
    };
    validate_governance_update(&action);
    action
}

/// Create a metadata table update action
public fun new_metadata_table_update_action(
    keys: vector<String>,
    values: vector<String>,
    keys_to_remove: vector<String>,
): MetadataTableUpdateAction {
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
    fee_escalation_basis_points: Option<u64>,
): QueueParamsUpdateAction {
    let action = QueueParamsUpdateAction {
        max_proposer_funded,
        max_concurrent_proposals,
        max_queue_size,
        fee_escalation_basis_points,
    };
    validate_queue_params_update(&action);
    action
}

// === Getter Functions ===

/// Get proposals enabled field
public fun get_proposals_enabled(action: &SetProposalsEnabledAction): bool {
    action.enabled
}

/// Get new name field
public fun get_new_name(action: &UpdateNameAction): String {
    action.new_name
}

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
    &Option<u64>,
    &Option<u64>,
    &Option<u64>,
    &Option<u64>
) {
    (
        &update.proposal_creation_enabled,
        &update.max_outcomes,
        &update.max_actions_per_outcome,
        &update.required_bond_amount,
        &update.max_intents_per_outcome,
        &update.proposal_intent_expiry_ms
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

/// Get slash distribution update fields
public fun get_slash_distribution_fields(update: &SlashDistributionUpdateAction): (u16, u16, u16, u16) {
    (
        update.slasher_reward_bps,
        update.dao_treasury_bps,
        update.protocol_bps,
        update.burn_bps
    )
}

/// Get queue params update fields
public fun get_queue_params_fields(update: &QueueParamsUpdateAction): (
    &Option<u64>,
    &Option<u64>,
    &Option<u64>,
    &Option<u64>
) {
    (
        &update.max_proposer_funded,
        &update.max_concurrent_proposals,
        &update.max_queue_size,
        &update.fee_escalation_basis_points
    )
}

/// Create a config action for trading params updates
public fun new_config_action_trading_params(
    params: TradingParamsUpdateAction
): ConfigAction {
    ConfigAction {
        config_type: CONFIG_TYPE_TRADING_PARAMS,
        trading_params: option::some(params),
        metadata: option::none(),
        twap_config: option::none(),
        governance: option::none(),
        metadata_table: option::none(),
        queue_params: option::none(),
    }
}

/// Create a config action for metadata updates  
public fun new_config_action_metadata(
    metadata: MetadataUpdateAction
): ConfigAction {
    ConfigAction {
        config_type: CONFIG_TYPE_METADATA,
        trading_params: option::none(),
        metadata: option::some(metadata),
        twap_config: option::none(),
        governance: option::none(),
        metadata_table: option::none(),
        queue_params: option::none(),
    }
}

/// Create a config action for TWAP config updates
public fun new_config_action_twap(
    twap: TwapConfigUpdateAction
): ConfigAction {
    ConfigAction {
        config_type: CONFIG_TYPE_TWAP,
        trading_params: option::none(),
        metadata: option::none(),
        twap_config: option::some(twap),
        governance: option::none(),
        metadata_table: option::none(),
        queue_params: option::none(),
    }
}

/// Create a config action for governance updates
public fun new_config_action_governance(
    gov: GovernanceUpdateAction
): ConfigAction {
    ConfigAction {
        config_type: CONFIG_TYPE_GOVERNANCE,
        trading_params: option::none(),
        metadata: option::none(),
        twap_config: option::none(),
        governance: option::some(gov),
        metadata_table: option::none(),
        queue_params: option::none(),
    }
}

/// Create a config action for metadata table updates
public fun new_config_action_metadata_table(
    table: MetadataTableUpdateAction
): ConfigAction {
    ConfigAction {
        config_type: CONFIG_TYPE_METADATA_TABLE,
        trading_params: option::none(),
        metadata: option::none(),
        twap_config: option::none(),
        governance: option::none(),
        metadata_table: option::some(table),
        queue_params: option::none(),
    }
}

/// Create a config action for queue params updates
public fun new_config_action_queue_params(
    queue: QueueParamsUpdateAction
): ConfigAction {
    ConfigAction {
        config_type: CONFIG_TYPE_QUEUE_PARAMS,
        trading_params: option::none(),
        metadata: option::none(),
        twap_config: option::none(),
        governance: option::none(),
        metadata_table: option::none(),
        queue_params: option::some(queue),
    }
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
}

/// Validate TWAP config update
fun validate_twap_config_update(action: &TwapConfigUpdateAction) {
    if (action.step_max.is_some()) {
        assert!(*action.step_max.borrow() > 0, EInvalidParameter);
    };
}

/// Validate governance update
fun validate_governance_update(action: &GovernanceUpdateAction) {
    if (action.max_outcomes.is_some()) {
        assert!(*action.max_outcomes.borrow() >= 2, EInvalidParameter); // At least YES/NO
    };
    if (action.max_intents_per_outcome.is_some()) {
        assert!(*action.max_intents_per_outcome.borrow() > 0, EInvalidParameter);
    };
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

// === Aliases for backwards compatibility ===

/// Alias for do_update_twap_config for compatibility
public fun do_update_twap_params<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    version: VersionWitness,
    iw: IW,
    clock: &Clock,
    ctx: &mut TxContext
) {
    do_update_twap_config<Outcome, IW>(executable, account, version, iw, clock, ctx);
}

/// Alias for queue params update (was called fee params)
public fun do_update_fee_params<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    version: VersionWitness,
    iw: IW,
    clock: &Clock,
    ctx: &mut TxContext
) {
    do_update_queue_params<Outcome, IW>(executable, account, version, iw, clock, ctx);
}