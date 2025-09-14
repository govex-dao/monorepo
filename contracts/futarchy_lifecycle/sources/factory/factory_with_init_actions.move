/// Extension to factory.move that allows creating DAOs with atomic init actions
/// This module provides a generic entry point for creating DAOs with ANY
/// initialization actions that execute atomically before objects are shared
module futarchy_lifecycle::factory_with_init_actions;

// === Imports ===
use std::{
    ascii::String as AsciiString,
    string::String as UTF8String,
    option::{Self, Option},
};
use sui::{
    clock::Clock,
    coin::{Self, Coin, TreasuryCap},
    sui::SUI,
    transfer,
};
use account_extensions::extensions::Extensions;
use futarchy_core::priority_queue::ProposalQueue;
use futarchy_lifecycle::factory::{Self, Factory};
use futarchy_markets::{
    fee::FeeManager,
    account_spot_pool::{Self, AccountSpotPool},
};
use futarchy_actions::{
    action_specs::InitActionSpecs,
    init_actions,
};

// === Entry Functions ===

/// Create a new futarchy DAO with initialization actions that execute atomically.
///
/// The init_specs parameter is completely generic - it can contain ANY valid
/// action types that the dispatchers support. This allows maximum flexibility:
/// - Add initial liquidity
/// - Create payment streams
/// - Set up multisig councils
/// - Configure vault settings
/// - Create initial proposals
/// - Or any combination of the above
///
/// All init actions execute BEFORE the DAO objects are shared publicly,
/// ensuring atomic setup. If any action fails, the entire DAO creation reverts.
public entry fun create_dao_with_init_actions<AssetType: drop, StableType>(
    factory: &mut Factory,
    extensions: &Extensions,
    fee_manager: &mut FeeManager,
    payment: Coin<SUI>,
    // Standard DAO creation parameters
    min_asset_amount: u64,
    min_stable_amount: u64,
    dao_name: AsciiString,
    icon_url_string: AsciiString,
    review_period_ms: u64,
    trading_period_ms: u64,
    twap_start_delay: u64,
    twap_step_max: u64,
    twap_initial_observation: u128,
    twap_threshold: u64,
    amm_total_fee_bps: u64,
    description: UTF8String,
    max_outcomes: u64,
    // Generic init actions - can be ANY valid action combination
    init_specs: InitActionSpecs,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Create DAO components without sharing them (hot potato pattern)
    let (mut account, mut queue, mut spot_pool) = factory::create_dao_unshared<AssetType, StableType>(
        factory,
        extensions,
        fee_manager,
        payment,
        min_asset_amount,
        min_stable_amount,
        dao_name,
        icon_url_string,
        review_period_ms,
        trading_period_ms,
        twap_start_delay,
        twap_step_max,
        twap_initial_observation,
        twap_threshold,
        amm_total_fee_bps,
        description,
        max_outcomes,
        option::none(), // No treasury cap
        clock,
        ctx,
    );

    // Execute the init actions - completely generic, no assumptions about content
    init_actions::execute_init_intent_with_resources<AssetType, StableType>(
        &mut account,
        init_specs,
        &mut queue,
        &mut spot_pool,
        clock,
        ctx,
    );

    // Share all objects atomically after successful init
    transfer::public_share_object(account);
    transfer::public_share_object(queue);
    account_spot_pool::share(spot_pool);
}

/// Create a DAO with init actions and a treasury cap
/// Same as above but also locks a TreasuryCap in the DAO
public entry fun create_dao_with_init_actions_and_treasury<AssetType: drop, StableType>(
    factory: &mut Factory,
    extensions: &Extensions,
    fee_manager: &mut FeeManager,
    payment: Coin<SUI>,
    treasury_cap: TreasuryCap<AssetType>,
    // Standard DAO creation parameters
    min_asset_amount: u64,
    min_stable_amount: u64,
    dao_name: AsciiString,
    icon_url_string: AsciiString,
    review_period_ms: u64,
    trading_period_ms: u64,
    twap_start_delay: u64,
    twap_step_max: u64,
    twap_initial_observation: u128,
    twap_threshold: u64,
    amm_total_fee_bps: u64,
    description: UTF8String,
    max_outcomes: u64,
    // Generic init actions
    init_specs: InitActionSpecs,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Create DAO components without sharing them
    let (mut account, mut queue, mut spot_pool) = factory::create_dao_unshared<AssetType, StableType>(
        factory,
        extensions,
        fee_manager,
        payment,
        min_asset_amount,
        min_stable_amount,
        dao_name,
        icon_url_string,
        review_period_ms,
        trading_period_ms,
        twap_start_delay,
        twap_step_max,
        twap_initial_observation,
        twap_threshold,
        amm_total_fee_bps,
        description,
        max_outcomes,
        option::some(treasury_cap),
        clock,
        ctx,
    );

    // Execute the init actions - completely generic
    init_actions::execute_init_intent_with_resources<AssetType, StableType>(
        &mut account,
        init_specs,
        &mut queue,
        &mut spot_pool,
        clock,
        ctx,
    );

    // Share all objects atomically
    transfer::public_share_object(account);
    transfer::public_share_object(queue);
    account_spot_pool::share(spot_pool);
}

// === Notes on Usage ===
//
// The InitActionSpecs is built off-chain by the SDK/UI and contains
// a vector of ActionSpec objects. Each ActionSpec has:
// - action_type: TypeName of the action
// - action_data: BCS-serialized action data
//
// The init_actions module will iterate through these specs and dispatch
// them to the appropriate handlers. The dispatchers are responsible for:
// - Deserializing the action data
// - Validating the action is allowed at init time
// - Executing the action with the hot potato resources
//
// This design is completely extensible - new action types can be added
// without modifying this factory module at all. The only requirement is
// that the action has a corresponding dispatcher that knows how to handle it.
//
// Example action combinations (built by SDK):
//
// 1. Bootstrap liquidity + create streams:
//    [AddLiquidityAction, CreateStreamAction, CreateStreamAction]
//
// 2. Multisig governance + initial config:
//    [CreateCouncilAction, SetPolicyAction, UpdateConfigAction]
//
// 3. Complex treasury setup:
//    [WhitelistCoinAction, DepositAction, SetSpendLimitAction]
//
// The SDK is responsible for:
// - Building the correct action structs
// - BCS-serializing them
// - Creating the InitActionSpecs
// - Ensuring action order is correct (if dependencies exist)