/// Module for managing liquidity-related proposals in the futarchy system.
/// 
/// # Security Considerations
/// - All treasury operations require ProposalExecutionContext for authorization
/// - Coins are returned directly from treasury functions without intermediate transfers
/// - LP tokens are deposited back to treasury after pool creation
/// - Amount validation is performed in the DAO treasury functions
/// 
/// # Architecture
/// This module acts as a bridge between proposal execution and liquidity management,
/// ensuring that DAO treasury funds are only accessible through approved proposals.
module futarchy::liquidity_proposals;

use std::string::String;
use sui::coin::{Coin};
use sui::event;
use sui::clock::Clock;
use sui::sui::SUI;

use futarchy::dao::{Self};
use futarchy::dao_state::{Self, DAO};
use futarchy::spot_liquidity_pool::{Self, SpotLiquidityPool, LP};
use futarchy::execution_context::ProposalExecutionContext;
use futarchy::treasury::{Self, Treasury};
use futarchy::fee;
use sui::table::{Self, Table};

// === Errors ===
const EInvalidAmount: u64 = 0;
const EInsufficientTreasuryBalance: u64 = 1;
const EPoolNotFound: u64 = 2;
const EInvalidRatio: u64 = 3;
const EActionsAlreadyStored: u64 = 4;
const ENoActionsFound: u64 = 5;
const EAlreadyExecuted: u64 = 6;
const EInvalidOutcome: u64 = 7;

// === Events ===

public struct AddLiquidityProposalCreated has copy, drop {
    dao_id: ID,
    proposal_id: ID,
    asset_amount: u64,
    stable_amount: u64,
}

public struct RemoveLiquidityProposalCreated has copy, drop {
    dao_id: ID,
    proposal_id: ID,
    lp_amount: u64,
}

public struct UpdatePoolFeesProposalCreated has copy, drop {
    dao_id: ID,
    proposal_id: ID,
    new_lp_fee_bps: u16,
    new_protocol_fee_bps: u16,
}

public struct CreateSpotPoolProposalCreated has copy, drop {
    dao_id: ID,
    proposal_id: ID,
    initial_asset: u64,
    initial_stable: u64,
}

// === Constants ===
const LIQUIDITY_ACTION_ADD: u8 = 0;
const LIQUIDITY_ACTION_REMOVE: u8 = 1;
const LIQUIDITY_ACTION_UPDATE_FEES: u8 = 2;
const LIQUIDITY_ACTION_CREATE_POOL: u8 = 3;

// === Structs ===

/// Registry to store liquidity actions for proposals
public struct LiquidityActionRegistry has key {
    id: UID,
    // Map proposal_id -> LiquidityProposalActions
    actions: Table<ID, LiquidityProposalActions>,
}

/// Liquidity actions for a proposal
public struct LiquidityProposalActions has store {
    // Map outcome -> LiquidityAction (stored at proposal creation)
    outcome_actions: Table<u64, LiquidityAction>,
    // Track execution status
    executed: bool,
}

/// Wrapper for different liquidity action types
public struct LiquidityAction has store, drop {
    action_type: u8,
    // Only one of these will be Some
    add_liquidity: Option<AddLiquidityAction>,
    remove_liquidity: Option<RemoveLiquidityAction>,
    update_fees: Option<UpdatePoolFeesAction>,
    create_pool: Option<CreateSpotPoolAction>,
}

/// Action to add liquidity from DAO treasury to spot pool
public struct AddLiquidityAction has store, drop {
    asset_amount: u64,
    stable_amount: u64,
    min_lp_out: u64, // Minimum LP tokens to receive (slippage protection)
}

/// Action to remove liquidity from spot pool to DAO treasury
public struct RemoveLiquidityAction has store, drop {
    lp_amount: u64,
    min_asset_out: u64,
    min_stable_out: u64,
}

/// Action to update pool fee parameters
public struct UpdatePoolFeesAction has store, drop {
    new_lp_fee_bps: u16,
    new_protocol_fee_bps: u16,
}

/// Action to create a new spot liquidity pool
public struct CreateSpotPoolAction has store, drop {
    initial_asset: u64,
    initial_stable: u64,
    lp_fee_bps: u16,
    protocol_fee_bps: u16,
}

// === Init Function ===

fun init(ctx: &mut TxContext) {
    let registry = LiquidityActionRegistry {
        id: object::new(ctx),
        actions: table::new(ctx),
    };
    transfer::share_object(registry);
}

// === Action Creation Functions ===

/// Create an add liquidity action
public fun create_add_liquidity_action(
    asset_amount: u64,
    stable_amount: u64,
    min_lp_out: u64,
): LiquidityAction {
    LiquidityAction {
        action_type: LIQUIDITY_ACTION_ADD,
        add_liquidity: option::some(AddLiquidityAction {
            asset_amount,
            stable_amount,
            min_lp_out,
        }),
        remove_liquidity: option::none(),
        update_fees: option::none(),
        create_pool: option::none(),
    }
}

/// Create a remove liquidity action
public fun create_remove_liquidity_action(
    lp_amount: u64,
    min_asset_out: u64,
    min_stable_out: u64,
): LiquidityAction {
    LiquidityAction {
        action_type: LIQUIDITY_ACTION_REMOVE,
        add_liquidity: option::none(),
        remove_liquidity: option::some(RemoveLiquidityAction {
            lp_amount,
            min_asset_out,
            min_stable_out,
        }),
        update_fees: option::none(),
        create_pool: option::none(),
    }
}

/// Create an update fees action
public fun create_update_fees_action(
    new_lp_fee_bps: u16,
    new_protocol_fee_bps: u16,
): LiquidityAction {
    LiquidityAction {
        action_type: LIQUIDITY_ACTION_UPDATE_FEES,
        add_liquidity: option::none(),
        remove_liquidity: option::none(),
        update_fees: option::some(UpdatePoolFeesAction {
            new_lp_fee_bps,
            new_protocol_fee_bps,
        }),
        create_pool: option::none(),
    }
}

/// Create a create pool action
public fun create_spot_pool_action(
    initial_asset: u64,
    initial_stable: u64,
    lp_fee_bps: u16,
    protocol_fee_bps: u16,
): LiquidityAction {
    LiquidityAction {
        action_type: LIQUIDITY_ACTION_CREATE_POOL,
        add_liquidity: option::none(),
        remove_liquidity: option::none(),
        update_fees: option::none(),
        create_pool: option::some(CreateSpotPoolAction {
            initial_asset,
            initial_stable,
            lp_fee_bps,
            protocol_fee_bps,
        }),
    }
}

// === Storage Functions ===

/// Store liquidity actions for a proposal
public(package) fun store_liquidity_actions(
    registry: &mut LiquidityActionRegistry,
    proposal_id: ID,
    outcome_actions: Table<u64, LiquidityAction>,
) {
    assert!(!table::contains(&registry.actions, proposal_id), EActionsAlreadyStored);
    
    let actions = LiquidityProposalActions {
        outcome_actions,
        executed: false,
    };
    
    table::add(&mut registry.actions, proposal_id, actions);
}

/// Get liquidity action for a specific outcome
public(package) fun get_liquidity_action(
    registry: &LiquidityActionRegistry,
    proposal_id: ID,
    outcome: u64,
): &LiquidityAction {
    assert!(table::contains(&registry.actions, proposal_id), ENoActionsFound);
    let actions = table::borrow(&registry.actions, proposal_id);
    assert!(table::contains(&actions.outcome_actions, outcome), EInvalidOutcome);
    table::borrow(&actions.outcome_actions, outcome)
}

/// Mark actions as executed
public(package) fun mark_executed(
    registry: &mut LiquidityActionRegistry,
    proposal_id: ID,
) {
    assert!(table::contains(&registry.actions, proposal_id), ENoActionsFound);
    let actions = table::borrow_mut(&mut registry.actions, proposal_id);
    assert!(!actions.executed, EAlreadyExecuted);
    actions.executed = true;
}

// === Public Functions ===

/// Create a proposal to add liquidity from DAO treasury
public entry fun create_add_liquidity_proposal<Asset, Stable>(
    dao: &mut DAO<Asset, Stable>,
    registry: &mut LiquidityActionRegistry,
    fee_manager: &mut fee::FeeManager,
    payment: Coin<SUI>,
    dao_fee_payment: Coin<Stable>,
    title: String,
    metadata: String,
    asset_amount: u64,
    stable_amount: u64,
    min_lp_out: u64, // Minimum LP tokens to receive (slippage protection)
    initial_outcome_messages: vector<String>,
    initial_outcome_details: vector<String>,
    initial_outcome_asset_amounts: vector<u64>,
    initial_outcome_stable_amounts: vector<u64>,
    clock: &Clock,
    ctx: &mut TxContext
) {
    assert!(asset_amount > 0 && stable_amount > 0, EInvalidAmount);
    
    // Create the proposal through DAO's internal function
    let (proposal_id, market_id, _) = dao::create_proposal_internal(
        dao,
        fee_manager,
        payment,
        dao_fee_payment,
        title,
        metadata,
        initial_outcome_messages,
        initial_outcome_details,
        initial_outcome_asset_amounts,
        initial_outcome_stable_amounts,
        false, // uses_dao_liquidity
        clock,
        ctx
    );
    
    // Create outcome actions table
    let mut outcome_actions = table::new<u64, LiquidityAction>(ctx);
    let outcome_count = initial_outcome_messages.length();
    let mut i = 0;
    
    // For add liquidity, all outcomes have the same action
    while (i < outcome_count) {
        let action = create_add_liquidity_action(asset_amount, stable_amount, min_lp_out);
        table::add(&mut outcome_actions, i, action);
        i = i + 1;
    };
    
    // Store actions in registry
    store_liquidity_actions(registry, proposal_id, outcome_actions);
    
    event::emit(AddLiquidityProposalCreated {
        dao_id: object::id(dao),
        proposal_id,
        asset_amount,
        stable_amount,
    });
}

/// Create a proposal to remove liquidity to DAO treasury
public entry fun create_remove_liquidity_proposal<Asset, Stable>(
    dao: &mut DAO<Asset, Stable>,
    registry: &mut LiquidityActionRegistry,
    fee_manager: &mut fee::FeeManager,
    payment: Coin<SUI>,
    dao_fee_payment: Coin<Stable>,
    title: String,
    metadata: String,
    lp_amount: u64,
    min_asset_out: u64,
    min_stable_out: u64,
    initial_outcome_messages: vector<String>,
    initial_outcome_details: vector<String>,
    initial_outcome_asset_amounts: vector<u64>,
    initial_outcome_stable_amounts: vector<u64>,
    clock: &Clock,
    ctx: &mut TxContext
) {
    assert!(lp_amount > 0, EInvalidAmount);
    
    // Create the proposal through DAO's internal function
    let (proposal_id, market_id, _) = dao::create_proposal_internal(
        dao,
        fee_manager,
        payment,
        dao_fee_payment,
        title,
        metadata,
        initial_outcome_messages,
        initial_outcome_details,
        initial_outcome_asset_amounts,
        initial_outcome_stable_amounts,
        false, // uses_dao_liquidity
        clock,
        ctx
    );
    
    // Create outcome actions table
    let mut outcome_actions = table::new<u64, LiquidityAction>(ctx);
    let outcome_count = initial_outcome_messages.length();
    let mut i = 0;
    
    // For remove liquidity, all outcomes have the same action
    while (i < outcome_count) {
        let action = create_remove_liquidity_action(lp_amount, min_asset_out, min_stable_out);
        table::add(&mut outcome_actions, i, action);
        i = i + 1;
    };
    
    // Store actions in registry
    store_liquidity_actions(registry, proposal_id, outcome_actions);
    
    event::emit(RemoveLiquidityProposalCreated {
        dao_id: object::id(dao),
        proposal_id,
        lp_amount,
    });
}

/// Create a proposal to update pool fees
public entry fun create_update_fees_proposal<Asset, Stable>(
    dao: &mut DAO<Asset, Stable>,
    registry: &mut LiquidityActionRegistry,
    fee_manager: &mut fee::FeeManager,
    payment: Coin<SUI>,
    dao_fee_payment: Coin<Stable>,
    title: String,
    metadata: String,
    new_lp_fee_bps: u16,
    new_protocol_fee_bps: u16,
    initial_outcome_messages: vector<String>,
    initial_outcome_details: vector<String>,
    initial_outcome_asset_amounts: vector<u64>,
    initial_outcome_stable_amounts: vector<u64>,
    clock: &Clock,
    ctx: &mut TxContext
) {
    // Validate individual fees and total
    assert!(new_lp_fee_bps <= 500, EInvalidAmount); // Max 5% LP fee
    assert!(new_protocol_fee_bps <= 200, EInvalidAmount); // Max 2% protocol fee
    assert!(new_lp_fee_bps + new_protocol_fee_bps < 1000, EInvalidAmount); // Max 10% total
    
    // Create the proposal through DAO's internal function
    let (proposal_id, market_id, _) = dao::create_proposal_internal(
        dao,
        fee_manager,
        payment,
        dao_fee_payment,
        title,
        metadata,
        initial_outcome_messages,
        initial_outcome_details,
        initial_outcome_asset_amounts,
        initial_outcome_stable_amounts,
        false, // uses_dao_liquidity
        clock,
        ctx
    );
    
    // Create outcome actions table
    let mut outcome_actions = table::new<u64, LiquidityAction>(ctx);
    let outcome_count = initial_outcome_messages.length();
    let mut i = 0;
    
    // For update fees, all outcomes have the same action
    while (i < outcome_count) {
        let action = create_update_fees_action(new_lp_fee_bps, new_protocol_fee_bps);
        table::add(&mut outcome_actions, i, action);
        i = i + 1;
    };
    
    // Store actions in registry
    store_liquidity_actions(registry, proposal_id, outcome_actions);
    
    event::emit(UpdatePoolFeesProposalCreated {
        dao_id: object::id(dao),
        proposal_id,
        new_lp_fee_bps,
        new_protocol_fee_bps,
    });
}

/// Create a proposal to initialize a new spot pool
public entry fun create_spot_pool_proposal<Asset, Stable>(
    dao: &mut DAO<Asset, Stable>,
    registry: &mut LiquidityActionRegistry,
    fee_manager: &mut fee::FeeManager,
    payment: Coin<SUI>,
    dao_fee_payment: Coin<Stable>,
    title: String,
    metadata: String,
    initial_asset: u64,
    initial_stable: u64,
    lp_fee_bps: u16,
    protocol_fee_bps: u16,
    initial_outcome_messages: vector<String>,
    initial_outcome_details: vector<String>,
    initial_outcome_asset_amounts: vector<u64>,
    initial_outcome_stable_amounts: vector<u64>,
    clock: &Clock,
    ctx: &mut TxContext
) {
    assert!(initial_asset > 0 && initial_stable > 0, EInvalidAmount);
    
    // Check against DAO minimums
    let (min_asset, min_stable) = dao::get_min_amounts(dao);
    assert!(initial_asset >= min_asset, EInvalidAmount);
    assert!(initial_stable >= min_stable, EInvalidAmount);
    
    // Create the proposal through DAO's internal function
    let (proposal_id, market_id, _) = dao::create_proposal_internal(
        dao,
        fee_manager,
        payment,
        dao_fee_payment,
        title,
        metadata,
        initial_outcome_messages,
        initial_outcome_details,
        initial_outcome_asset_amounts,
        initial_outcome_stable_amounts,
        false, // uses_dao_liquidity
        clock,
        ctx
    );
    
    // Create outcome actions table
    let mut outcome_actions = table::new<u64, LiquidityAction>(ctx);
    let outcome_count = initial_outcome_messages.length();
    let mut i = 0;
    
    // For create pool, all outcomes have the same action
    while (i < outcome_count) {
        let action = create_spot_pool_action(initial_asset, initial_stable, lp_fee_bps, protocol_fee_bps);
        table::add(&mut outcome_actions, i, action);
        i = i + 1;
    };
    
    // Store actions in registry
    store_liquidity_actions(registry, proposal_id, outcome_actions);
    
    event::emit(CreateSpotPoolProposalCreated {
        dao_id: object::id(dao),
        proposal_id,
        initial_asset,
        initial_stable,
    });
}

// === Execution Functions ===

/// Execute add liquidity proposal
public(package) fun execute_add_liquidity<Asset: drop, Stable: drop>(
    dao: &mut DAO<Asset, Stable>,
    registry: &mut LiquidityActionRegistry,
    treasury: &mut Treasury,
    pool: &mut SpotLiquidityPool<Asset, Stable>,
    proposal_id: ID,
    winning_outcome: u64,
    execution_context: &mut ProposalExecutionContext,
    clock: &Clock,
    ctx: &mut TxContext
) {
    // Get the action for the winning outcome
    let action = get_liquidity_action(registry, proposal_id, winning_outcome);
    assert!(action.action_type == LIQUIDITY_ACTION_ADD, EInvalidAmount);
    
    let add_action = option::borrow(&action.add_liquidity);
    let asset_amount = add_action.asset_amount;
    let stable_amount = add_action.stable_amount;
    
    // Get coins from DAO treasury
    let asset_coin = dao::withdraw_asset_from_treasury(
        dao,
        treasury,
        execution_context,
        asset_amount,
        ctx.sender(),
        clock,
        ctx
    );
    let stable_coin = dao::withdraw_stable_from_treasury(
        dao,
        treasury,
        execution_context,
        stable_amount,
        ctx.sender(),
        clock,
        ctx
    );
    
    // Use the internal add_liquidity function that returns LP tokens
    let lp_tokens = spot_liquidity_pool::add_liquidity_spot_only(
        pool,
        asset_coin,
        stable_coin,
        add_action.min_lp_out, // Use the minimum LP out from the proposal
        ctx
    );
    
    // The returned LP tokens need to be deposited back into the treasury
    treasury::deposit_without_drop(
        treasury,
        lp_tokens,
        ctx
    );
    
    // Mark as executed
    mark_executed(registry, proposal_id);
}

/// Execute remove liquidity proposal
public(package) fun execute_remove_liquidity<Asset: drop, Stable: drop>(
    dao: &mut DAO<Asset, Stable>,
    registry: &mut LiquidityActionRegistry,
    treasury: &mut Treasury,
    pool: &mut SpotLiquidityPool<Asset, Stable>,
    proposal_id: ID,
    winning_outcome: u64,
    execution_context: &mut ProposalExecutionContext,
    clock: &Clock,
    ctx: &mut TxContext
) {
    // Get the action for the winning outcome
    let action = get_liquidity_action(registry, proposal_id, winning_outcome);
    assert!(action.action_type == LIQUIDITY_ACTION_REMOVE, EInvalidAmount);
    
    let remove_action = option::borrow(&action.remove_liquidity);
    let lp_amount = remove_action.lp_amount;
    let min_asset_out = remove_action.min_asset_out;
    let min_stable_out = remove_action.min_stable_out;
    
    // Withdraw the required LP tokens from the DAO's treasury
    let lp_coin = dao::withdraw_lp_from_treasury<Asset, Stable, LP<Asset, Stable>>(
        dao,
        treasury,
        execution_context,
        lp_amount,
        ctx.sender(),
        clock,
        ctx
    );
    
    // Remove liquidity from pool
    let (asset_coin, stable_coin) = spot_liquidity_pool::remove_liquidity_spot_only(
        pool,
        lp_coin,
        min_asset_out,
        min_stable_out,
        ctx
    );
    
    // Deposit the withdrawn assets back into the DAO treasury
    treasury::deposit_without_drop(treasury, asset_coin, ctx);
    treasury::deposit_without_drop(treasury, stable_coin, ctx);
    
    // Mark as executed
    mark_executed(registry, proposal_id);
}

/// Execute update fees proposal
public(package) fun execute_update_fees<Asset: drop, Stable: drop>(
    dao: &mut DAO<Asset, Stable>,
    registry: &mut LiquidityActionRegistry,
    pool: &mut SpotLiquidityPool<Asset, Stable>,
    proposal_id: ID,
    winning_outcome: u64,
    execution_context: &mut ProposalExecutionContext,
    ctx: &mut TxContext
) {
    // Get the action for the winning outcome
    let action = get_liquidity_action(registry, proposal_id, winning_outcome);
    assert!(action.action_type == LIQUIDITY_ACTION_UPDATE_FEES, EInvalidAmount);
    
    let update_action = option::borrow(&action.update_fees);
    let new_lp_fee_bps = update_action.new_lp_fee_bps;
    let new_protocol_fee_bps = update_action.new_protocol_fee_bps;
    
    // Update fees
    spot_liquidity_pool::update_fees(
        pool,
        new_lp_fee_bps,
        new_protocol_fee_bps,
        ctx
    );
    
    // Mark as executed
    mark_executed(registry, proposal_id);
}

/// Execute create spot pool proposal
public(package) fun execute_create_spot_pool<Asset: drop, Stable: drop>(
    dao: &mut DAO<Asset, Stable>,
    registry: &mut LiquidityActionRegistry,
    treasury: &mut Treasury,
    proposal_id: ID,
    winning_outcome: u64,
    execution_context: &mut ProposalExecutionContext,
    clock: &Clock,
    ctx: &mut TxContext
) {
    // Get the action for the winning outcome
    let action = get_liquidity_action(registry, proposal_id, winning_outcome);
    assert!(action.action_type == LIQUIDITY_ACTION_CREATE_POOL, EInvalidAmount);
    
    let create_action = option::borrow(&action.create_pool);
    let initial_asset = create_action.initial_asset;
    let initial_stable = create_action.initial_stable;
    let lp_fee_bps = create_action.lp_fee_bps;
    let protocol_fee_bps = create_action.protocol_fee_bps;
    
    // Get initial liquidity from DAO treasury
    let asset_coin = dao::withdraw_asset_from_treasury(
        dao,
        treasury,
        execution_context,
        initial_asset,
        ctx.sender(),
        clock,
        ctx
    );
    let stable_coin = dao::withdraw_stable_from_treasury(
        dao,
        treasury,
        execution_context,
        initial_stable,
        ctx.sender(),
        clock,
        ctx
    );
    
    // Create the pool
    let (pool, initial_lp, protocol_admin_cap) = spot_liquidity_pool::create_pool<Asset, Stable>(
        dao,
        asset_coin,
        stable_coin,
        lp_fee_bps,
        protocol_fee_bps,
        ctx
    );
    
    // Transfer pool to DAO as a shared object
    transfer::public_share_object(pool);
    
    // Transfer the protocol admin cap to the DAO address for governance control
    // This ensures the admin cap is controlled by DAO governance rather than an individual
    // The DAO can later retrieve and use this cap through governance proposals
    transfer::public_transfer(protocol_admin_cap, object::id_to_address(&object::id(dao)));
    
    // Deposit the newly minted LP tokens into the treasury
    treasury::deposit_without_drop(treasury, initial_lp, ctx);
    
    // Mark as executed
    mark_executed(registry, proposal_id);
}