// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

/// Unified package registry intents for governance
module futarchy_governance_actions::package_registry_intents;

use account_protocol::account::{Self, Account, Auth};
use account_protocol::executable::Executable;
use account_protocol::intent_interface;
use account_protocol::intents::{Intent, Params};
use account_protocol::owned;
use account_protocol::package_registry::{PackageAdminCap, PackageRegistry};
use futarchy_core::version;
use futarchy_governance_actions::package_registry_actions;
use std::bcs;
use std::string::String;
use std::type_name;
use sui::transfer::Receiving;

// === Aliases ===
use fun intent_interface::process_intent as Account.process_intent;

// === Intent Witness Types ===

public struct AcceptPackageAdminCapIntent() has copy, drop;

// === Request Functions ===

/// Request to accept the PackageAdminCap into the DAO's custody
public fun request_accept_package_admin_cap<Outcome: store>(
    auth: Auth,
    account: &mut Account,
    registry: &PackageRegistry,
    params: Params,
    outcome: Outcome,
    cap_id: sui::object::ID,
    ctx: &mut TxContext,
) {
    account.verify(auth);
    params.assert_single_execution();

    intent_interface::build_intent!(
        account,
        registry,
        params,
        outcome,
        b"Accept PackageAdminCap into protocol DAO custody".to_string(),
        version::current(),
        AcceptPackageAdminCapIntent(),
        ctx,
        |intent, iw| {
            owned::new_withdraw_object(intent, account, cap_id, iw);
        },
    );
}

// === Execution Functions ===

/// Execute the intent to accept PackageAdminCap
public fun execute_accept_package_admin_cap<Outcome: store>(
    executable: &mut Executable<Outcome>,
    account: &mut Account,
    registry: &PackageRegistry,
    receiving: Receiving<PackageAdminCap>,
) {
    account.process_intent!(
        registry,
        executable,
        version::current(),
        AcceptPackageAdminCapIntent(),
        |executable, iw| {
            let cap = owned::do_withdraw_object(executable, account, receiving, iw);

            account::add_managed_asset(
                account,
                registry,
                b"protocol:package_admin_cap".to_string(),
                cap,
                version::current(),
            );
        },
    );
}

// === Migration Helper Functions ===

/// One-time migration function to transfer PackageAdminCap to the protocol DAO
entry fun migrate_package_admin_cap_to_dao(
    account: &mut Account,
    registry: &PackageRegistry,
    cap: PackageAdminCap,
    ctx: &mut TxContext,
) {
    account::add_managed_asset(
        account,
        registry,
        b"protocol:package_admin_cap".to_string(),
        cap,
        version::current(),
    );
}

// === Intent Helper Functions ===

/// Add package to registry
/// action_types should be full type names as strings (e.g., "package_name::module_name::ActionType")
public fun add_package_to_intent<Outcome: store, IW: drop>(
    intent: &mut Intent<Outcome>,
    name: String,
    addr: address,
    version: u64,
    action_types: vector<String>,
    category: String,
    description: String,
    intent_witness: IW,
) {
    let action = package_registry_actions::new_add_package(
        name,
        addr,
        version,
        action_types,
        category,
        description,
    );
    let action_data = bcs::to_bytes(&action);
    intent.add_typed_action(
        type_name::get<package_registry_actions::AddPackage>().into_string().to_string(),
        action_data,
        intent_witness
    );
}

/// Remove package from registry
public fun remove_package_from_intent<Outcome: store, IW: drop>(
    intent: &mut Intent<Outcome>,
    name: String,
    intent_witness: IW,
) {
    let action = package_registry_actions::new_remove_package(name);
    let action_data = bcs::to_bytes(&action);
    intent.add_typed_action(
        type_name::get<package_registry_actions::RemovePackage>().into_string().to_string(),
        action_data,
        intent_witness
    );
}

/// Update package version
public fun update_package_version_to_intent<Outcome: store, IW: drop>(
    intent: &mut Intent<Outcome>,
    name: String,
    addr: address,
    version: u64,
    intent_witness: IW,
) {
    let action = package_registry_actions::new_update_package_version(name, addr, version);
    let action_data = bcs::to_bytes(&action);
    intent.add_typed_action(
        type_name::get<package_registry_actions::UpdatePackageVersion>().into_string().to_string(),
        action_data,
        intent_witness
    );
}

/// Update package metadata
/// new_action_types should be full type names as strings (e.g., "package_name::module_name::ActionType")
public fun update_package_metadata_to_intent<Outcome: store, IW: drop>(
    intent: &mut Intent<Outcome>,
    name: String,
    new_action_types: vector<String>,
    new_category: String,
    new_description: String,
    intent_witness: IW,
) {
    let action = package_registry_actions::new_update_package_metadata(
        name,
        new_action_types,
        new_category,
        new_description,
    );
    let action_data = bcs::to_bytes(&action);
    intent.add_typed_action(
        type_name::get<package_registry_actions::UpdatePackageMetadata>().into_string().to_string(),
        action_data,
        intent_witness
    );
}
