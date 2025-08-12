module futarchy::proposal;

use futarchy::conditional_amm::{Self, LiquidityPool};
use futarchy::coin_escrow::{Self, TokenEscrow};
use futarchy::liquidity_initialize;
use futarchy::market_state;
use std::ascii::String as AsciiString;
use std::string::String;
use std::type_name;
use sui::balance::{Balance};
use sui::clock::Clock;
use sui::coin::{Coin};
use sui::event;

// === Introduction ===
// This defines the core proposal logic and details

// === Errors ===

const EInvalidAmount: u64 = 1;
const EInvalidState: u64 = 2;
const EAssetLiquidityTooLow: u64 = 4;
const EStableLiquidityTooLow: u64 = 5;
const EPoolNotFound: u64 = 6;
const EOutcomeOutOfBounds: u64 = 7;
const EInvalidOutcomeVectors: u64 = 8;

// === Constants ===

const STATE_PREMARKET: u8 = 0; // Proposal exists, outcomes can be added/mutated. No market yet.
const STATE_REVIEW: u8 = 1;    // Market is initialized and locked for review. Not yet trading.
const STATE_TRADING: u8 = 2;   // Market is live and trading.
const STATE_FINALIZED: u8 = 3; // Market has resolved.

// Outcome constants for TWAP calculation
const OUTCOME_ACCEPTED: u64 = 0;
const OUTCOME_REJECTED: u64 = 1;

// === Structs ===

/// Core proposal object that owns AMM pools
public struct Proposal<phantom AssetType, phantom StableType> has key, store {
    id: UID,
    /// The logical ID of the proposal from the priority queue.
    queued_proposal_id: ID,
    created_at: u64,
    market_initialized_at: Option<u64>,
    state: u8,
    outcome_count: u64,
    dao_id: ID,
    proposer: address, // The original proposer.
    liquidity_provider: Option<address>, // The user who provides liquidity (gets liquidity back).
    supply_ids: Option<vector<ID>>,
    amm_pools: Option<vector<LiquidityPool>>,
    // LP tokens are now handled as conditional tokens with asset_type = 2
    escrow_id: Option<ID>,
    market_state_id: Option<ID>,
    title: String,
    details: vector<String>,
    metadata: String,
    outcome_messages: vector<String>,
    // The creator of each specific outcome's text/parameters (gets fee rebate if outcome wins).
    outcome_creators: vector<address>,
    // Liquidity targets for each outcome, defined during premarket.
    asset_amounts: vector<u64>,
    stable_amounts: vector<u64>,
    twap_prices: vector<u128>, // Historical TWAP prices
    last_twap_update: u64,
    review_period_ms: u64,
    trading_period_ms: u64,
    min_asset_liquidity: u64,
    min_stable_liquidity: u64,
    twap_start_delay: u64,
    // A flag to indicate if this proposal's liquidity comes from the DAO pool.
    uses_dao_liquidity: bool,
    twap_initial_observation: u128,
    twap_step_max: u64,
    twap_threshold: u64,
    amm_total_fee_bps: u64,
    winning_outcome: Option<u64>,
    fee_escrow: Balance<StableType>,
    treasury_address: address,
    /// Intent keys for each outcome - when outcome i wins, create and execute intent with this key
    /// Intents are NOT created in Account until the outcome wins
    intent_keys: vector<Option<String>>,
}

// === Events ===

public struct ProposalCreated has copy, drop {
    proposal_id: ID,
    dao_id: ID,
    proposer: address,
    outcome_count: u64,
    outcome_messages: vector<String>,
    created_at: u64,
    asset_type: AsciiString,
    stable_type: AsciiString,
    review_period_ms: u64,
    trading_period_ms: u64,
    title: String,
    metadata: String,
}

public struct ProposalMarketInitialized has copy, drop {
    proposal_id: ID,
    dao_id: ID,
    market_state_id: ID,
    escrow_id: ID,
    timestamp: u64,
}

public struct ProposalOutcomeMutated has copy, drop {
    proposal_id: ID,
    dao_id: ID,
    outcome_idx: u64,
    old_creator: address,
    new_creator: address,
    timestamp: u64,
}

public struct ProposalOutcomeAdded has copy, drop {
    proposal_id: ID,
    dao_id: ID,
    new_outcome_idx: u64,
    creator: address,
    timestamp: u64,
}

// === Public Functions ===

/// Creates all on-chain objects for a futarchy market when a proposal is activated from the queue.
/// This is the main entry point for creating a full proposal with market infrastructure.
#[allow(lint(share_owned))]
public(package) fun initialize_market<AssetType, StableType>(
    // Proposal ID (generated when adding to queue)
    proposal_id: ID,
    // Market parameters from DAO
    dao_id: ID,
    review_period_ms: u64,
    trading_period_ms: u64,
    min_asset_liquidity: u64,
    min_stable_liquidity: u64,
    twap_start_delay: u64,
    twap_initial_observation: u128,
    twap_step_max: u64,
    twap_threshold: u64,
    amm_total_fee_bps: u64,
    treasury_address: address,
    // Proposal specific parameters
    title: String,
    metadata: String,
    initial_outcome_messages: vector<String>,
    initial_outcome_details: vector<String>,
    asset_coin: Coin<AssetType>,
    stable_coin: Coin<StableType>,
    proposer: address, // The original proposer from the queue
    uses_dao_liquidity: bool,
    fee_escrow: Balance<StableType>, // DAO fees if any
    intent_key_for_yes: Option<String>, // Intent key for YES outcome
    clock: &Clock,
    ctx: &mut TxContext,
): (ID, ID, u8) {

    // Create a new proposal UID
    let id = object::new(ctx);
    let actual_proposal_id = object::uid_to_inner(&id);
    let outcome_count = initial_outcome_messages.length();

    // Validate outcome count
    assert!(outcome_count == initial_outcome_details.length(), EInvalidOutcomeVectors);

    // Liquidity is split evenly among all outcomes
    let total_asset_liquidity = asset_coin.value();
    let total_stable_liquidity = stable_coin.value();
    assert!(total_asset_liquidity > 0 && total_stable_liquidity > 0, EInvalidAmount);
    
    let asset_per_outcome = total_asset_liquidity / outcome_count;
    let stable_per_outcome = total_stable_liquidity / outcome_count;
    
    // Calculate remainders from integer division
    let asset_remainder = total_asset_liquidity % outcome_count;
    let stable_remainder = total_stable_liquidity % outcome_count;
    
    // Distribute liquidity evenly, with remainder going to first outcomes
    let mut initial_asset_amounts = vector::empty<u64>();
    let mut initial_stable_amounts = vector::empty<u64>();
    let mut i = 0;
    while (i < outcome_count) {
        // Add 1 extra token to first 'remainder' outcomes
        let asset_amount = if (i < asset_remainder) { asset_per_outcome + 1 } else { asset_per_outcome };
        let stable_amount = if (i < stable_remainder) { stable_per_outcome + 1 } else { stable_per_outcome };
        
        vector::push_back(&mut initial_asset_amounts, asset_amount);
        vector::push_back(&mut initial_stable_amounts, stable_amount);
        i = i + 1;
    };

    // Validate minimum liquidity requirements
    assert!(asset_per_outcome >= min_asset_liquidity, EAssetLiquidityTooLow);
    assert!(stable_per_outcome >= min_stable_liquidity, EStableLiquidityTooLow);

    // Initialize outcome creators to the original proposer
    let outcome_creators = vector::tabulate!(outcome_count, |_| proposer);

    // Create market state
    let market_state = market_state::new(
        actual_proposal_id,  // Use the actual proposal ID, not the parameter
        dao_id, 
        outcome_count, 
        initial_outcome_messages, 
        clock, 
        ctx
    );
    let market_state_id = object::id(&market_state);

    // Create escrow
    let mut escrow = coin_escrow::new<AssetType, StableType>(market_state, ctx);
    let escrow_id = object::id(&escrow);

    // Create AMM pools and initialize liquidity
    let mut asset_balance = asset_coin.into_balance();
    let mut stable_balance = stable_coin.into_balance();
    
    // Quantum liquidity: the same liquidity backs all outcomes conditionally
    // We only need the MAX amount across outcomes since they share the same underlying liquidity
    let mut max_asset = 0u64;
    let mut max_stable = 0u64;
    let mut j = 0;
    while (j < outcome_count) {
        let asset_amt = *initial_asset_amounts.borrow(j);
        let stable_amt = *initial_stable_amounts.borrow(j);
        if (asset_amt > max_asset) { max_asset = asset_amt };
        if (stable_amt > max_stable) { max_stable = stable_amt };
        j = j + 1;
    };
    
    // Extract the exact amount needed for quantum liquidity
    let asset_total = asset_balance.value();
    let stable_total = stable_balance.value();
    
    let asset_for_pool = if (asset_total > max_asset) {
        asset_balance.split(max_asset)
    } else {
        asset_balance.split(asset_total)
    };
    
    let stable_for_pool = if (stable_total > max_stable) {
        stable_balance.split(max_stable)
    } else {
        stable_balance.split(stable_total)
    };
    
    // Return excess to proposer if any
    if (asset_balance.value() > 0) {
        transfer::public_transfer(asset_balance.into_coin(ctx), proposer);
    } else {
        asset_balance.destroy_zero();
    };
    
    if (stable_balance.value() > 0) {
        transfer::public_transfer(stable_balance.into_coin(ctx), proposer);
    } else {
        stable_balance.destroy_zero();
    };
    
    let (_, amm_pools) = liquidity_initialize::create_outcome_markets(
        &mut escrow, 
        outcome_count, 
        initial_asset_amounts, 
        initial_stable_amounts,
        twap_start_delay, 
        twap_initial_observation, 
        twap_step_max,
        amm_total_fee_bps,
        asset_for_pool, 
        stable_for_pool, 
        clock, 
        ctx
    );

    // Create proposal object
    let proposal = Proposal<AssetType, StableType> {
        id,
        queued_proposal_id: proposal_id,
        created_at: clock.timestamp_ms(),
        market_initialized_at: option::some(clock.timestamp_ms()),
        state: STATE_REVIEW, // Start in REVIEW state since market is initialized
        outcome_count,
        dao_id,
        proposer,
        liquidity_provider: option::some(ctx.sender()), // The activator provides liquidity
        supply_ids: option::none(), // Will be set when escrow mints tokens
        amm_pools: option::some(amm_pools),
        // lp_caps no longer needed - using conditional tokens
        escrow_id: option::some(escrow_id),
        market_state_id: option::some(market_state_id),
        title,
        details: initial_outcome_details,
        metadata,
        outcome_messages: initial_outcome_messages,
        outcome_creators,
        asset_amounts: initial_asset_amounts,
        stable_amounts: initial_stable_amounts,
        min_asset_liquidity,
        min_stable_liquidity,
        twap_start_delay,
        uses_dao_liquidity,
        twap_initial_observation,
        twap_step_max,
        twap_threshold,
        amm_total_fee_bps,
        winning_outcome: option::none(),
        fee_escrow,
        treasury_address,
        // Initialize with no intent keys for each outcome
        // Intent keys will be set separately if needed
        intent_keys: vector::tabulate!(outcome_count, |_| option::none()),
        review_period_ms,
        trading_period_ms,
        twap_prices: vector::empty(),
        last_twap_update: 0,
    };

    event::emit(ProposalCreated {
        proposal_id: actual_proposal_id,
        dao_id,
        proposer,
        outcome_count,
        outcome_messages: initial_outcome_messages,
        created_at: clock.timestamp_ms(),
        asset_type: type_name::get<AssetType>().into_string(),
        stable_type: type_name::get<StableType>().into_string(),
        review_period_ms,
        trading_period_ms,
        title,
        metadata,
    });

    transfer::public_share_object(proposal);
    transfer::public_share_object(escrow);

    // Return the actual on-chain proposal ID, not the queue ID
    (actual_proposal_id, market_state_id, STATE_REVIEW)
}

// The create function has been removed as it's not used in production.
// All proposals are created through initialize_market which properly handles proposal IDs
// generated from the priority queue.

/// Create a PREMARKET proposal without market/escrow/liquidity.
/// This reserves the proposal "as next" without consuming DAO/proposer liquidity.
#[allow(lint(share_owned))]
public(package) fun new_premarket<AssetType, StableType>(
    // Proposal ID originating from queue
    proposal_id_from_queue: ID,
    dao_id: ID,
    review_period_ms: u64,
    trading_period_ms: u64,
    min_asset_liquidity: u64,
    min_stable_liquidity: u64,
    twap_start_delay: u64,
    twap_initial_observation: u128,
    twap_step_max: u64,
    twap_threshold: u64,
    amm_total_fee_bps: u64,
    treasury_address: address,
    title: String,
    metadata: String,
    outcome_messages: vector<String>,
    outcome_details: vector<String>,
    proposer: address,
    uses_dao_liquidity: bool,
    fee_escrow: Balance<StableType>,
    intent_key_for_yes: Option<String>,
    clock: &Clock,
    ctx: &mut TxContext,
): ID {
    let id = object::new(ctx);
    let actual_proposal_id = object::uid_to_inner(&id);
    let outcome_count = outcome_messages.length();
    
    let proposal = Proposal<AssetType, StableType> {
        id,
        queued_proposal_id: proposal_id_from_queue,
        created_at: clock.timestamp_ms(),
        market_initialized_at: option::none(),
        state: STATE_PREMARKET,
        outcome_count,
        dao_id,
        proposer,
        liquidity_provider: option::none(),
        supply_ids: option::none(),
        amm_pools: option::none(),
        escrow_id: option::none(),
        market_state_id: option::none(),
        title,
        details: outcome_details,
        metadata,
        outcome_messages,
        outcome_creators: vector::tabulate!(outcome_count, |_| proposer),
        // Will be computed at market initialization from coin inputs
        asset_amounts: vector::empty(),
        stable_amounts: vector::empty(),
        min_asset_liquidity,
        min_stable_liquidity,
        twap_start_delay,
        uses_dao_liquidity,
        twap_initial_observation,
        twap_step_max,
        twap_threshold,
        amm_total_fee_bps,
        winning_outcome: option::none(),
        fee_escrow,
        treasury_address,
        intent_keys: vector::tabulate!(outcome_count, |_| option::none()),
        review_period_ms,
        trading_period_ms,
        twap_prices: vector::empty(),
        last_twap_update: 0,
    };
    
    transfer::public_share_object(proposal);
    actual_proposal_id
}

/// Initialize market/escrow/AMMs for a PREMARKET proposal.
/// Consumes provided coins, sets state to REVIEW, and readies the market for the review timer.
#[allow(lint(share_owned, self_transfer))]
public(package) fun initialize_market_from_premarket<AssetType, StableType>(
    proposal: &mut Proposal<AssetType, StableType>,
    asset_coin: Coin<AssetType>,
    stable_coin: Coin<StableType>,
    clock: &Clock,
    ctx: &mut TxContext,
): ID {
    assert!(proposal.state == STATE_PREMARKET, EInvalidState);
    
    // Evenly split liquidity across outcomes (same convention as initialize_market)
    let outcome_count = proposal.outcome_count;
    let total_asset_liquidity = asset_coin.value();
    let total_stable_liquidity = stable_coin.value();
    assert!(total_asset_liquidity > 0 && total_stable_liquidity > 0, EInvalidAmount);
    
    let asset_per = total_asset_liquidity / outcome_count;
    let stable_per = total_stable_liquidity / outcome_count;
    assert!(asset_per >= proposal.min_asset_liquidity, EAssetLiquidityTooLow);
    assert!(stable_per >= proposal.min_stable_liquidity, EStableLiquidityTooLow);
    
    let asset_remainder = total_asset_liquidity % outcome_count;
    let stable_remainder = total_stable_liquidity % outcome_count;
    
    let mut initial_asset_amounts = vector::empty<u64>();
    let mut initial_stable_amounts = vector::empty<u64>();
    let mut i = 0;
    while (i < outcome_count) {
        let a = if (i < asset_remainder) { asset_per + 1 } else { asset_per };
        let s = if (i < stable_remainder) { stable_per + 1 } else { stable_per };
        vector::push_back(&mut initial_asset_amounts, a);
        vector::push_back(&mut initial_stable_amounts, s);
        i = i + 1;
    };
    
    // Market state
    let ms = market_state::new(
        object::id(proposal),
        proposal.dao_id,
        proposal.outcome_count,
        proposal.outcome_messages,
        clock,
        ctx
    );
    let market_state_id = object::id(&ms);
    
    // Escrow
    let mut escrow = coin_escrow::new<AssetType, StableType>(ms, ctx);
    let escrow_id = object::id(&escrow);
    
    // Determine quantum liquidity amounts
    let mut asset_balance = asset_coin.into_balance();
    let mut stable_balance = stable_coin.into_balance();
    
    let mut max_asset = 0u64;
    let mut max_stable = 0u64;
    i = 0;
    while (i < outcome_count) {
        let a = *initial_asset_amounts.borrow(i);
        let s = *initial_stable_amounts.borrow(i);
        if (a > max_asset) { max_asset = a };
        if (s > max_stable) { max_stable = s };
        i = i + 1;
    };
    
    let asset_total = asset_balance.value();
    let stable_total = stable_balance.value();
    
    let asset_for_pool = if (asset_total > max_asset) {
        asset_balance.split(max_asset)
    } else {
        asset_balance.split(asset_total)
    };
    
    let stable_for_pool = if (stable_total > max_stable) {
        stable_balance.split(max_stable)
    } else {
        stable_balance.split(stable_total)
    };
    
    // Return any excess to liquidity provider (the activator who supplied coins)
    let sender = ctx.sender();
    if (asset_balance.value() > 0) {
        transfer::public_transfer(asset_balance.into_coin(ctx), sender);
    } else {
        asset_balance.destroy_zero();
    };
    
    if (stable_balance.value() > 0) {
        transfer::public_transfer(stable_balance.into_coin(ctx), sender);
    } else {
        stable_balance.destroy_zero();
    };
    
    // Create outcome markets
    let (_supply_ids, amm_pools) = liquidity_initialize::create_outcome_markets(
        &mut escrow,
        proposal.outcome_count,
        initial_asset_amounts,
        initial_stable_amounts,
        proposal.twap_start_delay,
        proposal.twap_initial_observation,
        proposal.twap_step_max,
        proposal.amm_total_fee_bps,
        asset_for_pool,
        stable_for_pool,
        clock,
        ctx
    );
    
    // Update proposal's liquidity amounts
    proposal.asset_amounts = initial_asset_amounts;
    proposal.stable_amounts = initial_stable_amounts;
    
    // Initialize market fields: PREMARKET → REVIEW
    initialize_market_fields(
        proposal,
        market_state_id,
        escrow_id,
        amm_pools,
        clock.timestamp_ms(),
        sender
    );
    
    transfer::public_share_object(escrow);
    market_state_id
}

/// Adds a new outcome during the premarket phase.
public(package) fun add_outcome<AssetType, StableType>(
    proposal: &mut Proposal<AssetType, StableType>,
    message: String,
    detail: String,
    asset_amount: u64,
    stable_amount: u64,
    creator: address,
    clock: &Clock,
) {
    proposal.outcome_messages.push_back(message);
    proposal.details.push_back(detail);
    proposal.asset_amounts.push_back(asset_amount);
    proposal.stable_amounts.push_back(stable_amount);
    proposal.outcome_creators.push_back(creator);

    let new_idx = proposal.outcome_count;
    proposal.outcome_count = new_idx + 1;

    event::emit(ProposalOutcomeAdded {
        proposal_id: get_id(proposal),
        dao_id: get_dao_id(proposal),
        new_outcome_idx: new_idx,
        creator,
        timestamp: clock.timestamp_ms(),
    });
}

/// Initializes the market-related fields of the proposal.
public(package) fun initialize_market_fields<AssetType, StableType>(
    proposal: &mut Proposal<AssetType, StableType>,
    market_state_id: ID,
    escrow_id: ID,
    amm_pools: vector<LiquidityPool>,
    // LP tracking moved to conditional tokens
    initialized_at: u64,
    liquidity_provider: address,
) {
    assert!(proposal.state == STATE_PREMARKET, EInvalidState);

    // Use option::fill to replace None with Some value
    option::fill(&mut proposal.market_state_id, market_state_id);
    option::fill(&mut proposal.escrow_id, escrow_id);
    option::fill(&mut proposal.amm_pools, amm_pools);
    // LP caps no longer needed - using conditional tokens
    option::fill(&mut proposal.market_initialized_at, initialized_at);
    option::fill(&mut proposal.liquidity_provider, liquidity_provider);
    proposal.state = STATE_REVIEW; // Advance state to REVIEW
}

/// Emits the ProposalMarketInitialized event
public(package) fun emit_market_initialized(
    proposal_id: ID,
    dao_id: ID,
    market_state_id: ID,
    escrow_id: ID,
    timestamp: u64,
) {
    event::emit(ProposalMarketInitialized {
        proposal_id,
        dao_id,
        market_state_id,
        escrow_id,
        timestamp,
    });
}

/// Takes the escrowed fee balance out of the proposal, leaving a zero balance behind.
public(package) fun take_fee_escrow<AssetType, StableType>(
    proposal: &mut Proposal<AssetType, StableType>,
): Balance<StableType> {
    let fee_balance = &mut proposal.fee_escrow;
    let amount = fee_balance.value();
    sui::balance::split(fee_balance, amount)
}

/// Searches the proposal's liquidity pools for an oracle matching the target ID.
/// Returns a reference to that oracle; aborts if not found.
public fun get_twaps_for_proposal<AssetType, StableType>(
    proposal: &mut Proposal<AssetType, StableType>,
    clock: &Clock,
): vector<u128> {
    let pools = proposal.amm_pools.borrow_mut();
    let mut twaps = vector[];
    let mut i = 0;
    while (i < pools.length()) {
        let pool = &mut pools[i];
        let twap = pool.get_twap(clock);
        twaps.push_back(twap);
        i = i + 1;
    };
    twaps
}

// === Private Functions ===

fun get_pool_mut(pools: &mut vector<LiquidityPool>, outcome_idx: u8): &mut LiquidityPool {
    let mut i = 0;
    let len = pools.length();
    while (i < len) {
        let pool = &mut pools[i];
        if (pool.get_outcome_idx() == outcome_idx) {
            return pool
        };
        i = i + 1;
    };
    abort EPoolNotFound
}

// === View Functions ===

public fun is_finalized<AssetType, StableType>(proposal: &Proposal<AssetType, StableType>): bool {
    proposal.state == STATE_FINALIZED
}

public fun get_twap_prices<AssetType, StableType>(
    proposal: &Proposal<AssetType, StableType>,
): &vector<u128> {
    &proposal.twap_prices
}

public fun get_last_twap_update<AssetType, StableType>(
    proposal: &Proposal<AssetType, StableType>,
): u64 {
    proposal.last_twap_update
}

public fun state<AssetType, StableType>(proposal: &Proposal<AssetType, StableType>): u8 {
    proposal.state
}

public fun get_winning_outcome<AssetType, StableType>(
    proposal: &Proposal<AssetType, StableType>,
): u64 {
    assert!(proposal.winning_outcome.is_some(), EInvalidState);
    *proposal.winning_outcome.borrow()
}

/// Checks if winning outcome has been set
public fun is_winning_outcome_set<AssetType, StableType>(
    proposal: &Proposal<AssetType, StableType>,
): bool {
    proposal.winning_outcome.is_some()
}

/// Returns the treasury address where fees for failed proposals are sent.
public(package) fun treasury_address<AssetType, StableType>(
    proposal: &Proposal<AssetType, StableType>,
): address {
    proposal.treasury_address
}

public fun get_id<AssetType, StableType>(proposal: &Proposal<AssetType, StableType>): ID {
    proposal.id.to_inner()
}

public fun escrow_id<AssetType, StableType>(proposal: &Proposal<AssetType, StableType>): ID {
    assert!(proposal.escrow_id.is_some(), EInvalidState);
    *proposal.escrow_id.borrow()
}

public fun market_state_id<AssetType, StableType>(proposal: &Proposal<AssetType, StableType>): ID {
    assert!(proposal.market_state_id.is_some(), EInvalidState);
    *proposal.market_state_id.borrow()
}

public fun get_market_initialized_at<AssetType, StableType>(proposal: &Proposal<AssetType, StableType>): u64 {
    assert!(proposal.market_initialized_at.is_some(), EInvalidState);
    *proposal.market_initialized_at.borrow()
}

public fun outcome_count<AssetType, StableType>(proposal: &Proposal<AssetType, StableType>): u64 {
    proposal.outcome_count
}

public fun proposer<AssetType, StableType>(proposal: &Proposal<AssetType, StableType>): address {
    proposal.proposer
}

public fun created_at<AssetType, StableType>(proposal: &Proposal<AssetType, StableType>): u64 {
    proposal.created_at
}

public fun get_details<AssetType, StableType>(proposal: &Proposal<AssetType, StableType>): &vector<String> {
    &proposal.details
}

public fun get_metadata<AssetType, StableType>(
    proposal: &Proposal<AssetType, StableType>,
): &String {
    &proposal.metadata
}

public fun get_amm_pool_ids<AssetType, StableType>(
    proposal: &Proposal<AssetType, StableType>,
): vector<ID> {
    let mut ids = vector[];
    let mut i = 0;
    let pools = proposal.amm_pools.borrow();
    let len = pools.length();
    while (i < len) {
        let pool = &pools[i];
        ids.push_back(pool.get_id());
        i = i + 1;
    };
    ids
}

public(package) fun get_pool_mut_by_outcome<AssetType, StableType>(
    proposal: &mut Proposal<AssetType, StableType>,
    outcome_idx: u8,
): &mut LiquidityPool {
    assert!((outcome_idx as u64) < proposal.outcome_count, EOutcomeOutOfBounds);
    let pools_mut = proposal.amm_pools.borrow_mut();
    get_pool_mut(pools_mut, outcome_idx)
}

#[test_only]
public fun get_pool_by_outcome<AssetType, StableType>(
    proposal: &Proposal<AssetType, StableType>,
    outcome_idx: u8,
): &LiquidityPool {
    assert!((outcome_idx as u64) < proposal.outcome_count, EOutcomeOutOfBounds);
    let pools = proposal.amm_pools.borrow();
    let mut i = 0;
    let len = pools.length();
    while (i < len) {
        let pool = &pools[i];
        if (pool.get_outcome_idx() == outcome_idx) {
            return pool
        };
        i = i + 1;
    };
    abort EPoolNotFound
}

// LP caps no longer needed - using conditional tokens for LP

// Pool and LP cap getter no longer needed - using conditional tokens for LP

public fun get_state<AssetType, StableType>(proposal: &Proposal<AssetType, StableType>): u8 {
    proposal.state
}

public fun get_dao_id<AssetType, StableType>(proposal: &Proposal<AssetType, StableType>): ID {
    proposal.dao_id
}

public fun proposal_id<AssetType, StableType>(proposal: &Proposal<AssetType, StableType>): ID {
    proposal.id.to_inner()
}

public fun get_amm_pools<AssetType, StableType>(
    proposal: &Proposal<AssetType, StableType>,
): &vector<LiquidityPool> {
    proposal.amm_pools.borrow()
}

public(package) fun get_amm_pools_mut<AssetType, StableType>(
    proposal: &mut Proposal<AssetType, StableType>,
): &mut vector<LiquidityPool> {
    proposal.amm_pools.borrow_mut()
}

public fun get_created_at<AssetType, StableType>(proposal: &Proposal<AssetType, StableType>): u64 {
    proposal.created_at
}

public fun get_review_period_ms<AssetType, StableType>(
    proposal: &Proposal<AssetType, StableType>,
): u64 {
    proposal.review_period_ms
}

public fun get_trading_period_ms<AssetType, StableType>(
    proposal: &Proposal<AssetType, StableType>,
): u64 {
    proposal.trading_period_ms
}

public fun get_twap_threshold<AssetType, StableType>(
    proposal: &Proposal<AssetType, StableType>,
): u64 {
    proposal.twap_threshold
}

public fun get_twap_start_delay<AssetType, StableType>(proposal: &Proposal<AssetType, StableType>): u64 {
    proposal.twap_start_delay
}

public fun get_twap_initial_observation<AssetType, StableType>(proposal: &Proposal<AssetType, StableType>): u128 {
    proposal.twap_initial_observation
}

public fun get_twap_step_max<AssetType, StableType>(proposal: &Proposal<AssetType, StableType>): u64 {
    proposal.twap_step_max
}

public fun uses_dao_liquidity<AssetType, StableType>(proposal: &Proposal<AssetType, StableType>): bool {
    proposal.uses_dao_liquidity
}

public fun get_amm_total_fee_bps<AssetType, StableType>(
    proposal: &Proposal<AssetType, StableType>,
): u64 {
    proposal.amm_total_fee_bps
}


/// Returns the parameters needed to initialize the market after the premarket phase.
public(package) fun get_market_init_params<AssetType, StableType>(proposal: &Proposal<AssetType, StableType>): (u64, &vector<String>, &vector<u64>, &vector<u64>) {
    (
        proposal.outcome_count,
        &proposal.outcome_messages,
        &proposal.asset_amounts,
        &proposal.stable_amounts,
    )
}

// === Package Functions ===

/// Advances the proposal state based on elapsed time
/// Transitions from REVIEW to TRADING when review period ends
/// Returns true if state was changed
public fun advance_state<AssetType, StableType>(
    proposal: &mut Proposal<AssetType, StableType>,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    clock: &Clock,
): bool {
    let current_time = clock.timestamp_ms();
    // Use market_initialized_at for timing calculations instead of created_at
    // This ensures premarket proposals get proper review/trading periods after initialization
    let base_timestamp = if (proposal.market_initialized_at.is_some()) {
        *proposal.market_initialized_at.borrow()
    } else {
        // Fallback to created_at if market not initialized (shouldn't happen in normal flow)
        proposal.created_at
    };
    
    // Check if we should transition from REVIEW to TRADING
    if (proposal.state == STATE_REVIEW) {
        let review_end = base_timestamp + proposal.review_period_ms;
        if (current_time >= review_end) {
            proposal.state = STATE_TRADING;
            
            // Start trading in the market state
            let market = coin_escrow::get_market_state_mut(escrow);
            market_state::start_trading(market, proposal.trading_period_ms, clock);
            
            // Set oracle start time for all pools when trading begins
            let pools = proposal.amm_pools.borrow_mut();
            let mut i = 0;
            while (i < pools.length()) {
                let pool = &mut pools[i];
                conditional_amm::set_oracle_start_time(pool, market);
                i = i + 1;
            };
            
            return true
        };
    };
    
    // Check if we should transition from TRADING to ended
    if (proposal.state == STATE_TRADING) {
        let trading_end = base_timestamp + proposal.review_period_ms + proposal.trading_period_ms;
        if (current_time >= trading_end) {
            // End trading in the market state
            let market = coin_escrow::get_market_state_mut(escrow);
            if (market_state::is_trading_active(market)) {
                market_state::end_trading(market, clock);
            };
            // Note: Full finalization requires calculating winner and is done separately
            return true
        };
    };
    
    false
}

public(package) fun set_state<AssetType, StableType>(
    proposal: &mut Proposal<AssetType, StableType>,
    new_state: u8,
) {
    proposal.state = new_state;
}

public(package) fun set_twap_prices<AssetType, StableType>(
    proposal: &mut Proposal<AssetType, StableType>,
    twap_prices: vector<u128>,
) {
    proposal.twap_prices = twap_prices;
}

public(package) fun set_last_twap_update<AssetType, StableType>(
    proposal: &mut Proposal<AssetType, StableType>,
    timestamp: u64,
) {
    proposal.last_twap_update = timestamp;
}

public(package) fun set_winning_outcome<AssetType, StableType>(
    proposal: &mut Proposal<AssetType, StableType>,
    outcome: u64,
) {
    proposal.winning_outcome = option::some(outcome);
}

/// Finalize the proposal with the winning outcome computed on-chain
/// This combines computing the winner from TWAP, setting the winning outcome and updating state atomically
public fun finalize_proposal<AssetType, StableType>(
    proposal: &mut Proposal<AssetType, StableType>,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    clock: &Clock,
) {
    // Ensure we're in a state that can be finalized
    assert!(proposal.state == STATE_TRADING || proposal.state == STATE_REVIEW, EInvalidState);
    
    // If still in trading, end trading first
    if (proposal.state == STATE_TRADING) {
        let market = coin_escrow::get_market_state_mut(escrow);
        if (market_state::is_trading_active(market)) {
            market_state::end_trading(market, clock);
        };
    };
    
    // Critical fix: Compute the winning outcome on-chain from TWAP prices
    // Get TWAP prices from all pools
    let twap_prices = get_twaps_for_proposal(proposal, clock);
    
    // For a simple YES/NO proposal, compare the YES TWAP to the threshold
    let winning_outcome = if (twap_prices.length() >= 2) {
        let yes_twap = *twap_prices.borrow(OUTCOME_ACCEPTED);
        let threshold = get_twap_threshold(proposal);
        
        // If YES TWAP exceeds threshold, YES wins
        if (yes_twap > (threshold as u128)) {
            OUTCOME_ACCEPTED
        } else {
            OUTCOME_REJECTED
        }
    } else {
        // For single-outcome or other configs, default to first outcome
        // This should be revisited based on your specific requirements
        0
    };
    
    // Set the winning outcome
    proposal.winning_outcome = option::some(winning_outcome);
    
    // Update state to finalized
    proposal.state = STATE_FINALIZED;
    
    // Finalize the market state
    let market = coin_escrow::get_market_state_mut(escrow);
    market_state::finalize(market, winning_outcome, clock);
}

public fun get_outcome_creators<AssetType, StableType>(proposal: &Proposal<AssetType, StableType>): &vector<address> {
    &proposal.outcome_creators
}

public fun get_liquidity_provider<AssetType, StableType>(proposal: &Proposal<AssetType, StableType>): Option<address> {
    proposal.liquidity_provider
}

public fun get_proposer<AssetType, StableType>(proposal: &Proposal<AssetType, StableType>): address {
    proposal.proposer
}

public fun get_outcome_messages<AssetType, StableType>(proposal: &Proposal<AssetType, StableType>): &vector<String> {
    &proposal.outcome_messages
}

/// Get the intent key for a specific outcome
public fun get_intent_key_for_outcome<AssetType, StableType>(
    proposal: &Proposal<AssetType, StableType>,
    outcome_index: u64
): &Option<String> {
    vector::borrow(&proposal.intent_keys, outcome_index)
}

/// Set the intent key for a specific outcome
public fun set_intent_key_for_outcome<AssetType, StableType>(
    proposal: &mut Proposal<AssetType, StableType>,
    outcome_index: u64,
    intent_key: String,
) {
    // Allow intents for any outcome - each outcome may need different actions
    assert!(outcome_index < proposal.outcome_count, EOutcomeOutOfBounds);
    
    let key_slot = vector::borrow_mut(&mut proposal.intent_keys, outcome_index);
    *key_slot = option::some(intent_key);
}

/// Clear the intent key for a specific outcome (if needed)
public fun clear_intent_key_for_outcome<AssetType, StableType>(
    proposal: &mut Proposal<AssetType, StableType>,
    outcome_index: u64
) {
    assert!(outcome_index < proposal.outcome_count, EOutcomeOutOfBounds);
    
    let key_slot = vector::borrow_mut(&mut proposal.intent_keys, outcome_index);
    *key_slot = option::none();
}

/// Check if an outcome has an intent key
public fun has_intent_key<AssetType, StableType>(
    proposal: &Proposal<AssetType, StableType>,
    outcome_index: u64
): bool {
    assert!(outcome_index < proposal.outcome_count, EOutcomeOutOfBounds);
    option::is_some(vector::borrow(&proposal.intent_keys, outcome_index))
}

/// Emits the ProposalOutcomeMutated event
public(package) fun emit_outcome_mutated(
    proposal_id: ID,
    dao_id: ID,
    outcome_idx: u64,
    old_creator: address,
    new_creator: address,
    timestamp: u64,
) {
    event::emit(ProposalOutcomeMutated {
        proposal_id,
        dao_id,
        outcome_idx,
        old_creator,
        new_creator,
        timestamp,
    });
}

public(package) fun set_outcome_creator<AssetType, StableType>(
    proposal: &mut Proposal<AssetType, StableType>,
    outcome_idx: u64,
    creator: address,
) {
    assert!(outcome_idx < proposal.outcome_count, EOutcomeOutOfBounds);
    let creator_ref = vector::borrow_mut(&mut proposal.outcome_creators, outcome_idx);
    *creator_ref = creator;
}

public(package) fun get_details_mut<AssetType, StableType>(proposal: &mut Proposal<AssetType, StableType>): &mut vector<String> {
    &mut proposal.details
}


// === Test Functions ===

#[test_only]
/// Gets a mutable reference to the token escrow of the proposal
public fun test_get_coin_escrow<AssetType, StableType>(
    escrow: &mut coin_escrow::TokenEscrow<AssetType, StableType>,
): &mut coin_escrow::TokenEscrow<AssetType, StableType> {
    escrow
}

#[test_only]
/// Gets the market state through the token escrow
public fun test_get_market_state<AssetType, StableType>(
    escrow: &coin_escrow::TokenEscrow<AssetType, StableType>,
): &market_state::MarketState {
    escrow.get_market_state()
}


// === Additional View Functions ===

/// Get proposal ID
public fun id<AssetType, StableType>(proposal: &Proposal<AssetType, StableType>): ID {
    object::id(proposal)
}

/// Get market ID (already defined earlier in the file)
