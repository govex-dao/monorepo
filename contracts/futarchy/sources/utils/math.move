module futarchy::math;

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
public fun mul_div_to_64(a: u64, b: u64, c: u64): u64 {
    assert!(c != 0, EDivideByZero);
    let a_128 = (a as u128);
    let b_128 = (b as u128);
    let c_128 = (c as u128);
    let result = (a_128 * b_128) / c_128;
    assert!(result <= (u64::max_value!() as u128), EOverflow);
    (result as u64)
}

public fun mul_div_to_128(a: u64, b: u64, c: u64): u128 {
    assert!(c != 0, EDivideByZero);
    let a_128 = (a as u128);
    let b_128 = (b as u128);
    let c_128 = (c as u128);
    // The intermediate product a_128 * b_128 can overflow u128, but the final result
    // after division is expected to fit within u128. This is a common pattern for
    // high-precision calculations where intermediate values exceed standard types.
    let result = (a_128 * b_128) / c_128;
    result
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
public fun mul_div_up(a: u64, b: u64, c: u64): u64 {
    assert!(c != 0, EDivideByZero);
    let a_128 = (a as u128);
    let b_128 = (b as u128);
    let c_128 = (c as u128);
    let numerator = a_128 * b_128;
    let result = if (numerator == 0) {
        0
    } else {
        let sum = numerator + c_128 - 1;
        assert!(sum >= numerator, EOverflow); // check for overflow
        sum / c_128
    };
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

// Returns the smaller of two u64 values
public fun min(a: u64, b: u64): u64 {
    if (a < b) { a } else { b }
}

// Returns the larger of two u64 values
public fun max(a: u64, b: u64): u64 {
    if (a > b) { a } else { b }
}

// Integer square root using Newton's method
// Returns the largest integer x such that x * x <= n
public fun sqrt(n: u64): u64 {
    if (n == 0) return 0;
    if (n < 4) return 1;
    
    // Initial guess: half of n
    let mut x = n / 2;
    let mut last_x = x;
    
    loop {
        // Newton's iteration: x = (x + n/x) / 2
        x = (x + n / x) / 2;
        
        // Check convergence
        if (x >= last_x) {
            return last_x;
        };
        last_x = x;
    }
}

// Integer square root for u128 values
public fun sqrt_u128(n: u128): u128 {
    if (n == 0) return 0;
    if (n < 4) return 1;
    
    // Initial guess
    let mut x = n / 2;
    let mut last_x = x;
    
    loop {
        // Newton's iteration
        x = (x + n / x) / 2;
        
        // Check convergence
        if (x >= last_x) {
            return last_x;
        };
        last_x = x;
    }
}

// Absolute difference between two u64 values
public fun abs_diff(a: u64, b: u64): u64 {
    if (a > b) { a - b } else { b - a }
}

// Check if a value is within a percentage tolerance
// Returns true if |a - b| <= (tolerance_bps * max(a,b)) / 10000
public fun within_tolerance(a: u64, b: u64, tolerance_bps: u64): bool {
    let diff = abs_diff(a, b);
    let max_val = max(a, b);
    let tolerance = mul_div_to_64(max_val, tolerance_bps, 10000);
    diff <= tolerance
}
