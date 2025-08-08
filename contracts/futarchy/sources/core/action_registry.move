/// Dynamic action registry for extensible DAO capabilities
/// Allows DAOs to register and manage custom actions via governance
module futarchy::action_registry;

// === Imports ===
use std::{
    string::{Self, String},
    type_name::{Self, TypeName},
    vector,
    option::{Self, Option},
};
use sui::{
    table::{Self, Table},
    object::ID,
    package::{Self, Publisher},
    event,
    clock::{Self, Clock},
};
use account_protocol::{
    account::{Self, Account},
    executable::Executable,
    version_witness::VersionWitness,
};
use futarchy::{
    version,
    futarchy_config::FutarchyConfig,
};

// === Errors ===
const EActionNotRegistered: u64 = 1;
const EActionDisabled: u64 = 2;
const EInvalidPublisher: u64 = 3;
const EActionAlreadyRegistered: u64 = 4;
const EInvalidFunctionSignature: u64 = 5;

// === Events ===

public struct ActionRegistered has copy, drop {
    dao_id: ID,
    action_type: String,
    package_id: ID,
    module_name: String,
    function_name: String,
    timestamp: u64,
}

public struct ActionStatusChanged has copy, drop {
    dao_id: ID,
    action_type: String,
    enabled: bool,
    timestamp: u64,
}

public struct ActionDeregistered has copy, drop {
    dao_id: ID,
    action_type: String,
    timestamp: u64,
}

// === Structs ===

/// Information about a single registered action
public struct ActionInfo has store, drop, copy {
    /// The package ID where the action logic resides
    package_id: ID,
    /// The module name containing the execution function
    module_name: String,
    /// The name of the execution function (must match standard signature)
    function_name: String,
    /// Whether this action is currently enabled
    is_enabled: bool,
    /// Optional publisher for verification (if required by DAO)
    publisher_id: Option<ID>,
    /// Registration timestamp
    registered_at: u64,
    /// Who registered this action
    registered_by: address,
}

/// The registry of all custom actions for a DAO
public struct ActionRegistry has store {
    /// Core mapping: TypeName of action struct -> ActionInfo
    registered_actions: Table<TypeName, ActionInfo>,
    /// Count of registered actions
    action_count: u64,
    /// Whether to require publisher verification for new actions
    require_publisher_verification: bool,
}

/// Key for storing the registry in Account's managed data
public struct ActionRegistryKey has copy, drop, store {}

// === Public Functions ===

/// Initialize a new action registry for a DAO
public fun new(require_publisher_verification: bool, ctx: &mut TxContext): ActionRegistry {
    ActionRegistry {
        registered_actions: table::new(ctx),
        action_count: 0,
        require_publisher_verification,
    }
}

/// Initialize registry in an account (called during DAO creation)
public fun init_registry(
    account: &mut Account<FutarchyConfig>,
    require_publisher_verification: bool,
    ctx: &mut TxContext,
) {
    let registry = new(require_publisher_verification, ctx);
    
    // Store in account's managed data
    account::add_managed_data(
        account,
        ActionRegistryKey {},
        registry,
        version::current(),
    );
}

/// Initialize registry for testing
#[test_only]
public fun init_registry_for_testing(
    account: &mut Account<FutarchyConfig>,
    require_publisher_verification: bool,
    ctx: &mut TxContext,
) {
    use account_protocol::version_witness;
    
    let registry = new(require_publisher_verification, ctx);
    
    account::add_managed_data(
        account,
        ActionRegistryKey {},
        registry,
        version_witness::new_for_testing(@account_protocol),
    );
}

/// Register a new action type
public fun register_action<ActionType: store>(
    account: &mut Account<FutarchyConfig>,
    package_id: ID,
    module_name: String,
    function_name: String,
    publisher_id: Option<ID>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let registry = borrow_registry_mut(account);
    let action_type = type_name::get<ActionType>();
    
    // Check if already registered
    assert!(
        !table::contains(&registry.registered_actions, action_type),
        EActionAlreadyRegistered
    );
    
    // If publisher verification is required, verify it
    if (registry.require_publisher_verification) {
        assert!(option::is_some(&publisher_id), EInvalidPublisher);
        // In production, would verify the publisher owns the package
        // This requires additional package introspection capabilities
    };
    
    let info = ActionInfo {
        package_id,
        module_name,
        function_name,
        is_enabled: true,
        publisher_id,
        registered_at: clock::timestamp_ms(clock),
        registered_by: tx_context::sender(ctx),
    };
    
    table::add(&mut registry.registered_actions, action_type, info);
    registry.action_count = registry.action_count + 1;
    
    event::emit(ActionRegistered {
        dao_id: object::id(account),
        action_type: type_name::into_string(action_type).to_string(),
        package_id,
        module_name,
        function_name,
        timestamp: clock::timestamp_ms(clock),
    });
}

/// Enable or disable an action
public fun set_action_status<ActionType: store>(
    account: &mut Account<FutarchyConfig>,
    enabled: bool,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let registry = borrow_registry_mut(account);
    let action_type = type_name::get<ActionType>();
    
    assert!(
        table::contains(&registry.registered_actions, action_type),
        EActionNotRegistered
    );
    
    let info = table::borrow_mut(&mut registry.registered_actions, action_type);
    info.is_enabled = enabled;
    
    event::emit(ActionStatusChanged {
        dao_id: object::id(account),
        action_type: type_name::into_string(action_type).to_string(),
        enabled,
        timestamp: clock::timestamp_ms(clock),
    });
}

/// Deregister an action completely
public fun deregister_action<ActionType: store>(
    account: &mut Account<FutarchyConfig>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let registry = borrow_registry_mut(account);
    let action_type = type_name::get<ActionType>();
    
    assert!(
        table::contains(&registry.registered_actions, action_type),
        EActionNotRegistered
    );
    
    table::remove(&mut registry.registered_actions, action_type);
    registry.action_count = registry.action_count - 1;
    
    event::emit(ActionDeregistered {
        dao_id: object::id(account),
        action_type: type_name::into_string(action_type).to_string(),
        timestamp: clock::timestamp_ms(clock),
    });
}

/// Check if an action is registered and enabled
public fun is_action_available(
    account: &Account<FutarchyConfig>,
    action_type: TypeName,
): bool {
    let registry = borrow_registry(account);
    
    if (!table::contains(&registry.registered_actions, action_type)) {
        return false
    };
    
    let info = table::borrow(&registry.registered_actions, action_type);
    info.is_enabled
}

/// Get action info for a specific type
public fun get_action_info(
    account: &Account<FutarchyConfig>,
    action_type: TypeName,
): Option<ActionInfo> {
    let registry = borrow_registry(account);
    
    if (!table::contains(&registry.registered_actions, action_type)) {
        return option::none()
    };
    
    option::some(*table::borrow(&registry.registered_actions, action_type))
}

/// Get the total number of registered actions
public fun action_count(account: &Account<FutarchyConfig>): u64 {
    let registry = borrow_registry(account);
    registry.action_count
}

// === Internal Functions ===

/// Borrow the registry from account's managed data
public fun borrow_registry(account: &Account<FutarchyConfig>): &ActionRegistry {
    account::borrow_managed_data(
        account,
        ActionRegistryKey {},
        version::current(),
    )
}

/// Borrow the registry mutably from account's managed data
fun borrow_registry_mut(account: &mut Account<FutarchyConfig>): &mut ActionRegistry {
    account::borrow_managed_data_mut(
        account,
        ActionRegistryKey {},
        version::current(),
    )
}

/// Get all registered action types
public fun get_registered_types(registry: &ActionRegistry): vector<TypeName> {
    // Note: In production, we'd need to iterate over the table
    // This is a simplified version
    vector::empty()
}

/// Check if an action is enabled from ActionInfo
public fun is_action_enabled(info: &ActionInfo): bool {
    info.is_enabled
}

/// Get package ID from ActionInfo
public fun get_package_id(info: &ActionInfo): ID {
    info.package_id
}

/// Get module name from ActionInfo
public fun get_module_name(info: &ActionInfo): String {
    info.module_name
}

/// Get function name from ActionInfo
public fun get_function_name(info: &ActionInfo): String {
    info.function_name
}

/// Register a native futarchy action (used during initialization)
public(package) fun register_native_action<ActionType: store>(
    account: &mut Account<FutarchyConfig>,
    module_name: String,
    function_name: String,
    ctx: &mut TxContext,
) {
    let registry = borrow_registry_mut(account);
    let action_type = type_name::get<ActionType>();
    
    // Native actions are always from the futarchy package
    let info = ActionInfo {
        package_id: object::id_from_address(@futarchy),
        module_name,
        function_name,
        is_enabled: true,
        publisher_id: option::none(),
        registered_at: 0, // Genesis registration
        registered_by: @futarchy,
    };
    
    table::add(&mut registry.registered_actions, action_type, info);
    registry.action_count = registry.action_count + 1;
}

/// Register a native action for testing
#[test_only]
public fun register_native_action_for_testing<ActionType: store>(
    account: &mut Account<FutarchyConfig>,
    module_name: String,
    function_name: String,
    ctx: &mut TxContext,
) {
    use account_protocol::version_witness;
    let registry: &mut ActionRegistry = account::borrow_managed_data_mut(
        account,
        ActionRegistryKey {},
        version_witness::new_for_testing(@account_protocol),
    );
    let action_type = type_name::get<ActionType>();
    
    let info = ActionInfo {
        package_id: object::id_from_address(@futarchy),
        module_name,
        function_name,
        is_enabled: true,
        publisher_id: option::none(),
        registered_at: 0,
        registered_by: @futarchy,
    };
    
    table::add(&mut registry.registered_actions, action_type, info);
    registry.action_count = registry.action_count + 1;
}