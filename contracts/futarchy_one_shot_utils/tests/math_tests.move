#[test_only]
module futarchy_one_shot_utils::math_tests;

use futarchy_one_shot_utils::math;
use std::u64;
use std::u128;

// === mul_div_to_64 Tests ===

#[test]
fun test_mul_div_to_64_basic() {
    assert!(math::mul_div_to_64(100, 50, 10) == 500, 0);
    assert!(math::mul_div_to_64(1000, 200, 100) == 2000, 1);
    assert!(math::mul_div_to_64(7, 3, 2) == 10, 2); // 7*3/2 = 10.5 -> 10 (floors)
}

#[test]
fun test_mul_div_to_64_edge_cases() {
    // Zero cases
    assert!(math::mul_div_to_64(0, 100, 50) == 0, 0);
    assert!(math::mul_div_to_64(100, 0, 50) == 0, 1);

    // Identity cases
    assert!(math::mul_div_to_64(100, 1, 1) == 100, 2);
    assert!(math::mul_div_to_64(100, 100, 100) == 100, 3);
}

#[test]
fun test_mul_div_to_64_large_values() {
    // Test with large u64 values
    let max = u64::max_value!();
    assert!(math::mul_div_to_64(max, 1, 2) == max / 2, 0);
    assert!(math::mul_div_to_64(max / 2, 2, 1) == max - 1, 1); // (max/2)*2 rounds down
}

#[test]
#[expected_failure(abort_code = 1)]
fun test_mul_div_to_64_divide_by_zero() {
    math::mul_div_to_64(100, 50, 0);
}

// === mul_div_up Tests ===

#[test]
fun test_mul_div_up_rounding() {
    // Should round up
    assert!(math::mul_div_up(7, 3, 2) == 11, 0); // 7*3/2 = 10.5 -> 11
    assert!(math::mul_div_up(10, 3, 2) == 15, 1); // 10*3/2 = 15
    assert!(math::mul_div_up(5, 3, 2) == 8, 2);   // 5*3/2 = 7.5 -> 8

    // Exact division should not round up
    assert!(math::mul_div_up(10, 10, 5) == 20, 3);
}

#[test]
fun test_mul_div_up_zero() {
    assert!(math::mul_div_up(0, 100, 50) == 0, 0);
    assert!(math::mul_div_up(100, 0, 50) == 0, 1);
}

#[test]
#[expected_failure(abort_code = 1)]
fun test_mul_div_up_divide_by_zero() {
    math::mul_div_up(100, 50, 0);
}

// === mul_div_to_128 Tests ===

#[test]
fun test_mul_div_to_128() {
    assert!(math::mul_div_to_128(1000, 2000, 100) == 20000, 0);
    assert!(math::mul_div_to_128(u64::max_value!(), 2, 1) == (u64::max_value!() as u128) * 2, 1);
}

#[test]
fun test_mul_div_mixed() {
    let a = 1000000000 as u128;
    let b = 500 as u64;
    let c = 100 as u128;
    assert!(math::mul_div_mixed(a, b, c) == 5000000000, 0);
}

// === sqrt Tests ===

#[test]
fun test_sqrt_exact_squares() {
    assert!(math::sqrt(0) == 0, 0);
    assert!(math::sqrt(1) == 1, 1);
    assert!(math::sqrt(4) == 2, 2);
    assert!(math::sqrt(9) == 3, 3);
    assert!(math::sqrt(16) == 4, 4);
    assert!(math::sqrt(25) == 5, 5);
    assert!(math::sqrt(100) == 10, 6);
    assert!(math::sqrt(144) == 12, 7);
    assert!(math::sqrt(10000) == 100, 8);
}

#[test]
fun test_sqrt_non_squares() {
    // Should return floor(sqrt(n))
    assert!(math::sqrt(2) == 1, 0);
    assert!(math::sqrt(3) == 1, 1);
    assert!(math::sqrt(5) == 2, 2);
    assert!(math::sqrt(8) == 2, 3);
    assert!(math::sqrt(15) == 3, 4);
    assert!(math::sqrt(99) == 9, 5);
    assert!(math::sqrt(101) == 10, 6);
}

#[test]
fun test_sqrt_u128() {
    assert!(math::sqrt_u128(0) == 0, 0);
    assert!(math::sqrt_u128(1) == 1, 1);
    assert!(math::sqrt_u128(10000) == 100, 2);
    assert!(math::sqrt_u128(1000000) == 1000, 3);
}

// === Saturating Operations Tests ===

#[test]
fun test_saturating_add_normal() {
    assert!(math::saturating_add(100, 200) == 300, 0);
    assert!(math::saturating_add(0, 0) == 0, 1);
    assert!(math::saturating_add(1000000, 2000000) == 3000000, 2);
}

#[test]
fun test_saturating_add_overflow() {
    let max = u128::max_value!();
    assert!(math::saturating_add(max, 1) == max, 0);
    assert!(math::saturating_add(max, max) == max, 1);
    assert!(math::saturating_add(max - 10, 20) == max, 2);
}

#[test]
fun test_saturating_sub_normal() {
    assert!(math::saturating_sub(200, 100) == 100, 0);
    assert!(math::saturating_sub(1000, 1000) == 0, 1);
    assert!(math::saturating_sub(5000000, 1000000) == 4000000, 2);
}

#[test]
fun test_saturating_sub_underflow() {
    assert!(math::saturating_sub(50, 100) == 0, 0);
    assert!(math::saturating_sub(0, 1) == 0, 1);
    assert!(math::saturating_sub(0, u128::max_value!()) == 0, 2);
}

// === safe_u128_to_u64 Tests ===

#[test]
fun test_safe_u128_to_u64() {
    assert!(math::safe_u128_to_u64(0) == 0, 0);
    assert!(math::safe_u128_to_u64(1000) == 1000, 1);
    assert!(math::safe_u128_to_u64((u64::max_value!() as u128)) == u64::max_value!(), 2);
}

#[test]
#[expected_failure(abort_code = 2)] // EValueExceedsU64
fun test_safe_u128_to_u64_overflow() {
    let too_large = (u64::max_value!() as u128) + 1;
    math::safe_u128_to_u64(too_large);
}

// === min/max Tests ===

#[test]
fun test_min_max() {
    assert!(math::min(5, 10) == 5, 0);
    assert!(math::min(10, 5) == 5, 1);
    assert!(math::min(100, 100) == 100, 2);
    assert!(math::min(0, 1000) == 0, 3);

    assert!(math::max(5, 10) == 10, 4);
    assert!(math::max(10, 5) == 10, 5);
    assert!(math::max(100, 100) == 100, 6);
    assert!(math::max(0, 1000) == 1000, 7);
}

// === abs_diff Tests ===

#[test]
fun test_abs_diff() {
    assert!(math::abs_diff(100, 50) == 50, 0);
    assert!(math::abs_diff(50, 100) == 50, 1);
    assert!(math::abs_diff(100, 100) == 0, 2);
    assert!(math::abs_diff(0, 1000) == 1000, 3);
    assert!(math::abs_diff(1000, 0) == 1000, 4);
}

// === within_tolerance Tests ===

#[test]
fun test_within_tolerance_percentage() {
    // 5% tolerance (500 bps)
    assert!(math::within_tolerance(100, 105, 500) == true, 0);
    assert!(math::within_tolerance(100, 95, 500) == true, 1);
    assert!(math::within_tolerance(100, 110, 500) == false, 2);
    assert!(math::within_tolerance(100, 90, 500) == false, 3);

    // 1% tolerance (100 bps)
    assert!(math::within_tolerance(1000, 1010, 100) == true, 4);
    assert!(math::within_tolerance(1000, 1011, 100) == false, 5);
}

#[test]
fun test_within_tolerance_edge_cases() {
    // Exact match
    assert!(math::within_tolerance(100, 100, 0) == true, 0);

    // Zero values
    assert!(math::within_tolerance(0, 0, 100) == true, 1);
    assert!(math::within_tolerance(0, 1, 0) == false, 2);

    // 100% tolerance (10000 bps)
    assert!(math::within_tolerance(100, 200, 10000) == true, 3);
}
