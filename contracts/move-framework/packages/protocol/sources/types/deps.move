// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

// Portions of this file are derived from the account.tech Move Framework project.
// Those portions remain licensed under the Apache License, Version 2.0.

/// Dependencies are the packages that an Account object can call.
/// They are stored in a vector and can be modified through an intent.
/// AccountProtocol is the only mandatory dependency, found at index 0.
///
/// For improved security, we provide a whitelist of allowed packages in PackageRegistry.
/// If unverified_allowed is false, then only these packages can be added.

module account_protocol::deps;

use account_protocol::package_registry::{Self, PackageRegistry};
use account_protocol::version_witness::{Self, VersionWitness};
use std::string::String;
use sui::vec_set::{Self, VecSet};

// === Imports ===

// === Errors ===

const EDepNotFound: u64 = 0;
const EDepAlreadyExists: u64 = 1;
const ENotDep: u64 = 2;
const ENotExtension: u64 = 3;
const EAccountProtocolMissing: u64 = 4;
const EDepsNotSameLength: u64 = 5;
const EAccountConfigMissing: u64 = 6;
const ERegistryMismatch: u64 = 7;

// === Structs ===

/// Parent struct protecting the deps
public struct Deps has copy, drop, store {
    // vector of dependencies
    inner: vector<Dep>,
    // can community extensions be added
    unverified_allowed: bool,
    // ID of the PackageRegistry to use for whitelist checking
    registry_id: ID,
}

/// Child struct storing the name, package and version of a dependency
public struct Dep has copy, drop, store {
    // name of the package
    name: String,
    // id of the package
    addr: address,
    // version of the package
    version: u64,
}

// === Public functions ===

/// Creates a new Deps struct, AccountProtocol must be the first dependency.
public fun new(
    registry: &PackageRegistry,
    unverified_allowed: bool,
    names: vector<String>,
    addresses: vector<address>,
    mut versions: vector<u64>,
): Deps {
    let registry_id = sui::object::id(registry);
    assert!(
        names.length() == addresses.length() && addresses.length() == versions.length(),
        EDepsNotSameLength,
    );
    assert!(
        names[0] == b"AccountProtocol".to_string() &&
        registry.is_valid_package(names[0], addresses[0], versions[0]),
        EAccountProtocolMissing,
    );
    assert!(names.length() >= 2, EAccountConfigMissing);

    let mut inner = vector<Dep>[];
    // Use VecSet for O(log N) duplicate detection during construction
    let mut name_set = vec_set::empty<String>();
    let mut addr_set = vec_set::empty<address>();

    names.zip_do!(addresses, |name, addr| {
        let version = versions.remove(0);

        // O(log N) duplicate checking instead of O(N²)
        assert!(!name_set.contains(&name), EDepAlreadyExists);
        assert!(!addr_set.contains(&addr), EDepAlreadyExists);
        name_set.insert(name);
        addr_set.insert(addr);

        // verify package registry
        if (!unverified_allowed)
            assert!(registry.is_valid_package(name, addr, version), ENotExtension);

        // add dep
        inner.push_back(Dep { name, addr, version });
    });

    Deps { inner, unverified_allowed, registry_id }
}

/// Creates a new Deps struct from latest packages for names.
/// Unverified packages are not allowed after this operation.
public fun new_latest_extensions(registry: &PackageRegistry, names: vector<String>): Deps {
    assert!(names[0] == b"AccountProtocol".to_string(), EAccountProtocolMissing);

    let registry_id = sui::object::id(registry);
    let mut inner = vector<Dep>[];
    // Use VecSet for O(log N) duplicate detection
    let mut name_set = vec_set::empty<String>();
    let mut addr_set = vec_set::empty<address>();

    names.do!(|name| {
        // O(log N) duplicate checking
        assert!(!name_set.contains(&name), EDepAlreadyExists);

        let (addr, version) = registry.get_latest_version(name);

        assert!(!addr_set.contains(&addr), EDepAlreadyExists);
        name_set.insert(name);
        addr_set.insert(addr);

        // add dep
        inner.push_back(Dep { name, addr, version });
    });

    Deps { inner, unverified_allowed: false, registry_id }
}

public fun new_inner(
    registry: &PackageRegistry,
    deps: &Deps,
    names: vector<String>,
    addresses: vector<address>,
    mut versions: vector<u64>,
): Deps {
    assert!(
        names.length() == addresses.length() && addresses.length() == versions.length(),
        EDepsNotSameLength,
    );
    assert!(names[0] == b"AccountProtocol".to_string(), EAccountProtocolMissing);
    assert!(names.length() >= 2, EAccountConfigMissing);

    let mut inner = vector<Dep>[];
    // Use VecSet for O(log N) duplicate detection
    let mut name_set = vec_set::empty<String>();
    let mut addr_set = vec_set::empty<address>();

    names.zip_do!(addresses, |name, addr| {
        let version = versions.remove(0);

        // O(log N) duplicate checking
        assert!(!name_set.contains(&name), EDepAlreadyExists);
        assert!(!addr_set.contains(&addr), EDepAlreadyExists);
        name_set.insert(name);
        addr_set.insert(addr);

        // verify package registry
        if (!deps.unverified_allowed)
            assert!(registry.is_valid_package(name, addr, version), ENotExtension);

        // add dep
        inner.push_back(Dep { name, addr, version });
    });

    Deps { inner, unverified_allowed: deps.unverified_allowed, registry_id: deps.registry_id }
}

/// Safe because deps_mut is only accessible in this package.
public fun inner_mut(deps: &mut Deps): &mut vector<Dep> {
    &mut deps.inner
}

// === View functions ===

/// Checks if a package is a dependency or in the global PackageRegistry whitelist.
/// This allows all whitelisted packages to work automatically for all accounts,
/// while individual accounts can still add custom packages to their deps.
///
/// Validates that the registry passed matches the stored registry_id to prevent malicious
/// registries from bypassing the whitelist.
public fun check(deps: &Deps, version_witness: VersionWitness, registry: &PackageRegistry) {
    // SECURITY: Validate registry matches stored ID to prevent fake registries
    assert!(deps.registry_id == sui::object::id(registry), ERegistryMismatch);

    let addr = version_witness.package_addr();

    // First check if it's in the account's custom deps list
    if (deps.contains_addr(addr)) return;

    // Then check if it's in the global whitelist (any version is acceptable)
    if (registry.contains_package_addr(addr)) return;

    // Not found in either - abort
    abort ENotDep
}

public fun unverified_allowed(deps: &Deps): bool {
    deps.unverified_allowed
}

/// Toggles the unverified_allowed flag.
public(package) fun toggle_unverified_allowed(deps: &mut Deps) {
    deps.unverified_allowed = !deps.unverified_allowed;
}

/// Returns a dependency by name.
public fun get_by_name(deps: &Deps, name: String): &Dep {
    let mut i = 0;
    while (i < deps.inner.length()) {
        if (deps.inner[i].name == name) {
            return &deps.inner[i]
        };
        i = i + 1;
    };
    abort EDepNotFound
}

/// Returns a dependency by address.
public fun get_by_addr(deps: &Deps, addr: address): &Dep {
    let mut i = 0;
    while (i < deps.inner.length()) {
        if (deps.inner[i].addr == addr) {
            return &deps.inner[i]
        };
        i = i + 1;
    };
    abort EDepNotFound
}

/// Returns a dependency by index.
public fun get_by_idx(deps: &Deps, idx: u64): &Dep {
    &deps.inner[idx]
}

/// Returns the number of dependencies.
public fun length(deps: &Deps): u64 {
    deps.inner.length()
}

/// Returns the name of a dependency.
public fun name(dep: &Dep): String {
    dep.name
}

/// Returns the address of a dependency.
public fun addr(dep: &Dep): address {
    dep.addr
}

/// Returns the version of a dependency.
public fun version(dep: &Dep): u64 {
    dep.version
}

/// Returns true if the dependency exists by name.
public fun contains_name(deps: &Deps, name: String): bool {
    let mut i = 0;
    while (i < deps.inner.length()) {
        if (deps.inner[i].name == name) return true;
        i = i + 1;
    };
    false
}

/// Returns true if the dependency exists by address.
public fun contains_addr(deps: &Deps, addr: address): bool {
    let mut i = 0;
    while (i < deps.inner.length()) {
        if (deps.inner[i].addr == addr) return true;
        i = i + 1;
    };
    false
}

// === Test only ===

#[test_only]
use sui::test_utils::destroy;

#[test_only]
public fun new_for_testing(registry: &PackageRegistry): Deps {
    Deps {
        inner: vector[
            Dep { name: b"AccountProtocol".to_string(), addr: @account_protocol, version: 1 },
            Dep { name: b"AccountConfig".to_string(), addr: @0x1, version: 1 },
            Dep { name: b"AccountActions".to_string(), addr: @0x2, version: 1 },
        ],
        unverified_allowed: false,
        registry_id: sui::object::id(registry),
    }
}

#[test_only]
public fun toggle_unverified_allowed_for_testing(deps: &mut Deps) {
    deps.unverified_allowed = !deps.unverified_allowed;
}

#[test_only]
/// Create deps for testing with a custom config package address
/// This is useful when the config module (e.g., FutarchyConfig) is in a different package
/// and version::current() from that package needs to be validated
/// Includes @account_protocol, account_actions, and the custom config address as valid dependencies
public fun new_for_testing_with_config(config_name: String, config_addr: address): Deps {
    // Use the named address for account_actions from Move.toml
    // This ensures the address matches what's used in tests
    let account_actions_addr = @account_actions;

    Deps {
        inner: vector[
            Dep { name: b"AccountProtocol".to_string(), addr: @account_protocol, version: 1 },
            Dep { name: config_name, addr: config_addr, version: 1 },
            Dep { name: b"AccountActions".to_string(), addr: account_actions_addr, version: 1 },
        ],
        unverified_allowed: false,
        registry_id: sui::object::id_from_address(@0x0), // Dummy ID for testing
    }
}

// === Tests ===

#[test]
fun test_new_and_getters(ctx: &mut TxContext) {
    // For test: create a registry first
    let registry = package_registry::new_for_testing(ctx);
    // Skip registry validation in test - just test the Deps structure
    let _deps = new_for_testing(&registry);
    // assertions
    let deps = new_for_testing(&registry);
    let witness = version_witness::new_for_testing(@account_protocol);
    deps.check(witness, &registry);
    // deps getters
    assert!(deps.length() == 3);
    assert!(deps.contains_name(b"AccountProtocol".to_string()));
    assert!(deps.contains_addr(@account_protocol));
    // dep getters
    let dep = deps.get_by_name(b"AccountProtocol".to_string());
    assert!(dep.name() == b"AccountProtocol".to_string());
    assert!(dep.addr() == @account_protocol);
    assert!(dep.version() == 1);
    let dep = deps.get_by_addr(@account_protocol);
    assert!(dep.name() == b"AccountProtocol".to_string());
    assert!(dep.addr() == @account_protocol);
    assert!(dep.version() == 1);
    destroy(registry);
}

#[test, expected_failure(abort_code = ENotDep)]
fun test_error_assert_is_dep(ctx: &mut TxContext) {
    let registry = package_registry::new_for_testing(ctx);
    let deps = new_for_testing(&registry);
    let witness = version_witness::new_for_testing(@0xDEAD);
    deps.check(witness, &registry);
    destroy(registry);
}

#[test, expected_failure(abort_code = EDepNotFound)]
fun test_error_name_not_found(ctx: &mut TxContext) {
    let registry = package_registry::new_for_testing(ctx);
    let deps = new_for_testing(&registry);
    deps.get_by_name(b"Other".to_string());
    destroy(registry);
}

#[test, expected_failure(abort_code = EDepNotFound)]
fun test_error_addr_not_found(ctx: &mut TxContext) {
    let registry = package_registry::new_for_testing(ctx);
    let deps = new_for_testing(&registry);
    deps.get_by_addr(@0xA);
    destroy(registry);
}

#[test]
fun test_contains_name(ctx: &mut TxContext) {
    let registry = package_registry::new_for_testing(ctx);
    let deps = new_for_testing(&registry);
    assert!(deps.contains_name(b"AccountProtocol".to_string()));
    assert!(!deps.contains_name(b"Other".to_string()));
    destroy(registry);
}

#[test]
fun test_contains_addr(ctx: &mut TxContext) {
    let registry = package_registry::new_for_testing(ctx);
    let deps = new_for_testing(&registry);
    assert!(deps.contains_addr(@account_protocol));
    assert!(!deps.contains_addr(@0xA));
    destroy(registry);
}

#[test]
fun test_getters_by_idx(ctx: &mut TxContext) {
    let registry = package_registry::new_for_testing(ctx);
    let deps = new_for_testing(&registry);
    let dep = deps.get_by_idx(0);
    assert!(dep.name() == b"AccountProtocol".to_string());
    assert!(dep.addr() == @account_protocol);
    assert!(dep.version() == 1);
    destroy(registry);
}

#[test]
fun test_toggle_unverified_allowed(ctx: &mut TxContext) {
    let registry = package_registry::new_for_testing(ctx);
    let mut deps = new_for_testing(&registry);
    assert!(deps.unverified_allowed() == false);
    deps.toggle_unverified_allowed_for_testing();
    assert!(deps.unverified_allowed() == true);
    destroy(registry);
}

#[test]
fun test_contains_name_empty_deps() {
    let deps = Deps {
        inner: vector[],
        unverified_allowed: false,
        registry_id: sui::object::id_from_address(@0x0),
    };
    assert!(!deps.contains_name(b"AccountProtocol".to_string()));
}

#[test]
fun test_contains_addr_empty_deps() {
    let deps = Deps {
        inner: vector[],
        unverified_allowed: false,
        registry_id: sui::object::id_from_address(@0x0),
    };
    assert!(!deps.contains_addr(@account_protocol));
}
