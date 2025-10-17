// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

module futarchy_one_shot_utils::vectors;

use std::string::String;
use sui::coin::{Self, Coin};
use sui::vec_set;

// === Introduction ===
// Vector Methods and processing

// === Public Functions ===
// Combined check that a vector contains only unique elements and that all the elements are less then a certain length
public fun check_valid_outcomes(outcome: vector<String>, max_length: u64): bool {
    let length = outcome.length();
    if (length == 0) return false;

    // Create a vec_set to track unique strings
    let mut seen = vec_set::empty<String>();

    let mut i = 0;
    while (i < length) {
        let current_string_ref = &outcome[i];
        // Check length constraint
        let string_length = current_string_ref.length();
        if (string_length == 0 || string_length > max_length) {
            return false
        };
        if (seen.contains(current_string_ref)) {
            return false
        };

        // Add to our set of seen strings
        seen.insert(*current_string_ref);
        i = i + 1;
    };

    true
}

/// Validates a single outcome message - checks length bounds
public fun validate_outcome_message(message: &String, max_length: u64): bool {
    let length = message.length();
    length > 0 && length <= max_length
}

/// Validates outcome detail - checks length bounds
public fun validate_outcome_detail(detail: &String, max_length: u64): bool {
    let length = detail.length();
    length > 0 && length <= max_length
}

/// Checks if a message already exists in the outcome messages
public fun is_duplicate_message(outcome_messages: &vector<String>, new_message: &String): bool {
    let mut i = 0;
    let len = outcome_messages.length();
    while (i < len) {
        if (outcome_messages[i] == *new_message) {
            return true
        };
        i = i + 1;
    };
    false
}

/// Merges a vector of coins into a single coin
public fun merge_coins<T>(mut coins: vector<Coin<T>>, ctx: &mut TxContext): Coin<T> {
    assert!(!coins.is_empty(), 0);

    let mut merged = coins.pop_back();
    while (!coins.is_empty()) {
        coin::join(&mut merged, coins.pop_back());
    };
    coins.destroy_empty();

    merged
}
