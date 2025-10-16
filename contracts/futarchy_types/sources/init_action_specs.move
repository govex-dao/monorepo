/// Action specification types for staging init actions
/// These are lightweight "blueprints" stored on Raise before DAO creation
/// GENERIC - doesn't know about specific action types
module futarchy_types::init_action_specs;

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

// === Equality Functions ===

/// Check if two ActionSpecs are equal
/// Compares both action_type and action_data
public fun action_spec_equals(a: &ActionSpec, b: &ActionSpec): bool {
    if (a.action_type != b.action_type) {
        return false
    };

    // Compare action_data vectors
    let a_data = &a.action_data;
    let b_data = &b.action_data;

    if (vector::length(a_data) != vector::length(b_data)) {
        return false
    };

    let mut i = 0;
    let len = vector::length(a_data);
    while (i < len) {
        if (*vector::borrow(a_data, i) != *vector::borrow(b_data, i)) {
            return false
        };
        i = i + 1;
    };

    true
}

/// Check if two InitActionSpecs are equal
/// Compares all actions in both specs
public fun init_action_specs_equals(a: &InitActionSpecs, b: &InitActionSpecs): bool {
    let a_actions = &a.actions;
    let b_actions = &b.actions;

    if (vector::length(a_actions) != vector::length(b_actions)) {
        return false
    };

    let mut i = 0;
    let len = vector::length(a_actions);
    while (i < len) {
        let a_spec = vector::borrow(a_actions, i);
        let b_spec = vector::borrow(b_actions, i);

        if (!action_spec_equals(a_spec, b_spec)) {
            return false
        };

        i = i + 1;
    };

    true
}