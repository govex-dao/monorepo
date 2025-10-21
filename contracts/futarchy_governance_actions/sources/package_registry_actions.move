// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

/// Unified package registry governance actions
/// Manages both package whitelisting AND action type declarations in a single system
module futarchy_governance_actions::package_registry_actions;

use std::string::String;
use sui::bcs::{Self, BCS};
use account_protocol::{
    account::{Self, Account},
    bcs_validation,
    executable::{Self, Executable},
    intents,
    version_witness::VersionWitness,
    action_validation,
    package_registry::{Self, PackageRegistry, PackageAdminCap},
};

// === Action Type Markers ===

public struct AddPackage has drop {}
public struct RemovePackage has drop {}
public struct UpdatePackageVersion has drop {}
public struct UpdatePackageMetadata has drop {}

// === Action Structs ===

public struct AddPackageAction has store, drop {
    name: String,
    addr: address,
    version: u64,
    action_types: vector<String>,  // Action types as strings (e.g., "package_name::ActionType")
    category: String,
    description: String,
}

public struct RemovePackageAction has store, drop {
    name: String,
}

public struct UpdatePackageVersionAction has store, drop {
    name: String,
    addr: address,
    version: u64,
}

public struct UpdatePackageMetadataAction has store, drop {
    name: String,
    new_action_types: vector<String>,
    new_category: String,
    new_description: String,
}

// === Errors ===

const EUnsupportedActionVersion: u64 = 1;

// === Public Constructors ===

public fun new_add_package(
    name: String,
    addr: address,
    version: u64,
    action_types: vector<String>,
    category: String,
    description: String,
): AddPackageAction {
    AddPackageAction { name, addr, version, action_types, category, description }
}

public fun new_remove_package(name: String): RemovePackageAction {
    RemovePackageAction { name }
}

public fun new_update_package_version(
    name: String,
    addr: address,
    version: u64,
): UpdatePackageVersionAction {
    UpdatePackageVersionAction { name, addr, version }
}

public fun new_update_package_metadata(
    name: String,
    new_action_types: vector<String>,
    new_category: String,
    new_description: String,
): UpdatePackageMetadataAction {
    UpdatePackageMetadataAction { name, new_action_types, new_category, new_description }
}

// === Execution Functions ===

public fun do_add_package<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account,
    version_witness: VersionWitness,
    witness: IW,
    registry: &mut PackageRegistry,
) {
    let specs = executable::intent(executable).action_specs();
    let spec = specs.borrow(executable::action_idx(executable));
    action_validation::assert_action_type<AddPackage>(spec);

    let spec_version = intents::action_spec_version(spec);
    assert!(spec_version == 1, EUnsupportedActionVersion);

    let action_data = intents::action_spec_data(spec);
    let mut reader = bcs::new(*action_data);

    let name = bcs::peel_vec_u8(&mut reader).to_string();
    let addr = bcs::peel_address(&mut reader);
    let version = bcs::peel_u64(&mut reader);

    // Deserialize action type strings
    let action_types_count = bcs::peel_vec_length(&mut reader);
    let mut action_types = vector::empty();
    let mut i = 0;
    while (i < action_types_count) {
        action_types.push_back(bcs::peel_vec_u8(&mut reader).to_string());
        i = i + 1;
    };

    let category = bcs::peel_vec_u8(&mut reader).to_string();
    let description = bcs::peel_vec_u8(&mut reader).to_string();

    bcs_validation::validate_all_bytes_consumed(reader);

    // Borrow PackageAdminCap
    let cap = account::borrow_managed_asset<String, PackageAdminCap>(
        account,
        b"protocol:package_admin_cap".to_string(),
        version_witness
    );

    // Execute - action_types are already Strings
    package_registry::add_package(
        registry,
        cap,
        name,
        addr,
        version,
        action_types,
        category,
        description,
    );

    executable::increment_action_idx(executable);
}

public fun do_remove_package<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account,
    version_witness: VersionWitness,
    witness: IW,
    registry: &mut PackageRegistry,
) {
    let specs = executable::intent(executable).action_specs();
    let spec = specs.borrow(executable::action_idx(executable));
    action_validation::assert_action_type<RemovePackage>(spec);

    let spec_version = intents::action_spec_version(spec);
    assert!(spec_version == 1, EUnsupportedActionVersion);

    let action_data = intents::action_spec_data(spec);
    let mut reader = bcs::new(*action_data);
    let name = bcs::peel_vec_u8(&mut reader).to_string();

    bcs_validation::validate_all_bytes_consumed(reader);

    let cap = account::borrow_managed_asset<String, PackageAdminCap>(
        account,
        b"protocol:package_admin_cap".to_string(),
        version_witness
    );

    package_registry::remove_package(registry, cap, name);

    executable::increment_action_idx(executable);
}

public fun do_update_package_version<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account,
    version_witness: VersionWitness,
    witness: IW,
    registry: &mut PackageRegistry,
) {
    let specs = executable::intent(executable).action_specs();
    let spec = specs.borrow(executable::action_idx(executable));
    action_validation::assert_action_type<UpdatePackageVersion>(spec);

    let spec_version = intents::action_spec_version(spec);
    assert!(spec_version == 1, EUnsupportedActionVersion);

    let action_data = intents::action_spec_data(spec);
    let mut reader = bcs::new(*action_data);

    let name = bcs::peel_vec_u8(&mut reader).to_string();
    let addr = bcs::peel_address(&mut reader);
    let version = bcs::peel_u64(&mut reader);

    bcs_validation::validate_all_bytes_consumed(reader);

    let cap = account::borrow_managed_asset<String, PackageAdminCap>(
        account,
        b"protocol:package_admin_cap".to_string(),
        version_witness
    );

    package_registry::update_package_version(registry, cap, name, addr, version);

    executable::increment_action_idx(executable);
}

public fun do_update_package_metadata<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account,
    version_witness: VersionWitness,
    witness: IW,
    registry: &mut PackageRegistry,
) {
    let specs = executable::intent(executable).action_specs();
    let spec = specs.borrow(executable::action_idx(executable));
    action_validation::assert_action_type<UpdatePackageMetadata>(spec);

    let spec_version = intents::action_spec_version(spec);
    assert!(spec_version == 1, EUnsupportedActionVersion);

    let action_data = intents::action_spec_data(spec);
    let mut reader = bcs::new(*action_data);

    let name = bcs::peel_vec_u8(&mut reader).to_string();

    // Deserialize action type strings
    let action_types_count = bcs::peel_vec_length(&mut reader);
    let mut action_types = vector::empty();
    let mut i = 0;
    while (i < action_types_count) {
        action_types.push_back(bcs::peel_vec_u8(&mut reader).to_string());
        i = i + 1;
    };

    let category = bcs::peel_vec_u8(&mut reader).to_string();
    let description = bcs::peel_vec_u8(&mut reader).to_string();

    bcs_validation::validate_all_bytes_consumed(reader);

    let cap = account::borrow_managed_asset<String, PackageAdminCap>(
        account,
        b"protocol:package_admin_cap".to_string(),
        version_witness
    );

    // action_types are already Strings
    package_registry::update_package_metadata(
        registry,
        cap,
        name,
        action_types,
        category,
        description,
    );

    executable::increment_action_idx(executable);
}

// === Garbage Collection ===

public fun delete_package_registry_action(expired: &mut account_protocol::intents::Expired) {
    let action_spec = account_protocol::intents::remove_action_spec(expired);
    let _ = action_spec;
}
