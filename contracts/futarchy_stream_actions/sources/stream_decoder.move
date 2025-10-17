// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

/// Decoder for stream/payment actions in futarchy DAOs
module futarchy_stream_actions::stream_decoder;

use account_protocol::bcs_validation;
use account_protocol::schema::{Self, ActionDecoderRegistry, HumanReadableField};
use futarchy_stream_actions::stream_actions::{
    CreateStreamAction,
    CancelStreamAction,
    WithdrawStreamAction,
    UpdateStreamAction,
    PauseStreamAction,
    ResumeStreamAction
};
use std::option::{Self, Option};
use std::string::String;
use std::type_name;
use sui::bcs;
use sui::dynamic_object_field;
use sui::object::{Self, UID};

// === Imports ===

// === Decoder Objects ===

/// Decoder for CreateStreamAction
public struct CreateStreamActionDecoder has key, store {
    id: UID,
}

/// Decoder for CancelStreamAction
public struct CancelStreamActionDecoder has key, store {
    id: UID,
}

/// Decoder for WithdrawStreamAction
public struct WithdrawStreamActionDecoder has key, store {
    id: UID,
}

/// Decoder for UpdateStreamAction
public struct UpdateStreamActionDecoder has key, store {
    id: UID,
}

/// Decoder for PauseStreamAction
public struct PauseStreamActionDecoder has key, store {
    id: UID,
}

/// Decoder for ResumeStreamAction
public struct ResumeStreamActionDecoder has key, store {
    id: UID,
}

/// Placeholder for generic registration
public struct CoinPlaceholder has drop, store {}

// === Decoder Functions ===

/// Decode a CreateStreamAction
public fun decode_create_stream_action<CoinType>(
    _decoder: &CreateStreamActionDecoder,
    action_data: vector<u8>,
): vector<HumanReadableField> {
    let mut bcs_data = bcs::new(action_data);

    let recipient = bcs::peel_address(&mut bcs_data);
    let amount_per_period = bcs::peel_u64(&mut bcs_data);
    let period_duration_ms = bcs::peel_u64(&mut bcs_data);
    let start_time = bcs::peel_u64(&mut bcs_data);
    let end_time = bcs::peel_option_u64(&mut bcs_data);
    let cliff_time = bcs::peel_option_u64(&mut bcs_data);
    let cancellable = bcs::peel_bool(&mut bcs_data);
    let description = bcs::peel_vec_u8(&mut bcs_data).to_string();

    // Security: ensure all bytes are consumed to prevent trailing data attacks
    bcs_validation::validate_all_bytes_consumed(bcs_data);

    let mut fields = vector[
        schema::new_field(
            b"recipient".to_string(),
            recipient.to_string(),
            b"address".to_string(),
        ),
        schema::new_field(
            b"amount_per_period".to_string(),
            amount_per_period.to_string(),
            b"u64".to_string(),
        ),
        schema::new_field(
            b"period_duration_ms".to_string(),
            period_duration_ms.to_string(),
            b"u64".to_string(),
        ),
        schema::new_field(
            b"start_time".to_string(),
            start_time.to_string(),
            b"u64".to_string(),
        ),
        schema::new_field(
            b"cancellable".to_string(),
            if (cancellable) { b"true" } else { b"false" }.to_string(),
            b"bool".to_string(),
        ),
        schema::new_field(
            b"description".to_string(),
            description,
            b"String".to_string(),
        ),
    ];

    if (end_time.is_some()) {
        fields.push_back(
            schema::new_field(
                b"end_time".to_string(),
                end_time.destroy_some().to_string(),
                b"u64".to_string(),
            ),
        );
    } else {
        end_time.destroy_none();
    };

    if (cliff_time.is_some()) {
        fields.push_back(
            schema::new_field(
                b"cliff_time".to_string(),
                cliff_time.destroy_some().to_string(),
                b"u64".to_string(),
            ),
        );
    } else {
        cliff_time.destroy_none();
    };

    fields
}

/// Decode a CancelStreamAction
public fun decode_cancel_stream_action(
    _decoder: &CancelStreamActionDecoder,
    action_data: vector<u8>,
): vector<HumanReadableField> {
    let mut bcs_data = bcs::new(action_data);

    let stream_id = bcs::peel_address(&mut bcs_data);
    let reason = bcs::peel_vec_u8(&mut bcs_data).to_string();

    // Security: ensure all bytes are consumed to prevent trailing data attacks
    bcs_validation::validate_all_bytes_consumed(bcs_data);

    vector[
        schema::new_field(
            b"stream_id".to_string(),
            stream_id.to_string(),
            b"ID".to_string(),
        ),
        schema::new_field(
            b"reason".to_string(),
            reason,
            b"String".to_string(),
        ),
    ]
}

// === Helper Functions ===

fun peel_option_u64(bcs_data: &mut bcs::BCS): Option<u64> {
    let is_some = bcs::peel_bool(bcs_data);
    if (is_some) {
        option::some(bcs::peel_u64(bcs_data))
    } else {
        option::none()
    }
}

// === Registration Functions ===

/// Register all stream decoders
public fun register_decoders(registry: &mut ActionDecoderRegistry, ctx: &mut TxContext) {
    register_create_stream_decoder(registry, ctx);
    register_cancel_stream_decoder(registry, ctx);
    register_withdraw_stream_decoder(registry, ctx);
    register_update_stream_decoder(registry, ctx);
    register_pause_stream_decoder(registry, ctx);
    register_resume_stream_decoder(registry, ctx);
}

fun register_create_stream_decoder(registry: &mut ActionDecoderRegistry, ctx: &mut TxContext) {
    let decoder = CreateStreamActionDecoder { id: object::new(ctx) };
    let type_key = type_name::with_defining_ids<CreateStreamAction<CoinPlaceholder>>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}

fun register_cancel_stream_decoder(registry: &mut ActionDecoderRegistry, ctx: &mut TxContext) {
    let decoder = CancelStreamActionDecoder { id: object::new(ctx) };
    let type_key = type_name::with_defining_ids<CancelStreamAction>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}

fun register_withdraw_stream_decoder(registry: &mut ActionDecoderRegistry, ctx: &mut TxContext) {
    let decoder = WithdrawStreamActionDecoder { id: object::new(ctx) };
    let type_key = type_name::with_defining_ids<WithdrawStreamAction>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}

fun register_update_stream_decoder(registry: &mut ActionDecoderRegistry, ctx: &mut TxContext) {
    let decoder = UpdateStreamActionDecoder { id: object::new(ctx) };
    let type_key = type_name::with_defining_ids<UpdateStreamAction>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}

fun register_pause_stream_decoder(registry: &mut ActionDecoderRegistry, ctx: &mut TxContext) {
    let decoder = PauseStreamActionDecoder { id: object::new(ctx) };
    let type_key = type_name::with_defining_ids<PauseStreamAction>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}

fun register_resume_stream_decoder(registry: &mut ActionDecoderRegistry, ctx: &mut TxContext) {
    let decoder = ResumeStreamActionDecoder { id: object::new(ctx) };
    let type_key = type_name::with_defining_ids<ResumeStreamAction>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}
