module futarchy::security_council_intents;

use std::{string::String, option::{Self, Option}};
use sui::{
    package::{UpgradeCap, UpgradeTicket, UpgradeReceipt},
    clock::Clock,
    object::{Self, ID},
    transfer::{Self, Receiving},
    tx_context::TxContext,
};
use account_protocol::{
    account::{Self, Account, Auth},
    intents::{Intent, Params, Expired},
    executable::Executable,
    intent_interface, // macros
    owned,            // withdraw/delete_withdraw
    account as account_protocol_account,
};
use fun intent_interface::build_intent as Account.build_intent;

use futarchy::{
    version,
    security_council,
    security_council_actions::{Self, UpdateCouncilMembershipAction, CreateSecurityCouncilAction},
    custody_actions,
    weighted_multisig::{Self as multisig, WeightedMultisig, Approvals},
    futarchy_config::{Self, FutarchyConfig, FutarchyOutcome},
    policy_registry,
};
use account_actions::package_upgrade;
use account_extensions::extensions::Extensions;

// witnesses
public struct RequestPackageUpgradeIntent has copy, drop {}
public struct AcceptUpgradeCapIntent has copy, drop {}

public struct RequestOAPolicyChangeIntent has copy, drop {}
public struct UpdateCouncilMembershipIntent has copy, drop {}
public struct CreateSecurityCouncilIntent has copy, drop {}
public struct ApprovePolicyChangeIntent has copy, drop {}

public fun request_package_upgrade(
    security_council: &mut Account<WeightedMultisig>,
    auth_from_futarchy_dao: Auth,
    params: Params,
    package_name: String,
    digest: vector<u8>,
    ctx: &mut TxContext
) {
    security_council.verify(auth_from_futarchy_dao);
    let outcome: Approvals = multisig::new_approvals(security_council.config());

    security_council.build_intent!(
        params,
        outcome,
        b"package_upgrade".to_string(),
        version::current(),
        RequestPackageUpgradeIntent{}, // <-- braces
        ctx,
        |intent, iw| {
            package_upgrade::new_upgrade(intent, package_name, digest, iw);
            package_upgrade::new_commit(intent, package_name, iw);
        }
    );
}

public fun execute_upgrade_request(
    executable: &mut Executable<Approvals>,
    security_council: &mut Account<WeightedMultisig>,
    clock: &Clock,
): UpgradeTicket {
    package_upgrade::do_upgrade(
        executable,
        security_council,
        clock,
        version::current(),
        RequestPackageUpgradeIntent{} // <-- braces
    )
}

public fun execute_commit_request(
    mut executable: Executable<Approvals>,
    security_council: &mut Account<WeightedMultisig>,
    receipt: UpgradeReceipt,
) {
    package_upgrade::do_commit(
        &mut executable,
        security_council,
        receipt,
        version::current(),
        RequestPackageUpgradeIntent{} // <-- braces
    );
    security_council.confirm_execution(executable);
}

/// A council member proposes an intent to accept an UpgradeCap into custody.
/// The object will be delivered as Receiving<UpgradeCap> at execution time.
public fun request_accept_and_lock_cap(
    security_council: &mut Account<WeightedMultisig>,
    auth_from_member: Auth,
    params: Params,
    cap_id: ID,
    package_name: String, // used as resource_key
    ctx: &mut TxContext
) {
    use account_protocol::account;

    security_council.verify(auth_from_member);
    let outcome: Approvals = multisig::new_approvals(security_council.config());

    // Manual intent creation to avoid borrow conflict with owned::new_withdraw
    let mut intent = account::create_intent(
        security_council,           // &Account
        params,
        outcome,
        b"accept_custody".to_string(),
        version::current(),
        AcceptUpgradeCapIntent{},    // witness
        ctx
    );

    // now it's safe to borrow &mut security_council to lock the object
    owned::new_withdraw(&mut intent, security_council, cap_id, AcceptUpgradeCapIntent{});
    
    // Use generic custody accept action
    {
        let resource_key = package_name; // resource identifier
        let action = custody_actions::new_accept_into_custody<UpgradeCap>(
            cap_id,
            resource_key,
            b"".to_string()   // optional context
        );
        intent.add_action(
            action,
            AcceptUpgradeCapIntent{}
        );
    };

    // insert it back
    account::insert_intent(security_council, intent, version::current(), AcceptUpgradeCapIntent{});
}

/// Execute accept and lock cap with optional DAO enforcement
public fun execute_accept_and_lock_cap(
    mut executable: Executable<Approvals>,
    security_council: &mut Account<WeightedMultisig>,
    cap_receipt: Receiving<UpgradeCap>,
    ctx: &mut TxContext
) {
    // Keep this for non-coexec single-side accept+lock (no DAO policy enforced).
    // It now expects the new custody action instead of the legacy one.
    let cap = owned::do_withdraw(&mut executable, security_council, cap_receipt, AcceptUpgradeCapIntent{});
    let action: &custody_actions::AcceptIntoCustodyAction<UpgradeCap> =
        executable.next_action(AcceptUpgradeCapIntent{});
    let (_cap_id, pkg_name_ref, _ctx_ref) = custody_actions::get_accept_params(action);
    let auth = security_council::authenticate(security_council, ctx);
    package_upgrade::lock_cap(auth, security_council, cap, *pkg_name_ref, 0);
    security_council.confirm_execution(executable);
}

/// Execute accept and lock cap with optional DAO enforcement
/// If dao is provided, checks if "UpgradeCap:Custodian" policy is set
/// If policy is set, aborts and instructs to use upgrade_cap_coexec instead
public fun execute_accept_and_lock_cap_with_dao_check(
    dao: &Account<FutarchyConfig>,
    mut executable: Executable<Approvals>,
    security_council: &mut Account<WeightedMultisig>,
    cap_receipt: Receiving<UpgradeCap>,
    ctx: &mut TxContext
) {
    // Check if DAO has UpgradeCap:Custodian policy set
    let reg = policy_registry::borrow_registry(dao, version::current());
    let key = b"UpgradeCap:Custodian".to_string();
    if (policy_registry::has_policy(reg, key)) {
        // If policy is set, enforce use of co-execution path
        abort 100 // ERequiresCoExecution - must use upgrade_cap_coexec::execute_accept_and_lock_with_council
    };
    
    // If no policy, proceed with regular execution
    execute_accept_and_lock_cap(executable, security_council, cap_receipt, ctx)
}

// Cleanup for “accept and lock cap” (must unlock the object via the Account)
public fun delete_accept_upgrade_cap(
    expired: &mut Expired,
    security_council: &mut Account<WeightedMultisig>
) {
    owned::delete_withdraw(expired, security_council); // <-- pass account too
    custody_actions::delete_accept_into_custody<UpgradeCap>(expired);
}

/// A council member proposes an intent to update the council's own membership.
public fun request_update_council_membership(
    security_council: &mut Account<WeightedMultisig>,
    auth_from_member: Auth,
    params: Params,
    new_members: vector<address>,
    new_weights: vector<u64>,
    new_threshold: u64,
    ctx: &mut TxContext
) {
    security_council.verify(auth_from_member);
    let outcome: Approvals = multisig::new_approvals(security_council.config());

    security_council.build_intent!(
        params,
        outcome,
        b"update_council_membership".to_string(),
        version::current(),
        UpdateCouncilMembershipIntent{},
        ctx,
        |intent, iw| {
            let action = security_council_actions::new_update_council_membership(
                new_members,
                new_weights,
                new_threshold
            );
            intent.add_action(action, iw);
        }
    );
}

/// After council approval, this executes the membership update.
public fun execute_update_council_membership(
    mut executable: Executable<Approvals>,
    security_council: &mut Account<WeightedMultisig>,
) {
    let action: &UpdateCouncilMembershipAction = executable.next_action(UpdateCouncilMembershipIntent{});
    let (new_members, new_weights, new_threshold) =
        security_council_actions::get_update_council_membership_params(action);

    // Get mutable access to the account's config
    let config_mut = account_protocol_account::config_mut(
        security_council,
        version::current(),
        security_council::witness()
    );

    // Use the weighted_multisig's update_membership function
    multisig::update_membership(
        config_mut,
        *new_members,
        *new_weights,
        new_threshold
    );

    security_council.confirm_execution(executable);
}

// === Create Security Council (DAO-side intent) ===

/// DAO proposes creation of a Security Council; optionally registers it as OA custodian.
public fun request_create_security_council(
    dao: &mut Account<FutarchyConfig>,
    params: Params,
    outcome: FutarchyOutcome,
    members: vector<address>,
    weights: vector<u64>,
    threshold: u64,
    set_as_oa_custodian: bool,
    ctx: &mut TxContext
) {
    dao.build_intent!(
        params,
        outcome,
        b"create_security_council".to_string(),
        version::current(),
        CreateSecurityCouncilIntent{},
        ctx,
        |intent, iw| {
            let action = security_council_actions::new_create_council(
                members,
                weights,
                threshold,
                set_as_oa_custodian
            );
            intent.add_action(action, iw);
        }
    );
}

/// Execute the council creation with a provided Extensions registry.
/// Creates the council, shares it, and optionally sets OA:Custodian policy.
public fun execute_create_security_council(
    dao: &mut Account<FutarchyConfig>,
    extensions: &Extensions,
    mut executable: Executable<FutarchyOutcome>,
    ctx: &mut TxContext
) {
    let action: &CreateSecurityCouncilAction = executable.next_action(CreateSecurityCouncilIntent{});
    let (members, weights, threshold, set_oa) =
        security_council_actions::get_create_council_params(action);

    // Build council account
    let council = security_council::new(
        extensions,
        *members,
        *weights,
        threshold,
        ctx
    );
    let council_id = object::id(&council);
    transfer::public_share_object(council);

    // Optionally set OA:Custodian policy to this council
    if (set_oa) {
        let dao_id = object::id(dao);
        let reg = policy_registry::borrow_registry_mut(dao, version::current());
        policy_registry::set_policy(
            reg,
            dao_id,
            b"OA:Custodian".to_string(),
            council_id,
            b"SecurityCouncil".to_string()
        );
    };

    // Confirm DAO-side execution
    dao.confirm_execution(executable);
}

// === Policy Change Approval (Council-side intent) ===

/// Council member proposes approval of a critical policy removal
public fun request_approve_policy_removal(
    security_council: &mut Account<WeightedMultisig>,
    auth_from_member: Auth,
    params: Params,
    dao_id: ID,
    resource_key: String,
    expires_at: u64,
    ctx: &mut TxContext
) {
    security_council.verify(auth_from_member);
    let outcome: Approvals = multisig::new_approvals(security_council.config());
    
    security_council.build_intent!(
        params,
        outcome,
        b"approve_policy_removal".to_string(),
        version::current(),
        ApprovePolicyChangeIntent{},
        ctx,
        |intent, iw| {
            let action = security_council_actions::new_approve_policy_change(
                dao_id,
                resource_key,
                0, // ACTION_TYPE_REMOVE
                option::none(),
                option::none(),
                expires_at
            );
            intent.add_action(action, iw);
        }
    );
}

/// Council member proposes approval of a critical policy set/update
public fun request_approve_policy_set(
    security_council: &mut Account<WeightedMultisig>,
    auth_from_member: Auth,
    params: Params,
    dao_id: ID,
    resource_key: String,
    policy_account_id: ID,
    intent_key_prefix: String,
    expires_at: u64,
    ctx: &mut TxContext
) {
    security_council.verify(auth_from_member);
    let outcome: Approvals = multisig::new_approvals(security_council.config());
    
    security_council.build_intent!(
        params,
        outcome,
        b"approve_policy_set".to_string(),
        version::current(),
        ApprovePolicyChangeIntent{},
        ctx,
        |intent, iw| {
            let action = security_council_actions::new_approve_policy_change(
                dao_id,
                resource_key,
                1, // ACTION_TYPE_SET
                option::some(policy_account_id),
                option::some(intent_key_prefix),
                expires_at
            );
            intent.add_action(action, iw);
        }
    );
}

/// Execute the approved policy change intent
public fun execute_approve_policy_change(
    mut executable: Executable<Approvals>,
    security_council: &mut Account<WeightedMultisig>,
) {
    // The action is consumed when used with policy_registry_coexec
    // This just confirms the executable was properly used
    security_council.confirm_execution(executable);
}

// Optional no-ops for symmetry
public fun delete_request_package_upgrade(_expired: &mut Expired) {}
public fun delete_request_oa_policy_change(_expired: &mut Expired) {}
public fun delete_update_council_membership(expired: &mut Expired) {
    security_council_actions::delete_update_council_membership(expired);
}
public fun delete_create_council(expired: &mut Expired) {
    security_council_actions::delete_create_council(expired);
}
public fun delete_approve_policy_change(expired: &mut Expired) {
    security_council_actions::delete_approve_policy_change(expired);
}