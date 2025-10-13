#[test_only]
module futarchy_core::version_tests;

use futarchy_core::version;
use account_protocol::version_witness::{Self, VersionWitness};

// === Basic Version Tests ===

#[test]
fun test_get_version_number() {
    let ver = version::get();
    assert!(ver == 1, 0);
}

#[test]
fun test_current_returns_valid_witness() {
    let witness = version::current();
    // Should not abort - valid VersionWitness created
    let _ = witness;
}

#[test]
fun test_test_version_returns_valid_witness() {
    let witness = version::test_version();
    // Should not abort - valid VersionWitness for testing
    let _ = witness;
}

#[test]
fun test_current_and_test_version_are_equivalent() {
    let current = version::current();
    let test = version::test_version();

    // Both should be valid V1 witnesses
    // We can't directly compare VersionWitness values, but we can verify both work
    let _ = current;
    let _ = test;
}

// === Version Witness Usage Tests ===

#[test]
fun test_version_witness_can_be_copied() {
    let witness1 = version::current();
    let witness2 = witness1; // Copy

    // Both should be valid
    let _ = witness1;
    let _ = witness2;
}

#[test]
fun test_multiple_version_witnesses() {
    // Should be able to create multiple witnesses
    let w1 = version::current();
    let w2 = version::current();
    let w3 = version::test_version();

    let _ = w1;
    let _ = w2;
    let _ = w3;
}

// === Version Consistency Tests ===

#[test]
fun test_version_number_consistency() {
    // Get version number multiple times
    let v1 = version::get();
    let v2 = version::get();
    let v3 = version::get();

    // Should always return same value
    assert!(v1 == v2, 0);
    assert!(v2 == v3, 1);
    assert!(v1 == v3, 2);
}

// === Test Witness Tests ===

#[test]
fun test_witness_constructor() {
    let w = version::witness();
    let _ = w;
}

#[test]
fun test_witness_has_drop() {
    let w = version::witness();
    // Should be droppable - no need to explicitly destroy
    let _ = w;
}
