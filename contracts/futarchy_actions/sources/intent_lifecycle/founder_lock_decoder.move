/// Decoder for founder lock actions in futarchy DAOs
module futarchy_actions::founder_lock_decoder;

use account_protocol::bcs_validation;
use account_protocol::schema::{Self, ActionDecoderRegistry, HumanReadableField};
use futarchy_actions::founder_lock_actions::{
    ExecuteFounderLockAction,
    UpdateFounderLockRecipientAction,
    WithdrawUnlockedTokensAction,
    CreateFounderLockProposalAction
};
use std::string::String;
use std::type_name;
use sui::bcs;
use sui::dynamic_object_field;
use sui::object::{Self, UID};

// === Imports ===

// === Decoder Objects ===

/// Decoder for CreateFounderLockProposalAction
public struct CreateFounderLockProposalActionDecoder has key, store {
    id: UID,
}

/// Decoder for ExecuteFounderLockAction
public struct ExecuteFounderLockActionDecoder has key, store {
    id: UID,
}

/// Decoder for UpdateFounderLockRecipientAction
public struct UpdateFounderLockRecipientActionDecoder has key, store {
    id: UID,
}

/// Decoder for WithdrawUnlockedTokensAction
public struct WithdrawUnlockedTokensActionDecoder has key, store {
    id: UID,
}

/// Placeholder for generic registration
public struct AssetPlaceholder has drop, store {}

// === Decoder Functions ===

/// Decode a CreateFounderLockProposalAction
public fun decode_create_founder_lock_proposal_action<AssetType>(
    _decoder: &CreateFounderLockProposalActionDecoder,
    action_data: vector<u8>,
): vector<HumanReadableField> {
    let mut bcs_data = bcs::new(action_data);

    let committed_amount = bcs::peel_u64(&mut bcs_data);

    // Read tiers vector (vector of PriceTier structs)
    let tiers_count = bcs::peel_vec_length(&mut bcs_data);
    let mut i = 0;
    while (i < tiers_count) {
        // PriceTier has price_threshold (u128) and vesting_amount (u64)
        bcs::peel_u128(&mut bcs_data); // price_threshold
        bcs::peel_u64(&mut bcs_data); // vesting_amount
        i = i + 1;
    };

    let proposal_id = bcs::peel_address(&mut bcs_data);
    let trading_start = bcs::peel_u64(&mut bcs_data);
    let trading_end = bcs::peel_u64(&mut bcs_data);
    let description = bcs::peel_vec_u8(&mut bcs_data).to_string();

    // Security: ensure all bytes are consumed to prevent trailing data attacks
    bcs_validation::validate_all_bytes_consumed(bcs_data);

    vector[
        schema::new_field(
            b"committed_amount".to_string(),
            committed_amount.to_string(),
            b"u64".to_string(),
        ),
        schema::new_field(
            b"tiers_count".to_string(),
            tiers_count.to_string(),
            b"u64".to_string(),
        ),
        schema::new_field(
            b"proposal_id".to_string(),
            proposal_id.to_string(),
            b"ID".to_string(),
        ),
        schema::new_field(
            b"trading_start".to_string(),
            trading_start.to_string(),
            b"u64".to_string(),
        ),
        schema::new_field(
            b"trading_end".to_string(),
            trading_end.to_string(),
            b"u64".to_string(),
        ),
        schema::new_field(
            b"description".to_string(),
            description,
            b"String".to_string(),
        ),
    ]
}

/// Decode an ExecuteFounderLockAction
public fun decode_execute_founder_lock_action(
    _decoder: &ExecuteFounderLockActionDecoder,
    action_data: vector<u8>,
): vector<HumanReadableField> {
    let mut bcs_data = bcs::new(action_data);
    let founder_lock_id = bcs::peel_address(&mut bcs_data);

    // Security: ensure all bytes are consumed to prevent trailing data attacks
    bcs_validation::validate_all_bytes_consumed(bcs_data);

    vector[
        schema::new_field(
            b"founder_lock_id".to_string(),
            founder_lock_id.to_string(),
            b"ID".to_string(),
        ),
    ]
}

/// Decode an UpdateFounderLockRecipientAction
public fun decode_update_founder_lock_recipient_action(
    _decoder: &UpdateFounderLockRecipientActionDecoder,
    action_data: vector<u8>,
): vector<HumanReadableField> {
    let mut bcs_data = bcs::new(action_data);
    let founder_lock_id = bcs::peel_address(&mut bcs_data);
    let new_recipient = bcs::peel_address(&mut bcs_data);

    // Security: ensure all bytes are consumed to prevent trailing data attacks
    bcs_validation::validate_all_bytes_consumed(bcs_data);

    vector[
        schema::new_field(
            b"founder_lock_id".to_string(),
            founder_lock_id.to_string(),
            b"ID".to_string(),
        ),
        schema::new_field(
            b"new_recipient".to_string(),
            new_recipient.to_string(),
            b"address".to_string(),
        ),
    ]
}

/// Decode a WithdrawUnlockedTokensAction
public fun decode_withdraw_unlocked_tokens_action(
    _decoder: &WithdrawUnlockedTokensActionDecoder,
    action_data: vector<u8>,
): vector<HumanReadableField> {
    let mut bcs_data = bcs::new(action_data);
    let founder_lock_id = bcs::peel_address(&mut bcs_data);

    // Security: ensure all bytes are consumed to prevent trailing data attacks
    bcs_validation::validate_all_bytes_consumed(bcs_data);

    vector[
        schema::new_field(
            b"founder_lock_id".to_string(),
            founder_lock_id.to_string(),
            b"ID".to_string(),
        ),
    ]
}

// === Registration Functions ===

/// Register all founder lock decoders
public fun register_decoders(registry: &mut ActionDecoderRegistry, ctx: &mut TxContext) {
    register_create_founder_lock_proposal_decoder(registry, ctx);
    register_execute_founder_lock_decoder(registry, ctx);
    register_update_founder_lock_recipient_decoder(registry, ctx);
    register_withdraw_unlocked_tokens_decoder(registry, ctx);
}

fun register_create_founder_lock_proposal_decoder(
    registry: &mut ActionDecoderRegistry,
    ctx: &mut TxContext,
) {
    let decoder = CreateFounderLockProposalActionDecoder { id: object::new(ctx) };
    let type_key = type_name::with_defining_ids<
        CreateFounderLockProposalAction<AssetPlaceholder>,
    >();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}

fun register_execute_founder_lock_decoder(
    registry: &mut ActionDecoderRegistry,
    ctx: &mut TxContext,
) {
    let decoder = ExecuteFounderLockActionDecoder { id: object::new(ctx) };
    let type_key = type_name::with_defining_ids<ExecuteFounderLockAction>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}

fun register_update_founder_lock_recipient_decoder(
    registry: &mut ActionDecoderRegistry,
    ctx: &mut TxContext,
) {
    let decoder = UpdateFounderLockRecipientActionDecoder { id: object::new(ctx) };
    let type_key = type_name::with_defining_ids<UpdateFounderLockRecipientAction>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}

fun register_withdraw_unlocked_tokens_decoder(
    registry: &mut ActionDecoderRegistry,
    ctx: &mut TxContext,
) {
    let decoder = WithdrawUnlockedTokensActionDecoder { id: object::new(ctx) };
    let type_key = type_name::with_defining_ids<WithdrawUnlockedTokensAction>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}
