#[test_only]
module futarchy_one_shot_utils::vectors_comprehensive_tests;

use std::string::{Self, String};
use sui::coin::{Self, Coin};
use sui::sui::SUI;
use sui::test_scenario::{Self as ts};
use futarchy_one_shot_utils::vectors;

// ========================================================================
// check_valid_outcomes - Comprehensive Tests
// ========================================================================

#[test]
fun test_check_valid_outcomes_basic_valid() {
    let mut outcomes = vector::empty<String>();
    outcomes.push_back(string::utf8(b"Yes"));
    outcomes.push_back(string::utf8(b"No"));
    assert!(vectors::check_valid_outcomes(outcomes, 100) == true, 0);
}

#[test]
fun test_check_valid_outcomes_single_outcome() {
    let mut outcomes = vector::empty<String>();
    outcomes.push_back(string::utf8(b"Only"));
    assert!(vectors::check_valid_outcomes(outcomes, 100) == true, 0);
}

#[test]
fun test_check_valid_outcomes_many_outcomes() {
    let mut outcomes = vector::empty<String>();
    outcomes.push_back(string::utf8(b"Option1"));
    outcomes.push_back(string::utf8(b"Option2"));
    outcomes.push_back(string::utf8(b"Option3"));
    outcomes.push_back(string::utf8(b"Option4"));
    outcomes.push_back(string::utf8(b"Option5"));
    assert!(vectors::check_valid_outcomes(outcomes, 100) == true, 0);
}

#[test]
fun test_check_valid_outcomes_unicode_strings() {
    let mut outcomes = vector::empty<String>();
    outcomes.push_back(string::utf8(b"Yes \xE2\x9C\x93"));  // Yes ✓
    outcomes.push_back(string::utf8(b"No \xE2\x9C\x97"));   // No ✗
    assert!(vectors::check_valid_outcomes(outcomes, 100) == true, 0);
}

#[test]
fun test_check_valid_outcomes_exact_max_length() {
    let mut outcomes = vector::empty<String>();
    outcomes.push_back(string::utf8(b"12345"));
    outcomes.push_back(string::utf8(b"67890"));
    assert!(vectors::check_valid_outcomes(outcomes, 5) == true, 0);
}

#[test]
fun test_check_valid_outcomes_one_char_each() {
    let mut outcomes = vector::empty<String>();
    outcomes.push_back(string::utf8(b"A"));
    outcomes.push_back(string::utf8(b"B"));
    outcomes.push_back(string::utf8(b"C"));
    assert!(vectors::check_valid_outcomes(outcomes, 1) == true, 0);
}

// === Failure Cases ===

#[test]
fun test_check_valid_outcomes_empty_vector() {
    let outcomes = vector::empty<String>();
    assert!(vectors::check_valid_outcomes(outcomes, 100) == false, 0);
}

#[test]
fun test_check_valid_outcomes_duplicate_exact() {
    let mut outcomes = vector::empty<String>();
    outcomes.push_back(string::utf8(b"Duplicate"));
    outcomes.push_back(string::utf8(b"Duplicate"));
    assert!(vectors::check_valid_outcomes(outcomes, 100) == false, 0);
}

#[test]
fun test_check_valid_outcomes_duplicate_in_middle() {
    let mut outcomes = vector::empty<String>();
    outcomes.push_back(string::utf8(b"First"));
    outcomes.push_back(string::utf8(b"Second"));
    outcomes.push_back(string::utf8(b"First"));
    assert!(vectors::check_valid_outcomes(outcomes, 100) == false, 0);
}

#[test]
fun test_check_valid_outcomes_duplicate_case_sensitive() {
    // Should be treated as different (case-sensitive)
    let mut outcomes = vector::empty<String>();
    outcomes.push_back(string::utf8(b"yes"));
    outcomes.push_back(string::utf8(b"Yes"));
    assert!(vectors::check_valid_outcomes(outcomes, 100) == true, 0);
}

#[test]
fun test_check_valid_outcomes_empty_string() {
    let mut outcomes = vector::empty<String>();
    outcomes.push_back(string::utf8(b"Valid"));
    outcomes.push_back(string::utf8(b""));
    assert!(vectors::check_valid_outcomes(outcomes, 100) == false, 0);
}

#[test]
fun test_check_valid_outcomes_empty_string_only() {
    let mut outcomes = vector::empty<String>();
    outcomes.push_back(string::utf8(b""));
    assert!(vectors::check_valid_outcomes(outcomes, 100) == false, 0);
}

#[test]
fun test_check_valid_outcomes_exceeds_max_length_first() {
    let mut outcomes = vector::empty<String>();
    outcomes.push_back(string::utf8(b"TooLongString"));
    outcomes.push_back(string::utf8(b"OK"));
    assert!(vectors::check_valid_outcomes(outcomes, 5) == false, 0);
}

#[test]
fun test_check_valid_outcomes_exceeds_max_length_last() {
    let mut outcomes = vector::empty<String>();
    outcomes.push_back(string::utf8(b"OK"));
    outcomes.push_back(string::utf8(b"TooLongString"));
    assert!(vectors::check_valid_outcomes(outcomes, 5) == false, 0);
}

#[test]
fun test_check_valid_outcomes_off_by_one_length() {
    let mut outcomes = vector::empty<String>();
    outcomes.push_back(string::utf8(b"123456")); // 6 chars
    assert!(vectors::check_valid_outcomes(outcomes, 5) == false, 0);
}

#[test]
fun test_check_valid_outcomes_max_length_zero() {
    let mut outcomes = vector::empty<String>();
    outcomes.push_back(string::utf8(b"Any"));
    assert!(vectors::check_valid_outcomes(outcomes, 0) == false, 0);
}

// ========================================================================
// validate_outcome_message - Comprehensive Tests
// ========================================================================

#[test]
fun test_validate_outcome_message_valid_short() {
    let msg = string::utf8(b"OK");
    assert!(vectors::validate_outcome_message(&msg, 100) == true, 0);
}

#[test]
fun test_validate_outcome_message_valid_long() {
    let msg = string::utf8(b"This is a very long message that is still valid because it's under the limit");
    assert!(vectors::validate_outcome_message(&msg, 100) == true, 0);
}

#[test]
fun test_validate_outcome_message_exact_boundary() {
    let msg = string::utf8(b"12345");
    assert!(vectors::validate_outcome_message(&msg, 5) == true, 0);
}

#[test]
fun test_validate_outcome_message_single_char() {
    let msg = string::utf8(b"X");
    assert!(vectors::validate_outcome_message(&msg, 100) == true, 0);
}

#[test]
fun test_validate_outcome_message_unicode() {
    let msg = string::utf8(b"\xE2\x9C\x93");  // ✓
    assert!(vectors::validate_outcome_message(&msg, 10) == true, 0);
}

#[test]
fun test_validate_outcome_message_whitespace() {
    let msg = string::utf8(b"   ");
    assert!(vectors::validate_outcome_message(&msg, 10) == true, 0);
}

// === Failure Cases ===

#[test]
fun test_validate_outcome_message_empty() {
    let msg = string::utf8(b"");
    assert!(vectors::validate_outcome_message(&msg, 100) == false, 0);
}

#[test]
fun test_validate_outcome_message_exceeds_by_one() {
    let msg = string::utf8(b"123456");
    assert!(vectors::validate_outcome_message(&msg, 5) == false, 0);
}

#[test]
fun test_validate_outcome_message_exceeds_by_many() {
    let msg = string::utf8(b"Way too long for this limit");
    assert!(vectors::validate_outcome_message(&msg, 5) == false, 0);
}

#[test]
fun test_validate_outcome_message_max_length_zero() {
    let msg = string::utf8(b"X");
    assert!(vectors::validate_outcome_message(&msg, 0) == false, 0);
}

// ========================================================================
// validate_outcome_detail - Comprehensive Tests
// ========================================================================

#[test]
fun test_validate_outcome_detail_valid() {
    let detail = string::utf8(b"Detailed description");
    assert!(vectors::validate_outcome_detail(&detail, 100) == true, 0);
}

#[test]
fun test_validate_outcome_detail_exact_boundary() {
    let detail = string::utf8(b"12345");
    assert!(vectors::validate_outcome_detail(&detail, 5) == true, 0);
}

#[test]
fun test_validate_outcome_detail_empty() {
    let detail = string::utf8(b"");
    assert!(vectors::validate_outcome_detail(&detail, 100) == false, 0);
}

#[test]
fun test_validate_outcome_detail_too_long() {
    let detail = string::utf8(b"This detail is way too long");
    assert!(vectors::validate_outcome_detail(&detail, 5) == false, 0);
}

#[test]
fun test_validate_outcome_detail_multiline_simulation() {
    // Simulate multiline with newline characters
    let detail = string::utf8(b"Line 1\nLine 2\nLine 3");
    assert!(vectors::validate_outcome_detail(&detail, 100) == true, 0);
}

// ========================================================================
// is_duplicate_message - Comprehensive Tests
// ========================================================================

#[test]
fun test_is_duplicate_message_found_first() {
    let mut messages = vector::empty<String>();
    messages.push_back(string::utf8(b"Target"));
    messages.push_back(string::utf8(b"Other"));

    let msg = string::utf8(b"Target");
    assert!(vectors::is_duplicate_message(&messages, &msg) == true, 0);
}

#[test]
fun test_is_duplicate_message_found_middle() {
    let mut messages = vector::empty<String>();
    messages.push_back(string::utf8(b"First"));
    messages.push_back(string::utf8(b"Target"));
    messages.push_back(string::utf8(b"Last"));

    let msg = string::utf8(b"Target");
    assert!(vectors::is_duplicate_message(&messages, &msg) == true, 0);
}

#[test]
fun test_is_duplicate_message_found_last() {
    let mut messages = vector::empty<String>();
    messages.push_back(string::utf8(b"First"));
    messages.push_back(string::utf8(b"Second"));
    messages.push_back(string::utf8(b"Target"));

    let msg = string::utf8(b"Target");
    assert!(vectors::is_duplicate_message(&messages, &msg) == true, 0);
}

#[test]
fun test_is_duplicate_message_case_sensitive_no_match() {
    let mut messages = vector::empty<String>();
    messages.push_back(string::utf8(b"lowercase"));

    let msg = string::utf8(b"LOWERCASE");
    assert!(vectors::is_duplicate_message(&messages, &msg) == false, 0);
}

#[test]
fun test_is_duplicate_message_whitespace_matters() {
    let mut messages = vector::empty<String>();
    messages.push_back(string::utf8(b"test"));

    let msg = string::utf8(b"test "); // trailing space
    assert!(vectors::is_duplicate_message(&messages, &msg) == false, 0);
}

#[test]
fun test_is_duplicate_message_not_found() {
    let mut messages = vector::empty<String>();
    messages.push_back(string::utf8(b"A"));
    messages.push_back(string::utf8(b"B"));
    messages.push_back(string::utf8(b"C"));

    let msg = string::utf8(b"D");
    assert!(vectors::is_duplicate_message(&messages, &msg) == false, 0);
}

#[test]
fun test_is_duplicate_message_empty_vector() {
    let messages = vector::empty<String>();
    let msg = string::utf8(b"Any");
    assert!(vectors::is_duplicate_message(&messages, &msg) == false, 0);
}

#[test]
fun test_is_duplicate_message_single_element_match() {
    let mut messages = vector::empty<String>();
    messages.push_back(string::utf8(b"Only"));

    let msg = string::utf8(b"Only");
    assert!(vectors::is_duplicate_message(&messages, &msg) == true, 0);
}

#[test]
fun test_is_duplicate_message_single_element_no_match() {
    let mut messages = vector::empty<String>();
    messages.push_back(string::utf8(b"Only"));

    let msg = string::utf8(b"Different");
    assert!(vectors::is_duplicate_message(&messages, &msg) == false, 0);
}

#[test]
fun test_is_duplicate_message_many_elements() {
    let mut messages = vector::empty<String>();
    let mut i = 0;
    while (i < 100) {
        messages.push_back(string::utf8(b"Item"));
        i = i + 1;
    };

    let msg = string::utf8(b"Item");
    assert!(vectors::is_duplicate_message(&messages, &msg) == true, 0);
}

// ========================================================================
// merge_coins - Comprehensive Tests
// ========================================================================

#[test]
fun test_merge_coins_two_coins() {
    let mut scenario = ts::begin(@0xA);
    {
        let ctx = ts::ctx(&mut scenario);

        let coin1 = coin::mint_for_testing<SUI>(100, ctx);
        let coin2 = coin::mint_for_testing<SUI>(200, ctx);

        let mut coins = vector::empty<Coin<SUI>>();
        coins.push_back(coin1);
        coins.push_back(coin2);

        let merged = vectors::merge_coins(coins, ctx);
        assert!(coin::value(&merged) == 300, 0);

        coin::burn_for_testing(merged);
    };
    ts::end(scenario);
}

#[test]
fun test_merge_coins_single_coin() {
    let mut scenario = ts::begin(@0xA);
    {
        let ctx = ts::ctx(&mut scenario);

        let coin1 = coin::mint_for_testing<SUI>(500, ctx);

        let mut coins = vector::empty<Coin<SUI>>();
        coins.push_back(coin1);

        let merged = vectors::merge_coins(coins, ctx);
        assert!(coin::value(&merged) == 500, 0);

        coin::burn_for_testing(merged);
    };
    ts::end(scenario);
}

#[test]
fun test_merge_coins_many_coins() {
    let mut scenario = ts::begin(@0xA);
    {
        let ctx = ts::ctx(&mut scenario);

        let mut coins = vector::empty<Coin<SUI>>();
        coins.push_back(coin::mint_for_testing<SUI>(10, ctx));
        coins.push_back(coin::mint_for_testing<SUI>(20, ctx));
        coins.push_back(coin::mint_for_testing<SUI>(30, ctx));
        coins.push_back(coin::mint_for_testing<SUI>(40, ctx));
        coins.push_back(coin::mint_for_testing<SUI>(50, ctx));

        let merged = vectors::merge_coins(coins, ctx);
        assert!(coin::value(&merged) == 150, 0);

        coin::burn_for_testing(merged);
    };
    ts::end(scenario);
}

#[test]
fun test_merge_coins_with_zero_value() {
    let mut scenario = ts::begin(@0xA);
    {
        let ctx = ts::ctx(&mut scenario);

        let mut coins = vector::empty<Coin<SUI>>();
        coins.push_back(coin::mint_for_testing<SUI>(100, ctx));
        coins.push_back(coin::mint_for_testing<SUI>(0, ctx));
        coins.push_back(coin::mint_for_testing<SUI>(200, ctx));

        let merged = vectors::merge_coins(coins, ctx);
        assert!(coin::value(&merged) == 300, 0);

        coin::burn_for_testing(merged);
    };
    ts::end(scenario);
}

#[test]
fun test_merge_coins_all_zero() {
    let mut scenario = ts::begin(@0xA);
    {
        let ctx = ts::ctx(&mut scenario);

        let mut coins = vector::empty<Coin<SUI>>();
        coins.push_back(coin::mint_for_testing<SUI>(0, ctx));
        coins.push_back(coin::mint_for_testing<SUI>(0, ctx));
        coins.push_back(coin::mint_for_testing<SUI>(0, ctx));

        let merged = vectors::merge_coins(coins, ctx);
        assert!(coin::value(&merged) == 0, 0);

        coin::burn_for_testing(merged);
    };
    ts::end(scenario);
}

#[test]
fun test_merge_coins_large_values() {
    let mut scenario = ts::begin(@0xA);
    {
        let ctx = ts::ctx(&mut scenario);

        let mut coins = vector::empty<Coin<SUI>>();
        coins.push_back(coin::mint_for_testing<SUI>(1_000_000_000, ctx));
        coins.push_back(coin::mint_for_testing<SUI>(2_000_000_000, ctx));

        let merged = vectors::merge_coins(coins, ctx);
        assert!(coin::value(&merged) == 3_000_000_000, 0);

        coin::burn_for_testing(merged);
    };
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = 0)]
fun test_merge_coins_empty_vector() {
    let mut scenario = ts::begin(@0xA);
    {
        let ctx = ts::ctx(&mut scenario);
        let coins = vector::empty<Coin<SUI>>();
        let merged = vectors::merge_coins(coins, ctx);
        coin::burn_for_testing(merged);
    };
    ts::end(scenario);
}

// ========================================================================
// Integration & Edge Case Tests
// ========================================================================

#[test]
fun test_check_valid_outcomes_stress_test() {
    // Test with many outcomes at exact boundary
    let mut outcomes = vector::empty<String>();
    let mut i = 0;
    while (i < 50) {
        let mut bytes = vector::empty<u8>();
        bytes.push_back((65 + i) as u8); // A, B, C...
        outcomes.push_back(string::utf8(bytes));
        i = i + 1;
    };
    assert!(vectors::check_valid_outcomes(outcomes, 100) == true, 0);
}

#[test]
fun test_validate_functions_consistency() {
    // Both validation functions should behave identically
    let test_string = string::utf8(b"Test");
    let max_len = 10;

    let msg_result = vectors::validate_outcome_message(&test_string, max_len);
    let detail_result = vectors::validate_outcome_detail(&test_string, max_len);

    assert!(msg_result == detail_result, 0);
}

#[test]
fun test_duplicate_detection_with_valid_outcomes() {
    // Ensure is_duplicate_message aligns with check_valid_outcomes logic
    let mut messages = vector::empty<String>();
    messages.push_back(string::utf8(b"Yes"));
    messages.push_back(string::utf8(b"No"));

    // Valid outcomes shouldn't have duplicates
    assert!(vectors::check_valid_outcomes(messages, 100) == true, 0);

    // Adding duplicate should be detected
    let dup = string::utf8(b"Yes");
    assert!(vectors::is_duplicate_message(&messages, &dup) == true, 0);
}

#[test]
fun test_special_characters_in_outcomes() {
    let mut outcomes = vector::empty<String>();
    outcomes.push_back(string::utf8(b"!@#$%^&*()"));
    outcomes.push_back(string::utf8(b"<>?:\"{}[]"));
    assert!(vectors::check_valid_outcomes(outcomes, 20) == true, 0);
}

#[test]
fun test_numeric_strings_in_outcomes() {
    let mut outcomes = vector::empty<String>();
    outcomes.push_back(string::utf8(b"123"));
    outcomes.push_back(string::utf8(b"456"));
    outcomes.push_back(string::utf8(b"789"));
    assert!(vectors::check_valid_outcomes(outcomes, 10) == true, 0);
}
