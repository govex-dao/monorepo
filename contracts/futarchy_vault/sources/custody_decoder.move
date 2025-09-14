/// Decoder for custody actions in futarchy DAOs
module futarchy_vault::custody_decoder;

// === Imports ===

use std::{string::String, type_name};
use sui::{object::{Self, UID}, dynamic_object_field, bcs};
use account_protocol::bcs_validation;
use account_protocol::schema::{Self, ActionDecoderRegistry, HumanReadableField};
use futarchy_vault::custody_actions::{
    ApproveCustodyAction,
    AcceptIntoCustodyAction,
};

// === Decoder Objects ===

/// Decoder for ApproveCustodyAction
public struct ApproveCustodyActionDecoder has key, store {
    id: UID,
}

/// Decoder for AcceptIntoCustodyAction
public struct AcceptIntoCustodyActionDecoder has key, store {
    id: UID,
}

/// Placeholder for generic registration
public struct ResourcePlaceholder has drop, store {}

// === Decoder Functions ===

/// Decode an ApproveCustodyAction
public fun decode_approve_custody_action<R>(
    _decoder: &ApproveCustodyActionDecoder,
    action_data: vector<u8>,
): vector<HumanReadableField> {
    let mut bcs_data = bcs::new(action_data);

    let dao_id = bcs::peel_address(&mut bcs_data);
    let object_id = bcs::peel_address(&mut bcs_data);
    let resource_key = bcs::peel_vec_u8(&mut bcs_data).to_string();
    let context = bcs::peel_vec_u8(&mut bcs_data).to_string();
    let expires_at = bcs::peel_u64(&mut bcs_data);

    // Security: ensure all bytes are consumed to prevent trailing data attacks
    bcs_validation::validate_all_bytes_consumed(bcs_data);

    vector[
        schema::new_field(
            b"dao_id".to_string(),
            dao_id.to_string(),
            b"ID".to_string(),
        ),
        schema::new_field(
            b"object_id".to_string(),
            object_id.to_string(),
            b"ID".to_string(),
        ),
        schema::new_field(
            b"resource_key".to_string(),
            resource_key,
            b"String".to_string(),
        ),
        schema::new_field(
            b"context".to_string(),
            context,
            b"String".to_string(),
        ),
        schema::new_field(
            b"expires_at".to_string(),
            expires_at.to_string(),
            b"u64".to_string(),
        ),
    ]
}

/// Decode an AcceptIntoCustodyAction
public fun decode_accept_into_custody_action<R>(
    _decoder: &AcceptIntoCustodyActionDecoder,
    action_data: vector<u8>,
): vector<HumanReadableField> {
    let mut bcs_data = bcs::new(action_data);

    let object_id = bcs::peel_address(&mut bcs_data);
    let resource_key = bcs::peel_vec_u8(&mut bcs_data).to_string();
    let context = bcs::peel_vec_u8(&mut bcs_data).to_string();

    // Security: ensure all bytes are consumed to prevent trailing data attacks
    bcs_validation::validate_all_bytes_consumed(bcs_data);

    vector[
        schema::new_field(
            b"object_id".to_string(),
            object_id.to_string(),
            b"ID".to_string(),
        ),
        schema::new_field(
            b"resource_key".to_string(),
            resource_key,
            b"String".to_string(),
        ),
        schema::new_field(
            b"context".to_string(),
            context,
            b"String".to_string(),
        ),
    ]
}

// === Registration Functions ===

/// Register all custody decoders
public fun register_decoders(
    registry: &mut ActionDecoderRegistry,
    ctx: &mut TxContext,
) {
    register_approve_custody_decoder(registry, ctx);
    register_accept_into_custody_decoder(registry, ctx);
}

fun register_approve_custody_decoder(
    registry: &mut ActionDecoderRegistry,
    ctx: &mut TxContext,
) {
    let decoder = ApproveCustodyActionDecoder { id: object::new(ctx) };
    let type_key = type_name::with_defining_ids<ApproveCustodyAction<ResourcePlaceholder>>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}

fun register_accept_into_custody_decoder(
    registry: &mut ActionDecoderRegistry,
    ctx: &mut TxContext,
) {
    let decoder = AcceptIntoCustodyActionDecoder { id: object::new(ctx) };
    let type_key = type_name::with_defining_ids<AcceptIntoCustodyAction<ResourcePlaceholder>>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}