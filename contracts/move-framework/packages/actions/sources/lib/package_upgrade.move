// ============================================================================
// FORK MODIFICATION NOTICE - Package Upgrade with Serialize-Then-Destroy Pattern
// ============================================================================
// This module manages UpgradeCap operations with timelock for Account.
//
// CHANGES IN THIS FORK:
// - Actions use type markers: PackageUpgrade, PackageCommit, PackageRestrict
// - Implemented serialize-then-destroy pattern for all 3 action types
// - Added destruction functions: destroy_upgrade_action, destroy_commit_action, destroy_restrict_action
// - Actions serialize to bytes before adding to intent via add_typed_action()
// - Enhanced BCS validation: version checks + validate_all_bytes_consumed
// - Type-safe action validation through compile-time TypeName comparison
// ============================================================================
/// Package managers can lock UpgradeCaps in the account. Caps can't be unlocked, this is to enforce the policies.
/// Any rule can be defined for the upgrade lock. The module provide a timelock rule by default, based on execution time.
/// Upon locking, the user can define an optional timelock corresponding to the minimum delay between an upgrade proposal and its execution.
/// The account can decide to make the policy more restrictive or destroy the Cap, to make the package immutable.

module account_actions::package_upgrade;

// === Imports ===

use std::string::String;
use sui::{
    package::{Self, UpgradeCap, UpgradeTicket, UpgradeReceipt},
    clock::Clock,
    vec_map::{Self, VecMap},
    bcs::{Self, BCS},
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
use account_extensions::framework_action_types::{Self, PackageUpgrade, PackageCommit, PackageRestrict};

// === Use Fun Aliases ===
// Removed - add_typed_action is now called directly

// === Error ===

const ELockAlreadyExists: u64 = 0;
const EUpgradeTooEarly: u64 = 1;
const EPackageDoesntExist: u64 = 2;
const EUnsupportedActionVersion: u64 = 3;

// === Structs ===

/// Dynamic Object Field key for the UpgradeCap.
public struct UpgradeCapKey(String) has copy, drop, store;
/// Dynamic field key for the UpgradeRules.
public struct UpgradeRulesKey(String) has copy, drop, store;
/// Dynamic field key for the UpgradeIndex.
public struct UpgradeIndexKey() has copy, drop, store;

/// Dynamic field wrapper defining an optional timelock.
public struct UpgradeRules has store {
    // minimum delay between proposal and execution
    delay_ms: u64,
} 

/// Map tracking the latest upgraded package address for a package name.
public struct UpgradeIndex has store {
    // map of package name to address
    packages_info: VecMap<String, address>,
}

/// Action to upgrade a package using a locked UpgradeCap.
public struct UpgradeAction has drop, store {
    // name of the package
    name: String,
    // digest of the package build we want to publish
    digest: vector<u8>,
}
/// Action to commit an upgrade.
public struct CommitAction has drop, store {
    // name of the package
    name: String,
}
/// Action to restrict the policy of a locked UpgradeCap.
public struct RestrictAction has drop, store {
    // name of the package
    name: String,
    // downgrades to this policy
    policy: u8,
}

// === Public Functions ===

/// Attaches the UpgradeCap as a Dynamic Object Field to the account.
public fun lock_cap<Config>(
    auth: Auth,
    account: &mut Account<Config>,
    cap: UpgradeCap,
    name: String, // name of the package
    delay_ms: u64, // minimum delay between proposal and execution
) {
    account.verify(auth);
    assert!(!has_cap(account, name), ELockAlreadyExists);

    if (!account.has_managed_data(UpgradeIndexKey()))
        account.add_managed_data(UpgradeIndexKey(), UpgradeIndex { packages_info: vec_map::empty() }, version::current());

    let upgrade_index_mut: &mut UpgradeIndex = account.borrow_managed_data_mut(UpgradeIndexKey(), version::current());
    upgrade_index_mut.packages_info.insert(name, cap.package().to_address());
    
    account.add_managed_asset(UpgradeCapKey(name), cap, version::current());
    account.add_managed_data(UpgradeRulesKey(name), UpgradeRules { delay_ms }, version::current());
}

/// Returns true if the account has an UpgradeCap for a given package name.
public fun has_cap<Config>(
    account: &Account<Config>, 
    name: String
): bool {
    account.has_managed_asset(UpgradeCapKey(name))
}

/// Returns the address of the package for a given package name.
public fun get_cap_package<Config>(
    account: &Account<Config>, 
    name: String
): address {
    account.borrow_managed_asset<_, _, UpgradeCap>(UpgradeCapKey(name), version::current()).package().to_address()
} 

/// Returns the version of the UpgradeCap for a given package name.
public fun get_cap_version<Config>(
    account: &Account<Config>, 
    name: String
): u64 {
    account.borrow_managed_asset<_, _, UpgradeCap>(UpgradeCapKey(name), version::current()).version()
} 

/// Returns the policy of the UpgradeCap for a given package name.
public fun get_cap_policy<Config>(
    account: &Account<Config>, 
    name: String
): u8 {
    account.borrow_managed_asset<_, _, UpgradeCap>(UpgradeCapKey(name), version::current()).policy()
} 

/// Returns the timelock of the UpgradeRules for a given package name.
public fun get_time_delay<Config>(
    account: &Account<Config>, 
    name: String
): u64 {
    account.borrow_managed_data<_, _, UpgradeRules>(UpgradeRulesKey(name), version::current()).delay_ms
}

/// Returns the map of package names to package addresses.
public fun get_packages_info<Config>(
    account: &Account<Config>
): &VecMap<String, address> {
    &account.borrow_managed_data<_, _, UpgradeIndex>(UpgradeIndexKey(), version::current()).packages_info
}

/// Returns true if the package is managed by the account.
public fun is_package_managed<Config>(
    account: &Account<Config>,
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
public fun get_package_addr<Config>(
    account: &Account<Config>,
    package_name: String
): address {
    let index: &UpgradeIndex = account.borrow_managed_data(UpgradeIndexKey(), version::current());
    *index.packages_info.get(&package_name)
}

/// Returns the package name for a given package address.
#[allow(unused_assignment)] // false positive
public fun get_package_name<Config>(
    account: &Account<Config>,
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
        framework_action_types::package_upgrade(),
        action_data,
        intent_witness
    );

    // Explicitly destroy the action struct
    destroy_upgrade_action(action);
}    

/// Processes an UpgradeAction and returns a UpgradeTicket.
public fun do_upgrade<Config, Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<Config>,
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
        framework_action_types::package_commit(),
        action_data,
        intent_witness
    );

    // Explicitly destroy the action struct
    destroy_commit_action(action);
}    

// must be called after UpgradeAction is processed, there cannot be any other action processed before
/// Commits an upgrade and updates the index with the new package address.
public fun do_commit<Config, Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<Config>,
    receipt: UpgradeReceipt,
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

    let cap_mut: &mut UpgradeCap = account.borrow_managed_asset_mut(UpgradeCapKey(name), version_witness);
    cap_mut.commit_upgrade(receipt);
    let new_package_addr = cap_mut.package().to_address();

    // update the index with the new package address
    let index_mut: &mut UpgradeIndex = account.borrow_managed_data_mut(UpgradeIndexKey(), version_witness);
    *index_mut.packages_info.get_mut(&name) = new_package_addr;

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
        framework_action_types::package_restrict(),
        action_data,
        intent_witness
    );

    // Explicitly destroy the action struct
    destroy_restrict_action(action);
}    

/// Processes a RestrictAction and updates the UpgradeCap policy.
public fun do_restrict<Config, Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<Config>,
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

    if (policy == package::additive_policy()) {
        let cap_mut: &mut UpgradeCap = account.borrow_managed_asset_mut(UpgradeCapKey(name), version_witness);
        cap_mut.only_additive_upgrades();
    } else if (policy == package::dep_only_policy()) {
        let cap_mut: &mut UpgradeCap = account.borrow_managed_asset_mut(UpgradeCapKey(name), version_witness);
        cap_mut.only_dep_upgrades();
    } else {
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

// === Package Funtions ===

/// Borrows the UpgradeCap for a given package address.
public(package) fun borrow_cap<Config>(
    account: &Account<Config>, 
    package_addr: address
): &UpgradeCap {
    let name = get_package_name(account, package_addr);
    account.borrow_managed_asset(UpgradeCapKey(name), version::current())
}
