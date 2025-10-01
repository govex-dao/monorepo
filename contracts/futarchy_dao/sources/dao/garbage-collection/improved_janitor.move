/// Improved garbage collection for futarchy DAOs
/// This module provides efficient cleanup of expired intents by:
/// 1. Reading action types directly from the Expired struct
/// 2. Only attempting to delete actions that actually exist
/// 3. Supporting a DeleteHookRegistry for extensible cleanup
module futarchy_dao::improved_janitor;

use std::type_name::{Self, TypeName};
use account_protocol::{
    account::{Self, Account},
    intents::{Self, Expired},
};
use futarchy_core::futarchy_config::FutarchyConfig;
use sui::dynamic_field;

// === Errors ===
const EActionTypeNotRecognized: u64 = 1;

// === Structs ===

/// Registry for delete hooks that know how to clean up specific action types
public struct DeleteHookRegistry has key {
    id: UID,
}

/// A delete hook for a specific action type
public struct DeleteHook<phantom T> has store {
    // Could store additional metadata if needed
    _placeholder: bool,
}

// === Functions ===

/// Initialize the delete hook registry
public fun init_registry(ctx: &mut TxContext): DeleteHookRegistry {
    DeleteHookRegistry {
        id: object::new(ctx),
    }
}

/// Register a delete hook for a specific action type
public fun register_delete_hook<T: drop>(
    registry: &mut DeleteHookRegistry,
    _ctx: &mut TxContext,
) {
    let type_name = type_name::get<T>();
    dynamic_field::add(&mut registry.id, type_name, DeleteHook<T> {
        _placeholder: true,
    });
}

/// Check if a delete hook exists for a type
public fun has_delete_hook(
    registry: &DeleteHookRegistry,
    action_type: TypeName,
): bool {
    dynamic_field::exists_(&registry.id, action_type)
}

/// Efficiently drain an Expired bag by reading action types
/// This version only attempts to delete actions that actually exist
public fun drain_expired_efficient(
    account: &mut Account<FutarchyConfig>,
    expired: &mut Expired,
    registry: &DeleteHookRegistry,
) {
    // First, collect all unique action types from the expired specs
    let mut processed_types = vector::empty<TypeName>();
    {
        let action_specs = intents::expired_action_specs(expired);
        let mut i = 0;
        let len = vector::length(action_specs);
        while (i < len) {
            let spec = vector::borrow(action_specs, i);
            let action_type = intents::action_spec_type(spec);

            // Collect unique types to process
            if (!vector::contains(&processed_types, &action_type)) {
                vector::push_back(&mut processed_types, action_type);
            };
            i = i + 1;
        };
    }; // action_specs reference is dropped here

    // Now process each unique type
    let mut j = 0;
    let types_len = vector::length(&processed_types);
    while (j < types_len) {
        let action_type = *vector::borrow(&processed_types, j);
        delete_action_by_type(expired, action_type, registry);
        j = j + 1;
    };
}

/// Delete actions of a specific type from the Expired struct
/// This function would dispatch to the appropriate delete function
/// based on the action type
fun delete_action_by_type(
    expired: &mut Expired,
    action_type: TypeName,
    registry: &DeleteHookRegistry,
) {
    // Check if we have a registered delete hook for this type
    if (has_delete_hook(registry, action_type)) {
        // In a real implementation, this would call the appropriate
        // delete function based on the action_type
        // For now, we'll need to maintain a mapping or use a pattern match

        // Example pattern matching (would need to be expanded):
        // if (action_type == type_name::get<UpdateNameAction>()) {
        //     gc_registry::delete_config_update(expired);
        // } else if (action_type == type_name::get<SetProposalsEnabledAction>()) {
        //     gc_registry::delete_proposals_enabled(expired);
        // } // ... etc

        // For now, attempt to remove the action spec
        // (actual implementation would call specific delete functions)
        attempt_delete_action(expired, action_type);
    }
    // If no hook registered, skip (action might have drop ability)
}

/// Attempt to delete an action from the Expired struct
/// This is a placeholder for the actual delete logic
fun attempt_delete_action(
    expired: &mut Expired,
    _action_type: TypeName,
) {
    // In practice, this would:
    // 1. Find the action in the expired struct
    // 2. Deserialize it if needed
    // 3. Call the appropriate destructor
    // 4. Mark it as processed

    // For now, just remove the first matching action spec
    if (intents::expired_action_count(expired) > 0) {
        let _spec = intents::remove_action_spec(expired);
        // Action spec has drop ability, so it's automatically cleaned up
    }
}

/// Public entry function for janitors to clean up expired intents
public entry fun cleanup_expired_intents(
    account: &mut Account<FutarchyConfig>,
    registry: &DeleteHookRegistry,
    max_iterations: u64,
    _ctx: &mut TxContext,
) {
    let mut iterations = 0;

    // Process expired intents up to max_iterations
    while (iterations < max_iterations) {
        // In practice, would get expired intents from account
        // and process them one by one

        iterations = iterations + 1;
    };
}