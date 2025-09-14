// ============================================================================
// FORK ADDITION - On-Chain Schema System
// ============================================================================
// NEW FILE added to the fork for self-describing actions.
//
// PURPOSE:
// Provides the foundation for on-chain action decoding, ensuring all actions
// can be transparently decoded and displayed to users before execution.
//
// ARCHITECTURE:
// - ActionDecoderRegistry: Global shared object holding all decoders
// - HumanReadableField: Standard format for decoded field display
// - Decoder objects attached as dynamic fields keyed by TypeName
//
// KEY DESIGN PRINCIPLES:
// - Protocol layer provides structure, application layer provides decoders
// - Mandatory validation at application boundary (entry functions)
// - Clean separation - protocol remains unaware of specific decoders
// - Universal transparency through self-describing actions
// ============================================================================

/// Simple, elegant schema system with active decoder objects
/// Each action module provides its own decoder that knows how to decode its actions
module account_protocol::schema;

// === Imports ===

use std::{string::String, type_name::TypeName};
use sui::{object::{Self, UID}, dynamic_object_field};

// === Structs ===

/// A standard, human-readable representation of a single decoded field
public struct HumanReadableField has drop, store, copy {
    name: String,   // Field name, e.g., "recipient"
    value: String,  // String representation of value, e.g., "0xabc..."
    type_name: String,   // Type description, e.g., "address"
}

/// The registry that holds all decoder objects
/// Decoders are attached as dynamic object fields keyed by TypeName
public struct ActionDecoderRegistry has key, store {
    id: UID,
}

// === Public Functions ===

/// Initialize an empty decoder registry
public fun init_registry(ctx: &mut TxContext): ActionDecoderRegistry {
    ActionDecoderRegistry {
        id: object::new(ctx),
    }
}

/// Create a human-readable field
public fun new_field(
    name: String,
    value: String,
    type_name: String,
): HumanReadableField {
    HumanReadableField { name, value, type_name }
}

// === View Functions ===

/// Get the registry's ID (immutable reference)
public fun registry_id(registry: &ActionDecoderRegistry): &UID {
    &registry.id
}

/// Get the registry's ID (mutable reference for adding decoders)
public fun registry_id_mut(registry: &mut ActionDecoderRegistry): &mut UID {
    &mut registry.id
}

/// Get field name
public fun field_name(field: &HumanReadableField): &String {
    &field.name
}

/// Get field value
public fun field_value(field: &HumanReadableField): &String {
    &field.value
}

/// Get field type
public fun field_type(field: &HumanReadableField): &String {
    &field.type_name
}

/// Check if a decoder exists for the given action type in the registry
public fun has_decoder(
    registry: &ActionDecoderRegistry,
    action_type: TypeName,
): bool {
    dynamic_object_field::exists_(registry_id(registry), action_type)
}