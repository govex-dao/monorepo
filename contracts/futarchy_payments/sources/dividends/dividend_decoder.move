/// Decoder for dividend actions in futarchy DAOs
module futarchy_payments::dividend_decoder;

use account_protocol::bcs_validation;
use account_protocol::schema::{Self, ActionDecoderRegistry, HumanReadableField};
use std::type_name;
use sui::bcs;
use sui::dynamic_object_field;
use sui::object::{Self, UID, ID};

// === Decoder Objects ===

/// Decoder for CreateDividendAction
public struct CreateDividendActionDecoder has key, store {
    id: UID,
}

/// Placeholder for generic registration
public struct CoinPlaceholder has drop, store {}

// === Decoder Functions ===

/// Decode a CreateDividendAction (tree-based)
public fun decode_create_dividend_action<CoinType>(
    _decoder: &CreateDividendActionDecoder,
    action_data: vector<u8>,
): vector<HumanReadableField> {
    let mut bcs_data = bcs::new(action_data);

    // New format: just tree_id
    let tree_id_bytes = bcs::peel_address(&mut bcs_data);
    let tree_id = tree_id_bytes.to_id();

    // Security: ensure all bytes are consumed to prevent trailing data attacks
    bcs_validation::validate_all_bytes_consumed(bcs_data);

    vector[
        schema::new_field(
            b"tree_id".to_string(),
            tree_id.to_address().to_string(),
            b"ID".to_string(),
        ),
        schema::new_field(
            b"note".to_string(),
            b"Pre-built DividendTree object. Query tree for recipient details.".to_string(),
            b"String".to_string(),
        ),
    ]
}

// === Registration Functions ===

/// Register dividend decoder
public fun register_decoders(registry: &mut ActionDecoderRegistry, ctx: &mut TxContext) {
    register_create_dividend_decoder(registry, ctx);
}

fun register_create_dividend_decoder(registry: &mut ActionDecoderRegistry, ctx: &mut TxContext) {
    let decoder = CreateDividendActionDecoder { id: object::new(ctx) };
    let type_key = type_name::with_defining_ids<
        futarchy_payments::dividend_actions::CreateDividendAction<CoinPlaceholder>,
    >();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}
