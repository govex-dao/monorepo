/// Common utilities and patterns for 2-of-2 co-execution between DAO and Security Council
module futarchy::coexec_common;

use std::string::String;
use sui::{
    clock::Clock,
    object::{Self, ID},
};
use account_protocol::{
    account::Account,
    executable::Executable,
};
use futarchy::{
    version,
    policy_registry,
    futarchy_config::FutarchyConfig,
    weighted_multisig::WeightedMultisig,
};

// === Common Error Codes ===
const ENoPolicy: u64 = 1;
const EWrongCouncil: u64 = 2;
const EWrongDao: u64 = 3;
const EExpired: u64 = 4;
const EDigestMismatch: u64 = 5;

// === Policy Validation ===

/// Verify that a DAO has a specific custodian policy set to the given council
/// Returns true if policy exists and points to the council, false otherwise
public fun verify_custodian_policy(
    dao: &Account<FutarchyConfig>,
    council: &Account<WeightedMultisig>,
    policy_key: String,
): bool {
    let reg = policy_registry::borrow_registry(dao, version::current());
    if (!policy_registry::has_policy(reg, policy_key)) {
        return false
    };
    let pol = policy_registry::get_policy(reg, policy_key);
    policy_registry::policy_account_id(pol) == object::id(council)
}

/// Assert that a DAO has a specific custodian policy set to the given council
/// Aborts with ENoPolicy if policy doesn't exist or EWrongCouncil if it points elsewhere
public fun enforce_custodian_policy(
    dao: &Account<FutarchyConfig>,
    council: &Account<WeightedMultisig>,
    policy_key: String,
) {
    let reg = policy_registry::borrow_registry(dao, version::current());
    assert!(policy_registry::has_policy(reg, policy_key), ENoPolicy);
    let pol = policy_registry::get_policy(reg, policy_key);
    assert!(policy_registry::policy_account_id(pol) == object::id(council), EWrongCouncil);
}

// === Common Validation Helpers ===

/// Validate that the DAO ID matches expected
public fun validate_dao_id(expected: ID, actual: ID) {
    assert!(expected == actual, EWrongDao);
}

/// Validate that current time hasn't exceeded expiry
public fun validate_expiry(clock: &Clock, expires_at: u64) {
    assert!(clock.timestamp_ms() < expires_at, EExpired);
}

/// Validate that two digests match
public fun validate_digest(expected: &vector<u8>, actual: &vector<u8>) {
    assert!(*expected == *actual, EDigestMismatch);
}

// === Executable Confirmation ===

/// Confirm both DAO and council executables atomically
/// This ensures both sides of the co-execution are committed together
public fun confirm_both_executables<DaoOutcome: store + drop, CouncilOutcome: store + drop>(
    dao: &mut Account<FutarchyConfig>,
    council: &mut Account<WeightedMultisig>,
    dao_exec: Executable<DaoOutcome>,
    council_exec: Executable<CouncilOutcome>,
) {
    account_protocol::account::confirm_execution(dao, dao_exec);
    account_protocol::account::confirm_execution(council, council_exec);
}

// === Action Extraction Helpers ===

/// Generic helper to check if an action exists and extract it
/// This pattern is common across all co-exec modules
public fun extract_action_with_check<Outcome: store, Action: store, W: drop>(
    executable: &mut account_protocol::executable::Executable<Outcome>,
    witness: W,
    error_code: u64,
): &Action {
    use account_protocol::executable;
    assert!(executable::contains_action<Outcome, Action>(executable), error_code);
    executable::next_action(executable, witness)
}

/// Extract an action without checking if it exists first
/// Use when you're certain the action is present
public fun extract_action<Outcome: store, Action: store, W: drop>(
    executable: &mut account_protocol::executable::Executable<Outcome>,
    witness: W,
): &Action {
    account_protocol::executable::next_action(executable, witness)
}

// === Common Co-Execution Pattern ===

/// Standard validation flow for co-execution:
/// 1. Enforce policy
/// 2. Extract and validate actions
/// 3. Check DAO ID, expiry, and digest
/// This encapsulates the common pattern used across all co-exec modules
public fun validate_coexec_standard(
    dao: &Account<FutarchyConfig>,
    council: &Account<WeightedMultisig>,
    policy_key: String,
    dao_id_from_action: ID,
    expires_at: u64,
    expected_digest: &vector<u8>,
    actual_digest: &vector<u8>,
    clock: &Clock,
) {
    // Enforce the policy
    enforce_custodian_policy(dao, council, policy_key);
    
    // Validate all standard requirements
    validate_dao_id(dao_id_from_action, object::id(dao));
    validate_expiry(clock, expires_at);
    validate_digest(expected_digest, actual_digest);
}

// === Getters for Error Codes (for external modules) ===

public fun error_no_policy(): u64 { ENoPolicy }
public fun error_wrong_council(): u64 { EWrongCouncil }
public fun error_wrong_dao(): u64 { EWrongDao }
public fun error_expired(): u64 { EExpired }
public fun error_digest_mismatch(): u64 { EDigestMismatch }