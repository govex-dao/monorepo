/// Registry for tracking recurring payment streams
/// This module provides proper integration between DAOs and payment streams
module futarchy::recurring_payment_registry;

// === Imports ===
use sui::{
    table::{Self, Table},
};
use futarchy::{
    dao::{Self, DAO},
};

// === Errors ===
const EUnauthorized: u64 = 0;
const ERegistryAlreadyExists: u64 = 1;

// === Structs ===

/// Registry that tracks all payment streams for a DAO
public struct PaymentStreamRegistry has key {
    id: UID,
    dao_id: ID,
    active_streams: Table<ID, bool>,
    active_count: u64,
}

// === Public Functions ===

/// Initialize a payment stream registry for a DAO
public fun init_registry(
    dao: &mut DAO,
    ctx: &mut TxContext,
): ID {
    let registry = PaymentStreamRegistry {
        id: object::new(ctx),
        dao_id: object::id(dao),
        active_streams: table::new(ctx),
        active_count: 0,
    };
    
    let registry_id = object::id(&registry);
    transfer::share_object(registry);
    registry_id
}

/// Add a stream to the registry
public fun add_stream(
    registry: &mut PaymentStreamRegistry,
    stream_id: ID,
) {
    if (!registry.active_streams.contains(stream_id)) {
        registry.active_streams.add(stream_id, true);
        registry.active_count = registry.active_count + 1;
    };
}

/// Remove a stream from the registry
public fun remove_stream(
    registry: &mut PaymentStreamRegistry,
    stream_id: ID,
) {
    if (registry.active_streams.contains(stream_id)) {
        registry.active_streams.remove(stream_id);
        if (registry.active_count > 0) {
            registry.active_count = registry.active_count - 1;
        };
    };
}

/// Check if a stream is tracked
public fun is_stream_tracked(
    registry: &PaymentStreamRegistry,
    stream_id: ID,
): bool {
    registry.active_streams.contains(stream_id)
}

/// Get the number of active streams
public fun get_active_count(registry: &PaymentStreamRegistry): u64 {
    registry.active_count
}

/// Get the DAO ID
public fun get_dao_id(registry: &PaymentStreamRegistry): ID {
    registry.dao_id
}

/// Verify registry belongs to DAO
public fun verify_dao_ownership(
    registry: &PaymentStreamRegistry,
    dao: &DAO,
) {
    assert!(registry.dao_id == object::id(dao), EUnauthorized);
}