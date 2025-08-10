module futarchy::security_council_intents;

use std::string::String;
use sui::{
    package::{UpgradeCap, UpgradeTicket, UpgradeReceipt},
    clock::Clock,
    object::ID,
    transfer::Receiving,
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
    security_council_actions::{Self, AcceptAndLockUpgradeCapAction, UpdateCouncilMembershipAction},
    weighted_multisig::{Self as multisig, WeightedMultisig, Approvals},
};
use account_actions::package_upgrade;

// witnesses
public struct RequestPackageUpgradeIntent has copy, drop {}
public struct AcceptUpgradeCapIntent has copy, drop {}
public struct RequestOAPolicyChangeIntent has copy, drop {}
public struct UpdateCouncilMembershipIntent has copy, drop {}

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

public fun request_accept_and_lock_cap(
    security_council: &mut Account<WeightedMultisig>,
    auth_from_member: Auth,
    params: Params,
    cap_id: ID,
    package_name: String,
    delay_ms: u64,
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
        b"access_control".to_string(),
        version::current(),
        AcceptUpgradeCapIntent{},    // witness
        ctx
    );

    // now it's safe to borrow &mut security_council to lock the object
    owned::new_withdraw(&mut intent, security_council, cap_id, AcceptUpgradeCapIntent{});
    intent.add_action(
        security_council_actions::new_accept_and_lock_cap(cap_id, package_name, delay_ms),
        AcceptUpgradeCapIntent{}
    );

    // insert it back
    account::insert_intent(security_council, intent, version::current(), AcceptUpgradeCapIntent{});
}

public fun execute_accept_and_lock_cap(
    mut executable: Executable<Approvals>,
    security_council: &mut Account<WeightedMultisig>,
    cap_receipt: Receiving<UpgradeCap>,
    ctx: &mut TxContext
) {
    let cap = owned::do_withdraw(
        &mut executable,
        security_council,
        cap_receipt,
        AcceptUpgradeCapIntent{} // <-- braces
    );
    let action: &AcceptAndLockUpgradeCapAction = executable.next_action(AcceptUpgradeCapIntent{}); // <-- braces
    let (_cap_id, name_ref, delay_ms) = security_council_actions::get_accept_and_lock_cap_params(action);
    let auth: Auth = security_council::authenticate(security_council, ctx);
    package_upgrade::lock_cap(auth, security_council, cap, *name_ref, delay_ms);
    security_council.confirm_execution(executable);
}

// Cleanup for “accept and lock cap” (must unlock the object via the Account)
public fun delete_accept_upgrade_cap(
    expired: &mut Expired,
    security_council: &mut Account<WeightedMultisig>
) {
    owned::delete_withdraw(expired, security_council); // <-- pass account too
    security_council_actions::delete_accept_and_lock_cap(expired);
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

// Optional no-ops for symmetry
public fun delete_request_package_upgrade(_expired: &mut Expired) {}
public fun delete_request_oa_policy_change(_expired: &mut Expired) {}
public fun delete_update_council_membership(expired: &mut Expired) {
    security_council_actions::delete_update_council_membership(expired);
}