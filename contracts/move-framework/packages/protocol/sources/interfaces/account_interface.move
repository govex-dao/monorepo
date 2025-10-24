// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

// Portions of this file are derived from the account.tech Move Framework project.
// Those portions remain licensed under the Apache License, Version 2.0.

/// [Account Interface] - High level functions to create required "methods" for the account.
///
/// 1. Define a new Account type with a specific config and default dependencies.
/// 2. Define a mechanism to authenticate an address to grant permission to call certain functions.
/// 3. Define a way to modify the outcome of an intent.
/// 4. Define an `Outcome.validate()` that will be called upon intent execution.

module account_protocol::account_interface;

use account_protocol::account::{Self, Account, Auth};
use account_protocol::deps::Deps;
use account_protocol::executable::Executable;
use account_protocol::version_witness::VersionWitness;
use std::string::String;
use sui::clock::Clock;

// === Imports ===

// === Public functions ===

/// Example implementation:
///
/// ```move
///
/// public struct Witness() has drop;
///
/// public fun new_account(
///     extensions: &Extensions,
///     ctx: &mut TxContext,
/// ): Account {
///     fees.process(coin);
///
///     let config = Config {
///        .. <FIELDS>
///     };
///
///     create_account!(
///        config,
///        version::current(),
///        Witness(),
///        ctx,
///        || deps::new_latest_extensions(extensions, vector[b"AccountProtocol".to_string(), b"MyConfig".to_string()])
///     )
/// }
///
/// ```

/// Returns a new Account object with a specific config and initialize dependencies.
public macro fun create_account<$Config: store, $CW: drop>(
    $config: $Config,
    $version_witness: VersionWitness,
    $config_witness: $CW,
    $ctx: &mut TxContext,
    $init_deps: || -> Deps,
): Account {
    let deps = $init_deps();
    account::new<$Config, $CW>($config, deps, $version_witness, $config_witness, $ctx)
}

/// Example implementation:
///
/// ```move
///
/// public fun authenticate(
///     account: &Account,
///     ctx: &TxContext
/// ): Auth {
///     authenticate!(
///        account,
///        version::current(),
///        Witness(),
///        || account.config::<Config>().assert_is_member(ctx)
///     )
/// }
///
/// ```

/// Returns an Auth if the conditions passed are met (used to create intents and more).
public macro fun create_auth<$Config: store, $CW: drop>(
    $account: &Account,
    $registry: &account_protocol::package_registry::PackageRegistry,
    $version_witness: VersionWitness,
    $config_witness: $CW,
    $grant_permission: ||, // condition to grant permission, must throw if not met
): Auth {
    let account = $account;
    let registry = $registry;

    $grant_permission();

    account.new_auth<$Config, $CW>(registry, $version_witness, $config_witness)
}

/// Example implementation:
///
/// ```move
///
/// public fun approve_intent<Config: store>(
///     account: &mut Account,
///     key: String,
///     ctx: &TxContext
/// ) {
///     <PREPARE_DATA>
///
///     resolve_intent!(
///         account,
///         key,
///         version::current(),
///         Witness(),
///         |outcome_mut| {
///             <DO_SOMETHING>
///         }
///     );
/// }
///
/// ```

/// Modifies the outcome of an intent.
public macro fun resolve_intent<$Config: store, $Outcome, $CW: drop>(
    $account: &mut Account,
    $key: String,
    $version_witness: VersionWitness,
    $config_witness: $CW,
    $modify_outcome: |&mut $Outcome|,
) {
    let account = $account;

    let outcome_mut = account
        .intents_mut<$Config, $CW>($version_witness, $config_witness)
        .get_mut($key)
        .outcome_mut<$Outcome>();

    $modify_outcome(outcome_mut);
}

/// Example implementation:
///
/// IMPORTANT: You must provide an Outcome.validate() function that will be called automatically.
/// It must take the outcome by value, a reference to the Config and the role of the intent even if not used.
///
/// ```move
///
/// public fun execute_intent(
///     account: &mut Account,
///     key: String,
///     clock: &Clock,
/// ): Executable<Outcome> {
///     execute_intent!<Config, Outcome, _>(account, key, clock, version::current(), Witness())
/// }
///
/// fun validate_outcome(
///     outcome: Outcome,
///     config: &Config,
///     role: String,
/// ) {
///     let Outcome { fields, .. } = outcome;
///
///     assert!(<CHECK_CONDITIONS>);
/// }
///
/// ```

/// Validates the outcome of an intent and returns an executable.
public macro fun execute_intent<$Config: store, $Outcome, $CW: drop>(
    $account: &mut Account,
    $key: String,
    $clock: &Clock,
    $version_witness: VersionWitness,
    $config_witness: $CW,
    $ctx: &mut TxContext,
    $validate_outcome: |$Outcome|,
): Executable<$Outcome> {
    let (outcome, executable) = account::create_executable<$Config, $Outcome, $CW>(
        $account,
        $key,
        $clock,
        $version_witness,
        $config_witness,
        $ctx,
    );

    $validate_outcome(outcome);

    executable
}
