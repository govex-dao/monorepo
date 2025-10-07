/// Action specification types for staging init actions
/// These are lightweight "blueprints" stored on Raise before DAO creation
/// GENERIC - doesn't know about specific action types
module futarchy_types::action_specs;

use std::type_name::TypeName;

/// Generic action specification - can hold ANY action data
/// The action_type tells us how to interpret the action_data bytes
public struct ActionSpec has store, drop, copy {
    action_type: TypeName,      // Type of the action (e.g., CreateCouncilAction)
    action_data: vector<u8>,    // BCS-serialized action data
}

/// Container for all init action specifications
/// Completely generic - can hold any combination of actions
public struct InitActionSpecs has store, drop, copy {
    actions: vector<ActionSpec>,
}

// === Constructors ===

public fun new_action_spec(
    action_type: TypeName,
    action_data: vector<u8>
): ActionSpec {
    ActionSpec {
        action_type,
        action_data
    }
}

public fun new_init_specs(): InitActionSpecs {
    InitActionSpecs {
        actions: vector::empty(),
    }
}

/// Add a generic action specification
/// The caller is responsible for BCS-serializing the action data
public fun add_action(
    specs: &mut InitActionSpecs,
    action_type: TypeName,
    action_data: vector<u8>
) {
    vector::push_back(&mut specs.actions, ActionSpec {
        action_type,
        action_data,
    });
}

// === Accessors ===

public fun action_type(spec: &ActionSpec): TypeName {
    spec.action_type
}

public fun action_data(spec: &ActionSpec): &vector<u8> {
    &spec.action_data
}

public fun actions(specs: &InitActionSpecs): &vector<ActionSpec> {
    &specs.actions
}

public fun action_count(specs: &InitActionSpecs): u64 {
    vector::length(&specs.actions)
}

public fun get_action(specs: &InitActionSpecs, index: u64): &ActionSpec {
    vector::borrow(&specs.actions, index)
}