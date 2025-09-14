/// Config actions with PTB-compatible do_* functions
/// This replaces the dispatcher pattern with direct callable functions
module futarchy_actions::config_actions_ptb;

// === Imports ===
use std::string::String;
use account_protocol::{
    account::{Self, Account},
    executable::{Self, Executable},
    intents,
    bcs_validation,
};
use futarchy_core::futarchy_config::{Self, FutarchyConfig, DaoStateKey, DaoState};
use sui::{dynamic_field, clock::Clock};

// === Action Structs ===

/// Action to update the DAO name
public struct UpdateNameAction has store, drop, copy {
    new_name: String,
}

/// Action to update trading parameters
public struct UpdateTradingParamsAction has store, drop, copy {
    min_asset_amount: u64,
    min_stable_amount: u64,
    review_period_ms: u64,
    trading_period_ms: u64,
}

/// Action to enable/disable proposals
public struct SetProposalsEnabledAction has store, drop, copy {
    enabled: bool,
}

// === Constructors ===

public fun new_update_name_action(new_name: String): UpdateNameAction {
    UpdateNameAction { new_name }
}

public fun new_update_trading_params_action(
    min_asset_amount: u64,
    min_stable_amount: u64,
    review_period_ms: u64,
    trading_period_ms: u64,
): UpdateTradingParamsAction {
    UpdateTradingParamsAction {
        min_asset_amount,
        min_stable_amount,
        review_period_ms,
        trading_period_ms,
    }
}

public fun new_set_proposals_enabled_action(enabled: bool): SetProposalsEnabledAction {
    SetProposalsEnabledAction { enabled }
}

// === PTB-Compatible Execution Functions ===

/// Execute UpdateNameAction - callable directly from PTB
public fun do_update_name(
    executable: &mut Executable,
    account: &mut Account<FutarchyConfig>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Verify this is the current action
    assert!(executable::is_current_action<UpdateNameAction>(executable), 0);

    // Get and deserialize the action
    let action_data = executable::get_current_action_data(executable);
    let action = bcs::from_bytes<UpdateNameAction>(action_data);

    // Execute the action logic
    let mut dao_state = dynamic_field::borrow_mut<DaoStateKey, DaoState>(
        account::uid_mut(account),
        DaoStateKey {},
    );

    // Update the name in config
    let config = account::config_mut(account);
    let new_config = futarchy_config::with_name(*config, action.new_name);
    *config = new_config;

    // Emit event
    emit_name_updated_event(account, action.new_name, clock);

    // Mark action as executed
    executable::mark_current_executed(executable);
}

/// Execute UpdateTradingParamsAction - callable directly from PTB
public fun do_update_trading_params(
    executable: &mut Executable,
    account: &mut Account<FutarchyConfig>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Verify this is the current action
    assert!(executable::is_current_action<UpdateTradingParamsAction>(executable), 0);

    // Get and deserialize the action
    let action_data = executable::get_current_action_data(executable);
    let action = bcs::from_bytes<UpdateTradingParamsAction>(action_data);

    // Execute the action logic
    let config = account::config_mut(account);
    let new_config = futarchy_config::with_trading_params(
        *config,
        action.min_asset_amount,
        action.min_stable_amount,
        action.review_period_ms,
        action.trading_period_ms,
    );
    *config = new_config;

    // Emit event
    emit_trading_params_updated_event(account, clock);

    // Mark action as executed
    executable::mark_current_executed(executable);
}

/// Execute SetProposalsEnabledAction - callable directly from PTB
public fun do_set_proposals_enabled(
    executable: &mut Executable,
    account: &mut Account<FutarchyConfig>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Verify this is the current action
    assert!(executable::is_current_action<SetProposalsEnabledAction>(executable), 0);

    // Get and deserialize the action
    let action_data = executable::get_current_action_data(executable);
    let action = bcs::from_bytes<SetProposalsEnabledAction>(action_data);

    // Execute the action logic
    let mut dao_state = dynamic_field::borrow_mut<DaoStateKey, DaoState>(
        account::uid_mut(account),
        DaoStateKey {},
    );

    futarchy_config::set_proposals_enabled(dao_state, action.enabled);

    // Emit event
    emit_proposals_enabled_changed_event(account, action.enabled, clock);

    // Mark action as executed
    executable::mark_current_executed(executable);
}

// === Helper Functions ===

fun emit_name_updated_event(
    account: &Account<FutarchyConfig>,
    new_name: String,
    clock: &Clock,
) {
    // Event emission logic
}

fun emit_trading_params_updated_event(
    account: &Account<FutarchyConfig>,
    clock: &Clock,
) {
    // Event emission logic
}

fun emit_proposals_enabled_changed_event(
    account: &Account<FutarchyConfig>,
    enabled: bool,
    clock: &Clock,
) {
    // Event emission logic
}

// === Destruction Functions (for serialize-then-destroy pattern) ===

public fun destroy_update_name_action(action: UpdateNameAction) {
    let UpdateNameAction { new_name: _ } = action;
}

public fun destroy_update_trading_params_action(action: UpdateTradingParamsAction) {
    let UpdateTradingParamsAction {
        min_asset_amount: _,
        min_stable_amount: _,
        review_period_ms: _,
        trading_period_ms: _,
    } = action;
}

public fun destroy_set_proposals_enabled_action(action: SetProposalsEnabledAction) {
    let SetProposalsEnabledAction { enabled: _ } = action;
}