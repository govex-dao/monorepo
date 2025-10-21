// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

/// Decoder for transfer actions - tightly coupled with transfer action definitions
module account_actions::transfer_decoder;

use account_actions::transfer::{TransferAction, TransferToSenderAction};
use account_protocol::schema::{Self as schema, ActionDecoderRegistry};
use std::type_name;
use sui::dynamic_object_field;
use sui::object::{Self, UID};

// === Decoder Objects ===

/// Decoder for TransferAction
public struct TransferActionDecoder has key, store {
    id: UID,
}

/// Decoder for TransferToSenderAction
public struct TransferToSenderActionDecoder has key, store {
    id: UID,
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
