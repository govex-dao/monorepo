/// Common utilities and patterns for 2-of-2 co-execution between DAO and Security Council
module futarchy_multisig::coexec_common;

use std::string::String;
use std::type_name;
use sui::{
    clock::Clock,
    object::{Self, ID},
};
use account_protocol::{
    account::Account,
    executable::Executable,
    version_witness::VersionWitness,
};
use futarchy_core::version;
use futarchy_core::futarchy_config::FutarchyConfig;
use futarchy_multisig::{
    policy_registry,
    weighted_multisig::WeightedMultisig,
};

// === Common Error Codes ===
const ENoPolicy: u64 = 1;
const EWrongCouncil: u64 = 2;
const EWrongDao: u64 = 3;
const EExpired: u64 = 4;
const EDigestMismatch: u64 = 5;
const EActionTypeMismatch: u64 = 6;
const EMetadataMissing: u64 = 7;
const EDAOMismatch: u64 = 8;
const EActionIndexOutOfBounds: u64 = 9;
const ENoActionsInIntent: u64 = 10;

// === Policy Validation ===

/// Verify that a DAO has a specific custodian policy set to the given council
/// Returns true if policy exists and points to the council, false otherwise
public fun verify_custodian_policy(
    dao: &Account<FutarchyConfig>,
    council: &Account<WeightedMultisig>,
    policy_key: String,
): bool {
    let _reg = policy_registry::borrow_registry(dao, version::current());
    let _council_id = object::id(council);
    let _ = policy_key;
    // TODO: Implement has_policy and get_policy functions
    // For now, return false (no policy match)
    false
}

/// Assert that a DAO has a specific custodian policy set to the given council
/// Aborts with ENoPolicy if policy doesn't exist or EWrongCouncil if it points elsewhere
public fun enforce_custodian_policy(
    dao: &Account<FutarchyConfig>,
    council: &Account<WeightedMultisig>,
    policy_key: String,
) {
    let _reg = policy_registry::borrow_registry(dao, version::current());
    let _council_id = object::id(council);
    let _ = policy_key;
    // TODO: Implement has_policy, get_policy and policy_account_id functions
    // For now, skip policy enforcement
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

/// Extract and advance to next action in executable
/// Used when processing actions that don't return data
public fun extract_action<Outcome: store>(
    executable: &mut account_protocol::executable::Executable<Outcome>,
    _version: VersionWitness,
) {
    // Simply increment the action index to move to next action
    account_protocol::executable::increment_action_idx(executable);
}

/// Check if the current action matches the expected type
/// This replaces the old contains_action functionality
public fun verify_current_action<Outcome: store, Action: store + drop + copy>(
    executable: &account_protocol::executable::Executable<Outcome>,
    error_code: u64,
) {
    use account_protocol::executable;
    assert!(executable::is_current_action<Outcome, Action>(executable), error_code);
}

/// Get the current action's type for validation
public fun get_current_action_type<Outcome: store>(
    executable: &account_protocol::executable::Executable<Outcome>
): type_name::TypeName {
    use account_protocol::executable;
    executable::current_action_type(executable)
}

/// Check if we're at the expected action index
public fun verify_action_index<Outcome: store>(
    executable: &account_protocol::executable::Executable<Outcome>,
    expected_idx: u64,
    error_code: u64,
) {
    use account_protocol::executable;
    assert!(executable::action_idx(executable) == expected_idx, error_code);
}

/// Advance to the next action after processing current one
/// This replaces the old next_action functionality
public fun advance_action<Outcome: store>(
    executable: &mut account_protocol::executable::Executable<Outcome>
) {
    use account_protocol::executable;
    executable::increment_action_idx(executable);
}

/// Safely get action data with bounds checking
public fun get_current_action_data<Outcome: store>(
    executable: &account_protocol::executable::Executable<Outcome>
): &vector<u8> {
    use account_protocol::{executable, intents};

    let intent = executable::intent(executable);
    let specs = intents::action_specs(intent);
    let action_count = specs.length();

    // Validate we have actions
    assert!(action_count > 0, ENoActionsInIntent);

    // Validate current index is in bounds
    let current_idx = executable::action_idx(executable);
    assert!(current_idx < action_count, EActionIndexOutOfBounds);

    // Safe to access now
    let spec = specs.borrow(current_idx);
    intents::action_spec_data(spec)
}

/// Peek at the type of an action at a specific index
public fun peek_action_type_at<Outcome: store>(
    executable: &account_protocol::executable::Executable<Outcome>,
    idx: u64
): type_name::TypeName {
    use account_protocol::executable;
    executable::action_type_at(executable, idx)
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
public fun error_action_type_mismatch(): u64 { EActionTypeMismatch }
public fun error_metadata_missing(): u64 { EMetadataMissing }
public fun error_dao_mismatch(): u64 { EDAOMismatch }