module futarchy::vectors;

// === Introduction ===
// Vector Methods and processing

// === Imports ===
use std::string::String;
use sui::vec_set;

// === Public Functions ===
// Combined check that a vector contains only unique elements and that all the elements are less then a certain length
public fun check_valid_outcomes(outcome: vector<String>, max_length: u64): bool {
    let length = vector::length(&outcome);
    if (length == 0) return false;

    // Create a vec_set to track unique strings
    let mut seen = vec_set::empty<String>();

    let mut i = 0;
    while (i < length) {
        let current_string_ref = vector::borrow(&outcome, i);
        // Check length constraint
        let string_length = current_string_ref.length();
        if (string_length == 0 || string_length > max_length) {
            return false
        };
        if (vec_set::contains(&seen, current_string_ref)) {
            return false
        };

        // Add to our set of seen strings
        vec_set::insert(&mut seen, *current_string_ref);
        i = i + 1;
    };

    true
}
