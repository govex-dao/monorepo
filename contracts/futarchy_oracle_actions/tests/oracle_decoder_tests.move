/// Comprehensive tests for oracle_decoder module
#[test_only]
module futarchy_oracle::oracle_decoder_tests;

use account_protocol::schema;
use futarchy_oracle::oracle_actions;
use futarchy_oracle::oracle_decoder;
use std::string;
use sui::bcs;
use sui::object;
use sui::test_scenario as ts;
use sui::test_utils;

// Test coin types
public struct ASSET has drop {}
public struct STABLE has drop {}

const ADMIN: address = @0xAD;
const RECIPIENT: address = @0x0000000000000000000000000000000000000000000000000000000000000001;

// === Helper Functions ===

fun create_decoder_for_testing<T: key + store>(ctx: &mut TxContext): T {
    sui::test_utils::create<T>(ctx)
}

// === CreateOracleGrant Decoder Tests ===

#[test]
fun test_decode_create_oracle_grant_single_recipient() {
    let mut scenario = ts::begin(ADMIN);

    let decoder = create_decoder_for_testing<oracle_decoder::CreateOracleGrantActionDecoder>(
        ts::ctx(&mut scenario),
    );

    let action = oracle_actions::new_create_oracle_grant<ASSET, STABLE>(
        vector[RECIPIENT],
        vector[100_000],
        0, // vesting_mode
        3, // cliff_months
        4, // vesting_years
        0, // strike_mode
        1_000_000, // strike_price
        2_000_000_000, // launchpad_multiplier
        0, // cooldown_ms
        1, // max_executions
        0, // earliest_execution_offset_ms
        10, // expiry_years
        0, // price_condition_mode
        0, // price_threshold
        false, // price_is_above
        true, // cancelable
        string::utf8(b"Test grant"),
    );

    let action_data = bcs::to_bytes(&action);
    let fields = oracle_decoder::decode_create_oracle_grant<ASSET, STABLE>(
        &decoder,
        action_data,
    );

    // Verify we got the expected fields
    assert!(fields.length() == 16, 0);

    // Check recipient_count field
    let field0 = &fields[0];
    assert!(*schema::field_name(field0) == string::utf8(b"recipient_count"), 1);
    assert!(*schema::field_value(field0) == string::utf8(b"1"), 2);

    test_utils::destroy(decoder);
    ts::end(scenario);
}

#[test]
fun test_decode_create_oracle_grant_multiple_recipients() {
    let mut scenario = ts::begin(ADMIN);

    let decoder = create_decoder_for_testing<oracle_decoder::CreateOracleGrantActionDecoder>(
        ts::ctx(&mut scenario),
    );

    let recipient2 = @0x0000000000000000000000000000000000000000000000000000000000000002;

    let action = oracle_actions::new_create_oracle_grant<ASSET, STABLE>(
        vector[RECIPIENT, recipient2],
        vector[100_000, 200_000],
        0,
        3,
        4,
        0,
        1_000_000,
        2_000_000_000,
        0,
        1,
        0,
        10,
        0,
        0,
        false,
        true,
        string::utf8(b"Multi recipient"),
    );

    let action_data = bcs::to_bytes(&action);
    let fields = oracle_decoder::decode_create_oracle_grant<ASSET, STABLE>(
        &decoder,
        action_data,
    );

    // Check recipient_count = 2
    let field0 = &fields[0];
    assert!(*schema::field_value(field0) == string::utf8(b"2"), 0);

    test_utils::destroy(decoder);
    ts::end(scenario);
}

#[test]
fun test_decode_create_oracle_grant_all_fields() {
    let mut scenario = ts::begin(ADMIN);

    let decoder = create_decoder_for_testing<oracle_decoder::CreateOracleGrantActionDecoder>(
        ts::ctx(&mut scenario),
    );

    let action = oracle_actions::new_create_oracle_grant<ASSET, STABLE>(
        vector[RECIPIENT],
        vector[500_000],
        1, // vesting_mode
        6, // cliff_months
        3, // vesting_years
        1, // strike_mode
        5_000_000, // strike_price
        3_000_000_000, // launchpad_multiplier
        86400000, // cooldown_ms (1 day)
        5, // max_executions
        3600000, // earliest_execution_offset_ms (1 hour)
        5, // expiry_years
        1, // price_condition_mode
        1_500_000_000, // price_threshold
        true, // price_is_above
        false, // cancelable
        string::utf8(b"Complex grant"),
    );

    let action_data = bcs::to_bytes(&action);
    let fields = oracle_decoder::decode_create_oracle_grant<ASSET, STABLE>(
        &decoder,
        action_data,
    );

    // Verify specific field values
    assert!(*schema::field_value(&fields[0]) == string::utf8(b"1"), 0); // recipient_count
    assert!(*schema::field_value(&fields[1]) == string::utf8(b"1"), 1); // vesting_mode
    assert!(*schema::field_value(&fields[2]) == string::utf8(b"6"), 2); // cliff_months
    assert!(*schema::field_value(&fields[3]) == string::utf8(b"3"), 3); // vesting_years
    assert!(*schema::field_value(&fields[13]) == string::utf8(b"true"), 4); // price_is_above
    assert!(*schema::field_value(&fields[14]) == string::utf8(b"false"), 5); // cancelable
    assert!(*schema::field_value(&fields[15]) == string::utf8(b"Complex grant"), 6); // description

    test_utils::destroy(decoder);
    ts::end(scenario);
}

// === CancelGrant Decoder Tests ===

#[test]
fun test_decode_cancel_grant() {
    let mut scenario = ts::begin(ADMIN);

    let decoder = create_decoder_for_testing<oracle_decoder::CancelGrantActionDecoder>(
        ts::ctx(&mut scenario),
    );

    let grant_id = object::id_from_address(
        @0x0000000000000000000000000000000000000000000000000000000000001234,
    );
    let action = oracle_actions::new_cancel_grant(grant_id);

    let action_data = bcs::to_bytes(&action);
    let fields = oracle_decoder::decode_cancel_grant(&decoder, action_data);

    // Should have 1 field: grant_id
    assert!(fields.length() == 1, 0);

    let field0 = &fields[0];
    assert!(*schema::field_name(field0) == string::utf8(b"grant_id"), 1);
    assert!(*schema::field_type(field0) == string::utf8(b"ID"), 2);

    test_utils::destroy(decoder);
    ts::end(scenario);
}

// === PauseGrant Decoder Tests ===

#[test]
fun test_decode_pause_grant() {
    let mut scenario = ts::begin(ADMIN);

    let decoder = create_decoder_for_testing<oracle_decoder::PauseGrantActionDecoder>(
        ts::ctx(&mut scenario),
    );

    let grant_id = object::id_from_address(
        @0x0000000000000000000000000000000000000000000000000000000000001234,
    );
    let action = oracle_actions::new_pause_grant(grant_id, 86400000); // 1 day

    let action_data = bcs::to_bytes(&action);
    let fields = oracle_decoder::decode_pause_grant(&decoder, action_data);

    // Should have 2 fields: grant_id, pause_duration_ms
    assert!(fields.length() == 2, 0);

    assert!(*schema::field_name(&fields[0]) == string::utf8(b"grant_id"), 1);
    assert!(*schema::field_name(&fields[1]) == string::utf8(b"pause_duration_ms"), 2);
    assert!(*schema::field_value(&fields[1]) == string::utf8(b"86400000"), 3);

    test_utils::destroy(decoder);
    ts::end(scenario);
}

// === UnpauseGrant Decoder Tests ===

#[test]
fun test_decode_unpause_grant() {
    let mut scenario = ts::begin(ADMIN);

    let decoder = create_decoder_for_testing<oracle_decoder::UnpauseGrantActionDecoder>(
        ts::ctx(&mut scenario),
    );

    let grant_id = object::id_from_address(
        @0x0000000000000000000000000000000000000000000000000000000000001234,
    );
    let action = oracle_actions::new_unpause_grant(grant_id);

    let action_data = bcs::to_bytes(&action);
    let fields = oracle_decoder::decode_unpause_grant(&decoder, action_data);

    // Should have 1 field: grant_id
    assert!(fields.length() == 1, 0);
    assert!(*schema::field_name(&fields[0]) == string::utf8(b"grant_id"), 1);

    test_utils::destroy(decoder);
    ts::end(scenario);
}

// === EmergencyFreezeGrant Decoder Tests ===

#[test]
fun test_decode_emergency_freeze_grant() {
    let mut scenario = ts::begin(ADMIN);

    let decoder = create_decoder_for_testing<oracle_decoder::EmergencyFreezeGrantActionDecoder>(
        ts::ctx(&mut scenario),
    );

    let grant_id = object::id_from_address(
        @0x0000000000000000000000000000000000000000000000000000000000001234,
    );
    let action = oracle_actions::new_emergency_freeze_grant(grant_id);

    let action_data = bcs::to_bytes(&action);
    let fields = oracle_decoder::decode_emergency_freeze_grant(&decoder, action_data);

    // Should have 1 field: grant_id
    assert!(fields.length() == 1, 0);
    assert!(*schema::field_name(&fields[0]) == string::utf8(b"grant_id"), 1);

    test_utils::destroy(decoder);
    ts::end(scenario);
}

// === EmergencyUnfreezeGrant Decoder Tests ===

#[test]
fun test_decode_emergency_unfreeze_grant() {
    let mut scenario = ts::begin(ADMIN);

    let decoder = create_decoder_for_testing<oracle_decoder::EmergencyUnfreezeGrantActionDecoder>(
        ts::ctx(&mut scenario),
    );

    let grant_id = object::id_from_address(
        @0x0000000000000000000000000000000000000000000000000000000000001234,
    );
    let action = oracle_actions::new_emergency_unfreeze_grant(grant_id);

    let action_data = bcs::to_bytes(&action);
    let fields = oracle_decoder::decode_emergency_unfreeze_grant(&decoder, action_data);

    // Should have 1 field: grant_id
    assert!(fields.length() == 1, 0);
    assert!(*schema::field_name(&fields[0]) == string::utf8(b"grant_id"), 1);

    test_utils::destroy(decoder);
    ts::end(scenario);
}

// === Edge Case Tests ===

#[test]
fun test_decode_grant_with_empty_description() {
    let mut scenario = ts::begin(ADMIN);

    let decoder = create_decoder_for_testing<oracle_decoder::CreateOracleGrantActionDecoder>(
        ts::ctx(&mut scenario),
    );

    let action = oracle_actions::new_create_oracle_grant<ASSET, STABLE>(
        vector[RECIPIENT],
        vector[100_000],
        0,
        3,
        4,
        0,
        1_000_000,
        2_000_000_000,
        0,
        1,
        0,
        10,
        0,
        0,
        false,
        true,
        string::utf8(b""), // Empty description
    );

    let action_data = bcs::to_bytes(&action);
    let fields = oracle_decoder::decode_create_oracle_grant<ASSET, STABLE>(
        &decoder,
        action_data,
    );

    // Description field should be empty string
    assert!(*schema::field_value(&fields[15]) == string::utf8(b""), 0);

    test_utils::destroy(decoder);
    ts::end(scenario);
}

#[test]
fun test_decode_grant_with_long_description() {
    let mut scenario = ts::begin(ADMIN);

    let decoder = create_decoder_for_testing<oracle_decoder::CreateOracleGrantActionDecoder>(
        ts::ctx(&mut scenario),
    );

    let long_desc = string::utf8(
        b"This is a very long description that contains multiple words and should still be decoded correctly without any issues",
    );

    let action = oracle_actions::new_create_oracle_grant<ASSET, STABLE>(
        vector[RECIPIENT],
        vector[100_000],
        0,
        3,
        4,
        0,
        1_000_000,
        2_000_000_000,
        0,
        1,
        0,
        10,
        0,
        0,
        false,
        true,
        long_desc,
    );

    let action_data = bcs::to_bytes(&action);
    let fields = oracle_decoder::decode_create_oracle_grant<ASSET, STABLE>(
        &decoder,
        action_data,
    );

    // Description should match
    assert!(*schema::field_value(&fields[15]) == long_desc, 0);

    test_utils::destroy(decoder);
    ts::end(scenario);
}
