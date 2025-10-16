/// Comprehensive tests for weighted_multisig.move
/// Tests core voting, time locks, and stale proposal detection
#[test_only]
module futarchy_multisig::weighted_multisig_tests;

use futarchy_multisig::weighted_multisig::{Self, WeightedMultisig, Approvals};
use sui::clock::{Self, Clock};
use sui::test_scenario;
use sui::test_utils::assert_eq;

// === Test Addresses ===
const ALICE: address = @0xA11CE;
const BOB: address = @0xB0B;
const CAROL: address = @0xCA501;
const DAVE: address = @0xDA4E;
const EVE: address = @0xE4E;

// === Test Constants ===
const ONE_HOUR_MS: u64 = 3_600_000;
const ONE_DAY_MS: u64 = 86_400_000;
const THIRTY_DAYS_MS: u64 = 2_592_000_000;

// === Helper Functions ===

fun setup_clock(): Clock {
    clock::create_for_testing(test_scenario::ctx(&mut test_scenario::begin(@0x0)))
}

// === Basic Construction Tests ===

#[test]
fun test_new_creates_valid_multisig() {
    let clock = setup_clock();

    let multisig = weighted_multisig::new(
        vector[ALICE, BOB, CAROL],
        vector[30, 30, 40],
        60, // 60% threshold
        &clock,
    );

    assert_eq(weighted_multisig::threshold(&multisig), 60);
    assert_eq(weighted_multisig::total_weight(&multisig), 100);
    assert_eq(weighted_multisig::member_count(&multisig), 3);
    assert_eq(weighted_multisig::nonce(&multisig), 0);
    assert!(!weighted_multisig::is_immutable(&multisig));
    assert_eq(weighted_multisig::time_lock_delay_ms(&multisig), 0);

    clock::destroy_for_testing(clock);
}

#[test]
fun test_new_immutable_creates_immutable_multisig() {
    let clock = setup_clock();

    let multisig = weighted_multisig::new_immutable(
        vector[ALICE, BOB],
        vector[50, 50],
        75,
        &clock,
    );

    assert!(weighted_multisig::is_immutable(&multisig));
    assert_eq(weighted_multisig::threshold(&multisig), 75);

    clock::destroy_for_testing(clock);
}

#[test]
fun test_new_with_time_lock() {
    let clock = setup_clock();

    let multisig = weighted_multisig::new_with_time_lock(
        vector[ALICE, BOB],
        vector[50, 50],
        75,
        ONE_DAY_MS, // 24 hour time lock
        &clock,
    );

    assert_eq(weighted_multisig::time_lock_delay_ms(&multisig), ONE_DAY_MS);
    assert_eq(weighted_multisig::threshold(&multisig), 75);

    clock::destroy_for_testing(clock);
}

#[test]
#[expected_failure(abort_code = weighted_multisig::EInvalidArguments)]
fun test_new_fails_with_zero_threshold() {
    let clock = setup_clock();

    let _multisig = weighted_multisig::new(
        vector[ALICE, BOB],
        vector[50, 50],
        0, // Invalid!
        &clock,
    );

    clock::destroy_for_testing(clock);
}

#[test]
#[expected_failure(abort_code = weighted_multisig::EThresholdUnreachable)]
fun test_new_fails_with_threshold_too_high() {
    let clock = setup_clock();

    let _multisig = weighted_multisig::new(
        vector[ALICE, BOB],
        vector[30, 40],
        100, // Total weight is only 70!
        &clock,
    );

    clock::destroy_for_testing(clock);
}

// === Approval Tests ===

#[test]
fun test_approve_intent_adds_approver() {
    let clock = setup_clock();

    let multisig = weighted_multisig::new(
        vector[ALICE, BOB, CAROL],
        vector[30, 30, 40],
        60,
        &clock,
    );

    let mut approvals = weighted_multisig::new_approvals(&multisig);

    weighted_multisig::approve_intent(&mut approvals, &multisig, ALICE);
    weighted_multisig::approve_intent(&mut approvals, &multisig, BOB);

    // Validate will pass because 30 + 30 >= 60 threshold
    weighted_multisig::validate_outcome(approvals, &multisig, b"".to_string(), &clock);

    clock::destroy_for_testing(clock);
}

#[test]
#[expected_failure(abort_code = weighted_multisig::ENotMember)]
fun test_approve_intent_fails_for_non_member() {
    let clock = setup_clock();

    let multisig = weighted_multisig::new(
        vector[ALICE, BOB],
        vector[50, 50],
        75,
        &clock,
    );

    let mut approvals = weighted_multisig::new_approvals(&multisig);

    // DAVE is not a member!
    weighted_multisig::approve_intent(&mut approvals, &multisig, DAVE);

    clock::destroy_for_testing(clock);
}

#[test]
#[expected_failure(abort_code = weighted_multisig::EAlreadyApproved)]
fun test_approve_intent_fails_if_already_approved() {
    let clock = setup_clock();

    let multisig = weighted_multisig::new(
        vector[ALICE, BOB],
        vector[50, 50],
        75,
        &clock,
    );

    let mut approvals = weighted_multisig::new_approvals(&multisig);

    weighted_multisig::approve_intent(&mut approvals, &multisig, ALICE);
    // Try to approve again!
    weighted_multisig::approve_intent(&mut approvals, &multisig, ALICE);

    clock::destroy_for_testing(clock);
}

#[test]
#[expected_failure(abort_code = weighted_multisig::EThresholdNotMet)]
fun test_validate_outcome_fails_if_threshold_not_met() {
    let clock = setup_clock();

    let multisig = weighted_multisig::new(
        vector[ALICE, BOB, CAROL],
        vector[30, 30, 40],
        80, // Need 80, but only 30 + 30 = 60
        &clock,
    );

    let mut approvals = weighted_multisig::new_approvals(&multisig);

    weighted_multisig::approve_intent(&mut approvals, &multisig, ALICE);
    weighted_multisig::approve_intent(&mut approvals, &multisig, BOB);

    weighted_multisig::validate_outcome(approvals, &multisig, b"".to_string(), &clock);

    clock::destroy_for_testing(clock);
}

// === Nonce-Based Staleness Tests ===

#[test]
fun test_nonce_increments_on_membership_update() {
    let mut clock = setup_clock();

    let mut multisig = weighted_multisig::new(
        vector[ALICE, BOB],
        vector[50, 50],
        75,
        &clock,
    );

    let initial_nonce = weighted_multisig::nonce(&multisig);
    assert_eq(initial_nonce, 0);

    // Update membership
    clock::increment_for_testing(&mut clock, 1000);
    weighted_multisig::update_membership(
        &mut multisig,
        vector[ALICE, CAROL],
        vector[60, 40],
        80,
        &clock,
    );

    let new_nonce = weighted_multisig::nonce(&multisig);
    assert_eq(new_nonce, 1);

    clock::destroy_for_testing(clock);
}

#[test]
#[expected_failure(abort_code = weighted_multisig::EProposalStale)]
fun test_stale_proposal_rejected_on_approve() {
    let mut clock = setup_clock();

    let mut multisig = weighted_multisig::new(
        vector[ALICE, BOB, CAROL],
        vector[30, 30, 40],
        60,
        &clock,
    );

    // Create proposal at nonce 0
    let mut approvals = weighted_multisig::new_approvals(&multisig);

    // Update membership - increments nonce to 1
    clock::increment_for_testing(&mut clock, 1000);
    weighted_multisig::update_membership(
        &mut multisig,
        vector[ALICE, BOB, DAVE],
        vector[40, 30, 30],
        60,
        &clock,
    );

    // Try to approve old proposal - should fail!
    weighted_multisig::approve_intent(&mut approvals, &multisig, ALICE);

    clock::destroy_for_testing(clock);
}

#[test]
#[expected_failure(abort_code = weighted_multisig::EProposalStale)]
fun test_stale_proposal_rejected_on_validate() {
    let mut clock = setup_clock();

    let mut multisig = weighted_multisig::new(
        vector[ALICE, BOB],
        vector[50, 50],
        75,
        &clock,
    );

    // Create and approve proposal at nonce 0
    let mut approvals = weighted_multisig::new_approvals(&multisig);
    weighted_multisig::approve_intent(&mut approvals, &multisig, ALICE);
    weighted_multisig::approve_intent(&mut approvals, &multisig, BOB);

    // Update membership - invalidates proposal
    clock::increment_for_testing(&mut clock, 1000);
    weighted_multisig::update_membership(
        &mut multisig,
        vector[ALICE, CAROL],
        vector[50, 50],
        75,
        &clock,
    );

    // Try to execute stale proposal - should fail!
    weighted_multisig::validate_outcome(approvals, &multisig, b"".to_string(), &clock);

    clock::destroy_for_testing(clock);
}

// === Time Lock Tests ===

#[test]
fun test_new_approvals_with_clock_captures_creation_time() {
    let mut clock = setup_clock();
    clock::set_for_testing(&mut clock, 1000000);

    let multisig = weighted_multisig::new_with_time_lock(
        vector[ALICE, BOB],
        vector[50, 50],
        75,
        ONE_DAY_MS,
        &clock,
    );

    let approvals = weighted_multisig::new_approvals_with_clock(&multisig, &clock);

    // Verify time until executable
    let time_remaining = weighted_multisig::time_until_executable(&approvals, &clock);
    assert_eq(time_remaining, ONE_DAY_MS);

    clock::destroy_for_testing(clock);
}

#[test]
#[expected_failure(abort_code = weighted_multisig::EInvalidArguments)]
fun test_new_approvals_fails_when_time_lock_configured() {
    let clock = setup_clock();

    let multisig = weighted_multisig::new_with_time_lock(
        vector[ALICE, BOB],
        vector[50, 50],
        75,
        ONE_DAY_MS,
        &clock,
    );

    // Should abort - must use new_approvals_with_clock!
    let _approvals = weighted_multisig::new_approvals(&multisig);

    clock::destroy_for_testing(clock);
}

#[test]
#[expected_failure(abort_code = weighted_multisig::ETimeLockNotExpired)]
fun test_validate_outcome_fails_before_time_lock_expires() {
    let mut clock = setup_clock();
    clock::set_for_testing(&mut clock, 1000000);

    let multisig = weighted_multisig::new_with_time_lock(
        vector[ALICE, BOB],
        vector[50, 50],
        75,
        ONE_DAY_MS,
        &clock,
    );

    let mut approvals = weighted_multisig::new_approvals_with_clock(&multisig, &clock);

    // Get approvals
    weighted_multisig::approve_intent(&mut approvals, &multisig, ALICE);
    weighted_multisig::approve_intent(&mut approvals, &multisig, BOB);

    // Try to execute before time lock expires (advance only 1 hour)
    clock::increment_for_testing(&mut clock, ONE_HOUR_MS);

    weighted_multisig::validate_outcome(approvals, &multisig, b"".to_string(), &clock);

    clock::destroy_for_testing(clock);
}

#[test]
fun test_validate_outcome_succeeds_after_time_lock_expires() {
    let mut clock = setup_clock();
    clock::set_for_testing(&mut clock, 1000000);

    let multisig = weighted_multisig::new_with_time_lock(
        vector[ALICE, BOB],
        vector[50, 50],
        75,
        ONE_DAY_MS,
        &clock,
    );

    let mut approvals = weighted_multisig::new_approvals_with_clock(&multisig, &clock);

    // Get approvals
    weighted_multisig::approve_intent(&mut approvals, &multisig, ALICE);
    weighted_multisig::approve_intent(&mut approvals, &multisig, BOB);

    // Advance past time lock
    clock::increment_for_testing(&mut clock, ONE_DAY_MS + 1);

    // Should succeed now
    weighted_multisig::validate_outcome(approvals, &multisig, b"".to_string(), &clock);

    clock::destroy_for_testing(clock);
}

#[test]
fun test_can_execute_checks_time_lock() {
    let mut clock = setup_clock();
    clock::set_for_testing(&mut clock, 1000000);

    let multisig = weighted_multisig::new_with_time_lock(
        vector[ALICE, BOB],
        vector[50, 50],
        75,
        ONE_HOUR_MS,
        &clock,
    );

    let mut approvals = weighted_multisig::new_approvals_with_clock(&multisig, &clock);
    weighted_multisig::approve_intent(&mut approvals, &multisig, ALICE);
    weighted_multisig::approve_intent(&mut approvals, &multisig, BOB);

    // Can't execute yet
    assert!(!weighted_multisig::can_execute(&approvals, &multisig, &clock));

    // Advance time
    clock::increment_for_testing(&mut clock, ONE_HOUR_MS + 1);

    // Now executable
    assert!(weighted_multisig::can_execute(&approvals, &multisig, &clock));

    clock::destroy_for_testing(clock);
}

// === DAO Relationship Tests ===

#[test]
fun test_set_and_get_dao_id() {
    let clock = setup_clock();

    let mut multisig = weighted_multisig::new(
        vector[ALICE, BOB],
        vector[50, 50],
        75,
        &clock,
    );

    let dao_id = object::id_from_address(@0xDA0);
    weighted_multisig::set_dao_id(&mut multisig, dao_id);

    assert!(weighted_multisig::dao_id(&multisig).is_some());
    assert_eq(*weighted_multisig::dao_id(&multisig).borrow(), dao_id);
    assert!(weighted_multisig::belongs_to_dao(&multisig, dao_id));

    clock::destroy_for_testing(clock);
}

#[test]
fun test_belongs_to_dao_returns_false_for_wrong_dao() {
    let clock = setup_clock();

    let mut multisig = weighted_multisig::new(
        vector[ALICE, BOB],
        vector[50, 50],
        75,
        &clock,
    );

    let dao_id = object::id_from_address(@0xDA0);
    let wrong_dao_id = object::id_from_address(@0xBAD);

    weighted_multisig::set_dao_id(&mut multisig, dao_id);

    assert!(!weighted_multisig::belongs_to_dao(&multisig, wrong_dao_id));

    clock::destroy_for_testing(clock);
}

// === Membership Update Tests ===

#[test]
fun test_update_membership_changes_members() {
    let mut clock = setup_clock();

    let mut multisig = weighted_multisig::new(
        vector[ALICE, BOB],
        vector[50, 50],
        75,
        &clock,
    );

    clock::increment_for_testing(&mut clock, 1000);

    weighted_multisig::update_membership(
        &mut multisig,
        vector[CAROL, DAVE, EVE],
        vector[30, 30, 40],
        70,
        &clock,
    );

    assert_eq(weighted_multisig::member_count(&multisig), 3);
    assert_eq(weighted_multisig::threshold(&multisig), 70);
    assert_eq(weighted_multisig::total_weight(&multisig), 100);
    assert!(weighted_multisig::is_member(&multisig, CAROL));
    assert!(!weighted_multisig::is_member(&multisig, ALICE));

    clock::destroy_for_testing(clock);
}

#[test]
#[expected_failure(abort_code = futarchy_multisig::weighted_list::EListIsImmutable)]
fun test_update_membership_fails_on_immutable() {
    let mut clock = setup_clock();

    let mut multisig = weighted_multisig::new_immutable(
        vector[ALICE, BOB],
        vector[50, 50],
        75,
        &clock,
    );

    clock::increment_for_testing(&mut clock, 1000);

    weighted_multisig::update_membership(
        &mut multisig,
        vector[CAROL, DAVE],
        vector[60, 40],
        80,
        &clock,
    );

    clock::destroy_for_testing(clock);
}

// === Accessor Tests ===

#[test]
fun test_is_member() {
    let clock = setup_clock();

    let multisig = weighted_multisig::new(
        vector[ALICE, BOB, CAROL],
        vector[30, 30, 40],
        60,
        &clock,
    );

    assert!(weighted_multisig::is_member(&multisig, ALICE));
    assert!(weighted_multisig::is_member(&multisig, BOB));
    assert!(weighted_multisig::is_member(&multisig, CAROL));
    assert!(!weighted_multisig::is_member(&multisig, DAVE));

    clock::destroy_for_testing(clock);
}

#[test]
fun test_get_member_weight() {
    let clock = setup_clock();

    let multisig = weighted_multisig::new(
        vector[ALICE, BOB, CAROL],
        vector[30, 30, 40],
        60,
        &clock,
    );

    assert_eq(weighted_multisig::get_member_weight(&multisig, ALICE), 30);
    assert_eq(weighted_multisig::get_member_weight(&multisig, BOB), 30);
    assert_eq(weighted_multisig::get_member_weight(&multisig, CAROL), 40);
    assert_eq(weighted_multisig::get_member_weight(&multisig, DAVE), 0);

    clock::destroy_for_testing(clock);
}

// === Invariant Tests ===

#[test]
fun test_check_multisig_invariants_passes() {
    let clock = setup_clock();

    let multisig = weighted_multisig::new(
        vector[ALICE, BOB, CAROL],
        vector[30, 30, 40],
        60,
        &clock,
    );

    // Should not abort
    weighted_multisig::check_multisig_invariants(&multisig);
    assert!(weighted_multisig::is_healthy(&multisig));

    clock::destroy_for_testing(clock);
}

#[test]
fun test_validate_approvals_checks_membership() {
    let clock = setup_clock();

    let multisig = weighted_multisig::new(
        vector[ALICE, BOB],
        vector[50, 50],
        75,
        &clock,
    );

    let mut approvals = weighted_multisig::new_approvals(&multisig);
    weighted_multisig::approve_intent(&mut approvals, &multisig, ALICE);

    // Should not abort - ALICE is a member
    weighted_multisig::validate_approvals(&approvals, &multisig);

    clock::destroy_for_testing(clock);
}

// === Complex Scenario Tests ===

#[test]
fun test_full_proposal_lifecycle_with_time_lock() {
    let mut clock = setup_clock();
    clock::set_for_testing(&mut clock, 1000000);

    // Create multisig with 24h time lock
    let multisig = weighted_multisig::new_with_time_lock(
        vector[ALICE, BOB, CAROL],
        vector[30, 30, 40],
        60,
        ONE_DAY_MS,
        &clock,
    );

    // Create proposal
    let mut approvals = weighted_multisig::new_approvals_with_clock(&multisig, &clock);

    // Get approvals
    weighted_multisig::approve_intent(&mut approvals, &multisig, ALICE);
    weighted_multisig::approve_intent(&mut approvals, &multisig, BOB);

    // Check can't execute yet
    assert!(!weighted_multisig::can_execute(&approvals, &multisig, &clock));

    let time_remaining = weighted_multisig::time_until_executable(&approvals, &clock);
    assert_eq(time_remaining, ONE_DAY_MS);

    // Advance time
    clock::increment_for_testing(&mut clock, ONE_DAY_MS / 2);
    assert!(!weighted_multisig::can_execute(&approvals, &multisig, &clock));

    // Advance more
    clock::increment_for_testing(&mut clock, ONE_DAY_MS / 2 + 1);
    assert!(weighted_multisig::can_execute(&approvals, &multisig, &clock));

    // Execute
    weighted_multisig::validate_outcome(approvals, &multisig, b"".to_string(), &clock);

    clock::destroy_for_testing(clock);
}
