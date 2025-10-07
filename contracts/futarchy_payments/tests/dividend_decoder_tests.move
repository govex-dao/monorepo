/// Tests for dividend_decoder module
#[test_only]
module futarchy_payments::dividend_decoder_tests;

use std::string;
use sui::test_scenario::{Self as ts};
use sui::bcs;
use sui::object;
use sui::test_utils;
use account_protocol::schema;
use futarchy_payments::{dividend_decoder, dividend_actions};

const ADMIN: address = @0xAD;

// Test coin type
public struct USDC has drop {}

// Helper to create decoder
fun create_decoder_for_testing<T: key + store>(ctx: &mut TxContext): T {
    sui::test_utils::create<T>(ctx)
}

#[test]
fun test_decode_create_dividend_action() {
    let mut scenario = ts::begin(ADMIN);

    let decoder = create_decoder_for_testing<dividend_decoder::CreateDividendActionDecoder>(
        ts::ctx(&mut scenario)
    );

    let tree_id = object::id_from_address(@0x0000000000000000000000000000000000000000000000000000000000001234);
    let action = dividend_actions::new_create_dividend_action<USDC>(tree_id);

    let action_data = bcs::to_bytes(&action);
    let fields = dividend_decoder::decode_create_dividend_action<USDC>(
        &decoder,
        action_data,
    );

    // Should have 2 fields: tree_id and note
    assert!(fields.length() == 2, 0);

    // Check tree_id field
    let field0 = &fields[0];
    assert!(*schema::field_name(field0) == string::utf8(b"tree_id"), 1);
    assert!(*schema::field_type(field0) == string::utf8(b"ID"), 2);

    // Check note field
    let field1 = &fields[1];
    assert!(*schema::field_name(field1) == string::utf8(b"note"), 3);
    assert!(*schema::field_value(field1) == string::utf8(b"Pre-built DividendTree object. Query tree for recipient details."), 4);

    test_utils::destroy(decoder);
    ts::end(scenario);
}

#[test]
fun test_decode_create_dividend_different_tree_ids() {
    let mut scenario = ts::begin(ADMIN);

    let decoder = create_decoder_for_testing<dividend_decoder::CreateDividendActionDecoder>(
        ts::ctx(&mut scenario)
    );

    // Test with different tree IDs
    let tree_id1 = object::id_from_address(@0x0000000000000000000000000000000000000000000000000000000000001111);
    let tree_id2 = object::id_from_address(@0x0000000000000000000000000000000000000000000000000000000000002222);

    let action1 = dividend_actions::new_create_dividend_action<USDC>(tree_id1);
    let action2 = dividend_actions::new_create_dividend_action<USDC>(tree_id2);

    let fields1 = dividend_decoder::decode_create_dividend_action<USDC>(
        &decoder,
        bcs::to_bytes(&action1),
    );

    let fields2 = dividend_decoder::decode_create_dividend_action<USDC>(
        &decoder,
        bcs::to_bytes(&action2),
    );

    // Tree IDs should be different
    assert!(*schema::field_value(&fields1[0]) != *schema::field_value(&fields2[0]), 0);

    test_utils::destroy(decoder);
    ts::end(scenario);
}
