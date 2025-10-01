/// Decoder for oracle-related actions in futarchy DAOs
module futarchy_oracle::oracle_decoder;

// === Imports ===

use std::type_name;
use sui::{object::{Self, UID}, dynamic_object_field, bcs, tx_context::TxContext};
use account_protocol::bcs_validation;
use account_protocol::schema::{Self, ActionDecoderRegistry, HumanReadableField};
use futarchy_oracle::oracle_actions::{
    ConditionalMintAction,
    TieredMintAction,
};

// === Decoder Objects ===

/// Decoder for ConditionalMintAction
public struct ConditionalMintActionDecoder has key, store {
    id: UID,
}

/// Decoder for TieredMintAction
public struct TieredMintActionDecoder has key, store {
    id: UID,
}

/// Placeholder for generic registration
public struct AssetPlaceholder has drop, store {}
public struct StablePlaceholder has drop, store {}
public struct CoinPlaceholder has drop, store {}

// === Decoder Functions ===

/// Decode a ConditionalMintAction
public fun decode_conditional_mint_action(
    _decoder: &ConditionalMintActionDecoder,
    action_data: vector<u8>,
): vector<HumanReadableField> {
    let mut bcs_data = bcs::new(action_data);

    let recipient = bcs::peel_address(&mut bcs_data);
    let amount = bcs::peel_u64(&mut bcs_data);
    let price_threshold = bcs::peel_u128(&mut bcs_data);
    let above_threshold = bcs::peel_bool(&mut bcs_data);

    // Security: ensure all bytes are consumed to prevent trailing data attacks
    bcs_validation::validate_all_bytes_consumed(bcs_data);

    vector[
        schema::new_field(
            b"recipient".to_string(),
            recipient.to_string(),
            b"address".to_string(),
        ),
        schema::new_field(
            b"amount".to_string(),
            amount.to_string(),
            b"u64".to_string(),
        ),
        schema::new_field(
            b"price_threshold".to_string(),
            price_threshold.to_string(),
            b"u128".to_string(),
        ),
        schema::new_field(
            b"above_threshold".to_string(),
            if (above_threshold) { b"true" } else { b"false" }.to_string(),
            b"bool".to_string(),
        ),
    ]
}

/// Decode a TieredMintAction
public fun decode_tiered_mint_action(
    _decoder: &TieredMintActionDecoder,
    action_data: vector<u8>,
): vector<HumanReadableField> {
    let mut bcs_data = bcs::new(action_data);

    let recipient = bcs::peel_address(&mut bcs_data);

    // Read price thresholds vector
    let thresholds_count = bcs::peel_vec_length(&mut bcs_data);
    let mut i = 0;
    while (i < thresholds_count) {
        bcs::peel_u128(&mut bcs_data); // Just consume the data
        i = i + 1;
    };

    // Read amounts vector
    let amounts_count = bcs::peel_vec_length(&mut bcs_data);
    let mut j = 0;
    while (j < amounts_count) {
        bcs::peel_u64(&mut bcs_data); // Just consume the data
        j = j + 1;
    };

    // Security: ensure all bytes are consumed to prevent trailing data attacks
    bcs_validation::validate_all_bytes_consumed(bcs_data);

    vector[
        schema::new_field(
            b"recipient".to_string(),
            recipient.to_string(),
            b"address".to_string(),
        ),
        schema::new_field(
            b"tiers_count".to_string(),
            thresholds_count.to_string(),
            b"u64".to_string(),
        ),
    ]
}

// === Registration Functions ===

/// Register all oracle decoders
public fun register_decoders(
    registry: &mut ActionDecoderRegistry,
    ctx: &mut TxContext,
) {
    register_conditional_mint_decoder(registry, ctx);
    register_tiered_mint_decoder(registry, ctx);
}

fun register_conditional_mint_decoder(
    registry: &mut ActionDecoderRegistry,
    ctx: &mut TxContext,
) {
    let decoder = ConditionalMintActionDecoder { id: object::new(ctx) };
    let type_key = type_name::with_defining_ids<ConditionalMintAction<CoinPlaceholder>>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}

fun register_tiered_mint_decoder(
    registry: &mut ActionDecoderRegistry,
    ctx: &mut TxContext,
) {
    let decoder = TieredMintActionDecoder { id: object::new(ctx) };
    let type_key = type_name::with_defining_ids<TieredMintAction<CoinPlaceholder>>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}
