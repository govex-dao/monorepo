// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

/// Decoder for memo actions
module account_actions::memo_decoder;

use account_actions::memo::EmitMemoAction;
use account_protocol::schema::{Self as schema, ActionDecoderRegistry};
use std::type_name;
use sui::dynamic_object_field;
use sui::object::{Self, UID};

// === Decoder Objects ===

/// Decoder for EmitMemoAction
public struct MemoActionDecoder has key, store {
    id: UID,
}

// === Registration Functions ===

/// Register memo decoder
public fun register_decoders(registry: &mut ActionDecoderRegistry, ctx: &mut TxContext) {
    let decoder = MemoActionDecoder { id: object::new(ctx) };
    let type_key = type_name::with_defining_ids<EmitMemoAction>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}
