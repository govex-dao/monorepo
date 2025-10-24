// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

// Portions of this file are derived from the account.tech Move Framework project.
// Those portions remain licensed under the Apache License, Version 2.0.

module account_actions::package_upgrade_intents;

use account_actions::package_upgrade;
use account_actions::version;
use account_protocol::account::{Account, Auth};
use account_protocol::executable::Executable;
use account_protocol::intent_interface;
use account_protocol::intents::Params;
use account_protocol::package_registry::PackageRegistry;
use std::string::String;
use sui::clock::Clock;
use sui::package::{Self, UpgradeTicket, UpgradeReceipt};

// === Imports ===

// === Aliases ===

use fun intent_interface::build_intent as Account.build_intent;
use fun intent_interface::process_intent as Account.process_intent;

// === Errors ===

const EInvalidPolicy: u64 = 1;
const EPolicyShouldRestrict: u64 = 2;
const ENoLock: u64 = 3;
const ETimeDelay: u64 = 4;

// === Structs ===

/// Intent Witness defining the intent to upgrade a package.
public struct UpgradePackageIntent() has copy, drop;
/// Intent Witness defining the intent to restrict an UpgradeCap.
public struct RestrictPolicyIntent() has copy, drop;
/// Intent Witness defining the intent to create and transfer a commit cap.
public struct CreateCommitCapIntent() has copy, drop;

// === Public Functions ===

/// Creates an UpgradePackageIntent and adds it to an Account.
public fun request_upgrade_package<Config: store, Outcome: store>(
    auth: Auth,
    account: &mut Account,
    registry: &PackageRegistry,
    params: Params,
    outcome: Outcome,
    package_name: String,
    digest: vector<u8>,
    ctx: &mut TxContext,
) {
    account.verify(auth);
    params.assert_single_execution();

    assert!(package_upgrade::has_cap(account, package_name), ENoLock);
    assert!(
        params.execution_times()[0] >= params.creation_time() + package_upgrade::get_time_delay(account, registry, package_name),
        ETimeDelay,
    );

    account.build_intent!(
        registry,
        params,
        outcome,
        package_name,
        version::current(),
        UpgradePackageIntent(),
        ctx,
        |intent, iw| {
            package_upgrade::new_upgrade(intent, package_name, digest, iw);
            package_upgrade::new_commit(intent, package_name, iw);
        },
    );
}

/// Executes an UpgradePackageIntent, returns the UpgradeTicket for upgrading.
public fun execute_upgrade_package<Config: store, Outcome: store>(
    executable: &mut Executable<Outcome>,
    account: &mut Account,
    registry: &PackageRegistry,
    clock: &Clock,
): UpgradeTicket {
    account.process_intent!(
        registry,
        executable,
        version::current(),
        UpgradePackageIntent(),
        |executable, iw| package_upgrade::do_upgrade(
            executable,
            account,
            registry,
            clock,
            version::current(),
            iw,
        ),
    )
}

/// Commits upgrade - DAO-only mode (no commit cap required)
/// Use this when DAO has full control over upgrades OR when reclaim timelock has expired
/// If reclaim is pending, validates that timelock has passed
public fun execute_commit_upgrade_dao_only<Config: store, Outcome: store>(
    executable: &mut Executable<Outcome>,
    account: &mut Account,
    registry: &PackageRegistry,
    receipt: UpgradeReceipt,
    clock: &Clock,
) {
    account.process_intent!(
        registry,
        executable,
        version::current(),
        UpgradePackageIntent(),
        |executable, iw| package_upgrade::do_commit_dao_only(
            executable,
            account,
            registry,
            receipt,
            clock,
            version::current(),
            iw,
        ),
    )
}

/// Commits upgrade - Core team mode (requires commit cap)
/// Use this when core team/multisig holds commit authority
public fun execute_commit_upgrade_with_cap<Config: store, Outcome: store>(
    executable: &mut Executable<Outcome>,
    account: &mut Account,
    registry: &PackageRegistry,
    receipt: UpgradeReceipt,
    commit_cap: &package_upgrade::UpgradeCommitCap,
) {
    account.process_intent!(
        registry,
        executable,
        version::current(),
        UpgradePackageIntent(),
        |executable, iw| package_upgrade::do_commit_with_cap(
            executable,
            account,
            registry,
            receipt,
            commit_cap,
            version::current(),
            iw,
        ),
    )
}

/// Creates a RestrictPolicyIntent and adds it to an Account.
public fun request_restrict_policy<Config: store, Outcome: store>(
    auth: Auth,
    account: &mut Account,
    registry: &PackageRegistry,
    params: Params,
    outcome: Outcome,
    package_name: String,
    policy: u8,
    ctx: &mut TxContext,
) {
    account.verify(auth);
    params.assert_single_execution();

    let current_policy = package_upgrade::get_cap_policy(account, registry, package_name);
    assert!(policy > current_policy, EPolicyShouldRestrict);
    assert!(
        policy == package::additive_policy() ||
        policy == package::dep_only_policy() ||
        policy == 255, // make immutable
        EInvalidPolicy,
    );

    account.build_intent!(
        registry,
        params,
        outcome,
        package_name,
        version::current(),
        RestrictPolicyIntent(),
        ctx,
        |intent, iw| package_upgrade::new_restrict(intent, package_name, policy, iw),
    );
}

/// Restricts the upgrade policy.
public fun execute_restrict_policy<Config: store, Outcome: store>(
    executable: &mut Executable<Outcome>,
    account: &mut Account,
    registry: &PackageRegistry,
) {
    account.process_intent!(
        registry,
        executable,
        version::current(),
        RestrictPolicyIntent(),
        |executable, iw| package_upgrade::do_restrict(executable, account, registry, version::current(), iw),
    );
}

/// Creates a CreateCommitCapIntent to give commit authority to a new team via governance
/// This allows the DAO to vote on transferring commit authority and set new reclaim delay
public fun request_create_commit_cap<Config: store, Outcome: store>(
    auth: Auth,
    account: &mut Account,
    registry: &PackageRegistry,
    params: Params,
    outcome: Outcome,
    package_name: String,
    recipient: address,
    new_reclaim_delay_ms: u64,
    ctx: &mut TxContext,
) {
    account.verify(auth);
    params.assert_single_execution();

    assert!(package_upgrade::has_cap(account, package_name), ENoLock);

    account.build_intent!(
        registry,
        params,
        outcome,
        package_name,
        version::current(),
        CreateCommitCapIntent(),
        ctx,
        |intent, iw| package_upgrade::new_create_commit_cap(intent, package_name, recipient, new_reclaim_delay_ms, iw),
    );
}

/// Executes a CreateCommitCapIntent, creating and transferring commit cap to recipient
public fun execute_create_commit_cap<Config: store, Outcome: store>(
    executable: &mut Executable<Outcome>,
    account: &mut Account,
    registry: &PackageRegistry,
    ctx: &mut TxContext,
) {
    account.process_intent!(
        registry,
        executable,
        version::current(),
        CreateCommitCapIntent(),
        |executable, iw| package_upgrade::do_create_commit_cap(
            executable,
            account,
            registry,
            ctx,
            version::current(),
            iw,
        ),
    )
}
