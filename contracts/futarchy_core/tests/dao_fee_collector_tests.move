#[test_only]
module futarchy_core::dao_fee_collector_tests;

use sui::{
    test_scenario::{Self as test, Scenario, next_tx, ctx},
    clock::{Self, Clock},
    coin::{Self, Coin},
    sui::SUI,
    test_utils::assert_eq,
};
use futarchy_core::{
    dao_fee_collector,
    dao_payment_tracker::{Self, DaoPaymentTracker},
};

// Test addresses
const ADMIN: address = @0xAD;
const DAO_1: address = @0xDA01;
const DAO_2: address = @0xDA02;

// Helper: Create test scenario with clock
fun setup_test(): (Scenario, Clock) {
    let mut scenario = test::begin(ADMIN);
    let clock = clock::create_for_testing(ctx(&mut scenario));
    (scenario, clock)
}

// Helper: Create payment tracker
fun create_tracker(scenario: &mut Scenario): DaoPaymentTracker {
    dao_payment_tracker::new_for_testing(ctx(scenario))
}

// Helper: Mint test coins
fun mint_sui(amount: u64, scenario: &mut Scenario): Coin<SUI> {
    coin::mint_for_testing<SUI>(amount, ctx(scenario))
}

// === Basic Fee Collection Tests ===

#[test]
fun test_collect_fee_with_sufficient_funds() {
    let (mut scenario, clock) = setup_test();
    let mut tracker = create_tracker(&mut scenario);

    let dao_id = object::id_from_address(DAO_1);
    let fee_amount = 1000;
    let available = mint_sui(5000, &mut scenario);

    let (success, fee_coin, remaining) = dao_fee_collector::try_collect_fee(
        &mut tracker,
        dao_id,
        fee_amount,
        available,
        &clock,
        ctx(&mut scenario)
    );

    assert!(success, 0);
    assert_eq(fee_coin.value(), fee_amount);
    assert_eq(remaining.value(), 4000);
    assert_eq(dao_payment_tracker::get_debt(&tracker, dao_id), 0);

    fee_coin.burn_for_testing();
    remaining.burn_for_testing();
    dao_payment_tracker::destroy_for_testing(tracker);
    clock.destroy_for_testing();
    test::end(scenario);
}

#[test]
fun test_collect_fee_with_exact_funds() {
    let (mut scenario, clock) = setup_test();
    let mut tracker = create_tracker(&mut scenario);

    let dao_id = object::id_from_address(DAO_1);
    let fee_amount = 1000;
    let available = mint_sui(1000, &mut scenario);

    let (success, fee_coin, remaining) = dao_fee_collector::try_collect_fee(
        &mut tracker,
        dao_id,
        fee_amount,
        available,
        &clock,
        ctx(&mut scenario)
    );

    assert!(success, 0);
    assert_eq(fee_coin.value(), fee_amount);
    assert_eq(remaining.value(), 0);
    assert_eq(dao_payment_tracker::get_debt(&tracker, dao_id), 0);

    fee_coin.burn_for_testing();
    remaining.burn_for_testing();
    dao_payment_tracker::destroy_for_testing(tracker);
    clock.destroy_for_testing();
    test::end(scenario);
}

#[test]
fun test_collect_fee_with_insufficient_funds() {
    let (mut scenario, clock) = setup_test();
    let mut tracker = create_tracker(&mut scenario);

    let dao_id = object::id_from_address(DAO_1);
    let fee_amount = 1000;
    let available_amount = 600;
    let available = mint_sui(available_amount, &mut scenario);

    let (success, fee_coin, remaining) = dao_fee_collector::try_collect_fee(
        &mut tracker,
        dao_id,
        fee_amount,
        available,
        &clock,
        ctx(&mut scenario)
    );

    assert!(!success, 0);
    assert_eq(fee_coin.value(), available_amount); // Partial payment
    assert_eq(remaining.value(), 0); // No remaining funds
    assert_eq(dao_payment_tracker::get_debt(&tracker, dao_id), 400); // Debt accumulated

    fee_coin.burn_for_testing();
    remaining.burn_for_testing();
    dao_payment_tracker::destroy_for_testing(tracker);
    clock.destroy_for_testing();
    test::end(scenario);
}

#[test]
fun test_collect_fee_with_zero_funds() {
    let (mut scenario, clock) = setup_test();
    let mut tracker = create_tracker(&mut scenario);

    let dao_id = object::id_from_address(DAO_1);
    let fee_amount = 1000;
    let available = mint_sui(0, &mut scenario);

    let (success, fee_coin, remaining) = dao_fee_collector::try_collect_fee(
        &mut tracker,
        dao_id,
        fee_amount,
        available,
        &clock,
        ctx(&mut scenario)
    );

    assert!(!success, 0);
    assert_eq(fee_coin.value(), 0);
    assert_eq(remaining.value(), 0);
    assert_eq(dao_payment_tracker::get_debt(&tracker, dao_id), 1000); // Full debt

    fee_coin.burn_for_testing();
    remaining.burn_for_testing();
    dao_payment_tracker::destroy_for_testing(tracker);
    clock.destroy_for_testing();
    test::end(scenario);
}

// === Debt Accumulation Tests ===

#[test]
fun test_multiple_failed_collections_accumulate_debt() {
    let (mut scenario, clock) = setup_test();
    let mut tracker = create_tracker(&mut scenario);

    let dao_id = object::id_from_address(DAO_1);

    // First failed collection - 300 debt
    let (success1, fee1, remaining1) = dao_fee_collector::try_collect_fee(
        &mut tracker,
        dao_id,
        1000,
        mint_sui(700, &mut scenario),
        &clock,
        ctx(&mut scenario)
    );
    assert!(!success1, 0);
    assert_eq(dao_payment_tracker::get_debt(&tracker, dao_id), 300);

    // Second failed collection - 500 more debt
    let (success2, fee2, remaining2) = dao_fee_collector::try_collect_fee(
        &mut tracker,
        dao_id,
        1000,
        mint_sui(500, &mut scenario),
        &clock,
        ctx(&mut scenario)
    );
    assert!(!success2, 0);
    assert_eq(dao_payment_tracker::get_debt(&tracker, dao_id), 800); // 300 + 500

    fee1.burn_for_testing();
    remaining1.burn_for_testing();
    fee2.burn_for_testing();
    remaining2.burn_for_testing();
    dao_payment_tracker::destroy_for_testing(tracker);
    clock.destroy_for_testing();
    test::end(scenario);
}

// === Convenience Function Tests ===

#[test]
fun test_collect_fee_or_block_success() {
    let (mut scenario, clock) = setup_test();
    let mut tracker = create_tracker(&mut scenario);

    let dao_id = object::id_from_address(DAO_1);
    let (fee, remaining) = dao_fee_collector::collect_fee_or_block(
        &mut tracker,
        dao_id,
        1000,
        mint_sui(5000, &mut scenario),
        &clock,
        ctx(&mut scenario)
    );

    assert_eq(fee.value(), 1000);
    assert_eq(remaining.value(), 4000);

    fee.burn_for_testing();
    remaining.burn_for_testing();
    dao_payment_tracker::destroy_for_testing(tracker);
    clock.destroy_for_testing();
    test::end(scenario);
}

#[test]
fun test_collect_fee_or_block_failure() {
    let (mut scenario, clock) = setup_test();
    let mut tracker = create_tracker(&mut scenario);

    let dao_id = object::id_from_address(DAO_1);
    let (fee, remaining) = dao_fee_collector::collect_fee_or_block(
        &mut tracker,
        dao_id,
        1000,
        mint_sui(300, &mut scenario),
        &clock,
        ctx(&mut scenario)
    );

    assert_eq(fee.value(), 300);
    assert_eq(remaining.value(), 0);
    assert_eq(dao_payment_tracker::get_debt(&tracker, dao_id), 700);

    fee.burn_for_testing();
    remaining.burn_for_testing();
    dao_payment_tracker::destroy_for_testing(tracker);
    clock.destroy_for_testing();
    test::end(scenario);
}

// === Can Afford Fee Tests ===

#[test]
fun test_can_afford_fee_true() {
    assert!(dao_fee_collector::can_afford_fee(5000, 1000), 0);
    assert!(dao_fee_collector::can_afford_fee(1000, 1000), 0);
    assert!(dao_fee_collector::can_afford_fee(1001, 1000), 0);
}

#[test]
fun test_can_afford_fee_false() {
    assert!(!dao_fee_collector::can_afford_fee(999, 1000), 0);
    assert!(!dao_fee_collector::can_afford_fee(0, 1000), 0);
    assert!(!dao_fee_collector::can_afford_fee(500, 1000), 0);
}

// === Debt Handling Function Tests ===

#[test]
fun test_collect_with_debt_handling_full_payment() {
    let (mut scenario, clock) = setup_test();
    let mut tracker = create_tracker(&mut scenario);

    let dao_id = object::id_from_address(DAO_1);
    let (fee, change) = dao_fee_collector::collect_fee_with_debt_handling(
        &mut tracker,
        dao_id,
        1000,
        mint_sui(2000, &mut scenario),
        &clock,
        ctx(&mut scenario)
    );

    assert_eq(fee.value(), 1000);
    assert_eq(change.value(), 1000);
    assert_eq(dao_payment_tracker::get_debt(&tracker, dao_id), 0);

    fee.burn_for_testing();
    change.burn_for_testing();
    dao_payment_tracker::destroy_for_testing(tracker);
    clock.destroy_for_testing();
    test::end(scenario);
}

#[test]
fun test_collect_with_debt_handling_partial_payment() {
    let (mut scenario, clock) = setup_test();
    let mut tracker = create_tracker(&mut scenario);

    let dao_id = object::id_from_address(DAO_1);
    let (fee, change) = dao_fee_collector::collect_fee_with_debt_handling(
        &mut tracker,
        dao_id,
        1000,
        mint_sui(600, &mut scenario),
        &clock,
        ctx(&mut scenario)
    );

    assert_eq(fee.value(), 600);
    assert_eq(change.value(), 0);
    assert_eq(dao_payment_tracker::get_debt(&tracker, dao_id), 400);

    fee.burn_for_testing();
    change.burn_for_testing();
    dao_payment_tracker::destroy_for_testing(tracker);
    clock.destroy_for_testing();
    test::end(scenario);
}

// === Edge Cases ===

#[test]
fun test_zero_fee_collection() {
    let (mut scenario, clock) = setup_test();
    let mut tracker = create_tracker(&mut scenario);

    let dao_id = object::id_from_address(DAO_1);
    let (success, fee, remaining) = dao_fee_collector::try_collect_fee(
        &mut tracker,
        dao_id,
        0,
        mint_sui(1000, &mut scenario),
        &clock,
        ctx(&mut scenario)
    );

    assert!(success, 0);
    assert_eq(fee.value(), 0);
    assert_eq(remaining.value(), 1000);

    fee.burn_for_testing();
    remaining.burn_for_testing();
    dao_payment_tracker::destroy_for_testing(tracker);
    clock.destroy_for_testing();
    test::end(scenario);
}

#[test]
fun test_multiple_daos_independent_debt() {
    let (mut scenario, clock) = setup_test();
    let mut tracker = create_tracker(&mut scenario);

    let dao1_id = object::id_from_address(DAO_1);
    let dao2_id = object::id_from_address(DAO_2);

    // DAO 1 fails to pay
    let (success1, fee1, remaining1) = dao_fee_collector::try_collect_fee(
        &mut tracker,
        dao1_id,
        1000,
        mint_sui(400, &mut scenario),
        &clock,
        ctx(&mut scenario)
    );
    assert!(!success1, 0);
    assert_eq(dao_payment_tracker::get_debt(&tracker, dao1_id), 600);

    // DAO 2 pays successfully
    let (success2, fee2, remaining2) = dao_fee_collector::try_collect_fee(
        &mut tracker,
        dao2_id,
        1000,
        mint_sui(2000, &mut scenario),
        &clock,
        ctx(&mut scenario)
    );
    assert!(success2, 0);
    assert_eq(dao_payment_tracker::get_debt(&tracker, dao2_id), 0);

    // Verify debts are independent
    assert_eq(dao_payment_tracker::get_debt(&tracker, dao1_id), 600);
    assert_eq(dao_payment_tracker::get_debt(&tracker, dao2_id), 0);

    fee1.burn_for_testing();
    remaining1.burn_for_testing();
    fee2.burn_for_testing();
    remaining2.burn_for_testing();
    dao_payment_tracker::destroy_for_testing(tracker);
    clock.destroy_for_testing();
    test::end(scenario);
}

// === Large Value Tests ===

#[test]
fun test_large_fee_amounts() {
    let (mut scenario, clock) = setup_test();
    let mut tracker = create_tracker(&mut scenario);

    let dao_id = object::id_from_address(DAO_1);
    let large_fee = 1_000_000_000_000; // 1 trillion
    let large_funds = 5_000_000_000_000; // 5 trillion

    let (success, fee, remaining) = dao_fee_collector::try_collect_fee(
        &mut tracker,
        dao_id,
        large_fee,
        mint_sui(large_funds, &mut scenario),
        &clock,
        ctx(&mut scenario)
    );

    assert!(success, 0);
    assert_eq(fee.value(), large_fee);
    assert_eq(remaining.value(), large_funds - large_fee);

    fee.burn_for_testing();
    remaining.burn_for_testing();
    dao_payment_tracker::destroy_for_testing(tracker);
    clock.destroy_for_testing();
    test::end(scenario);
}

#[test]
fun test_sequential_collections_same_dao() {
    let (mut scenario, clock) = setup_test();
    let mut tracker = create_tracker(&mut scenario);

    let dao_id = object::id_from_address(DAO_1);

    // First collection - success
    let (s1, f1, r1) = dao_fee_collector::try_collect_fee(
        &mut tracker,
        dao_id,
        1000,
        mint_sui(5000, &mut scenario),
        &clock,
        ctx(&mut scenario)
    );
    assert!(s1, 0);
    assert_eq(dao_payment_tracker::get_debt(&tracker, dao_id), 0);

    // Second collection - success with previous remaining
    let (s2, f2, r2) = dao_fee_collector::try_collect_fee(
        &mut tracker,
        dao_id,
        1000,
        r1, // Use remaining from first collection
        &clock,
        ctx(&mut scenario)
    );
    assert!(s2, 0);
    assert_eq(dao_payment_tracker::get_debt(&tracker, dao_id), 0);

    // Third collection - fail with insufficient remaining
    let (s3, f3, r3) = dao_fee_collector::try_collect_fee(
        &mut tracker,
        dao_id,
        5000,
        r2, // Use remaining from second collection
        &clock,
        ctx(&mut scenario)
    );
    assert!(!s3, 0);
    assert!(dao_payment_tracker::get_debt(&tracker, dao_id) > 0, 0);

    f1.burn_for_testing();
    f2.burn_for_testing();
    f3.burn_for_testing();
    r3.burn_for_testing();
    dao_payment_tracker::destroy_for_testing(tracker);
    clock.destroy_for_testing();
    test::end(scenario);
}
