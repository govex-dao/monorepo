/// Comprehensive tests for dividend_tree.move
/// Tests tree construction, prefix bucketing, validation, and query functions
#[test_only]
module futarchy_payments::dividend_tree_tests;

use futarchy_payments::dividend_tree::{Self, DividendTree};
use std::string;
use sui::coin::Coin;
use sui::sui::SUI;
use sui::test_scenario as ts;
use sui::test_utils::assert_eq;

// === Test Addresses ===
const ALICE: address = @0xA1;
const BOB: address = @0xB2;
const CAROL: address = @0x01C3;
const DAVE: address = @0x01D4;
const EVE: address = @0x02E5;

// === Basic Construction Tests ===

#[test]
fun test_create_tree() {
    let mut scenario = ts::begin(@0x0);

    let tree = dividend_tree::create_tree<SUI>(
        string::utf8(b"Test Dividend Tree"),
        ts::ctx(&mut scenario),
    );

    let (total_recipients, total_amount, num_buckets, finalized) = dividend_tree::tree_info(&tree);

    assert_eq(total_recipients, 0);
    assert_eq(total_amount, 0);
    assert_eq(num_buckets, 0);
    assert!(!finalized);
    assert_eq(dividend_tree::build_nonce(&tree), 0);

    dividend_tree::destroy_tree_for_testing(tree);
    ts::end(scenario);
}

#[test]
fun test_add_single_bucket() {
    let mut scenario = ts::begin(@0x0);

    let mut tree = dividend_tree::create_tree<SUI>(
        string::utf8(b"Single Bucket Test"),
        ts::ctx(&mut scenario),
    );

    // Add bucket with prefix 0x00
    let prefix = vector[0x00];
    let recipients = vector[ALICE, BOB];
    let amounts = vector[1000, 2000];

    dividend_tree::add_bucket(
        &mut tree,
        prefix,
        recipients,
        amounts,
        0, // expected nonce
        ts::ctx(&mut scenario),
    );

    let (total_recipients, total_amount, num_buckets, _) = dividend_tree::tree_info(&tree);

    assert_eq(total_recipients, 2);
    assert_eq(total_amount, 3000);
    assert_eq(num_buckets, 1);
    assert_eq(dividend_tree::build_nonce(&tree), 1);

    dividend_tree::destroy_tree_for_testing(tree);
    ts::end(scenario);
}

#[test]
fun test_add_multiple_buckets() {
    let mut scenario = ts::begin(@0x0);

    let mut tree = dividend_tree::create_tree<SUI>(
        string::utf8(b"Multiple Buckets Test"),
        ts::ctx(&mut scenario),
    );

    // Bucket 1: prefix 0x00
    dividend_tree::add_bucket(
        &mut tree,
        vector[0x00],
        vector[ALICE, BOB],
        vector[1000, 2000],
        0,
        ts::ctx(&mut scenario),
    );

    // Bucket 2: prefix 0x0001
    dividend_tree::add_bucket(
        &mut tree,
        vector[0x00, 0x01],
        vector[CAROL, DAVE],
        vector[3000, 4000],
        1,
        ts::ctx(&mut scenario),
    );

    let (total_recipients, total_amount, num_buckets, _) = dividend_tree::tree_info(&tree);

    assert_eq(total_recipients, 4);
    assert_eq(total_amount, 10000);
    assert_eq(num_buckets, 2);
    assert_eq(dividend_tree::build_nonce(&tree), 2);

    dividend_tree::destroy_tree_for_testing(tree);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = dividend_tree::EInvalidNonce)]
fun test_add_bucket_fails_with_wrong_nonce() {
    let mut scenario = ts::begin(@0x0);

    let mut tree = dividend_tree::create_tree<SUI>(
        string::utf8(b"Wrong Nonce Test"),
        ts::ctx(&mut scenario),
    );

    // Try to add bucket with wrong nonce (expecting 0 but passing 1)
    dividend_tree::add_bucket(
        &mut tree,
        vector[0x00],
        vector[ALICE],
        vector[1000],
        1, // Wrong! Should be 0
        ts::ctx(&mut scenario),
    );

    dividend_tree::destroy_tree_for_testing(tree);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = dividend_tree::EBucketAlreadyExists)]
fun test_add_bucket_fails_with_duplicate_prefix() {
    let mut scenario = ts::begin(@0x0);

    let mut tree = dividend_tree::create_tree<SUI>(
        string::utf8(b"Duplicate Prefix Test"),
        ts::ctx(&mut scenario),
    );

    let prefix = vector[0x00];

    // Add first bucket
    dividend_tree::add_bucket(
        &mut tree,
        prefix,
        vector[ALICE],
        vector[1000],
        0,
        ts::ctx(&mut scenario),
    );

    // Try to add bucket with same prefix - should fail!
    dividend_tree::add_bucket(
        &mut tree,
        prefix,
        vector[BOB],
        vector[2000],
        1,
        ts::ctx(&mut scenario),
    );

    dividend_tree::destroy_tree_for_testing(tree);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = dividend_tree::EMismatchedLength)]
fun test_add_bucket_fails_with_mismatched_lengths() {
    let mut scenario = ts::begin(@0x0);

    let mut tree = dividend_tree::create_tree<SUI>(
        string::utf8(b"Mismatched Lengths"),
        ts::ctx(&mut scenario),
    );

    // 2 recipients but only 1 amount
    dividend_tree::add_bucket(
        &mut tree,
        vector[0x00],
        vector[ALICE, BOB],
        vector[1000], // Missing amount for BOB!
        0,
        ts::ctx(&mut scenario),
    );

    dividend_tree::destroy_tree_for_testing(tree);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = dividend_tree::EZeroAmount)]
fun test_add_bucket_fails_with_zero_amount() {
    let mut scenario = ts::begin(@0x0);

    let mut tree = dividend_tree::create_tree<SUI>(
        string::utf8(b"Zero Amount Test"),
        ts::ctx(&mut scenario),
    );

    dividend_tree::add_bucket(
        &mut tree,
        vector[0x00],
        vector[ALICE],
        vector[0], // Zero amount not allowed!
        0,
        ts::ctx(&mut scenario),
    );

    dividend_tree::destroy_tree_for_testing(tree);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = dividend_tree::EEmptyPrefix)]
fun test_add_bucket_fails_with_empty_prefix() {
    let mut scenario = ts::begin(@0x0);

    let mut tree = dividend_tree::create_tree<SUI>(
        string::utf8(b"Empty Prefix Test"),
        ts::ctx(&mut scenario),
    );

    dividend_tree::add_bucket(
        &mut tree,
        vector::empty(), // Empty prefix not allowed!
        vector[ALICE],
        vector[1000],
        0,
        ts::ctx(&mut scenario),
    );

    dividend_tree::destroy_tree_for_testing(tree);
    ts::end(scenario);
}

// === Finalization Tests ===

#[test]
fun test_finalize_tree() {
    let mut scenario = ts::begin(@0x0);

    let mut tree = dividend_tree::create_tree<SUI>(
        string::utf8(b"Finalize Test"),
        ts::ctx(&mut scenario),
    );

    dividend_tree::add_bucket(
        &mut tree,
        vector[0x00],
        vector[ALICE],
        vector[1000],
        0,
        ts::ctx(&mut scenario),
    );

    assert!(!dividend_tree::is_finalized(&tree));

    dividend_tree::finalize_tree(&mut tree);

    assert!(dividend_tree::is_finalized(&tree));

    // Content hash should be set
    assert!(dividend_tree::content_hash(&tree).length() > 0);

    dividend_tree::destroy_tree_for_testing(tree);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = dividend_tree::ETreeFinalized)]
fun test_cannot_add_bucket_after_finalization() {
    let mut scenario = ts::begin(@0x0);

    let mut tree = dividend_tree::create_tree<SUI>(
        string::utf8(b"Finalized Tree Test"),
        ts::ctx(&mut scenario),
    );

    dividend_tree::add_bucket(
        &mut tree,
        vector[0x00],
        vector[ALICE],
        vector[1000],
        0,
        ts::ctx(&mut scenario),
    );

    dividend_tree::finalize_tree(&mut tree);

    // Try to add bucket after finalization - should fail!
    dividend_tree::add_bucket(
        &mut tree,
        vector[0x01],
        vector[BOB],
        vector[2000],
        1,
        ts::ctx(&mut scenario),
    );

    dividend_tree::destroy_tree_for_testing(tree);
    ts::end(scenario);
}

// === Hash Functions Tests ===

#[test]
fun test_hash_bucket_data() {
    let recipients = vector[ALICE, BOB];
    let amounts = vector[1000, 2000];

    let hash = dividend_tree::hash_bucket_data(&recipients, &amounts);

    assert!(hash.length() == 32); // Blake2b256 produces 32-byte hash
}

#[test]
fun test_add_bucket_hash() {
    let mut scenario = ts::begin(@0x0);

    let mut tree = dividend_tree::create_tree<SUI>(
        string::utf8(b"Hash Test"),
        ts::ctx(&mut scenario),
    );

    let recipients = vector[ALICE, BOB];
    let amounts = vector[1000, 2000];

    let bucket_hash = dividend_tree::hash_bucket_data(&recipients, &amounts);

    dividend_tree::add_bucket_hash(&mut tree, bucket_hash, 0);

    assert_eq(dividend_tree::build_nonce(&tree), 1);
    assert!(dividend_tree::rolling_hash(&tree).length() > 0);

    dividend_tree::destroy_tree_for_testing(tree);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = dividend_tree::ETreeFinalized)]
fun test_cannot_add_hash_after_finalization() {
    let mut scenario = ts::begin(@0x0);

    let mut tree = dividend_tree::create_tree<SUI>(
        string::utf8(b"Hash After Finalize"),
        ts::ctx(&mut scenario),
    );

    dividend_tree::finalize_tree(&mut tree);

    // Try to add hash after finalization - should fail!
    dividend_tree::add_bucket_hash(&mut tree, vector[1, 2, 3], 0);

    dividend_tree::destroy_tree_for_testing(tree);
    ts::end(scenario);
}

// === Prefix Validation Tests ===

#[test]
fun test_address_has_prefix() {
    // ALICE (@0xA1) has leading zeros when converted to 32 bytes
    // In 32-byte form: 0x00000000000000000000000000000000000000000000000000000000000000A1
    assert!(dividend_tree::address_has_prefix(ALICE, &vector[0x00]));
    assert!(!dividend_tree::address_has_prefix(ALICE, &vector[0xFF]));

    // CAROL (@0x01C3) starts with 0x00...01
    assert!(dividend_tree::address_has_prefix(CAROL, &vector[0x00]));
}

#[test]
fun test_is_prefix_directory_sorted() {
    let mut scenario = ts::begin(@0x0);

    let mut tree = dividend_tree::create_tree<SUI>(
        string::utf8(b"Sorted Prefixes Test"),
        ts::ctx(&mut scenario),
    );

    // Add buckets in sorted order
    dividend_tree::add_bucket(
        &mut tree,
        vector[0x00],
        vector[ALICE],
        vector[1000],
        0,
        ts::ctx(&mut scenario),
    );

    dividend_tree::add_bucket(
        &mut tree,
        vector[0x00, 0x01],
        vector[CAROL],
        vector[2000],
        1,
        ts::ctx(&mut scenario),
    );

    dividend_tree::add_bucket(
        &mut tree,
        vector[0x00, 0x02],
        vector[EVE],
        vector[3000],
        2,
        ts::ctx(&mut scenario),
    );

    // Should be sorted
    assert!(dividend_tree::is_prefix_directory_sorted(&tree));

    dividend_tree::destroy_tree_for_testing(tree);
    ts::end(scenario);
}

// === Query Tests ===

#[test]
fun test_query_allocation_found() {
    let mut scenario = ts::begin(@0x0);

    let mut tree = dividend_tree::create_tree<SUI>(
        string::utf8(b"Query Allocation Test"),
        ts::ctx(&mut scenario),
    );

    dividend_tree::add_bucket(
        &mut tree,
        vector[0x00],
        vector[ALICE, BOB],
        vector[1000, 2000],
        0,
        ts::ctx(&mut scenario),
    );

    dividend_tree::finalize_tree(&mut tree);

    let (found, amount, prefix) = dividend_tree::query_allocation(&tree, ALICE);

    assert!(found);
    assert_eq(amount, 1000);
    assert_eq(prefix, vector[0x00]);

    dividend_tree::destroy_tree_for_testing(tree);
    ts::end(scenario);
}

#[test]
fun test_query_allocation_not_found() {
    let mut scenario = ts::begin(@0x0);

    let mut tree = dividend_tree::create_tree<SUI>(
        string::utf8(b"Query Not Found Test"),
        ts::ctx(&mut scenario),
    );

    dividend_tree::add_bucket(
        &mut tree,
        vector[0x00],
        vector[ALICE],
        vector[1000],
        0,
        ts::ctx(&mut scenario),
    );

    dividend_tree::finalize_tree(&mut tree);

    // Query for address not in tree
    let (found, amount, prefix) = dividend_tree::query_allocation(&tree, EVE);

    assert!(!found);
    assert_eq(amount, 0);
    assert_eq(prefix, vector::empty());

    dividend_tree::destroy_tree_for_testing(tree);
    ts::end(scenario);
}

#[test]
fun test_has_bucket() {
    let mut scenario = ts::begin(@0x0);

    let mut tree = dividend_tree::create_tree<SUI>(
        string::utf8(b"Has Bucket Test"),
        ts::ctx(&mut scenario),
    );

    let prefix = vector[0x00];

    assert!(!dividend_tree::has_bucket(&tree, prefix));

    dividend_tree::add_bucket(
        &mut tree,
        prefix,
        vector[ALICE],
        vector[1000],
        0,
        ts::ctx(&mut scenario),
    );

    assert!(dividend_tree::has_bucket(&tree, prefix));
    assert!(!dividend_tree::has_bucket(&tree, vector[0x01]));

    dividend_tree::destroy_tree_for_testing(tree);
    ts::end(scenario);
}

#[test]
fun test_get_bucket() {
    let mut scenario = ts::begin(@0x0);

    let mut tree = dividend_tree::create_tree<SUI>(
        string::utf8(b"Get Bucket Test"),
        ts::ctx(&mut scenario),
    );

    let prefix = vector[0x00];

    dividend_tree::add_bucket(
        &mut tree,
        prefix,
        vector[ALICE, BOB],
        vector[1000, 2000],
        0,
        ts::ctx(&mut scenario),
    );

    let bucket = dividend_tree::get_bucket(&tree, prefix);
    let addresses = dividend_tree::bucket_addresses(bucket);

    assert_eq(addresses.length(), 2);
    assert_eq(*addresses.borrow(0), ALICE);
    assert_eq(*addresses.borrow(1), BOB);

    let alice_amount = dividend_tree::get_recipient_amount(bucket, ALICE);
    let bob_amount = dividend_tree::get_recipient_amount(bucket, BOB);

    assert_eq(alice_amount, 1000);
    assert_eq(bob_amount, 2000);

    dividend_tree::destroy_tree_for_testing(tree);
    ts::end(scenario);
}

#[test]
fun test_get_bucket_summary() {
    let mut scenario = ts::begin(@0x0);

    let mut tree = dividend_tree::create_tree<SUI>(
        string::utf8(b"Bucket Summary Test"),
        ts::ctx(&mut scenario),
    );

    dividend_tree::add_bucket(
        &mut tree,
        vector[0x00],
        vector[ALICE, BOB, CAROL],
        vector[1000, 2000, 3000],
        0,
        ts::ctx(&mut scenario),
    );

    let (prefix, recipient_count, total_amount) = dividend_tree::get_bucket_summary(&tree, 0);

    assert_eq(prefix, vector[0x00]);
    assert_eq(recipient_count, 3);
    assert_eq(total_amount, 6000);

    dividend_tree::destroy_tree_for_testing(tree);
    ts::end(scenario);
}

#[test]
fun test_batch_query_allocations() {
    let mut scenario = ts::begin(@0x0);

    let mut tree = dividend_tree::create_tree<SUI>(
        string::utf8(b"Batch Query Test"),
        ts::ctx(&mut scenario),
    );

    dividend_tree::add_bucket(
        &mut tree,
        vector[0x00],
        vector[ALICE, BOB],
        vector[1000, 2000],
        0,
        ts::ctx(&mut scenario),
    );

    let (found_vec, amount_vec) = dividend_tree::batch_query_allocations(
        &tree,
        vector[ALICE, BOB, CAROL],
    );

    assert_eq(found_vec.length(), 3);
    assert_eq(*found_vec.borrow(0), true); // ALICE found
    assert_eq(*found_vec.borrow(1), true); // BOB found
    assert_eq(*found_vec.borrow(2), false); // CAROL not found

    assert_eq(*amount_vec.borrow(0), 1000);
    assert_eq(*amount_vec.borrow(1), 2000);
    assert_eq(*amount_vec.borrow(2), 0);

    dividend_tree::destroy_tree_for_testing(tree);
    ts::end(scenario);
}

// === Getter Tests ===

#[test]
fun test_tree_getters() {
    let mut scenario = ts::begin(@0x0);

    let description = string::utf8(b"Getter Test Tree");
    let mut tree = dividend_tree::create_tree<SUI>(description, ts::ctx(&mut scenario));

    assert_eq(dividend_tree::description(&tree), description);
    assert_eq(dividend_tree::total_recipients(&tree), 0);
    assert_eq(dividend_tree::total_amount(&tree), 0);
    assert_eq(dividend_tree::num_buckets(&tree), 0);
    assert!(!dividend_tree::is_finalized(&tree));

    dividend_tree::add_bucket(
        &mut tree,
        vector[0x00],
        vector[ALICE],
        vector[5000],
        0,
        ts::ctx(&mut scenario),
    );

    assert_eq(dividend_tree::total_recipients(&tree), 1);
    assert_eq(dividend_tree::total_amount(&tree), 5000);
    assert_eq(dividend_tree::num_buckets(&tree), 1);

    dividend_tree::destroy_tree_for_testing(tree);
    ts::end(scenario);
}

// === Complex Scenario Tests ===

#[test]
fun test_full_tree_workflow() {
    let mut scenario = ts::begin(@0x0);

    let mut tree = dividend_tree::create_tree<SUI>(
        string::utf8(b"Full Workflow Test"),
        ts::ctx(&mut scenario),
    );

    // Build tree with multiple buckets
    dividend_tree::add_bucket(
        &mut tree,
        vector[0x00],
        vector[ALICE, BOB],
        vector[1000, 2000],
        0,
        ts::ctx(&mut scenario),
    );

    dividend_tree::add_bucket(
        &mut tree,
        vector[0x00, 0x01],
        vector[CAROL, DAVE],
        vector[3000, 4000],
        1,
        ts::ctx(&mut scenario),
    );

    dividend_tree::add_bucket(
        &mut tree,
        vector[0x00, 0x02],
        vector[EVE],
        vector[5000],
        2,
        ts::ctx(&mut scenario),
    );

    // Check tree state
    let (total_recipients, total_amount, num_buckets, finalized) = dividend_tree::tree_info(&tree);
    assert_eq(total_recipients, 5);
    assert_eq(total_amount, 15000);
    assert_eq(num_buckets, 3);
    assert!(!finalized);

    // Finalize
    dividend_tree::finalize_tree(&mut tree);
    assert!(dividend_tree::is_finalized(&tree));

    // Query allocations
    let (found, amount, _) = dividend_tree::query_allocation(&tree, ALICE);
    assert!(found && amount == 1000);

    let (found, amount, _) = dividend_tree::query_allocation(&tree, EVE);
    assert!(found && amount == 5000);

    // Validate integrity
    assert!(dividend_tree::is_prefix_directory_sorted(&tree));

    dividend_tree::destroy_tree_for_testing(tree);
    ts::end(scenario);
}

#[test]
fun test_tree_with_duplicate_recipients_accumulates() {
    let mut scenario = ts::begin(@0x0);

    let mut tree = dividend_tree::create_tree<SUI>(
        string::utf8(b"Duplicate Recipients Test"),
        ts::ctx(&mut scenario),
    );

    // Add bucket with duplicate address (ALICE appears twice)
    dividend_tree::add_bucket(
        &mut tree,
        vector[0x00],
        vector[ALICE, BOB, ALICE], // ALICE twice!
        vector[1000, 2000, 500],
        0,
        ts::ctx(&mut scenario),
    );

    // Total should accumulate duplicates
    let (total_recipients, total_amount, _, _) = dividend_tree::tree_info(&tree);
    assert_eq(total_recipients, 2); // Only 2 unique recipients
    assert_eq(total_amount, 3500); // All amounts added

    // Query ALICE - should have accumulated amount
    let (found, amount, _) = dividend_tree::query_allocation(&tree, ALICE);
    assert!(found);
    assert_eq(amount, 1500); // 1000 + 500

    dividend_tree::destroy_tree_for_testing(tree);
    ts::end(scenario);
}

#[test]
fun test_get_validation_chunk_size() {
    let mut scenario = ts::begin(@0x0);

    // Small tree (<= 1000 buckets)
    let small_tree = dividend_tree::create_tree<SUI>(
        string::utf8(b"Small Tree"),
        ts::ctx(&mut scenario),
    );

    let (chunk_size, num_chunks) = dividend_tree::get_validation_chunk_size(&small_tree);
    assert_eq(chunk_size, 0); // No buckets yet
    assert_eq(num_chunks, 0);

    dividend_tree::destroy_tree_for_testing(small_tree);
    ts::end(scenario);
}
