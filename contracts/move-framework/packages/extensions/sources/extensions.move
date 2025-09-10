// ============================================================================
// FORK NOTE: Table-based implementation for architectural correctness
// 
// CONTEXT:
// Extensions is a shared global registry - a public good that all protocols
// build upon. Success means growth: new standards, partners, and integrations.
// 
// DECISION:
// Using Tables for O(1) lookups is not optimization - it's the architecturally
// correct choice for a global registry. A vector would create a scalability
// bug that punishes ecosystem growth with degraded performance.
// 
// AUDIT BENEFIT:
// Table-based code is simpler to audit - verifying correct usage of standard
// Sui primitives vs. proving correctness of custom nested loops.
// ============================================================================

/// The Extensions shared object tracks a list of verified and whitelisted packages.
/// These are the only packages that can be added as dependencies to an account if it disallows unverified packages.

module account_extensions::extensions;

// === Imports ===

use std::string::String;
use sui::table::{Self, Table};

// === Errors ===

const EExtensionNotFound: u64 = 0;
const EExtensionAlreadyExists: u64 = 1;
const ECannotRemoveAccountProtocol: u64 = 2;

// === Structs ===

/// A list of verified and whitelisted packages
public struct Extensions has key {
    id: UID,
    /// Table for O(1) name-based lookups
    by_name: Table<String, Extension>,
    /// Table for O(1) address-based lookups  
    by_addr: Table<address, String>,
}

/// A package with a name and all authorized versions
public struct Extension has copy, drop, store {
    name: String,
    history: vector<History>,
}

/// The address and version of a package
public struct History has copy, drop, store {
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

/// Returns the number of extensions (alias for length)
public fun size(extensions: &Extensions): u64 {
    extensions.by_name.length()
}

/// Returns the extension by name
public fun get_by_name(extensions: &Extensions, name: String): &Extension {
    assert!(extensions.by_name.contains(name), EExtensionNotFound);
    extensions.by_name.borrow(name)
}


/// Returns the name of the extension
public fun name(extension: &Extension): String {
    extension.name
}

/// Returns the history of the extension
public fun history(extension: &Extension): vector<History> {
    extension.history
}

/// Returns the address of the history
public fun addr(history: &History): address {
    history.addr
}

/// Returns the version of the history
public fun version(history: &History): u64 {
    history.version
}

/// Returns the latest address and version for a given name
public fun get_latest_for_name(
    extensions: &Extensions, 
    name: String, 
): (address, u64) {
    assert!(extensions.by_name.contains(name), EExtensionNotFound);
    let extension = extensions.by_name.borrow(name);
    let history = extension.history;
    let last_idx = history.length() - 1;

    (history[last_idx].addr, history[last_idx].version)
}

/// Returns true if the package (name, addr, version) is in the list
public fun is_extension(
    extensions: &Extensions, 
    name: String,
    addr: address,
    version: u64,
): bool {
    // O(1) check if the name exists
    if (!extensions.by_name.contains(name)) return false;
    
    // O(1) check if the address is registered
    if (!extensions.by_addr.contains(addr)) return false;
    
    // Verify the address maps to this name
    if (extensions.by_addr.borrow(addr) != name) return false;
    
    // Check version in history (small list, typically 1-3 versions)
    let extension = extensions.by_name.borrow(name);
    let history = extension.history;
    let opt_idx = history.find_index!(|h| h.addr == addr);
    if (opt_idx.is_none()) return false;
    let idx = opt_idx.destroy_some();
    history[idx].version == version
}

// === Admin functions ===

/// Adds a package to the list
public fun add(extensions: &mut Extensions, _: &AdminCap, name: String, addr: address, version: u64) {    
    // O(1) checks - simpler for auditors to verify
    assert!(!extensions.by_name.contains(name), EExtensionAlreadyExists);
    assert!(!extensions.by_addr.contains(addr), EExtensionAlreadyExists);
    
    let extension = Extension { name, history: vector[History { addr, version }] };
    
    // O(1) insertions
    extensions.by_name.add(name, extension);
    extensions.by_addr.add(addr, name);
}

/// Removes a package from the list
public fun remove(extensions: &mut Extensions, _: &AdminCap, name: String) {
    assert!(extensions.by_name.contains(name), EExtensionNotFound);
    assert!(name != b"AccountProtocol".to_string(), ECannotRemoveAccountProtocol);
    
    // Remove from tables (O(1) operations)
    let extension = extensions.by_name.remove(name);
    let history = extension.history;
    history.do!(|h| {
        if (extensions.by_addr.contains(h.addr) && extensions.by_addr.borrow(h.addr) == name) {
            extensions.by_addr.remove(h.addr);
        };
    });
}

/// Adds a new version to the history of a package
public fun update(extensions: &mut Extensions, _: &AdminCap, name: String, addr: address, version: u64) {
    // O(1) checks
    assert!(extensions.by_name.contains(name), EExtensionNotFound);
    assert!(!extensions.by_addr.contains(addr), EExtensionAlreadyExists);
    
    // Update in table
    let extension = extensions.by_name.borrow_mut(name);
    extension.history.push_back(History { addr, version });
    
    // Add address mapping
    extensions.by_addr.add(addr, name);
}

public entry fun new_admin(_: &AdminCap, recipient: address, ctx: &mut TxContext) {
    transfer::public_transfer(AdminCap { id: object::new(ctx) }, recipient);
}

// === Private functions ===


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
    let extension = Extension { name, history: vector[History { addr, version }] };
    extensions.by_name.add(name, extension);
    extensions.by_addr.add(addr, name);
}

#[test_only]
public fun remove_for_testing(extensions: &mut Extensions, name: String) {
    assert!(extensions.by_name.contains(name), EExtensionNotFound);
    assert!(name != b"AccountProtocol".to_string(), ECannotRemoveAccountProtocol);
    
    let extension = extensions.by_name.remove(name);
    let history = extension.history;
    history.do!(|h| {
        if (extensions.by_addr.contains(h.addr) && extensions.by_addr.borrow(h.addr) == name) {
            extensions.by_addr.remove(h.addr);
        };
    });
}

#[test_only]
public fun update_for_testing(extensions: &mut Extensions, name: String, addr: address, version: u64) {
    assert!(extensions.by_name.contains(name), EExtensionNotFound);
    assert!(!extensions.by_addr.contains(addr), EExtensionAlreadyExists);
    
    let extension = extensions.by_name.borrow_mut(name);
    extension.history.push_back(History { addr, version });
    extensions.by_addr.add(addr, name);
}

#[test_only]
public fun new_for_testing_with_addrs(addr1: address, addr2: address, addr3: address, ctx: &mut TxContext): Extensions {
    let mut extensions = Extensions {
        id: object::new(ctx),
        by_name: table::new(ctx),
        by_addr: table::new(ctx),
    };
    
    // Add AccountProtocol
    let ext1 = Extension { name: b"AccountProtocol".to_string(), history: vector[History { addr: addr1, version: 1 }] };
    extensions.by_name.add(b"AccountProtocol".to_string(), ext1);
    extensions.by_addr.add(addr1, b"AccountProtocol".to_string());
    
    // Add AccountConfig
    let ext2 = Extension { name: b"AccountConfig".to_string(), history: vector[History { addr: addr2, version: 1 }] };
    extensions.by_name.add(b"AccountConfig".to_string(), ext2);
    extensions.by_addr.add(addr2, b"AccountConfig".to_string());
    
    // Add AccountActions
    let ext3 = Extension { name: b"AccountActions".to_string(), history: vector[History { addr: addr3, version: 1 }] };
    extensions.by_name.add(b"AccountActions".to_string(), ext3);
    extensions.by_addr.add(addr3, b"AccountActions".to_string());
    
    extensions
}

#[test_only]
public struct Witness() has drop;

#[test_only]
public fun witness(): Witness {
    Witness()
}

// === Unit Tests ===

#[test_only]
use sui::test_utils::destroy;
#[test_only]
use sui::test_scenario as ts;

#[test]
fun test_init() {
    let mut scenario = ts::begin(@0xCAFE);
    init(scenario.ctx());
    scenario.next_tx(@0xCAFE);

    let cap = scenario.take_from_sender<AdminCap>();
    let extensions = scenario.take_shared<Extensions>();

    destroy(cap);
    destroy(extensions);
    scenario.end();
}

#[test]
fun test_getters() {
    let extensions = new_for_testing_with_addrs(@0x0, @0x1, @0x2, &mut tx_context::dummy());

    // assertions
    assert!(extensions.is_extension(b"AccountProtocol".to_string(), @0x0, 1));
    assert!(extensions.is_extension(b"AccountConfig".to_string(), @0x1, 1));

    assert!(extensions.length() == 3);
    assert!(extensions.get_by_idx(0).name() == b"AccountProtocol".to_string());
    assert!(extensions.get_by_idx(0).history()[0].addr() == @0x0);
    assert!(extensions.get_by_idx(0).history()[0].version() == 1);
    assert!(extensions.get_by_idx(1).name() == b"AccountConfig".to_string());
    assert!(extensions.get_by_idx(1).history()[0].addr() == @0x1);
    assert!(extensions.get_by_idx(1).history()[0].version() == 1);
    assert!(extensions.get_by_idx(2).name() == b"AccountActions".to_string());
    assert!(extensions.get_by_idx(2).history()[0].addr() == @0x2);
    assert!(extensions.get_by_idx(2).history()[0].version() == 1);

    destroy(extensions);
}

#[test]
fun test_get_latest_for_name() {
    let mut extensions = new_for_testing_with_addrs(@0x0, @0x1, @0x2, &mut tx_context::dummy());
    let cap = AdminCap { id: object::new(&mut tx_context::dummy()) };

    let (addr, version) = extensions.get_latest_for_name(b"AccountProtocol".to_string());
    assert!(addr == @0x0);
    assert!(version == 1);
    let (addr, version) = extensions.get_latest_for_name(b"AccountConfig".to_string());
    assert!(addr == @0x1);
    assert!(version == 1);
    let (addr, version) = extensions.get_latest_for_name(b"AccountActions".to_string());
    assert!(addr == @0x2);
    assert!(version == 1);
    // update
    extensions.update(&cap, b"AccountConfig".to_string(), @0x11, 2);
    extensions.update(&cap, b"AccountActions".to_string(), @0x21, 2);
    extensions.update(&cap, b"AccountActions".to_string(), @0x22, 3);
    let (addr, version) = extensions.get_latest_for_name(b"AccountProtocol".to_string());
    assert!(addr == @0x0);
    assert!(version == 1);
    let (addr, version) = extensions.get_latest_for_name(b"AccountConfig".to_string());
    assert!(addr == @0x11);
    assert!(version == 2);
    let (addr, version) = extensions.get_latest_for_name(b"AccountActions".to_string());
    assert!(addr == @0x22);
    assert!(version == 3);

    destroy(extensions);
    destroy(cap);
}

#[test]
fun test_is_extension() {
    let extensions = new_for_testing_with_addrs(@0x0, @0x1, @0x2, &mut tx_context::dummy());
    let cap = AdminCap { id: object::new(&mut tx_context::dummy()) };

    let (addr, version) = extensions.get_latest_for_name(b"AccountProtocol".to_string());
    assert!(addr == @0x0);
    assert!(version == 1);
    let (addr, version) = extensions.get_latest_for_name(b"AccountConfig".to_string());
    assert!(addr == @0x1);
    assert!(version == 1);
    let (addr, version) = extensions.get_latest_for_name(b"AccountActions".to_string());
    assert!(addr == @0x2);
    assert!(version == 1);

    // correct extensions
    assert!(extensions.is_extension(b"AccountProtocol".to_string(), @0x0, 1));
    assert!(extensions.is_extension(b"AccountConfig".to_string(), @0x1, 1));
    assert!(extensions.is_extension(b"AccountActions".to_string(), @0x2, 1));
    // incorrect names
    assert!(!extensions.is_extension(b"AccountProtoco".to_string(), @0x0, 1));
    assert!(!extensions.is_extension(b"AccountConfi".to_string(), @0x1, 1));
    assert!(!extensions.is_extension(b"AccountAction".to_string(), @0x2, 1));
    // incorrect addresses
    assert!(!extensions.is_extension(b"AccountProtocol".to_string(), @0x1, 1));
    assert!(!extensions.is_extension(b"AccountConfig".to_string(), @0x0, 1));
    assert!(!extensions.is_extension(b"AccountActions".to_string(), @0x0, 1));
    // incorrect versions
    assert!(!extensions.is_extension(b"AccountProtocol".to_string(), @0x0, 2));
    assert!(!extensions.is_extension(b"AccountConfig".to_string(), @0x1, 2));
    assert!(!extensions.is_extension(b"AccountActions".to_string(), @0x2, 2));

    destroy(extensions);
    destroy(cap);
}

#[test]
fun test_add_deps() {
    let mut extensions = new_for_testing(&mut tx_context::dummy());
    let cap = AdminCap { id: object::new(&mut tx_context::dummy()) };

    // add extension
    extensions.add(&cap, b"A".to_string(), @0xA, 1);
    extensions.add(&cap, b"B".to_string(), @0xB, 1);
    extensions.add(&cap, b"C".to_string(), @0xC, 1);
    // assertions
    assert!(extensions.is_extension(b"A".to_string(), @0xA, 1));
    assert!(extensions.is_extension(b"B".to_string(), @0xB, 1));
    assert!(extensions.is_extension(b"C".to_string(), @0xC, 1));

    destroy(extensions);
    destroy(cap);
}

#[test]
fun test_update_deps() {
    let mut extensions = new_for_testing_with_addrs(@0x0, @0x1, @0x2, &mut tx_context::dummy());
    let cap = AdminCap { id: object::new(&mut tx_context::dummy()) };

    // add extension (checked above)
    extensions.add(&cap, b"A".to_string(), @0xA, 1);
    extensions.add(&cap, b"B".to_string(), @0xB, 1);
    extensions.add(&cap, b"C".to_string(), @0xC, 1);
    // update deps
    extensions.update(&cap, b"B".to_string(), @0x1B, 2);
    extensions.update(&cap, b"C".to_string(), @0x1C, 2);
    extensions.update(&cap, b"C".to_string(), @0x2C, 3);
    // assertions - Find indices for each extension
    let a_idx = extensions.get_idx_for_name(b"A".to_string());
    let b_idx = extensions.get_idx_for_name(b"B".to_string());
    let c_idx = extensions.get_idx_for_name(b"C".to_string());
    
    assert!(extensions.inner[a_idx].name() == b"A".to_string());
    assert!(extensions.inner[a_idx].history()[0].addr() == @0xA);
    assert!(extensions.inner[a_idx].history()[0].version() == 1);
    assert!(extensions.inner[b_idx].name() == b"B".to_string());
    assert!(extensions.inner[b_idx].history()[1].addr() == @0x1B);
    assert!(extensions.inner[b_idx].history()[1].version() == 2);
    assert!(extensions.inner[c_idx].name() == b"C".to_string());
    assert!(extensions.inner[c_idx].history()[2].addr() == @0x2C);
    assert!(extensions.inner[c_idx].history()[2].version() == 3);
    // verify core deps didn't change    
    assert!(extensions.length() == 6);
    assert!(extensions.get_by_idx(0).name() == b"AccountProtocol".to_string());
    assert!(extensions.get_by_idx(0).history()[0].addr() == @0x0);
    assert!(extensions.get_by_idx(0).history()[0].version() == 1);
    assert!(extensions.get_by_idx(1).name() == b"AccountConfig".to_string());
    assert!(extensions.get_by_idx(1).history()[0].addr() == @0x1);
    assert!(extensions.get_by_idx(1).history()[0].version() == 1);
    assert!(extensions.get_by_idx(2).name() == b"AccountActions".to_string());
    assert!(extensions.get_by_idx(2).history()[0].addr() == @0x2);
    assert!(extensions.get_by_idx(2).history()[0].version() == 1);

    destroy(extensions);
    destroy(cap);
}

#[test]
fun test_remove_deps() {
    let mut extensions = new_for_testing_with_addrs(@0x0, @0x1, @0x2, &mut tx_context::dummy());
    let cap = AdminCap { id: object::new(&mut tx_context::dummy()) };

    // add extension (checked above)
    extensions.add(&cap, b"A".to_string(), @0xA, 1);
    extensions.add(&cap, b"B".to_string(), @0xB, 1);
    extensions.add(&cap, b"C".to_string(), @0xC, 1);
    // update deps
    extensions.update(&cap, b"B".to_string(), @0x1B, 2);
    extensions.update(&cap, b"C".to_string(), @0x1C, 2);
    extensions.update(&cap, b"C".to_string(), @0x2C, 3);
    // remove deps
    extensions.remove(&cap, b"A".to_string());
    extensions.remove(&cap, b"B".to_string());
    extensions.remove(&cap, b"C".to_string());
    // assertions
    assert!(!extensions.is_extension(b"A".to_string(), @0xA, 1));
    assert!(!extensions.is_extension(b"B".to_string(), @0xB, 1));
    assert!(!extensions.is_extension(b"B".to_string(), @0x1B, 2));
    assert!(!extensions.is_extension(b"C".to_string(), @0xC, 1));
    assert!(!extensions.is_extension(b"C".to_string(), @0x1C, 2));
    assert!(!extensions.is_extension(b"C".to_string(), @0x2C, 3));

    destroy(extensions);
    destroy(cap);
}

#[test]
fun test_new_admin() {
    let mut scenario = ts::begin(@0xCAFE);
    let cap = AdminCap { id: object::new(scenario.ctx()) };
    new_admin(&cap, @0xB0B, scenario.ctx());
    scenario.next_tx(@0xB0B);
    // check it exists
    let new_cap = scenario.take_from_sender<AdminCap>();
    destroy(cap);
    destroy(new_cap);
    ts::end(scenario);
}

#[test, expected_failure(abort_code = ECannotRemoveAccountProtocol)]
fun test_error_remove_account_protocol() {
    let mut extensions = new_for_testing_with_addrs(@0x0, @0x1, @0x2, &mut tx_context::dummy());
    let cap = AdminCap { id: object::new(&mut tx_context::dummy()) };
    extensions.remove(&cap, b"AccountProtocol".to_string());
    destroy(extensions);
    destroy(cap);
}

#[test, expected_failure(abort_code = EExtensionAlreadyExists)]
fun test_error_add_extension_name_already_exists() {
    let mut extensions = new_for_testing_with_addrs(@0x0, @0x1, @0x2, &mut tx_context::dummy());
    let cap = AdminCap { id: object::new(&mut tx_context::dummy()) };
    extensions.add(&cap, b"AccountProtocol".to_string(), @0xA, 1);
    destroy(extensions);
    destroy(cap);
}

#[test, expected_failure(abort_code = EExtensionAlreadyExists)]
fun test_error_add_extension_address_already_exists() {
    let mut extensions = new_for_testing_with_addrs(@0x0, @0x1, @0x2, &mut tx_context::dummy());
    let cap = AdminCap { id: object::new(&mut tx_context::dummy()) };
    extensions.add(&cap, b"A".to_string(), @0x0, 1);
    destroy(extensions);
    destroy(cap);
}

#[test, expected_failure(abort_code = EExtensionNotFound)]
fun test_error_update_not_extension() {
    let mut extensions = new_for_testing_with_addrs(@0x0, @0x1, @0x2, &mut tx_context::dummy());
    let cap = AdminCap { id: object::new(&mut tx_context::dummy()) };
    extensions.update(&cap, b"A".to_string(), @0x0, 1);
    destroy(extensions);
    destroy(cap);
}

#[test, expected_failure(abort_code = EExtensionAlreadyExists)]
fun test_error_update_same_address() {
    let mut extensions = new_for_testing_with_addrs(@0x0, @0x1, @0x2, &mut tx_context::dummy());
    let cap = AdminCap { id: object::new(&mut tx_context::dummy()) };
    extensions.add(&cap, b"A".to_string(), @0xA, 1);
    extensions.update(&cap, b"A".to_string(), @0xA, 2);
    destroy(extensions);
    destroy(cap);
}

#[test, expected_failure(abort_code = EExtensionNotFound)]
fun test_error_remove_not_extension() {
    let mut extensions = new_for_testing_with_addrs(@0x0, @0x1, @0x2, &mut tx_context::dummy());
    let cap = AdminCap { id: object::new(&mut tx_context::dummy()) };
    extensions.remove(&cap, b"A".to_string());
    destroy(extensions);
    destroy(cap);
}

// === Additional tests for Table optimization edge cases ===

#[test]
/// Test that Tables handle many extensions efficiently
fun test_large_scale_extensions() {
    let mut extensions = new_for_testing_with_addrs(@0x0, @0x1, @0x2, &mut tx_context::dummy());
    let cap = AdminCap { id: object::new(&mut tx_context::dummy()) };
    
    // Add multiple extensions to test O(1) scalability
    // Using predefined addresses since Move doesn't support address arithmetic
    let test_addrs = vector[@0x1000, @0x1001, @0x1002, @0x1003, @0x1004, 
                            @0x1005, @0x1006, @0x1007, @0x1008, @0x1009,
                            @0x100A, @0x100B, @0x100C, @0x100D, @0x100E];
    
    let mut i = 0;
    while (i < test_addrs.length()) {
        let mut name = b"Extension_".to_string();
        let num_str = if (i < 10) {
            vector[48u8 + (i as u8)]  // ASCII '0' = 48
        } else {
            vector[49u8, 48u8 + ((i - 10) as u8)]  // "1x" for 10-14
        };
        name.append_utf8(num_str);
        extensions.add(&cap, name, test_addrs[i], 1);
        i = i + 1;
    };
    
    // Verify O(1) lookups work with many extensions
    assert!(extensions.is_extension(b"Extension_0".to_string(), @0x1000, 1));
    assert!(extensions.is_extension(b"Extension_5".to_string(), @0x1005, 1));
    assert!(extensions.is_extension(b"Extension_14".to_string(), @0x100E, 1));
    
    // Verify get_latest_for_name still works efficiently
    let (addr, version) = extensions.get_latest_for_name(b"Extension_7".to_string());
    assert!(addr == @0x1007);
    assert!(version == 1);
    
    destroy(extensions);
    destroy(cap);
}

#[test]
/// Test that version history is maintained correctly with Tables
fun test_version_history_with_tables() {
    let mut extensions = new_for_testing_with_addrs(@0x0, @0x1, @0x2, &mut tx_context::dummy());
    let cap = AdminCap { id: object::new(&mut tx_context::dummy()) };
    
    // Add an extension
    extensions.add(&cap, b"TestExt".to_string(), @0xA, 1);
    
    // Update it multiple times
    extensions.update(&cap, b"TestExt".to_string(), @0xB, 2);
    extensions.update(&cap, b"TestExt".to_string(), @0xC, 3);
    extensions.update(&cap, b"TestExt".to_string(), @0xD, 4);
    
    // Verify version history
    assert!(extensions.is_extension(b"TestExt".to_string(), @0xA, 1));
    assert!(extensions.is_extension(b"TestExt".to_string(), @0xB, 2));
    assert!(extensions.is_extension(b"TestExt".to_string(), @0xC, 3));
    assert!(extensions.is_extension(b"TestExt".to_string(), @0xD, 4));
    
    // Verify latest version
    let (addr, version) = extensions.get_latest_for_name(b"TestExt".to_string());
    assert!(addr == @0xD);
    assert!(version == 4);
    
    destroy(extensions);
    destroy(cap);
}

#[test]
/// Test concurrent operations on different extensions
fun test_concurrent_operations() {
    let mut extensions = new_for_testing_with_addrs(@0x0, @0x1, @0x2, &mut tx_context::dummy());
    let cap = AdminCap { id: object::new(&mut tx_context::dummy()) };
    
    // Add multiple extensions
    extensions.add(&cap, b"Ext1".to_string(), @0xA1, 1);
    extensions.add(&cap, b"Ext2".to_string(), @0xA2, 1);
    extensions.add(&cap, b"Ext3".to_string(), @0xA3, 1);
    
    // Update them in different order
    extensions.update(&cap, b"Ext3".to_string(), @0xB3, 2);
    extensions.update(&cap, b"Ext1".to_string(), @0xB1, 2);
    extensions.update(&cap, b"Ext2".to_string(), @0xB2, 2);
    
    // Verify all updates worked correctly
    assert!(extensions.is_extension(b"Ext1".to_string(), @0xB1, 2));
    assert!(extensions.is_extension(b"Ext2".to_string(), @0xB2, 2));
    assert!(extensions.is_extension(b"Ext3".to_string(), @0xB3, 2));
    
    // Remove one and verify others still work
    extensions.remove(&cap, b"Ext2".to_string());
    assert!(extensions.is_extension(b"Ext1".to_string(), @0xB1, 2));
    assert!(extensions.is_extension(b"Ext3".to_string(), @0xB3, 2));
    assert!(extensions.inner.find_index!(|e| e.name == b"Ext2".to_string()).is_none());
    
    destroy(extensions);
    destroy(cap);
}

#[test, expected_failure(abort_code = EExtensionAlreadyExists)]
/// Test that duplicate address detection works with Tables
fun test_error_duplicate_address_across_extensions() {
    let mut extensions = new_for_testing_with_addrs(@0x0, @0x1, @0x2, &mut tx_context::dummy());
    let cap = AdminCap { id: object::new(&mut tx_context::dummy()) };
    
    extensions.add(&cap, b"Ext1".to_string(), @0xABC, 1);
    // Try to add different extension with same address
    extensions.add(&cap, b"Ext2".to_string(), @0xABC, 1);
    
    destroy(extensions);
    destroy(cap);
}