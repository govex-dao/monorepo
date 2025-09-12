/// A shared registry for dynamically dispatching init actions.
/// It maps the TypeName of an action struct to the ID of the ActionHandler
/// object responsible for executing it.
module futarchy_actions::dispatcher_registry;

use std::type_name::TypeName;
use sui::object::{Self, UID, ID};
use sui::table::{Self, Table};
use sui::tx_context::TxContext;
use sui::transfer;
use futarchy_actions::action_handler_interface::ActionHandler;

/// The central registry object. This should be created once and shared globally.
public struct DispatcherRegistry has key {
    id: UID,
    handlers: Table<TypeName, ID>,
}

/// Capability to manage the registry.
public struct AdminCap has key, store {
    id: UID,
}

/// Initialize the registry and transfer the AdminCap to the deployer.
fun init(ctx: &mut TxContext) {
    transfer::transfer(AdminCap { id: object::new(ctx) }, ctx.sender());
    transfer::share_object(DispatcherRegistry {
        id: object::new(ctx),
        handlers: table::new(ctx),
    });
}

/// Register a new action handler.
/// This is typically called once per action type during protocol deployment.
public fun register_handler(
    registry: &mut DispatcherRegistry,
    _cap: &AdminCap,
    action_type: TypeName,
    handler: ActionHandler,
    ctx: &mut TxContext,
) {
    let handler_id = object::id(&handler);
    // The handler object is made a child of the registry for ownership clarity.
    sui::dynamic_object_field::add(&mut registry.id, handler_id, handler);
    table::add(&mut registry.handlers, action_type, handler_id);
}

/// Get the handler ID for a given action type.
public fun get_handler_id(registry: &DispatcherRegistry, action_type: &TypeName): ID {
    *table::borrow(&registry.handlers, *action_type)
}

/// Get the registry UID for borrowing child objects
public fun uid_mut(registry: &mut DispatcherRegistry): &mut UID {
    &mut registry.id
}