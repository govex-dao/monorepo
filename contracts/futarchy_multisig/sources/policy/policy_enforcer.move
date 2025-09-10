/// Enforces critical policies and validates council ownership
module futarchy_multisig::policy_enforcer;

use std::vector;
use std::option::{Self, Option};
use sui::object::{Self, ID, UID};
use sui::tx_context::TxContext;
use account_protocol::account::Account;
use futarchy_multisig::weighted_multisig::WeightedMultisig;

// === Council Registry ===

/// Capability proving a council belongs to a specific DAO
/// Created when DAO creates/registers a council
public struct CouncilRegistration has key, store {
    id: UID,
    dao_id: ID,                    // The DAO that owns this council
    council_id: ID,                 // The security council Account ID
    council_type: vector<u8>,       // b"treasury", b"technical", b"legal", etc.
    created_at_ms: u64,
}

/// Create a new council registration (called when DAO creates a council)
public fun register_council(
    dao_id: ID,
    council_id: ID,
    council_type: vector<u8>,
    created_at_ms: u64,
    ctx: &mut TxContext,
): CouncilRegistration {
    CouncilRegistration {
        id: object::new(ctx),
        dao_id,
        council_id,
        council_type,
        created_at_ms,
    }
}

/// Verify a council belongs to the DAO
public fun verify_council_ownership(
    council: &Account<WeightedMultisig>,
    dao_id: ID,
    registrations: &vector<CouncilRegistration>,
): bool {
    let council_id = object::id(council);
    let mut i = 0;
    while (i < vector::length(registrations)) {
        let reg = vector::borrow(registrations, i);
        if (reg.council_id == council_id && reg.dao_id == dao_id) {
            return true
        };
        i = i + 1;
    };
    false
}

// === Helper Functions ===

/// Check if a pattern is typically critical (just a suggestion, not enforced)
/// DAOs can override this with their own policies
public fun is_typically_critical(pattern: vector<u8>): bool {
    // These are commonly critical but DAOs can configure as they wish
    pattern == b"governance/set_pattern_policy" ||
    pattern == b"governance/set_object_policy" ||
    pattern == b"governance/register_council" ||
    pattern == b"upgrade/package" ||
    pattern == b"upgrade/restrict" ||
    pattern == b"treasury/mint" ||
    pattern == b"dissolution/initiate"
}

// === Pattern Matching Optimization ===

/// Check if pattern matches with wildcard support
/// For ~100 patterns, linear search is acceptable (< 1ms)
/// Patterns like "treasury/*" match "treasury/spend", "treasury/mint", etc.
public fun pattern_matches(pattern: vector<u8>, action_pattern: vector<u8>): bool {
    // Check for wildcard
    let pattern_len = vector::length(&pattern);
    if (pattern_len > 0 && *vector::borrow(&pattern, pattern_len - 1) == 42) { // 42 = '*'
        // Wildcard pattern - check prefix
        let prefix_len = pattern_len - 1;
        if (vector::length(&action_pattern) < prefix_len) {
            return false
        };
        
        let mut i = 0;
        while (i < prefix_len) {
            if (*vector::borrow(&pattern, i) != *vector::borrow(&action_pattern, i)) {
                return false
            };
            i = i + 1;
        };
        true
    } else {
        // Exact match
        pattern == action_pattern
    }
}

// === Efficient Pattern Lookup ===

/// For ~100 patterns, linear search with early exit is efficient
/// Returns first matching pattern and its policy
public fun find_matching_pattern(
    action_pattern: vector<u8>,
    patterns: &vector<vector<u8>>,
): Option<u64> {
    let mut i = 0;
    let len = vector::length(patterns);
    
    while (i < len) {
        let pattern = vector::borrow(patterns, i);
        if (pattern_matches(*pattern, action_pattern)) {
            return option::some(i)
        };
        i = i + 1;
    };
    
    option::none()
}

// === Gas Optimization Notes ===
// For ~100 patterns:
// - Linear search: ~100-200 gas per pattern check
// - Total: ~10,000-20,000 gas for full scan
// - This is negligible compared to storage operations (100,000+ gas)
// 
// Hash table would be:
// - ~5,000 gas for hash computation
// - ~10,000 gas for table lookup
// - Not significantly better for small N
//
// Recommendation: Keep linear search for simplicity until >1000 patterns