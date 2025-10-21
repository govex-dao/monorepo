// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

// Portions of this file are derived from the account.tech Move Framework project.
// Those portions remain licensed under the Apache License, Version 2.0.

/// This is the core module managing the account Account.
/// It provides the apis to create, approve and execute intents with actions.
///
/// The flow is as follows:
///   1. An intent is created by stacking actions into it.
///      Actions are pushed from first to last, they must be executed then destroyed in the same order.
///   2. When the intent is resolved (threshold reached, quorum reached, etc), it can be executed.
///      This returns an Executable hot potato constructed from certain fields of the validated Intent.
///      It is directly passed into action functions to enforce account approval for an action to be executed.
///   3. The module that created the intent must destroy all of the actions and the Executable after execution
///      by passing the same witness that was used for instantiation.
///      This prevents the actions or the intent to be stored instead of executed.
///
/// Dependencies can create and manage dynamic fields for an account.
/// They should use custom types as keys to enable access only via the accessors defined.
///
/// Functions related to authentication, intent resolution, state of intents and config for an account type
/// must be called from the module that defines the config of the account.
/// They necessitate a config_witness to ensure the caller is a dependency of the account.
///
/// The rest of the functions manipulating the common state of accounts are only called within this package.

module account_protocol::account;

use account_protocol::package_registry;
use account_protocol::deps::{Self, Deps};
use account_protocol::executable::{Self, Executable};
use account_protocol::intents::{Self, Intents, Intent, Expired, Params};
use account_protocol::metadata::{Self, Metadata};
use account_protocol::version;
use account_protocol::version_witness::{Self, VersionWitness};
use std::option::Option;
use std::string::String;
use std::type_name::{Self, TypeName};
use sui::clock::Clock;
use sui::dynamic_field as df;
use sui::dynamic_object_field as dof;
use sui::event;
use sui::package;
use sui::transfer::Receiving;
use sui::vec_set::{Self, VecSet};

// === Imports ===

// === Errors ===

const ECantBeRemovedYet: u64 = 1;
const EHasntExpired: u64 = 2;
const ECantBeExecutedYet: u64 = 3;
const EWrongAccount: u64 = 4;
const ENotCalledFromConfigModule: u64 = 5;
const EActionsRemaining: u64 = 6;
const EManagedDataAlreadyExists: u64 = 7;
const EManagedDataDoesntExist: u64 = 8;
const EManagedAssetAlreadyExists: u64 = 9;
const EManagedAssetDoesntExist: u64 = 10;
const EDepositsDisabled: u64 = 11;
const EObjectCountUnderflow: u64 = 12;
const EWhitelistTooLarge: u64 = 13;
const EObjectLimitReached: u64 = 14;
const EMaxObjectsReached: u64 = 14;
const EWrongConfigType: u64 = 15;
const ENotConfigModule: u64 = 16;

// === Structs ===

public struct ACCOUNT has drop {}

/// Shared multisig Account object.
/// Config is stored as a dynamic field to allow runtime config migration
public struct Account has key, store {
    id: UID,
    // arbitrary data that can be proposed and added by members
    // first field is a human readable name to differentiate the multisig accounts
    metadata: Metadata,
    // ids and versions of the packages this account is using
    // idx 0: account_protocol, idx 1: account_actions optionally
    deps: Deps,
    // open intents, key should be a unique descriptive name
    intents: Intents,
    // config: Config,  ← MOVED TO DYNAMIC FIELD (see ConfigKey below)
}

/// Object tracking state stored as dynamic field
/// Separate struct to allow extensions to interact without circular deps
public struct ObjectTracker has copy, drop, store {}

public struct ObjectTrackerState has copy, store {
    // Current object count (excluding coins)
    object_count: u128,
    // Whether permissionless deposits are enabled
    deposits_open: bool,
    // Maximum objects before auto-disabling deposits
    max_objects: u128,
    // Whitelisted types that bypass restrictions (O(1) lookups with VecSet)
    // Store canonical string representation for serializability
    whitelisted_types: VecSet<String>,
}

// === Dynamic Field Keys for Config Storage ===

/// Key for storing config as a dynamic field
public struct ConfigKey has copy, drop, store {}

/// Key for storing config type name (for runtime validation)
public struct ConfigTypeKey has copy, drop, store {}

// === Events ===

/// Protected type ensuring provenance, authenticate an address to an account.
public struct Auth {
    // address of the account that created the auth
    account_addr: address,
}

// === Upgradeable Configuration Functions ===
// These are functions (not constants) so they can be changed in package upgrades

/// Maximum whitelist size - can be changed in future upgrades
public fun max_whitelist_size(): u64 {
    50 // Reasonable limit - can increase in upgrades if needed
}

/// Default max objects - can be changed in future upgrades
public fun default_max_objects(): u128 {
    10000 // Adjust this in future upgrades if needed
}

//**************************************************************************************************//
// Public functions                                                                                //
//**************************************************************************************************//

fun init(otw: ACCOUNT, ctx: &mut TxContext) {
    package::claim_and_keep(otw, ctx); // to create Display objects in the future
}

/// Initialize object tracking for an account (called during account creation)
public(package) fun init_object_tracker(account: &mut Account, max_objects: u128) {
    if (!df::exists_(&account.id, ObjectTracker {})) {
        df::add(
            &mut account.id,
            ObjectTracker {},
            ObjectTrackerState {
                object_count: 0,
                deposits_open: true,
                max_objects: if (max_objects > 0) max_objects else default_max_objects(),
                whitelisted_types: vec_set::empty(),
            },
        );
    }
}

/// Get or create object tracker state
public(package) fun ensure_object_tracker(
    account: &mut Account,
): &mut ObjectTrackerState {
    if (!df::exists_(&account.id, ObjectTracker {})) {
        init_object_tracker(account, default_max_objects());
    };
    df::borrow_mut(&mut account.id, ObjectTracker {})
}

/// Apply deposit configuration changes
public(package) fun apply_deposit_config(
    account: &mut Account,
    enable: bool,
    new_max: Option<u128>,
    reset_counter: bool,
) {
    let tracker = ensure_object_tracker(account);
    tracker.deposits_open = enable;

    if (new_max.is_some()) {
        tracker.max_objects = *new_max.borrow();
    };

    if (reset_counter) {
        tracker.object_count = 0;
    };
}

/// Apply whitelist changes
public(package) fun apply_whitelist_changes(
    account: &mut Account,
    add_types: &vector<String>,
    remove_types: &vector<String>,
) {
    let tracker = ensure_object_tracker(account);

    // Remove types first
    let mut i = 0;
    while (i < remove_types.length()) {
        let type_str = &remove_types[i];
        vec_set::remove(&mut tracker.whitelisted_types, type_str);
        i = i + 1;
    };

    // Add new types with size check
    i = 0;
    while (i < add_types.length()) {
        let type_str = add_types[i];
        if (!vec_set::contains(&tracker.whitelisted_types, &type_str)) {
            assert!(
                vec_set::size(&tracker.whitelisted_types) < max_whitelist_size(),
                EWhitelistTooLarge,
            );
            vec_set::insert(&mut tracker.whitelisted_types, type_str);
        };
        i = i + 1;
    };

    // Whitelist updated
}

/// Verifies all actions have been processed and destroys the executable.
/// Called to complete the intent execution.
public fun confirm_execution<Outcome: drop + store>(
    account: &mut Account,
    executable: Executable<Outcome>,
) {
    let actions_length = executable.intent().action_specs().length();
    assert!(executable.action_idx() == actions_length, EActionsRemaining);

    let intent = executable.destroy();
    intent.assert_is_account(account.addr());

    account.intents.add_intent(intent);
}

/// Destroys an intent if it has no remaining execution.
/// Expired needs to be emptied by deleting each action in the bag within their own module.
public fun destroy_empty_intent<Outcome: store + drop>(
    account: &mut Account,
    key: String,
    ctx: &mut TxContext,
): Expired {
    assert!(account.intents.get<Outcome>(key).execution_times().is_empty(), ECantBeRemovedYet);
    account.intents.destroy_intent<Outcome>(key, ctx)
}

/// Destroys an intent if it has expired.
/// Expired needs to be emptied by deleting each action in the bag within their own module.
public fun delete_expired_intent<Outcome: store + drop>(
    account: &mut Account,
    key: String,
    clock: &Clock,
    ctx: &mut TxContext,
): Expired {
    assert!(
        clock.timestamp_ms() >= account.intents.get<Outcome>(key).expiration_time(),
        EHasntExpired,
    );
    account.intents.destroy_intent<Outcome>(key, ctx)
}

/// Asserts that the function is called from the module defining the config of the account.
/// Static version: validate witness matches config type (no account needed)
fun assert_is_config_module_static<Config, CW: drop>() {
    let config_type = type_name::with_defining_ids<Config>();
    let witness_type = type_name::with_defining_ids<CW>();
    assert!(
        config_type.address_string() == witness_type.address_string() &&
        config_type.module_string() == witness_type.module_string(),
        ENotConfigModule,
    );
}

/// Runtime version: validate witness matches stored config type
public(package) fun assert_is_config_module<Config: store, CW: drop>(
    account: &Account,
    _config_witness: CW,
) {
    // First check the stored type matches requested type
    let stored_type = df::borrow<ConfigTypeKey, TypeName>(&account.id, ConfigTypeKey {});
    let requested_type = type_name::get<Config>();
    assert!(&requested_type == stored_type, EWrongConfigType);

    // Then validate witness package/module matches config
    assert_is_config_module_static<Config, CW>();
}

/// Witness-only version: validate witness matches stored config type (no explicit Config needed)
public(package) fun assert_is_config_module_witness<CW: drop>(
    account: &Account,
    _config_witness: CW,
) {
    // Get the stored config type
    let stored_type = df::borrow<ConfigTypeKey, TypeName>(&account.id, ConfigTypeKey {});
    let witness_type = type_name::with_defining_ids<CW>();

    // Validate witness package/module matches stored config package/module
    assert!(
        stored_type.address_string() == witness_type.address_string() &&
        stored_type.module_string() == witness_type.module_string(),
        ENotConfigModule,
    );
}

/// Cancel an active intent and return its Expired bag for GC draining.
///
/// Security:
/// - `config_witness` gates **authority**: only the Config module may cancel.
/// - `deps_witness` gates **compatibility**: caller must be compiled against the
///   same `account_protocol` package identity/version the Account expects.
///   This prevents mismatched callers from older/newer packages.
public fun cancel_intent<Config: store, Outcome: store + drop, CW: drop>(
    account: &mut Account,
    key: String,
    deps_witness: VersionWitness,
    config_witness: CW,
    ctx: &mut TxContext,
): Expired {
    // Ensure the protocol dependency matches what this account expects
    account.deps().check(deps_witness);
    // Only the config module may cancel
    assert_is_config_module_witness(account, config_witness);
    // Convert to Expired - deleters will handle unlocking during drain
    account.intents.destroy_intent<Outcome>(key, ctx)
}

/// Helper function to transfer an object to the account with tracking.
/// Excludes Coin types and whitelisted types from restrictions.
public fun keep<T: key + store>(account: &mut Account, obj: T, ctx: &TxContext) {
    let type_name = type_name::with_defining_ids<T>();
    let is_coin = is_coin_type(type_name);

    // Check if type is whitelisted
    let is_whitelisted = {
        let tracker = ensure_object_tracker(account);
        let ascii_str = type_name::into_string(type_name);
        let type_str = ascii_str.to_string();
        vec_set::contains(&tracker.whitelisted_types, &type_str)
    };

    // Only apply restrictions to non-coin, non-whitelisted types
    if (!is_coin && !is_whitelisted) {
        // Get tracker state for checking
        let (deposits_open, sender_is_self) = {
            let tracker = ensure_object_tracker(account);
            (tracker.deposits_open, ctx.sender() == account.addr())
        };

        // Check if deposits are allowed
        if (!deposits_open) {
            // Allow self-deposits even when closed
            assert!(sender_is_self, EDepositsDisabled);
        };

        // Now update tracker state
        let tracker = ensure_object_tracker(account);

        // Increment counter only for restricted types
        tracker.object_count = tracker.object_count + 1;

        // Auto-disable if hitting threshold
        if (tracker.object_count >= tracker.max_objects) {
            tracker.deposits_open = false;
            // Auto-disabled deposits at threshold
        };
    };

    transfer::public_transfer(obj, account.addr());
}

/// Unpacks and verifies the Auth matches the account.
public fun verify(account: &Account, auth: Auth) {
    let Auth { account_addr } = auth;

    assert!(account.addr() == account_addr, EWrongAccount);
}

/// Returns the account address from Auth.
public fun auth_account_addr(auth: &Auth): address {
    auth.account_addr
}

//**************************************************************************************************//
// Deps-only functions                                                                              //
//**************************************************************************************************//

/// The following functions are used to compose intents in external modules and packages.
///
/// The proper instantiation and execution of an intent is ensured by an intent witness.
/// This is a drop only type defined in the intent module preventing other modules to misuse the intent.
///
/// Additionally, these functions require a version witness which is a protected type for the protocol.
/// It is checked against the dependencies of the account to ensure the package being called is authorized.
/// VersionWitness is a wrapper around a type defined in the version of the package being called.
/// It behaves like a witness but it is usable in the entire package instead of in a single module.

/// Creates a new intent. Can only be called from a dependency of the account.
public fun create_intent<Outcome: store, IW: drop>(
    account: &Account,
    params: Params,
    outcome: Outcome, // resolution settings
    managed_name: String, // managed struct/object name for the role
    version_witness: VersionWitness, // proof of the package address that creates the intent
    intent_witness: IW, // intent witness
    ctx: &mut TxContext,
): Intent<Outcome> {
    // ensures the package address is a dependency for this account
    account.deps().check(version_witness);

    params.new_intent(
        outcome,
        managed_name,
        account.addr(),
        intent_witness,
        ctx,
    )
}

/// Adds an intent to the account. Can only be called from a dependency of the account.
public fun insert_intent<Outcome: store, IW: drop>(
    account: &mut Account,
    intent: Intent<Outcome>,
    version_witness: VersionWitness,
    intent_witness: IW,
) {
    // ensures the package address is a dependency for this account
    account.deps().check(version_witness);
    // ensures the right account is passed
    intent.assert_is_account(account.addr());
    // ensures the intent is created by the same package that creates the action
    intent.assert_is_witness(intent_witness);

    account.intents.add_intent(intent);
}

/// Managed data and assets:
/// Data structs and Assets objects attached as dynamic fields to the account object.
/// They are separated to improve objects discoverability on frontends and indexers.
/// Keys must be custom types defined in the same module where the function is implemented.

/// Adds a managed data struct to the account.
public fun add_managed_data<Key: copy + drop + store, Data: store>(
    account: &mut Account,
    key: Key,
    data: Data,
    version_witness: VersionWitness,
) {
    assert!(!has_managed_data(account, key), EManagedDataAlreadyExists);
    account.deps().check(version_witness);
    df::add(&mut account.id, key, data);
}

/// Checks if a managed data struct exists in the account.
public fun has_managed_data<Key: copy + drop + store>(
    account: &Account,
    key: Key,
): bool {
    df::exists_(&account.id, key)
}

/// Borrows a managed data struct from the account.
public fun borrow_managed_data<Key: copy + drop + store, Data: store>(
    account: &Account,
    key: Key,
    version_witness: VersionWitness,
): &Data {
    assert!(has_managed_data(account, key), EManagedDataDoesntExist);
    account.deps().check(version_witness);
    df::borrow(&account.id, key)
}

/// Borrows a managed data struct mutably from the account.
public fun borrow_managed_data_mut<Key: copy + drop + store, Data: store>(
    account: &mut Account,
    key: Key,
    version_witness: VersionWitness,
): &mut Data {
    assert!(has_managed_data(account, key), EManagedDataDoesntExist);
    account.deps().check(version_witness);
    df::borrow_mut(&mut account.id, key)
}

/// Removes a managed data struct from the account.
public fun remove_managed_data<Key: copy + drop + store, A: store>(
    account: &mut Account,
    key: Key,
    version_witness: VersionWitness,
): A {
    assert!(has_managed_data(account, key), EManagedDataDoesntExist);
    account.deps().check(version_witness);
    df::remove(&mut account.id, key)
}

/// Adds a managed object to the account.
public fun add_managed_asset<Key: copy + drop + store, Asset: key + store>(
    account: &mut Account,
    key: Key,
    asset: Asset,
    version_witness: VersionWitness,
) {
    assert!(!has_managed_asset(account, key), EManagedAssetAlreadyExists);
    account.deps().check(version_witness);
    dof::add(&mut account.id, key, asset);
}

/// Checks if a managed object exists in the account.
public fun has_managed_asset<Key: copy + drop + store>(
    account: &Account,
    key: Key,
): bool {
    dof::exists_(&account.id, key)
}

/// Borrows a managed object from the account.
public fun borrow_managed_asset<Key: copy + drop + store, Asset: key + store>(
    account: &Account,
    key: Key,
    version_witness: VersionWitness,
): &Asset {
    assert!(has_managed_asset(account, key), EManagedAssetDoesntExist);
    account.deps().check(version_witness);
    dof::borrow(&account.id, key)
}

/// Borrows a managed object mutably from the account.
public fun borrow_managed_asset_mut<Key: copy + drop + store, Asset: key + store>(
    account: &mut Account,
    key: Key,
    version_witness: VersionWitness,
): &mut Asset {
    assert!(has_managed_asset(account, key), EManagedAssetDoesntExist);
    account.deps().check(version_witness);
    dof::borrow_mut(&mut account.id, key)
}

/// Removes a managed object from the account.
public fun remove_managed_asset<Key: copy + drop + store, Asset: key + store>(
    account: &mut Account,
    key: Key,
    version_witness: VersionWitness,
): Asset {
    assert!(has_managed_asset(account, key), EManagedAssetDoesntExist);
    account.deps().check(version_witness);
    dof::remove(&mut account.id, key)
}

//**************************************************************************************************//
// Config-only functions                                                                            //
//**************************************************************************************************//

/// The following functions are used to define account and intent behavior for a specific account type/config.
///
/// They must be implemented in the module that defines the config of the account, which must be a dependency of the account.
/// We provide higher level macros to facilitate the implementation of these functions.

/// Creates a new account with default dependencies. Can only be called from the config module.
public fun new<Config: store, CW: drop>(
    config: Config,
    deps: Deps,
    version_witness: VersionWitness,
    config_witness: CW,
    ctx: &mut TxContext,
): Account {
    // Validate witness matches config module at compile time
    assert_is_config_module_static<Config, CW>();

    let mut account = Account {
        id: object::new(ctx),
        metadata: metadata::empty(),
        deps,
        intents: intents::empty(ctx),
    };

    account.deps().check(version_witness);

    // Store config and its type as dynamic fields
    df::add(&mut account.id, ConfigKey {}, config);
    df::add(&mut account.id, ConfigTypeKey {}, type_name::get<Config>());

    account
}

/// Returns an Auth object that can be used to call gated functions. Can only be called from the config module.
public fun new_auth<Config: store, CW: drop>(
    account: &Account,
    version_witness: VersionWitness,
    config_witness: CW,
): Auth {
    account.deps().check(version_witness);
    assert_is_config_module<Config, CW>(account, config_witness);

    Auth { account_addr: account.addr() }
}

/// Returns a tuple of the outcome that must be validated and the executable. Can only be called from the config module.
public fun create_executable<Config: store, Outcome: store + copy, CW: drop>(
    account: &mut Account,
    key: String,
    clock: &Clock,
    version_witness: VersionWitness,
    config_witness: CW,
    ctx: &mut TxContext, // Kept for API compatibility
): (Outcome, Executable<Outcome>) {
    account.deps().check(version_witness);
    assert_is_config_module<Config, CW>(account, config_witness);

    let mut intent = account.intents.remove_intent<Outcome>(key);
    let time = intent.pop_front_execution_time();
    assert!(clock.timestamp_ms() >= time, ECantBeExecutedYet);

    (
        *intent.outcome(),
        executable::new(intent, ctx), // ctx no longer used but kept for API compatibility
    )
}

/// Returns a mutable reference to the intents of the account. Can only be called from the config module.
public fun intents_mut<Config: store, CW: drop>(
    account: &mut Account,
    version_witness: VersionWitness,
    config_witness: CW,
): &mut Intents {
    account.deps().check(version_witness);
    assert_is_config_module<Config, CW>(account, config_witness);

    &mut account.intents
}

/// Returns a mutable reference to the config of the account. Can only be called from the config module.
public fun config_mut<Config: store, CW: drop>(
    account: &mut Account,
    version_witness: VersionWitness,
    config_witness: CW,
): &mut Config {
    account.deps().check(version_witness);
    assert_is_config_module<Config, CW>(account, config_witness);

    df::borrow_mut<ConfigKey, Config>(&mut account.id, ConfigKey {})
}

//**************************************************************************************************//
// View functions                                                                                   //
//**************************************************************************************************//

/// Returns the address of the account.
public fun addr(account: &Account): address {
    account.id.uid_to_inner().id_to_address()
}

/// Returns the metadata of the account.
public fun metadata(account: &Account): &Metadata {
    &account.metadata
}

/// Returns the dependencies of the account.
public fun deps(account: &Account): &Deps {
    &account.deps
}

/// Returns the intents of the account.
public fun intents(account: &Account): &Intents {
    &account.intents
}

/// Returns the config of the account.
public fun config<Config: store>(account: &Account): &Config {
    df::borrow<ConfigKey, Config>(&account.id, ConfigKey {})
}

/// Returns object tracking stats (count, deposits_open, max)
public fun object_stats(account: &Account): (u128, bool, u128) {
    if (df::exists_(&account.id, ObjectTracker {})) {
        let tracker: &ObjectTrackerState = df::borrow(&account.id, ObjectTracker {});
        (tracker.object_count, tracker.deposits_open, tracker.max_objects)
    } else {
        (0, true, default_max_objects())
    }
}

/// Check if account is accepting object deposits
public fun is_accepting_objects<Config: store>(account: &Account): bool {
    if (df::exists_(&account.id, ObjectTracker {})) {
        let tracker: &ObjectTrackerState = df::borrow(&account.id, ObjectTracker {});
        tracker.deposits_open && tracker.object_count < tracker.max_objects
    } else {
        true // Default open if not initialized
    }
}

/// Configure object deposit settings (requires Auth)
public fun configure_object_deposits<Config: store>(
    auth: Auth,
    account: &mut Account,
    enable: bool,
    new_max: Option<u128>,
    reset_counter: bool,
) {
    account.verify(auth);

    let tracker = ensure_object_tracker(account);
    tracker.deposits_open = enable;

    if (new_max.is_some()) {
        tracker.max_objects = *new_max.borrow();
    };

    if (reset_counter) {
        tracker.object_count = 0;
    };
}

/// Manage whitelist for object types (requires Auth)
public fun manage_type_whitelist<Config: store>(
    auth: Auth,
    account: &mut Account,
    add_types: vector<String>,
    remove_types: vector<String>,
) {
    account.verify(auth);

    let tracker = ensure_object_tracker(account);

    // Remove types first (in case of duplicates in add/remove)
    let mut i = 0;
    while (i < remove_types.length()) {
        let type_str = &remove_types[i];
        vec_set::remove(&mut tracker.whitelisted_types, type_str);
        i = i + 1;
    };

    // Add new types (check size limit)
    i = 0;
    while (i < add_types.length()) {
        let type_str = add_types[i];
        if (!vec_set::contains(&tracker.whitelisted_types, &type_str)) {
            // Check size limit before adding
            assert!(
                vec_set::size(&tracker.whitelisted_types) < max_whitelist_size(),
                EWhitelistTooLarge,
            );
            vec_set::insert(&mut tracker.whitelisted_types, type_str);
        };
        i = i + 1;
    };
    // Whitelist updated
}

/// Get whitelisted types for inspection/debugging
public fun get_whitelisted_types<Config: store>(account: &Account): vector<String> {
    if (df::exists_(&account.id, ObjectTracker {})) {
        let tracker: &ObjectTrackerState = df::borrow(&account.id, ObjectTracker {});
        vec_set::into_keys(tracker.whitelisted_types) // Convert VecSet to vector
    } else {
        vector::empty()
    }
}

/// Check if a specific type is whitelisted
public fun is_type_whitelisted<Config, T>(account: &Account): bool {
    if (df::exists_(&account.id, ObjectTracker {})) {
        let tracker: &ObjectTrackerState = df::borrow(&account.id, ObjectTracker {});
        // Convert TypeName to String for the lookup
        let type_name = type_name::with_defining_ids<T>();
        let ascii_str = type_name::into_string(type_name);
        let type_str = ascii_str.to_string();
        vec_set::contains(&tracker.whitelisted_types, &type_str)
    } else {
        false
    }
}

/// Helper to check if a TypeName represents a Coin type
fun is_coin_type(type_name: TypeName): bool {
    // Check if the type is a Coin type by checking if it starts with
    // the Coin module prefix from the Sui framework
    let type_addr = type_name::address_string(&type_name);

    // Check if this is from the Sui framework and the module is "coin"
    if (
        type_addr == b"0000000000000000000000000000000000000000000000000000000000000002".to_ascii_string()
    ) {
        let module_name = type_name::module_string(&type_name);
        module_name == b"coin".to_ascii_string()
    } else {
        false
    }
}

//**************************************************************************************************//
// Package functions                                                                                //
//**************************************************************************************************//

/// Returns a mutable reference to the metadata of the account.
public(package) fun metadata_mut(
    account: &mut Account,
    version_witness: VersionWitness,
): &mut Metadata {
    // ensures the package address is a dependency for this account
    account.deps().check(version_witness);
    &mut account.metadata
}

/// Returns a mutable reference to the dependencies of the account.
public(package) fun deps_mut(
    account: &mut Account,
    version_witness: VersionWitness,
): &mut Deps {
    // ensures the package address is a dependency for this account
    account.deps().check(version_witness);
    &mut account.deps
}

/// Receives an object from an account with tracking, only used in owned action lib module.
/// NOTE: This is for WITHDRAWALS - receiving an object FROM the account to return it.
public(package) fun receive<T: key + store>(
    account: &mut Account,
    receiving: Receiving<T>,
): T {
    let type_name = type_name::with_defining_ids<T>();
    let is_coin = is_coin_type(type_name);

    let tracker = ensure_object_tracker(account);
    let ascii_str = type_name::into_string(type_name);
    let type_str = ascii_str.to_string();
    let is_whitelisted = vec_set::contains(&tracker.whitelisted_types, &type_str);

    // Only count non-coin, non-whitelisted types
    if (!is_coin && !is_whitelisted) {
        // This is a WITHDRAWAL, so DECREMENT the counter
        assert!(tracker.object_count > 0, EObjectCountUnderflow);
        tracker.object_count = tracker.object_count - 1;

        // Re-enable deposits if we're back under 50% of threshold
        if (tracker.object_count < tracker.max_objects / 2) {
            tracker.deposits_open = true;
        };
    };

    transfer::public_receive(&mut account.id, receiving)
}

/// Track when an object leaves the account (withdrawal/burn/transfer)
public(package) fun track_object_removal<Config: store>(account: &mut Account, _object_id: ID) {
    let tracker = ensure_object_tracker(account);
    assert!(tracker.object_count > 0, EObjectCountUnderflow);
    tracker.object_count = tracker.object_count - 1;

    // Re-enable deposits if we're back under 50% of threshold
    if (tracker.object_count < tracker.max_objects / 2) {
        tracker.deposits_open = true;
    };
}

// REMOVED: lock_object and unlock_object - no locking in new design
// Conflicts between intents are natural in DAO governance

//**************************************************************************************************//
// Tests                                                                                            //
//**************************************************************************************************//

// === Test Helpers ===

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(ACCOUNT {}, ctx);
}

#[test_only]
public struct Witness has drop {}

#[test_only]
public fun not_config_witness(): Witness {
    Witness {}
}

// === Unit Tests ===

#[test_only]
use sui::test_utils::{assert_eq, destroy};
#[test_only]
public struct TestConfig has copy, drop, store {}
#[test_only]
public struct TestWitness() has drop;

#[test_only]
public struct TestWitness2() has drop;

#[test_only]
public struct WrongWitness() has drop;
#[test_only]
public struct TestKey has copy, drop, store {}
#[test_only]
public struct TestData has copy, drop, store {
    value: u64,
}
#[test_only]
public struct TestAsset has key, store {
    id: UID,
}

#[test]
fun test_addr() {
    let ctx = &mut tx_context::dummy();
    let deps = deps::new_for_testing();

    let account = new(TestConfig {}, deps, version::current(), TestWitness(), ctx);
    let account_addr = addr(&account);

    assert_eq(account_addr, object::id(&account).to_address());
    destroy(account);
}

#[test]
fun test_verify_auth() {
    let ctx = &mut tx_context::dummy();
    let deps = deps::new_for_testing();

    let account = new(TestConfig {}, deps, version::current(), TestWitness(), ctx);
    let auth = Auth { account_addr: account.addr() };

    // Should not abort
    verify(&account, auth);
    destroy(account);
}

#[test, expected_failure(abort_code = EWrongAccount)]
fun test_verify_auth_wrong_account() {
    let ctx = &mut tx_context::dummy();
    let deps = deps::new_for_testing();

    let account = new(TestConfig {}, deps, version::current(), TestWitness(), ctx);
    let auth = Auth { account_addr: @0xBAD };

    verify(&account, auth);
    destroy(account);
}

#[test]
fun test_managed_data_flow() {
    let ctx = &mut tx_context::dummy();
    let deps = deps::new_for_testing();

    let mut account = new(TestConfig {}, deps, version::current(), TestWitness(), ctx);
    let key = TestKey {};
    let data = TestData { value: 42 };

    // Test add
    add_managed_data(&mut account, key, data, version::current());
    assert!(has_managed_data(&account, key));

    // Test borrow
    let borrowed_data = borrow_managed_data(&account, key, version::current());
    assert_eq(*borrowed_data, data);

    // Test borrow_mut
    let borrowed_mut_data = borrow_managed_data_mut(&mut account, key, version::current());
    assert_eq(*borrowed_mut_data, data);

    // Test remove
    let removed_data = remove_managed_data(&mut account, key, version::current());
    assert_eq(removed_data, data);
    assert!(!has_managed_data(&account, key));
    destroy(account);
}

#[test, expected_failure(abort_code = EManagedDataAlreadyExists)]
fun test_add_managed_data_already_exists() {
    let ctx = &mut tx_context::dummy();
    let deps = deps::new_for_testing();

    let mut account = new(TestConfig {}, deps, version::current(), TestWitness(), ctx);
    let key = TestKey {};
    let data1 = TestData { value: 42 };
    let data2 = TestData { value: 100 };

    add_managed_data(&mut account, key, data1, version::current());
    add_managed_data(&mut account, key, data2, version::current());
    destroy(account);
}

#[test, expected_failure(abort_code = EManagedDataDoesntExist)]
fun test_borrow_managed_data_doesnt_exist() {
    let ctx = &mut tx_context::dummy();
    let deps = deps::new_for_testing();

    let account = new(TestConfig {}, deps, version::current(), TestWitness(), ctx);
    let key = TestKey {};

    borrow_managed_data<TestKey, TestData>(&account, key, version::current());
    destroy(account);
}

#[test, expected_failure(abort_code = EManagedDataDoesntExist)]
fun test_borrow_managed_data_mut_doesnt_exist() {
    let ctx = &mut tx_context::dummy();
    let deps = deps::new_for_testing();

    let mut account = new(TestConfig {}, deps, version::current(), TestWitness(), ctx);
    let key = TestKey {};

    borrow_managed_data_mut<TestKey, TestData>(&mut account, key, version::current());
    destroy(account);
}

#[test, expected_failure(abort_code = EManagedDataDoesntExist)]
fun test_remove_managed_data_doesnt_exist() {
    let ctx = &mut tx_context::dummy();
    let deps = deps::new_for_testing();

    let mut account = new(TestConfig {}, deps, version::current(), TestWitness(), ctx);
    let key = TestKey {};

    remove_managed_data<TestKey, TestData>(&mut account, key, version::current());
    destroy(account);
}

#[test]
fun test_managed_asset_flow() {
    let ctx = &mut tx_context::dummy();
    let deps = deps::new_for_testing();

    let mut account = new(TestConfig {}, deps, version::current(), TestWitness(), ctx);
    let key = TestKey {};
    let asset = TestAsset { id: object::new(ctx) };
    let asset_id = object::id(&asset);

    // Test add
    add_managed_asset(&mut account, key, asset, version::current());
    assert!(has_managed_asset(&account, key), 0);

    // Test borrow
    let borrowed_asset = borrow_managed_asset<TestKey, TestAsset>(
        &account,
        key,
        version::current(),
    );
    let borrowed_asset_id = object::id(borrowed_asset);
    assert_eq(borrowed_asset_id, asset_id);

    // Test remove
    let removed_asset = remove_managed_asset<TestKey, TestAsset>(
        &mut account,
        key,
        version::current(),
    );
    assert_eq(object::id(&removed_asset), asset_id);
    assert!(!has_managed_asset(&account, key));
    destroy(account);
    destroy(removed_asset);
}

#[test]
fun test_has_managed_data_false() {
    let ctx = &mut tx_context::dummy();
    let deps = deps::new_for_testing();

    let account = new(TestConfig {}, deps, version::current(), TestWitness(), ctx);
    let key = TestKey {};

    assert!(!has_managed_data(&account, key));
    destroy(account);
}

#[test]
fun test_has_managed_asset_false() {
    let ctx = &mut tx_context::dummy();
    let deps = deps::new_for_testing();

    let account = new(TestConfig {}, deps, version::current(), TestWitness(), ctx);
    let key = TestKey {};

    assert!(!has_managed_asset(&account, key));
    destroy(account);
}

#[test, expected_failure(abort_code = EManagedAssetAlreadyExists)]
fun test_add_managed_asset_already_exists() {
    let ctx = &mut tx_context::dummy();
    let deps = deps::new_for_testing();

    let mut account = new(TestConfig {}, deps, version::current(), TestWitness(), ctx);
    let key = TestKey {};
    let asset1 = TestAsset { id: object::new(ctx) };
    let asset2 = TestAsset { id: object::new(ctx) };

    add_managed_asset(&mut account, key, asset1, version::current());
    add_managed_asset(&mut account, key, asset2, version::current());
    destroy(account);
}

#[test, expected_failure(abort_code = EManagedAssetDoesntExist)]
fun test_borrow_managed_asset_doesnt_exist() {
    let ctx = &mut tx_context::dummy();
    let deps = deps::new_for_testing();

    let account = new(TestConfig {}, deps, version::current(), TestWitness(), ctx);
    let key = TestKey {};

    borrow_managed_asset<TestKey, TestAsset>(&account, key, version::current());
    destroy(account);
}

#[test, expected_failure(abort_code = EManagedAssetDoesntExist)]
fun test_borrow_managed_asset_mut_doesnt_exist() {
    let ctx = &mut tx_context::dummy();
    let deps = deps::new_for_testing();

    let mut account = new(TestConfig {}, deps, version::current(), TestWitness(), ctx);
    let key = TestKey {};

    borrow_managed_asset_mut<TestKey, TestAsset>(&mut account, key, version::current());
    destroy(account);
}

#[test, expected_failure(abort_code = EManagedAssetDoesntExist)]
fun test_remove_managed_asset_doesnt_exist() {
    let ctx = &mut tx_context::dummy();
    let deps = deps::new_for_testing();

    let mut account = new(TestConfig {}, deps, version::current(), TestWitness(), ctx);
    let key = TestKey {};

    let removed_asset = remove_managed_asset<TestKey, TestAsset>(
        &mut account,
        key,
        version::current(),
    );
    destroy(removed_asset);
    destroy(account);
}

#[test]
fun test_new_auth() {
    let ctx = &mut tx_context::dummy();
    let deps = deps::new_for_testing();

    let account = new(TestConfig {}, deps, version::current(), TestWitness(), ctx);
    let auth = new_auth<TestConfig, TestWitness>(&account, version::current(), TestWitness());

    assert_eq(auth.account_addr, account.addr());
    destroy(account);
    destroy(auth);
}

#[test]
fun test_metadata_access() {
    let ctx = &mut tx_context::dummy();
    let deps = deps::new_for_testing();

    let account = new(TestConfig {}, deps, version::current(), TestWitness(), ctx);

    // Should not abort - just testing access
    assert_eq(metadata(&account).size(), 0);
    destroy(account);
}

#[test]
fun test_config_access() {
    let ctx = &mut tx_context::dummy();
    let deps = deps::new_for_testing();

    let account = new(TestConfig {}, deps, version::current(), TestWitness(), ctx);

    // Should not abort - just testing access
    config<TestConfig>(&account);
    destroy(account);
}

#[test]
fun test_assert_is_config_module_correct_witness() {
    let ctx = &mut tx_context::dummy();
    let deps = deps::new_for_testing();

    let account = new(TestConfig {}, deps, version::current(), TestWitness(), ctx);

    // Should not abort
    assert_is_config_module<TestConfig, TestWitness>(&account, TestWitness());
    destroy(account);
}

// REMOVED: test_assert_config_module_wrong_witness_package_address
// REMOVED: test_assert_config_module_wrong_witness_module
// Both tests used TestWitness2 which is in the same module as TestConfig, so they can't test cross-module validation
// Would need to define TestWitness2 in a separate module to properly test this

// === Test Helper Functions ===

#[test_only]
public fun new_for_testing(ctx: &mut TxContext): Account {
    let deps = deps::new_for_testing();
    new(TestConfig {}, deps, version::current(), TestWitness(), ctx)
}

#[test_only]
public fun destroy_for_testing<Config: store>(account: Account) {
    destroy(account);
}

#[test_only]
public fun get_object_tracker<Config: store>(account: &Account): Option<ObjectTrackerState> {
    if (df::exists_(&account.id, ObjectTracker {})) {
        let tracker: &ObjectTrackerState = df::borrow(&account.id, ObjectTracker {});
        option::some(*tracker)
    } else {
        option::none()
    }
}

#[test_only]
public fun track_object_addition<Config: store>(account: &mut Account, id: ID) {
    let tracker = ensure_object_tracker(account);
    tracker.object_count = tracker.object_count + 1;
    if (tracker.object_count >= tracker.max_objects) {
        tracker.deposits_open = false;
    };
}

#[test_only]
public fun set_max_objects_for_testing<Config: store>(account: &mut Account, max: u128) {
    let tracker = ensure_object_tracker(account);
    tracker.max_objects = max;
}

// === Share Functions ===

/// Share an account - can only be called by this module
/// Used during DAO/account initialization after setup is complete
public fun share_account<Config: store>(account: Account) {
    transfer::share_object(account);
}

#[test_only]
public fun enable_deposits_for_testing<Config: store>(account: &mut Account) {
    let tracker = ensure_object_tracker(account);
    tracker.deposits_open = true;
}

#[test_only]
public fun close_deposits_for_testing<Config: store>(account: &mut Account) {
    let tracker = ensure_object_tracker(account);
    tracker.deposits_open = false;
}

#[test_only]
public fun check_can_receive_object<Config, T>(account: &Account) {
    let tracker: &ObjectTrackerState = df::borrow(&account.id, ObjectTracker {});
    let type_name = type_name::with_defining_ids<T>();
    let ascii_str = type_name::into_string(type_name);
    let type_str = ascii_str.to_string();

    assert!(
        tracker.deposits_open || tracker.whitelisted_types.contains(&type_str),
        EDepositsDisabled,
    );

    // For test purposes, we'll treat all objects the same
    // In production, coins don't count against limits but for tests this is fine
    if (!tracker.whitelisted_types.contains(&type_str)) {
        assert!(tracker.object_count < tracker.max_objects, EObjectLimitReached);
    };
}
