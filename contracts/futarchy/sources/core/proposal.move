module futarchy::proposal;

use futarchy::amm::{Self, LiquidityPool};
use futarchy::coin_escrow;
use futarchy::dao;
use futarchy::liquidity_initialize;
use futarchy::market_state;
use std::ascii::String as AsciiString;
use std::option::{Self, Option};
use std::string::String;
use std::type_name;
use std::vector;
use sui::balance::{Self, Balance};
use sui::clock::Clock;
use sui::coin::{Self, Coin, TreasuryCap};
use sui::event;
use sui::object::{Self, UID, ID};
use sui::transfer;
use sui::tx_context::{Self, TxContext};

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
const STATE_REVIEW: u8 = 1;    // Market is initialized and liquidity is locked, but not yet trading.
// const STATE_TRADING: u8 = 2;   // Market is live and trading. (currently unused)
const STATE_FINALIZED: u8 = 3; // Market has resolved.

// === Structs ===

/// Core proposal object that owns AMM pools
public struct Proposal<phantom AssetType, phantom StableType> has key, store {
    id: UID,
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
    winning_outcome: Option<u64>,
    fee_escrow: Balance<StableType>,
    treasury_address: address,
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
    clock: &Clock,
    ctx: &mut TxContext,
): (ID, ID, u8) {

    let id = object::new(ctx);
    let proposal_id = id.to_inner();
    let outcome_count = initial_outcome_messages.length();

    // Validate outcome count
    assert!(outcome_count == initial_outcome_details.length(), EInvalidOutcomeVectors);

    // Liquidity is split evenly among all outcomes
    let total_asset_liquidity = asset_coin.value();
    let total_stable_liquidity = stable_coin.value();
    assert!(total_asset_liquidity > 0 && total_stable_liquidity > 0, EInvalidAmount);
    
    let asset_per_outcome = total_asset_liquidity / outcome_count;
    let stable_per_outcome = total_stable_liquidity / outcome_count;
    let initial_asset_amounts = vector::tabulate!(outcome_count, |_| asset_per_outcome);
    let initial_stable_amounts = vector::tabulate!(outcome_count, |_| stable_per_outcome);

    // Validate minimum liquidity requirements
    assert!(asset_per_outcome >= min_asset_liquidity, EAssetLiquidityTooLow);
    assert!(stable_per_outcome >= min_stable_liquidity, EStableLiquidityTooLow);

    // Initialize outcome creators to the original proposer
    let outcome_creators = vector::tabulate!(outcome_count, |_| proposer);

    // Create market state
    let market_state = market_state::new(
        proposal_id, 
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
    let asset_balance = asset_coin.into_balance();
    let stable_balance = stable_coin.into_balance();
    
    let (_, amm_pools) = liquidity_initialize::create_outcome_markets(
        &mut escrow, 
        outcome_count, 
        initial_asset_amounts, 
        initial_stable_amounts,
        twap_start_delay, 
        twap_initial_observation, 
        twap_step_max,
        asset_balance, 
        stable_balance, 
        clock, 
        ctx
    );

    // Create proposal object
    let proposal = Proposal<AssetType, StableType> {
        id,
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
        winning_outcome: option::none(),
        fee_escrow,
        treasury_address,
        review_period_ms,
        trading_period_ms,
        twap_prices: vector::empty(),
        last_twap_update: 0,
    };

    event::emit(ProposalCreated {
        proposal_id,
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

    (proposal_id, market_state_id, STATE_REVIEW)
}

#[allow(lint(share_owned))]
public(package) fun create<AssetType, StableType>(
    fee_escrow: Balance<StableType>,
    dao_id: ID,
    review_period_ms: u64,
    trading_period_ms: u64,
    min_asset_liquidity: u64,
    min_stable_liquidity: u64,
    title: String,
    metadata: String,
    // Initial outcome definitions
    initial_outcome_messages: vector<String>,
    initial_outcome_details: vector<String>,
    initial_outcome_asset_amounts: vector<u64>,
    initial_outcome_stable_amounts: vector<u64>,
    // TWAP params
    twap_start_delay: u64,
    twap_initial_observation: u128,
    twap_step_max: u64,
    twap_threshold: u64,
    uses_dao_liquidity: bool,
    treasury_address: address,
    clock: &Clock,
    ctx: &mut TxContext,
): (ID, ID, u8) {
    let sender = tx_context::sender(ctx);
    let id = object::new(ctx);
    let proposal_id = id.to_inner();
    let outcome_count = initial_outcome_messages.length();

    // Validate all vectors have same length
    assert!(outcome_count == initial_outcome_details.length(), EInvalidOutcomeVectors);
    assert!(outcome_count == initial_outcome_asset_amounts.length(), EInvalidOutcomeVectors);
    assert!(outcome_count == initial_outcome_stable_amounts.length(), EInvalidOutcomeVectors);

    // Skip liquidity amount checks if using DAO liquidity, as they are placeholders.
    if (!uses_dao_liquidity) {
        // Validate each outcome's liquidity amounts
        let mut i = 0;
        while (i < outcome_count) {
            let asset_amt = *vector::borrow(&initial_outcome_asset_amounts, i);
            let stable_amt = *vector::borrow(&initial_outcome_stable_amounts, i);
            
            assert!(asset_amt >= min_asset_liquidity, EAssetLiquidityTooLow);
            assert!(stable_amt >= min_stable_liquidity, EStableLiquidityTooLow);
            
            i = i + 1;
        };
    };

    // Initialize all outcome creators to be the original proposer
    let mut outcome_creators = vector::empty();
    let mut i = 0;
    while (i < outcome_count) {
        vector::push_back(&mut outcome_creators, sender);
        i = i + 1;
    };

    let proposal = Proposal<AssetType, StableType> {
        id,
        created_at: clock.timestamp_ms(),
        market_initialized_at: option::none(),
        state: STATE_PREMARKET,
        outcome_count,
        dao_id,
        proposer: sender,
        liquidity_provider: option::none(),
        supply_ids: option::none(),
        amm_pools: option::none(),
        // LP tokens handled as conditional tokens
        escrow_id: option::none(),
        market_state_id: option::none(),
        title,
        details: initial_outcome_details,
        metadata,
        outcome_messages: initial_outcome_messages,
        outcome_creators,
        asset_amounts: initial_outcome_asset_amounts,
        stable_amounts: initial_outcome_stable_amounts,
        twap_prices: vector[],
        last_twap_update: clock.timestamp_ms(),
        review_period_ms,
        trading_period_ms,
        min_asset_liquidity,
        min_stable_liquidity,
        twap_start_delay,
        uses_dao_liquidity,
        twap_initial_observation,
        twap_step_max,
        twap_threshold,
        winning_outcome: option::none(),
        fee_escrow,
        treasury_address,
    };

    event::emit(ProposalCreated {
        proposal_id,
        dao_id,
        proposer: sender,
        outcome_count,
        outcome_messages: initial_outcome_messages,
        created_at: proposal.created_at,
        asset_type: type_name::get<AssetType>().into_string(),
        stable_type: type_name::get<StableType>().into_string(),
        review_period_ms: proposal.review_period_ms,
        trading_period_ms,
        title,
        metadata,
    });

    let state = proposal.state;

    transfer::public_share_object(proposal);

    // Return a dummy market state ID as it doesn't exist yet.
    (proposal_id, object::id_from_address(@0x0), state)
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
    proposal.state = STATE_REVIEW; // Advance state
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
