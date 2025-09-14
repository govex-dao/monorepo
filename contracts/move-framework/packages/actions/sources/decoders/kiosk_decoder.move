// ============================================================================
// FORK ADDITION - Kiosk Action Decoder
// ============================================================================
// NEW FILE added to the fork for on-chain action decoding.
//
// PURPOSE:
// Provides human-readable decoding of kiosk (NFT) actions for transparency.
// Part of the mandatory decoder system that ensures all actions can be
// decoded and displayed to users before execution.
//
// IMPLEMENTATION:
// - Handles TakeAction and ListAction for NFT operations
// - Uses object::id_from_bytes() for ID deserialization
// - Converts IDs to addresses for string representation
// - Returns vector<HumanReadableField> for universal display
// ============================================================================

/// Decoder for kiosk actions - tightly coupled with kiosk action definitions
module account_actions::kiosk_decoder;

// === Imports ===

use std::{string::String, type_name};
use sui::{object::{Self, UID, ID}, dynamic_object_field, bcs};
use account_protocol::{schema::{Self, ActionDecoderRegistry, HumanReadableField}, bcs_validation};
use account_actions::kiosk::{TakeAction, ListAction};

// === Decoder Objects ===

/// Decoder for TakeAction
public struct TakeActionDecoder has key, store {
    id: UID,
}

/// Decoder for ListAction
public struct ListActionDecoder has key, store {
    id: UID,
}

// === Decoder Functions ===

/// Decode a TakeAction
public fun decode_take_action(
    _decoder: &TakeActionDecoder,
    action_data: vector<u8>,
): vector<HumanReadableField> {
    // Deserialize the fields directly - DO NOT reconstruct the Action struct
    let mut bcs_data = bcs::new(action_data);
    let name = bcs::peel_vec_u8(&mut bcs_data).to_string();
    let nft_id = object::id_from_bytes(bcs::peel_vec_u8(&mut bcs_data));
    let recipient = bcs::peel_address(&mut bcs_data);

    // Security: ensure all bytes are consumed to prevent trailing data attacks
    bcs_validation::validate_all_bytes_consumed(bcs_data);

    let mut fields = vector::empty();

    fields.push_back(schema::new_field(
        b"name".to_string(),
        name,
        b"String".to_string(),
    ));

    fields.push_back(schema::new_field(
        b"nft_id".to_string(),
        nft_id.id_to_address().to_string(),
        b"ID".to_string(),
    ));

    fields.push_back(schema::new_field(
        b"recipient".to_string(),
        recipient.to_string(),
        b"address".to_string(),
    ));

    fields
}

/// Decode a ListAction
public fun decode_list_action(
    _decoder: &ListActionDecoder,
    action_data: vector<u8>,
): vector<HumanReadableField> {
    // Deserialize the fields directly - DO NOT reconstruct the Action struct
    let mut bcs_data = bcs::new(action_data);
    let name = bcs::peel_vec_u8(&mut bcs_data).to_string();
    let nft_id = object::id_from_bytes(bcs::peel_vec_u8(&mut bcs_data));
    let price = bcs::peel_u64(&mut bcs_data);

    // Security: ensure all bytes are consumed to prevent trailing data attacks
    bcs_validation::validate_all_bytes_consumed(bcs_data);

    let mut fields = vector::empty();

    fields.push_back(schema::new_field(
        b"name".to_string(),
        name,
        b"String".to_string(),
    ));

    fields.push_back(schema::new_field(
        b"nft_id".to_string(),
        nft_id.id_to_address().to_string(),
        b"ID".to_string(),
    ));

    fields.push_back(schema::new_field(
        b"price".to_string(),
        price.to_string(),
        b"u64".to_string(),
    ));

    fields
}

// === Registration Functions ===

/// Register all kiosk decoders
public fun register_decoders(
    registry: &mut ActionDecoderRegistry,
    ctx: &mut TxContext,
) {
    register_take_decoder(registry, ctx);
    register_list_decoder(registry, ctx);
}

fun register_take_decoder(
    registry: &mut ActionDecoderRegistry,
    ctx: &mut TxContext,
) {
    let decoder = TakeActionDecoder { id: object::new(ctx) };
    let type_key = type_name::with_defining_ids<TakeAction>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}

fun register_list_decoder(
    registry: &mut ActionDecoderRegistry,
    ctx: &mut TxContext,
) {
    let decoder = ListActionDecoder { id: object::new(ctx) };
    let type_key = type_name::with_defining_ids<ListAction>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}