/// The Extensions shared object tracks a list of verified and whitelisted packages.
/// These are the only packages that can be added as dependencies to an account if it disallows unverified packages.

module account_extensions::extensions;

// === Imports ===

use std::string::String;
use sui::table::{Self, Table};

// === Errors ===

const EExtensionNotFound: u64 = 0;
const EExtensionAlreadyExists: u64 = 1;

// === Structs ===

/// A list of verified and whitelisted packages
public struct Extensions has key {
    id: UID,
    by_name: Table<String, vector<PackageVersion>>,
    by_addr: Table<address, String>,
}

/// The address and version of a package
public struct PackageVersion has copy, drop, store {
    addr: address,
    version: u64,
}

/// A capability to add and remove extensions
public struct AdminCap has key, store {
    id: UID,
}

// === Public functions ===

fun init(ctx: &mut TxContext) {
    transfer::transfer(AdminCap { id: object::new(ctx) }, ctx.sender());
    transfer::share_object(Extensions {
        id: object::new(ctx),
        by_name: table::new(ctx),
        by_addr: table::new(ctx),
    });
}

// === View functions ===

/// Returns the number of extensions in the list
public fun length(extensions: &Extensions): u64 {
    extensions.by_name.length()
}

/// Returns the package versions for a given name
public fun by_name(extensions: &Extensions, name: String): &vector<PackageVersion> {
    extensions.by_name.borrow(name)
}

/// Returns the name of the extension
public fun by_addr(extensions: &Extensions, addr: address): &String {
    extensions.by_addr.borrow(addr)
}

/// Returns the address of the PackageVersion
public fun addr(package_version: &PackageVersion): address {
    package_version.addr
}

/// Returns the version of the PackageVersion
public fun version(package_version: &PackageVersion): u64 {
    package_version.version
}

/// Returns the latest address and version for a given name
public fun get_latest_for_name(
    extensions: &Extensions,
    name: String,
): (address, u64) {
    let history = extensions.by_name.borrow(name);
    let package_version = history[history.length() - 1];

    (package_version.addr, package_version.version)
}

/// Returns true if the package (name, addr, version) is in the list
public fun is_extension(
    extensions: &Extensions,
    name: String,
    addr: address,
    version: u64,
): bool {
    if (!extensions.by_name.contains(name)) return false;
    let history = extensions.by_name.borrow(name);
    let opt_idx = history.find_index!(|h| h.addr == addr);
    if (opt_idx.is_none()) return false;
    let idx = opt_idx.destroy_some();
    // check if the version exists for the name and address
    history[idx].version == version
}

// === Admin functions ===

/// Adds a new extension to the list
public fun add(extensions: &mut Extensions, _: &AdminCap, name: String, addr: address, version: u64) {
    assert!(!extensions.by_name.contains(name), EExtensionAlreadyExists);
    assert!(!extensions.by_addr.contains(addr), EExtensionAlreadyExists);
    let history = vector[PackageVersion { addr, version }];
    extensions.by_name.add(name, history);
    extensions.by_addr.add(addr, name);
}

/// Removes a package from the list
public fun remove(extensions: &mut Extensions, _: &AdminCap, name: String) {
    assert!(extensions.by_name.contains(name), EExtensionNotFound);
    let history = extensions.by_name.remove(name);
    history.do_ref!(|package_version| {
        if (extensions.by_addr.borrow(package_version.addr) == name) {
            extensions.by_addr.remove(package_version.addr);
        }
    });
}

/// Removes the version from the history of a package
public fun remove_version(extensions: &mut Extensions, _: &AdminCap, name: String, addr: address, version: u64) {
    let history = extensions.by_name.borrow_mut(name);
    let (exists, idx) = history.index_of(&PackageVersion { addr, version });
    assert!(exists, EExtensionNotFound);
    history.remove(idx);
}

/// Adds a new version to the history of a package
public fun update(extensions: &mut Extensions, _: &AdminCap, name: String, addr: address, version: u64) {
    assert!(extensions.by_name.contains(name), EExtensionNotFound);
    assert!(!extensions.by_addr.contains(addr), EExtensionAlreadyExists);
    extensions.by_name.borrow_mut(name).push_back(PackageVersion { addr, version });
    extensions.by_addr.add(addr, name);
}

public fun new_admin(_: &AdminCap, recipient: address, ctx: &mut TxContext) {
    transfer::public_transfer(AdminCap { id: object::new(ctx) }, recipient);
}

//**************************************************************************************************//
// Tests                                                                                            //
//**************************************************************************************************//

// === Test Helpers ===

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx);
}

#[test_only]
public fun new_for_testing(ctx: &mut TxContext): Extensions {
    Extensions {
        id: object::new(ctx),
        by_name: table::new(ctx),
        by_addr: table::new(ctx),
    }
}

#[test_only]
public fun add_for_testing(extensions: &mut Extensions, name: String, addr: address, version: u64) {
    assert!(!extensions.by_name.contains(name), EExtensionAlreadyExists);
    assert!(!extensions.by_addr.contains(addr), EExtensionAlreadyExists);
    let history = vector[PackageVersion { addr, version }];
    extensions.by_name.add(name, history);
    extensions.by_addr.add(addr, name);
}

#[test_only]
public fun remove_for_testing(extensions: &mut Extensions, name: String) {
    let history = extensions.by_name.remove(name);
    history.do_ref!(|package_version| {
        if (extensions.by_addr.borrow(package_version.addr) == name) {
            extensions.by_addr.remove(package_version.addr);
        }
    });
}

#[test_only]
public fun remove_version_for_testing(extensions: &mut Extensions, name: String, addr: address, version: u64) {
    let history = extensions.by_name.borrow_mut(name);
    let (exists, idx) = history.index_of(&PackageVersion { addr, version });
    assert!(exists, EExtensionNotFound);
    history.remove(idx);
}

#[test_only]
public fun update_for_testing(extensions: &mut Extensions, name: String, addr: address, version: u64) {
    assert!(!extensions.by_addr.contains(addr), EExtensionAlreadyExists);
    extensions.by_name.borrow_mut(name).push_back(PackageVersion { addr, version });
    extensions.by_addr.add(addr, name);
}

#[test_only]
public fun new_for_testing_with_addrs(addr1: address, addr2: address, addr3: address, ctx: &mut TxContext): Extensions {
    let mut extensions = new_for_testing(ctx);

    extensions.add_for_testing(b"AccountProtocol".to_string(), addr1, 1);
    extensions.add_for_testing(b"AccountActions".to_string(), addr2, 1);
    extensions.add_for_testing(b"AccountExtensions".to_string(), addr3, 1);

    extensions
}

// === Tests ===

#[test]
fun test_init() {
    use sui::test_scenario as ts;

    let admin = @0xA;
    let mut scenario = ts::begin(admin);

    init(scenario.ctx());
    scenario.next_tx(admin);

    assert!(ts::has_most_recent_shared<Extensions>());
    assert!(scenario.has_most_recent_for_sender<AdminCap>());

    scenario.end();
}

#[test]
fun test_add_and_get() {
    let mut extensions = new_for_testing(&mut tx_context::dummy());
    let admin_cap = AdminCap { id: object::new(&mut tx_context::dummy()) };

    extensions.add(&admin_cap, b"TestPackage".to_string(), @0x1, 1);

    assert!(extensions.length() == 1);
    assert!(extensions.is_extension(b"TestPackage".to_string(), @0x1, 1));
    assert!(extensions.by_addr(@0x1) == &b"TestPackage".to_string());

    let (addr, version) = extensions.get_latest_for_name(b"TestPackage".to_string());
    assert!(addr == @0x1);
    assert!(version == 1);

    sui::test_utils::destroy(extensions);
    sui::test_utils::destroy(admin_cap);
}

#[test]
fun test_update() {
    let mut extensions = new_for_testing(&mut tx_context::dummy());
    let admin_cap = AdminCap { id: object::new(&mut tx_context::dummy()) };

    extensions.add(&admin_cap, b"TestPackage".to_string(), @0x1, 1);
    extensions.update(&admin_cap, b"TestPackage".to_string(), @0x2, 2);

    assert!(extensions.is_extension(b"TestPackage".to_string(), @0x1, 1));
    assert!(extensions.is_extension(b"TestPackage".to_string(), @0x2, 2));

    let (addr, version) = extensions.get_latest_for_name(b"TestPackage".to_string());
    assert!(addr == @0x2);
    assert!(version == 2);

    sui::test_utils::destroy(extensions);
    sui::test_utils::destroy(admin_cap);
}

#[test]
fun test_remove() {
    let mut extensions = new_for_testing(&mut tx_context::dummy());
    let admin_cap = AdminCap { id: object::new(&mut tx_context::dummy()) };

    extensions.add(&admin_cap, b"TestPackage".to_string(), @0x1, 1);
    extensions.remove(&admin_cap, b"TestPackage".to_string());

    assert!(extensions.length() == 0);
    assert!(!extensions.is_extension(b"TestPackage".to_string(), @0x1, 1));

    sui::test_utils::destroy(extensions);
    sui::test_utils::destroy(admin_cap);
}

#[test]
fun test_remove_version() {
    let mut extensions = new_for_testing(&mut tx_context::dummy());
    let admin_cap = AdminCap { id: object::new(&mut tx_context::dummy()) };

    extensions.add(&admin_cap, b"TestPackage".to_string(), @0x1, 1);
    extensions.update(&admin_cap, b"TestPackage".to_string(), @0x2, 2);
    extensions.remove_version(&admin_cap, b"TestPackage".to_string(), @0x1, 1);

    assert!(!extensions.is_extension(b"TestPackage".to_string(), @0x1, 1));
    assert!(extensions.is_extension(b"TestPackage".to_string(), @0x2, 2));

    sui::test_utils::destroy(extensions);
    sui::test_utils::destroy(admin_cap);
}

#[test, expected_failure(abort_code = EExtensionAlreadyExists)]
fun test_error_add_duplicate_name() {
    let mut extensions = new_for_testing(&mut tx_context::dummy());
    let admin_cap = AdminCap { id: object::new(&mut tx_context::dummy()) };

    extensions.add(&admin_cap, b"TestPackage".to_string(), @0x1, 1);
    extensions.add(&admin_cap, b"TestPackage".to_string(), @0x2, 2);

    sui::test_utils::destroy(extensions);
    sui::test_utils::destroy(admin_cap);
}

#[test, expected_failure(abort_code = EExtensionAlreadyExists)]
fun test_error_add_duplicate_addr() {
    let mut extensions = new_for_testing(&mut tx_context::dummy());
    let admin_cap = AdminCap { id: object::new(&mut tx_context::dummy()) };

    extensions.add(&admin_cap, b"TestPackage1".to_string(), @0x1, 1);
    extensions.add(&admin_cap, b"TestPackage2".to_string(), @0x1, 2);

    sui::test_utils::destroy(extensions);
    sui::test_utils::destroy(admin_cap);
}

#[test, expected_failure(abort_code = EExtensionNotFound)]
fun test_error_remove_nonexistent() {
    let mut extensions = new_for_testing(&mut tx_context::dummy());
    let admin_cap = AdminCap { id: object::new(&mut tx_context::dummy()) };

    extensions.remove(&admin_cap, b"TestPackage".to_string());

    sui::test_utils::destroy(extensions);
    sui::test_utils::destroy(admin_cap);
}

#[test]
/// Test edge case: empty Extensions object operations
fun test_empty_extensions_operations() {
    let extensions = new_for_testing(&mut tx_context::dummy());

    // Test operations on empty Extensions
    assert!(extensions.length() == 0);
    assert!(extensions.length() == 0);
    assert!(!extensions.is_extension(b"Any".to_string(), @0x1, 1));

    sui::test_utils::destroy(extensions);
}
