// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

// Portions of this file are derived from the account.tech Move Framework project.
// Those portions remain licensed under the Apache License, Version 2.0.

/// Package managers can lock UpgradeCaps in the account. Caps can't be unlocked, this is to enforce the policies.
/// Any rule can be defined for the upgrade lock. The module provide a timelock rule by default, based on execution time.
/// Upon locking, the user can define an optional timelock corresponding to the minimum delay between an upgrade proposal and its execution.
/// The account can decide to make the policy more restrictive or destroy the Cap, to make the package immutable.

module account_actions::package_upgrade;

// === Imports ===

use std::{
    string::String,
    option::{Self, Option},
};
use sui::{
    package::{Self, UpgradeCap, UpgradeTicket, UpgradeReceipt},
    clock::Clock,
    vec_map::{Self, VecMap},
    bcs::{Self, BCS},
    transfer,
};
use account_protocol::{
    action_validation,
    account::{Account, Auth},
    intents::{Self, Expired, Intent},
    executable::{Self, Executable},
    version_witness::VersionWitness,
    bcs_validation,
};
use account_actions::{
    version,
};

// === Use Fun Aliases ===
// Removed - add_typed_action is now called directly

// === Error ===

const ELockAlreadyExists: u64 = 0;
const EUpgradeTooEarly: u64 = 1;
const EPackageDoesntExist: u64 = 2;
const EUnsupportedActionVersion: u64 = 3;
const ECommitCapMismatch: u64 = 4;
const ENoCommitCap: u64 = 5;
const EReclaimTooEarly: u64 = 6;
const ENoReclaimRequest: u64 = 7;
const ECapRevoked: u64 = 8;
const EReclaimNotExpired: u64 = 9;
const EReclaimPending: u64 = 10;
const EReclaimAlreadyPending: u64 = 11;
const EProposalNotApproved: u64 = 12;
const EProposalNotFound: u64 = 13;
const EDigestMismatch: u64 = 14;

// === Events ===

/// Emitted when DAO requests to reclaim commit cap from external holder
public struct ReclaimRequested has copy, drop {
    package_name: String,
    dao_account: address,
    request_time_ms: u64,
    available_after_ms: u64,
    new_nonce: u256,
}

/// Emitted when DAO finalizes reclaim after timelock expires
public struct ReclaimFinalized has copy, drop {
    package_name: String,
    dao_account: address,
    finalized_at_ms: u64,
    final_nonce: u256,
}

/// Emitted when an UpgradeCommitCap is created
public struct CommitCapCreated has copy, drop {
    package_name: String,
    cap_id: ID,
    recipient: address,
    nonce: u256,
}

/// Emitted when an UpgradeCommitCap is locked in an account
public struct CommitCapLocked has copy, drop {
    package_name: String,
    cap_id: ID,
    account: address,
    nonce: u256,
}

/// Emitted when upgrade is committed using DAO-only mode
public struct UpgradeCommittedDaoOnly has copy, drop {
    package_name: String,
    dao_account: address,
    new_package_addr: address,
}

/// Emitted when upgrade is committed using commit cap
public struct UpgradeCommittedWithCap has copy, drop {
    package_name: String,
    dao_account: address,
    new_package_addr: address,
    cap_nonce: u256,
}

/// Emitted when a commit cap is destroyed and DAO takes immediate control
public struct CommitCapDestroyed has copy, drop {
    package_name: String,
    cap_id: ID,
    destroyed_by: address,
}

/// Emitted when reclaim delay is updated (during cap creation)
public struct ReclaimDelayUpdated has copy, drop {
    package_name: String,
    old_delay_ms: u64,
    new_delay_ms: u64,
    updated_via: address, // Address receiving the new cap
}

/// Emitted when a new upgrade digest is proposed
public struct UpgradeDigestProposed has copy, drop {
    package_name: String,
    digest: vector<u8>,
    proposed_at_ms: u64,
    execution_time_ms: u64,
}

/// Emitted when an upgrade digest is approved by governance
public struct UpgradeDigestApproved has copy, drop {
    package_name: String,
    digest: vector<u8>,
    approved_at_ms: u64,
}

/// Emitted when an approved upgrade is executed (ticket created)
public struct UpgradeTicketCreated has copy, drop {
    package_name: String,
    digest: vector<u8>,
    mode: String, // "dao_only" or "with_cap"
}

/// Emitted when an upgrade is completed (receipt consumed)
public struct UpgradeCompleted has copy, drop {
    package_name: String,
    digest: vector<u8>,
    new_package_addr: address,
    mode: String, // "dao_only" or "with_cap"
}

// === Action Type Markers ===

/// Upgrade package
public struct PackageUpgrade has drop {}
/// Commit upgrade
public struct PackageCommit has drop {}
/// Restrict upgrade policy
public struct PackageRestrict has drop {}
/// Create and transfer commit cap
public struct PackageCreateCommitCap has drop {}

public fun package_upgrade(): PackageUpgrade { PackageUpgrade {} }
public fun package_commit(): PackageCommit { PackageCommit {} }
public fun package_restrict(): PackageRestrict { PackageRestrict {} }
public fun package_create_commit_cap(): PackageCreateCommitCap { PackageCreateCommitCap {} }

// === Structs ===

/// Dynamic Object Field key for the UpgradeCap.
public struct UpgradeCapKey(String) has copy, drop, store;
/// Dynamic field key for the UpgradeRules.
public struct UpgradeRulesKey(String) has copy, drop, store;
/// Dynamic field key for the UpgradeIndex.
public struct UpgradeIndexKey() has copy, drop, store;
/// Dynamic Object Field key for the UpgradeCommitCap.
public struct UpgradeCommitCapKey(String) has copy, drop, store;
/// Dynamic field key for UpgradeProposal (keyed by package_name + digest hash)
public struct UpgradeProposalKey has copy, drop, store {
    package_name: String,
    digest_hash: address, // hash of digest for unique key
}

/// Helper to create UpgradeProposalKey from digest
fun proposal_key(package_name: String, digest: vector<u8>): UpgradeProposalKey {
    use sui::hash;
    let digest_hash = object::id_from_bytes(hash::blake2b256(&digest)).to_address();
    UpgradeProposalKey { package_name, digest_hash }
}

/// Proposal for a package upgrade - stores the digest for governance voting
/// This replaces the hot-potato UpgradeAction pattern
public struct UpgradeProposal has store, drop {
    package_name: String,
    digest: vector<u8>,
    proposed_time_ms: u64,
    execution_time_ms: u64,  // Can't execute before this (timelock)
    approved: bool,
}

/// Capability granting authority to commit package upgrades
/// Held by core team/multisig to restrict who can finalize upgrades
/// valid_nonce must match current commit_nonce in UpgradeRules or cap is revoked
public struct UpgradeCommitCap has key, store {
    id: UID,
    package_name: String,
    valid_nonce: u256,
}

/// Dynamic field wrapper defining an optional timelock.
public struct UpgradeRules has store {
    // minimum delay between proposal and execution
    delay_ms: u64,
    // Optional: timestamp when DAO requested to reclaim commit cap from external holder
    // If Some(timestamp), DAO can reclaim after reclaim_delay_ms has passed
    reclaim_request_time: Option<u64>,
    // Duration in ms before DAO can reclaim commit cap (e.g., 6 months = 15552000000)
    reclaim_delay_ms: u64,
    // Nonce that increments on reclaim request, invalidating existing commit caps
    // Caps must have valid_nonce == commit_nonce to be valid
    commit_nonce: u256,
} 

/// Map tracking the latest upgraded package address for a package name.
public struct UpgradeIndex has store {
    // map of package name to address
    packages_info: VecMap<String, address>,
}

/// DEPRECATED: Old intent-based action structs (DO NOT USE - use digest-based flow instead)
/// These are kept only for the restrict action which still works
public struct RestrictAction has drop, store {
    // name of the package
    name: String,
    // downgrades to this policy
    policy: u8,
}

/// Action for upgrading a package
public struct UpgradeAction has drop, store {
    name: String,
    digest: vector<u8>,
}

/// Action for committing an upgrade
public struct CommitAction has drop, store {
    name: String,
}

/// Action for creating a commit cap
public struct CreateCommitCapAction has drop, store {
    name: String,
    recipient: address,
    new_reclaim_delay_ms: u64,
}

// === Public Functions ===

/// Attaches the UpgradeCap as a Dynamic Object Field to the account.
/// reclaim_delay_ms: Time DAO must wait after requesting reclaim (e.g., 6 months)
public fun lock_cap(
    auth: Auth,
    account: &mut Account,
    cap: UpgradeCap,
    name: String, // name of the package
    delay_ms: u64, // minimum delay between proposal and execution
    reclaim_delay_ms: u64, // delay before DAO can reclaim commit cap
) {
    account.verify(auth);
    assert!(!has_cap(account, name), ELockAlreadyExists);

    if (!account.has_managed_data(UpgradeIndexKey()))
        account.add_managed_data(UpgradeIndexKey(), UpgradeIndex { packages_info: vec_map::empty() }, version::current());

    let upgrade_index_mut: &mut UpgradeIndex = account.borrow_managed_data_mut(UpgradeIndexKey(), version::current());
    upgrade_index_mut.packages_info.insert(name, cap.package().to_address());

    account.add_managed_asset(UpgradeCapKey(name), cap, version::current());
    account.add_managed_data(
        UpgradeRulesKey(name),
        UpgradeRules {
            delay_ms,
            reclaim_request_time: option::none(),
            reclaim_delay_ms,
            commit_nonce: 0,
        },
        version::current()
    );
}

/// Lock upgrade cap during initialization - works on unshared Accounts
/// This function is for use during account creation, before the account is shared.
public(package) fun do_lock_cap_unshared(
    account: &mut Account,
    cap: UpgradeCap,
    name: String,
    delay_ms: u64,
    reclaim_delay_ms: u64,
) {
    assert!(!has_cap(account, name), ELockAlreadyExists);

    if (!account.has_managed_data(UpgradeIndexKey()))
        account.add_managed_data(UpgradeIndexKey(), UpgradeIndex { packages_info: vec_map::empty() }, version::current());

    let upgrade_index_mut: &mut UpgradeIndex = account.borrow_managed_data_mut(UpgradeIndexKey(), version::current());
    upgrade_index_mut.packages_info.insert(name, cap.package().to_address());

    account.add_managed_asset(UpgradeCapKey(name), cap, version::current());
    account.add_managed_data(
        UpgradeRulesKey(name),
        UpgradeRules {
            delay_ms,
            reclaim_request_time: option::none(),
            reclaim_delay_ms,
            commit_nonce: 0,
        },
        version::current()
    );
}

/// Creates an UpgradeCommitCap and locks it in an Account
/// This cap grants authority to commit package upgrades (finalize with UpgradeReceipt)
/// Typically given to core team multisig for security
/// Cap is created with current nonce from UpgradeRules
public fun lock_commit_cap(
    auth: Auth,
    account: &mut Account,
    package_name: String,
    ctx: &mut TxContext,
) {
    account.verify(auth);

    // Get current nonce
    let rules: &UpgradeRules = account.borrow_managed_data(
        UpgradeRulesKey(package_name),
        version::current()
    );
    let current_nonce = rules.commit_nonce;

    let cap_id = object::new(ctx);
    let cap_id_copy = object::uid_to_inner(&cap_id);

    let commit_cap = UpgradeCommitCap {
        id: cap_id,
        package_name,
        valid_nonce: current_nonce,
    };

    account.add_managed_asset(
        UpgradeCommitCapKey(package_name),
        commit_cap,
        version::current()
    );

    sui::event::emit(CommitCapLocked {
        package_name,
        cap_id: cap_id_copy,
        account: account.addr(),
        nonce: current_nonce,
    });
}

/// Lock commit cap during initialization - works on unshared Accounts
public(package) fun do_lock_commit_cap_unshared(
    account: &mut Account,
    package_name: String,
    ctx: &mut TxContext,
) {
    // Get current nonce (should be 0 at init)
    let rules: &UpgradeRules = account.borrow_managed_data(
        UpgradeRulesKey(package_name),
        version::current()
    );
    let current_nonce = rules.commit_nonce;

    let commit_cap = UpgradeCommitCap {
        id: object::new(ctx),
        package_name,
        valid_nonce: current_nonce,
    };

    account.add_managed_asset(
        UpgradeCommitCapKey(package_name),
        commit_cap,
        version::current()
    );
}

/// Creates an UpgradeCommitCap and transfers it to a recipient
/// Use this to give commit authority to an external multisig
/// Cap is created with current nonce - will be invalidated if DAO requests reclaim
/// BLOCKED if reclaim is currently pending (to avoid confusion)
public fun create_and_transfer_commit_cap<Config: store>(
    auth: Auth,
    account: &Account,
    package_name: String,
    recipient: address,
    ctx: &mut TxContext,
) {
    account.verify(auth);

    // Get current nonce
    let rules: &UpgradeRules = account.borrow_managed_data(
        UpgradeRulesKey(package_name),
        version::current()
    );

    // Block cap creation if reclaim is pending
    assert!(option::is_none(&rules.reclaim_request_time), EReclaimPending);

    let current_nonce = rules.commit_nonce;

    let cap_id = object::new(ctx);
    let cap_id_copy = object::uid_to_inner(&cap_id);

    let commit_cap = UpgradeCommitCap {
        id: cap_id,
        package_name,
        valid_nonce: current_nonce,
    };

    sui::event::emit(CommitCapCreated {
        package_name,
        cap_id: cap_id_copy,
        recipient,
        nonce: current_nonce,
    });

    transfer::transfer(commit_cap, recipient);
}

/// Checks if account has a commit cap for a package
public fun has_commit_cap(
    account: &Account,
    package_name: String,
): bool {
    account.has_managed_asset(UpgradeCommitCapKey(package_name))
}

/// Get the package name from an UpgradeCommitCap
public fun commit_cap_package_name(cap: &UpgradeCommitCap): String {
    cap.package_name
}

/// Get the valid nonce from an UpgradeCommitCap
public fun commit_cap_valid_nonce(cap: &UpgradeCommitCap): u256 {
    cap.valid_nonce
}

/// Get the current commit nonce from UpgradeRules
/// This is the nonce that new caps will be created with
/// Existing caps are only valid if their nonce matches this value
public fun get_current_commit_nonce(
    account: &Account,
    package_name: String,
): u256 {
    let rules: &UpgradeRules = account.borrow_managed_data(
        UpgradeRulesKey(package_name),
        version::current()
    );
    rules.commit_nonce
}

/// Returns true if the account has an UpgradeCap for a given package name.
public fun has_cap(
    account: &Account, 
    name: String
): bool {
    account.has_managed_asset(UpgradeCapKey(name))
}

/// Returns the address of the package for a given package name.
public fun get_cap_package(
    account: &Account, 
    name: String
): address {
    account.borrow_managed_asset<UpgradeCapKey, UpgradeCap>(UpgradeCapKey(name), version::current()).package().to_address()
} 

/// Returns the version of the UpgradeCap for a given package name.
public fun get_cap_version(
    account: &Account, 
    name: String
): u64 {
    account.borrow_managed_asset<UpgradeCapKey, UpgradeCap>(UpgradeCapKey(name), version::current()).version()
} 

/// Returns the policy of the UpgradeCap for a given package name.
public fun get_cap_policy(
    account: &Account, 
    name: String
): u8 {
    account.borrow_managed_asset<UpgradeCapKey, UpgradeCap>(UpgradeCapKey(name), version::current()).policy()
} 

/// Returns the timelock of the UpgradeRules for a given package name.
public fun get_time_delay(
    account: &Account,
    name: String
): u64 {
    account.borrow_managed_data<UpgradeRulesKey, UpgradeRules>(UpgradeRulesKey(name), version::current()).delay_ms
}

/// Returns the map of package names to package addresses.
public fun get_packages_info(
    account: &Account
): &VecMap<String, address> {
    &account.borrow_managed_data<UpgradeIndexKey, UpgradeIndex>(UpgradeIndexKey(), version::current()).packages_info
}

/// Returns true if the package is managed by the account.
public fun is_package_managed(
    account: &Account,
    package_addr: address
): bool {
    if (!account.has_managed_data(UpgradeIndexKey())) return false;
    let index: &UpgradeIndex = account.borrow_managed_data(UpgradeIndexKey(), version::current());

    let mut i = 0;
    while (i < index.packages_info.length()) {
        let (_, value) = index.packages_info.get_entry_by_idx(i);
        if (value == package_addr) return true;
        i = i + 1;
    };

    false
}

/// Returns the address of the package for a given package name.
public fun get_package_addr(
    account: &Account,
    package_name: String
): address {
    let index: &UpgradeIndex = account.borrow_managed_data(UpgradeIndexKey(), version::current());
    *index.packages_info.get(&package_name)
}

/// Returns the package name for a given package address.
#[allow(unused_assignment)] // false positive
public fun get_package_name(
    account: &Account,
    package_addr: address
): String {
    let index: &UpgradeIndex = account.borrow_managed_data(UpgradeIndexKey(), version::current());
    let (mut i, mut package_name) = (0, b"".to_string());
    loop {
        let (name, addr) = index.packages_info.get_entry_by_idx(i);
        package_name = *name;
        if (addr == package_addr) break package_name;
        
        i = i + 1;
        if (i == index.packages_info.length()) abort EPackageDoesntExist;
    };
    
    package_name
}

// === Destruction Functions ===

/// Destroy an UpgradeAction after serialization
public fun destroy_upgrade_action(action: UpgradeAction) {
    let UpgradeAction { name: _, digest: _ } = action;
}

/// Destroy a CommitAction after serialization
public fun destroy_commit_action(action: CommitAction) {
    let CommitAction { name: _ } = action;
}

/// Destroy a RestrictAction after serialization
public fun destroy_restrict_action(action: RestrictAction) {
    let RestrictAction { name: _, policy: _ } = action;
}

/// Destroy a CreateCommitCapAction after serialization
public fun destroy_create_commit_cap_action(action: CreateCommitCapAction) {
    let CreateCommitCapAction { name: _, recipient: _, new_reclaim_delay_ms: _ } = action;
}

// Intent functions

/// Creates a new UpgradeAction and adds it to an intent.
public fun new_upgrade<Outcome, IW: drop>(
    intent: &mut Intent<Outcome>,
    name: String,
    digest: vector<u8>,
    intent_witness: IW,
) {
    // Create the action struct
    let action = UpgradeAction { name, digest };

    // Serialize it
    let action_data = bcs::to_bytes(&action);

    // Add to intent with pre-serialized bytes
    intent.add_typed_action(
        package_upgrade(),
        action_data,
        intent_witness
    );

    // Explicitly destroy the action struct
    destroy_upgrade_action(action);
}    

/// Processes an UpgradeAction and returns a UpgradeTicket.
public fun do_upgrade<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account,
    clock: &Clock,
    version_witness: VersionWitness,
    _intent_witness: IW,
): UpgradeTicket {
    executable.intent().assert_is_account(account.addr());

    // Get BCS bytes from ActionSpec
    let specs = executable.intent().action_specs();
    let spec = specs.borrow(executable.action_idx());

    // CRITICAL: Assert that the action type is what we expect
    action_validation::assert_action_type<PackageUpgrade>(spec);

    let action_data = intents::action_spec_data(spec);

    // Check version before deserialization
    let spec_version = intents::action_spec_version(spec);
    assert!(spec_version == 1, EUnsupportedActionVersion);

    // Create BCS reader and deserialize
    let mut reader = bcs::new(*action_data);
    let name = bcs::peel_vec_u8(&mut reader).to_string();
    let digest = bcs::peel_vec_u8(&mut reader);

    // Validate all bytes consumed
    bcs_validation::validate_all_bytes_consumed(reader);

    assert!(
        clock.timestamp_ms() >= executable.intent().creation_time() + get_time_delay(account, name),
        EUpgradeTooEarly
    );

    let cap: &mut UpgradeCap = account.borrow_managed_asset_mut(UpgradeCapKey(name), version_witness);
    let policy = cap.policy();

    // Increment action index
    executable::increment_action_idx(executable);

    cap.authorize_upgrade(policy, digest) // return ticket
}    

/// Deletes an UpgradeAction from an expired intent.
public fun delete_upgrade(expired: &mut Expired) {
    let _spec = intents::remove_action_spec(expired);
    // ActionSpec has drop, automatically cleaned up
}

/// Creates a new CommitAction and adds it to an intent.
public fun new_commit<Outcome, IW: drop>(
    intent: &mut Intent<Outcome>,
    name: String,
    intent_witness: IW,
) {
    // Create the action struct
    let action = CommitAction { name };

    // Serialize it
    let action_data = bcs::to_bytes(&action);

    // Add to intent with pre-serialized bytes
    intent.add_typed_action(
        package_commit(),
        action_data,
        intent_witness
    );

    // Explicitly destroy the action struct
    destroy_commit_action(action);
}    

// must be called after UpgradeAction is processed, there cannot be any other action processed before
/// Commits an upgrade WITHOUT requiring commit cap validation
/// Use this when DAO has full control over upgrades OR when reclaim timelock has expired
/// If a reclaim request is pending, validates that the timelock has expired before allowing DAO-only commit
public fun do_commit_dao_only<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account,
    receipt: UpgradeReceipt,
    clock: &Clock,
    version_witness: VersionWitness,
    _intent_witness: IW,
) {
    executable.intent().assert_is_account(account.addr());

    // Get BCS bytes from ActionSpec
    let specs = executable.intent().action_specs();
    let spec = specs.borrow(executable.action_idx());

    // CRITICAL: Assert that the action type is what we expect
    action_validation::assert_action_type<PackageCommit>(spec);

    let action_data = intents::action_spec_data(spec);

    // Check version before deserialization
    let spec_version = intents::action_spec_version(spec);
    assert!(spec_version == 1, EUnsupportedActionVersion);

    // Create BCS reader and deserialize
    let mut reader = bcs::new(*action_data);
    let _name = bcs::peel_vec_u8(&mut reader).to_string();

    // Validate all bytes consumed
    bcs_validation::validate_all_bytes_consumed(reader);

    // SECURITY: If reclaim request is pending, verify timelock has expired
    let rules: &UpgradeRules = account.borrow_managed_data(
        UpgradeRulesKey(_name),
        version_witness
    );

    if (option::is_some(&rules.reclaim_request_time)) {
        let request_time = *option::borrow(&rules.reclaim_request_time);
        let current_time = clock.timestamp_ms();
        assert!(
            current_time >= request_time + rules.reclaim_delay_ms,
            EReclaimNotExpired
        );
    };
    // If no reclaim request, DAO can commit anytime (pure DAO-only mode)

    let cap_mut: &mut UpgradeCap = account.borrow_managed_asset_mut(UpgradeCapKey(_name), version_witness);
    cap_mut.commit_upgrade(receipt);
    let new_package_addr = cap_mut.package().to_address();

    // update the index with the new package address
    let index_mut: &mut UpgradeIndex = account.borrow_managed_data_mut(UpgradeIndexKey(), version_witness);
    *index_mut.packages_info.get_mut(&_name) = new_package_addr;

    sui::event::emit(UpgradeCommittedDaoOnly {
        package_name: _name,
        dao_account: account.addr(),
        new_package_addr,
    });

    // Increment action index
    executable::increment_action_idx(executable);
}

/// Commits an upgrade WITH commit cap validation
/// Use this when core team holds commit authority
/// Cap must have valid nonce matching current commit_nonce or will be rejected
public fun do_commit_with_cap<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account,
    receipt: UpgradeReceipt,
    commit_cap: &UpgradeCommitCap,
    version_witness: VersionWitness,
    _intent_witness: IW,
) {
    executable.intent().assert_is_account(account.addr());

    // Get BCS bytes from ActionSpec
    let specs = executable.intent().action_specs();
    let spec = specs.borrow(executable.action_idx());

    // CRITICAL: Assert that the action type is what we expect
    action_validation::assert_action_type<PackageCommit>(spec);

    let action_data = intents::action_spec_data(spec);

    // Check version before deserialization
    let spec_version = intents::action_spec_version(spec);
    assert!(spec_version == 1, EUnsupportedActionVersion);

    // Create BCS reader and deserialize
    let mut reader = bcs::new(*action_data);
    let name = bcs::peel_vec_u8(&mut reader).to_string();

    // Validate all bytes consumed
    bcs_validation::validate_all_bytes_consumed(reader);

    // SECURITY: Validate that the commit cap matches the package being upgraded
    assert!(commit_cap.package_name == name, ECommitCapMismatch);

    // SECURITY: Validate that the cap's nonce matches current nonce (not revoked)
    let rules: &UpgradeRules = account.borrow_managed_data(
        UpgradeRulesKey(name),
        version_witness
    );
    assert!(commit_cap.valid_nonce == rules.commit_nonce, ECapRevoked);

    let cap_mut: &mut UpgradeCap = account.borrow_managed_asset_mut(UpgradeCapKey(name), version_witness);
    cap_mut.commit_upgrade(receipt);
    let new_package_addr = cap_mut.package().to_address();

    // update the index with the new package address
    let index_mut: &mut UpgradeIndex = account.borrow_managed_data_mut(UpgradeIndexKey(), version_witness);
    *index_mut.packages_info.get_mut(&name) = new_package_addr;

    sui::event::emit(UpgradeCommittedWithCap {
        package_name: name,
        dao_account: account.addr(),
        new_package_addr,
        cap_nonce: commit_cap.valid_nonce,
    });

    // Increment action index
    executable::increment_action_idx(executable);
}

public fun delete_commit(expired: &mut Expired) {
    let _spec = intents::remove_action_spec(expired);
    // ActionSpec has drop, automatically cleaned up
}

/// Creates a new RestrictAction and adds it to an intent.
public fun new_restrict<Outcome, IW: drop>(
    intent: &mut Intent<Outcome>,
    name: String,
    policy: u8,
    intent_witness: IW,
) {
    // Create the action struct
    let action = RestrictAction { name, policy };

    // Serialize it
    let action_data = bcs::to_bytes(&action);

    // Add to intent with pre-serialized bytes
    intent.add_typed_action(
        package_restrict(),
        action_data,
        intent_witness
    );

    // Explicitly destroy the action struct
    destroy_restrict_action(action);
}    

/// Processes a RestrictAction and updates the UpgradeCap policy.
public fun do_restrict<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account,
    version_witness: VersionWitness,
    _intent_witness: IW,
) {
    executable.intent().assert_is_account(account.addr());

    // Get BCS bytes from ActionSpec
    let specs = executable.intent().action_specs();
    let spec = specs.borrow(executable.action_idx());

    // CRITICAL: Assert that the action type is what we expect
    action_validation::assert_action_type<PackageRestrict>(spec);

    let action_data = intents::action_spec_data(spec);

    // Check version before deserialization
    let spec_version = intents::action_spec_version(spec);
    assert!(spec_version == 1, EUnsupportedActionVersion);

    // Create BCS reader and deserialize
    let mut reader = bcs::new(*action_data);
    let name = bcs::peel_vec_u8(&mut reader).to_string();
    let policy = bcs::peel_u8(&mut reader);

    // Validate all bytes consumed
    bcs_validation::validate_all_bytes_consumed(reader);

    // Defense-in-depth: explicitly validate known policy values
    if (policy == package::additive_policy()) {
        let cap_mut: &mut UpgradeCap = account.borrow_managed_asset_mut(UpgradeCapKey(name), version_witness);
        cap_mut.only_additive_upgrades();
    } else if (policy == package::dep_only_policy()) {
        let cap_mut: &mut UpgradeCap = account.borrow_managed_asset_mut(UpgradeCapKey(name), version_witness);
        cap_mut.only_dep_upgrades();
    } else {
        // Only make immutable for the explicit immutable policy (255)
        // Any other policy value should abort rather than defaulting to immutable
        assert!(policy == 255, EUnsupportedActionVersion); // Reuse error code for invalid policy
        let cap: UpgradeCap = account.remove_managed_asset(UpgradeCapKey(name), version_witness);
        package::make_immutable(cap);
    };

    // Increment action index
    executable::increment_action_idx(executable);
}

/// Deletes a RestrictAction from an expired intent.
public fun delete_restrict(expired: &mut Expired) {
    let _spec = intents::remove_action_spec(expired);
    // ActionSpec has drop, automatically cleaned up
}

/// Creates a new CreateCommitCapAction and adds it to an intent.
public fun new_create_commit_cap<Outcome, IW: drop>(
    intent: &mut Intent<Outcome>,
    name: String,
    recipient: address,
    new_reclaim_delay_ms: u64,
    intent_witness: IW,
) {
    // Create the action struct
    let action = CreateCommitCapAction { name, recipient, new_reclaim_delay_ms };

    // Serialize it
    let action_data = bcs::to_bytes(&action);

    // Add to intent with pre-serialized bytes
    intent.add_typed_action(
        package_create_commit_cap(),
        action_data,
        intent_witness
    );

    // Explicitly destroy the action struct
    destroy_create_commit_cap_action(action);
}

/// Processes a CreateCommitCapAction and creates/transfers the commit cap.
public fun do_create_commit_cap<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account,
    ctx: &mut TxContext,
    version_witness: VersionWitness,
    _intent_witness: IW,
) {
    executable.intent().assert_is_account(account.addr());

    // Get BCS bytes from ActionSpec
    let specs = executable.intent().action_specs();
    let spec = specs.borrow(executable.action_idx());

    // CRITICAL: Assert that the action type is what we expect
    action_validation::assert_action_type<PackageCreateCommitCap>(spec);

    let action_data = intents::action_spec_data(spec);

    // Check version before deserialization
    let spec_version = intents::action_spec_version(spec);
    assert!(spec_version == 1, EUnsupportedActionVersion);

    // Create BCS reader and deserialize
    let mut reader = bcs::new(*action_data);
    let name = bcs::peel_vec_u8(&mut reader).to_string();
    let recipient_bytes = bcs::peel_address(&mut reader);
    let new_reclaim_delay_ms = bcs::peel_u64(&mut reader);

    // Validate all bytes consumed
    bcs_validation::validate_all_bytes_consumed(reader);

    // Get current nonce from rules
    let rules_mut: &mut UpgradeRules = account.borrow_managed_data_mut(
        UpgradeRulesKey(name),
        version_witness
    );

    // Block if reclaim is pending
    assert!(option::is_none(&rules_mut.reclaim_request_time), EReclaimPending);

    let current_nonce = rules_mut.commit_nonce;
    let old_delay_ms = rules_mut.reclaim_delay_ms;

    // Update reclaim delay
    rules_mut.reclaim_delay_ms = new_reclaim_delay_ms;

    // Emit delay update event
    sui::event::emit(ReclaimDelayUpdated {
        package_name: name,
        old_delay_ms,
        new_delay_ms: new_reclaim_delay_ms,
        updated_via: recipient_bytes,
    });

    // Create the commit cap
    let cap_id = object::new(ctx);
    let cap_id_copy = object::uid_to_inner(&cap_id);

    let commit_cap = UpgradeCommitCap {
        id: cap_id,
        package_name: name,
        valid_nonce: current_nonce,
    };

    // Emit event
    sui::event::emit(CommitCapCreated {
        package_name: name,
        cap_id: cap_id_copy,
        recipient: recipient_bytes,
        nonce: current_nonce,
    });

    // Transfer to recipient
    transfer::transfer(commit_cap, recipient_bytes);

    // Increment action index
    executable::increment_action_idx(executable);
}

/// Deletes a CreateCommitCapAction from an expired intent.
public fun delete_create_commit_cap(expired: &mut Expired) {
    let _spec = intents::remove_action_spec(expired);
    // ActionSpec has drop, automatically cleaned up
}

// === Package Funtions ===

/// Borrows the UpgradeCap for a given package address.
public(package) fun borrow_cap<Config: store>(
    account: &Account,
    package_addr: address
): &UpgradeCap {
    let name = get_package_name(account, package_addr);
    account.borrow_managed_asset(UpgradeCapKey(name), version::current())
}

// === Commit Cap Borrow/Return Functions ===
// These enable using the commit cap via the access_control pattern

/// Borrow the commit cap from the account (removes it temporarily)
/// Must be returned in the same transaction using return_commit_cap
public fun borrow_commit_cap<Config: store>(
    account: &mut Account,
    package_name: String,
    version_witness: VersionWitness,
): UpgradeCommitCap {
    account.remove_managed_asset(UpgradeCommitCapKey(package_name), version_witness)
}

/// Return the commit cap to the account after use
public fun return_commit_cap<Config: store>(
    account: &mut Account,
    commit_cap: UpgradeCommitCap,
    version_witness: VersionWitness,
) {
    let package_name = commit_cap.package_name;
    account.add_managed_asset(UpgradeCommitCapKey(package_name), commit_cap, version_witness);
}

/// Create an UpgradeCommitCap for transferring (used in init_actions)
/// This is public(package) as it's only meant for initialization helpers
/// Created with nonce=0 (initial state)
public(package) fun create_commit_cap_for_transfer(
    package_name: String,
    ctx: &mut TxContext,
): UpgradeCommitCap {
    UpgradeCommitCap {
        id: object::new(ctx),
        package_name,
        valid_nonce: 0,
    }
}

/// Transfer commit cap to an address (needed for Sui private transfer rules)
public fun transfer_commit_cap(cap: UpgradeCommitCap, recipient: address) {
    transfer::transfer(cap, recipient);
}

/// Destroys a commit cap and immediately gives DAO full control
/// Anyone holding the cap can call this to destroy it
/// This resets nonce to 0, clears any pending reclaim, giving DAO immediate control
/// Use this when core team wants to hand over control immediately
public fun destroy_commit_cap<Config: store>(
    cap: UpgradeCommitCap,
    account: &mut Account,
    ctx: &TxContext,
) {
    let UpgradeCommitCap { id, package_name, valid_nonce: _ } = cap;
    let cap_id = object::uid_to_inner(&id);
    let destroyed_by = ctx.sender();
    object::delete(id);

    // Reset to DAO-only mode: nonce=0, no reclaim pending
    let rules_mut: &mut UpgradeRules = account.borrow_managed_data_mut(
        UpgradeRulesKey(package_name),
        version::current()
    );

    rules_mut.commit_nonce = 0;
    rules_mut.reclaim_request_time = option::none();

    // Emit event
    sui::event::emit(CommitCapDestroyed {
        package_name,
        cap_id,
        destroyed_by,
    });
}

// === Commit Cap Reclaim Functions ===

/// DAO initiates reclaim of commit cap from external holder
/// Starts the timelock countdown (e.g., 6 months)
/// IMMEDIATELY increments nonce, invalidating all existing commit caps
/// This gives core team notice that DAO wants to reclaim control
public fun request_reclaim_commit_cap<Config: store>(
    auth: Auth,
    account: &mut Account,
    package_name: String,
    clock: &Clock,
) {
    account.verify(auth);

    let dao_account = account.addr();

    let rules_mut: &mut UpgradeRules = account.borrow_managed_data_mut(
        UpgradeRulesKey(package_name),
        version::current()
    );

    // Can only request reclaim if not already pending
    assert!(option::is_none(&rules_mut.reclaim_request_time), EReclaimAlreadyPending);

    // Increment nonce - this IMMEDIATELY invalidates all existing commit caps
    rules_mut.commit_nonce = rules_mut.commit_nonce + 1;

    let current_time = clock.timestamp_ms();
    // Start the reclaim timer
    rules_mut.reclaim_request_time = option::some(current_time);

    sui::event::emit(ReclaimRequested {
        package_name,
        dao_account,
        request_time_ms: current_time,
        available_after_ms: current_time + rules_mut.reclaim_delay_ms,
        new_nonce: rules_mut.commit_nonce,
    });
}

/// Clears the reclaim request after timelock expires (optional cleanup)
/// After timelock expires, DAO can use do_commit_dao_only() without calling this
/// This just clears the reclaim_request_time for cleaner state
/// Can only be called after request_reclaim_commit_cap + reclaim_delay_ms
public fun clear_reclaim_request<Config: store>(
    auth: Auth,
    account: &mut Account,
    package_name: String,
    clock: &Clock,
) {
    account.verify(auth);

    let dao_account = account.addr();

    let rules_mut: &mut UpgradeRules = account.borrow_managed_data_mut(
        UpgradeRulesKey(package_name),
        version::current()
    );

    // Validate reclaim request exists
    assert!(option::is_some(&rules_mut.reclaim_request_time), ENoReclaimRequest);

    let request_time = *option::borrow(&rules_mut.reclaim_request_time);
    let current_time = clock.timestamp_ms();

    // Validate timelock has passed
    assert!(
        current_time >= request_time + rules_mut.reclaim_delay_ms,
        EReclaimTooEarly
    );

    // Clear the reclaim request (nonce stays incremented, caps stay invalid)
    rules_mut.reclaim_request_time = option::none();

    sui::event::emit(ReclaimFinalized {
        package_name,
        dao_account,
        finalized_at_ms: current_time,
        final_nonce: rules_mut.commit_nonce,
    });

    // Note: DAO can now use do_commit_dao_only() since timelock has expired
}

/// Check if a reclaim request is pending
public fun has_reclaim_request(
    account: &Account,
    package_name: String,
): bool {
    let rules: &UpgradeRules = account.borrow_managed_data(
        UpgradeRulesKey(package_name),
        version::current()
    );
    option::is_some(&rules.reclaim_request_time)
}

/// Get the timestamp when reclaim will be available (if request exists)
public fun get_reclaim_available_time(
    account: &Account,
    package_name: String,
): Option<u64> {
    let rules: &UpgradeRules = account.borrow_managed_data(
        UpgradeRulesKey(package_name),
        version::current()
    );

    if (option::is_none(&rules.reclaim_request_time)) {
        return option::none()
    };

    let request_time = *option::borrow(&rules.reclaim_request_time);
    option::some(request_time + rules.reclaim_delay_ms)
}

// === NEW: Digest-Based Upgrade System (Fixes Hot Potato Issue) ===

/// Phase 1: Propose an upgrade digest for governance voting
/// This creates a proposal that can be voted on over time (multi-day)
/// The digest is just data (has `store`), not a hot potato
public fun propose_upgrade_digest(
    auth: Auth,
    account: &mut Account,
    package_name: String,
    digest: vector<u8>,
    execution_time_ms: u64,
    clock: &Clock,
) {
    account.verify(auth);

    // Validate package exists
    assert!(has_cap(account, package_name), EPackageDoesntExist);

    // Validate timelock
    let rules: &UpgradeRules = account.borrow_managed_data(
        UpgradeRulesKey(package_name),
        version::current()
    );
    let current_time = clock.timestamp_ms();
    assert!(
        execution_time_ms >= current_time + rules.delay_ms,
        EUpgradeTooEarly
    );

    // Create proposal
    let proposal = UpgradeProposal {
        package_name,
        digest,
        proposed_time_ms: current_time,
        execution_time_ms,
        approved: false,
    };

    // Store proposal for voting
    account.add_managed_data(
        proposal_key(package_name, digest),
        proposal,
        version::current()
    );

    // Emit event
    sui::event::emit(UpgradeDigestProposed {
        package_name,
        digest,
        proposed_at_ms: current_time,
        execution_time_ms,
    });
}

/// Called by governance system when vote passes
/// Marks the digest as approved for execution
public fun approve_upgrade_proposal<Config: store>(
    auth: Auth,
    account: &mut Account,
    package_name: String,
    digest: vector<u8>,
    clock: &Clock,
) {
    account.verify(auth);

    let proposal: &mut UpgradeProposal = account.borrow_managed_data_mut(
        proposal_key(package_name, digest),
        version::current()
    );

    proposal.approved = true;

    // Emit event
    sui::event::emit(UpgradeDigestApproved {
        package_name,
        digest,
        approved_at_ms: clock.timestamp_ms(),
    });
}

/// Phase 2a: Execute approved upgrade atomically (DAO-only mode)
/// This creates the UpgradeTicket (hot potato) which MUST be consumed in same PTB
/// Returns ticket that caller must immediately consume via sui upgrade command
public fun execute_approved_upgrade_dao_only<Config: store>(
    account: &mut Account,
    package_name: String,
    digest: vector<u8>,
    clock: &Clock,
    version_witness: VersionWitness,
): UpgradeTicket {
    // 1. Validate proposal exists and is approved
    let proposal: &UpgradeProposal = account.borrow_managed_data(
        proposal_key(package_name, digest),
        version_witness
    );
    assert!(proposal.approved, EProposalNotApproved);

    // 2. Validate execution time
    let current_time = clock.timestamp_ms();
    assert!(current_time >= proposal.execution_time_ms, EUpgradeTooEarly);

    // 3. Check reclaim logic (if applicable)
    let rules: &UpgradeRules = account.borrow_managed_data(
        UpgradeRulesKey(package_name),
        version_witness
    );
    if (option::is_some(&rules.reclaim_request_time)) {
        let request_time = *option::borrow(&rules.reclaim_request_time);
        assert!(
            current_time >= request_time + rules.reclaim_delay_ms,
            EReclaimNotExpired
        );
    };

    // 4. Create upgrade ticket (HOT POTATO STARTS HERE!)
    let cap: &mut UpgradeCap = account.borrow_managed_asset_mut(
        UpgradeCapKey(package_name),
        version_witness
    );
    let policy = cap.policy();
    let ticket = cap.authorize_upgrade(policy, digest);

    // Emit event
    sui::event::emit(UpgradeTicketCreated {
        package_name,
        digest,
        mode: b"dao_only".to_string(),
    });

    // Return ticket - caller MUST consume in same PTB!
    ticket
}

/// Phase 2b: Complete the upgrade by consuming the receipt (DAO-only mode)
/// This MUST be called in same PTB after sui upgrade command
public fun complete_approved_upgrade_dao_only<Config: store>(
    account: &mut Account,
    package_name: String,
    digest: vector<u8>,
    receipt: UpgradeReceipt,
    version_witness: VersionWitness,
) {
    // Validate this matches an approved upgrade
    let proposal: &UpgradeProposal = account.borrow_managed_data(
        proposal_key(package_name, digest),
        version_witness
    );
    assert!(proposal.approved, EProposalNotApproved);

    // Validate digest matches receipt
    assert!(receipt.package() == get_cap_package(account, package_name).to_id(), EDigestMismatch);

    // Commit the upgrade
    let cap: &mut UpgradeCap = account.borrow_managed_asset_mut(
        UpgradeCapKey(package_name),
        version_witness
    );
    cap.commit_upgrade(receipt);

    // Update package index
    let new_addr = cap.package().to_address();
    let index: &mut UpgradeIndex = account.borrow_managed_data_mut(
        UpgradeIndexKey(),
        version_witness
    );
    *index.packages_info.get_mut(&package_name) = new_addr;

    // Clean up proposal
    let _removed_proposal: UpgradeProposal = account.remove_managed_data(
        proposal_key(package_name, digest),
        version_witness
    );

    // Emit event
    sui::event::emit(UpgradeCompleted {
        package_name,
        digest,
        new_package_addr: new_addr,
        mode: b"dao_only".to_string(),
    });
}

/// Phase 2a: Execute approved upgrade atomically (with commit cap)
/// This requires the commit cap to be provided, validating nonce
public fun execute_approved_upgrade_with_cap<Config: store>(
    account: &mut Account,
    package_name: String,
    digest: vector<u8>,
    commit_cap: &UpgradeCommitCap,
    clock: &Clock,
    version_witness: VersionWitness,
): UpgradeTicket {
    // 1. Validate proposal exists and is approved
    let proposal: &UpgradeProposal = account.borrow_managed_data(
        proposal_key(package_name, digest),
        version_witness
    );
    assert!(proposal.approved, EProposalNotApproved);

    // 2. Validate execution time
    assert!(clock.timestamp_ms() >= proposal.execution_time_ms, EUpgradeTooEarly);

    // 3. Validate commit cap
    assert!(commit_cap.package_name == package_name, ECommitCapMismatch);
    let rules: &UpgradeRules = account.borrow_managed_data(
        UpgradeRulesKey(package_name),
        version_witness
    );
    assert!(commit_cap.valid_nonce == rules.commit_nonce, ECapRevoked);

    // 4. Create upgrade ticket
    let cap: &mut UpgradeCap = account.borrow_managed_asset_mut(
        UpgradeCapKey(package_name),
        version_witness
    );
    let policy = cap.policy();
    let ticket = cap.authorize_upgrade(policy, digest);

    // Emit event
    sui::event::emit(UpgradeTicketCreated {
        package_name,
        digest,
        mode: b"with_cap".to_string(),
    });

    ticket
}

/// Phase 2b: Complete the upgrade by consuming the receipt (with commit cap)
public fun complete_approved_upgrade_with_cap<Config: store>(
    account: &mut Account,
    package_name: String,
    digest: vector<u8>,
    receipt: UpgradeReceipt,
    commit_cap: &UpgradeCommitCap,
    version_witness: VersionWitness,
) {
    // Validate proposal
    let proposal: &UpgradeProposal = account.borrow_managed_data(
        proposal_key(package_name, digest),
        version_witness
    );
    assert!(proposal.approved, EProposalNotApproved);

    // Validate commit cap again (defense in depth)
    assert!(commit_cap.package_name == package_name, ECommitCapMismatch);
    let rules: &UpgradeRules = account.borrow_managed_data(
        UpgradeRulesKey(package_name),
        version_witness
    );
    assert!(commit_cap.valid_nonce == rules.commit_nonce, ECapRevoked);

    // Commit upgrade
    let cap: &mut UpgradeCap = account.borrow_managed_asset_mut(
        UpgradeCapKey(package_name),
        version_witness
    );
    cap.commit_upgrade(receipt);

    // Update package index
    let new_addr = cap.package().to_address();
    let index: &mut UpgradeIndex = account.borrow_managed_data_mut(
        UpgradeIndexKey(),
        version_witness
    );
    *index.packages_info.get_mut(&package_name) = new_addr;

    // Clean up proposal
    let _removed_proposal: UpgradeProposal = account.remove_managed_data(
        proposal_key(package_name, digest),
        version_witness
    );

    // Emit event
    sui::event::emit(UpgradeCompleted {
        package_name,
        digest,
        new_package_addr: new_addr,
        mode: b"with_cap".to_string(),
    });
}

/// Check if a specific upgrade digest proposal exists
public fun has_upgrade_proposal(
    account: &Account,
    package_name: String,
    digest: vector<u8>,
): bool {
    account.has_managed_data(proposal_key(package_name, digest))
}

/// Check if a specific upgrade digest is approved
public fun is_upgrade_approved(
    account: &Account,
    package_name: String,
    digest: vector<u8>,
): bool {
    if (!has_upgrade_proposal(account, package_name, digest)) {
        return false
    };

    let proposal: &UpgradeProposal = account.borrow_managed_data(
        proposal_key(package_name, digest),
        version::current()
    );
    proposal.approved
}

/// Get upgrade proposal details
public fun get_upgrade_proposal(
    account: &Account,
    package_name: String,
    digest: vector<u8>,
): (vector<u8>, u64, u64, bool) {
    let proposal: &UpgradeProposal = account.borrow_managed_data(
        proposal_key(package_name, digest),
        version::current()
    );
    (proposal.digest, proposal.proposed_time_ms, proposal.execution_time_ms, proposal.approved)
}
