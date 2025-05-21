#[test_only]
module futarchy::math_tests;

use futarchy::math;
use std::u256;
use std::u128;
use std::u64;

#[test]
public fun test_mul_div_to_64() {
    // Basic cases
    assert!(math::mul_div_to_64(500, 2000, 1000) == 1000, 0);
    assert!(math::mul_div_to_64(100, 100, 100) == 100, 1);
    assert!(math::mul_div_to_64(0, 1000, 1) == 0, 2);

    // Edge cases
    assert!(math::mul_div_to_64(1, 1, 1) == 1, 3);
    assert!(math::mul_div_to_64(0, 0, 1) == 0, 4);

    // Large numbers (but not overflowing)
    assert!(math::mul_div_to_64(1000000000, 2000000000, 1000000000) == 2000000000, 5);

    // Division resulting in decimal (should truncate)
    assert!(math::mul_div_to_64(10, 10, 3) == 33, 6); // 100/3 = 33.333...
    assert!(math::mul_div_to_64(7, 7, 2) == 24, 7); // 49/2 = 24.5
}

#[test]
public fun test_mul_div_up() {
    // Basic cases
    assert!(math::mul_div_up(500, 2000, 1000) == 1000, 0);
    assert!(math::mul_div_up(100, 100, 100) == 100, 1);
    assert!(math::mul_div_up(0, 1000, 1) == 0, 2);

    // Cases requiring rounding up
    assert!(math::mul_div_up(5, 2, 3) == 4, 3); // 10/3 ≈ 3.33... -> 4
    assert!(math::mul_div_up(7, 7, 2) == 25, 4); // 49/2 = 24.5 -> 25
    assert!(math::mul_div_up(10, 10, 3) == 34, 5); // 100/3 = 33.333... -> 34

    // Edge cases
    assert!(math::mul_div_up(1, 1, 1) == 1, 6);
    assert!(math::mul_div_up(0, 0, 1) == 0, 7);

    // Cases that divide evenly (shouldn't round up)
    assert!(math::mul_div_up(5, 2, 2) == 5, 8);
    assert!(math::mul_div_up(100, 100, 10) == 1000, 9);

    // Large numbers (but not overflowing)
    assert!(math::mul_div_up(1000000000, 2000000000, 1000000000) == 2000000000, 10);
}

#[test]
#[expected_failure(abort_code = math::EDIVIDE_BY_ZERO)]
public fun test_mul_div_div_by_zero() {
    math::mul_div_to_64(100, 100, 0);
}

#[test]
#[expected_failure(abort_code = math::EDIVIDE_BY_ZERO)]
public fun test_mul_div_up_div_by_zero() {
    math::mul_div_up(100, 100, 0);
}

#[test]
#[expected_failure(abort_code = math::EOVERFLOW)]
public fun test_mul_div_overflow() {
    math::mul_div_to_64(18446744073709551615, 18446744073709551615, 1);
}

#[test]
#[expected_failure(abort_code = math::EOVERFLOW)]
public fun test_mul_div_up_overflow() {
    math::mul_div_up(18446744073709551615, 18446744073709551615, 1);
}

#[test]
public fun test_mul_div_to_128() {
    // Basic cases
    assert!(math::mul_div_to_128(500, 2000, 1000) == 1000, 0);
    assert!(math::mul_div_to_128(100, 100, 100) == 100, 1);
    assert!(math::mul_div_to_128(0, 1000, 1) == 0, 2);

    // Edge cases
    assert!(math::mul_div_to_128(1, 1, 1) == 1, 3);
    assert!(math::mul_div_to_128(0, 0, 1) == 0, 4);

    // Large numbers (including those that would overflow u64)
    assert!(math::mul_div_to_128(18446744073709551615, 2, 1) == 36893488147419103230, 5);

    // Division resulting in decimal (should truncate)
    assert!(math::mul_div_to_128(10, 10, 3) == 33, 6); // 100/3 = 33.333...
    assert!(math::mul_div_to_128(7, 7, 2) == 24, 7); // 49/2 = 24.5
}

#[test]
#[expected_failure(abort_code = math::EDIVIDE_BY_ZERO)]
public fun test_mul_div_to_128_div_by_zero() {
    math::mul_div_to_128(100, 100, 0);
}

#[test]
public fun test_saturating_add() {
    // Normal addition
    assert!(math::saturating_add(10, 20) == 30, 0);
    assert!(math::saturating_add(0, 0) == 0, 1);

    // Edge cases
    assert!(math::saturating_add(0, u128::max_value!()) == u128::max_value!(), 2);
    assert!(math::saturating_add(u128::max_value!(), 0) == u128::max_value!(), 3);

    // Saturating behavior
    assert!(math::saturating_add(u128::max_value!(), 1) == u128::max_value!(), 4);
    assert!(math::saturating_add(u128::max_value!(), u128::max_value!()) == u128::max_value!(), 5);
}

#[test]
public fun test_saturating_sub() {
    // Normal subtraction
    assert!(math::saturating_sub(30, 20) == 10, 0);
    assert!(math::saturating_sub(10, 10) == 0, 1);

    // Edge cases
    assert!(math::saturating_sub(0, 0) == 0, 2);
    assert!(math::saturating_sub(u128::max_value!(), u128::max_value!()) == 0, 3);

    // Saturating behavior
    assert!(math::saturating_sub(10, 20) == 0, 4);
    assert!(math::saturating_sub(0, 1) == 0, 5);
    assert!(math::saturating_sub(0, u128::max_value!()) == 0, 6);
}

#[test]
public fun test_safe_u128_to_u64() {
    // Valid conversions
    assert!(math::safe_u128_to_u64(0) == 0, 0);
    assert!(math::safe_u128_to_u64(1) == 1, 1);
    assert!(math::safe_u128_to_u64((u64::max_value!() as u128)) == u64::max_value!(), 2);
}

#[test]
#[expected_failure(abort_code = math::EVALUE_EXCEEDS_U64)]
public fun test_safe_u128_to_u64_overflow() {
    math::safe_u128_to_u64((u64::max_value!() as u128) + 1);
}

#[test]
public fun test_mul_div_mixed() {
    let u128_max = u128::max_value!();
    let u64_max = u64::max_value!();

    // 1. Basic case
    assert!(math::mul_div_mixed(500u128, 2000u64, 1000u128) == 1000u128, 0);

    // 2. 'a' is large, 'b' and 'c' effectively cancel
    assert!(math::mul_div_mixed(u128_max / 2, 2u64, 2u128) == u128_max / 2, 1);

    // 3. 'b' is large (u64::max_value), result fits u128
    // (10 * u64_max) / 5 = 2 * u64_max
    assert!(math::mul_div_mixed(10u128, u64_max, 5u128) == (u64_max as u128) * 2, 2);

    // 4. 'c' is very large, resulting in 0
    assert!(math::mul_div_mixed(100u128, 2u64, u128_max) == 0u128, 3);

    // 5. 'a' and 'c' are large and equal
    assert!(math::mul_div_mixed(u128_max, 1u64, u128_max) == 1u128, 4);

    // 6. 'a' is zero
    assert!(math::mul_div_mixed(0u128, 1000u64, 1u128) == 0u128, 5);

    // 7. 'b' is zero
    assert!(math::mul_div_mixed(1000u128, 0u64, 1u128) == 0u128, 6);

    // 8. Both 'a' and 'b' are zero
    assert!(math::mul_div_mixed(0u128, 0u64, 1u128) == 0u128, 7);

    // 9. Edge case: all ones
    assert!(math::mul_div_mixed(1u128, 1u64, 1u128) == 1u128, 8);

    // 10. 'a' is max u128, 'b' and 'c' are 1 (result is u128_max)
    assert!(math::mul_div_mixed(u128_max, 1u64, 1u128) == u128_max, 9);

    // 11. Truncation: (10 * 10) / 3 = 100 / 3 = 33
    assert!(math::mul_div_mixed(10u128, 10u64, 3u128) == 33u128, 10);

    // 12. Truncation: (7 * 7) / 2 = 49 / 2 = 24
    assert!(math::mul_div_mixed(7u128, 7u64, 2u128) == 24u128, 11);

    // 13. Intermediate product (a*b) would overflow u128, but u256 handles it. Final result fits u128.
    // (u128_max * 2) / 2 = u128_max
    assert!(math::mul_div_mixed(u128_max, 2u64, 2u128) == u128_max, 12);

    // 14. Another intermediate overflow case where final result fits u128.
    // a_val approx u128_max / 100. (a_val * 200) would overflow u128 if directly calculated in u128.
    // (a_val * 200) / 100 = a_val * 2, which fits u128.
    let a_val_intermediate_overflow = (u128_max / 100) + 1;
    let b_val_intermediate_overflow = 200u64;
    let c_val_intermediate_overflow = 100u128;
    let expected_res_intermediate_overflow = a_val_intermediate_overflow * 2; // This u128 * literal is fine
    assert!(math::mul_div_mixed(a_val_intermediate_overflow, b_val_intermediate_overflow, c_val_intermediate_overflow) == expected_res_intermediate_overflow, 13);

    // 15. Max value interactions: (u128_max/2 * 2) / 1.
    // u128_max is odd (2^128 - 1). u128_max / 2 (integer division) truncates to (2^127 - 1).
    // (((2^128 - 1)/2) * 2) / 1 = ((2^127 - 1) * 2) / 1 = (2^128 - 2) / 1 = u128_max - 1. This fits u128.
    assert!(math::mul_div_mixed(u128_max / 2, 2u64, 1u128) == u128_max - 1, 14);

    // 16. Result is exactly u128_max, through different numbers than test #10
    // (u128_max * 10) / 10 = u128_max
    assert!(math::mul_div_mixed(u128_max, 10u64, 10u128) == u128_max, 15);
}

#[test]
#[expected_failure(abort_code = math::EDIVIDE_BY_ZERO)]
public fun test_mul_div_mixed_div_by_zero() {
    math::mul_div_mixed(1u128, 1u64, 0u128);
}

#[test]
#[expected_failure(abort_code = math::EOVERFLOW)]
public fun test_mul_div_mixed_result_overflow() {
    let u128_max = u128::max_value!();
    math::mul_div_mixed(u128_max, 2u64, 1u128);
}

