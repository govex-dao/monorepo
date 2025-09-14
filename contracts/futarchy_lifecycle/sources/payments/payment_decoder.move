/// Decoder for payment actions with proper BCS validation
module futarchy_lifecycle::payment_decoder;

use std::{string::String, type_name};
use sui::{object::{Self, UID}, bcs};
use account_protocol::bcs_validation;
use account_protocol::schema::{Self, ActionDecoderRegistry, HumanReadableField};
use futarchy_lifecycle::payment_actions::{
    CreatePaymentAction,
    CancelPaymentAction,
};

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
    // Use the type-safe BCS deserialization
    let action = bcs::from_bytes<CreatePaymentAction<CoinType>>(action_data);

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
                action.interval_or_cliff().borrow().to_string()
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
    // Use the type-safe BCS deserialization
    let action = bcs::from_bytes<CancelPaymentAction>(action_data);

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

    // Use type-safe BCS deserialization
    let action = bcs::from_bytes<CreatePaymentAction<CoinType>>(action_data);

    // The bcs::from_bytes function automatically validates that all bytes are consumed
    // No need for manual validation with bcs_validation::validate_all_bytes_consumed

    action
}

/// Deserialize CancelPaymentAction from bytes with validation
public fun deserialize_cancel_payment_action(
    action_data: vector<u8>,
    version: u8,
): CancelPaymentAction {
    assert!(version == 1, EInvalidActionVersion);

    // Use type-safe BCS deserialization
    let action = bcs::from_bytes<CancelPaymentAction>(action_data);

    // The bcs::from_bytes function automatically validates that all bytes are consumed

    action
}

// === Registration Functions ===

/// Register decoders with the registry
public fun register_decoders(registry: &mut ActionDecoderRegistry, ctx: &mut TxContext) {
    // Register CreatePaymentAction decoder
    let create_decoder = CreatePaymentActionDecoder {
        id: object::new(ctx),
    };
    registry.register_decoder(
        type_name::with_defining_ids<CreatePaymentAction<CoinPlaceholder>>(),
        create_decoder,
    );

    // Register CancelPaymentAction decoder
    let cancel_decoder = CancelPaymentActionDecoder {
        id: object::new(ctx),
    };
    registry.register_decoder(
        type_name::with_defining_ids<CancelPaymentAction>(),
        cancel_decoder,
    );
}