/// 2-of-2 co-execution for accepting and locking UpgradeCaps (DAO + Security Council).
/// Enforced when DAO sets type policy BorrowAction<UpgradeCap> → council_id in policy_registry.
module futarchy_multisig::upgrade_cap_coexec;

use account_actions::package_upgrade;
use account_protocol::account::{Self, Account};
use account_protocol::executable::{Self, Executable};
use account_protocol::owned;
use futarchy_core::futarchy_config::{Self, FutarchyConfig};
use futarchy_core::version;
use futarchy_multisig::coexec_common;
use futarchy_multisig::security_council;
use futarchy_multisig::security_council_actions;
use futarchy_multisig::weighted_multisig::{Self, WeightedMultisig, Approvals};
use futarchy_vault::custody_actions;
use std::hash;
use std::string::{Self, String};
use std::vector;
use sui::clock::Clock;
use sui::object::{Self, ID};
use sui::package::UpgradeCap;
use sui::transfer::Receiving;
use sui::tx_context::TxContext;

// Error codes
const ECapIdMismatch: u64 = 1001;
const EPackageNameMismatch: u64 = 1002;
const EWrongCapObject: u64 = 1003;
const EWrongActionType: u64 = 1004;

/// Require 2-of-2 for accepting/locking an UpgradeCap:
/// - DAO must have type policy BorrowAction<UpgradeCap> pointing to Security Council
/// - DAO executable contains custody action or DAO's approval
/// - Council executable contains ApproveGenericAction with matching params
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
    use sui::bcs;

    // Extract Council's generic approval for the UpgradeCap
    // Get the action data and deserialize it
    let action_data = coexec_common::get_current_action_data(&council_exec);
    let mut bcs = bcs::new(*action_data);

    // Deserialize ApproveGenericAction fields
    let dao_id = bcs::peel_address(&mut bcs).to_id();
    let action_type_bytes = bcs::peel_vec_u8(&mut bcs);
    let action_type = string::utf8(action_type_bytes);
    let resource_key_bytes = bcs::peel_vec_u8(&mut bcs);
    let resource_key = string::utf8(resource_key_bytes);
    let resource_id_from_council = bcs::peel_address(&mut bcs).to_id(); // Will validate against DAO's cap_id
    let expires_at = bcs::peel_u64(&mut bcs);

    // Deserialize metadata vector
    let metadata_count = bcs::peel_vec_length(&mut bcs);
    let mut metadata = vector::empty<String>();
    let mut i = 0;
    while (i < metadata_count) {
        let meta_bytes = bcs::peel_vec_u8(&mut bcs);
        metadata.push_back(string::utf8(meta_bytes));
        i = i + 1;
    };

    // Advance to next action after extraction
    coexec_common::advance_action(&mut council_exec);

    // Validate action type
    assert!(
        action_type == b"custody_accept".to_string(),
        coexec_common::error_action_type_mismatch(),
    );
    assert!(
        resource_key.bytes().length() >= 11 &&
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
        EPackageNameMismatch,
    );

    // Extract package_name from metadata
    // metadata should be: ["package_name", <name>]
    assert!(metadata.length() == 2, coexec_common::error_metadata_missing());
    assert!(
        *metadata.borrow(0) == b"package_name".to_string(),
        coexec_common::error_metadata_missing(),
    );
    let pkg_name_expected = metadata.borrow(1);

    // === CRITICAL: Data Integrity Check ===
    // NOTE: Unlike coexec_custody.move, we cannot use digest validation here because
    // the two actions are DIFFERENT TYPES:
    // - DAO side: AcceptAndLockUpgradeCapAction { cap_id, package_name }
    // - Council side: ApproveGenericAction { dao_id, action_type, resource_key, metadata, expires_at }
    //
    // Instead, we validate that all KEY PARAMETERS match:
    // 1. cap_id (extracted below from DAO action) == cap_id_expected (from council approval)
    // 2. package_name (extracted below from DAO action) == pkg_name_expected (from council metadata)
    // 3. dao_id (from Council action) == actual DAO ID (validated below)
    // 4. expires_at (from Council action) is not expired (validated below)
    //
    // This achieves the same security goal: both parties agree on critical parameters.
    // The parameter validation happens at lines 130-133 (dao_id, expires_at) and
    // lines 142-143 (cap_id, package_name).

    // Validate basic requirements
    assert!(dao_id == object::id(dao), coexec_common::error_dao_mismatch());
    assert!(clock.timestamp_ms() < expires_at, coexec_common::error_expired());

    // Verify council is the UpgradeCap custodian (type-level policy)
    // Checks if BorrowAction<UpgradeCap> policy requires this council
    coexec_common::enforce_custodian_policy_for_type<UpgradeCap>(dao, council);

    // Extract the accept action to get the cap
    // Validate DAO action type for security
    let dao_action_type = coexec_common::get_current_action_type(&futarchy_exec);
    assert!(
        dao_action_type == std::type_name::get<custody_actions::ApproveCustodyAction<UpgradeCap>>(),
        EWrongActionType
    );

    // Get the action data and deserialize it
    let accept_action_data = coexec_common::get_current_action_data(&futarchy_exec);
    let mut accept_bcs = bcs::new(*accept_action_data);

    // Deserialize AcceptAndLockUpgradeCapAction fields
    let cap_id_expected = bcs::peel_address(&mut accept_bcs).to_id();
    let pkg_name_bytes = bcs::peel_vec_u8(&mut accept_bcs);
    let pkg_name_from_accept = string::utf8(pkg_name_bytes);

    // Advance to next action after extraction
    coexec_common::advance_action(&mut futarchy_exec);

    let pkg_name_council_ref = &pkg_name_from_accept;

    // Validate that council's resource_id matches DAO's cap_id
    // This ensures both parties agree on which specific object is being transferred
    assert!(resource_id_from_council == cap_id_expected, ECapIdMismatch);

    // Validate package names match
    assert!(*pkg_name_expected == pkg_name_from_accept, EPackageNameMismatch);

    // Withdraw the cap from the receipt and lock it into the council
    let cap = owned::do_withdraw_object(
        &mut futarchy_exec,
        dao,
        cap_receipt,
        version::current(),
    );

    // Strong object identity check
    assert!(object::id(&cap) == cap_id_expected, EWrongCapObject);

    // Lock the cap under council management
    let auth = security_council::authenticate(council, ctx);
    package_upgrade::lock_cap(auth, council, cap, pkg_name_from_accept, 0);

    // Record the council approval for this intent
    let intent_key = executable::intent(&futarchy_exec).key();
    let generic_approval = futarchy_config::new_custody_approval(
        object::id(dao),
        resource_key,
        cap_id_expected,
        expires_at,
        ctx,
    );
    futarchy_config::record_council_approval_generic(
        dao,
        intent_key,
        generic_approval,
        clock,
        ctx,
    );

    // Confirm both executables atomically
    coexec_common::confirm_both_executables(dao, council, futarchy_exec, council_exec);
}
