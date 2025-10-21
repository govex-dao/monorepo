// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

/// Decoder for currency actions - tightly coupled with currency action definitions
module account_actions::currency_decoder;

use account_actions::currency::{MintAction, BurnAction, DisableAction, UpdateAction};
use account_protocol::schema::{Self as schema, ActionDecoderRegistry};
use std::type_name;
use sui::dynamic_object_field;
use sui::object::{Self, UID};

// === Decoder Objects ===

/// Decoder for MintAction<CoinType>
public struct MintActionDecoder has key, store {
    id: UID,
}

/// Decoder for BurnAction<CoinType>
public struct BurnActionDecoder has key, store {
    id: UID,
}

/// Decoder for DisableAction<CoinType>
public struct DisableActionDecoder has key, store {
    id: UID,
}

/// Decoder for UpdateAction<CoinType>
public struct UpdateActionDecoder has key, store {
    id: UID,
}

/// Placeholder for generic registration
public struct CoinPlaceholder has drop, store {}

// === Registration Functions ===

/// Register all currency decoders
public fun register_decoders(registry: &mut ActionDecoderRegistry, ctx: &mut TxContext) {
    register_mint_decoder(registry, ctx);
    register_burn_decoder(registry, ctx);
    register_disable_decoder(registry, ctx);
    register_update_decoder(registry, ctx);
}

fun register_mint_decoder(registry: &mut ActionDecoderRegistry, ctx: &mut TxContext) {
    let decoder = MintActionDecoder { id: object::new(ctx) };
    let type_key = type_name::with_defining_ids<MintAction<CoinPlaceholder>>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}

fun register_burn_decoder(registry: &mut ActionDecoderRegistry, ctx: &mut TxContext) {
    let decoder = BurnActionDecoder { id: object::new(ctx) };
    let type_key = type_name::with_defining_ids<BurnAction<CoinPlaceholder>>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}

fun register_disable_decoder(registry: &mut ActionDecoderRegistry, ctx: &mut TxContext) {
    let decoder = DisableActionDecoder { id: object::new(ctx) };
    let type_key = type_name::with_defining_ids<DisableAction<CoinPlaceholder>>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}

fun register_update_decoder(registry: &mut ActionDecoderRegistry, ctx: &mut TxContext) {
    let decoder = UpdateActionDecoder { id: object::new(ctx) };
    let type_key = type_name::with_defining_ids<UpdateAction<CoinPlaceholder>>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}
