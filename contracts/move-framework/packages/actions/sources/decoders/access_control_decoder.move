// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

/// Decoder for access control actions - tightly coupled with access control action definitions
module account_actions::access_control_decoder;

use account_actions::access_control::{BorrowAction, ReturnAction};
use account_protocol::bcs_validation;
use account_protocol::schema::{Self, ActionDecoderRegistry, HumanReadableField};
use std::string::String;
use std::type_name;
use sui::bcs;
use sui::dynamic_object_field;
use sui::object::{Self, UID};

// === Imports ===

// === Decoder Objects ===

/// Decoder for BorrowAction<Cap>
public struct BorrowActionDecoder has key, store {
    id: UID,
}

/// Decoder for ReturnAction<Cap>
public struct ReturnActionDecoder has key, store {
    id: UID,
}

// === Placeholder for Generic Registration ===

/// Placeholder type for registering generic decoders
public struct CapPlaceholder has drop, store {}

// === Decoder Functions ===

/// Decode a BorrowAction
public fun decode_borrow_action<Cap>(
    _decoder: &BorrowActionDecoder,
    _action_data: vector<u8>,
): vector<HumanReadableField> {
    // BorrowAction is an empty struct with no fields to decode
    // We acknowledge the action_data exists but don't deserialize it

    // Return action type information
    vector[
        schema::new_field(
            b"action_type".to_string(),
            b"BorrowAction".to_string(),
            b"String".to_string(),
        ),
    ]
}

/// Decode a ReturnAction
public fun decode_return_action<Cap>(
    _decoder: &ReturnActionDecoder,
    _action_data: vector<u8>,
): vector<HumanReadableField> {
    // ReturnAction is an empty struct with no fields to decode
    // We acknowledge the action_data exists but don't deserialize it

    // Return action type information
    vector[
        schema::new_field(
            b"action_type".to_string(),
            b"ReturnAction".to_string(),
            b"String".to_string(),
        ),
    ]
}

// === Registration Functions ===

/// Register all access control decoders
public fun register_decoders(registry: &mut ActionDecoderRegistry, ctx: &mut TxContext) {
    register_borrow_decoder(registry, ctx);
    register_return_decoder(registry, ctx);
}

fun register_borrow_decoder(registry: &mut ActionDecoderRegistry, ctx: &mut TxContext) {
    let decoder = BorrowActionDecoder { id: object::new(ctx) };
    let type_key = type_name::with_defining_ids<BorrowAction<CapPlaceholder>>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}

fun register_return_decoder(registry: &mut ActionDecoderRegistry, ctx: &mut TxContext) {
    let decoder = ReturnActionDecoder { id: object::new(ctx) };
    let type_key = type_name::with_defining_ids<ReturnAction<CapPlaceholder>>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}
