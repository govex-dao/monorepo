// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

/// Decoder registry for vault actions
///
/// Lightweight decoder structs for UX validation.
/// BCS decoding happens off-chain in indexers.
module account_actions::vault_decoder;

use account_actions::vault::{
    SpendAction,
    DepositAction,
    ToggleStreamPauseAction,
    ToggleStreamFreezeAction,
    CancelStreamAction
};
use account_protocol::schema::{Self as schema, ActionDecoderRegistry};
use std::type_name;
use sui::dynamic_object_field;
use sui::object::{Self, UID};

// === Decoder Objects ===

/// Decoder for SpendAction<CoinType>
public struct SpendActionDecoder has key, store {
    id: UID,
}

/// Decoder for DepositAction<CoinType>
public struct DepositActionDecoder has key, store {
    id: UID,
}

/// Decoder for ToggleStreamPauseAction
public struct ToggleStreamPauseActionDecoder has key, store {
    id: UID,
}

/// Decoder for ToggleStreamFreezeAction
public struct ToggleStreamFreezeActionDecoder has key, store {
    id: UID,
}

/// Decoder for CancelStreamAction
public struct CancelStreamActionDecoder has key, store {
    id: UID,
}

// === Placeholder for Generic Registration ===

/// Placeholder type for registering generic decoders
public struct CoinPlaceholder has drop, store {}

// === Registration Functions ===

/// Register all vault decoders
public fun register_decoders(registry: &mut ActionDecoderRegistry, ctx: &mut TxContext) {
    register_spend_decoder(registry, ctx);
    register_deposit_decoder(registry, ctx);
    register_toggle_stream_pause_decoder(registry, ctx);
    register_toggle_stream_freeze_decoder(registry, ctx);
    register_cancel_stream_decoder(registry, ctx);
}

fun register_spend_decoder(registry: &mut ActionDecoderRegistry, ctx: &mut TxContext) {
    let decoder = SpendActionDecoder {
        id: object::new(ctx),
    };

    let type_key = type_name::with_defining_ids<SpendAction<CoinPlaceholder>>();

    dynamic_object_field::add(
        schema::registry_id_mut(registry),
        type_key,
        decoder,
    );
}

fun register_deposit_decoder(registry: &mut ActionDecoderRegistry, ctx: &mut TxContext) {
    let decoder = DepositActionDecoder {
        id: object::new(ctx),
    };

    let type_key = type_name::with_defining_ids<DepositAction<CoinPlaceholder>>();

    dynamic_object_field::add(
        schema::registry_id_mut(registry),
        type_key,
        decoder,
    );
}

fun register_toggle_stream_pause_decoder(
    registry: &mut ActionDecoderRegistry,
    ctx: &mut TxContext,
) {
    let decoder = ToggleStreamPauseActionDecoder {
        id: object::new(ctx),
    };

    let type_key = type_name::with_defining_ids<ToggleStreamPauseAction>();

    dynamic_object_field::add(
        schema::registry_id_mut(registry),
        type_key,
        decoder,
    );
}

fun register_toggle_stream_freeze_decoder(
    registry: &mut ActionDecoderRegistry,
    ctx: &mut TxContext,
) {
    let decoder = ToggleStreamFreezeActionDecoder {
        id: object::new(ctx),
    };

    let type_key = type_name::with_defining_ids<ToggleStreamFreezeAction>();

    dynamic_object_field::add(
        schema::registry_id_mut(registry),
        type_key,
        decoder,
    );
}

fun register_cancel_stream_decoder(
    registry: &mut ActionDecoderRegistry,
    ctx: &mut TxContext,
) {
    let decoder = CancelStreamActionDecoder {
        id: object::new(ctx),
    };

    let type_key = type_name::with_defining_ids<CancelStreamAction>();

    dynamic_object_field::add(
        schema::registry_id_mut(registry),
        type_key,
        decoder,
    );
}

// === Verification Functions ===

/// Check if a SpendAction decoder is registered
public fun has_spend_decoder(registry: &ActionDecoderRegistry): bool {
    let type_key = type_name::with_defining_ids<SpendAction<CoinPlaceholder>>();
    dynamic_object_field::exists_(schema::registry_id(registry), type_key)
}

/// Check if a DepositAction decoder is registered
public fun has_deposit_decoder(registry: &ActionDecoderRegistry): bool {
    let type_key = type_name::with_defining_ids<DepositAction<CoinPlaceholder>>();
    dynamic_object_field::exists_(schema::registry_id(registry), type_key)
}
