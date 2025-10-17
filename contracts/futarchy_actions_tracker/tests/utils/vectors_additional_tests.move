#[test_only]
module futarchy::vectors_additional_tests;

use futarchy::vectors;
use std::string;
use sui::coin::{Self, Coin};
use sui::sui::SUI;
use sui::test_scenario::{Self as test, ctx};
use sui::transfer;

const ADMIN: address = @0xA;

// === Tests for validate_outcome_message ===

#[test]
fun test_validate_outcome_message_valid() {
    let message = b"Valid message".to_string();
    assert!(vectors::validate_outcome_message(&message, 100), 0);
}

#[test]
fun test_validate_outcome_message_empty() {
    let message = b"".to_string();
    assert!(!vectors::validate_outcome_message(&message, 100), 0);
}

#[test]
fun test_validate_outcome_message_too_long() {
    let message = b"This message is too long".to_string();
    assert!(!vectors::validate_outcome_message(&message, 10), 0);
}

#[test]
fun test_validate_outcome_message_exact_limit() {
    let message = b"Exact".to_string(); // 5 characters
    assert!(vectors::validate_outcome_message(&message, 5), 0);
}

#[test]
fun test_validate_outcome_message_one_char() {
    let message = b"A".to_string();
    assert!(vectors::validate_outcome_message(&message, 1), 0);
}

#[test]
fun test_validate_outcome_message_unicode() {
    let message = b"Hello \xE2\x9C\x85".to_string(); // Hello with checkmark emoji
    assert!(vectors::validate_outcome_message(&message, 20), 0);
}

// === Tests for validate_outcome_detail ===

#[test]
fun test_validate_outcome_detail_valid() {
    let detail = b"This is a detailed description of the outcome".to_string();
    assert!(vectors::validate_outcome_detail(&detail, 100), 0);
}

#[test]
fun test_validate_outcome_detail_empty() {
    let detail = b"".to_string();
    assert!(!vectors::validate_outcome_detail(&detail, 100), 0);
}

#[test]
fun test_validate_outcome_detail_too_long() {
    let detail = b"Too long detail text that exceeds the maximum".to_string();
    assert!(!vectors::validate_outcome_detail(&detail, 10), 0);
}

#[test]
fun test_validate_outcome_detail_multiline() {
    let detail = b"Line 1\nLine 2\nLine 3".to_string();
    assert!(vectors::validate_outcome_detail(&detail, 100), 0);
}

// === Tests for is_duplicate_message ===

#[test]
fun test_is_duplicate_message_found() {
    let messages = vector[b"First".to_string(), b"Second".to_string(), b"Third".to_string()];
    let new_message = b"Second".to_string();

    assert!(vectors::is_duplicate_message(&messages, &new_message), 0);
}

#[test]
fun test_is_duplicate_message_not_found() {
    let messages = vector[b"First".to_string(), b"Second".to_string(), b"Third".to_string()];
    let new_message = b"Fourth".to_string();

    assert!(!vectors::is_duplicate_message(&messages, &new_message), 0);
}

#[test]
fun test_is_duplicate_message_empty_vector() {
    let messages = vector<string::String>[];
    let new_message = b"Any".to_string();

    assert!(!vectors::is_duplicate_message(&messages, &new_message), 0);
}

#[test]
fun test_is_duplicate_case_sensitive() {
    let messages = vector[b"Yes".to_string(), b"No".to_string()];
    let new_message1 = b"YES".to_string();
    let new_message2 = b"Yes".to_string();

    // Case sensitive - YES != Yes
    assert!(!vectors::is_duplicate_message(&messages, &new_message1), 0);
    // Exact match
    assert!(vectors::is_duplicate_message(&messages, &new_message2), 1);
}

#[test]
fun test_is_duplicate_first_element() {
    let messages = vector[b"First".to_string(), b"Second".to_string(), b"Third".to_string()];
    let new_message = b"First".to_string();

    assert!(vectors::is_duplicate_message(&messages, &new_message), 0);
}

#[test]
fun test_is_duplicate_last_element() {
    let messages = vector[b"First".to_string(), b"Second".to_string(), b"Third".to_string()];
    let new_message = b"Third".to_string();

    assert!(vectors::is_duplicate_message(&messages, &new_message), 0);
}

// === Tests for merge_coins ===

#[test]
fun test_merge_single_coin() {
    let mut scenario = test::begin(ADMIN);

    test::next_tx(&mut scenario, ADMIN);
    {
        let coin = coin::mint_for_testing<SUI>(1000, ctx(&mut scenario));
        let coins = vector[coin];

        let merged = vectors::merge_coins(coins, ctx(&mut scenario));
        assert!(coin::value(&merged) == 1000, 0);

        transfer::public_transfer(merged, ADMIN);
    };

    test::end(scenario);
}

#[test]
fun test_merge_two_coins() {
    let mut scenario = test::begin(ADMIN);

    test::next_tx(&mut scenario, ADMIN);
    {
        let coin1 = coin::mint_for_testing<SUI>(1000, ctx(&mut scenario));
        let coin2 = coin::mint_for_testing<SUI>(2000, ctx(&mut scenario));
        let coins = vector[coin1, coin2];

        let merged = vectors::merge_coins(coins, ctx(&mut scenario));
        assert!(coin::value(&merged) == 3000, 0);

        transfer::public_transfer(merged, ADMIN);
    };

    test::end(scenario);
}

#[test]
fun test_merge_multiple_coins() {
    let mut scenario = test::begin(ADMIN);

    test::next_tx(&mut scenario, ADMIN);
    {
        let coin1 = coin::mint_for_testing<SUI>(1000, ctx(&mut scenario));
        let coin2 = coin::mint_for_testing<SUI>(2000, ctx(&mut scenario));
        let coin3 = coin::mint_for_testing<SUI>(3000, ctx(&mut scenario));
        let coin4 = coin::mint_for_testing<SUI>(4000, ctx(&mut scenario));
        let coins = vector[coin1, coin2, coin3, coin4];

        let merged = vectors::merge_coins(coins, ctx(&mut scenario));
        assert!(coin::value(&merged) == 10000, 0);

        transfer::public_transfer(merged, ADMIN);
    };

    test::end(scenario);
}

#[test]
fun test_merge_many_coins() {
    let mut scenario = test::begin(ADMIN);

    test::next_tx(&mut scenario, ADMIN);
    {
        let mut coins = vector<Coin<SUI>>[];
        let mut expected_total = 0;

        // Create 10 coins with different values
        let mut i = 0;
        while (i < 10) {
            let value = (i + 1) * 100;
            coins.push_back(coin::mint_for_testing<SUI>(value, ctx(&mut scenario)));
            expected_total = expected_total + value;
            i = i + 1;
        };

        let merged = vectors::merge_coins(coins, ctx(&mut scenario));
        assert!(coin::value(&merged) == expected_total, 0);
        assert!(expected_total == 5500, 1); // 100+200+300+...+1000 = 5500

        transfer::public_transfer(merged, ADMIN);
    };

    test::end(scenario);
}

#[test]
fun test_merge_zero_value_coins() {
    let mut scenario = test::begin(ADMIN);

    test::next_tx(&mut scenario, ADMIN);
    {
        let coin1 = coin::mint_for_testing<SUI>(0, ctx(&mut scenario));
        let coin2 = coin::mint_for_testing<SUI>(1000, ctx(&mut scenario));
        let coin3 = coin::mint_for_testing<SUI>(0, ctx(&mut scenario));
        let coins = vector[coin1, coin2, coin3];

        let merged = vectors::merge_coins(coins, ctx(&mut scenario));
        assert!(coin::value(&merged) == 1000, 0);

        transfer::public_transfer(merged, ADMIN);
    };

    test::end(scenario);
}

#[test, expected_failure(abort_code = 0)]
fun test_merge_empty_vector() {
    let mut scenario = test::begin(ADMIN);

    test::next_tx(&mut scenario, ADMIN);
    {
        let coins = vector<Coin<SUI>>[];
        // Should abort with error code 0
        let merged = vectors::merge_coins(coins, ctx(&mut scenario));
        // This line should never be reached due to abort
        transfer::public_transfer(merged, ADMIN);
    };

    test::end(scenario);
}

// === Test coin type for generic testing ===
public struct TEST_COIN has drop {}

#[test]
fun test_merge_coins_generic_type() {
    let mut scenario = test::begin(ADMIN);

    test::next_tx(&mut scenario, ADMIN);
    {
        let coin1 = coin::mint_for_testing<TEST_COIN>(100, ctx(&mut scenario));
        let coin2 = coin::mint_for_testing<TEST_COIN>(200, ctx(&mut scenario));
        let coin3 = coin::mint_for_testing<TEST_COIN>(300, ctx(&mut scenario));
        let coins = vector[coin1, coin2, coin3];

        let merged = vectors::merge_coins(coins, ctx(&mut scenario));
        assert!(coin::value(&merged) == 600, 0);

        transfer::public_transfer(merged, ADMIN);
    };

    test::end(scenario);
}

// === Comprehensive edge case tests ===

#[test]
fun test_check_valid_outcomes_boundary_cases() {
    // Test with exactly the boundary of uniqueness
    let outcomes1 = vector[
        b"A".to_string(),
        b"B".to_string(),
        b"C".to_string(),
        b"D".to_string(),
        b"E".to_string(),
    ];
    assert!(vectors::check_valid_outcomes(outcomes1, 1), 0);

    // Test with maximum allowed strings of maximum length
    let long_string = b"12345678901234567890".to_string(); // 20 chars
    let outcomes2 = vector[
        long_string,
        b"12345678901234567891".to_string(),
        b"12345678901234567892".to_string(),
    ];
    assert!(vectors::check_valid_outcomes(outcomes2, 20), 1);
}

#[test]
fun test_validate_functions_with_special_chars() {
    // Test with various special characters
    let message1 = b"Message with @#$%^&*()".to_string();
    assert!(vectors::validate_outcome_message(&message1, 100), 0);

    let detail1 = b"Detail: {key: \"value\"}".to_string();
    assert!(vectors::validate_outcome_detail(&detail1, 100), 1);

    // Test with control characters
    let message2 = b"Tab\there".to_string();
    assert!(vectors::validate_outcome_message(&message2, 100), 2);
}

#[test]
fun test_is_duplicate_with_similar_strings() {
    let messages = vector[
        b"test".to_string(),
        b"test ".to_string(), // With trailing space
        b" test".to_string(), // With leading space
        b"test1".to_string(),
    ];

    // Exact match only
    assert!(vectors::is_duplicate_message(&messages, &b"test".to_string()), 0);
    assert!(!vectors::is_duplicate_message(&messages, &b"TEST".to_string()), 1);
    assert!(!vectors::is_duplicate_message(&messages, &b"tes".to_string()), 2);
}
