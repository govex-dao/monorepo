/// Version tracking for the futarchy package
module futarchy::version;

// === Imports ===
use account_protocol::version_witness::{Self, VersionWitness};

// === Constants ===
const VERSION: u64 = 1;

// === Structs ===
public struct V1() has drop;

// === Public Functions ===

/// Get the current version witness
public(package) fun current(): VersionWitness {
    version_witness::new(V1())
}

/// Get the version number
public fun get(): u64 {
    VERSION
}

// === Test Functions ===

#[test_only]
public struct Witness() has drop;

#[test_only]
public fun witness(): Witness {
    Witness()
}

#[test_only]
/// Get a test version witness for the futarchy package
public fun test_version(): VersionWitness {
    // Create a proper version witness for testing
    version_witness::new(V1())
}