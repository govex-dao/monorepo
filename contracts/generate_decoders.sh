#!/bin/bash

# Script to generate decoder modules for all Futarchy actions
# This follows the established pattern from dissolution_decoder and config_decoder

echo "Generating decoder modules for Futarchy actions..."

# Create liquidity decoder
cat > contracts/futarchy_actions/sources/liquidity/liquidity_decoder.move << 'EOF'
/// Decoder for liquidity-related actions in futarchy DAOs
module futarchy_actions::liquidity_decoder;

// === Imports ===

use std::{string::String, type_name};
use sui::{object::{Self, UID}, dynamic_object_field, bcs};
use account_protocol::bcs_validation;
use account_protocol::schema::{Self, ActionDecoderRegistry, HumanReadableField};
use futarchy_actions::liquidity_actions::{
    CreatePoolAction,
    UpdatePoolParamsAction,
    AddLiquidityAction,
    RemoveLiquidityAction,
    SwapAction,
    CollectFeesAction,
    SetPoolEnabledAction,
    WithdrawFeesAction,
};

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

fun peel_option_u64(bcs_data: &mut BCS): Option<u64> {
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
    let type_key = type_name::get<CreatePoolAction<AssetPlaceholder, StablePlaceholder>>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}

fun register_update_pool_params_decoder(
    registry: &mut ActionDecoderRegistry,
    ctx: &mut TxContext,
) {
    let decoder = UpdatePoolParamsActionDecoder { id: object::new(ctx) };
    let type_key = type_name::get<UpdatePoolParamsAction<AssetPlaceholder, StablePlaceholder>>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}

fun register_add_liquidity_decoder(
    registry: &mut ActionDecoderRegistry,
    ctx: &mut TxContext,
) {
    let decoder = AddLiquidityActionDecoder { id: object::new(ctx) };
    let type_key = type_name::get<AddLiquidityAction<AssetPlaceholder, StablePlaceholder>>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}

fun register_remove_liquidity_decoder(
    registry: &mut ActionDecoderRegistry,
    ctx: &mut TxContext,
) {
    let decoder = RemoveLiquidityActionDecoder { id: object::new(ctx) };
    let type_key = type_name::get<RemoveLiquidityAction<AssetPlaceholder, StablePlaceholder>>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}

fun register_swap_decoder(
    registry: &mut ActionDecoderRegistry,
    ctx: &mut TxContext,
) {
    let decoder = SwapActionDecoder { id: object::new(ctx) };
    let type_key = type_name::get<SwapAction<AssetPlaceholder, StablePlaceholder>>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}

fun register_collect_fees_decoder(
    registry: &mut ActionDecoderRegistry,
    ctx: &mut TxContext,
) {
    let decoder = CollectFeesActionDecoder { id: object::new(ctx) };
    let type_key = type_name::get<CollectFeesAction<AssetPlaceholder, StablePlaceholder>>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}

fun register_set_pool_enabled_decoder(
    registry: &mut ActionDecoderRegistry,
    ctx: &mut TxContext,
) {
    let decoder = SetPoolEnabledActionDecoder { id: object::new(ctx) };
    let type_key = type_name::get<SetPoolEnabledAction<AssetPlaceholder, StablePlaceholder>>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}

fun register_withdraw_fees_decoder(
    registry: &mut ActionDecoderRegistry,
    ctx: &mut TxContext,
) {
    let decoder = WithdrawFeesActionDecoder { id: object::new(ctx) };
    let type_key = type_name::get<WithdrawFeesAction<AssetPlaceholder, StablePlaceholder>>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}
EOF

echo "✓ Created liquidity_decoder.move"

# Create oracle decoder
cat > contracts/futarchy_lifecycle/sources/oracle/oracle_decoder.move << 'EOF'
/// Decoder for oracle-related actions in futarchy DAOs
module futarchy_lifecycle::oracle_decoder;

// === Imports ===

use std::{string::String, type_name};
use sui::{object::{Self, UID}, dynamic_object_field, bcs};
use account_protocol::bcs_validation;
use account_protocol::schema::{Self, ActionDecoderRegistry, HumanReadableField};
use futarchy_lifecycle::oracle_actions::{
    ReadOraclePriceAction,
    ConditionalMintAction,
    TieredMintAction,
};

// === Decoder Objects ===

/// Decoder for ReadOraclePriceAction
public struct ReadOraclePriceActionDecoder has key, store {
    id: UID,
}

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

/// Decode a ReadOraclePriceAction
public fun decode_read_oracle_price_action<AssetType, StableType>(
    _decoder: &ReadOraclePriceActionDecoder,
    action_data: vector<u8>,
): vector<HumanReadableField> {
    let mut bcs_data = bcs::new(action_data);

    let pool_id = bcs::peel_address(&mut bcs_data);
    let min_observations = bcs::peel_u64(&mut bcs_data);

    // Security: ensure all bytes are consumed to prevent trailing data attacks
    bcs_validation::validate_all_bytes_consumed(bcs_data);

    vector[
        schema::new_field(
            b"pool_id".to_string(),
            pool_id.to_string(),
            b"ID".to_string(),
        ),
        schema::new_field(
            b"min_observations".to_string(),
            min_observations.to_string(),
            b"u64".to_string(),
        ),
    ]
}

/// Decode a ConditionalMintAction
public fun decode_conditional_mint_action<CoinType>(
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
public fun decode_tiered_mint_action<CoinType>(
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
    register_read_oracle_price_decoder(registry, ctx);
    register_conditional_mint_decoder(registry, ctx);
    register_tiered_mint_decoder(registry, ctx);
}

fun register_read_oracle_price_decoder(
    registry: &mut ActionDecoderRegistry,
    ctx: &mut TxContext,
) {
    let decoder = ReadOraclePriceActionDecoder { id: object::new(ctx) };
    let type_key = type_name::get<ReadOraclePriceAction<AssetPlaceholder, StablePlaceholder>>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}

fun register_conditional_mint_decoder(
    registry: &mut ActionDecoderRegistry,
    ctx: &mut TxContext,
) {
    let decoder = ConditionalMintActionDecoder { id: object::new(ctx) };
    let type_key = type_name::get<ConditionalMintAction<CoinPlaceholder>>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}

fun register_tiered_mint_decoder(
    registry: &mut ActionDecoderRegistry,
    ctx: &mut TxContext,
) {
    let decoder = TieredMintActionDecoder { id: object::new(ctx) };
    let type_key = type_name::get<TieredMintAction<CoinPlaceholder>>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}
EOF

echo "✓ Created oracle_decoder.move"

# Create stream decoder
cat > contracts/futarchy_lifecycle/sources/payments/stream_decoder.move << 'EOF'
/// Decoder for stream/payment actions in futarchy DAOs
module futarchy_lifecycle::stream_decoder;

// === Imports ===

use std::{string::String, type_name};
use sui::{object::{Self, UID}, dynamic_object_field, bcs};
use account_protocol::bcs_validation;
use account_protocol::schema::{Self, ActionDecoderRegistry, HumanReadableField};
use futarchy_lifecycle::stream_actions::{
    CreateStreamAction,
    CancelStreamAction,
    WithdrawStreamAction,
    UpdateStreamAction,
    PauseStreamAction,
    ResumeStreamAction,
};

// === Decoder Objects ===

/// Decoder for CreateStreamAction
public struct CreateStreamActionDecoder has key, store {
    id: UID,
}

/// Decoder for CancelStreamAction
public struct CancelStreamActionDecoder has key, store {
    id: UID,
}

/// Decoder for WithdrawStreamAction
public struct WithdrawStreamActionDecoder has key, store {
    id: UID,
}

/// Decoder for UpdateStreamAction
public struct UpdateStreamActionDecoder has key, store {
    id: UID,
}

/// Decoder for PauseStreamAction
public struct PauseStreamActionDecoder has key, store {
    id: UID,
}

/// Decoder for ResumeStreamAction
public struct ResumeStreamActionDecoder has key, store {
    id: UID,
}

/// Placeholder for generic registration
public struct CoinPlaceholder has drop, store {}

// === Decoder Functions ===

/// Decode a CreateStreamAction
public fun decode_create_stream_action<CoinType>(
    _decoder: &CreateStreamActionDecoder,
    action_data: vector<u8>,
): vector<HumanReadableField> {
    let mut bcs_data = bcs::new(action_data);

    let recipient = bcs::peel_address(&mut bcs_data);
    let amount_per_period = bcs::peel_u64(&mut bcs_data);
    let period_duration_ms = bcs::peel_u64(&mut bcs_data);
    let start_time = bcs::peel_u64(&mut bcs_data);
    let end_time = bcs::peel_option_u64(&mut bcs_data);
    let cliff_time = bcs::peel_option_u64(&mut bcs_data);
    let cancellable = bcs::peel_bool(&mut bcs_data);
    let description = bcs::peel_vec_u8(&mut bcs_data).to_string();

    // Security: ensure all bytes are consumed to prevent trailing data attacks
    bcs_validation::validate_all_bytes_consumed(bcs_data);

    let mut fields = vector[
        schema::new_field(
            b"recipient".to_string(),
            recipient.to_string(),
            b"address".to_string(),
        ),
        schema::new_field(
            b"amount_per_period".to_string(),
            amount_per_period.to_string(),
            b"u64".to_string(),
        ),
        schema::new_field(
            b"period_duration_ms".to_string(),
            period_duration_ms.to_string(),
            b"u64".to_string(),
        ),
        schema::new_field(
            b"start_time".to_string(),
            start_time.to_string(),
            b"u64".to_string(),
        ),
        schema::new_field(
            b"cancellable".to_string(),
            if (cancellable) { b"true" } else { b"false" }.to_string(),
            b"bool".to_string(),
        ),
        schema::new_field(
            b"description".to_string(),
            description,
            b"String".to_string(),
        ),
    ];

    if (end_time.is_some()) {
        fields.push_back(schema::new_field(
            b"end_time".to_string(),
            end_time.destroy_some().to_string(),
            b"u64".to_string(),
        ));
    } else {
        end_time.destroy_none();
    };

    if (cliff_time.is_some()) {
        fields.push_back(schema::new_field(
            b"cliff_time".to_string(),
            cliff_time.destroy_some().to_string(),
            b"u64".to_string(),
        ));
    } else {
        cliff_time.destroy_none();
    };

    fields
}

/// Decode a CancelStreamAction
public fun decode_cancel_stream_action(
    _decoder: &CancelStreamActionDecoder,
    action_data: vector<u8>,
): vector<HumanReadableField> {
    let mut bcs_data = bcs::new(action_data);

    let stream_id = bcs::peel_address(&mut bcs_data);
    let reason = bcs::peel_vec_u8(&mut bcs_data).to_string();

    // Security: ensure all bytes are consumed to prevent trailing data attacks
    bcs_validation::validate_all_bytes_consumed(bcs_data);

    vector[
        schema::new_field(
            b"stream_id".to_string(),
            stream_id.to_string(),
            b"ID".to_string(),
        ),
        schema::new_field(
            b"reason".to_string(),
            reason,
            b"String".to_string(),
        ),
    ]
}

// === Helper Functions ===

fun peel_option_u64(bcs_data: &mut BCS): Option<u64> {
    let is_some = bcs::peel_bool(bcs_data);
    if (is_some) {
        option::some(bcs::peel_u64(bcs_data))
    } else {
        option::none()
    }
}

// === Registration Functions ===

/// Register all stream decoders
public fun register_decoders(
    registry: &mut ActionDecoderRegistry,
    ctx: &mut TxContext,
) {
    register_create_stream_decoder(registry, ctx);
    register_cancel_stream_decoder(registry, ctx);
    register_withdraw_stream_decoder(registry, ctx);
    register_update_stream_decoder(registry, ctx);
    register_pause_stream_decoder(registry, ctx);
    register_resume_stream_decoder(registry, ctx);
}

fun register_create_stream_decoder(
    registry: &mut ActionDecoderRegistry,
    ctx: &mut TxContext,
) {
    let decoder = CreateStreamActionDecoder { id: object::new(ctx) };
    let type_key = type_name::get<CreateStreamAction<CoinPlaceholder>>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}

fun register_cancel_stream_decoder(
    registry: &mut ActionDecoderRegistry,
    ctx: &mut TxContext,
) {
    let decoder = CancelStreamActionDecoder { id: object::new(ctx) };
    let type_key = type_name::get<CancelStreamAction>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}

fun register_withdraw_stream_decoder(
    registry: &mut ActionDecoderRegistry,
    ctx: &mut TxContext,
) {
    let decoder = WithdrawStreamActionDecoder { id: object::new(ctx) };
    let type_key = type_name::get<WithdrawStreamAction>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}

fun register_update_stream_decoder(
    registry: &mut ActionDecoderRegistry,
    ctx: &mut TxContext,
) {
    let decoder = UpdateStreamActionDecoder { id: object::new(ctx) };
    let type_key = type_name::get<UpdateStreamAction>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}

fun register_pause_stream_decoder(
    registry: &mut ActionDecoderRegistry,
    ctx: &mut TxContext,
) {
    let decoder = PauseStreamActionDecoder { id: object::new(ctx) };
    let type_key = type_name::get<PauseStreamAction>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}

fun register_resume_stream_decoder(
    registry: &mut ActionDecoderRegistry,
    ctx: &mut TxContext,
) {
    let decoder = ResumeStreamActionDecoder { id: object::new(ctx) };
    let type_key = type_name::get<ResumeStreamAction>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}
EOF

echo "✓ Created stream_decoder.move"

echo "✓ Decoder generation script complete!"
echo ""
echo "Note: This script creates stub implementations for demonstration."
echo "You'll need to:"
echo "1. Review the actual action structs in each module"
echo "2. Update the decoder functions to match the actual struct fields"
echo "3. Add proper BCS deserialization for each field"
echo "4. Ensure all decoders are registered in futarchy_decoder_registry.move"

chmod +x contracts/generate_decoders.sh