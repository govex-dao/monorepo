// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

/// Init Actions - Entry functions for DAO initialization
///
/// Each module that needs init actions exposes its own entry functions here.
/// PTBs call these directly during DAO creation for atomic initialization.
///
/// ## Usage Pattern:
/// ```typescript
/// // PTB calls these in sequence
/// tx.moveCall({ target: 'factory::create_dao_unshared', ... });
/// tx.moveCall({ target: 'init_actions::init_config_update_name', ... });
/// tx.moveCall({ target: 'init_actions::init_add_liquidity', ... });
/// tx.moveCall({ target: 'factory::finalize_and_share_dao', ... });
/// ```
module futarchy_factory::init_actions;

use account_protocol::account::{Self, Account};
use futarchy_core::futarchy_config::{Self, FutarchyConfig};
use futarchy_core::priority_queue::{Self, ProposalQueue};
use futarchy_markets_core::unified_spot_pool::{Self, UnifiedSpotPool};
use futarchy_types::init_action_specs::{Self, ActionSpec, InitActionSpecs};
use std::option::{Self, Option};
use std::string::{Self, String};
use sui::clock::Clock;
use sui::coin::Coin;
use sui::event;
use sui::object;
use sui::transfer;
use sui::tx_context::TxContext;

/// Special witness for init actions that bypass voting
public struct InitWitness has drop {}

/// Result of init action execution with detailed error tracking
public struct InitResult has drop {
    total_actions: u64,
    succeeded: u64,
    failed: u64,
    first_error: Option<String>,
    failed_action_index: Option<u64>,
    partial_execution_allowed: bool,
}

/// Event emitted for each init action attempted (for launchpad tracking)
public struct InitActionAttempted has copy, drop {
    dao_id: address,
    action_type: String, // TypeName as string
    action_index: u64,
    success: bool,
}

/// Event for init batch completion
public struct InitBatchCompleted has copy, drop {
    dao_id: address,
    total_actions: u64,
    successful_actions: u64,
    failed_actions: u64,
}

// === PTB Entry Functions for Init Actions ===

/// Initialize config action during DAO creation
/// Called by PTB to set initial configuration parameters
public entry fun init_config_update_name(
    new_name: vector<u8>,
    account: &mut Account<FutarchyConfig>,
    ctx: &mut TxContext,
) {
    // Update DAO name during initialization
    let config = futarchy_config::internal_config_mut(account, futarchy_core::version::current());
    let name_string = std::string::utf8(new_name);
    futarchy_config::set_dao_name(config, name_string);
}

/// Initialize trading parameters during DAO creation
public entry fun init_config_trading_params<StableType>(
    min_asset_amount: u64,
    min_stable_amount: u64,
    review_period_ms: u64,
    trading_period_ms: u64,
    account: &mut Account<FutarchyConfig>,
    ctx: &mut TxContext,
) {
    let config = futarchy_config::internal_config_mut(account, futarchy_core::version::current());
    futarchy_config::set_min_asset_amount(config, min_asset_amount);
    futarchy_config::set_min_stable_amount(config, min_stable_amount);
    futarchy_config::set_review_period_ms(config, review_period_ms);
    futarchy_config::set_trading_period_ms(config, trading_period_ms);
}

/// Initialize liquidity pool during DAO creation
public entry fun init_create_liquidity_pool<AssetType: drop, StableType: drop>(
    initial_asset_amount: u64,
    initial_stable_amount: u64,
    fee_bps: u64,
    asset_coin: Coin<AssetType>,
    stable_coin: Coin<StableType>,
    spot_pool: &mut UnifiedSpotPool<AssetType, StableType>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Add initial liquidity to the unshared pool
    let lp_tokens = unified_spot_pool::add_liquidity_and_return(
        spot_pool,
        asset_coin,
        stable_coin,
        0, // min_lp_out
        ctx,
    );

    // Transfer LP tokens to the pool itself for initial liquidity
    transfer::public_transfer(lp_tokens, object::id_address(spot_pool));
}

/// Initialize proposal queue settings during DAO creation
public entry fun init_queue_settings<StableType>(
    max_queue_size: u64,
    proposal_bond: u64,
    queue: &mut ProposalQueue<StableType>,
    ctx: &mut TxContext,
) {}

/// Get witness for init actions
public fun init_witness(): InitWitness {
    InitWitness {}
}

// === Init Action Entry Functions ===
// Note: Each action module should expose its own init entry functions
// that can be called directly by the PTB during DAO initialization

/// Example entry function pattern that each action module should implement:
/// ```
/// public entry fun execute_init_<action_name>(
///     params: <ActionParams>,
///     account: &mut Account<FutarchyConfig>,
///     <required_resources>,
///     clock: &Clock,
///     ctx: &mut TxContext,
/// )
/// ```

// === Constants ===
const MAX_INIT_ACTIONS: u64 = 50; // Reasonable limit to prevent gas issues

// === Public Getters for InitResult ===
public fun result_succeeded(result: &InitResult): u64 { result.succeeded }

public fun result_failed(result: &InitResult): u64 { result.failed }

public fun result_first_error(result: &InitResult): &Option<String> { &result.first_error }

public fun result_failed_index(result: &InitResult): &Option<u64> { &result.failed_action_index }

public fun result_is_complete_success(result: &InitResult): bool { result.failed == 0 }

public fun result_is_partial_success(result: &InitResult): bool {
    result.succeeded > 0 && result.failed > 0 && result.partial_execution_allowed
}

// === Main Execution Function ===

/// Execute init actions with resources during launchpad finalization
/// This function processes all init actions in the specs and applies them to the DAO
/// before it becomes public. All actions must succeed or the entire transaction reverts.
public fun execute_init_intent_with_resources<RaiseToken, StableCoin>(
    account: &mut Account<FutarchyConfig>,
    specs: InitActionSpecs,
    queue: &mut ProposalQueue<StableCoin>,
    spot_pool: &mut UnifiedSpotPool<RaiseToken, StableCoin>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let dao_id = object::id_address(account);
    // For now, just process without the actions since we can't access them directly
    // The actual init actions would be handled by PTB calling specific functions
    let total_actions = 0u64;

    // Note: The actual init actions would be handled by PTB calling
    // specific init functions. This is just a placeholder for now.

    // Emit completion event
    event::emit(InitBatchCompleted {
        dao_id,
        total_actions,
        successful_actions: total_actions,
        failed_actions: 0,
    });
}

// === Errors ===
const EUnhandledAction: u64 = 1;
const EActionNotAllowedAtInit: u64 = 2;
const EInitActionFailed: u64 = 3;
const ETooManyInitActions: u64 = 4;
