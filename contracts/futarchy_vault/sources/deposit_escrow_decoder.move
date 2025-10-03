/// Decoder for deposit escrow actions
module futarchy_vault::deposit_escrow_decoder;

use std::{string::String, type_name};
use sui::{object::{Self, UID}, dynamic_object_field, bcs};
use account_protocol::bcs_validation;
use account_protocol::schema::{Self, ActionDecoderRegistry, HumanReadableField};
use futarchy_vault::deposit_escrow_actions::AcceptDepositAction;

// === Decoder Object ===

public struct AcceptDepositActionDecoder has key, store {
    id: UID,
}

// === Decoder Function ===

/// Decode AcceptDepositAction
public fun decode_accept_deposit_action(
    _decoder: &AcceptDepositActionDecoder,
    action_data: vector<u8>,
): vector<HumanReadableField> {
    let mut bcs_data = bcs::new(action_data);

    let escrow_id = bcs::peel_address(&mut bcs_data);
    let vault_name = bcs::peel_vec_u8(&mut bcs_data).to_string();

    bcs_validation::validate_all_bytes_consumed(bcs_data);

    vector[
        schema::new_field(
            b"escrow_id".to_string(),
            escrow_id.to_string(),
            b"ID".to_string(),
        ),
        schema::new_field(
            b"vault_name".to_string(),
            vault_name,
            b"String".to_string(),
        ),
    ]
}

// === Registration ===

/// Register decoder
public fun register_decoder(
    registry: &mut ActionDecoderRegistry,
    ctx: &mut TxContext,
) {
    let decoder = AcceptDepositActionDecoder { id: object::new(ctx) };
    let type_key = type_name::with_defining_ids<AcceptDepositAction>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}
