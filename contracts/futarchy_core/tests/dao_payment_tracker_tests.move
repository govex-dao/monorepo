#[test_only]
module futarchy_core::dao_payment_tracker_tests;

// === Imports ===

use sui::{
    test_utils::destroy,
    test_scenario::{Self as ts, Scenario},
    coin::{Self, Coin},
    sui::SUI,
};
use futarchy_core::dao_payment_tracker::{Self, DaoPaymentTracker, AdminCap};

// === Constants ===

const OWNER: address = @0xCAFE;
const PAYER: address = @0xBEEF;

// === Helpers ===

fun start(): (Scenario, DaoPaymentTracker, AdminCap) {
    let mut scenario = ts::begin(OWNER);
    let tracker = dao_payment_tracker::new_for_testing(scenario.ctx());
    let admin_cap = dao_payment_tracker::create_admin_cap(scenario.ctx());
    (scenario, tracker, admin_cap)
}

fun end(scenario: Scenario, tracker: DaoPaymentTracker, admin_cap: AdminCap) {
    destroy(admin_cap);
    dao_payment_tracker::destroy_for_testing(tracker);
    ts::end(scenario);
}

fun create_test_coin(amount: u64, ctx: &mut TxContext): Coin<SUI> {
    coin::mint_for_testing<SUI>(amount, ctx)
}

// === Tests ===

#[test]
fun test_new_tracker() {
    let (scenario, tracker, admin_cap) = start();

    let dao_id = object::id_from_address(@0xDA0);

    // Verify initial state
    assert!(!dao_payment_tracker::is_dao_blocked(&tracker, dao_id), 0);
    assert!(dao_payment_tracker::get_dao_debt(&tracker, dao_id) == 0, 1);
    assert!(dao_payment_tracker::get_protocol_revenue(&tracker) == 0, 2);

    end(scenario, tracker, admin_cap);
}

#[test]
fun test_accumulate_debt() {
    let (scenario, mut tracker, admin_cap) = start();

    let dao_id = object::id_from_address(@0xDA0);

    // Accumulate debt
    dao_payment_tracker::accumulate_debt(&mut tracker, dao_id, 1000);

    // Verify debt accumulated
    assert!(dao_payment_tracker::is_dao_blocked(&tracker, dao_id), 0);
    assert!(dao_payment_tracker::get_dao_debt(&tracker, dao_id) == 1000, 1);

    end(scenario, tracker, admin_cap);
}

#[test]
fun test_accumulate_debt_multiple_times() {
    let (scenario, mut tracker, admin_cap) = start();

    let dao_id = object::id_from_address(@0xDA0);

    // Accumulate debt multiple times
    dao_payment_tracker::accumulate_debt(&mut tracker, dao_id, 500);
    dao_payment_tracker::accumulate_debt(&mut tracker, dao_id, 300);
    dao_payment_tracker::accumulate_debt(&mut tracker, dao_id, 200);

    // Verify total debt
    assert!(dao_payment_tracker::get_dao_debt(&tracker, dao_id) == 1000, 0);

    end(scenario, tracker, admin_cap);
}

#[test]
fun test_pay_dao_debt_full() {
    let (mut scenario, mut tracker, admin_cap) = start();

    let dao_id = object::id_from_address(@0xDA0);

    // Accumulate debt
    dao_payment_tracker::accumulate_debt(&mut tracker, dao_id, 1000);

    // Pay full debt
    let payment = create_test_coin(1000, scenario.ctx());
    let change = dao_payment_tracker::pay_dao_debt(&mut tracker, dao_id, payment, scenario.ctx());

    // Verify debt cleared
    assert!(!dao_payment_tracker::is_dao_blocked(&tracker, dao_id), 0);
    assert!(dao_payment_tracker::get_dao_debt(&tracker, dao_id) == 0, 1);
    assert!(dao_payment_tracker::get_protocol_revenue(&tracker) == 1000, 2);
    assert!(change.value() == 0, 3);

    destroy(change);
    end(scenario, tracker, admin_cap);
}

#[test]
fun test_pay_dao_debt_with_change() {
    let (mut scenario, mut tracker, admin_cap) = start();

    let dao_id = object::id_from_address(@0xDA0);

    // Accumulate debt of 1000
    dao_payment_tracker::accumulate_debt(&mut tracker, dao_id, 1000);

    // Pay 1500 (overpayment)
    let payment = create_test_coin(1500, scenario.ctx());
    let change = dao_payment_tracker::pay_dao_debt(&mut tracker, dao_id, payment, scenario.ctx());

    // Verify debt cleared and change returned
    assert!(!dao_payment_tracker::is_dao_blocked(&tracker, dao_id), 0);
    assert!(dao_payment_tracker::get_dao_debt(&tracker, dao_id) == 0, 1);
    assert!(dao_payment_tracker::get_protocol_revenue(&tracker) == 1000, 2);
    assert!(change.value() == 500, 3); // 500 change

    destroy(change);
    end(scenario, tracker, admin_cap);
}

#[test]
fun test_pay_dao_debt_partial() {
    let (mut scenario, mut tracker, admin_cap) = start();

    let dao_id = object::id_from_address(@0xDA0);

    // Accumulate debt of 1000
    dao_payment_tracker::accumulate_debt(&mut tracker, dao_id, 1000);

    // Pay partial amount (500)
    let payment = create_test_coin(500, scenario.ctx());
    let change = dao_payment_tracker::pay_dao_debt(&mut tracker, dao_id, payment, scenario.ctx());

    // Verify debt reduced but not cleared
    assert!(dao_payment_tracker::is_dao_blocked(&tracker, dao_id), 0); // Still blocked
    assert!(dao_payment_tracker::get_dao_debt(&tracker, dao_id) == 500, 1); // 500 remaining
    assert!(dao_payment_tracker::get_protocol_revenue(&tracker) == 500, 2);
    assert!(change.value() == 0, 3); // No change

    destroy(change);
    end(scenario, tracker, admin_cap);
}

#[test]
fun test_pay_dao_debt_multiple_payments() {
    let (mut scenario, mut tracker, admin_cap) = start();

    let dao_id = object::id_from_address(@0xDA0);

    // Accumulate debt of 1000
    dao_payment_tracker::accumulate_debt(&mut tracker, dao_id, 1000);

    // First partial payment (300)
    let payment1 = create_test_coin(300, scenario.ctx());
    let change1 = dao_payment_tracker::pay_dao_debt(&mut tracker, dao_id, payment1, scenario.ctx());
    assert!(change1.value() == 0, 0);
    assert!(dao_payment_tracker::get_dao_debt(&tracker, dao_id) == 700, 1);

    // Second partial payment (400)
    let payment2 = create_test_coin(400, scenario.ctx());
    let change2 = dao_payment_tracker::pay_dao_debt(&mut tracker, dao_id, payment2, scenario.ctx());
    assert!(change2.value() == 0, 2);
    assert!(dao_payment_tracker::get_dao_debt(&tracker, dao_id) == 300, 3);

    // Final payment (500, overpayment)
    let payment3 = create_test_coin(500, scenario.ctx());
    let change3 = dao_payment_tracker::pay_dao_debt(&mut tracker, dao_id, payment3, scenario.ctx());
    assert!(change3.value() == 200, 4); // 200 change
    assert!(dao_payment_tracker::get_dao_debt(&tracker, dao_id) == 0, 5);
    assert!(!dao_payment_tracker::is_dao_blocked(&tracker, dao_id), 6);

    destroy(change1);
    destroy(change2);
    destroy(change3);
    end(scenario, tracker, admin_cap);
}

#[test]
#[expected_failure(abort_code = dao_payment_tracker::ENoDebtToPay)]
fun test_pay_dao_debt_no_debt_fails() {
    let (mut scenario, mut tracker, admin_cap) = start();

    let dao_id = object::id_from_address(@0xDA0);

    // Try to pay debt when there is no debt
    let payment = create_test_coin(1000, scenario.ctx());
    let change = dao_payment_tracker::pay_dao_debt(&mut tracker, dao_id, payment, scenario.ctx());

    destroy(change);
    end(scenario, tracker, admin_cap);
}

#[test]
fun test_forgive_debt() {
    let (scenario, mut tracker, admin_cap) = start();

    let dao_id = object::id_from_address(@0xDA0);

    // Accumulate debt
    dao_payment_tracker::accumulate_debt(&mut tracker, dao_id, 1000);
    assert!(dao_payment_tracker::is_dao_blocked(&tracker, dao_id), 0);

    // Forgive debt
    dao_payment_tracker::forgive_debt(&mut tracker, dao_id, &admin_cap);

    // Verify debt forgiven
    assert!(!dao_payment_tracker::is_dao_blocked(&tracker, dao_id), 1);
    assert!(dao_payment_tracker::get_dao_debt(&tracker, dao_id) == 0, 2);
    assert!(dao_payment_tracker::get_protocol_revenue(&tracker) == 0, 3); // No revenue from forgiveness

    end(scenario, tracker, admin_cap);
}

#[test]
fun test_forgive_debt_nonexistent_dao_safe() {
    let (scenario, mut tracker, admin_cap) = start();

    let dao_id = object::id_from_address(@0xDA0);

    // Forgive debt for DAO with no debt (should not crash)
    dao_payment_tracker::forgive_debt(&mut tracker, dao_id, &admin_cap);

    // Verify no issues
    assert!(!dao_payment_tracker::is_dao_blocked(&tracker, dao_id), 0);

    end(scenario, tracker, admin_cap);
}

#[test]
fun test_reduce_debt_partial() {
    let (scenario, mut tracker, admin_cap) = start();

    let dao_id = object::id_from_address(@0xDA0);

    // Accumulate debt
    dao_payment_tracker::accumulate_debt(&mut tracker, dao_id, 1000);

    // Reduce debt by 300
    dao_payment_tracker::reduce_debt(&mut tracker, dao_id, 300, &admin_cap);

    // Verify debt reduced
    assert!(dao_payment_tracker::is_dao_blocked(&tracker, dao_id), 0); // Still blocked
    assert!(dao_payment_tracker::get_dao_debt(&tracker, dao_id) == 700, 1);

    end(scenario, tracker, admin_cap);
}

#[test]
fun test_reduce_debt_full() {
    let (scenario, mut tracker, admin_cap) = start();

    let dao_id = object::id_from_address(@0xDA0);

    // Accumulate debt
    dao_payment_tracker::accumulate_debt(&mut tracker, dao_id, 1000);

    // Reduce debt by full amount
    dao_payment_tracker::reduce_debt(&mut tracker, dao_id, 1000, &admin_cap);

    // Verify debt cleared
    assert!(!dao_payment_tracker::is_dao_blocked(&tracker, dao_id), 0);
    assert!(dao_payment_tracker::get_dao_debt(&tracker, dao_id) == 0, 1);

    end(scenario, tracker, admin_cap);
}

#[test]
fun test_reduce_debt_over_amount() {
    let (scenario, mut tracker, admin_cap) = start();

    let dao_id = object::id_from_address(@0xDA0);

    // Accumulate debt of 500
    dao_payment_tracker::accumulate_debt(&mut tracker, dao_id, 500);

    // Try to reduce by 1000 (more than debt)
    dao_payment_tracker::reduce_debt(&mut tracker, dao_id, 1000, &admin_cap);

    // Verify debt set to 0, not negative
    assert!(!dao_payment_tracker::is_dao_blocked(&tracker, dao_id), 0);
    assert!(dao_payment_tracker::get_dao_debt(&tracker, dao_id) == 0, 1);

    end(scenario, tracker, admin_cap);
}

#[test]
fun test_withdraw_revenue() {
    let (mut scenario, mut tracker, admin_cap) = start();

    let dao_id = object::id_from_address(@0xDA0);

    // Accumulate and pay debt to create revenue
    dao_payment_tracker::accumulate_debt(&mut tracker, dao_id, 1000);
    let payment = create_test_coin(1000, scenario.ctx());
    let change = dao_payment_tracker::pay_dao_debt(&mut tracker, dao_id, payment, scenario.ctx());
    destroy(change);

    assert!(dao_payment_tracker::get_protocol_revenue(&tracker) == 1000, 0);

    // Withdraw revenue
    let withdrawn = dao_payment_tracker::withdraw_revenue(&mut tracker, 500, scenario.ctx());

    assert!(withdrawn.value() == 500, 1);
    assert!(dao_payment_tracker::get_protocol_revenue(&tracker) == 500, 2);

    destroy(withdrawn);
    end(scenario, tracker, admin_cap);
}

#[test]
fun test_transfer_revenue_to_fee_manager() {
    let (mut scenario, mut tracker, admin_cap) = start();

    let dao_id = object::id_from_address(@0xDA0);

    // Create revenue
    dao_payment_tracker::accumulate_debt(&mut tracker, dao_id, 1000);
    let payment = create_test_coin(1000, scenario.ctx());
    let change = dao_payment_tracker::pay_dao_debt(&mut tracker, dao_id, payment, scenario.ctx());
    destroy(change);

    // Transfer to fee manager
    let transferred = dao_payment_tracker::transfer_revenue_to_fee_manager(&mut tracker, 600, scenario.ctx());

    assert!(transferred.value() == 600, 0);
    assert!(dao_payment_tracker::get_protocol_revenue(&tracker) == 400, 1);

    destroy(transferred);
    end(scenario, tracker, admin_cap);
}

#[test]
#[expected_failure(abort_code = dao_payment_tracker::EInsufficientRevenue)]
fun test_transfer_revenue_insufficient_fails() {
    let (mut scenario, mut tracker, admin_cap) = start();

    // Try to transfer revenue when there is none
    let transferred = dao_payment_tracker::transfer_revenue_to_fee_manager(&mut tracker, 100, scenario.ctx());

    destroy(transferred);
    end(scenario, tracker, admin_cap);
}

#[test]
fun test_multiple_daos() {
    let (mut scenario, mut tracker, admin_cap) = start();

    let dao1 = object::id_from_address(@0xDA01);
    let dao2 = object::id_from_address(@0xDA02);
    let dao3 = object::id_from_address(@0xDA03);

    // Accumulate different debts for different DAOs
    dao_payment_tracker::accumulate_debt(&mut tracker, dao1, 1000);
    dao_payment_tracker::accumulate_debt(&mut tracker, dao2, 2000);
    dao_payment_tracker::accumulate_debt(&mut tracker, dao3, 500);

    // Verify individual debts
    assert!(dao_payment_tracker::get_dao_debt(&tracker, dao1) == 1000, 0);
    assert!(dao_payment_tracker::get_dao_debt(&tracker, dao2) == 2000, 1);
    assert!(dao_payment_tracker::get_dao_debt(&tracker, dao3) == 500, 2);

    // Pay dao1's debt
    let payment1 = create_test_coin(1000, scenario.ctx());
    let change1 = dao_payment_tracker::pay_dao_debt(&mut tracker, dao1, payment1, scenario.ctx());
    destroy(change1);

    // Verify dao1 cleared, others unchanged
    assert!(dao_payment_tracker::get_dao_debt(&tracker, dao1) == 0, 3);
    assert!(dao_payment_tracker::get_dao_debt(&tracker, dao2) == 2000, 4);
    assert!(dao_payment_tracker::get_dao_debt(&tracker, dao3) == 500, 5);

    end(scenario, tracker, admin_cap);
}

#[test]
fun test_anyone_can_pay_debt() {
    let (mut scenario, mut tracker, admin_cap) = start();

    let dao_id = object::id_from_address(@0xDA0);

    // Accumulate debt
    dao_payment_tracker::accumulate_debt(&mut tracker, dao_id, 1000);

    // Different address pays the debt
    scenario.next_tx(PAYER);
    let payment = create_test_coin(1000, scenario.ctx());
    let change = dao_payment_tracker::pay_dao_debt(&mut tracker, dao_id, payment, scenario.ctx());

    // Verify debt cleared (permissionless payment worked)
    assert!(!dao_payment_tracker::is_dao_blocked(&tracker, dao_id), 0);
    assert!(dao_payment_tracker::get_protocol_revenue(&tracker) == 1000, 1);

    destroy(change);
    end(scenario, tracker, admin_cap);
}
