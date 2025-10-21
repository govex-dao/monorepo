// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

/// Decoder registry for vesting actions
///
/// Lightweight decoder structs for UX validation.
/// BCS decoding happens off-chain in indexers.
module account_actions::vesting_decoder;

use account_actions::vesting::{
    CreateVestingAction,
    CancelVestingAction,
    ToggleVestingPauseAction,
    ToggleVestingFreezeAction
};
use account_protocol::schema::{Self as schema, ActionDecoderRegistry};
use std::type_name;
use sui::dynamic_object_field;
use sui::object::{Self, UID};

// === Decoder Objects ===

/// Decoder for CreateVestingAction<CoinType>
public struct CreateVestingActionDecoder has key, store {
    id: UID,
}

/// Decoder for CancelVestingAction
public struct CancelVestingActionDecoder has key, store {
    id: UID,
}

/// Decoder for ToggleVestingPauseAction
public struct ToggleVestingPauseActionDecoder has key, store {
    id: UID,
}

/// Decoder for ToggleVestingFreezeAction
public struct ToggleVestingFreezeActionDecoder has key, store {
    id: UID,
}

// === Placeholder for Generic Registration ===

/// Placeholder type for registering generic decoders
public struct CoinPlaceholder has drop, store {}

// === Registration Functions ===

/// Register all vesting decoders
public fun register_decoders(registry: &mut ActionDecoderRegistry, ctx: &mut TxContext) {
    register_create_vesting_decoder(registry, ctx);
    register_cancel_vesting_decoder(registry, ctx);
    register_toggle_vesting_pause_decoder(registry, ctx);
    register_toggle_vesting_freeze_decoder(registry, ctx);
}

fun register_create_vesting_decoder(registry: &mut ActionDecoderRegistry, ctx: &mut TxContext) {
    let decoder = CreateVestingActionDecoder { id: object::new(ctx) };
    let type_key = type_name::with_defining_ids<CreateVestingAction<CoinPlaceholder>>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}

fun register_cancel_vesting_decoder(registry: &mut ActionDecoderRegistry, ctx: &mut TxContext) {
    let decoder = CancelVestingActionDecoder { id: object::new(ctx) };
    let type_key = type_name::with_defining_ids<CancelVestingAction>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}

fun register_toggle_vesting_pause_decoder(
    registry: &mut ActionDecoderRegistry,
    ctx: &mut TxContext,
) {
    let decoder = ToggleVestingPauseActionDecoder { id: object::new(ctx) };
    let type_key = type_name::with_defining_ids<ToggleVestingPauseAction>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}

fun register_toggle_vesting_freeze_decoder(
    registry: &mut ActionDecoderRegistry,
    ctx: &mut TxContext,
) {
    let decoder = ToggleVestingFreezeActionDecoder { id: object::new(ctx) };
    let type_key = type_name::with_defining_ids<ToggleVestingFreezeAction>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}
