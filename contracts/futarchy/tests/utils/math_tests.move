#[test_only]
module futarchy::math_tests;

use futarchy::math;
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
