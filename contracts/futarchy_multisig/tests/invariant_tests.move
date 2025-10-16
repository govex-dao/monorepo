#[test_only]
module futarchy_multisig::invariant_tests;

use futarchy_multisig::weighted_list::{Self, WeightedList};
use futarchy_multisig::weighted_multisig::{Self, WeightedMultisig};
use sui::clock::{Self, Clock};
use sui::test_scenario;

// === Test Invariants in WeightedList ===

#[test]
fun test_weighted_list_invariants_enforced() {
    // Creating a valid list should pass all invariants
    let list = weighted_list::new(
        vector[@0x1, @0x2, @0x3],
        vector[100, 200, 300],
    );

    // Invariants are automatically checked during creation
    assert!(weighted_list::total_weight(&list) == 600, 1);
    assert!(weighted_list::size(&list) == 3, 2);
}

#[test]
#[expected_failure(abort_code = weighted_list::EInvariantEmptyList)]
fun test_empty_list_invariant_fails() {
    // This should fail because empty lists are not allowed
    let _list = weighted_list::new(
        vector[],
        vector[],
    );
}

#[test]
#[expected_failure(abort_code = weighted_list::EInvalidArguments)]
fun test_zero_weight_invariant_fails() {
    // This should fail because zero weights are not allowed
    let _list = weighted_list::new(
        vector[@0x1],
        vector[0],
    );
}

#[test]
fun test_update_maintains_invariants() {
    let mut list = weighted_list::new(
        vector[@0x1, @0x2],
        vector[100, 200],
    );

    // Update the list - invariants will be checked automatically
    weighted_list::update(
        &mut list,
        vector[@0x3, @0x4, @0x5],
        vector[150, 250, 350],
    );

    assert!(weighted_list::total_weight(&list) == 750, 1);
    assert!(weighted_list::size(&list) == 3, 2);
}

#[test]
#[expected_failure(abort_code = weighted_list::EListIsImmutable)]
fun test_immutable_list_cannot_be_updated() {
    let mut list = weighted_list::new_immutable(
        vector[@0x1, @0x2],
        vector[100, 200],
    );

    // This should fail because the list is immutable
    weighted_list::update(
        &mut list,
        vector[@0x3],
        vector[300],
    );
}

#[test]
fun test_remove_member_maintains_invariants() {
    let mut list = weighted_list::new(
        vector[@0x1, @0x2, @0x3],
        vector[100, 200, 300],
    );

    // Remove a member - invariants will be checked
    weighted_list::remove_member(&mut list, @0x2);

    assert!(weighted_list::total_weight(&list) == 400, 1);
    assert!(weighted_list::size(&list) == 2, 2);
}

#[test]
#[expected_failure(abort_code = weighted_list::EEmptyMemberList)]
fun test_cannot_remove_last_member() {
    let mut list = weighted_list::new(
        vector[@0x1],
        vector[100],
    );

    // This should fail - cannot have empty list
    weighted_list::remove_member(&mut list, @0x1);
}

// === Test Invariants in WeightedMultisig ===

#[test]
fun test_multisig_invariants_enforced() {
    let mut scenario = test_scenario::begin(@0x0);
    let clock = clock::create_for_testing(test_scenario::ctx(&mut scenario));

    // Create a valid multisig - invariants are checked
    let multisig = weighted_multisig::new(
        vector[@0x1, @0x2, @0x3],
        vector[100, 200, 300],
        400, // threshold
        &clock,
    );

    assert!(weighted_multisig::threshold(&multisig) == 400, 1);
    assert!(weighted_multisig::total_weight(&multisig) == 600, 2);

    clock::destroy_for_testing(clock);
    test_scenario::end(scenario);
}

#[test]
#[expected_failure(abort_code = weighted_multisig::EThresholdUnreachable)]
fun test_threshold_too_high_invariant() {
    let mut scenario = test_scenario::begin(@0x0);
    let clock = clock::create_for_testing(test_scenario::ctx(&mut scenario));

    // This should fail - threshold higher than total weight
    let _multisig = weighted_multisig::new(
        vector[@0x1, @0x2],
        vector[100, 200],
        400, // threshold > total weight (300)
        &clock,
    );

    clock::destroy_for_testing(clock);
    test_scenario::end(scenario);
}

#[test]
#[expected_failure(abort_code = weighted_multisig::EInvalidArguments)]
fun test_zero_threshold_invariant() {
    let mut scenario = test_scenario::begin(@0x0);
    let clock = clock::create_for_testing(test_scenario::ctx(&mut scenario));

    // This should fail - threshold cannot be zero
    let _multisig = weighted_multisig::new(
        vector[@0x1],
        vector[100],
        0, // invalid threshold
        &clock,
    );

    clock::destroy_for_testing(clock);
    test_scenario::end(scenario);
}

#[test]
fun test_update_membership_maintains_invariants() {
    let mut scenario = test_scenario::begin(@0x0);
    let clock = clock::create_for_testing(test_scenario::ctx(&mut scenario));

    let mut multisig = weighted_multisig::new(
        vector[@0x1, @0x2],
        vector[100, 200],
        200,
        &clock,
    );

    // Update membership - invariants will be checked
    clock::increment_for_testing(&mut clock, 1000);
    weighted_multisig::update_membership(
        &mut multisig,
        vector[@0x3, @0x4, @0x5],
        vector[150, 250, 350],
        500,
        &clock,
    );

    assert!(weighted_multisig::threshold(&multisig) == 500, 1);
    assert!(weighted_multisig::total_weight(&multisig) == 750, 2);
    assert!(weighted_multisig::member_count(&multisig) == 3, 3);

    clock::destroy_for_testing(clock);
    test_scenario::end(scenario);
}

#[test]
#[expected_failure(abort_code = weighted_list::EListIsImmutable)]
fun test_immutable_multisig_cannot_update_membership() {
    let mut scenario = test_scenario::begin(@0x0);
    let clock = clock::create_for_testing(test_scenario::ctx(&mut scenario));

    // Create an immutable multisig
    let mut multisig = weighted_multisig::new_immutable(
        vector[@0x1, @0x2],
        vector[100, 200],
        200,
        &clock,
    );

    // This should fail - cannot update immutable multisig
    weighted_multisig::update_membership(
        &mut multisig,
        vector[@0x3],
        vector[300],
        300,
        &clock,
    );

    clock::destroy_for_testing(clock);
    test_scenario::end(scenario);
}

#[test]
fun test_invariants_prevent_corruption() {
    // This test demonstrates that invariants prevent data corruption
    // Even if there were a bug that tried to create invalid state,
    // the invariant checks would catch it and abort the transaction

    let mut scenario = test_scenario::begin(@0x0);
    let clock = clock::create_for_testing(test_scenario::ctx(&mut scenario));

    // Create a valid multisig
    let multisig = weighted_multisig::new(
        vector[@0x1, @0x2, @0x3],
        vector[100, 200, 300],
        400,
        &clock,
    );

    // Any operation that would violate invariants would abort
    // For example, if we had a bug that tried to set threshold to 0,
    // the invariant check would catch it

    // The multisig remains in a valid state
    assert!(weighted_multisig::is_healthy(&multisig), 1);

    clock::destroy_for_testing(clock);
    test_scenario::end(scenario);
}

#[test]
fun test_verify_invariants_helper() {
    // Test the non-aborting verify function (useful for monitoring)
    let list = weighted_list::new(
        vector[@0x1, @0x2],
        vector[100, 200],
    );

    // Should return true for valid list
    assert!(weighted_list::verify_invariants(&list), 1);

    let mut scenario = test_scenario::begin(@0x0);
    let clock = clock::create_for_testing(test_scenario::ctx(&mut scenario));

    let multisig = weighted_multisig::new(
        vector[@0x1, @0x2],
        vector[100, 200],
        200,
        &clock,
    );

    // Should return true for valid multisig
    assert!(weighted_multisig::is_healthy(&multisig), 2);

    clock::destroy_for_testing(clock);
    test_scenario::end(scenario);
}
