#[test_only]
module account_actions::version_tests;

use account_actions::version;
use account_protocol::version_witness;

// === Imports ===

// === Tests ===

#[test]
fun test_get_version() {
    let ver = version::get();
    assert!(ver == 1, 0);
}

#[test]
fun test_current_returns_version_witness() {
    // Test that current() returns a valid VersionWitness
    let witness = version::current();

    // Verify it's a valid witness by checking it can be used
    // VersionWitness is opaque, so we mainly verify it doesn't abort
    let _ = witness;
}

#[test]
fun test_version_consistency() {
    // Verify version number is consistent
    let v1 = version::get();
    let v2 = version::get();
    assert!(v1 == v2, 0);
}

#[test]
fun test_version_is_positive() {
    let ver = version::get();
    assert!(ver > 0, 0);
}

#[test]
fun test_multiple_current_calls() {
    // Multiple calls to current() should work (creates new witness each time)
    let w1 = version::current();
    let w2 = version::current();
    let w3 = version::current();

    // All should be valid witnesses
    let _ = w1;
    let _ = w2;
    let _ = w3;
}

#[test]
fun test_version_witness_has_correct_package() {
    // Create witness and verify it has the correct package address
    let witness = version::current();

    // Extract package address from witness
    let package_address = version_witness::package_addr(&witness);

    // Verify it's the account_actions package address
    assert!(package_address == @account_actions, 0);
}
