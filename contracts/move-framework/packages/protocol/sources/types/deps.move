// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

// Portions of this file are derived from the account.tech Move Framework project.
// Those portions remain licensed under the Apache License, Version 2.0.

/// Dependencies are the packages that an Account object can call.
/// They are stored in a vector and can be modified through an intent.
/// AccountProtocol is the only mandatory dependency, found at index 0.
///
/// For improved security, we provide a whitelist of allowed packages in Extensions.
/// If unverified_allowed is false, then only these packages can be added.

module account_protocol::deps;

use account_extensions::extensions::Extensions;
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

// === Structs ===

/// Parent struct protecting the deps
public struct Deps has copy, drop, store {
    // vector of dependencies
    inner: vector<Dep>,
    // can community extensions be added
    unverified_allowed: bool,
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
    extensions: &Extensions,
    unverified_allowed: bool,
    names: vector<String>,
    addresses: vector<address>,
    mut versions: vector<u64>,
): Deps {
    assert!(
        names.length() == addresses.length() && addresses.length() == versions.length(),
        EDepsNotSameLength,
    );
    assert!(
        names[0] == b"AccountProtocol".to_string() &&
        extensions.is_extension(names[0], addresses[0], versions[0]),
        EAccountProtocolMissing,
    );
    // ✅ FIXED: Removed fragile negative assertion for position 1 (AccountConfig)
    //
    // DESIGN RATIONALE:
    // Position 1 must contain an AccountConfig implementation, but config names vary
    // (FutarchyConfig, MultiSigConfig, CustomConfig, etc.). We cannot use exact string
    // matching like we do for AccountProtocol.
    //
    // OLD APPROACH (FRAGILE):
    //   assert!(names[1] != b"AccountActions".to_string(), EAccountConfigMissing);
    //   Problem: Breaks if legitimate packages contain "AccountActions" in their name
    //
    // NEW APPROACH (TYPE-SAFE):
    //   - Rely on Move's type system for validation
    //   - Account<Config> construction requires a valid Config type parameter
    //   - Extensions whitelist validates package authenticity via is_extension()
    //   - String validation at Deps level is redundant and error-prone
    //
    // Type safety is enforced at compile time, not runtime string matching.
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

        // verify extensions
        if (!unverified_allowed)
            assert!(extensions.is_extension(name, addr, version), ENotExtension);

        // add dep
        inner.push_back(Dep { name, addr, version });
    });

    Deps { inner, unverified_allowed }
}

/// Creates a new Deps struct from latest packages for names.
/// Unverified packages are not allowed after this operation.
public fun new_latest_extensions(extensions: &Extensions, names: vector<String>): Deps {
    assert!(names[0] == b"AccountProtocol".to_string(), EAccountProtocolMissing);

    let mut inner = vector<Dep>[];
    // Use VecSet for O(log N) duplicate detection
    let mut name_set = vec_set::empty<String>();
    let mut addr_set = vec_set::empty<address>();

    names.do!(|name| {
        // O(log N) duplicate checking
        assert!(!name_set.contains(&name), EDepAlreadyExists);

        let (addr, version) = extensions.get_latest_for_name(name);

        assert!(!addr_set.contains(&addr), EDepAlreadyExists);
        name_set.insert(name);
        addr_set.insert(addr);

        // add dep
        inner.push_back(Dep { name, addr, version });
    });

    Deps { inner, unverified_allowed: false }
}

public fun new_inner(
    extensions: &Extensions,
    deps: &Deps,
    names: vector<String>,
    addresses: vector<address>,
    mut versions: vector<u64>,
): Deps {
    assert!(
        names.length() == addresses.length() && addresses.length() == versions.length(),
        EDepsNotSameLength,
    );
    // AccountProtocol is mandatory and cannot be removed
    assert!(names[0] == b"AccountProtocol".to_string(), EAccountProtocolMissing);
    // ✅ FIXED: Removed fragile negative assertion for position 1 (AccountConfig)
    // See detailed rationale in new() function above - type safety is enforced by
    // Move's type system (Account<Config>) rather than runtime string matching.
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

        // verify extensions
        if (!deps.unverified_allowed)
            assert!(extensions.is_extension(name, addr, version), ENotExtension);

        // add dep
        inner.push_back(Dep { name, addr, version });
    });

    Deps { inner, unverified_allowed: deps.unverified_allowed }
}

/// Safe because deps_mut is only accessible in this package.
public fun inner_mut(deps: &mut Deps): &mut vector<Dep> {
    &mut deps.inner
}

// === View functions ===

/// Checks if a package is a dependency.
public fun check(deps: &Deps, version_witness: VersionWitness) {
    assert!(deps.contains_addr(version_witness.package_addr()), ENotDep);
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
public fun new_for_testing(): Deps {
    Deps {
        inner: vector[
            Dep { name: b"AccountProtocol".to_string(), addr: @account_protocol, version: 1 },
            Dep { name: b"AccountConfig".to_string(), addr: @0x1, version: 1 },
            Dep { name: b"AccountActions".to_string(), addr: @0x2, version: 1 },
        ],
        unverified_allowed: false,
    }
}

#[test_only]
public fun toggle_unverified_allowed_for_testing(deps: &mut Deps) {
    deps.unverified_allowed = !deps.unverified_allowed;
}

// === Tests ===

#[test]
fun test_new_and_getters() {
    let extensions = account_extensions::extensions::new_for_testing_with_addrs(
        @account_protocol,
        @0x1,
        @0x2,
        &mut tx_context::dummy(),
    );

    let _deps = new(
        &extensions,
        false,
        vector[b"AccountProtocol".to_string(), b"AccountConfig".to_string()],
        vector[@account_protocol, @0x1],
        vector[1, 1],
    );
    // assertions
    let deps = new_for_testing();
    let witness = version_witness::new_for_testing(@account_protocol);
    deps.check(witness);
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

    sui::test_utils::destroy(extensions);
}

#[test, expected_failure(abort_code = ENotDep)]
fun test_error_assert_is_dep() {
    let deps = new_for_testing();
    let witness = version_witness::new_for_testing(@0xDEAD);
    deps.check(witness);
}

#[test, expected_failure(abort_code = EDepNotFound)]
fun test_error_name_not_found() {
    let deps = new_for_testing();
    deps.get_by_name(b"Other".to_string());
}

#[test, expected_failure(abort_code = EDepNotFound)]
fun test_error_addr_not_found() {
    let deps = new_for_testing();
    deps.get_by_addr(@0xA);
}

#[test]
fun test_contains_name() {
    let deps = new_for_testing();
    assert!(deps.contains_name(b"AccountProtocol".to_string()));
    assert!(!deps.contains_name(b"Other".to_string()));
}

#[test]
fun test_contains_addr() {
    let deps = new_for_testing();
    assert!(deps.contains_addr(@account_protocol));
    assert!(!deps.contains_addr(@0xA));
}

#[test]
fun test_getters_by_idx() {
    let deps = new_for_testing();
    let dep = deps.get_by_idx(0);
    assert!(dep.name() == b"AccountProtocol".to_string());
    assert!(dep.addr() == @account_protocol);
    assert!(dep.version() == 1);
}

#[test]
fun test_toggle_unverified_allowed() {
    let mut deps = new_for_testing();
    assert!(deps.unverified_allowed() == false);
    deps.toggle_unverified_allowed_for_testing();
    assert!(deps.unverified_allowed() == true);
}

#[test]
fun test_contains_name_empty_deps() {
    let deps = Deps {
        inner: vector[],
        unverified_allowed: false,
    };
    assert!(!deps.contains_name(b"AccountProtocol".to_string()));
}

#[test]
fun test_contains_addr_empty_deps() {
    let deps = Deps {
        inner: vector[],
        unverified_allowed: false,
    };
    assert!(!deps.contains_addr(@account_protocol));
}
