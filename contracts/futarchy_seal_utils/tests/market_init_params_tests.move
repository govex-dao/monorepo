#[test_only]
module futarchy_seal_utils::market_init_params_tests;

use futarchy_seal_utils::market_init_params;
use std::vector;

// === Constructor Tests ===

#[test]
fun test_new_none() {
    let params = market_init_params::new_none();

    assert!(market_init_params::mode(&params) == market_init_params::mode_none(), 0);
    assert!(market_init_params::is_none(&params), 1);
    assert!(!market_init_params::is_raise(&params), 2);
    assert!(!market_init_params::is_buyback(&params), 3);
}

#[test]
fun test_new_conditional_raise_basic() {
    let params = market_init_params::new_conditional_raise(
        1,      // target_outcome = YES
        1000,   // mint_amount
        900,    // min_stable_out
    );

    assert!(market_init_params::mode(&params) == market_init_params::mode_conditional_raise(), 0);
    assert!(market_init_params::is_raise(&params), 1);
    assert!(!market_init_params::is_none(&params), 2);
    assert!(!market_init_params::is_buyback(&params), 3);

    // Verify raise params are populated
    let raise_opt = market_init_params::get_raise_params(&params);
    assert!(raise_opt.is_some(), 4);

    let raise = raise_opt.destroy_some();
    assert!(market_init_params::raise_target_outcome(&raise) == 1, 5);
    assert!(market_init_params::raise_mint_amount(&raise) == 1000, 6);
    assert!(market_init_params::raise_min_stable_out(&raise) == 900, 7);

    // Verify buyback params are empty
    let buyback_opt = market_init_params::get_buyback_params(&params);
    assert!(buyback_opt.is_none(), 8);
}

#[test]
fun test_new_conditional_raise_outcome_zero() {
    let params = market_init_params::new_conditional_raise(
        0,      // target_outcome = NO
        5000,
        4500,
    );

    let raise_opt = market_init_params::get_raise_params(&params);
    let raise = raise_opt.destroy_some();
    assert!(market_init_params::raise_target_outcome(&raise) == 0, 0);
}

#[test]
fun test_new_conditional_raise_large_amounts() {
    let params = market_init_params::new_conditional_raise(
        1,
        18446744073709551615, // u64::MAX
        18446744073709551615,
    );

    let raise_opt = market_init_params::get_raise_params(&params);
    let raise = raise_opt.destroy_some();
    assert!(market_init_params::raise_mint_amount(&raise) == 18446744073709551615, 0);
    assert!(market_init_params::raise_min_stable_out(&raise) == 18446744073709551615, 1);
}

#[test]
#[expected_failure(abort_code = market_init_params::EZeroAmount)]
fun test_new_conditional_raise_zero_mint() {
    let _params = market_init_params::new_conditional_raise(
        1,
        0,      // ← Zero mint amount should fail
        900,
    );
}

#[test]
#[expected_failure(abort_code = market_init_params::EZeroAmount)]
fun test_new_conditional_raise_zero_min_stable() {
    let _params = market_init_params::new_conditional_raise(
        1,
        1000,
        0,      // ← Zero min_stable_out should fail
    );
}

#[test]
fun test_new_conditional_buyback_single_outcome() {
    let mut outcome_amounts = vector::empty<u64>();
    outcome_amounts.push_back(500);

    let mut min_asset_outs = vector::empty<u64>();
    min_asset_outs.push_back(450);

    let params = market_init_params::new_conditional_buyback(
        outcome_amounts,
        min_asset_outs,
    );

    assert!(market_init_params::mode(&params) == market_init_params::mode_conditional_buyback(), 0);
    assert!(market_init_params::is_buyback(&params), 1);
    assert!(!market_init_params::is_none(&params), 2);
    assert!(!market_init_params::is_raise(&params), 3);

    // Verify buyback params
    let buyback_opt = market_init_params::get_buyback_params(&params);
    assert!(buyback_opt.is_some(), 4);

    let buyback = buyback_opt.destroy_some();
    let amounts = market_init_params::buyback_outcome_amounts(&buyback);
    let mins = market_init_params::buyback_min_asset_outs(&buyback);

    assert!(vector::length(amounts) == 1, 5);
    assert!(*vector::borrow(amounts, 0) == 500, 6);
    assert!(vector::length(mins) == 1, 7);
    assert!(*vector::borrow(mins, 0) == 450, 8);

    // Verify total
    assert!(market_init_params::buyback_total_withdraw_amount(&buyback) == 500, 9);

    // Verify raise params are empty
    let raise_opt = market_init_params::get_raise_params(&params);
    assert!(raise_opt.is_none(), 10);
}

#[test]
fun test_new_conditional_buyback_multiple_outcomes() {
    let mut outcome_amounts = vector::empty<u64>();
    outcome_amounts.push_back(300); // Outcome 0
    outcome_amounts.push_back(500); // Outcome 1
    outcome_amounts.push_back(200); // Outcome 2

    let mut min_asset_outs = vector::empty<u64>();
    min_asset_outs.push_back(270);
    min_asset_outs.push_back(450);
    min_asset_outs.push_back(180);

    let params = market_init_params::new_conditional_buyback(
        outcome_amounts,
        min_asset_outs,
    );

    let buyback_opt = market_init_params::get_buyback_params(&params);
    let buyback = buyback_opt.destroy_some();

    let amounts = market_init_params::buyback_outcome_amounts(&buyback);
    assert!(vector::length(amounts) == 3, 0);
    assert!(*vector::borrow(amounts, 0) == 300, 1);
    assert!(*vector::borrow(amounts, 1) == 500, 2);
    assert!(*vector::borrow(amounts, 2) == 200, 3);

    let mins = market_init_params::buyback_min_asset_outs(&buyback);
    assert!(vector::length(mins) == 3, 4);
    assert!(*vector::borrow(mins, 0) == 270, 5);
    assert!(*vector::borrow(mins, 1) == 450, 6);
    assert!(*vector::borrow(mins, 2) == 180, 7);

    // Verify total
    assert!(market_init_params::buyback_total_withdraw_amount(&buyback) == 1000, 8);
}

#[test]
fun test_new_conditional_buyback_with_zero_outcomes() {
    // Some outcomes can be zero, as long as at least one is non-zero
    let mut outcome_amounts = vector::empty<u64>();
    outcome_amounts.push_back(0);   // Outcome 0 - no buyback
    outcome_amounts.push_back(500); // Outcome 1 - buyback
    outcome_amounts.push_back(0);   // Outcome 2 - no buyback

    let mut min_asset_outs = vector::empty<u64>();
    min_asset_outs.push_back(0);
    min_asset_outs.push_back(450);
    min_asset_outs.push_back(0);

    let params = market_init_params::new_conditional_buyback(
        outcome_amounts,
        min_asset_outs,
    );

    let buyback_opt = market_init_params::get_buyback_params(&params);
    let buyback = buyback_opt.destroy_some();

    // Total should only count non-zero outcomes
    assert!(market_init_params::buyback_total_withdraw_amount(&buyback) == 500, 0);
}

#[test]
#[expected_failure(abort_code = market_init_params::EZeroAmount)]
fun test_new_conditional_buyback_empty_vectors() {
    let outcome_amounts = vector::empty<u64>();
    let min_asset_outs = vector::empty<u64>();

    let _params = market_init_params::new_conditional_buyback(
        outcome_amounts,
        min_asset_outs,
    );
}

#[test]
#[expected_failure(abort_code = market_init_params::EAmountMismatch)]
fun test_new_conditional_buyback_length_mismatch() {
    let mut outcome_amounts = vector::empty<u64>();
    outcome_amounts.push_back(500);
    outcome_amounts.push_back(300);

    let mut min_asset_outs = vector::empty<u64>();
    min_asset_outs.push_back(450);
    // Missing second element - length mismatch

    let _params = market_init_params::new_conditional_buyback(
        outcome_amounts,
        min_asset_outs,
    );
}

#[test]
#[expected_failure(abort_code = market_init_params::EZeroAmount)]
fun test_new_conditional_buyback_all_zeros() {
    // All outcomes with zero buyback should fail
    let mut outcome_amounts = vector::empty<u64>();
    outcome_amounts.push_back(0);
    outcome_amounts.push_back(0);

    let mut min_asset_outs = vector::empty<u64>();
    min_asset_outs.push_back(0);
    min_asset_outs.push_back(0);

    let _params = market_init_params::new_conditional_buyback(
        outcome_amounts,
        min_asset_outs,
    );
}

// === Getter Tests ===

#[test]
fun test_mode_getters() {
    let none_params = market_init_params::new_none();
    assert!(market_init_params::mode(&none_params) == 0, 0);

    let raise_params = market_init_params::new_conditional_raise(1, 1000, 900);
    assert!(market_init_params::mode(&raise_params) == 1, 1);

    let mut amounts = vector::empty<u64>();
    amounts.push_back(500);
    let mut mins = vector::empty<u64>();
    mins.push_back(450);
    let buyback_params = market_init_params::new_conditional_buyback(amounts, mins);
    assert!(market_init_params::mode(&buyback_params) == 2, 2);
}

#[test]
fun test_is_none_checks() {
    let none = market_init_params::new_none();
    assert!(market_init_params::is_none(&none), 0);

    let raise = market_init_params::new_conditional_raise(1, 1000, 900);
    assert!(!market_init_params::is_none(&raise), 1);

    let mut amounts = vector::empty<u64>();
    amounts.push_back(500);
    let mut mins = vector::empty<u64>();
    mins.push_back(450);
    let buyback = market_init_params::new_conditional_buyback(amounts, mins);
    assert!(!market_init_params::is_none(&buyback), 2);
}

#[test]
fun test_is_raise_checks() {
    let none = market_init_params::new_none();
    assert!(!market_init_params::is_raise(&none), 0);

    let raise = market_init_params::new_conditional_raise(1, 1000, 900);
    assert!(market_init_params::is_raise(&raise), 1);

    let mut amounts = vector::empty<u64>();
    amounts.push_back(500);
    let mut mins = vector::empty<u64>();
    mins.push_back(450);
    let buyback = market_init_params::new_conditional_buyback(amounts, mins);
    assert!(!market_init_params::is_raise(&buyback), 2);
}

#[test]
fun test_is_buyback_checks() {
    let none = market_init_params::new_none();
    assert!(!market_init_params::is_buyback(&none), 0);

    let raise = market_init_params::new_conditional_raise(1, 1000, 900);
    assert!(!market_init_params::is_buyback(&raise), 1);

    let mut amounts = vector::empty<u64>();
    amounts.push_back(500);
    let mut mins = vector::empty<u64>();
    mins.push_back(450);
    let buyback = market_init_params::new_conditional_buyback(amounts, mins);
    assert!(market_init_params::is_buyback(&buyback), 2);
}

#[test]
fun test_get_raise_params_none_when_not_raise() {
    let none = market_init_params::new_none();
    let raise_opt = market_init_params::get_raise_params(&none);
    assert!(raise_opt.is_none(), 0);

    let mut amounts = vector::empty<u64>();
    amounts.push_back(500);
    let mut mins = vector::empty<u64>();
    mins.push_back(450);
    let buyback = market_init_params::new_conditional_buyback(amounts, mins);
    let raise_opt2 = market_init_params::get_raise_params(&buyback);
    assert!(raise_opt2.is_none(), 1);
}

#[test]
fun test_get_buyback_params_none_when_not_buyback() {
    let none = market_init_params::new_none();
    let buyback_opt = market_init_params::get_buyback_params(&none);
    assert!(buyback_opt.is_none(), 0);

    let raise = market_init_params::new_conditional_raise(1, 1000, 900);
    let buyback_opt2 = market_init_params::get_buyback_params(&raise);
    assert!(buyback_opt2.is_none(), 1);
}

#[test]
fun test_buyback_total_withdraw_amount_calculation() {
    let mut outcome_amounts = vector::empty<u64>();
    outcome_amounts.push_back(100);
    outcome_amounts.push_back(200);
    outcome_amounts.push_back(300);
    outcome_amounts.push_back(400);

    let mut min_asset_outs = vector::empty<u64>();
    min_asset_outs.push_back(90);
    min_asset_outs.push_back(180);
    min_asset_outs.push_back(270);
    min_asset_outs.push_back(360);

    let params = market_init_params::new_conditional_buyback(
        outcome_amounts,
        min_asset_outs,
    );

    let buyback_opt = market_init_params::get_buyback_params(&params);
    let buyback = buyback_opt.destroy_some();

    // 100 + 200 + 300 + 400 = 1000
    assert!(market_init_params::buyback_total_withdraw_amount(&buyback) == 1000, 0);
}

#[test]
fun test_buyback_total_with_zeros() {
    let mut outcome_amounts = vector::empty<u64>();
    outcome_amounts.push_back(0);
    outcome_amounts.push_back(500);
    outcome_amounts.push_back(0);
    outcome_amounts.push_back(300);
    outcome_amounts.push_back(0);

    let mut min_asset_outs = vector::empty<u64>();
    min_asset_outs.push_back(0);
    min_asset_outs.push_back(450);
    min_asset_outs.push_back(0);
    min_asset_outs.push_back(270);
    min_asset_outs.push_back(0);

    let params = market_init_params::new_conditional_buyback(
        outcome_amounts,
        min_asset_outs,
    );

    let buyback_opt = market_init_params::get_buyback_params(&params);
    let buyback = buyback_opt.destroy_some();

    // 0 + 500 + 0 + 300 + 0 = 800
    assert!(market_init_params::buyback_total_withdraw_amount(&buyback) == 800, 0);
}

// === Copy Ability Tests ===

#[test]
fun test_market_init_params_copy() {
    let params1 = market_init_params::new_conditional_raise(1, 1000, 900);
    let params2 = params1; // Uses copy

    assert!(market_init_params::mode(&params1) == market_init_params::mode(&params2), 0);
    assert!(market_init_params::is_raise(&params1) == market_init_params::is_raise(&params2), 1);
}

#[test]
fun test_conditional_raise_params_copy() {
    let params = market_init_params::new_conditional_raise(1, 1000, 900);
    let raise_opt = market_init_params::get_raise_params(&params);
    let raise1 = raise_opt.destroy_some();

    // Get again (params has copy)
    let raise_opt2 = market_init_params::get_raise_params(&params);
    let raise2 = raise_opt2.destroy_some();

    assert!(market_init_params::raise_target_outcome(&raise1) == market_init_params::raise_target_outcome(&raise2), 0);
    assert!(market_init_params::raise_mint_amount(&raise1) == market_init_params::raise_mint_amount(&raise2), 1);
}

// === Edge Cases ===

#[test]
fun test_buyback_single_large_amount() {
    let mut outcome_amounts = vector::empty<u64>();
    outcome_amounts.push_back(18446744073709551615); // u64::MAX

    let mut min_asset_outs = vector::empty<u64>();
    min_asset_outs.push_back(1);

    let params = market_init_params::new_conditional_buyback(
        outcome_amounts,
        min_asset_outs,
    );

    let buyback_opt = market_init_params::get_buyback_params(&params);
    let buyback = buyback_opt.destroy_some();

    assert!(market_init_params::buyback_total_withdraw_amount(&buyback) == 18446744073709551615, 0);
}

#[test]
fun test_mode_constants() {
    assert!(market_init_params::mode_none() == 0, 0);
    assert!(market_init_params::mode_conditional_raise() == 1, 1);
    assert!(market_init_params::mode_conditional_buyback() == 2, 2);
}

// === Integration Test ===

#[test]
fun test_full_workflow_none() {
    let params = market_init_params::new_none();

    assert!(market_init_params::is_none(&params), 0);
    assert!(market_init_params::get_raise_params(&params).is_none(), 1);
    assert!(market_init_params::get_buyback_params(&params).is_none(), 2);
}

#[test]
fun test_full_workflow_raise() {
    let params = market_init_params::new_conditional_raise(1, 5000, 4500);

    assert!(market_init_params::is_raise(&params), 0);
    assert!(market_init_params::mode(&params) == 1, 1);

    let raise_opt = market_init_params::get_raise_params(&params);
    assert!(raise_opt.is_some(), 2);

    let raise = raise_opt.destroy_some();
    assert!(market_init_params::raise_target_outcome(&raise) == 1, 3);
    assert!(market_init_params::raise_mint_amount(&raise) == 5000, 4);
    assert!(market_init_params::raise_min_stable_out(&raise) == 4500, 5);

    let buyback_opt = market_init_params::get_buyback_params(&params);
    assert!(buyback_opt.is_none(), 6);
}

#[test]
fun test_full_workflow_buyback() {
    let mut outcome_amounts = vector::empty<u64>();
    outcome_amounts.push_back(1000);
    outcome_amounts.push_back(2000);

    let mut min_asset_outs = vector::empty<u64>();
    min_asset_outs.push_back(900);
    min_asset_outs.push_back(1800);

    let params = market_init_params::new_conditional_buyback(
        outcome_amounts,
        min_asset_outs,
    );

    assert!(market_init_params::is_buyback(&params), 0);
    assert!(market_init_params::mode(&params) == 2, 1);

    let buyback_opt = market_init_params::get_buyback_params(&params);
    assert!(buyback_opt.is_some(), 2);

    let buyback = buyback_opt.destroy_some();

    let amounts = market_init_params::buyback_outcome_amounts(&buyback);
    assert!(vector::length(amounts) == 2, 3);
    assert!(*vector::borrow(amounts, 0) == 1000, 4);
    assert!(*vector::borrow(amounts, 1) == 2000, 5);

    let mins = market_init_params::buyback_min_asset_outs(&buyback);
    assert!(vector::length(mins) == 2, 6);
    assert!(*vector::borrow(mins, 0) == 900, 7);
    assert!(*vector::borrow(mins, 1) == 1800, 8);

    assert!(market_init_params::buyback_total_withdraw_amount(&buyback) == 3000, 9);

    let raise_opt = market_init_params::get_raise_params(&params);
    assert!(raise_opt.is_none(), 10);
}
