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
    futarchy_config::{Self, FutarchyConfig},
    security_council,
    custody_actions,
    security_council_intents,
    weighted_multisig::{Self, WeightedMultisig, Approvals},
};
use account_actions::package_upgrade;

// Error codes
const ECapIdMismatch: u64 = 1001;
const EPackageNameMismatch: u64 = 1002;
const EWrongCapObject: u64 = 1003;

/// Require 2-of-2 for accepting/locking an UpgradeCap:
/// - DAO must have policy "UpgradeCap:Custodian" pointing to Security Council
/// - DAO executable contains ApproveCustodyAction<UpgradeCap> (with dao_id, cap_id, resource_key=package_name, expires_at)
/// - Council executable contains AcceptIntoCustodyAction<UpgradeCap> and the cap is delivered as Receiving<UpgradeCap>
/// If checks pass, withdraw and lock the cap into the council via package_upgrade,
/// and confirm both executables atomically.
public fun execute_accept_and_lock_with_council<FutarchyOutcome: store + drop + copy>(
    dao: &mut Account<FutarchyConfig>,
    council: &mut Account<WeightedMultisig>,
    mut futarchy_exec: Executable<FutarchyOutcome>,
    mut council_exec: Executable<Approvals>,
    cap_receipt: Receiving<UpgradeCap>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Extract DAO approval (generic custody action)
    let approve: &custody_actions::ApproveCustodyAction<UpgradeCap> =
        coexec_common::extract_action(&mut futarchy_exec, version::current());
    let (dao_id_expected, cap_id_expected, pkg_name_ref, _ctx_str_ref, expires_at) =
        custody_actions::get_approve_custody_params(approve);
    let pkg_name_expected = *pkg_name_ref;
    
    // Extract Council accept action (custody), using the same witness used when building the withdraw intent
    let accept: &custody_actions::AcceptIntoCustodyAction<UpgradeCap> =
        coexec_common::extract_action(
            &mut council_exec,
            security_council_intents::new_accept_upgrade_cap_intent()
        );
    let (cap_id_from_council, pkg_name_council_ref, _ctx2_str_ref) =
        custody_actions::get_accept_params(accept);
    let pkg_name_council = *pkg_name_council_ref;
    
    // Policy and expiry checks
    coexec_common::enforce_custodian_policy(dao, council, b"UpgradeCap:Custodian".to_string());
    coexec_common::validate_dao_id(dao_id_expected, object::id(dao));
    coexec_common::validate_expiry(clock, expires_at);
    
    // Typed equality for cap and package name.
    assert!(cap_id_expected == cap_id_from_council, ECapIdMismatch);
    assert!(pkg_name_expected == pkg_name_council, EPackageNameMismatch);
    
    // Withdraw the cap from the receipt and lock it into the council
    let cap = owned::do_withdraw(
        &mut council_exec,
        council,
        cap_receipt,
        security_council_intents::new_accept_upgrade_cap_intent()
    );
    
    // Strong object identity check.
    assert!(object::id(&cap) == cap_id_expected, EWrongCapObject);
    
    let auth = security_council::authenticate(council, ctx);
    // Lock under council-managed assets; version 0 for ruleset as before
    package_upgrade::lock_cap(auth, council, cap, pkg_name_expected, 0);
    
    // Confirm both executables atomically
    coexec_common::confirm_both_executables(dao, council, futarchy_exec, council_exec);
}