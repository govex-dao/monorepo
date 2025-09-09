/// 2-of-2 co-execution for accepting and locking UpgradeCaps (DAO + Security Council).
/// Enforced when DAO sets policy "UpgradeCap:Custodian" -> council_id in policy_registry.
module futarchy_multisig::upgrade_cap_coexec;

use std::{string::{Self, String}, hash, vector};
use sui::{
    clock::Clock,
    object::{Self, ID},
    package::UpgradeCap,
    transfer::Receiving,
    tx_context::TxContext,
};
use account_protocol::{
    account::{Self, Account},
    executable::{Self, Executable},
    owned, // withdraw helper
};
use futarchy_core::version;
use futarchy_core::futarchy_config::{Self, FutarchyConfig, GenericApproval};
use futarchy_multisig::{
    coexec_common,
    security_council,
    security_council_intents,
};
use futarchy_multisig::{
    security_council_actions,
    weighted_multisig::{Self, WeightedMultisig, Approvals},
};
use futarchy_vault::custody_actions;
use account_actions::package_upgrade;

// Error codes
const ECapIdMismatch: u64 = 1001;
const EPackageNameMismatch: u64 = 1002;
const EWrongCapObject: u64 = 1003;

/// Require 2-of-2 for accepting/locking an UpgradeCap:
/// - DAO must have policy "UpgradeCap:Custodian" pointing to Security Council
/// - DAO executable contains custody action or DAO's approval
/// - Council executable contains ApproveUpgradeCapAction with matching params
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
    // Extract Council's generic approval for the UpgradeCap
    let approval: &security_council_actions::ApproveGenericAction =
        coexec_common::extract_action(&mut council_exec, version::current());
    let (dao_id, action_type, resource_key, metadata, expires_at) =
        security_council_actions::get_approve_generic_params(approval);
    
    // Validate action type
    assert!(*action_type == b"custody_accept".to_string(), coexec_common::error_action_type_mismatch());
    assert!(resource_key.bytes().length() >= 11 && 
            // Check if resource_key starts with "UpgradeCap:"
            {
                let key_bytes = resource_key.bytes();
                let mut i = 0;
                let mut matches = true;
                let prefix = b"UpgradeCap:";
                while (i < 11 && i < key_bytes.length()) {
                    if (*key_bytes.borrow(i) != *prefix.borrow(i)) {
                        matches = false;
                        break
                    };
                    i = i + 1;
                };
                matches && key_bytes.length() >= 11
            }, 
            EPackageNameMismatch);
    
    // Extract package_name from metadata
    // metadata should be: ["package_name", <name>]
    assert!(metadata.length() == 2, coexec_common::error_metadata_missing());
    assert!(*metadata.borrow(0) == b"package_name".to_string(), coexec_common::error_metadata_missing());
    let pkg_name_expected = metadata.borrow(1);
    
    // Validate basic requirements
    assert!(dao_id == object::id(dao), coexec_common::error_dao_mismatch());
    assert!(clock.timestamp_ms() < expires_at, coexec_common::error_expired());
    
    // Verify council is the UpgradeCap custodian
    coexec_common::enforce_custodian_policy(dao, council, b"UpgradeCap:Custodian".to_string());
    
    // Extract the accept action to get the cap
    let accept: &custody_actions::AcceptIntoCustodyAction<UpgradeCap> =
        coexec_common::extract_action(
            &mut futarchy_exec,
            version::current()
        );
    let (cap_id_expected, pkg_name_council_ref, _) =
        custody_actions::get_accept_params(accept);
    
    // Validate package names match
    assert!(*pkg_name_expected == *pkg_name_council_ref, EPackageNameMismatch);
    
    // Withdraw the cap from the receipt and lock it into the council
    let cap = owned::do_withdraw(
        &mut futarchy_exec,
        dao,
        cap_receipt,
        version::current()
    );
    
    // Strong object identity check
    assert!(object::id(&cap) == cap_id_expected, EWrongCapObject);
    
    // Lock the cap under council management
    let auth = security_council::authenticate(council, ctx);
    package_upgrade::lock_cap(auth, council, cap, *pkg_name_expected, 0);
    
    // Record the council approval for this intent
    let intent_key = executable::intent(&futarchy_exec).key();
    let generic_approval = futarchy_config::new_custody_approval(
        object::id(dao),
        *resource_key,
        cap_id_expected,
        expires_at,
        ctx
    );
    futarchy_config::record_council_approval_generic(
        dao,
        intent_key,
        generic_approval,
        clock,
        ctx
    );
    
    // Confirm both executables atomically
    coexec_common::confirm_both_executables(dao, council, futarchy_exec, council_exec);
}