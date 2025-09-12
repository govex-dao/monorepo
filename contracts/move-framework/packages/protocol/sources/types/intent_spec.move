/// Generic intent specification for staging actions before execution
/// This lives in the framework to avoid circular dependencies
/// Application packages (like Futarchy) will interpret these specs
module account_protocol::intent_spec;

use std::string::String;
use std::type_name::{Self, TypeName};
use sui::object::{Self, UID};

// === Structs ===

/// A specification for creating an intent - can be stored and executed later
public struct IntentSpec has key, store {
    id: UID,
    /// Human-readable description of what this intent will do
    description: String,
    /// The staged action specifications
    actions: vector<ActionSpec>,
    /// Whether this intent requires voting (false for init actions)
    requires_voting: bool,
}

/// A specification for a single action within an intent
public struct ActionSpec has store, copy, drop {
    /// Type of the action for type-safe routing
    action_type: TypeName,
    /// Serialized action parameters (BCS encoded)
    action_data: vector<u8>,
}

// === Public Functions ===

/// Create a new intent specification
public fun new_intent_spec(
    description: String,
    actions: vector<ActionSpec>,
    requires_voting: bool,
    ctx: &mut TxContext,
): IntentSpec {
    IntentSpec {
        id: object::new(ctx),
        description,
        actions,
        requires_voting,
    }
}

/// Create a new action specification
public fun new_action_spec(
    action_type: TypeName,
    action_data: vector<u8>,
): ActionSpec {
    ActionSpec {
        action_type,
        action_data,
    }
}

/// Add an action to an existing intent spec
public fun add_action(
    spec: &mut IntentSpec,
    action: ActionSpec,
) {
    spec.actions.push_back(action);
}

// === Accessors ===

public fun description(spec: &IntentSpec): &String {
    &spec.description
}

public fun actions(spec: &IntentSpec): &vector<ActionSpec> {
    &spec.actions
}

public fun requires_voting(spec: &IntentSpec): bool {
    spec.requires_voting
}

public fun action_type(action: &ActionSpec): TypeName {
    action.action_type
}

public fun action_data(action: &ActionSpec): &vector<u8> {
    &action.action_data
}

// === Destructors ===

public fun destroy_intent_spec(spec: IntentSpec) {
    let IntentSpec { id, description: _, actions: _, requires_voting: _ } = spec;
    object::delete(id);
}