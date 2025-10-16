/// Decoder for quota management actions in futarchy DAOs
module futarchy_actions::quota_decoder;

use account_protocol::bcs_validation;
use account_protocol::schema::{Self, ActionDecoderRegistry, HumanReadableField};
use futarchy_actions::quota_actions::SetQuotasAction;
use std::string::String;
use std::type_name;
use sui::bcs::{Self, BCS};
use sui::dynamic_object_field;
use sui::object::{Self, UID};

// === Imports ===

// === Decoder Object ===

/// Decoder for SetQuotasAction
public struct SetQuotasActionDecoder has key, store {
    id: UID,
}

// === Decoder Functions ===

/// Decode a SetQuotasAction
public fun decode_set_quotas_action(
    _decoder: &SetQuotasActionDecoder,
    action_data: vector<u8>,
): vector<HumanReadableField> {
    let mut bcs_data = bcs::new(action_data);

    // Read users vector
    let users_count = bcs::peel_vec_length(&mut bcs_data);
    let mut users = vector::empty<address>();
    let mut i = 0;
    while (i < users_count) {
        users.push_back(bcs::peel_address(&mut bcs_data));
        i = i + 1;
    };

    // Read quota parameters
    let quota_amount = bcs::peel_u64(&mut bcs_data);
    let quota_period_ms = bcs::peel_u64(&mut bcs_data);
    let reduced_fee = bcs::peel_u64(&mut bcs_data);

    // Security: ensure all bytes are consumed to prevent trailing data attacks
    bcs_validation::validate_all_bytes_consumed(bcs_data);

    vector[
        schema::new_field(
            b"users_count".to_string(),
            users.length().to_string(),
            b"u64".to_string(),
        ),
        schema::new_field(
            b"quota_amount".to_string(),
            quota_amount.to_string(),
            b"u64".to_string(),
        ),
        schema::new_field(
            b"quota_period_ms".to_string(),
            quota_period_ms.to_string(),
            b"u64".to_string(),
        ),
        schema::new_field(
            b"reduced_fee".to_string(),
            reduced_fee.to_string(),
            b"u64".to_string(),
        ),
    ]
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
