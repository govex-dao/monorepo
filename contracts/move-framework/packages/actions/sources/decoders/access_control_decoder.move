// ============================================================================
// FORK ADDITION - Access Control Action Decoder
// ============================================================================
// NEW FILE added to the fork for on-chain action decoding.
//
// PURPOSE:
// Provides human-readable decoding of access control actions for transparency.
// Part of the mandatory decoder system that ensures all actions can be
// decoded and displayed to users before execution.
//
// IMPLEMENTATION:
// - Handles BorrowAction and ReturnAction (empty structs)
// - Minimal decoder as these actions have no fields
// - Still validates BCS consumption for security
// - Returns action type information for display
// ============================================================================

/// Decoder for access control actions - tightly coupled with access control action definitions
module account_actions::access_control_decoder;

// === Imports ===

use std::{string::String, type_name};
use sui::{object::{Self, UID}, dynamic_object_field};
use account_protocol::{schema::{Self, ActionDecoderRegistry, HumanReadableField}, bcs_validation};
use account_actions::access_control::{BorrowAction, ReturnAction};

// === Decoder Objects ===

/// Decoder for BorrowAction<Cap>
public struct BorrowActionDecoder has key, store {
    id: UID,
}

/// Decoder for ReturnAction<Cap>
public struct ReturnActionDecoder has key, store {
    id: UID,
}

// === Placeholder for Generic Registration ===

/// Placeholder type for registering generic decoders
public struct CapPlaceholder has drop, store {}

// === Decoder Functions ===

/// Decode a BorrowAction
public fun decode_borrow_action<Cap>(
    _decoder: &BorrowActionDecoder,
    action_data: vector<u8>,
): vector<HumanReadableField> {
    // BorrowAction has no fields - it's an empty struct
    // Still validate that all bytes are consumed (should be empty)
    let bcs_data = sui::bcs::new(action_data);

    // Security: ensure all bytes are consumed to prevent trailing data attacks
    bcs_validation::validate_all_bytes_consumed(bcs_data);

    // Return empty vector since there are no fields to decode
    vector[
        schema::new_field(
            b"action_type".to_string(),
            b"BorrowAction".to_string(),
            b"String".to_string(),
        )
    ]
}

/// Decode a ReturnAction
public fun decode_return_action<Cap>(
    _decoder: &ReturnActionDecoder,
    action_data: vector<u8>,
): vector<HumanReadableField> {
    // ReturnAction has no fields - it's an empty struct
    // Still validate that all bytes are consumed (should be empty)
    let bcs_data = sui::bcs::new(action_data);

    // Security: ensure all bytes are consumed to prevent trailing data attacks
    bcs_validation::validate_all_bytes_consumed(bcs_data);

    // Return empty vector since there are no fields to decode
    vector[
        schema::new_field(
            b"action_type".to_string(),
            b"ReturnAction".to_string(),
            b"String".to_string(),
        )
    ]
}

// === Registration Functions ===

/// Register all access control decoders
public fun register_decoders(
    registry: &mut ActionDecoderRegistry,
    ctx: &mut TxContext,
) {
    register_borrow_decoder(registry, ctx);
    register_return_decoder(registry, ctx);
}

fun register_borrow_decoder(
    registry: &mut ActionDecoderRegistry,
    ctx: &mut TxContext,
) {
    let decoder = BorrowActionDecoder { id: object::new(ctx) };
    let type_key = type_name::get<BorrowAction<CapPlaceholder>>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}

fun register_return_decoder(
    registry: &mut ActionDecoderRegistry,
    ctx: &mut TxContext,
) {
    let decoder = ReturnActionDecoder { id: object::new(ctx) };
    let type_key = type_name::get<ReturnAction<CapPlaceholder>>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}