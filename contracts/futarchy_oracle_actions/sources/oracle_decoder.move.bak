// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

/// Decoder for oracle grant actions
module futarchy_oracle::oracle_decoder;

use account_protocol::bcs_validation;
use account_protocol::schema::{Self, ActionDecoderRegistry, HumanReadableField};
use futarchy_oracle::oracle_actions::{
    CreateOracleGrantAction,
    CancelGrantAction,
    EmergencyFreezeGrantAction,
    EmergencyUnfreezeGrantAction,
};
use std::type_name;
use sui::bcs;
use sui::dynamic_object_field;
use sui::object;
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
public fun decode_create_oracle_grant<AssetType, StableType>(
    _decoder: &CreateOracleGrantActionDecoder,
    action_data: vector<u8>,
): vector<HumanReadableField> {
    let mut bcs_data = bcs::new(action_data);

    // Deserialize tier specs
    let tier_spec_count = bcs::peel_vec_length(&mut bcs_data);
    let mut total_recipients = 0u64;
    let mut total_amount = 0u64;

    // Parse tiers to extract summary info
    let mut i = 0;
    while (i < tier_spec_count) {
        let _price_threshold = bcs::peel_u128(&mut bcs_data);
        let _is_above = bcs::peel_bool(&mut bcs_data);

        let recipient_count = bcs::peel_vec_length(&mut bcs_data);
        total_recipients = total_recipients + recipient_count;

        let mut j = 0;
        while (j < recipient_count) {
            let _recipient = bcs::peel_address(&mut bcs_data);
            let amount = bcs::peel_u64(&mut bcs_data);
            total_amount = total_amount + amount;
            j = j + 1;
        };

        let _tier_description_bytes = bcs::peel_vec_u8(&mut bcs_data);
        i = i + 1;
    };

    let launchpad_multiplier = bcs::peel_u64(&mut bcs_data);
    let earliest_execution_offset_ms = bcs::peel_u64(&mut bcs_data);
    let expiry_years = bcs::peel_u64(&mut bcs_data);
    let cancelable = bcs::peel_bool(&mut bcs_data);
    let description_bytes = bcs::peel_vec_u8(&mut bcs_data);

    bcs_validation::validate_all_bytes_consumed(bcs_data);

    let description = std::string::utf8(description_bytes);

    vector[
        schema::new_field(
            b"tier_count".to_string(),
            tier_spec_count.to_string(),
            b"u64".to_string(),
        ),
        schema::new_field(
            b"total_recipients".to_string(),
            total_recipients.to_string(),
            b"u64".to_string(),
        ),
        schema::new_field(
            b"total_amount".to_string(),
            total_amount.to_string(),
            b"u64".to_string(),
        ),
        schema::new_field(
            b"launchpad_multiplier".to_string(),
            launchpad_multiplier.to_string(),
            b"u64".to_string(),
        ),
        schema::new_field(
            b"earliest_execution_offset_ms".to_string(),
            earliest_execution_offset_ms.to_string(),
            b"u64".to_string(),
        ),
        schema::new_field(
            b"expiry_years".to_string(),
            expiry_years.to_string(),
            b"u64".to_string(),
        ),
        schema::new_field(
            b"cancelable".to_string(),
            if (cancelable) { b"true" } else { b"false" }.to_string(),
            b"bool".to_string(),
        ),
        schema::new_field(b"description".to_string(), description, b"String".to_string()),
    ]
}

/// Decode CancelGrantAction
public fun decode_cancel_grant(
    _decoder: &CancelGrantActionDecoder,
    action_data: vector<u8>,
): vector<HumanReadableField> {
    let mut bcs_data = bcs::new(action_data);

    let grant_id_address = bcs::peel_address(&mut bcs_data);

    bcs_validation::validate_all_bytes_consumed(bcs_data);

    vector[
        schema::new_field(b"grant_id".to_string(), grant_id_address.to_string(), b"ID".to_string()),
    ]
}

/// Decode EmergencyFreezeGrantAction
public fun decode_emergency_freeze_grant(
    _decoder: &EmergencyFreezeGrantActionDecoder,
    action_data: vector<u8>,
): vector<HumanReadableField> {
    let mut bcs_data = bcs::new(action_data);

    let grant_id_address = bcs::peel_address(&mut bcs_data);

    bcs_validation::validate_all_bytes_consumed(bcs_data);

    vector[
        schema::new_field(b"grant_id".to_string(), grant_id_address.to_string(), b"ID".to_string()),
    ]
}

/// Decode EmergencyUnfreezeGrantAction
public fun decode_emergency_unfreeze_grant(
    _decoder: &EmergencyUnfreezeGrantActionDecoder,
    action_data: vector<u8>,
): vector<HumanReadableField> {
    let mut bcs_data = bcs::new(action_data);

    let grant_id_address = bcs::peel_address(&mut bcs_data);

    bcs_validation::validate_all_bytes_consumed(bcs_data);

    vector[
        schema::new_field(b"grant_id".to_string(), grant_id_address.to_string(), b"ID".to_string()),
    ]
}

// === Registration Functions ===

/// Register all oracle decoders with the registry
public fun register_oracle_decoders<AssetType, StableType>(
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
