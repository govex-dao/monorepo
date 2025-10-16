module futarchy_multisig::coexec_custody;

use account_protocol::account::{Self, Account};
use account_protocol::executable::Executable;
use account_protocol::owned;
use futarchy_core::futarchy_config::{Self, FutarchyConfig};
use futarchy_core::version;
use futarchy_multisig::coexec_common;
use futarchy_multisig::weighted_multisig::{Self, WeightedMultisig, Approvals};
use futarchy_vault::custody_actions;
use std::hash;
use sui::clock::Clock;
use sui::object::{Self, ID};
use sui::transfer::Receiving;
use sui::tx_context::TxContext;

// Error codes
const EActionTypeMismatch: u64 = 4;
const EObjectIdMismatch: u64 = 5;
const EResourceKeyMismatch: u64 = 6;
const EWithdrawnObjectIdMismatch: u64 = 7;

/// Generic 2-of-2 custody accept:
/// - DAO executable must contain ApproveCustodyAction<R>
/// - Council executable must contain AcceptIntoCustodyAction<R> and a Receiving<R>
/// - Enforces type policy BorrowAction<R> (or object policy if specific object has one)
/// - Uses OBJECT > TYPE hierarchy: checks object-level policy first, falls back to type-level
/// Stores the object under council custody with a standard key.
public fun execute_accept_with_council<
    FutarchyOutcome: store + drop + copy,
    R: key + store,
    W: copy + drop,
>(
    dao: &mut Account<FutarchyConfig>,
    council: &mut Account<WeightedMultisig>,
    mut futarchy_exec: Executable<FutarchyOutcome>,
    mut council_exec: Executable<Approvals>,
    receipt: Receiving<R>,
    intent_witness: W,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Verify we're at the right action types
    use account_protocol::{executable, intents};
    use futarchy_vault::custody_actions;

    // Verify DAO action type
    coexec_common::verify_current_action<FutarchyOutcome, custody_actions::ApproveCustodyAction<R>>(
        &futarchy_exec,
        EActionTypeMismatch,
    );

    // Get action data safely with bounds checking
    let dao_action_data = coexec_common::get_current_action_data(&futarchy_exec);

    // Deserialize the approve action
    let approve = custody_actions::approve_custody_action_from_bytes<R>(*dao_action_data);
    let (
        dao_id_expected,
        obj_id_expected,
        res_key_ref,
        _ctx_ref,
        expires_at,
    ) = custody_actions::get_approve_custody_params(&approve);

    // Verify Council action type
    coexec_common::verify_current_action<Approvals, custody_actions::AcceptIntoCustodyAction<R>>(
        &council_exec,
        EActionTypeMismatch,
    );

    // Get council action data safely with bounds checking
    let council_action_data = coexec_common::get_current_action_data(&council_exec);

    // Deserialize the accept action
    let accept = custody_actions::accept_into_custody_action_from_bytes<R>(*council_action_data);
    let (obj_id_council, res_key_council_ref, _ctx2_ref) = custody_actions::get_accept_params(
        &accept,
    );

    // Validate IDs match
    assert!(obj_id_expected == obj_id_council, EObjectIdMismatch);
    assert!(*res_key_ref == *res_key_council_ref, EResourceKeyMismatch);

    // === CRITICAL: Data Integrity Check ===
    // Validate that the complete action data from both sides matches exactly.
    // This prevents a malicious council from injecting modified parameters that
    // the DAO did not approve. The DAO and Council must agree on the ENTIRE action,
    // not just the object ID and resource key.
    let dao_digest = hash::sha3_256(*dao_action_data);
    let council_digest = hash::sha3_256(*council_action_data);
    coexec_common::validate_digest(&dao_digest, &council_digest);

    // Enforce custodian policy using OBJECT > TYPE hierarchy
    // Check if object-level policy exists (regardless of mode)
    let registry = futarchy_multisig::policy_registry::borrow_registry(dao, version::current());

    if (futarchy_multisig::policy_registry::has_object_policy(registry, obj_id_expected)) {
        // OBJECT-level policy exists - use it exclusively (highest priority)
        // This works correctly even if object policy is MODE_DAO_ONLY (0):
        // - has_object_policy() returns true (policy exists)
        // - enforce_custodian_policy_for_object() will check mode and abort if council not allowed
        coexec_common::enforce_custodian_policy_for_object(dao, council, obj_id_expected);
    } else {
        // No object policy - fall back to TYPE-level policy for ApproveCustodyAction<R>
        coexec_common::enforce_custodian_policy_for_type<R>(dao, council);
    };

    // Validate DAO ID and expiry
    coexec_common::validate_dao_id(dao_id_expected, object::id(dao));
    coexec_common::validate_expiry(clock, expires_at);

    // Withdraw the object (must match the withdraw action witness used when building the intent)
    let obj = owned::do_withdraw_object(&mut council_exec, council, receipt, intent_witness);
    assert!(object::id(&obj) == obj_id_expected, EWithdrawnObjectIdMismatch);

    // Store under council custody using a standard key
    let mut key = b"custody:".to_string();
    key.append(*res_key_ref);
    account_protocol::account::add_managed_asset(council, key, obj, version::current());

    // Confirm both executables atomically
    coexec_common::confirm_both_executables(dao, council, futarchy_exec, council_exec);
}
