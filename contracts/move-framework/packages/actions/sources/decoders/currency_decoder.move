// ============================================================================
// FORK ADDITION - Currency Action Decoder
// ============================================================================
// NEW FILE added to the fork for on-chain action decoding.
//
// PURPOSE:
// Provides human-readable decoding of currency actions (minting, burning,
// metadata updates) for transparency. Part of the mandatory decoder system
// that ensures all actions can be decoded and displayed to users.
//
// IMPLEMENTATION:
// - Handles MintAction, BurnAction, UpdateAction, DisableAction
// - Complex Option<T> handling for metadata fields
// - Uses BCS deserialization with peel_* functions and macros
// - Security validation via validate_all_bytes_consumed()
// ============================================================================

/// Decoder for currency actions - tightly coupled with currency action definitions
module account_actions::currency_decoder;

// === Imports ===

use std::{string::String, type_name, ascii};
use sui::{object::{Self, UID}, dynamic_object_field, bcs};
use account_protocol::bcs_validation;
use account_protocol::schema::{Self, ActionDecoderRegistry, HumanReadableField};
use account_actions::currency::{MintAction, BurnAction, DisableAction, UpdateAction};

// === Decoder Objects ===

/// Decoder for MintAction<CoinType>
public struct MintActionDecoder has key, store {
    id: UID,
}

/// Decoder for BurnAction<CoinType>
public struct BurnActionDecoder has key, store {
    id: UID,
}

/// Decoder for DisableAction<CoinType>
public struct DisableActionDecoder has key, store {
    id: UID,
}

/// Decoder for UpdateAction<CoinType>
public struct UpdateActionDecoder has key, store {
    id: UID,
}

/// Placeholder for generic registration
public struct CoinPlaceholder has drop, store {}

// === Decoder Functions ===

/// Decode a MintAction
public fun decode_mint_action<CoinType>(
    _decoder: &MintActionDecoder,
    action_data: vector<u8>,
): vector<HumanReadableField> {
    let mut bcs_data = bcs::new(action_data);
    let amount = bcs::peel_u64(&mut bcs_data);

    // Security: ensure all bytes are consumed to prevent trailing data attacks
    bcs_validation::validate_all_bytes_consumed(bcs_data);

    vector[
        schema::new_field(
            b"amount".to_string(),
            amount.to_string(),
            b"u64".to_string(),
        )
    ]
}

/// Decode a BurnAction
public fun decode_burn_action<CoinType>(
    _decoder: &BurnActionDecoder,
    action_data: vector<u8>,
): vector<HumanReadableField> {
    let mut bcs_data = bcs::new(action_data);
    let amount = bcs::peel_u64(&mut bcs_data);

    // Security: ensure all bytes are consumed to prevent trailing data attacks
    bcs_validation::validate_all_bytes_consumed(bcs_data);

    vector[
        schema::new_field(
            b"amount".to_string(),
            amount.to_string(),
            b"u64".to_string(),
        )
    ]
}

/// Decode a DisableAction
public fun decode_disable_action<CoinType>(
    _decoder: &DisableActionDecoder,
    action_data: vector<u8>,
): vector<HumanReadableField> {
    let mut bcs_data = bcs::new(action_data);
    let mint = bcs::peel_bool(&mut bcs_data);
    let burn = bcs::peel_bool(&mut bcs_data);
    let update_symbol = bcs::peel_bool(&mut bcs_data);
    let update_name = bcs::peel_bool(&mut bcs_data);
    let update_description = bcs::peel_bool(&mut bcs_data);
    let update_icon = bcs::peel_bool(&mut bcs_data);

    // Security: ensure all bytes are consumed to prevent trailing data attacks
    bcs_validation::validate_all_bytes_consumed(bcs_data);

    let mut fields = vector::empty();

    fields.push_back(schema::new_field(
        b"mint".to_string(),
        if (mint) { b"true" } else { b"false" }.to_string(),
        b"bool".to_string(),
    ));

    fields.push_back(schema::new_field(
        b"burn".to_string(),
        if (burn) { b"true" } else { b"false" }.to_string(),
        b"bool".to_string(),
    ));

    fields.push_back(schema::new_field(
        b"update_symbol".to_string(),
        if (update_symbol) { b"true" } else { b"false" }.to_string(),
        b"bool".to_string(),
    ));

    fields.push_back(schema::new_field(
        b"update_name".to_string(),
        if (update_name) { b"true" } else { b"false" }.to_string(),
        b"bool".to_string(),
    ));

    fields.push_back(schema::new_field(
        b"update_description".to_string(),
        if (update_description) { b"true" } else { b"false" }.to_string(),
        b"bool".to_string(),
    ));

    fields
}

/// Decode an UpdateAction
public fun decode_update_action<CoinType>(
    _decoder: &UpdateActionDecoder,
    action_data: vector<u8>,
): vector<HumanReadableField> {
    let mut bcs_data = bcs::new(action_data);
    let mut symbol = bcs_data.peel_option!(|bcs| bcs.peel_vec_u8());
    let mut name = bcs_data.peel_option!(|bcs| bcs.peel_vec_u8());
    let mut description = bcs_data.peel_option!(|bcs| bcs.peel_vec_u8());
    let mut icon_url = bcs_data.peel_option!(|bcs| bcs.peel_vec_u8());

    // Security: ensure all bytes are consumed to prevent trailing data attacks
    bcs_validation::validate_all_bytes_consumed(bcs_data);

    let mut fields = vector::empty();

    // Symbol (optional)
    fields.push_back(schema::new_field(
        b"symbol".to_string(),
        if (symbol.is_some()) {
            symbol.destroy_some().to_string()
        } else {
            symbol.destroy_none();
            b"None".to_string()
        },
        b"Option<String>".to_string(),
    ));

    // Name (optional)
    fields.push_back(schema::new_field(
        b"name".to_string(),
        if (name.is_some()) {
            name.destroy_some().to_string()
        } else {
            name.destroy_none();
            b"None".to_string()
        },
        b"Option<String>".to_string(),
    ));

    // Description (optional)
    fields.push_back(schema::new_field(
        b"description".to_string(),
        if (description.is_some()) {
            description.destroy_some().to_string()
        } else {
            description.destroy_none();
            b"None".to_string()
        },
        b"Option<String>".to_string(),
    ));

    // Icon URL (optional)
    fields.push_back(schema::new_field(
        b"icon_url".to_string(),
        if (icon_url.is_some()) {
            icon_url.destroy_some().to_string()
        } else {
            icon_url.destroy_none();
            b"None".to_string()
        },
        b"Option<String>".to_string(),
    ));

    fields
}

// === Registration Functions ===

/// Register all currency decoders
public fun register_decoders(
    registry: &mut ActionDecoderRegistry,
    ctx: &mut TxContext,
) {
    register_mint_decoder(registry, ctx);
    register_burn_decoder(registry, ctx);
    register_disable_decoder(registry, ctx);
    register_update_decoder(registry, ctx);
}

fun register_mint_decoder(
    registry: &mut ActionDecoderRegistry,
    ctx: &mut TxContext,
) {
    let decoder = MintActionDecoder { id: object::new(ctx) };
    let type_key = type_name::with_defining_ids<MintAction<CoinPlaceholder>>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}

fun register_burn_decoder(
    registry: &mut ActionDecoderRegistry,
    ctx: &mut TxContext,
) {
    let decoder = BurnActionDecoder { id: object::new(ctx) };
    let type_key = type_name::with_defining_ids<BurnAction<CoinPlaceholder>>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}

fun register_disable_decoder(
    registry: &mut ActionDecoderRegistry,
    ctx: &mut TxContext,
) {
    let decoder = DisableActionDecoder { id: object::new(ctx) };
    let type_key = type_name::with_defining_ids<DisableAction<CoinPlaceholder>>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}

fun register_update_decoder(
    registry: &mut ActionDecoderRegistry,
    ctx: &mut TxContext,
) {
    let decoder = UpdateActionDecoder { id: object::new(ctx) };
    let type_key = type_name::with_defining_ids<UpdateAction<CoinPlaceholder>>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}