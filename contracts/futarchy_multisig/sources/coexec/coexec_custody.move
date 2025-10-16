module futarchy_multisig::coexec_custody;

use account_protocol::account::{Self, Account};
use account_protocol::executable::Executable;
use account_protocol::owned;
use futarchy_core::futarchy_config::{Self, FutarchyConfig};
use futarchy_core::version;
use futarchy_multisig::coexec_common;
use futarchy_multisig::weighted_multisig::{Self, WeightedMultisig, Approvals};
use futarchy_vault::custody_actions;
use std::string::String;
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
/// - Enforces policy_key on DAO ("Custody:*" or domain-specific like "UpgradeCap:Custodian")
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
    policy_key: String,
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

    // Policy/expiry checks
    coexec_common::enforce_custodian_policy(dao, council, policy_key);
    coexec_common::validate_dao_id(dao_id_expected, object::id(dao));
    coexec_common::validate_expiry(clock, expires_at);

    assert!(obj_id_expected == obj_id_council, EObjectIdMismatch);
    assert!(*res_key_ref == *res_key_council_ref, EResourceKeyMismatch);

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
