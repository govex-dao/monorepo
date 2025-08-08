/// Governance actions for managing the ActionRegistry
/// Allows DAOs to register, enable/disable, and deregister custom actions
module futarchy::registry_actions;

// === Imports ===
use std::{
    string::{Self, String},
    option::Option,
};
use sui::{
    clock::Clock,
    object::ID,
    tx_context::TxContext,
};
use account_protocol::{
    account::{Self, Account},
    executable::Executable,
};
use futarchy::{
    version,
    futarchy_config::FutarchyConfig,
};

// === Errors ===
const EInvalidActionType: u64 = 1;
const EEmptyModuleName: u64 = 2;
const EEmptyFunctionName: u64 = 3;

// === Structs ===

/// Action to register a new custom action type
public struct RegisterActionAction has store {
    /// The TypeName of the action struct to register
    action_type_name: String,
    /// The package ID where the action logic resides
    package_id: ID,
    /// The module name containing the execution function
    module_name: String,
    /// The name of the execution function
    function_name: String,
    /// Optional publisher ID for verification
    publisher_id: Option<ID>,
}

/// Action to enable or disable an existing action
public struct SetActionStatusAction has store {
    /// The TypeName of the action to modify
    action_type_name: String,
    /// Whether to enable or disable the action
    enabled: bool,
}

/// Action to completely deregister an action
public struct DeregisterActionAction has store {
    /// The TypeName of the action to deregister
    action_type_name: String,
}

// === Public Functions ===

/// Create an action to register a new custom action type
public fun new_register_action(
    action_type_name: String,
    package_id: ID,
    module_name: String,
    function_name: String,
    publisher_id: Option<ID>,
): RegisterActionAction {
    assert!(string::length(&action_type_name) > 0, EInvalidActionType);
    assert!(string::length(&module_name) > 0, EEmptyModuleName);
    assert!(string::length(&function_name) > 0, EEmptyFunctionName);
    
    RegisterActionAction {
        action_type_name,
        package_id,
        module_name,
        function_name,
        publisher_id,
    }
}

/// Create an action to set the status of an existing action
public fun new_set_status_action(
    action_type_name: String,
    enabled: bool,
): SetActionStatusAction {
    assert!(string::length(&action_type_name) > 0, EInvalidActionType);
    
    SetActionStatusAction {
        action_type_name,
        enabled,
    }
}

/// Create an action to deregister an action
public fun new_deregister_action(
    action_type_name: String,
): DeregisterActionAction {
    assert!(string::length(&action_type_name) > 0, EInvalidActionType);
    
    DeregisterActionAction {
        action_type_name,
    }
}

// === Action Execution Functions ===

/// Execute a register action
public fun do_register_action<Outcome: store, IW: drop>(
    _executable: &mut Executable<Outcome>,
    _account: &mut Account<FutarchyConfig>,
    _witness: IW,
    _clock: &Clock,
    _ctx: &mut TxContext,
) {
    // Dynamic dispatch implementation pending
}

/// Execute a set status action
public fun do_set_action_status<Outcome: store, IW: drop>(
    _executable: &mut Executable<Outcome>,
    _account: &mut Account<FutarchyConfig>,
    _witness: IW,
    _clock: &Clock,
    _ctx: &mut TxContext,
) {
    // Dynamic dispatch implementation pending
}

/// Execute a deregister action
public fun do_deregister_action<Outcome: store, IW: drop>(
    _executable: &mut Executable<Outcome>,
    _account: &mut Account<FutarchyConfig>,
    _witness: IW,
    _clock: &Clock,
    _ctx: &mut TxContext,
) {
    // Dynamic dispatch implementation pending
}