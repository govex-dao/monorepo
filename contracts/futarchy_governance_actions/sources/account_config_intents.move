// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

/// Account configuration intents for Futarchy governance
///
/// This module provides governance-based wrappers around account_protocol::config actions.
/// Instead of requiring Auth capabilities (direct authorization), these functions create
/// proposals that go through the futarchy market-based governance flow.
///
/// Key differences from account_protocol::config:
/// - No Auth requirement - controlled by proposal/market governance
/// - Uses FutarchyOutcome instead of generic Outcome
/// - Uses futarchy_core::version instead of account_protocol::version
///
/// Actions provided:
/// - Update account dependencies (add new action packages)
/// - Toggle unverified package allowance
module futarchy_governance_actions::account_config_intents;

use account_protocol::package_registry::PackageRegistry;
use account_protocol::{
    account::Account,
    config,
    deps::{Self},
    executable::Executable,
    intents::Params,
    intent_interface,
};
use futarchy_core::{futarchy_config::FutarchyOutcome, version};
use std::string::String;
use sui::bcs;

// === Intent Witnesses ===

/// Intent witness for updating account dependencies
public struct UpdateDepsIntent() has drop;

/// Intent witness for toggling unverified package allowance
public struct ToggleUnverifiedIntent() has drop;

// === Public Functions: Request (Create Proposals) ===

/// Create a futarchy proposal to update account dependencies
///
/// This allows the DAO to add new action packages through governance.
/// After the proposal passes and the market resolves to YES, the deps will be updated.
///
/// # Arguments
/// * `account` - The futarchy DAO account
/// * `params` - Intent parameters (execution times, expiration, etc.)
/// * `outcome` - FutarchyOutcome for tracking proposal
/// * `extensions` - Extensions registry for validating packages (if unverified_allowed=false)
/// * `names` - Package names to set as dependencies
/// * `addresses` - Package addresses corresponding to names
/// * `versions` - Package versions corresponding to names
///
/// # Example Use Case
/// DAO wants to add a new "DividendActions" package to enable dividend distribution:
/// ```
/// request_update_deps(
///     account,
///     params,
///     outcome,
///     extensions,
///     vector[b"AccountProtocol", b"FutarchyCore", b"DividendActions"],
///     vector[@0xabc..., @0xdef..., @0x123...],
///     vector[1, 1, 1],
///     ctx
/// );
/// ```
public fun request_update_deps(
    account: &mut Account,
    params: Params,
    outcome: FutarchyOutcome,
    registry: &PackageRegistry,
    names: vector<String>,
    addresses: vector<address>,
    versions: vector<u64>,
    ctx: &mut TxContext,
) {
    // No Auth check - proposal governance handles authorization
    params.assert_single_execution();

    // Validate and create deps (same validation as account_protocol::config)
    let mut deps = deps::new_inner(registry, account.deps(), names, addresses, versions);
    let deps_inner = *deps.inner_mut();

    // Build intent using the intent_interface macro
    intent_interface::build_intent!<futarchy_core::futarchy_config::FutarchyConfig, FutarchyOutcome, UpdateDepsIntent>(
        account,
        params,
        outcome,
        b"Update Account Dependencies".to_string(),
        version::current(),  // Use futarchy_core::version, not account_protocol::version
        UpdateDepsIntent(),
        ctx,
        |intent, iw| {
            // Create the action struct using public constructor
            let action = config::new_config_deps_action(deps_inner);
            let action_data = bcs::to_bytes(&action);

            // Add to intent with existing type marker from account_protocol::config
            intent.add_typed_action(
                config::config_update_deps(),
                action_data,
                iw
            );

            // Explicitly destroy the action struct
            config::destroy_config_deps_action(action);
        },
    );
}

/// Create a futarchy proposal to toggle unverified package allowance
///
/// If enabled, the DAO can add packages that aren't in the Extensions whitelist.
/// This increases flexibility but reduces security guarantees.
///
/// # Arguments
/// * `account` - The futarchy DAO account
/// * `params` - Intent parameters
/// * `outcome` - FutarchyOutcome for tracking proposal
///
/// # Security Consideration
/// Enabling unverified packages allows adding any package as a dependency.
/// This should only be done if the DAO trusts its governance process to vet packages.
public fun request_toggle_unverified(
    account: &mut Account,
    params: Params,
    outcome: FutarchyOutcome,
    ctx: &mut TxContext,
) {
    // No Auth check - proposal governance handles authorization
    params.assert_single_execution();

    intent_interface::build_intent!<futarchy_core::futarchy_config::FutarchyConfig, FutarchyOutcome, ToggleUnverifiedIntent>(
        account,
        params,
        outcome,
        b"Toggle Unverified Package Allowance".to_string(),
        version::current(),  // Use futarchy_core::version
        ToggleUnverifiedIntent(),
        ctx,
        |intent, iw| {
            // Create the action struct using public constructor
            let action = config::new_toggle_unverified_action();
            let action_data = bcs::to_bytes(&action);

            // Add to intent with existing type marker
            intent.add_typed_action(
                config::config_toggle_unverified(),
                action_data,
                iw
            );

            // Explicitly destroy the action struct
            config::destroy_toggle_unverified_action(action);
        },
    );
}

// === Public Functions: Execute (After Proposal Passes) ===

/// Execute the deps update action after proposal passes
///
/// This is called during PTB execution after the market resolves to YES.
/// It directly delegates to account_protocol::config::execute_config_deps.
///
/// # Arguments
/// * `executable` - The executable hot potato from the resolved proposal
/// * `account` - The futarchy DAO account
/// * `extensions` - Extensions registry for validation
public fun execute_update_deps(
    executable: &mut Executable<FutarchyOutcome>,
    account: &mut Account,
    registry: &PackageRegistry,
) {
    // Delegate to account_protocol::config executor
    // This reuses all the validation and execution logic
    config::execute_config_deps<futarchy_core::futarchy_config::FutarchyConfig, FutarchyOutcome>(
        executable,
        account,
        registry,
    );
}

/// Execute the toggle unverified action after proposal passes
///
/// This is called during PTB execution after the market resolves to YES.
/// It directly delegates to account_protocol::config::execute_toggle_unverified_allowed.
///
/// # Arguments
/// * `executable` - The executable hot potato from the resolved proposal
/// * `account` - The futarchy DAO account
public fun execute_toggle_unverified(
    executable: &mut Executable<FutarchyOutcome>,
    account: &mut Account,
) {
    // Delegate to account_protocol::config executor
    config::execute_toggle_unverified_allowed<futarchy_core::futarchy_config::FutarchyConfig, FutarchyOutcome>(
        executable,
        account,
    );
}
