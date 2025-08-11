/// 2-of-2 co-execution for accepting and locking UpgradeCaps (DAO + Security Council).
/// Enforced when DAO sets policy "UpgradeCap:Custodian" -> council_id in policy_registry.
module futarchy::upgrade_cap_coexec;

use std::{string::{Self, String}, hash};
use sui::{
    clock::Clock,
    object::{Self, ID},
    package::UpgradeCap,
    transfer::Receiving,
    tx_context::TxContext,
};
use account_protocol::{
    account::{Self, Account},
    executable::Executable,
    owned, // withdraw helper
};
use futarchy::{
    version,
    coexec_common,
    futarchy_config::{Self, FutarchyConfig, FutarchyOutcome},
    security_council,
    security_council_actions,
    security_council_intents,
    weighted_multisig::{Self, WeightedMultisig, Approvals},
};
use account_actions::package_upgrade;

/// Require 2-of-2 for accepting/locking an UpgradeCap:
/// - DAO must have policy "UpgradeCap:Custodian" pointing to the Security Council
/// - DAO executable contains ApproveUpgradeCapAction with digest, expiry
/// - Council executable contains AcceptAndLockUpgradeCapAction, and the cap is delivered as Receiving<UpgradeCap>
/// If checks pass, this function withdraws and locks the cap into the council under governance control,
/// and confirms both executables atomically.
public fun execute_accept_and_lock_with_council(
    dao: &mut Account<FutarchyConfig>,
    council: &mut Account<WeightedMultisig>,
    mut futarchy_exec: Executable<FutarchyOutcome>,
    mut council_exec: Executable<Approvals>,
    cap_receipt: Receiving<UpgradeCap>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Extract DAO approval action (typed)
    let approve: &security_council_actions::ApproveUpgradeCapAction =
        coexec_common::extract_action(&mut futarchy_exec, version::current());
    let (dao_id_expected, cap_id_expected, pkg_name_ref, expires_at) =
        security_council_actions::get_approve_upgrade_cap_params(approve);
    let pkg_name_expected = *pkg_name_ref;
    
    // Extract Council accept/lock action
    let accept: &security_council_actions::AcceptAndLockUpgradeCapAction =
        coexec_common::extract_action(
            &mut council_exec,
            security_council_intents::accept_upgrade_cap_witness()
        );
    let (cap_id_from_council, pkg_name_council_ref) =
        security_council_actions::get_accept_and_lock_cap_params(accept);
    let pkg_name_council = *pkg_name_council_ref;
    
    // Policy and expiry checks (digest removed).
    coexec_common::enforce_custodian_policy(dao, council, b"UpgradeCap:Custodian".to_string());
    coexec_common::validate_dao_id(dao_id_expected, object::id(dao));
    coexec_common::validate_expiry(clock, expires_at);
    
    // Typed equality for cap and package name.
    assert!(cap_id_expected == cap_id_from_council, /* EActionTypeMismatch or dedicated code */ 5);
    assert!(pkg_name_expected == pkg_name_council, /* EActionTypeMismatch or dedicated code */ 5);
    
    // 4) Withdraw the cap from the receipt and lock it into the council
    let cap = owned::do_withdraw(
        &mut council_exec,
        council,
        cap_receipt,
        security_council_intents::accept_upgrade_cap_witness()
    );
    
    // Strong object identity check.
    assert!(object::id(&cap) == cap_id_expected, /* Wrong object */ 6);
    
    let auth = security_council::authenticate(council, ctx);
    // Lock under council-managed assets; version 0 for ruleset as before
    package_upgrade::lock_cap(auth, council, cap, pkg_name_expected, 0);
    
    // 5) Confirm both executables atomically
    coexec_common::confirm_both_executables(dao, council, futarchy_exec, council_exec);
}