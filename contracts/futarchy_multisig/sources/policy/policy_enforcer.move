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

/// Check if a type is typically critical (just a suggestion, not enforced)
/// DAOs can override this with their own policies
public fun is_typically_critical<T>(): bool {
    use std::type_name;
    use futarchy_core::action_types;

    // These are commonly critical but DAOs can configure as they wish
    let type_name = type_name::get<T>();
    // TODO: Add actual critical action type checks once policy action types are defined
    // For now, only check for InitiateDissolution which exists
    type_name == type_name::get<action_types::InitiateDissolution>()
}

// === Type-Based Policy Notes ===
// With type-based policies, we no longer need pattern matching.
// TypeName comparison is O(1) and handled natively by Sui.
// The policy registry directly maps TypeName -> PolicyRule.
// This is more efficient and safer than string pattern matching.