/// Decoder for liquidity-related actions in futarchy DAOs
module futarchy_actions::liquidity_decoder;

// === Imports ===

use std::{string::String, type_name, option::{Self, Option}};
use sui::{object::{Self, UID}, dynamic_object_field, bcs};
use account_protocol::bcs_validation;
use account_protocol::schema::{Self, ActionDecoderRegistry, HumanReadableField};
// Import action structs from liquidity_actions (now properly exported)
use futarchy_actions::liquidity_actions::{
    CreatePoolAction,
    UpdatePoolParamsAction,
    RemoveLiquidityAction,
    SwapAction,
    CollectFeesAction,
    SetPoolEnabledAction,
    WithdrawFeesAction,
    SetPoolStatusAction,
};
use futarchy_one_shot_utils::action_data_structs::{AddLiquidityAction};

// === Decoder Objects ===

/// Decoder for CreatePoolAction
public struct CreatePoolActionDecoder has key, store {
    id: UID,
}

/// Decoder for UpdatePoolParamsAction
public struct UpdatePoolParamsActionDecoder has key, store {
    id: UID,
}

/// Decoder for AddLiquidityAction
public struct AddLiquidityActionDecoder has key, store {
    id: UID,
}

/// Decoder for RemoveLiquidityAction
public struct RemoveLiquidityActionDecoder has key, store {
    id: UID,
}

/// Decoder for SwapAction
public struct SwapActionDecoder has key, store {
    id: UID,
}

/// Decoder for CollectFeesAction
public struct CollectFeesActionDecoder has key, store {
    id: UID,
}

/// Decoder for SetPoolEnabledAction
public struct SetPoolEnabledActionDecoder has key, store {
    id: UID,
}

/// Decoder for WithdrawFeesAction
public struct WithdrawFeesActionDecoder has key, store {
    id: UID,
}

/// Decoder for SetPoolStatusAction
public struct SetPoolStatusActionDecoder has key, store {
    id: UID,
}

/// Placeholder for generic registration
public struct AssetPlaceholder has drop, store {}
public struct StablePlaceholder has drop, store {}

// === Decoder Functions ===

/// Decode a CreatePoolAction
public fun decode_create_pool_action<AssetType, StableType>(
    _decoder: &CreatePoolActionDecoder,
    action_data: vector<u8>,
): vector<HumanReadableField> {
    let mut bcs_data = bcs::new(action_data);

    let initial_asset_amount = bcs::peel_u64(&mut bcs_data);
    let initial_stable_amount = bcs::peel_u64(&mut bcs_data);
    let fee_bps = bcs::peel_u64(&mut bcs_data);
    let protocol_fee_bps = bcs::peel_u64(&mut bcs_data);

    // Security: ensure all bytes are consumed to prevent trailing data attacks
    bcs_validation::validate_all_bytes_consumed(bcs_data);

    vector[
        schema::new_field(
            b"initial_asset_amount".to_string(),
            initial_asset_amount.to_string(),
            b"u64".to_string(),
        ),
        schema::new_field(
            b"initial_stable_amount".to_string(),
            initial_stable_amount.to_string(),
            b"u64".to_string(),
        ),
        schema::new_field(
            b"fee_bps".to_string(),
            fee_bps.to_string(),
            b"u64".to_string(),
        ),
        schema::new_field(
            b"protocol_fee_bps".to_string(),
            protocol_fee_bps.to_string(),
            b"u64".to_string(),
        ),
    ]
}

/// Decode an UpdatePoolParamsAction
public fun decode_update_pool_params_action<AssetType, StableType>(
    _decoder: &UpdatePoolParamsActionDecoder,
    action_data: vector<u8>,
): vector<HumanReadableField> {
    let mut bcs_data = bcs::new(action_data);

    let pool_id = bcs::peel_address(&mut bcs_data);
    let new_fee_bps = bcs::peel_option_u64(&mut bcs_data);
    let new_protocol_fee_bps = bcs::peel_option_u64(&mut bcs_data);

    // Security: ensure all bytes are consumed to prevent trailing data attacks
    bcs_validation::validate_all_bytes_consumed(bcs_data);

    let mut fields = vector[
        schema::new_field(
            b"pool_id".to_string(),
            pool_id.to_string(),
            b"ID".to_string(),
        ),
    ];

    if (new_fee_bps.is_some()) {
        fields.push_back(schema::new_field(
            b"new_fee_bps".to_string(),
            new_fee_bps.destroy_some().to_string(),
            b"u64".to_string(),
        ));
    } else {
        new_fee_bps.destroy_none();
    };

    if (new_protocol_fee_bps.is_some()) {
        fields.push_back(schema::new_field(
            b"new_protocol_fee_bps".to_string(),
            new_protocol_fee_bps.destroy_some().to_string(),
            b"u64".to_string(),
        ));
    } else {
        new_protocol_fee_bps.destroy_none();
    };

    fields
}

// === Helper Functions ===

fun peel_option_u64(bcs_data: &mut bcs::BCS): Option<u64> {
    let is_some = bcs::peel_bool(bcs_data);
    if (is_some) {
        option::some(bcs::peel_u64(bcs_data))
    } else {
        option::none()
    }
}

// === Registration Functions ===

/// Register all liquidity decoders
public fun register_decoders(
    registry: &mut ActionDecoderRegistry,
    ctx: &mut TxContext,
) {
    register_create_pool_decoder(registry, ctx);
    register_update_pool_params_decoder(registry, ctx);
    register_add_liquidity_decoder(registry, ctx);
    register_remove_liquidity_decoder(registry, ctx);
    register_swap_decoder(registry, ctx);
    register_collect_fees_decoder(registry, ctx);
    register_set_pool_enabled_decoder(registry, ctx);
    register_withdraw_fees_decoder(registry, ctx);
}

fun register_create_pool_decoder(
    registry: &mut ActionDecoderRegistry,
    ctx: &mut TxContext,
) {
    let decoder = CreatePoolActionDecoder { id: object::new(ctx) };
    let type_key = type_name::with_defining_ids<CreatePoolAction<AssetPlaceholder, StablePlaceholder>>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}

fun register_update_pool_params_decoder(
    registry: &mut ActionDecoderRegistry,
    ctx: &mut TxContext,
) {
    let decoder = UpdatePoolParamsActionDecoder { id: object::new(ctx) };
    let type_key = type_name::with_defining_ids<UpdatePoolParamsAction>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}

fun register_add_liquidity_decoder(
    registry: &mut ActionDecoderRegistry,
    ctx: &mut TxContext,
) {
    let decoder = AddLiquidityActionDecoder { id: object::new(ctx) };
    let type_key = type_name::with_defining_ids<AddLiquidityAction<AssetPlaceholder, StablePlaceholder>>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}

fun register_remove_liquidity_decoder(
    registry: &mut ActionDecoderRegistry,
    ctx: &mut TxContext,
) {
    let decoder = RemoveLiquidityActionDecoder { id: object::new(ctx) };
    let type_key = type_name::with_defining_ids<RemoveLiquidityAction<AssetPlaceholder, StablePlaceholder>>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}

fun register_swap_decoder(
    registry: &mut ActionDecoderRegistry,
    ctx: &mut TxContext,
) {
    let decoder = SwapActionDecoder { id: object::new(ctx) };
    let type_key = type_name::with_defining_ids<SwapAction<AssetPlaceholder, StablePlaceholder>>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}

fun register_collect_fees_decoder(
    registry: &mut ActionDecoderRegistry,
    ctx: &mut TxContext,
) {
    let decoder = CollectFeesActionDecoder { id: object::new(ctx) };
    let type_key = type_name::with_defining_ids<CollectFeesAction<AssetPlaceholder, StablePlaceholder>>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}

fun register_set_pool_enabled_decoder(
    registry: &mut ActionDecoderRegistry,
    ctx: &mut TxContext,
) {
    let decoder = SetPoolEnabledActionDecoder { id: object::new(ctx) };
    let type_key = type_name::with_defining_ids<SetPoolEnabledAction>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}

fun register_withdraw_fees_decoder(
    registry: &mut ActionDecoderRegistry,
    ctx: &mut TxContext,
) {
    let decoder = WithdrawFeesActionDecoder { id: object::new(ctx) };
    let type_key = type_name::with_defining_ids<WithdrawFeesAction<AssetPlaceholder, StablePlaceholder>>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}
