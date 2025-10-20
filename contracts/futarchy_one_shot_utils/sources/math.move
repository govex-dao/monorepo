// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

module futarchy_one_shot_utils::math;

use std::u128;
use std::u64;

// === Introduction ===
// Integer type conversion and integer methods

// === Errors ===
const EOverflow: u64 = 0;
const EDivideByZero: u64 = 1;
const EValueExceedsU64: u64 = 2;

// === Public Functions ===
// Multiplies two u64 values and divides by a third, checking for overflow
// Returns (a * b) / c
//
// SAFETY: The product of two u64 values can be at most (2^64 - 1)^2 = 2^128 - 2^65 + 1,
// which is less than 2^128 and therefore always fits in a u128. This property ensures
// that the intermediate multiplication a_128 * b_128 will never overflow.
// The division by c then reduces the result, and we verify it fits in u64 before casting.
public fun mul_div_to_64(a: u64, b: u64, c: u64): u64 {
    assert!(c != 0, EDivideByZero);

    // Cast to u128 to prevent overflow during multiplication
    // SAFE: Product of two u64s always fits in u128 (see safety note above)
    let a_128 = (a as u128);
    let b_128 = (b as u128);
    let c_128 = (c as u128);

    // Perform the multiplication and division
    let result = (a_128 * b_128) / c_128;

    // Ensure the result fits back into u64
    assert!(result <= (u64::max_value!() as u128), EOverflow);
    (result as u64)
}

public fun mul_div_to_128(a: u64, b: u64, c: u64): u128 {
    assert!(c != 0, EDivideByZero);
    // Use u256 for intermediate calculation to avoid overflow
    let a_256 = (a as u256);
    let b_256 = (b as u256);
    let c_256 = (c as u256);
    let result_256 = (a_256 * b_256) / c_256;
    // Ensure result fits in u128
    assert!(result_256 <= (u128::max_value!() as u256), EOverflow);
    (result_256 as u128)
}

public fun mul_div_mixed(a: u128, b: u64, c: u128): u128 {
    assert!(c != 0, EDivideByZero);
    let a_256 = (a as u256);
    let b_256 = (b as u256);
    let c_256 = (c as u256);
    let result = (a_256 * b_256) / c_256;
    assert!(result <= (u128::max_value!() as u256), EOverflow);
    (result as u128)
}

// Safely multiplies two u64 values and divides by a third, rounding up
// Returns ceil((a * b) / c)
//
// SAFETY: Same as mul_div_to_64 - the product of two u64s always fits in u128.
// The rounding up operation adds at most (c-1) to the numerator before division.
public fun mul_div_up(a: u64, b: u64, c: u64): u64 {
    assert!(c != 0, EDivideByZero);

    // Cast to u128 to prevent overflow during multiplication
    // SAFE: Product of two u64s always fits in u128
    let a_128 = (a as u128);
    let b_128 = (b as u128);
    let c_128 = (c as u128);

    // Calculate the numerator (product of a and b)
    let numerator = a_128 * b_128;

    // Perform division with rounding up
    let result = if (numerator == 0) {
        0
    } else {
        // Add (c-1) to round up: ceil(n/c) = floor((n + c - 1) / c)
        let sum = numerator + c_128 - 1;
        assert!(sum >= numerator, EOverflow); // Verify no overflow in addition
        sum / c_128
    };

    // Ensure the result fits back into u64
    assert!(result <= (u64::max_value!() as u128), EOverflow);
    (result as u64)
}

// Saturating addition that won't overflow
public fun saturating_add(a: u128, b: u128): u128 {
    if (u128::max_value!() - a < b) {
        u128::max_value!()
    } else {
        a + b
    }
}

// Saturating subtraction that won't underflow
public fun saturating_sub(a: u128, b: u128): u128 {
    if (a < b) {
        0
    } else {
        a - b
    }
}

public fun safe_u128_to_u64(value: u128): u64 {
    assert!(value <= (u64::max_value!() as u128), EValueExceedsU64);
    (value as u64)
}

// Check if a value is within a percentage tolerance
// Returns true if |a - b| <= (tolerance_bps * max(a,b)) / 10000
public fun within_tolerance(a: u64, b: u64, tolerance_bps: u64): bool {
    let diff = a.diff(b);
    let max_val = a.max(b);
    let tolerance = mul_div_to_64(max_val, tolerance_bps, 10000);
    diff <= tolerance
}
