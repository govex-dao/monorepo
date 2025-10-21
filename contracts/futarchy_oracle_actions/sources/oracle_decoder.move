// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

/// Decoder for oracle grant actions
module futarchy_oracle::oracle_decoder;

use account_protocol::schema::{Self as schema, ActionDecoderRegistry};use futarchy_oracle::oracle_actions::{
    CreateOracleGrantAction,
    CancelGrantAction,
    EmergencyFreezeGrantAction,
    EmergencyUnfreezeGrantAction,
};
use std::type_name;
use sui::bcs;
use sui::tx_context;

// === Decoder Objects ===

public struct CreateOracleGrantActionDecoder has key, store {
    id: UID,
}

public struct CancelGrantActionDecoder has key, store {
    id: UID,
}

public struct EmergencyFreezeGrantActionDecoder has key, store {
    id: UID,
}

public struct EmergencyUnfreezeGrantActionDecoder has key, store {
    id: UID,
}

// === Decoder Functions ===

/// Decode CreateOracleGrantAction
#[allow(unused_type_parameter)]
    registry: &mut ActionDecoderRegistry,
    ctx: &mut tx_context::TxContext,
) {
    register_create_oracle_grant_decoder<AssetType, StableType>(registry, ctx);
    register_cancel_grant_decoder(registry, ctx);
    register_emergency_freeze_grant_decoder(registry, ctx);
    register_emergency_unfreeze_grant_decoder(registry, ctx);
}

fun register_create_oracle_grant_decoder<AssetType, StableType>(
    registry: &mut ActionDecoderRegistry,
    ctx: &mut tx_context::TxContext,
) {
    let decoder = CreateOracleGrantActionDecoder { id: object::new(ctx) };
    let type_key = type_name::with_defining_ids<CreateOracleGrantAction<AssetType, StableType>>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}

fun register_cancel_grant_decoder(registry: &mut ActionDecoderRegistry, ctx: &mut tx_context::TxContext) {
    let decoder = CancelGrantActionDecoder { id: object::new(ctx) };
    let type_key = type_name::with_defining_ids<CancelGrantAction>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}

fun register_emergency_freeze_grant_decoder(
    registry: &mut ActionDecoderRegistry,
    ctx: &mut tx_context::TxContext,
) {
    let decoder = EmergencyFreezeGrantActionDecoder { id: object::new(ctx) };
    let type_key = type_name::with_defining_ids<EmergencyFreezeGrantAction>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}

fun register_emergency_unfreeze_grant_decoder(
    registry: &mut ActionDecoderRegistry,
    ctx: &mut tx_context::TxContext,
) {
    let decoder = EmergencyUnfreezeGrantActionDecoder { id: object::new(ctx) };
    let type_key = type_name::with_defining_ids<EmergencyUnfreezeGrantAction>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}
