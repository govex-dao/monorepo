// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

/// Decoder for transfer actions - tightly coupled with transfer action definitions
module account_actions::transfer_decoder;

use account_actions::transfer::{TransferAction, TransferToSenderAction};
use account_protocol::bcs_validation;
use account_protocol::schema::{Self, ActionDecoderRegistry, HumanReadableField};
use std::string::String;
use std::type_name;
use sui::bcs;
use sui::dynamic_object_field;
use sui::object::{Self, UID};

// === Imports ===

// === Decoder Objects ===

/// Decoder for TransferAction
public struct TransferActionDecoder has key, store {
    id: UID,
}

/// Decoder for TransferToSenderAction
public struct TransferToSenderActionDecoder has key, store {
    id: UID,
}

// === Decoder Functions ===

/// Decode a TransferAction
public fun decode_transfer_action(
    _decoder: &TransferActionDecoder,
    action_data: vector<u8>,
): vector<HumanReadableField> {
    // Deserialize the fields directly - DO NOT reconstruct the Action struct
    let mut bcs_data = bcs::new(action_data);
    let recipient = bcs::peel_address(&mut bcs_data);

    // Security: ensure all bytes are consumed to prevent trailing data attacks
    bcs_validation::validate_all_bytes_consumed(bcs_data);

    vector[
        schema::new_field(
            b"recipient".to_string(),
            recipient.to_string(),
            b"address".to_string(),
        ),
    ]
}

/// Decode a TransferToSenderAction
public fun decode_transfer_to_sender_action(
    _decoder: &TransferToSenderActionDecoder,
    _action_data: vector<u8>,
): vector<HumanReadableField> {
    // TransferToSenderAction is an empty struct with no fields to decode
    // We acknowledge the action_data exists but don't deserialize it

    // Return action type information
    vector[
        schema::new_field(
            b"action_type".to_string(),
            b"TransferToSenderAction".to_string(),
            b"String".to_string(),
        ),
    ]
}

// === Registration Functions ===

/// Register all transfer decoders
public fun register_decoders(registry: &mut ActionDecoderRegistry, ctx: &mut TxContext) {
    register_transfer_decoder(registry, ctx);
    register_transfer_to_sender_decoder(registry, ctx);
}

fun register_transfer_decoder(registry: &mut ActionDecoderRegistry, ctx: &mut TxContext) {
    let decoder = TransferActionDecoder { id: object::new(ctx) };
    let type_key = type_name::with_defining_ids<TransferAction>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}

fun register_transfer_to_sender_decoder(registry: &mut ActionDecoderRegistry, ctx: &mut TxContext) {
    let decoder = TransferToSenderActionDecoder { id: object::new(ctx) };
    let type_key = type_name::with_defining_ids<TransferToSenderAction>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}
