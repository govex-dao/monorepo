// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

// Portions of this file are derived from the account.tech Move Framework project.
// Those portions remain licensed under the Apache License, Version 2.0.

/// This module allows to manage Account settings.
/// The actions are related to the modifications of all the fields of the Account (except Intents and Config).
/// All these fields are encapsulated in the `Account` struct and each managed in their own module.
/// They are only accessible mutably via package functions defined in account.move which are used here only.
/// 
/// Dependencies are all the packages and their versions that the account can call (including this one).
/// The allowed dependencies are defined in the `Extensions` struct and are maintained by account.tech team.
/// Optionally, any package can be added to the account if unverified_allowed is true.
/// 
/// Accounts can choose to use any version of any package and must explicitly migrate to the new version.
/// This is closer to a trustless model preventing anyone with the UpgradeCap from updating the dependencies maliciously.

module account_protocol::config;

// === Imports ===

use std::{string::{Self, String}, option::Option, type_name::{Self, TypeName}};
use sui::bcs::{Self, BCS};
use sui::{vec_set::{Self, VecSet}, event};
use account_protocol::{
    account::{Self, Account, Auth},
    intents::{Intent, Expired, Params},
    executable::Executable,
    deps::{Self, Dep},
    metadata,
    version,
    intent_interface,
};
use account_protocol::package_registry::PackageRegistry;

use fun account_protocol::intents::add_typed_action as Intent.add_typed_action;

// === Aliases ===

use fun intent_interface::build_intent as Account.build_intent;
use fun intent_interface::process_intent as Account.process_intent;

// === Error Constants ===

/// Error when action version is not supported
const EUnsupportedActionVersion: u64 = 1;

// === Action Type Markers ===

/// Update account dependencies
public struct ConfigUpdateDeps has drop {}
/// Toggle unverified packages allowed
public struct ConfigToggleUnverified has drop {}
/// Update account metadata
public struct ConfigUpdateMetadata has drop {}
/// Configure object deposit settings
public struct ConfigUpdateDeposits has drop {}
/// Manage type whitelist for deposits
public struct ConfigManageWhitelist has drop {}

public fun config_update_deps(): ConfigUpdateDeps { ConfigUpdateDeps {} }
public fun config_toggle_unverified(): ConfigToggleUnverified { ConfigToggleUnverified {} }
public fun config_update_metadata(): ConfigUpdateMetadata { ConfigUpdateMetadata {} }
public fun config_update_deposits(): ConfigUpdateDeposits { ConfigUpdateDeposits {} }
public fun config_manage_whitelist(): ConfigManageWhitelist { ConfigManageWhitelist {} }

// === Structs ===

/// Intent Witness
public struct ConfigDepsIntent() has drop;
/// Intent Witness
public struct ToggleUnverifiedAllowedIntent() has drop;
/// Intent Witness for deposit configuration
public struct ConfigureDepositsIntent() has drop;
/// Intent Witness for whitelist management
public struct ManageWhitelistIntent() has drop;

/// Action struct wrapping the deps account field into an action
public struct ConfigDepsAction has drop, store {
    deps: vector<Dep>,
}
/// Action struct wrapping the unverified_allowed account field into an action
public struct ToggleUnverifiedAllowedAction has drop, store {}
/// Action to configure object deposit settings
public struct ConfigureDepositsAction has drop, store {
    enable: bool,
    new_max: Option<u128>,
    reset_counter: bool,
}
/// Action to manage type whitelist for deposits
public struct ManageWhitelistAction has drop, store {
    add_types: vector<String>,
    remove_types: vector<String>,
}

// === Public Constructors for Actions ===

/// Create a new ConfigDepsAction
/// Allows external modules to construct this action for their own intents
public fun new_config_deps_action(deps: vector<Dep>): ConfigDepsAction {
    ConfigDepsAction { deps }
}

/// Create a new ToggleUnverifiedAllowedAction
/// Allows external modules to construct this action for their own intents
public fun new_toggle_unverified_action(): ToggleUnverifiedAllowedAction {
    ToggleUnverifiedAllowedAction {}
}

/// Create a new ConfigureDepositsAction
/// Allows external modules to construct this action for their own intents
public fun new_configure_deposits_action(
    enable: bool,
    new_max: Option<u128>,
    reset_counter: bool,
): ConfigureDepositsAction {
    ConfigureDepositsAction { enable, new_max, reset_counter }
}

/// Create a new ManageWhitelistAction
/// Allows external modules to construct this action for their own intents
public fun new_manage_whitelist_action(
    add_types: vector<String>,
    remove_types: vector<String>,
): ManageWhitelistAction {
    ManageWhitelistAction { add_types, remove_types }
}

// === Helper Functions for BCS Deserialization ===

/// Helper to deserialize deps data as three vectors
/// Made public to allow governance layers (futarchy, etc.) to reuse execution logic
public fun peel_deps_as_vectors(reader: &mut BCS): (vector<String>, vector<address>, vector<u64>) {
    let len = bcs::peel_vec_length(reader);
    let mut names = vector::empty();
    let mut addrs = vector::empty();
    let mut versions = vector::empty();
    let mut i = 0;
    while (i < len) {
        // Each Dep has: name (String), addr (address), version (u64)
        names.push_back(string::utf8(bcs::peel_vec_u8(reader)));
        addrs.push_back(bcs::peel_address(reader));
        versions.push_back(bcs::peel_u64(reader));
        i = i + 1;
    };
    (names, addrs, versions)
}

// === Destruction Functions ===

/// Destroy a ConfigDepsAction after serialization
public fun destroy_config_deps_action(action: ConfigDepsAction) {
    let ConfigDepsAction { deps: _ } = action;
}

/// Destroy a ToggleUnverifiedAllowedAction after serialization
public fun destroy_toggle_unverified_action(action: ToggleUnverifiedAllowedAction) {
    let ToggleUnverifiedAllowedAction {} = action;
}

/// Destroy a ConfigureDepositsAction after serialization
public fun destroy_configure_deposits_action(action: ConfigureDepositsAction) {
    let ConfigureDepositsAction { enable: _, new_max: _, reset_counter: _ } = action;
}

/// Destroy a ManageWhitelistAction after serialization
public fun destroy_manage_whitelist_action(action: ManageWhitelistAction) {
    let ManageWhitelistAction { add_types: _, remove_types: _ } = action;
}

/// Helper to deserialize vector<String>
fun peel_vector_string(reader: &mut BCS): vector<String> {
    let len = bcs::peel_vec_length(reader);
    let mut i = 0;
    let mut vec = vector::empty();
    while (i < len) {
        vec.push_back(string::utf8(bcs::peel_vec_u8(reader)));
        i = i + 1;
    };
    vec
}

// === Public functions ===

/// Authorized addresses can configure object deposit settings directly
public fun configure_deposits<Config: store>(
    auth: Auth,
    account: &mut Account,
    enable: bool,
    new_max: Option<u128>,
    reset_counter: bool,
) {
    account.verify(auth);
    // Apply the configuration using the helper function
    account.apply_deposit_config(enable, new_max, reset_counter);
}

/// Authorized addresses can edit the metadata of the account
public fun edit_metadata<Config: store>(
    auth: Auth,
    account: &mut Account,
    keys: vector<String>,
    values: vector<String>,
) {
    account.verify(auth);
    *account::metadata_mut(account, version::current()) = metadata::from_keys_values(keys, values);
}

/// Authorized addresses can update the existing dependencies of the account to the latest versions
public fun update_extensions_to_latest<Config: store>(
    auth: Auth,
    account: &mut Account,
    registry: &PackageRegistry,
) {
    account.verify(auth);

    let mut i = 0;
    let mut new_names = vector<String>[];
    let mut new_addrs = vector<address>[];
    let mut new_versions = vector<u64>[];

    while (i < account.deps().length()) {
        let dep = account.deps().get_by_idx(i);
        if (registry.is_valid_package(dep.name(), dep.addr(), dep.version())) {
            let (addr, version) = registry.get_latest_version(dep.name());
            new_names.push_back(dep.name());
            new_addrs.push_back(addr);
            new_versions.push_back(version);
        } else {
            // else cannot automatically update to latest version so add as is
            new_names.push_back(dep.name());
            new_addrs.push_back(dep.addr());
            new_versions.push_back(dep.version());
        };
        i = i + 1;
    };

    *account::deps_mut(account, version::current()) = 
        deps::new_inner(registry, account.deps(), new_names, new_addrs, new_versions);
}

/// Creates an intent to update the dependencies of the account
public fun request_config_deps<Config: store, Outcome: store>(
    auth: Auth,
    account: &mut Account,
    params: Params,
    outcome: Outcome,
    registry: &PackageRegistry,
    names: vector<String>,
    addresses: vector<address>,
    versions: vector<u64>,
    ctx: &mut TxContext
) {
    account.verify(auth);
    params.assert_single_execution();

    let mut deps = deps::new_inner(registry, account.deps(), names, addresses, versions);
    let deps_inner = *deps.inner_mut();

    account.build_intent!(
        params,
        outcome, 
        b"".to_string(),
        version::current(),
        ConfigDepsIntent(),   
        ctx,
        |intent, iw| {
            // Create the action struct
            let action = ConfigDepsAction { deps: deps_inner };

            // Serialize it
            let action_data = bcs::to_bytes(&action);

            // Add to intent with pre-serialized bytes
            intent.add_typed_action(
                config_update_deps(),
                action_data,
                iw
            );

            // Explicitly destroy the action struct
            destroy_config_deps_action(action);
        },
    );
}

/// Executes an intent updating the dependencies of the account
public fun execute_config_deps<Config: store, Outcome: store>(
    executable: &mut Executable<Outcome>,
    account: &mut Account,
    registry: &PackageRegistry,
) {
    account.process_intent!(
        executable,
        version::current(),
        ConfigDepsIntent(),
        |executable, _iw| {
            // Get BCS bytes from ActionSpec
            let specs = executable.intent().action_specs();
            let spec = specs.borrow(executable.action_idx());

            // Check version before deserialization
            let spec_version = account_protocol::intents::action_spec_version(spec);
            assert!(spec_version == 1, EUnsupportedActionVersion);

            let action_data = account_protocol::intents::action_spec_data(spec);

            // Create BCS reader and deserialize
            let mut reader = bcs::new(*action_data);
            let (names, addrs, versions) = peel_deps_as_vectors(&mut reader);

            // Validate all bytes consumed (prevent trailing data attacks)
            account_protocol::bcs_validation::validate_all_bytes_consumed(reader);

            // Apply the action - reconstruct deps using the public constructor
            *account::deps_mut(account, version::current()) =
                deps::new_inner(registry, account.deps(), names, addrs, versions);
            account_protocol::executable::increment_action_idx(executable);
        }
    );
} 

/// Deletes the ConfigDepsAction from an expired intent
public fun delete_config_deps(expired: &mut Expired) {
    let spec = expired.remove_action_spec();
    let action_data = account_protocol::intents::action_spec_data(&spec);
    let mut reader = bcs::new(*action_data);

    // We don't need the values, but we must peel them to consume the bytes
    let (names, addrs, versions) = peel_deps_as_vectors(&mut reader);
    // Just consume the data without creating the struct
    let _ = names;
    let _ = addrs;
    let _ = versions;
}

/// Creates an intent to toggle the unverified_allowed flag of the account
public fun request_toggle_unverified_allowed<Config: store, Outcome: store>(
    auth: Auth,
    account: &mut Account, 
    params: Params,
    outcome: Outcome,
    ctx: &mut TxContext
) {
    account.verify(auth);
    params.assert_single_execution();
    
    account.build_intent!(
        params,
        outcome,
        b"".to_string(),
        version::current(),
        ToggleUnverifiedAllowedIntent(),
        ctx,
        |intent, iw| {
            // Create the action struct
            let action = ToggleUnverifiedAllowedAction {};

            // Serialize it
            let action_data = bcs::to_bytes(&action);

            // Add to intent with pre-serialized bytes
            intent.add_typed_action(
                config_toggle_unverified(),
                action_data,
                iw
            );

            // Explicitly destroy the action struct
            destroy_toggle_unverified_action(action);
        },
    );
}

/// Executes an intent toggling the unverified_allowed flag of the account
public fun execute_toggle_unverified_allowed<Config: store, Outcome: store>(
    executable: &mut Executable<Outcome>,
    account: &mut Account,
) {
    account.process_intent!(
        executable,
        version::current(),
        ToggleUnverifiedAllowedIntent(),
        |executable, _iw| {
            // Check version before execution
            let specs = executable.intent().action_specs();
            let spec = specs.borrow(executable.action_idx());
            let spec_version = account_protocol::intents::action_spec_version(spec);
            assert!(spec_version == 1, EUnsupportedActionVersion);

            // ToggleUnverifiedAllowedAction is an empty struct, no deserialization needed
            // Just increment the action index
            account::deps_mut(account, version::current()).toggle_unverified_allowed();
            account_protocol::executable::increment_action_idx(executable);
        },
    );    
}

/// Deletes the ToggleUnverifiedAllowedAction from an expired intent
public fun delete_toggle_unverified_allowed(expired: &mut Expired) {
    let spec = expired.remove_action_spec();
    // ToggleUnverifiedAllowedAction is an empty struct, no deserialization needed
    let ToggleUnverifiedAllowedAction {} = ToggleUnverifiedAllowedAction {};
}

/// Creates an intent to configure object deposit settings
public fun request_configure_deposits<Config: store, Outcome: store>(
    auth: Auth,
    account: &mut Account,
    outcome: Outcome,
    params: Params,
    enable: bool,
    new_max: Option<u128>,
    reset_counter: bool,
    ctx: &mut TxContext,
) {
    account.verify(auth);
    account.build_intent!(
        params,
        outcome,
        b"ConfigureDepositsIntent".to_string(),
        version::current(),
        ConfigureDepositsIntent(),
        ctx,
        |intent, iw| {
            // Create the action struct
            let action = ConfigureDepositsAction { enable, new_max, reset_counter };

            // Serialize it
            let action_data = bcs::to_bytes(&action);

            // Add to intent with pre-serialized bytes
            intent.add_typed_action(
                config_update_deposits(),
                action_data,
                iw
            );

            // Explicitly destroy the action struct
            destroy_configure_deposits_action(action);
        },
    );
}

/// Executes an intent to configure object deposit settings
public fun execute_configure_deposits<Config: store, Outcome: store>(
    executable: &mut Executable<Outcome>,
    account: &mut Account,
) {
    account.process_intent!(
        executable,
        version::current(),
        ConfigureDepositsIntent(),
        |executable, _iw| {
            // Get BCS bytes from ActionSpec
            let specs = executable.intent().action_specs();
            let spec = specs.borrow(executable.action_idx());

            // Check version before deserialization
            let spec_version = account_protocol::intents::action_spec_version(spec);
            assert!(spec_version == 1, EUnsupportedActionVersion);

            let action_data = account_protocol::intents::action_spec_data(spec);

            // Create BCS reader and deserialize
            let mut reader = bcs::new(*action_data);
            let enable = bcs::peel_bool(&mut reader);
            let new_max = bcs::peel_option_u128(&mut reader);
            let reset_counter = bcs::peel_bool(&mut reader);

            // Validate all bytes consumed (prevent trailing data attacks)
            account_protocol::bcs_validation::validate_all_bytes_consumed(reader);

            // Apply the action
            account.apply_deposit_config(enable, new_max, reset_counter);
            account_protocol::executable::increment_action_idx(executable);
        },
    );
}

/// Deletes the ConfigureDepositsAction from an expired intent
public fun delete_configure_deposits(expired: &mut Expired) {
    let spec = expired.remove_action_spec();
    let action_data = account_protocol::intents::action_spec_data(&spec);
    let mut reader = bcs::new(*action_data);

    // We don't need the values, but we must peel them to consume the bytes
    let ConfigureDepositsAction { enable: _, new_max: _, reset_counter: _ } = ConfigureDepositsAction {
        enable: bcs::peel_bool(&mut reader),
        new_max: bcs::peel_option_u128(&mut reader),
        reset_counter: bcs::peel_bool(&mut reader)
    };
}

/// Creates an intent to manage type whitelist
public fun request_manage_whitelist<Config: store, Outcome: store>(
    auth: Auth,
    account: &mut Account,
    outcome: Outcome,
    params: Params,
    add_types: vector<String>,
    remove_types: vector<String>,
    ctx: &mut TxContext,
) {
    account.verify(auth);
    account.build_intent!(
        params,
        outcome,
        b"ManageWhitelistIntent".to_string(),
        version::current(),
        ManageWhitelistIntent(),
        ctx,
        |intent, iw| {
            // Create the action struct
            let action = ManageWhitelistAction { add_types, remove_types };

            // Serialize it
            let action_data = bcs::to_bytes(&action);

            // Add to intent with pre-serialized bytes
            intent.add_typed_action(
                config_manage_whitelist(),
                action_data,
                iw
            );

            // Explicitly destroy the action struct
            destroy_manage_whitelist_action(action);
        },
    );
}

/// Executes an intent to manage type whitelist
public fun execute_manage_whitelist<Config: store, Outcome: store>(
    executable: &mut Executable<Outcome>,
    account: &mut Account,
) {
    account.process_intent!(
        executable,
        version::current(),
        ManageWhitelistIntent(),
        |executable, _iw| {
            // Get BCS bytes from ActionSpec
            let specs = executable.intent().action_specs();
            let spec = specs.borrow(executable.action_idx());

            // Check version before deserialization
            let spec_version = account_protocol::intents::action_spec_version(spec);
            assert!(spec_version == 1, EUnsupportedActionVersion);

            let action_data = account_protocol::intents::action_spec_data(spec);

            // Create BCS reader and deserialize
            let mut reader = bcs::new(*action_data);
            let add_types = peel_vector_string(&mut reader);
            let remove_types = peel_vector_string(&mut reader);

            // Validate all bytes consumed (prevent trailing data attacks)
            account_protocol::bcs_validation::validate_all_bytes_consumed(reader);

            // Apply the action
            account.apply_whitelist_changes(&add_types, &remove_types);
            account_protocol::executable::increment_action_idx(executable);
        },
    );
}

/// Deletes the ManageWhitelistAction from an expired intent
public fun delete_manage_whitelist(expired: &mut Expired) {
    let spec = expired.remove_action_spec();
    let action_data = account_protocol::intents::action_spec_data(&spec);
    let mut reader = bcs::new(*action_data);

    // We don't need the values, but we must peel them to consume the bytes
    let ManageWhitelistAction { add_types: _, remove_types: _ } = ManageWhitelistAction {
        add_types: peel_vector_string(&mut reader),
        remove_types: peel_vector_string(&mut reader)
    };
}
