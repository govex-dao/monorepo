/// Comprehensive tests for payment_decoder.move
/// Tests BCS serialization/deserialization, decoder functions, and validation
#[test_only]
module futarchy_payments::payment_decoder_tests;

use account_protocol::schema::{Self, ActionDecoderRegistry};
use futarchy_payments::payment_actions;
use futarchy_payments::payment_decoder;
use std::option;
use std::string;
use sui::bcs;
use sui::sui::SUI;
use sui::test_scenario as ts;
use sui::test_utils::assert_eq;

// === Test Addresses ===
const ALICE: address = @0xA1;
const ADMIN: address = @0xAD;

// === Serialization/Deserialization Tests ===

#[test]
fun test_deserialize_create_payment_action() {
    let action = payment_actions::new_create_payment_action<SUI>(
        1u8, // payment_type
        2u8, // source_mode
        ALICE, // recipient
        1000u64, // amount
        100u64, // start_timestamp
        200u64, // end_timestamp
        option::some(50u64), // interval_or_cliff
        10u64, // total_payments
        true, // cancellable
        string::utf8(b"Test payment"), // description
        100u64, // max_per_withdrawal
        1000u64, // min_interval_ms
        5u64, // max_beneficiaries
    );

    // Serialize to BCS
    let action_data = bcs::to_bytes(&action);

    // Deserialize back
    let deserialized = payment_decoder::deserialize_create_payment_action<SUI>(action_data, 1);

    // Verify all fields match
    assert_eq(payment_actions::payment_type(&deserialized), 1u8);
    assert_eq(payment_actions::source_mode(&deserialized), 2u8);
    assert_eq(payment_actions::recipient(&deserialized), ALICE);
    assert_eq(payment_actions::amount(&deserialized), 1000u64);
    assert_eq(payment_actions::start_timestamp(&deserialized), 100u64);
    assert_eq(payment_actions::end_timestamp(&deserialized), 200u64);
    assert_eq(payment_actions::total_payments(&deserialized), 10u64);
    assert_eq(payment_actions::cancellable(&deserialized), true);
    assert_eq(*payment_actions::description(&deserialized), string::utf8(b"Test payment"));
    assert_eq(payment_actions::max_per_withdrawal(&deserialized), 100u64);
    assert_eq(payment_actions::min_interval_ms(&deserialized), 1000u64);
    assert_eq(payment_actions::max_beneficiaries(&deserialized), 5u64);

    let interval = payment_actions::interval_or_cliff(&deserialized);
    assert!(interval.is_some());
    assert_eq(*interval.borrow(), 50u64);

    payment_actions::destroy_create_payment_action(action);
    payment_actions::destroy_create_payment_action(deserialized);
}

#[test]
fun test_deserialize_create_payment_action_with_none_interval() {
    let action = payment_actions::new_create_payment_action<SUI>(
        1u8,
        2u8,
        ALICE,
        1000u64,
        100u64,
        200u64,
        option::none(), // interval_or_cliff (none)
        10u64,
        true,
        string::utf8(b"Test"),
        100u64,
        1000u64,
        5u64,
    );

    // Serialize and deserialize
    let action_data = bcs::to_bytes(&action);
    let deserialized = payment_decoder::deserialize_create_payment_action<SUI>(action_data, 1);

    // Verify interval is none
    let interval = payment_actions::interval_or_cliff(&deserialized);
    assert!(interval.is_none());

    payment_actions::destroy_create_payment_action(action);
    payment_actions::destroy_create_payment_action(deserialized);
}

#[test]
fun test_deserialize_create_payment_action_zero_values() {
    let action = payment_actions::new_create_payment_action<SUI>(
        0u8,
        0u8,
        @0x0,
        0u64,
        0u64,
        0u64,
        option::none(),
        0u64,
        false,
        string::utf8(b""),
        0u64,
        0u64,
        0u64,
    );

    let action_data = bcs::to_bytes(&action);
    let deserialized = payment_decoder::deserialize_create_payment_action<SUI>(action_data, 1);

    assert_eq(payment_actions::payment_type(&deserialized), 0u8);
    assert_eq(payment_actions::amount(&deserialized), 0u64);
    assert_eq(payment_actions::cancellable(&deserialized), false);

    payment_actions::destroy_create_payment_action(action);
    payment_actions::destroy_create_payment_action(deserialized);
}

#[test]
fun test_deserialize_create_payment_action_max_values() {
    let action = payment_actions::new_create_payment_action<SUI>(
        255u8,
        255u8,
        ALICE,
        18446744073709551615u64, // max u64
        18446744073709551615u64,
        18446744073709551615u64,
        option::some(18446744073709551615u64),
        18446744073709551615u64,
        true,
        string::utf8(b"Max"),
        18446744073709551615u64,
        18446744073709551615u64,
        18446744073709551615u64,
    );

    let action_data = bcs::to_bytes(&action);
    let deserialized = payment_decoder::deserialize_create_payment_action<SUI>(action_data, 1);

    assert_eq(payment_actions::payment_type(&deserialized), 255u8);
    assert_eq(payment_actions::amount(&deserialized), 18446744073709551615u64);

    payment_actions::destroy_create_payment_action(action);
    payment_actions::destroy_create_payment_action(deserialized);
}

#[test]
#[expected_failure(abort_code = payment_decoder::EInvalidActionVersion)]
fun test_deserialize_create_payment_action_invalid_version() {
    let action = payment_actions::new_create_payment_action<SUI>(
        1u8,
        2u8,
        ALICE,
        1000u64,
        100u64,
        200u64,
        option::some(50u64),
        10u64,
        true,
        string::utf8(b"Test"),
        100u64,
        1000u64,
        5u64,
    );

    let action_data = bcs::to_bytes(&action);

    // Try to deserialize with wrong version
    let _deserialized = payment_decoder::deserialize_create_payment_action<SUI>(action_data, 2);

    payment_actions::destroy_create_payment_action(action);
}

#[test]
fun test_deserialize_cancel_payment_action() {
    let payment_id = string::utf8(b"PAYMENT_123_T_1000");
    let action = payment_actions::new_cancel_payment_action(payment_id);

    // Serialize and deserialize
    let action_data = bcs::to_bytes(&action);
    let deserialized = payment_decoder::deserialize_cancel_payment_action(action_data, 1);

    // Verify payment_id matches
    assert_eq(*payment_actions::payment_id(&deserialized), string::utf8(b"PAYMENT_123_T_1000"));

    payment_actions::destroy_cancel_payment_action(action);
    payment_actions::destroy_cancel_payment_action(deserialized);
}

#[test]
fun test_deserialize_cancel_payment_action_empty_id() {
    let action = payment_actions::new_cancel_payment_action(string::utf8(b""));

    let action_data = bcs::to_bytes(&action);
    let deserialized = payment_decoder::deserialize_cancel_payment_action(action_data, 1);

    assert_eq(*payment_actions::payment_id(&deserialized), string::utf8(b""));

    payment_actions::destroy_cancel_payment_action(action);
    payment_actions::destroy_cancel_payment_action(deserialized);
}

#[test]
fun test_deserialize_cancel_payment_action_long_id() {
    let long_id = string::utf8(b"PAYMENT_123456789_T_1234567890_VERY_LONG_ID");
    let action = payment_actions::new_cancel_payment_action(long_id);

    let action_data = bcs::to_bytes(&action);
    let deserialized = payment_decoder::deserialize_cancel_payment_action(action_data, 1);

    assert_eq(
        *payment_actions::payment_id(&deserialized),
        string::utf8(b"PAYMENT_123456789_T_1234567890_VERY_LONG_ID"),
    );

    payment_actions::destroy_cancel_payment_action(action);
    payment_actions::destroy_cancel_payment_action(deserialized);
}

#[test]
#[expected_failure(abort_code = payment_decoder::EInvalidActionVersion)]
fun test_deserialize_cancel_payment_action_invalid_version() {
    let action = payment_actions::new_cancel_payment_action(string::utf8(b"PAYMENT_123"));

    let action_data = bcs::to_bytes(&action);

    // Try with wrong version
    let _deserialized = payment_decoder::deserialize_cancel_payment_action(action_data, 99);

    payment_actions::destroy_cancel_payment_action(action);
}

// === Decoder Function Tests ===

#[test]
fun test_decode_create_payment_action() {
    let mut scenario = ts::begin(ADMIN);

    // Create decoder registry and register decoders
    let mut registry = schema::create_registry(ts::ctx(&mut scenario));
    payment_decoder::register_decoders(&mut registry, ts::ctx(&mut scenario));

    ts::next_tx(&mut scenario, ADMIN);
    {
        let action = payment_actions::new_create_payment_action<SUI>(
            1u8,
            2u8,
            ALICE,
            1000u64,
            100u64,
            200u64,
            option::some(50u64),
            10u64,
            true,
            string::utf8(b"Test payment"),
            100u64,
            1000u64,
            5u64,
        );

        let action_data = bcs::to_bytes(&action);

        // Get decoder and decode
        let decoder = schema::borrow_decoder<payment_decoder::CreatePaymentActionDecoder>(
            &registry,
        );
        let fields = payment_decoder::decode_create_payment_action<SUI>(decoder, action_data);

        // Verify fields (13 total)
        assert_eq(fields.length(), 13);

        // Check specific fields
        let payment_type_field = fields.borrow(0);
        assert_eq(*schema::field_name(payment_type_field), string::utf8(b"payment_type"));
        assert_eq(*schema::field_value(payment_type_field), string::utf8(b"1"));

        let amount_field = fields.borrow(3);
        assert_eq(*schema::field_name(amount_field), string::utf8(b"amount"));
        assert_eq(*schema::field_value(amount_field), string::utf8(b"1000"));

        let description_field = fields.borrow(9);
        assert_eq(*schema::field_name(description_field), string::utf8(b"description"));
        assert_eq(*schema::field_value(description_field), string::utf8(b"Test payment"));

        payment_actions::destroy_create_payment_action(action);
    };

    schema::destroy_registry_for_testing(registry);
    ts::end(scenario);
}

#[test]
fun test_decode_create_payment_action_with_none_interval() {
    let mut scenario = ts::begin(ADMIN);

    let mut registry = schema::create_registry(ts::ctx(&mut scenario));
    payment_decoder::register_decoders(&mut registry, ts::ctx(&mut scenario));

    ts::next_tx(&mut scenario, ADMIN);
    {
        let action = payment_actions::new_create_payment_action<SUI>(
            1u8,
            2u8,
            ALICE,
            1000u64,
            100u64,
            200u64,
            option::none(), // interval_or_cliff is none
            10u64,
            true,
            string::utf8(b"Test"),
            100u64,
            1000u64,
            5u64,
        );

        let action_data = bcs::to_bytes(&action);

        let decoder = schema::borrow_decoder<payment_decoder::CreatePaymentActionDecoder>(
            &registry,
        );
        let fields = payment_decoder::decode_create_payment_action<SUI>(decoder, action_data);

        // Check interval_or_cliff field (index 6)
        let interval_field = fields.borrow(6);
        assert_eq(*schema::field_name(interval_field), string::utf8(b"interval_or_cliff"));
        assert_eq(*schema::field_value(interval_field), string::utf8(b"none"));

        payment_actions::destroy_create_payment_action(action);
    };

    schema::destroy_registry_for_testing(registry);
    ts::end(scenario);
}

#[test]
fun test_decode_cancel_payment_action() {
    let mut scenario = ts::begin(ADMIN);

    let mut registry = schema::create_registry(ts::ctx(&mut scenario));
    payment_decoder::register_decoders(&mut registry, ts::ctx(&mut scenario));

    ts::next_tx(&mut scenario, ADMIN);
    {
        let action = payment_actions::new_cancel_payment_action(
            string::utf8(b"PAYMENT_123_T_1000"),
        );

        let action_data = bcs::to_bytes(&action);

        let decoder = schema::borrow_decoder<payment_decoder::CancelPaymentActionDecoder>(
            &registry,
        );
        let fields = payment_decoder::decode_cancel_payment_action(decoder, action_data);

        // Should have 1 field
        assert_eq(fields.length(), 1);

        let payment_id_field = fields.borrow(0);
        assert_eq(*schema::field_name(payment_id_field), string::utf8(b"payment_id"));
        assert_eq(*schema::field_value(payment_id_field), string::utf8(b"PAYMENT_123_T_1000"));

        payment_actions::destroy_cancel_payment_action(action);
    };

    schema::destroy_registry_for_testing(registry);
    ts::end(scenario);
}

// === Registration Tests ===

#[test]
fun test_register_decoders() {
    let mut scenario = ts::begin(ADMIN);

    let mut registry = schema::create_registry(ts::ctx(&mut scenario));

    // Register the decoders
    payment_decoder::register_decoders(&mut registry, ts::ctx(&mut scenario));

    ts::next_tx(&mut scenario, ADMIN);
    {
        // Verify CreatePaymentActionDecoder is registered
        let _create_decoder = schema::borrow_decoder<payment_decoder::CreatePaymentActionDecoder>(
            &registry,
        );

        // Verify CancelPaymentActionDecoder is registered
        let _cancel_decoder = schema::borrow_decoder<payment_decoder::CancelPaymentActionDecoder>(
            &registry,
        );
    };

    schema::destroy_registry_for_testing(registry);
    ts::end(scenario);
}

// === Round-trip Tests ===

#[test]
fun test_roundtrip_create_payment_action() {
    let mut scenario = ts::begin(ADMIN);

    let mut registry = schema::create_registry(ts::ctx(&mut scenario));
    payment_decoder::register_decoders(&mut registry, ts::ctx(&mut scenario));

    ts::next_tx(&mut scenario, ADMIN);
    {
        // Create action
        let original = payment_actions::new_create_payment_action<SUI>(
            5u8,
            7u8,
            ALICE,
            5000u64,
            500u64,
            1500u64,
            option::some(100u64),
            20u64,
            false,
            string::utf8(b"Roundtrip test"),
            200u64,
            5000u64,
            10u64,
        );

        // Serialize
        let action_data = bcs::to_bytes(&original);

        // Deserialize
        let deserialized = payment_decoder::deserialize_create_payment_action<SUI>(action_data, 1);

        // Verify all fields match
        assert_eq(
            payment_actions::payment_type(&original),
            payment_actions::payment_type(&deserialized),
        );
        assert_eq(
            payment_actions::source_mode(&original),
            payment_actions::source_mode(&deserialized),
        );
        assert_eq(
            payment_actions::recipient(&original),
            payment_actions::recipient(&deserialized),
        );
        assert_eq(
            payment_actions::amount(&original),
            payment_actions::amount(&deserialized),
        );
        assert_eq(
            payment_actions::start_timestamp(&original),
            payment_actions::start_timestamp(&deserialized),
        );
        assert_eq(
            payment_actions::end_timestamp(&original),
            payment_actions::end_timestamp(&deserialized),
        );
        assert_eq(
            payment_actions::total_payments(&original),
            payment_actions::total_payments(&deserialized),
        );
        assert_eq(
            payment_actions::cancellable(&original),
            payment_actions::cancellable(&deserialized),
        );

        payment_actions::destroy_create_payment_action(original);
        payment_actions::destroy_create_payment_action(deserialized);
    };

    schema::destroy_registry_for_testing(registry);
    ts::end(scenario);
}

#[test]
fun test_roundtrip_cancel_payment_action() {
    let mut scenario = ts::begin(ADMIN);

    let mut registry = schema::create_registry(ts::ctx(&mut scenario));
    payment_decoder::register_decoders(&mut registry, ts::ctx(&mut scenario));

    ts::next_tx(&mut scenario, ADMIN);
    {
        let original = payment_actions::new_cancel_payment_action(
            string::utf8(b"PAYMENT_XYZ_999"),
        );

        let action_data = bcs::to_bytes(&original);
        let deserialized = payment_decoder::deserialize_cancel_payment_action(action_data, 1);

        assert_eq(
            *payment_actions::payment_id(&original),
            *payment_actions::payment_id(&deserialized),
        );

        payment_actions::destroy_cancel_payment_action(original);
        payment_actions::destroy_cancel_payment_action(deserialized);
    };

    schema::destroy_registry_for_testing(registry);
    ts::end(scenario);
}

// === Edge Case Tests ===

#[test]
fun test_decode_create_payment_action_unicode() {
    let mut scenario = ts::begin(ADMIN);

    let mut registry = schema::create_registry(ts::ctx(&mut scenario));
    payment_decoder::register_decoders(&mut registry, ts::ctx(&mut scenario));

    ts::next_tx(&mut scenario, ADMIN);
    {
        let action = payment_actions::new_create_payment_action<SUI>(
            1u8,
            2u8,
            ALICE,
            1000u64,
            100u64,
            200u64,
            option::some(50u64),
            10u64,
            true,
            string::utf8(b"Payment \xF0\x9F\x92\xB0"), // Unicode emoji
            100u64,
            1000u64,
            5u64,
        );

        let action_data = bcs::to_bytes(&action);

        let decoder = schema::borrow_decoder<payment_decoder::CreatePaymentActionDecoder>(
            &registry,
        );
        let fields = payment_decoder::decode_create_payment_action<SUI>(decoder, action_data);

        let description_field = fields.borrow(9);
        assert_eq(
            *schema::field_value(description_field),
            string::utf8(b"Payment \xF0\x9F\x92\xB0"),
        );

        payment_actions::destroy_create_payment_action(action);
    };

    schema::destroy_registry_for_testing(registry);
    ts::end(scenario);
}
