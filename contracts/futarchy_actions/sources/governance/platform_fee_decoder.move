/// Decoder for platform fee actions
module futarchy_actions::platform_fee_decoder;

use account_protocol::schema::{Self, ActionDecoderRegistry, HumanReadableField};
use futarchy_actions::platform_fee_actions::{
    Self as platform_fee_actions,
    CollectPlatformFeeAction
};
use std::string::String;
use std::type_name;
use sui::dynamic_object_field;
use sui::object::{Self, UID};
use sui::tx_context::TxContext;

public struct CollectPlatformFeeActionDecoder has key, store {
    id: UID,
}

/// Decode CollectPlatformFeeAction into human-readable fields
public fun decode_collect_platform_fee_action(
    _decoder: &CollectPlatformFeeActionDecoder,
    action_data: vector<u8>,
): vector<HumanReadableField> {
    let action = platform_fee_actions::collect_platform_fee_action_from_bytes(action_data);
    let vault_name = platform_fee_actions::get_vault_name(&action);
    let max_amount = platform_fee_actions::get_max_amount(&action);

    vector[
        schema::new_field(
            b"vault_name".to_string(),
            vault_name,
            b"String".to_string(),
        ),
        schema::new_field(
            b"max_amount".to_string(),
            max_amount.to_string(),
            b"u64".to_string(),
        ),
    ]
}

/// Register decoders for platform fee actions
public fun register_decoders(registry: &mut ActionDecoderRegistry, ctx: &mut TxContext) {
    let decoder = CollectPlatformFeeActionDecoder { id: object::new(ctx) };
    let type_key = type_name::with_defining_ids<CollectPlatformFeeAction>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}
