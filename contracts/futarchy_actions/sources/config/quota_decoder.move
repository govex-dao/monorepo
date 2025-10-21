// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

/// Decoder for quota management actions in futarchy DAOs
module futarchy_actions::quota_decoder;

use account_protocol::schema::{Self as schema, ActionDecoderRegistry};
use futarchy_actions::quota_actions::SetQuotasAction;
use std::type_name;
use sui::dynamic_object_field;
use sui::object::{Self, UID};

// === Decoder Object ===

/// Decoder for SetQuotasAction
public struct SetQuotasActionDecoder has key, store {
    id: UID,
}

// === Registration Functions ===

/// Register quota decoder
public fun register_decoders(registry: &mut ActionDecoderRegistry, ctx: &mut TxContext) {
    register_set_quotas_decoder(registry, ctx);
}

fun register_set_quotas_decoder(registry: &mut ActionDecoderRegistry, ctx: &mut TxContext) {
    let decoder = SetQuotasActionDecoder { id: object::new(ctx) };
    let type_key = type_name::with_defining_ids<SetQuotasAction>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}
