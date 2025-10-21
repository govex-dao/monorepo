// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

/// Decoder registry for access control actions
///
/// Lightweight decoder structs for UX validation.
/// BCS decoding happens off-chain in indexers.
module account_actions::access_control_decoder;

use account_actions::access_control::{BorrowAction, ReturnAction};
use account_protocol::schema::{Self as schema, ActionDecoderRegistry};
use std::type_name;
use sui::dynamic_object_field;
use sui::object::{Self, UID};

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
