#[test_only]
module futarchy::dao_internal_tests;

use futarchy::dao;
use futarchy::shared_constants;
use std::debug;

/// Helper struct to set up test parameters
public struct TestParams has drop {
    percentage: u128,
    stable_amount: u64,
    asset_amount: u64,
    stable_decimals: u8,
    asset_decimals: u8
}

/// Create default test parameters
fun default_params(): TestParams {
    TestParams {
        percentage: 50,            // 5%
        stable_amount: 1000000,    // 1M stable coins
        asset_amount: 100000,      // 100K asset coins
        stable_decimals: 6,
        asset_decimals: 6
    }
}

/// Modify a parameter and return the test params
fun with_percentage(mut params: TestParams, percentage: u128): TestParams {
    params.percentage = percentage;
    params
}

fun with_stable_amount(mut params: TestParams, amount: u64): TestParams {
    params.stable_amount = amount;
    params
}

fun with_asset_amount(mut params: TestParams, amount: u64): TestParams {
    params.asset_amount = amount;
    params
}

fun with_stable_decimals(mut params: TestParams, decimals: u8): TestParams {
    params.stable_decimals = decimals;
    params
}

fun with_asset_decimals(mut params: TestParams, decimals: u8): TestParams {
    params.asset_decimals = decimals;
    params
}

/// Calculate expected result based on production formula and basis points
fun expected_result(params: &TestParams): u64 {
    let basis_points = shared_constants::amm_basis_points() as u128;
    let numerator = params.percentage * (params.stable_amount as u128) * basis_points * 10u128.pow(params.stable_decimals);
    let divisor = (params.asset_amount as u128) * 10u128.pow(params.asset_decimals) * 1000u128;
    (numerator / divisor) as u64
}

#[test]
/// Test basic calculation with equal decimals
fun test_equal_decimals() {
    let params = default_params();
    let result = dao::calculate_amm_twap_step_max(
        params.percentage,
        params.stable_amount,
        params.asset_amount,
        params.stable_decimals,
        params.asset_decimals
    );
    
    let expected = expected_result(&params);
    debug::print(&result);
    debug::print(&expected);
    assert!(result == expected, 0);
}

#[test]
/// Test with different decimals
fun test_different_decimals() {
    let params = with_stable_decimals(default_params(), 8);
    let result = dao::calculate_amm_twap_step_max(
        params.percentage,
        params.stable_amount,
        params.asset_amount,
        params.stable_decimals,
        params.asset_decimals
    );
    
    let expected = expected_result(&params);
    debug::print(&result);
    debug::print(&expected);
    assert!(result == expected, 0);
}

#[test]
/// Test with maximum decimal difference
fun test_max_decimal_diff() {
    let params = with_stable_decimals(default_params(), 15);
    let result = dao::calculate_amm_twap_step_max(
        params.percentage,
        params.stable_amount,
        params.asset_amount,
        params.stable_decimals,
        params.asset_decimals
    );
    
    assert!(params.stable_decimals - params.asset_decimals == 9, 0);
    let expected = expected_result(&params);
    debug::print(&result);
    debug::print(&expected);
    assert!(result == expected, 0);
    
}

#[test]
/// Test with small percentage
fun test_small_percentage() {
    let params = with_percentage(
        with_asset_amount(default_params(), 1000), 
        1
    );
    
    let result = dao::calculate_amm_twap_step_max(
        params.percentage,
        params.stable_amount,
        params.asset_amount,
        params.stable_decimals,
        params.asset_decimals
    );
    
    let expected = expected_result(&params);
    debug::print(&result);
    debug::print(&expected);
    assert!(result == expected, 0);
}

#[test]
/// Test with large values
fun test_large_values() {
    let params = with_percentage(
        with_stable_amount(
            with_asset_amount(
                with_stable_decimals(default_params(), 9),
                1000000000
            ),
            10000000000
        ),
        500
    );
    
    let result = dao::calculate_amm_twap_step_max(
        params.percentage,
        params.stable_amount,
        params.asset_amount,
        params.stable_decimals,
        params.asset_decimals
    );
    
    let expected = expected_result(&params);
    debug::print(&result);
    debug::print(&expected);
    assert!(result > 0, 0);
    assert!(result == expected, 0);
}

#[test]
/// Test with reversed decimal order
fun test_reverse_decimal_order() {
    let params = with_asset_decimals(default_params(), 9);
    let result = dao::calculate_amm_twap_step_max(
        params.percentage,
        params.stable_amount,
        params.asset_amount,
        params.stable_decimals,
        params.asset_decimals
    );
    
    let expected = expected_result(&params);
    debug::print(&result);
    debug::print(&expected);
    assert!(result == expected, 0);
}

#[test]
#[expected_failure(abort_code = dao::EINVALID_DECIMALS_DIFF)]
/// Test that exceeding the decimal difference limit fails
fun test_decimal_diff_too_large() {
    let params = with_stable_decimals(default_params(), 16);
    dao::calculate_amm_twap_step_max(
        params.percentage,
        params.stable_amount,
        params.asset_amount,
        params.stable_decimals,
        params.asset_decimals
    );
}

#[test]
#[expected_failure(abort_code = dao::E_DECIMALS_TOO_LARGE)]
/// Test that exceeding the max decimals fails
fun test_decimals_too_large() {
    let params = with_stable_decimals(default_params(), 22); // Exceeds MAX_DECIMALS
    dao::calculate_amm_twap_step_max(
        params.percentage,
        params.stable_amount,
        params.asset_amount,
        params.stable_decimals,
        params.asset_decimals
    );
}

#[test]
#[expected_failure(abort_code = dao::EINVALID_TWAP_MAX_STEP)]
/// Test that a result less than 1 fails
fun test_result_too_small() {
    let params = with_stable_amount(
        with_asset_amount(
            with_asset_decimals(default_params(), 9),
            100000000
        ),
        1
    );
    
    dao::calculate_amm_twap_step_max(
        params.percentage,
        params.stable_amount,
        params.asset_amount,
        params.stable_decimals,
        params.asset_decimals
    );
}