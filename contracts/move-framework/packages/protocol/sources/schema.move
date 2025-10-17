// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

/// Registry and types for action decoder schemas.
module account_protocol::schema;

use std::string::String;
use std::type_name::TypeName;
use sui::dynamic_object_field;
use sui::object::{Self, UID};

// === Imports ===

// === Structs ===

/// A standard, human-readable representation of a single decoded field
public struct HumanReadableField has copy, drop, store {
    name: String, // Field name, e.g., "recipient"
    value: String, // String representation of value, e.g., "0xabc..."
    type_name: String, // Type description, e.g., "address"
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
public fun new_field(name: String, value: String, type_name: String): HumanReadableField {
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
public fun has_decoder(registry: &ActionDecoderRegistry, action_type: TypeName): bool {
    dynamic_object_field::exists_(registry_id(registry), action_type)
}

/// Assert that a decoder exists for the given action type
/// Aborts with EDecoderNotFound if the decoder is not registered
public fun assert_decoder_exists(registry: &ActionDecoderRegistry, action_type: TypeName) {
    assert!(has_decoder(registry, action_type), EDecoderNotFound);
}

// === Errors ===
const EDecoderNotFound: u64 = 1;
