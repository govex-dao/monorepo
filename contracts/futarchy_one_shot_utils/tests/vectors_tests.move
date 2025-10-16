#[test_only]
module futarchy_one_shot_utils::vectors_tests;

use futarchy_one_shot_utils::vectors;
use std::string::{Self, String};

// === Tests for check_valid_outcomes ===

#[test]
fun test_check_valid_outcomes_success() {
    let mut outcomes = vector::empty<String>();
    outcomes.push_back(string::utf8(b"Yes"));
    outcomes.push_back(string::utf8(b"No"));

    let result = vectors::check_valid_outcomes(outcomes, 100);
    assert!(result == true, 0);
}

#[test]
fun test_check_valid_outcomes_empty_vector() {
    let outcomes = vector::empty<String>();
    let result = vectors::check_valid_outcomes(outcomes, 100);
    assert!(result == false, 0);
}

#[test]
fun test_check_valid_outcomes_duplicate() {
    let mut outcomes = vector::empty<String>();
    outcomes.push_back(string::utf8(b"Yes"));
    outcomes.push_back(string::utf8(b"Yes"));

    let result = vectors::check_valid_outcomes(outcomes, 100);
    assert!(result == false, 0);
}

#[test]
fun test_check_valid_outcomes_empty_string() {
    let mut outcomes = vector::empty<String>();
    outcomes.push_back(string::utf8(b"Yes"));
    outcomes.push_back(string::utf8(b""));

    let result = vectors::check_valid_outcomes(outcomes, 100);
    assert!(result == false, 0);
}

#[test]
fun test_check_valid_outcomes_exceeds_max_length() {
    let mut outcomes = vector::empty<String>();
    outcomes.push_back(string::utf8(b"Short"));
    outcomes.push_back(
        string::utf8(b"This is a very long string that exceeds the maximum allowed length"),
    );

    let result = vectors::check_valid_outcomes(outcomes, 10);
    assert!(result == false, 0);
}

// === Tests for validate_outcome_message ===

#[test]
fun test_validate_outcome_message_valid() {
    let msg = string::utf8(b"Valid message");
    let result = vectors::validate_outcome_message(&msg, 100);
    assert!(result == true, 0);
}

#[test]
fun test_validate_outcome_message_empty() {
    let msg = string::utf8(b"");
    let result = vectors::validate_outcome_message(&msg, 100);
    assert!(result == false, 0);
}

#[test]
fun test_validate_outcome_message_too_long() {
    let msg = string::utf8(b"This is too long");
    let result = vectors::validate_outcome_message(&msg, 5);
    assert!(result == false, 0);
}

#[test]
fun test_validate_outcome_message_exact_max() {
    let msg = string::utf8(b"12345");
    let result = vectors::validate_outcome_message(&msg, 5);
    assert!(result == true, 0);
}

// === Tests for is_duplicate_message ===

#[test]
fun test_is_duplicate_message_found() {
    let mut messages = vector::empty<String>();
    messages.push_back(string::utf8(b"Yes"));
    messages.push_back(string::utf8(b"No"));

    let msg = string::utf8(b"Yes");
    let result = vectors::is_duplicate_message(&messages, &msg);
    assert!(result == true, 0);
}

#[test]
fun test_is_duplicate_message_not_found() {
    let mut messages = vector::empty<String>();
    messages.push_back(string::utf8(b"Yes"));
    messages.push_back(string::utf8(b"No"));

    let msg = string::utf8(b"Maybe");
    let result = vectors::is_duplicate_message(&messages, &msg);
    assert!(result == false, 0);
}

#[test]
fun test_is_duplicate_message_empty_vector() {
    let messages = vector::empty<String>();
    let msg = string::utf8(b"Yes");
    let result = vectors::is_duplicate_message(&messages, &msg);
    assert!(result == false, 0);
}
