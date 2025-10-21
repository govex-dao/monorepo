// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

/// Unified registry for packages and their action decoders
///
/// This module combines package whitelisting and decoder registration into a single
/// coherent system, ensuring packages and their UI representations are always in sync.
///
/// Key improvements over separate Extensions + ActionDecoderRegistry:
/// - Atomic operations: Can't add package without declaring action types
/// - Single admin cap: Unified governance
/// - Enforced invariants: Package metadata always includes action types
/// - Better discoverability: Query which packages provide which actions
module account_protocol::package_registry;

use std::string::String;
use sui::event;
use sui::object::{Self, UID};
use sui::table::{Self, Table};
use sui::transfer;
use sui::tx_context::TxContext;

// === Errors ===

const EPackageNotFound: u64 = 0;
const EPackageAlreadyExists: u64 = 1;
const EActionTypeNotFound: u64 = 2;
const EActionTypeAlreadyRegistered: u64 = 3;
const EVersionNotMonotonic: u64 = 4;
const EEmptyVersionHistory: u64 = 5;

// === Events ===

public struct PackageAdded has copy, drop {
    name: String,
    addr: address,
    version: u64,
    num_action_types: u64,
    category: String,
}

public struct PackageRemoved has copy, drop {
    name: String,
}

public struct PackageVersionAdded has copy, drop {
    name: String,
    addr: address,
    version: u64,
}

public struct PackageVersionRemoved has copy, drop {
    name: String,
    addr: address,
    version: u64,
}

public struct PackageMetadataUpdated has copy, drop {
    name: String,
    num_action_types: u64,
    category: String,
}

// === Structs ===

/// Unified registry for packages and decoders
public struct PackageRegistry has key {
    id: UID,
    // Package tracking (name -> metadata)
    packages: Table<String, PackageMetadata>,
    // Reverse lookup (addr -> name)
    by_addr: Table<address, String>,
    // Active versions for O(1) validation (addr -> version)
    active_versions: Table<address, u64>,
    // Action type tracking (action type name -> package that provides it)
    action_to_package: Table<String, String>,
}

/// Metadata for a registered package
public struct PackageMetadata has store {
    // Version history (addr, version pairs)
    versions: vector<PackageVersion>,
    // Action types provided by this package (stored as String for serialization)
    action_types: vector<String>,
    // Package category (e.g., "core", "governance", "defi")
    category: String,
    // Optional description
    description: String,
}

/// A package version entry
public struct PackageVersion has copy, drop, store {
    addr: address,
    version: u64,
}

/// Single admin capability for the unified registry
public struct PackageAdminCap has key, store {
    id: UID,
}

/// Human-readable field for decoder output
public struct HumanReadableField has copy, drop, store {
    name: String,
    value: String,
    type_name: String,
}

// === Init ===

fun init(ctx: &mut TxContext) {
    transfer::transfer(PackageAdminCap { id: object::new(ctx) }, ctx.sender());
    transfer::share_object(PackageRegistry {
        id: object::new(ctx),
        packages: table::new(ctx),
        by_addr: table::new(ctx),
        active_versions: table::new(ctx),
        action_to_package: table::new(ctx),
    });
}

// === Admin Functions ===

/// Add a new package to the registry with its action types
/// This is an atomic operation - package and action type metadata are added together
public fun add_package(
    registry: &mut PackageRegistry,
    _cap: &PackageAdminCap,
    name: String,
    addr: address,
    version: u64,
    action_types: vector<String>,
    category: String,
    description: String,
) {
    assert!(!registry.packages.contains(name), EPackageAlreadyExists);
    assert!(!registry.by_addr.contains(addr), EPackageAlreadyExists);

    // Register action types -> package mapping
    // CRITICAL FIX: Assert on duplicates instead of silent skip
    let mut i = 0;
    while (i < action_types.length()) {
        let action_type = &action_types[i];
        assert!(!registry.action_to_package.contains(*action_type), EActionTypeAlreadyRegistered);
        registry.action_to_package.add(*action_type, name);
        i = i + 1;
    };

    // Create package metadata
    let metadata = PackageMetadata {
        versions: vector[PackageVersion { addr, version }],
        action_types,
        category,
        description,
    };

    // Add to registry
    registry.packages.add(name, metadata);
    registry.by_addr.add(addr, name);
    registry.active_versions.add(addr, version);

    // Emit event
    event::emit(PackageAdded {
        name,
        addr,
        version,
        num_action_types: action_types.length(),
        category,
    });
}

/// Remove a package from the registry
/// Also removes all its action type mappings
public fun remove_package(
    registry: &mut PackageRegistry,
    _cap: &PackageAdminCap,
    name: String,
) {
    assert!(registry.packages.contains(name), EPackageNotFound);

    // Get package metadata to clean up action types
    let metadata = registry.packages.borrow(name);
    let action_types = &metadata.action_types;

    // Remove action type mappings
    let mut i = 0;
    while (i < action_types.length()) {
        let action_type = &action_types[i];
        if (registry.action_to_package.contains(*action_type)) {
            registry.action_to_package.remove(*action_type);
        };
        i = i + 1;
    };

    // Remove version history addresses
    let metadata = registry.packages.remove(name);
    let versions = &metadata.versions;
    let mut j = 0;
    while (j < versions.length()) {
        let pkg_version = &versions[j];
        if (registry.by_addr.contains(pkg_version.addr) &&
            *registry.by_addr.borrow(pkg_version.addr) == name) {
            registry.by_addr.remove(pkg_version.addr);
            registry.active_versions.remove(pkg_version.addr);
        };
        j = j + 1;
    };

    // Destroy metadata
    let PackageMetadata { action_types: _, category: _, description: _, versions: _ } = metadata;

    // Emit event
    event::emit(PackageRemoved { name });
}

/// Add a new version to an existing package
/// Version must be greater than all existing versions (monotonic)
public fun update_package_version(
    registry: &mut PackageRegistry,
    _cap: &PackageAdminCap,
    name: String,
    addr: address,
    version: u64,
) {
    assert!(registry.packages.contains(name), EPackageNotFound);
    assert!(!registry.by_addr.contains(addr), EPackageAlreadyExists);

    // Get package metadata and validate version monotonicity
    let metadata = registry.packages.borrow_mut(name);
    assert!(metadata.versions.length() > 0, EEmptyVersionHistory);

    let latest = &metadata.versions[metadata.versions.length() - 1];
    assert!(version > latest.version, EVersionNotMonotonic);

    // Add new version
    metadata.versions.push_back(PackageVersion { addr, version });

    // Update lookups
    registry.by_addr.add(addr, name);
    registry.active_versions.add(addr, version);

    // Emit event
    event::emit(PackageVersionAdded { name, addr, version });
}

/// Remove a specific version from a package's history
public fun remove_package_version(
    registry: &mut PackageRegistry,
    _cap: &PackageAdminCap,
    name: String,
    addr: address,
    version: u64,
) {
    assert!(registry.packages.contains(name), EPackageNotFound);

    let metadata = registry.packages.borrow_mut(name);
    let versions = &mut metadata.versions;

    // Find and remove the version
    let mut i = 0;
    let mut found = false;
    while (i < versions.length()) {
        let pkg_version = &versions[i];
        if (pkg_version.addr == addr && pkg_version.version == version) {
            versions.remove(i);
            found = true;
            break
        };
        i = i + 1;
    };

    assert!(found, EPackageNotFound);

    // CRITICAL FIX: Only remove lookups if address is no longer used by any version
    let metadata_ref = registry.packages.borrow(name);
    let mut address_still_in_use = false;
    let mut k = 0;
    while (k < metadata_ref.versions.length()) {
        if (metadata_ref.versions[k].addr == addr) {
            address_still_in_use = true;
            break
        };
        k = k + 1;
    };

    if (!address_still_in_use) {
        if (registry.by_addr.contains(addr)) {
            registry.by_addr.remove(addr);
        };
        if (registry.active_versions.contains(addr)) {
            registry.active_versions.remove(addr);
        };
    };

    // Emit event
    event::emit(PackageVersionRemoved { name, addr, version });
}

/// Update package metadata (category, description, action types)
public fun update_package_metadata(
    registry: &mut PackageRegistry,
    _cap: &PackageAdminCap,
    name: String,
    new_action_types: vector<String>,
    new_category: String,
    new_description: String,
) {
    assert!(registry.packages.contains(name), EPackageNotFound);

    let metadata = registry.packages.borrow_mut(name);

    // Remove old action type mappings
    let old_action_types = &metadata.action_types;
    let mut i = 0;
    while (i < old_action_types.length()) {
        let action_type = &old_action_types[i];
        if (registry.action_to_package.contains(*action_type)) {
            registry.action_to_package.remove(*action_type);
        };
        i = i + 1;
    };

    // Add new action type mappings
    // CRITICAL FIX: Assert on duplicates instead of silent skip
    let mut j = 0;
    while (j < new_action_types.length()) {
        let action_type = &new_action_types[j];
        assert!(!registry.action_to_package.contains(*action_type), EActionTypeAlreadyRegistered);
        registry.action_to_package.add(*action_type, name);
        j = j + 1;
    };

    // Update metadata
    metadata.action_types = new_action_types;
    metadata.category = new_category;
    metadata.description = new_description;

    // Emit event
    event::emit(PackageMetadataUpdated {
        name,
        num_action_types: new_action_types.length(),
        category: new_category,
    });
}

// === View Functions ===

/// Check if a package exists
public fun has_package(registry: &PackageRegistry, name: String): bool {
    registry.packages.contains(name)
}

/// Check if an action type has a registered package
public fun has_action_type(registry: &PackageRegistry, action_type: String): bool {
    registry.action_to_package.contains(action_type)
}

/// Get which package provides an action type
public fun get_package_for_action(registry: &PackageRegistry, action_type: String): String {
    assert!(registry.action_to_package.contains(action_type), EActionTypeNotFound);
    *registry.action_to_package.borrow(action_type)
}

/// Get package metadata
public fun get_package_metadata(registry: &PackageRegistry, name: String): &PackageMetadata {
    assert!(registry.packages.contains(name), EPackageNotFound);
    registry.packages.borrow(name)
}

/// Get latest version for a package
public fun get_latest_version(registry: &PackageRegistry, name: String): (address, u64) {
    assert!(registry.packages.contains(name), EPackageNotFound);
    let metadata = registry.packages.borrow(name);
    let versions = &metadata.versions;
    assert!(versions.length() > 0, EEmptyVersionHistory);

    let latest = &versions[versions.length() - 1];
    (latest.addr, latest.version)
}

/// Check if a specific (name, addr, version) triple is valid
/// This is the compatibility function for Extensions::is_extension
public fun is_valid_package(
    registry: &PackageRegistry,
    name: String,
    addr: address,
    version: u64,
): bool {
    if (!registry.packages.contains(name)) return false;
    if (!registry.active_versions.contains(addr)) return false;
    if (!registry.by_addr.contains(addr)) return false;

    // CRITICAL FIX: Use borrow() to avoid panic
    *registry.by_addr.borrow(addr) == name && *registry.active_versions.borrow(addr) == version
}

/// Get package name from address
public fun get_package_name(registry: &PackageRegistry, addr: address): String {
    assert!(registry.by_addr.contains(addr), EPackageNotFound);
    *registry.by_addr.borrow(addr)
}

/// Get all action types for a package
public fun get_action_types(registry: &PackageRegistry, name: String): &vector<String> {
    assert!(registry.packages.contains(name), EPackageNotFound);
    let metadata = registry.packages.borrow(name);
    &metadata.action_types
}

/// Get package category
public fun get_category(registry: &PackageRegistry, name: String): &String {
    assert!(registry.packages.contains(name), EPackageNotFound);
    let metadata = registry.packages.borrow(name);
    &metadata.category
}

/// Get package description
public fun get_description(registry: &PackageRegistry, name: String): &String {
    assert!(registry.packages.contains(name), EPackageNotFound);
    let metadata = registry.packages.borrow(name);
    &metadata.description
}

/// Get version history for a package
public fun get_versions(registry: &PackageRegistry, name: String): &vector<PackageVersion> {
    assert!(registry.packages.contains(name), EPackageNotFound);
    let metadata = registry.packages.borrow(name);
    &metadata.versions
}

/// Get registry ID for dynamic field access (decoders)
public fun registry_id(registry: &PackageRegistry): &UID {
    &registry.id
}

/// Get mutable registry ID for adding decoders
public fun registry_id_mut(registry: &mut PackageRegistry): &mut UID {
    &mut registry.id
}

// === PackageMetadata Accessors ===

/// Get action types from metadata
public fun metadata_action_types(metadata: &PackageMetadata): &vector<String> {
    &metadata.action_types
}

/// Get category from metadata
public fun metadata_category(metadata: &PackageMetadata): &String {
    &metadata.category
}

/// Get description from metadata
public fun metadata_description(metadata: &PackageMetadata): &String {
    &metadata.description
}

/// Get versions from metadata
public fun metadata_versions(metadata: &PackageMetadata): &vector<PackageVersion> {
    &metadata.versions
}

// === Helper Functions ===

/// Create a human-readable field for decoder output
public fun new_field(name: String, value: String, type_name: String): HumanReadableField {
    HumanReadableField { name, value, type_name }
}

/// Get field name
public fun field_name(field: &HumanReadableField): &String {
    &field.name
}

/// Get field value
public fun field_value(field: &HumanReadableField): &String {
    &field.value
}

/// Get field type
public fun field_type(field: &HumanReadableField): &String {
    &field.type_name
}

/// Check if decoder exists for action type (via dynamic object field)
/// Action type should be the full type name as a string
public fun has_package_decoder(registry: &PackageRegistry, action_type: String): bool {
    // For dynamic field lookup, we need to convert string to TypeName
    // This is a simplified check - actual decoder attachment happens externally
    registry.action_to_package.contains(action_type)
}

// === PackageVersion Accessors ===

public fun version_addr(version: &PackageVersion): address {
    version.addr
}

public fun version_number(version: &PackageVersion): u64 {
    version.version
}

public fun new_package_version(addr: address, version: u64): PackageVersion {
    PackageVersion { addr, version }
}

// === Test-Only Functions ===

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx);
}

#[test_only]
public fun new_for_testing(ctx: &mut TxContext): PackageRegistry {
    PackageRegistry {
        id: object::new(ctx),
        packages: table::new(ctx),
        by_addr: table::new(ctx),
        active_versions: table::new(ctx),
        action_to_package: table::new(ctx),
    }
}

#[test_only]
public fun new_admin_cap_for_testing(ctx: &mut TxContext): PackageAdminCap {
    PackageAdminCap { id: object::new(ctx) }
}

#[test_only]
public fun add_for_testing(
    registry: &mut PackageRegistry,
    cap: &PackageAdminCap,
    name: String,
    addr: address,
    version: u64,
) {
    add_package(
        registry,
        cap,
        name,
        addr,
        version,
        vector[], // empty action types for testing
        b"test".to_string(),
        b"test package".to_string(),
    );
}

#[test_only]
public fun remove_for_testing(registry: &mut PackageRegistry, cap: &PackageAdminCap, name: String) {
    remove_package(
        registry,
        cap,
        name,
    );
}

#[test_only]
public fun update_for_testing(
    registry: &mut PackageRegistry,
    cap: &PackageAdminCap,
    name: String,
    addr: address,
    version: u64,
) {
    update_package_version(
        registry,
        cap,
        name,
        addr,
        version,
    );
}
