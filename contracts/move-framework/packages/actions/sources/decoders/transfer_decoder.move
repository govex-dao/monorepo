// ============================================================================
// FORK ADDITION - Transfer Action Decoder
// ============================================================================
// NEW FILE added to the fork for on-chain action decoding.
//
// PURPOSE:
// Provides human-readable decoding of transfer actions for transparency.
// Part of the mandatory decoder system that ensures all actions can be
// decoded and displayed to users before execution.
//
// IMPLEMENTATION:
// - Simple single-field decoder for TransferAction
// - Uses BCS deserialization with security validation
// - Returns vector<HumanReadableField> for universal display
// ============================================================================

/// Decoder for transfer actions - tightly coupled with transfer action definitions
module account_actions::transfer_decoder;

// === Imports ===

use std::{string::String, type_name};
use sui::{object::{Self, UID}, dynamic_object_field, bcs};
use account_protocol::{schema::{Self, ActionDecoderRegistry, HumanReadableField}, bcs_validation};
use account_actions::transfer::TransferAction;

// === Decoder Objects ===

/// Decoder for TransferAction
public struct TransferActionDecoder has key, store {
    id: UID,
}

// === Decoder Functions ===

/// Decode a TransferAction
public fun decode_transfer_action(
    _decoder: &TransferActionDecoder,
    action_data: vector<u8>,
): vector<HumanReadableField> {
    // Deserialize the fields directly - DO NOT reconstruct the Action struct
    let mut bcs_data = bcs::new(action_data);
    let recipient = bcs::peel_address(&mut bcs_data);

    // Security: ensure all bytes are consumed to prevent trailing data attacks
    bcs_validation::validate_all_bytes_consumed(bcs_data);

    vector[
        schema::new_field(
            b"recipient".to_string(),
            recipient.to_string(),
            b"address".to_string(),
        )
    ]
}

// === Registration Functions ===

/// Register all transfer decoders
public fun register_decoders(
    registry: &mut ActionDecoderRegistry,
    ctx: &mut TxContext,
) {
    register_transfer_decoder(registry, ctx);
}

fun register_transfer_decoder(
    registry: &mut ActionDecoderRegistry,
    ctx: &mut TxContext,
) {
    let decoder = TransferActionDecoder { id: object::new(ctx) };
    let type_key = type_name::get<TransferAction>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}