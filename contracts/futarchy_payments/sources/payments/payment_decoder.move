/// Decoder for payment actions with proper BCS validation
module futarchy_payments::payment_decoder;

use account_protocol::bcs_validation;
use account_protocol::schema::{Self, ActionDecoderRegistry, HumanReadableField};
use futarchy_payments::payment_actions::{
    Self as payment_actions,
    CreatePaymentAction,
    CancelPaymentAction
};
use std::option;
use std::string::String;
use std::type_name;
use sui::bcs;
use sui::dynamic_object_field;
use sui::object::{Self, UID};
use sui::tx_context::TxContext;

// === Errors ===

const EInvalidActionVersion: u64 = 0;

// === Decoder Objects ===

/// Decoder for CreatePaymentAction
public struct CreatePaymentActionDecoder has key, store {
    id: UID,
}

/// Decoder for CancelPaymentAction
public struct CancelPaymentActionDecoder has key, store {
    id: UID,
}

/// Placeholder for generic registration
public struct CoinPlaceholder has drop, store {}

// === Decoder Functions ===

/// Decode a CreatePaymentAction using safe BCS deserialization
public fun decode_create_payment_action<CoinType>(
    _decoder: &CreatePaymentActionDecoder,
    action_data: vector<u8>,
): vector<HumanReadableField> {
    // Deserialize the action
    let action = deserialize_create_payment_action<CoinType>(action_data, 1);

    // Convert to human-readable fields
    vector[
        schema::new_field(
            b"payment_type".to_string(),
            action.payment_type().to_string(),
            b"u8".to_string(),
        ),
        schema::new_field(
            b"source_mode".to_string(),
            action.source_mode().to_string(),
            b"u8".to_string(),
        ),
        schema::new_field(
            b"recipient".to_string(),
            action.recipient().to_string(),
            b"address".to_string(),
        ),
        schema::new_field(
            b"amount".to_string(),
            action.amount().to_string(),
            b"u64".to_string(),
        ),
        schema::new_field(
            b"start_timestamp".to_string(),
            action.start_timestamp().to_string(),
            b"u64".to_string(),
        ),
        schema::new_field(
            b"end_timestamp".to_string(),
            action.end_timestamp().to_string(),
            b"u64".to_string(),
        ),
        schema::new_field(
            b"interval_or_cliff".to_string(),
            if (action.interval_or_cliff().is_some()) {
                (*action.interval_or_cliff().borrow()).to_string()
            } else {
                b"none".to_string()
            },
            b"Option<u64>".to_string(),
        ),
        schema::new_field(
            b"total_payments".to_string(),
            action.total_payments().to_string(),
            b"u64".to_string(),
        ),
        schema::new_field(
            b"cancellable".to_string(),
            if (action.cancellable()) { b"true" } else { b"false" }.to_string(),
            b"bool".to_string(),
        ),
        schema::new_field(
            b"description".to_string(),
            *action.description(),
            b"string".to_string(),
        ),
        schema::new_field(
            b"max_per_withdrawal".to_string(),
            action.max_per_withdrawal().to_string(),
            b"u64".to_string(),
        ),
        schema::new_field(
            b"min_interval_ms".to_string(),
            action.min_interval_ms().to_string(),
            b"u64".to_string(),
        ),
        schema::new_field(
            b"max_beneficiaries".to_string(),
            action.max_beneficiaries().to_string(),
            b"u64".to_string(),
        ),
    ]
}

/// Decode a CancelPaymentAction using safe BCS deserialization
public fun decode_cancel_payment_action(
    _decoder: &CancelPaymentActionDecoder,
    action_data: vector<u8>,
): vector<HumanReadableField> {
    // Deserialize the action
    let action = deserialize_cancel_payment_action(action_data, 1);

    // Convert to human-readable fields
    vector[
        schema::new_field(
            b"payment_id".to_string(),
            *action.payment_id(),
            b"string".to_string(),
        ),
    ]
}

/// Deserialize CreatePaymentAction from bytes with validation
public fun deserialize_create_payment_action<CoinType>(
    action_data: vector<u8>,
    version: u8,
): CreatePaymentAction<CoinType> {
    assert!(version == 1, EInvalidActionVersion);

    // Manual BCS deserialization
    let mut reader = bcs::new(action_data);

    let payment_type = bcs::peel_u8(&mut reader);
    let source_mode = bcs::peel_u8(&mut reader);
    let recipient = bcs::peel_address(&mut reader);
    let amount = bcs::peel_u64(&mut reader);
    let start_timestamp = bcs::peel_u64(&mut reader);
    let end_timestamp = bcs::peel_u64(&mut reader);

    // Handle optional interval_or_cliff
    let interval_or_cliff = if (bcs::peel_bool(&mut reader)) {
        option::some(bcs::peel_u64(&mut reader))
    } else {
        option::none()
    };

    let total_payments = bcs::peel_u64(&mut reader);
    let cancellable = bcs::peel_bool(&mut reader);
    let description = bcs::peel_vec_u8(&mut reader).to_string();
    let max_per_withdrawal = bcs::peel_u64(&mut reader);
    let min_interval_ms = bcs::peel_u64(&mut reader);
    let max_beneficiaries = bcs::peel_u64(&mut reader);

    // Validate all bytes consumed
    bcs_validation::validate_all_bytes_consumed(reader);

    payment_actions::new_create_payment_action<CoinType>(
        payment_type,
        source_mode,
        recipient,
        amount,
        start_timestamp,
        end_timestamp,
        interval_or_cliff,
        total_payments,
        cancellable,
        description,
        max_per_withdrawal,
        min_interval_ms,
        max_beneficiaries,
    )
}

/// Deserialize CancelPaymentAction from bytes with validation
public fun deserialize_cancel_payment_action(
    action_data: vector<u8>,
    version: u8,
): CancelPaymentAction {
    assert!(version == 1, EInvalidActionVersion);

    // Manual BCS deserialization
    let mut reader = bcs::new(action_data);
    let payment_id = bcs::peel_vec_u8(&mut reader).to_string();

    // Validate all bytes consumed
    bcs_validation::validate_all_bytes_consumed(reader);

    payment_actions::new_cancel_payment_action(payment_id)
}

// === Registration Functions ===

/// Register decoders with the registry
public fun register_decoders(registry: &mut ActionDecoderRegistry, ctx: &mut TxContext) {
    // Register CreatePaymentAction decoder
    let create_decoder = CreatePaymentActionDecoder {
        id: object::new(ctx),
    };
    let type_key = type_name::with_defining_ids<CreatePaymentAction<CoinPlaceholder>>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, create_decoder);

    // Register CancelPaymentAction decoder
    let cancel_decoder = CancelPaymentActionDecoder {
        id: object::new(ctx),
    };
    let type_key = type_name::with_defining_ids<CancelPaymentAction>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, cancel_decoder);
}
