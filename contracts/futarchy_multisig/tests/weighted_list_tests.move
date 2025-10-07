#[test_only]
module futarchy_multisig::weighted_list_tests;

use futarchy_multisig::weighted_list::{Self, WeightedList};
use sui::test_utils::assert_eq;

// === Test Addresses ===
const ALICE: address = @0xA11CE;
const BOB: address = @0xB0B;
const CAROL: address = @0xCA501;
const DAVE: address = @0xDA4E;

// === Construction Tests ===

#[test]
fun test_new_creates_valid_list() {
    let list = weighted_list::new(
        vector[ALICE, BOB],
        vector[30, 70]
    );

    assert_eq(weighted_list::total_weight(&list), 100);
    assert_eq(weighted_list::size(&list), 2);
    assert!(weighted_list::contains(&list, &ALICE));
    assert!(weighted_list::contains(&list, &BOB));
    assert_eq(weighted_list::get_weight(&list, &ALICE), 30);
    assert_eq(weighted_list::get_weight(&list, &BOB), 70);
    assert!(!weighted_list::is_immutable(&list));
}

#[test]
fun test_new_immutable_creates_immutable_list() {
    let list = weighted_list::new_immutable(
        vector[ALICE, BOB],
        vector[50, 50]
    );

    assert!(weighted_list::is_immutable(&list));
    assert_eq(weighted_list::total_weight(&list), 100);
}

#[test]
fun test_singleton_creates_single_member() {
    let list = weighted_list::singleton(ALICE);

    assert_eq(weighted_list::size(&list), 1);
    assert_eq(weighted_list::total_weight(&list), 1);
    assert_eq(weighted_list::get_weight(&list, &ALICE), 1);
    assert!(!weighted_list::is_immutable(&list));
}

#[test]
fun test_singleton_immutable() {
    let list = weighted_list::singleton_immutable(ALICE);

    assert!(weighted_list::is_immutable(&list));
    assert_eq(weighted_list::size(&list), 1);
}

#[test]
fun test_large_weights() {
    let max_weight = weighted_list::max_member_weight();
    let list = weighted_list::new(
        vector[ALICE, BOB],
        vector[max_weight, max_weight]
    );

    assert_eq(weighted_list::get_weight(&list, &ALICE), max_weight);
    assert_eq(weighted_list::total_weight(&list), max_weight * 2);
}

#[test]
#[expected_failure(abort_code = weighted_list::EInvalidArguments)]
fun test_new_fails_with_mismatched_lengths() {
    let _list = weighted_list::new(
        vector[ALICE, BOB],
        vector[100] // Only one weight for two addresses
    );
}

#[test]
#[expected_failure(abort_code = weighted_list::EEmptyMemberList)]
fun test_new_fails_with_empty_vectors() {
    let _list = weighted_list::new(
        vector[],
        vector[]
    );
}

#[test]
#[expected_failure(abort_code = weighted_list::EDuplicateMember)]
fun test_new_fails_with_duplicate_members() {
    let _list = weighted_list::new(
        vector[ALICE, ALICE], // Duplicate!
        vector[50, 50]
    );
}

#[test]
#[expected_failure(abort_code = weighted_list::EInvalidArguments)]
fun test_new_fails_with_zero_weight() {
    let _list = weighted_list::new(
        vector[ALICE, BOB],
        vector[100, 0] // Zero weight!
    );
}

#[test]
#[expected_failure(abort_code = weighted_list::EWeightTooLarge)]
fun test_new_fails_with_weight_too_large() {
    let max_weight = weighted_list::max_member_weight();
    let _list = weighted_list::new(
        vector[ALICE],
        vector[max_weight + 1] // Exceeds maximum!
    );
}

#[test]
#[expected_failure(abort_code = weighted_list::EWeightOverflow)]
fun test_new_fails_with_total_overflow() {
    let max_total = weighted_list::max_total_weight();
    let max_weight = weighted_list::max_member_weight();

    // Create enough members to exceed max total
    let mut addresses = vector[];
    let mut weights = vector[];
    let mut i = 0;
    while (i < 2000) { // 2000 * 1M = 2B > 1B max
        addresses.push_back(@0x1);
        weights.push_back(max_weight);
        i = i + 1;
    };

    let _list = weighted_list::new(addresses, weights);
}

// === Accessor Tests ===

#[test]
fun test_contains() {
    let list = weighted_list::new(
        vector[ALICE, BOB],
        vector[40, 60]
    );

    assert!(weighted_list::contains(&list, &ALICE));
    assert!(weighted_list::contains(&list, &BOB));
    assert!(!weighted_list::contains(&list, &CAROL));
}

#[test]
fun test_get_weight() {
    let list = weighted_list::new(
        vector[ALICE, BOB, CAROL],
        vector[20, 30, 50]
    );

    assert_eq(weighted_list::get_weight(&list, &ALICE), 20);
    assert_eq(weighted_list::get_weight(&list, &BOB), 30);
    assert_eq(weighted_list::get_weight(&list, &CAROL), 50);
}

#[test]
#[expected_failure(abort_code = weighted_list::ENotMember)]
fun test_get_weight_fails_for_non_member() {
    let list = weighted_list::new(
        vector[ALICE],
        vector[100]
    );

    let _ = weighted_list::get_weight(&list, &BOB);
}

#[test]
fun test_get_weight_or_zero() {
    let list = weighted_list::new(
        vector[ALICE],
        vector[100]
    );

    assert_eq(weighted_list::get_weight_or_zero(&list, &ALICE), 100);
    assert_eq(weighted_list::get_weight_or_zero(&list, &BOB), 0);
}

#[test]
fun test_size_and_is_empty() {
    let list = weighted_list::new(
        vector[ALICE, BOB, CAROL],
        vector[10, 20, 30]
    );

    assert_eq(weighted_list::size(&list), 3);
    assert!(!weighted_list::is_empty(&list));
}

#[test]
fun test_get_members_and_weights() {
    let list = weighted_list::new(
        vector[ALICE, BOB],
        vector[40, 60]
    );

    let (addresses, weights) = weighted_list::get_members_and_weights(&list);

    assert_eq(addresses.length(), 2);
    assert_eq(weights.length(), 2);
    assert_eq(weighted_list::total_weight(&list), 100);
}

// === Share Calculation Tests ===

#[test]
fun test_calculate_share() {
    let list = weighted_list::new(
        vector[ALICE, BOB],
        vector[30, 70]
    );

    // Total amount to distribute: 1000
    let total = 1000u64;

    // Alice has 30/100 weight = 30%
    let alice_share = weighted_list::calculate_share(&list, 30, total);
    assert_eq(alice_share, 300);

    // Bob has 70/100 weight = 70%
    let bob_share = weighted_list::calculate_share(&list, 70, total);
    assert_eq(bob_share, 700);
}

#[test]
fun test_calculate_member_share() {
    let list = weighted_list::new(
        vector[ALICE, BOB, CAROL],
        vector[10, 20, 70]
    );

    let total = 10000u64;

    // Alice: 10/100 = 10% = 1000
    assert_eq(weighted_list::calculate_member_share(&list, &ALICE, total), 1000);

    // Bob: 20/100 = 20% = 2000
    assert_eq(weighted_list::calculate_member_share(&list, &BOB, total), 2000);

    // Carol: 70/100 = 70% = 7000
    assert_eq(weighted_list::calculate_member_share(&list, &CAROL, total), 7000);
}

#[test]
fun test_calculate_share_with_large_amounts() {
    let list = weighted_list::new(
        vector[ALICE, BOB],
        vector[1, 1]
    );

    // Test with very large total amount
    let large_total = 1_000_000_000u64; // 1 billion
    let alice_share = weighted_list::calculate_member_share(&list, &ALICE, large_total);

    // 50% of 1 billion = 500 million
    assert_eq(alice_share, 500_000_000);
}

#[test]
fun test_calculate_share_rounds_down() {
    let list = weighted_list::new(
        vector[ALICE, BOB, CAROL],
        vector[1, 1, 1]
    );

    // 100 / 3 = 33.333... should round down to 33
    let alice_share = weighted_list::calculate_member_share(&list, &ALICE, 100);
    assert_eq(alice_share, 33);
}

// === Equality Tests ===

#[test]
fun test_equals_same_lists() {
    let list1 = weighted_list::new(
        vector[ALICE, BOB],
        vector[30, 70]
    );

    let list2 = weighted_list::new(
        vector[ALICE, BOB],
        vector[30, 70]
    );

    assert!(weighted_list::equals(&list1, &list2));
}

#[test]
fun test_equals_different_weights() {
    let list1 = weighted_list::new(
        vector[ALICE, BOB],
        vector[30, 70]
    );

    let list2 = weighted_list::new(
        vector[ALICE, BOB],
        vector[40, 60]
    );

    assert!(!weighted_list::equals(&list1, &list2));
}

#[test]
fun test_equals_different_members() {
    let list1 = weighted_list::new(
        vector[ALICE, BOB],
        vector[50, 50]
    );

    let list2 = weighted_list::new(
        vector[ALICE, CAROL],
        vector[50, 50]
    );

    assert!(!weighted_list::equals(&list1, &list2));
}

#[test]
fun test_equals_different_sizes() {
    let list1 = weighted_list::new(
        vector[ALICE],
        vector[100]
    );

    let list2 = weighted_list::new(
        vector[ALICE, BOB],
        vector[50, 50]
    );

    assert!(!weighted_list::equals(&list1, &list2));
}

// === Mutation Tests ===

#[test]
fun test_update_replaces_entire_list() {
    let mut list = weighted_list::new(
        vector[ALICE, BOB],
        vector[30, 70]
    );

    weighted_list::update(
        &mut list,
        vector[CAROL, DAVE],
        vector[40, 60]
    );

    assert_eq(weighted_list::size(&list), 2);
    assert!(!weighted_list::contains(&list, &ALICE));
    assert!(!weighted_list::contains(&list, &BOB));
    assert!(weighted_list::contains(&list, &CAROL));
    assert!(weighted_list::contains(&list, &DAVE));
    assert_eq(weighted_list::get_weight(&list, &CAROL), 40);
    assert_eq(weighted_list::total_weight(&list), 100);
}

#[test]
#[expected_failure(abort_code = weighted_list::EListIsImmutable)]
fun test_update_fails_on_immutable() {
    let mut list = weighted_list::new_immutable(
        vector[ALICE],
        vector[100]
    );

    weighted_list::update(
        &mut list,
        vector[BOB],
        vector[100]
    );
}

#[test]
fun test_set_member_weight_updates_existing() {
    let mut list = weighted_list::new(
        vector[ALICE, BOB],
        vector[30, 70]
    );

    weighted_list::set_member_weight(&mut list, ALICE, 50);

    assert_eq(weighted_list::get_weight(&list, &ALICE), 50);
    assert_eq(weighted_list::total_weight(&list), 120); // 50 + 70
}

#[test]
fun test_set_member_weight_adds_new_member() {
    let mut list = weighted_list::new(
        vector[ALICE],
        vector[100]
    );

    weighted_list::set_member_weight(&mut list, BOB, 50);

    assert_eq(weighted_list::size(&list), 2);
    assert!(weighted_list::contains(&list, &BOB));
    assert_eq(weighted_list::get_weight(&list, &BOB), 50);
    assert_eq(weighted_list::total_weight(&list), 150);
}

#[test]
#[expected_failure(abort_code = weighted_list::EListIsImmutable)]
fun test_set_member_weight_fails_on_immutable() {
    let mut list = weighted_list::new_immutable(
        vector[ALICE],
        vector[100]
    );

    weighted_list::set_member_weight(&mut list, ALICE, 50);
}

#[test]
#[expected_failure(abort_code = weighted_list::EInvalidArguments)]
fun test_set_member_weight_fails_with_zero() {
    let mut list = weighted_list::new(
        vector[ALICE],
        vector[100]
    );

    weighted_list::set_member_weight(&mut list, ALICE, 0);
}

#[test]
#[expected_failure(abort_code = weighted_list::EWeightTooLarge)]
fun test_set_member_weight_fails_with_too_large() {
    let mut list = weighted_list::new(
        vector[ALICE],
        vector[100]
    );

    let max_weight = weighted_list::max_member_weight();
    weighted_list::set_member_weight(&mut list, ALICE, max_weight + 1);
}

#[test]
fun test_remove_member() {
    let mut list = weighted_list::new(
        vector[ALICE, BOB, CAROL],
        vector[20, 30, 50]
    );

    weighted_list::remove_member(&mut list, BOB);

    assert_eq(weighted_list::size(&list), 2);
    assert!(!weighted_list::contains(&list, &BOB));
    assert_eq(weighted_list::total_weight(&list), 70); // 20 + 50
}

#[test]
#[expected_failure(abort_code = weighted_list::ENotMember)]
fun test_remove_member_fails_for_non_member() {
    let mut list = weighted_list::new(
        vector[ALICE],
        vector[100]
    );

    weighted_list::remove_member(&mut list, BOB);
}

#[test]
#[expected_failure(abort_code = weighted_list::EEmptyMemberList)]
fun test_remove_member_fails_on_last_member() {
    let mut list = weighted_list::new(
        vector[ALICE],
        vector[100]
    );

    weighted_list::remove_member(&mut list, ALICE);
}

#[test]
#[expected_failure(abort_code = weighted_list::EListIsImmutable)]
fun test_remove_member_fails_on_immutable() {
    let mut list = weighted_list::new_immutable(
        vector[ALICE, BOB],
        vector[50, 50]
    );

    weighted_list::remove_member(&mut list, ALICE);
}

// === Invariant Tests ===

#[test]
fun test_invariants_hold_after_mutations() {
    let mut list = weighted_list::new(
        vector[ALICE, BOB],
        vector[30, 70]
    );

    // All mutations should maintain invariants
    weighted_list::set_member_weight(&mut list, CAROL, 100);
    assert!(weighted_list::verify_invariants(&list));

    weighted_list::set_member_weight(&mut list, ALICE, 50);
    assert!(weighted_list::verify_invariants(&list));

    weighted_list::remove_member(&mut list, BOB);
    assert!(weighted_list::verify_invariants(&list));

    weighted_list::update(&mut list, vector[DAVE, CAROL], vector[25, 75]);
    assert!(weighted_list::verify_invariants(&list));
}

#[test]
fun test_complex_scenario() {
    // Create a multisig with 4 members
    let mut list = weighted_list::new(
        vector[ALICE, BOB, CAROL, DAVE],
        vector[10, 20, 30, 40]
    );

    // Total: 100
    assert_eq(weighted_list::total_weight(&list), 100);

    // Calculate shares for 10,000 token distribution
    let total_distribution = 10_000u64;
    assert_eq(weighted_list::calculate_member_share(&list, &ALICE, total_distribution), 1_000);
    assert_eq(weighted_list::calculate_member_share(&list, &BOB, total_distribution), 2_000);
    assert_eq(weighted_list::calculate_member_share(&list, &CAROL, total_distribution), 3_000);
    assert_eq(weighted_list::calculate_member_share(&list, &DAVE, total_distribution), 4_000);

    // Update Bob's weight
    weighted_list::set_member_weight(&mut list, BOB, 50);
    assert_eq(weighted_list::total_weight(&list), 130); // 10+50+30+40

    // Remove Dave
    weighted_list::remove_member(&mut list, DAVE);
    assert_eq(weighted_list::total_weight(&list), 90); // 10+50+30
    assert_eq(weighted_list::size(&list), 3);

    // Verify invariants still hold
    assert!(weighted_list::verify_invariants(&list));
}
