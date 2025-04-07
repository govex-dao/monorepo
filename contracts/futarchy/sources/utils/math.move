module futarchy::math;

use std::u128;
use std::u64;

// === Introduction ===
// Integer type conversion and integer methods

// === Errors ===
const EOVERFLOW: u64 = 1001;
const EDIVIDE_BY_ZERO: u64 = 1002;
const EVALUE_EXCEEDS_U64: u64 = 1003;

/// Multiplies two u64 values and divides by a third, checking for overflow
/// Returns (a * b) / c
public fun mul_div_to_64(a: u64, b: u64, c: u64): u64 {
    assert!(c != 0, EDIVIDE_BY_ZERO);
    let a_128 = (a as u128);
    let b_128 = (b as u128);
    let c_128 = (c as u128);
    let result = (a_128 * b_128) / c_128;
    assert!(result <= (u64::max_value!() as u128), EOVERFLOW); // Max u64
    (result as u64)
}

public fun mul_div_to_128(a: u64, b: u64, c: u64): u128 {
    assert!(c != 0, EDIVIDE_BY_ZERO);
    let a_128 = (a as u128);
    let b_128 = (b as u128);
    let c_128 = (c as u128);
    let result = (a_128 * b_128) / c_128;
    result
}

/// Safely multiplies two u64 values and divides by a third, rounding up
/// Returns ceil((a * b) / c)
public fun mul_div_up(a: u64, b: u64, c: u64): u64 {
    assert!(c != 0, EDIVIDE_BY_ZERO);
    let a_128 = (a as u128);
    let b_128 = (b as u128);
    let c_128 = (c as u128);
    let numerator = a_128 * b_128;
    let result = if (numerator == 0) {
        0
    } else {
        (numerator + c_128 - 1) / c_128
    };
    assert!(result <= (u64::max_value!() as u128), EOVERFLOW); // Max u64
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
    assert!(value <= (u64::max_value!() as u128), EVALUE_EXCEEDS_U64);
    (value as u64)
}
