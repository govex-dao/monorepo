module futarchy::vectors;

use std::string::{Self, String};
use sui::vec_set;

// === Introduction ===
//  Vector Methods and processing

// Combined check that a vector contains only unique elements and that all the elements are less then a certain length
public fun check_valid_outcomes(outcome: vector<String>, max_length: u64): bool {
    let length = vector::length(&outcome);
    if (length == 0) return false;

    // Create a vec_set to track unique strings
    let mut seen = vec_set::empty<vector<u8>>();

    let mut i = 0;
    while (i < length) {
        let current_string = vector::borrow(&outcome, i);

        // Check length constraint
        let string_length = string::length(current_string);
        if (string_length == 0 || string_length > max_length) {
            return false
        };

        // Check uniqueness
        let string_bytes = *string::as_bytes(current_string);
        if (vec_set::contains(&seen, &string_bytes)) {
            return false
        };

        // Add to our set of seen strings
        vec_set::insert(&mut seen, string_bytes);
        i = i + 1;
    };

    true
}
