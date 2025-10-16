/// Comprehensive tests for dissolution_decoder.move
/// Tests all 8 decoder functions, BCS serialization, and registration
#[test_only]
module futarchy_lifecycle::dissolution_decoder_tests;

use account_protocol::schema::{Self, ActionDecoderRegistry};
use futarchy_lifecycle::dissolution_actions;
use futarchy_lifecycle::dissolution_decoder;
use std::string;
use sui::bcs;
use sui::object;
use sui::test_scenario as ts;
use sui::test_utils::assert_eq;

// === Test Addresses ===
const ADMIN: address = @0xAD;
const ALICE: address = @0xA1;
const BOB: address = @0xB2;

// === Test Coin Types ===
public struct TEST_ASSET has drop {}
public struct TEST_STABLE has drop {}
public struct TEST_COIN has drop {}

// === InitiateDissolutionAction Decoder Tests ===

#[test]
fun test_decode_initiate_dissolution_action_prorata() {
    let mut scenario = ts::begin(ADMIN);

    let mut registry = schema::create_registry(ts::ctx(&mut scenario));
    dissolution_decoder::register_decoders(&mut registry, ts::ctx(&mut scenario));

    ts::next_tx(&mut scenario, ADMIN);
    {
        let action = dissolution_actions::new_initiate_dissolution_action(
            string::utf8(b"Market price below NAV"),
            0, // Pro-rata
            true,
            1000000,
        );

        let action_data = bcs::to_bytes(&action);
        let decoder = schema::borrow_decoder<dissolution_decoder::InitiateDissolutionActionDecoder>(
            &registry,
        );
        let fields = dissolution_decoder::decode_initiate_dissolution_action(decoder, action_data);

        assert_eq(fields.length(), 4);

        let reason_field = fields.borrow(0);
        assert_eq(*schema::field_name(reason_field), string::utf8(b"reason"));
        assert_eq(*schema::field_value(reason_field), string::utf8(b"Market price below NAV"));

        let method_field = fields.borrow(1);
        assert_eq(*schema::field_name(method_field), string::utf8(b"distribution_method"));
        assert_eq(*schema::field_value(method_field), string::utf8(b"pro-rata"));

        let burn_field = fields.borrow(2);
        assert_eq(*schema::field_value(burn_field), string::utf8(b"true"));

        let deadline_field = fields.borrow(3);
        assert_eq(*schema::field_value(deadline_field), string::utf8(b"1000000"));
    };

    schema::destroy_registry_for_testing(registry);
    ts::end(scenario);
}

#[test]
fun test_decode_initiate_dissolution_action_equal() {
    let mut scenario = ts::begin(ADMIN);

    let mut registry = schema::create_registry(ts::ctx(&mut scenario));
    dissolution_decoder::register_decoders(&mut registry, ts::ctx(&mut scenario));

    ts::next_tx(&mut scenario, ADMIN);
    {
        let action = dissolution_actions::new_initiate_dissolution_action(
            string::utf8(b"Test"),
            1, // Equal distribution
            false,
            5000,
        );

        let action_data = bcs::to_bytes(&action);
        let decoder = schema::borrow_decoder<dissolution_decoder::InitiateDissolutionActionDecoder>(
            &registry,
        );
        let fields = dissolution_decoder::decode_initiate_dissolution_action(decoder, action_data);

        let method_field = fields.borrow(1);
        assert_eq(*schema::field_value(method_field), string::utf8(b"equal"));

        let burn_field = fields.borrow(2);
        assert_eq(*schema::field_value(burn_field), string::utf8(b"false"));
    };

    schema::destroy_registry_for_testing(registry);
    ts::end(scenario);
}

#[test]
fun test_decode_initiate_dissolution_action_custom() {
    let mut scenario = ts::begin(ADMIN);

    let mut registry = schema::create_registry(ts::ctx(&mut scenario));
    dissolution_decoder::register_decoders(&mut registry, ts::ctx(&mut scenario));

    ts::next_tx(&mut scenario, ADMIN);
    {
        let action = dissolution_actions::new_initiate_dissolution_action(
            string::utf8(b"Custom distribution"),
            2, // Custom
            true,
            2000000,
        );

        let action_data = bcs::to_bytes(&action);
        let decoder = schema::borrow_decoder<dissolution_decoder::InitiateDissolutionActionDecoder>(
            &registry,
        );
        let fields = dissolution_decoder::decode_initiate_dissolution_action(decoder, action_data);

        let method_field = fields.borrow(1);
        assert_eq(*schema::field_value(method_field), string::utf8(b"custom"));
    };

    schema::destroy_registry_for_testing(registry);
    ts::end(scenario);
}

// === BatchDistributeAction Decoder Tests ===

#[test]
fun test_decode_batch_distribute_action() {
    let mut scenario = ts::begin(ADMIN);

    let mut registry = schema::create_registry(ts::ctx(&mut scenario));
    dissolution_decoder::register_decoders(&mut registry, ts::ctx(&mut scenario));

    ts::next_tx(&mut scenario, ADMIN);
    {
        let asset_types = vector[string::utf8(b"0x2::sui::SUI"), string::utf8(b"0x2::usdc::USDC")];

        let action = dissolution_actions::new_batch_distribute_action(asset_types);
        let action_data = bcs::to_bytes(&action);
        let decoder = schema::borrow_decoder<dissolution_decoder::BatchDistributeActionDecoder>(
            &registry,
        );
        let fields = dissolution_decoder::decode_batch_distribute_action(decoder, action_data);

        assert_eq(fields.length(), 1);

        let assets_field = fields.borrow(0);
        assert_eq(*schema::field_name(assets_field), string::utf8(b"asset_types"));
        assert_eq(
            *schema::field_value(assets_field),
            string::utf8(b"[0x2::sui::SUI, 0x2::usdc::USDC]"),
        );
    };

    schema::destroy_registry_for_testing(registry);
    ts::end(scenario);
}

#[test]
fun test_decode_batch_distribute_action_single_asset() {
    let mut scenario = ts::begin(ADMIN);

    let mut registry = schema::create_registry(ts::ctx(&mut scenario));
    dissolution_decoder::register_decoders(&mut registry, ts::ctx(&mut scenario));

    ts::next_tx(&mut scenario, ADMIN);
    {
        let asset_types = vector[string::utf8(b"0x2::sui::SUI")];

        let action = dissolution_actions::new_batch_distribute_action(asset_types);
        let action_data = bcs::to_bytes(&action);
        let decoder = schema::borrow_decoder<dissolution_decoder::BatchDistributeActionDecoder>(
            &registry,
        );
        let fields = dissolution_decoder::decode_batch_distribute_action(decoder, action_data);

        let assets_field = fields.borrow(0);
        assert_eq(*schema::field_value(assets_field), string::utf8(b"[0x2::sui::SUI]"));
    };

    schema::destroy_registry_for_testing(registry);
    ts::end(scenario);
}

// === FinalizeDissolutionAction Decoder Tests ===

#[test]
fun test_decode_finalize_dissolution_action() {
    let mut scenario = ts::begin(ADMIN);

    let mut registry = schema::create_registry(ts::ctx(&mut scenario));
    dissolution_decoder::register_decoders(&mut registry, ts::ctx(&mut scenario));

    ts::next_tx(&mut scenario, ADMIN);
    {
        let action = dissolution_actions::new_finalize_dissolution_action(
            ALICE,
            true, // Destroy account
        );

        let action_data = bcs::to_bytes(&action);
        let decoder = schema::borrow_decoder<dissolution_decoder::FinalizeDissolutionActionDecoder>(
            &registry,
        );
        let fields = dissolution_decoder::decode_finalize_dissolution_action(decoder, action_data);

        assert_eq(fields.length(), 2);

        let recipient_field = fields.borrow(0);
        assert_eq(*schema::field_name(recipient_field), string::utf8(b"final_recipient"));
        assert_eq(*schema::field_value(recipient_field), ALICE.to_string());

        let destroy_field = fields.borrow(1);
        assert_eq(*schema::field_name(destroy_field), string::utf8(b"destroy_account"));
        assert_eq(*schema::field_value(destroy_field), string::utf8(b"true"));
    };

    schema::destroy_registry_for_testing(registry);
    ts::end(scenario);
}

#[test]
fun test_decode_finalize_dissolution_action_no_destroy() {
    let mut scenario = ts::begin(ADMIN);

    let mut registry = schema::create_registry(ts::ctx(&mut scenario));
    dissolution_decoder::register_decoders(&mut registry, ts::ctx(&mut scenario));

    ts::next_tx(&mut scenario, ADMIN);
    {
        let action = dissolution_actions::new_finalize_dissolution_action(
            BOB,
            false, // Don't destroy
        );

        let action_data = bcs::to_bytes(&action);
        let decoder = schema::borrow_decoder<dissolution_decoder::FinalizeDissolutionActionDecoder>(
            &registry,
        );
        let fields = dissolution_decoder::decode_finalize_dissolution_action(decoder, action_data);

        let destroy_field = fields.borrow(1);
        assert_eq(*schema::field_value(destroy_field), string::utf8(b"false"));
    };

    schema::destroy_registry_for_testing(registry);
    ts::end(scenario);
}

// === CancelDissolutionAction Decoder Tests ===

#[test]
fun test_decode_cancel_dissolution_action() {
    let mut scenario = ts::begin(ADMIN);

    let mut registry = schema::create_registry(ts::ctx(&mut scenario));
    dissolution_decoder::register_decoders(&mut registry, ts::ctx(&mut scenario));

    ts::next_tx(&mut scenario, ADMIN);
    {
        let action = dissolution_actions::new_cancel_dissolution_action(
            string::utf8(b"Community voted to continue"),
        );

        let action_data = bcs::to_bytes(&action);
        let decoder = schema::borrow_decoder<dissolution_decoder::CancelDissolutionActionDecoder>(
            &registry,
        );
        let fields = dissolution_decoder::decode_cancel_dissolution_action(decoder, action_data);

        assert_eq(fields.length(), 1);

        let reason_field = fields.borrow(0);
        assert_eq(*schema::field_name(reason_field), string::utf8(b"reason"));
        assert_eq(*schema::field_value(reason_field), string::utf8(b"Community voted to continue"));
    };

    schema::destroy_registry_for_testing(registry);
    ts::end(scenario);
}

// === CalculateProRataSharesAction Decoder Tests ===

#[test]
fun test_decode_calculate_pro_rata_shares_action() {
    let mut scenario = ts::begin(ADMIN);

    let mut registry = schema::create_registry(ts::ctx(&mut scenario));
    dissolution_decoder::register_decoders(&mut registry, ts::ctx(&mut scenario));

    ts::next_tx(&mut scenario, ADMIN);
    {
        let action = dissolution_actions::new_calculate_pro_rata_shares_action(
            1000000, // Total supply
            true, // Exclude DAO tokens
        );

        let action_data = bcs::to_bytes(&action);
        let decoder = schema::borrow_decoder<
            dissolution_decoder::CalculateProRataSharesActionDecoder,
        >(&registry);
        let fields = dissolution_decoder::decode_calculate_pro_rata_shares_action(
            decoder,
            action_data,
        );

        assert_eq(fields.length(), 2);

        let supply_field = fields.borrow(0);
        assert_eq(*schema::field_name(supply_field), string::utf8(b"total_supply"));
        assert_eq(*schema::field_value(supply_field), string::utf8(b"1000000"));

        let exclude_field = fields.borrow(1);
        assert_eq(*schema::field_name(exclude_field), string::utf8(b"exclude_dao_tokens"));
        assert_eq(*schema::field_value(exclude_field), string::utf8(b"true"));
    };

    schema::destroy_registry_for_testing(registry);
    ts::end(scenario);
}

#[test]
fun test_decode_calculate_pro_rata_shares_action_include_dao() {
    let mut scenario = ts::begin(ADMIN);

    let mut registry = schema::create_registry(ts::ctx(&mut scenario));
    dissolution_decoder::register_decoders(&mut registry, ts::ctx(&mut scenario));

    ts::next_tx(&mut scenario, ADMIN);
    {
        let action = dissolution_actions::new_calculate_pro_rata_shares_action(
            5000000,
            false, // Include DAO tokens
        );

        let action_data = bcs::to_bytes(&action);
        let decoder = schema::borrow_decoder<
            dissolution_decoder::CalculateProRataSharesActionDecoder,
        >(&registry);
        let fields = dissolution_decoder::decode_calculate_pro_rata_shares_action(
            decoder,
            action_data,
        );

        let exclude_field = fields.borrow(1);
        assert_eq(*schema::field_value(exclude_field), string::utf8(b"false"));
    };

    schema::destroy_registry_for_testing(registry);
    ts::end(scenario);
}

// === CancelAllStreamsAction Decoder Tests ===

#[test]
fun test_decode_cancel_all_streams_action_return() {
    let mut scenario = ts::begin(ADMIN);

    let mut registry = schema::create_registry(ts::ctx(&mut scenario));
    dissolution_decoder::register_decoders(&mut registry, ts::ctx(&mut scenario));

    ts::next_tx(&mut scenario, ADMIN);
    {
        let action = dissolution_actions::new_cancel_all_streams_action(true);

        let action_data = bcs::to_bytes(&action);
        let decoder = schema::borrow_decoder<dissolution_decoder::CancelAllStreamsActionDecoder>(
            &registry,
        );
        let fields = dissolution_decoder::decode_cancel_all_streams_action(decoder, action_data);

        assert_eq(fields.length(), 1);

        let return_field = fields.borrow(0);
        assert_eq(*schema::field_name(return_field), string::utf8(b"return_to_treasury"));
        assert_eq(*schema::field_value(return_field), string::utf8(b"true"));
    };

    schema::destroy_registry_for_testing(registry);
    ts::end(scenario);
}

#[test]
fun test_decode_cancel_all_streams_action_no_return() {
    let mut scenario = ts::begin(ADMIN);

    let mut registry = schema::create_registry(ts::ctx(&mut scenario));
    dissolution_decoder::register_decoders(&mut registry, ts::ctx(&mut scenario));

    ts::next_tx(&mut scenario, ADMIN);
    {
        let action = dissolution_actions::new_cancel_all_streams_action(false);

        let action_data = bcs::to_bytes(&action);
        let decoder = schema::borrow_decoder<dissolution_decoder::CancelAllStreamsActionDecoder>(
            &registry,
        );
        let fields = dissolution_decoder::decode_cancel_all_streams_action(decoder, action_data);

        let return_field = fields.borrow(0);
        assert_eq(*schema::field_value(return_field), string::utf8(b"false"));
    };

    schema::destroy_registry_for_testing(registry);
    ts::end(scenario);
}

// === WithdrawAmmLiquidityAction Decoder Tests ===

#[test]
fun test_decode_withdraw_amm_liquidity_action() {
    let mut scenario = ts::begin(ADMIN);

    let mut registry = schema::create_registry(ts::ctx(&mut scenario));
    dissolution_decoder::register_decoders(&mut registry, ts::ctx(&mut scenario));

    ts::next_tx(&mut scenario, ADMIN);
    {
        let pool_id = object::id_from_address(@0x123);

        let action = dissolution_actions::new_withdraw_amm_liquidity_action<
            TEST_ASSET,
            TEST_STABLE,
        >(
            pool_id,
            true, // Burn LP tokens
        );

        let action_data = bcs::to_bytes(&action);
        let decoder = schema::borrow_decoder<
            dissolution_decoder::WithdrawAmmLiquidityActionDecoder,
        >(&registry);
        let fields = dissolution_decoder::decode_withdraw_amm_liquidity_action<
            TEST_ASSET,
            TEST_STABLE,
        >(
            decoder,
            action_data,
        );

        assert_eq(fields.length(), 2);

        let pool_field = fields.borrow(0);
        assert_eq(*schema::field_name(pool_field), string::utf8(b"pool_id"));

        let burn_field = fields.borrow(1);
        assert_eq(*schema::field_name(burn_field), string::utf8(b"burn_lp_tokens"));
        assert_eq(*schema::field_value(burn_field), string::utf8(b"true"));
    };

    schema::destroy_registry_for_testing(registry);
    ts::end(scenario);
}

#[test]
fun test_decode_withdraw_amm_liquidity_action_no_burn() {
    let mut scenario = ts::begin(ADMIN);

    let mut registry = schema::create_registry(ts::ctx(&mut scenario));
    dissolution_decoder::register_decoders(&mut registry, ts::ctx(&mut scenario));

    ts::next_tx(&mut scenario, ADMIN);
    {
        let pool_id = object::id_from_address(@0x456);

        let action = dissolution_actions::new_withdraw_amm_liquidity_action<
            TEST_ASSET,
            TEST_STABLE,
        >(
            pool_id,
            false, // Don't burn
        );

        let action_data = bcs::to_bytes(&action);
        let decoder = schema::borrow_decoder<
            dissolution_decoder::WithdrawAmmLiquidityActionDecoder,
        >(&registry);
        let fields = dissolution_decoder::decode_withdraw_amm_liquidity_action<
            TEST_ASSET,
            TEST_STABLE,
        >(
            decoder,
            action_data,
        );

        let burn_field = fields.borrow(1);
        assert_eq(*schema::field_value(burn_field), string::utf8(b"false"));
    };

    schema::destroy_registry_for_testing(registry);
    ts::end(scenario);
}

// === DistributeAssetsAction Decoder Tests ===

#[test]
fun test_decode_distribute_assets_action() {
    let mut scenario = ts::begin(ADMIN);

    let mut registry = schema::create_registry(ts::ctx(&mut scenario));
    dissolution_decoder::register_decoders(&mut registry, ts::ctx(&mut scenario));

    ts::next_tx(&mut scenario, ADMIN);
    {
        let holders = vector[ALICE, BOB, @0xC3];
        let holder_amounts = vector[100, 200, 300];

        let action = dissolution_actions::new_distribute_assets_action<TEST_COIN>(
            holders,
            holder_amounts,
            10000, // Total distribution
        );

        let action_data = bcs::to_bytes(&action);
        let decoder = schema::borrow_decoder<dissolution_decoder::DistributeAssetsActionDecoder>(
            &registry,
        );
        let fields = dissolution_decoder::decode_distribute_assets_action<TEST_COIN>(
            decoder,
            action_data,
        );

        assert_eq(fields.length(), 2);

        let count_field = fields.borrow(0);
        assert_eq(*schema::field_name(count_field), string::utf8(b"holders_count"));
        assert_eq(*schema::field_value(count_field), string::utf8(b"3"));

        let total_field = fields.borrow(1);
        assert_eq(*schema::field_name(total_field), string::utf8(b"total_distribution_amount"));
        assert_eq(*schema::field_value(total_field), string::utf8(b"10000"));
    };

    schema::destroy_registry_for_testing(registry);
    ts::end(scenario);
}

// === Registration Tests ===

#[test]
fun test_register_all_decoders() {
    let mut scenario = ts::begin(ADMIN);

    let mut registry = schema::create_registry(ts::ctx(&mut scenario));
    dissolution_decoder::register_decoders(&mut registry, ts::ctx(&mut scenario));

    ts::next_tx(&mut scenario, ADMIN);
    {
        // Verify all decoders are registered
        let _initiate = schema::borrow_decoder<
            dissolution_decoder::InitiateDissolutionActionDecoder,
        >(&registry);
        let _batch = schema::borrow_decoder<dissolution_decoder::BatchDistributeActionDecoder>(
            &registry,
        );
        let _finalize = schema::borrow_decoder<
            dissolution_decoder::FinalizeDissolutionActionDecoder,
        >(&registry);
        let _cancel = schema::borrow_decoder<dissolution_decoder::CancelDissolutionActionDecoder>(
            &registry,
        );
        let _prorata = schema::borrow_decoder<
            dissolution_decoder::CalculateProRataSharesActionDecoder,
        >(&registry);
        let _streams = schema::borrow_decoder<dissolution_decoder::CancelAllStreamsActionDecoder>(
            &registry,
        );
        let _amm = schema::borrow_decoder<dissolution_decoder::WithdrawAmmLiquidityActionDecoder>(
            &registry,
        );
        let _distribute = schema::borrow_decoder<
            dissolution_decoder::DistributeAssetsActionDecoder,
        >(&registry);
    };

    schema::destroy_registry_for_testing(registry);
    ts::end(scenario);
}

// === Round-trip Tests ===

#[test]
fun test_roundtrip_initiate_dissolution() {
    let mut scenario = ts::begin(ADMIN);

    let mut registry = schema::create_registry(ts::ctx(&mut scenario));
    dissolution_decoder::register_decoders(&mut registry, ts::ctx(&mut scenario));

    ts::next_tx(&mut scenario, ADMIN);
    {
        let original = dissolution_actions::new_initiate_dissolution_action(
            string::utf8(b"Test reason"),
            1,
            true,
            999999,
        );

        let serialized = bcs::to_bytes(&original);
        let decoder = schema::borrow_decoder<dissolution_decoder::InitiateDissolutionActionDecoder>(
            &registry,
        );
        let fields = dissolution_decoder::decode_initiate_dissolution_action(decoder, serialized);

        // Verify deserialized fields match original
        assert_eq(*schema::field_value(fields.borrow(0)), string::utf8(b"Test reason"));
        assert_eq(*schema::field_value(fields.borrow(1)), string::utf8(b"equal"));
        assert_eq(*schema::field_value(fields.borrow(3)), string::utf8(b"999999"));
    };

    schema::destroy_registry_for_testing(registry);
    ts::end(scenario);
}
