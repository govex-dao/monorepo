// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

/// Decoder for memo actions
module account_actions::memo_decoder;

use account_actions::memo::EmitMemoAction;
use account_protocol::bcs_validation;
use account_protocol::schema::{Self, ActionDecoderRegistry, HumanReadableField};
use std::type_name;
use sui::bcs;
use sui::dynamic_object_field;
use sui::object::{Self, UID};

// === Decoder Objects ===

/// Decoder for EmitMemoAction
public struct MemoActionDecoder has key, store {
    id: UID,
}

// === Decoder Functions ===

/// Decode an EmitMemoAction
public fun decode_memo_action(
    _decoder: &MemoActionDecoder,
    action_data: vector<u8>,
): vector<HumanReadableField> {
    // Deserialize the fields directly - DO NOT reconstruct the Action struct
    let mut bcs_data = bcs::new(action_data);
    let message = bcs::peel_vec_u8(&mut bcs_data).to_string();
    // BCS encodes Option as: 0x00 for None, 0x01 followed by value for Some
    let option_byte = bcs::peel_u8(&mut bcs_data);
    let reference_id = if (option_byte == 1) {
        bcs::peel_vec_u8(&mut bcs_data).to_string()
    } else {
        b"None".to_string()
    };

    // Security: ensure all bytes are consumed to prevent trailing data attacks
    bcs_validation::validate_all_bytes_consumed(bcs_data);

    vector[
        schema::new_field(
            b"message".to_string(),
            message,
            b"String".to_string(),
        ),
        schema::new_field(
            b"reference_id".to_string(),
            reference_id,
            b"Option<ID>".to_string(),
        ),
    ]
}

// === Registration Functions ===

/// Register memo decoder
public fun register_decoders(registry: &mut ActionDecoderRegistry, ctx: &mut TxContext) {
    let decoder = MemoActionDecoder { id: object::new(ctx) };
    let type_key = type_name::with_defining_ids<EmitMemoAction>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}
