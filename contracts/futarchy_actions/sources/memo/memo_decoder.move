/// Decoder for memo actions
module futarchy_actions::memo_decoder;

use account_protocol::bcs_validation;
use account_protocol::schema::{Self, ActionDecoderRegistry, HumanReadableField};
use futarchy_actions::memo_actions::EmitMemoAction;
use std::string::String;
use std::type_name;
use sui::bcs;
use sui::dynamic_object_field;
use sui::object::{Self, UID};

public struct MemoActionDecoder has key, store {
    id: UID,
}

public fun decode_memo_action(
    _decoder: &MemoActionDecoder,
    action_data: vector<u8>,
): vector<HumanReadableField> {
    let mut bcs_data = bcs::new(action_data);
    let message = bcs::peel_vec_u8(&mut bcs_data).to_string();
    bcs_validation::validate_all_bytes_consumed(bcs_data);

    vector[
        schema::new_field(
            b"message".to_string(),
            message,
            b"String".to_string(),
        ),
    ]
}

public fun register_decoders(registry: &mut ActionDecoderRegistry, ctx: &mut TxContext) {
    let decoder = MemoActionDecoder { id: object::new(ctx) };
    let type_key = type_name::with_defining_ids<EmitMemoAction>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}
