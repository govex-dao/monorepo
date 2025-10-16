/// Decoder for dissolution-related actions in futarchy DAOs
module futarchy_lifecycle::dissolution_decoder;

use account_protocol::bcs_validation;
use account_protocol::schema::{Self, ActionDecoderRegistry, HumanReadableField};
use futarchy_lifecycle::dissolution_actions::{
    InitiateDissolutionAction,
    BatchDistributeAction,
    FinalizeDissolutionAction,
    CancelDissolutionAction,
    CalculateProRataSharesAction,
    CancelAllStreamsAction,
    WithdrawAmmLiquidityAction,
    DistributeAssetsAction,
    CreateAuctionAction
};
use std::string::String;
use std::type_name;
use sui::bcs;
use sui::dynamic_object_field;
use sui::object::{Self, UID};

// === Imports ===

// === Decoder Objects ===

/// Decoder for InitiateDissolutionAction
public struct InitiateDissolutionActionDecoder has key, store {
    id: UID,
}

/// Decoder for BatchDistributeAction
public struct BatchDistributeActionDecoder has key, store {
    id: UID,
}

/// Decoder for FinalizeDissolutionAction
public struct FinalizeDissolutionActionDecoder has key, store {
    id: UID,
}

/// Decoder for CancelDissolutionAction
public struct CancelDissolutionActionDecoder has key, store {
    id: UID,
}

/// Decoder for CalculateProRataSharesAction
public struct CalculateProRataSharesActionDecoder has key, store {
    id: UID,
}

/// Decoder for CancelAllStreamsAction
public struct CancelAllStreamsActionDecoder has key, store {
    id: UID,
}

/// Decoder for WithdrawAmmLiquidityAction
public struct WithdrawAmmLiquidityActionDecoder has key, store {
    id: UID,
}

/// Decoder for DistributeAssetsAction
public struct DistributeAssetsActionDecoder has key, store {
    id: UID,
}

/// Decoder for CreateAuctionAction
public struct CreateAuctionActionDecoder has key, store {
    id: UID,
}

/// Placeholder for generic registration
public struct AssetPlaceholder has drop, store {}
public struct StablePlaceholder has drop, store {}
public struct CoinPlaceholder has drop, store {}

// === Decoder Functions ===

/// Decode an InitiateDissolutionAction
public fun decode_initiate_dissolution_action(
    _decoder: &InitiateDissolutionActionDecoder,
    action_data: vector<u8>,
): vector<HumanReadableField> {
    let mut bcs_data = bcs::new(action_data);
    let reason = bcs::peel_vec_u8(&mut bcs_data).to_string();
    let distribution_method = bcs::peel_u8(&mut bcs_data);
    let burn_unsold_tokens = bcs::peel_bool(&mut bcs_data);
    let final_operations_deadline = bcs::peel_u64(&mut bcs_data);

    // Security: ensure all bytes are consumed to prevent trailing data attacks
    bcs_validation::validate_all_bytes_consumed(bcs_data);

    let distribution_method_str = if (distribution_method == 0) {
        b"pro-rata"
    } else if (distribution_method == 1) {
        b"equal"
    } else {
        b"custom"
    };

    vector[
        schema::new_field(
            b"reason".to_string(),
            reason,
            b"String".to_string(),
        ),
        schema::new_field(
            b"distribution_method".to_string(),
            distribution_method_str.to_string(),
            b"String".to_string(),
        ),
        schema::new_field(
            b"burn_unsold_tokens".to_string(),
            if (burn_unsold_tokens) { b"true" } else { b"false" }.to_string(),
            b"bool".to_string(),
        ),
        schema::new_field(
            b"final_operations_deadline".to_string(),
            final_operations_deadline.to_string(),
            b"u64".to_string(),
        ),
    ]
}

/// Decode a BatchDistributeAction
public fun decode_batch_distribute_action(
    _decoder: &BatchDistributeActionDecoder,
    action_data: vector<u8>,
): vector<HumanReadableField> {
    let mut bcs_data = bcs::new(action_data);

    // Read vector of asset types (vector of strings)
    let asset_types_count = bcs::peel_vec_length(&mut bcs_data);
    let mut asset_types = vector::empty<String>();
    let mut i = 0;
    while (i < asset_types_count) {
        let asset_type = bcs::peel_vec_u8(&mut bcs_data).to_string();
        asset_types.push_back(asset_type);
        i = i + 1;
    };

    // Security: ensure all bytes are consumed to prevent trailing data attacks
    bcs_validation::validate_all_bytes_consumed(bcs_data);

    // Join asset types with commas for display
    let mut asset_types_str = b"[".to_string();
    let mut j = 0;
    while (j < asset_types.length()) {
        if (j > 0) {
            asset_types_str.append(b", ".to_string());
        };
        asset_types_str.append(asset_types[j]);
        j = j + 1;
    };
    asset_types_str.append(b"]".to_string());

    vector[
        schema::new_field(
            b"asset_types".to_string(),
            asset_types_str,
            b"vector<String>".to_string(),
        ),
    ]
}

/// Decode a FinalizeDissolutionAction
public fun decode_finalize_dissolution_action(
    _decoder: &FinalizeDissolutionActionDecoder,
    action_data: vector<u8>,
): vector<HumanReadableField> {
    let mut bcs_data = bcs::new(action_data);
    let final_recipient = bcs::peel_address(&mut bcs_data);
    let destroy_account = bcs::peel_bool(&mut bcs_data);

    // Security: ensure all bytes are consumed to prevent trailing data attacks
    bcs_validation::validate_all_bytes_consumed(bcs_data);

    vector[
        schema::new_field(
            b"final_recipient".to_string(),
            final_recipient.to_string(),
            b"address".to_string(),
        ),
        schema::new_field(
            b"destroy_account".to_string(),
            if (destroy_account) { b"true" } else { b"false" }.to_string(),
            b"bool".to_string(),
        ),
    ]
}

/// Decode a CancelDissolutionAction
public fun decode_cancel_dissolution_action(
    _decoder: &CancelDissolutionActionDecoder,
    action_data: vector<u8>,
): vector<HumanReadableField> {
    let mut bcs_data = bcs::new(action_data);
    let reason = bcs::peel_vec_u8(&mut bcs_data).to_string();

    // Security: ensure all bytes are consumed to prevent trailing data attacks
    bcs_validation::validate_all_bytes_consumed(bcs_data);

    vector[
        schema::new_field(
            b"reason".to_string(),
            reason,
            b"String".to_string(),
        ),
    ]
}

/// Decode a CalculateProRataSharesAction
public fun decode_calculate_pro_rata_shares_action(
    _decoder: &CalculateProRataSharesActionDecoder,
    action_data: vector<u8>,
): vector<HumanReadableField> {
    let mut bcs_data = bcs::new(action_data);
    let total_supply = bcs::peel_u64(&mut bcs_data);
    let exclude_dao_tokens = bcs::peel_bool(&mut bcs_data);

    // Security: ensure all bytes are consumed to prevent trailing data attacks
    bcs_validation::validate_all_bytes_consumed(bcs_data);

    vector[
        schema::new_field(
            b"total_supply".to_string(),
            total_supply.to_string(),
            b"u64".to_string(),
        ),
        schema::new_field(
            b"exclude_dao_tokens".to_string(),
            if (exclude_dao_tokens) { b"true" } else { b"false" }.to_string(),
            b"bool".to_string(),
        ),
    ]
}

/// Decode a CancelAllStreamsAction
public fun decode_cancel_all_streams_action(
    _decoder: &CancelAllStreamsActionDecoder,
    action_data: vector<u8>,
): vector<HumanReadableField> {
    let mut bcs_data = bcs::new(action_data);
    let return_to_treasury = bcs::peel_bool(&mut bcs_data);

    // Security: ensure all bytes are consumed to prevent trailing data attacks
    bcs_validation::validate_all_bytes_consumed(bcs_data);

    vector[
        schema::new_field(
            b"return_to_treasury".to_string(),
            if (return_to_treasury) { b"true" } else { b"false" }.to_string(),
            b"bool".to_string(),
        ),
    ]
}

/// Decode a WithdrawAmmLiquidityAction
public fun decode_withdraw_amm_liquidity_action<AssetType, StableType>(
    _decoder: &WithdrawAmmLiquidityActionDecoder,
    action_data: vector<u8>,
): vector<HumanReadableField> {
    let mut bcs_data = bcs::new(action_data);
    let pool_id = bcs::peel_address(&mut bcs_data);
    let dao_owned_lp_amount = bcs::peel_u64(&mut bcs_data);
    let bypass_minimum = bcs::peel_bool(&mut bcs_data);

    // Security: ensure all bytes are consumed to prevent trailing data attacks
    bcs_validation::validate_all_bytes_consumed(bcs_data);

    vector[
        schema::new_field(
            b"pool_id".to_string(),
            pool_id.to_string(),
            b"ID".to_string(),
        ),
        schema::new_field(
            b"dao_owned_lp_amount".to_string(),
            dao_owned_lp_amount.to_string(),
            b"u64".to_string(),
        ),
        schema::new_field(
            b"bypass_minimum".to_string(),
            if (bypass_minimum) { b"true" } else { b"false" }.to_string(),
            b"bool".to_string(),
        ),
    ]
}

/// Decode a DistributeAssetsAction
public fun decode_distribute_assets_action<CoinType>(
    _decoder: &DistributeAssetsActionDecoder,
    action_data: vector<u8>,
): vector<HumanReadableField> {
    let mut bcs_data = bcs::new(action_data);

    // Read holders vector
    let holders_count = bcs::peel_vec_length(&mut bcs_data);
    let mut holders = vector::empty<address>();
    let mut i = 0;
    while (i < holders_count) {
        let holder = bcs::peel_address(&mut bcs_data);
        holders.push_back(holder);
        i = i + 1;
    };

    // Read holder amounts vector
    let amounts_count = bcs::peel_vec_length(&mut bcs_data);
    let mut holder_amounts = vector::empty<u64>();
    let mut j = 0;
    while (j < amounts_count) {
        let amount = bcs::peel_u64(&mut bcs_data);
        holder_amounts.push_back(amount);
        j = j + 1;
    };

    let total_distribution_amount = bcs::peel_u64(&mut bcs_data);

    // Security: ensure all bytes are consumed to prevent trailing data attacks
    bcs_validation::validate_all_bytes_consumed(bcs_data);

    vector[
        schema::new_field(
            b"holders_count".to_string(),
            holders.length().to_string(),
            b"u64".to_string(),
        ),
        schema::new_field(
            b"total_distribution_amount".to_string(),
            total_distribution_amount.to_string(),
            b"u64".to_string(),
        ),
    ]
}

/// Decode a CreateAuctionAction
public fun decode_create_auction_action(
    _decoder: &CreateAuctionActionDecoder,
    action_data: vector<u8>,
): vector<HumanReadableField> {
    let mut bcs_data = bcs::new(action_data);
    let object_id = bcs::peel_address(&mut bcs_data);
    let object_type = bcs::peel_vec_u8(&mut bcs_data).to_string();
    let bid_coin_type = bcs::peel_vec_u8(&mut bcs_data).to_string();
    let minimum_bid = bcs::peel_u64(&mut bcs_data);
    let duration_ms = bcs::peel_u64(&mut bcs_data);

    // Security: ensure all bytes are consumed to prevent trailing data attacks
    bcs_validation::validate_all_bytes_consumed(bcs_data);

    vector[
        schema::new_field(
            b"object_id".to_string(),
            object_id.to_string(),
            b"ID".to_string(),
        ),
        schema::new_field(
            b"object_type".to_string(),
            object_type,
            b"String".to_string(),
        ),
        schema::new_field(
            b"bid_coin_type".to_string(),
            bid_coin_type,
            b"String".to_string(),
        ),
        schema::new_field(
            b"minimum_bid".to_string(),
            minimum_bid.to_string(),
            b"u64".to_string(),
        ),
        schema::new_field(
            b"duration_ms".to_string(),
            duration_ms.to_string(),
            b"u64".to_string(),
        ),
    ]
}

// === Registration Functions ===

/// Register all dissolution decoders
public fun register_decoders(registry: &mut ActionDecoderRegistry, ctx: &mut TxContext) {
    register_initiate_dissolution_decoder(registry, ctx);
    register_batch_distribute_decoder(registry, ctx);
    register_finalize_dissolution_decoder(registry, ctx);
    register_cancel_dissolution_decoder(registry, ctx);
    register_calculate_pro_rata_shares_decoder(registry, ctx);
    register_cancel_all_streams_decoder(registry, ctx);
    register_withdraw_amm_liquidity_decoder(registry, ctx);
    register_distribute_assets_decoder(registry, ctx);
    register_create_auction_decoder(registry, ctx);
}

fun register_initiate_dissolution_decoder(
    registry: &mut ActionDecoderRegistry,
    ctx: &mut TxContext,
) {
    let decoder = InitiateDissolutionActionDecoder { id: object::new(ctx) };
    let type_key = type_name::with_defining_ids<InitiateDissolutionAction>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}

fun register_batch_distribute_decoder(registry: &mut ActionDecoderRegistry, ctx: &mut TxContext) {
    let decoder = BatchDistributeActionDecoder { id: object::new(ctx) };
    let type_key = type_name::with_defining_ids<BatchDistributeAction>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}

fun register_finalize_dissolution_decoder(
    registry: &mut ActionDecoderRegistry,
    ctx: &mut TxContext,
) {
    let decoder = FinalizeDissolutionActionDecoder { id: object::new(ctx) };
    let type_key = type_name::with_defining_ids<FinalizeDissolutionAction>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}

fun register_cancel_dissolution_decoder(registry: &mut ActionDecoderRegistry, ctx: &mut TxContext) {
    let decoder = CancelDissolutionActionDecoder { id: object::new(ctx) };
    let type_key = type_name::with_defining_ids<CancelDissolutionAction>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}

fun register_calculate_pro_rata_shares_decoder(
    registry: &mut ActionDecoderRegistry,
    ctx: &mut TxContext,
) {
    let decoder = CalculateProRataSharesActionDecoder { id: object::new(ctx) };
    let type_key = type_name::with_defining_ids<CalculateProRataSharesAction>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}

fun register_cancel_all_streams_decoder(registry: &mut ActionDecoderRegistry, ctx: &mut TxContext) {
    let decoder = CancelAllStreamsActionDecoder { id: object::new(ctx) };
    let type_key = type_name::with_defining_ids<CancelAllStreamsAction>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}

fun register_withdraw_amm_liquidity_decoder(
    registry: &mut ActionDecoderRegistry,
    ctx: &mut TxContext,
) {
    let decoder = WithdrawAmmLiquidityActionDecoder { id: object::new(ctx) };
    let type_key = type_name::with_defining_ids<
        WithdrawAmmLiquidityAction<AssetPlaceholder, StablePlaceholder>,
    >();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}

fun register_distribute_assets_decoder(registry: &mut ActionDecoderRegistry, ctx: &mut TxContext) {
    let decoder = DistributeAssetsActionDecoder { id: object::new(ctx) };
    let type_key = type_name::with_defining_ids<DistributeAssetsAction<CoinPlaceholder>>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}

fun register_create_auction_decoder(registry: &mut ActionDecoderRegistry, ctx: &mut TxContext) {
    let decoder = CreateAuctionActionDecoder { id: object::new(ctx) };
    let type_key = type_name::with_defining_ids<CreateAuctionAction>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}
