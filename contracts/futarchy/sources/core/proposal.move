module futarchy::proposal;

use futarchy::amm::{Self, LiquidityPool};
use futarchy::coin_escrow;
use futarchy::liquidity_initialize;
use futarchy::market_state;
use futarchy::oracle;
use std::ascii::String as AsciiString;
use std::string::String;
use std::type_name;
use sui::balance::{Self, Balance};
use sui::clock::{Self, Clock};
use sui::event;

// === Introduction ===
// This defines the core proposal logic and details

// === Errors ===
const EINVALID_POOL_LENGTH: u64 = 0;
const EINVALID_AMOUNT: u64 = 1;
const EINVALID_STATE: u64 = 2;
const EINVALID_LIQUIDITY: u64 = 3;
const EASSET_LIQUIDITY_TOO_LOW: u64 = 4;
const ESTABLE_LIQUIDITY_TOO_LOW: u64 = 5;
const EPOOL_NOT_FOUND: u64 = 6;
const EOUTCOME_OUT_OF_BOUNDS: u64 = 7;

// === Constants ===
const STATE_REVIEW: u8 = 0;
const STATE_TRADING: u8 = 1;
const STATE_FINALIZED: u8 = 2;

// === Structs ===
// Core proposal object that owns AMM pools
public struct Proposal<phantom AssetType, phantom StableType> has key, store {
    id: UID,
    created_at: u64,
    state: u8,
    outcome_count: u64,
    dao_id: ID,
    proposer: address,
    supply_ids: vector<ID>,
    amm_pools: vector<LiquidityPool>, // Now owns the pools directly
    escrow_id: ID,
    market_state_id: ID,
    title: String, // New field
    details: String, // Renamed from description
    metadata: String,
    outcome_messages: vector<String>,
    twap_prices: vector<u128>, // Historical TWAP prices
    last_twap_update: u64, // Last TWAP update timestamp,
    review_period_ms: u64, // Review period in milliseconds
    trading_period_ms: u64, // Trading period in milliseconds
    min_asset_liquidity: u64, // Minimum asset liquidity required
    min_stable_liquidity: u64, // Minimum stable liquidity
    twap_threshold: u64,
    winning_outcome: Option<u64>,
}

// === Constants ===
public struct ProposalCreated has copy, drop {
    proposal_id: ID,
    dao_id: ID,
    proposer: address,
    outcome_count: u64,
    outcome_messages: vector<String>,
    created_at: u64,
    market_state_id: ID,
    escrow_id: ID,
    asset_value: u64,
    stable_value: u64,
    asset_type: AsciiString,
    stable_type: AsciiString,
    review_period_ms: u64,
    trading_period_ms: u64,
    title: String,
    details: String,
    metadata: String,
    initial_outcome_amounts: Option<vector<u64>>,
    twap_start_delay: u64,
    twap_initial_observation: u128,
    twap_step_max: u64,
    twap_threshold: u64,
    oracle_ids: vector<ID>, // NEW: List of oracle IDs for each outcome
}

// === Public Functions ===
#[allow(lint(share_owned))]
public(package) fun create<AssetType, StableType>(
    dao_id: ID,
    outcome_count: u64,
    initial_asset: Balance<AssetType>,
    initial_stable: Balance<StableType>,
    review_period_ms: u64,
    trading_period_ms: u64,
    min_asset_liquidity: u64,
    min_stable_liquidity: u64,
    title: String,
    details: String,
    metadata: String,
    outcome_messages: vector<String>,
    twap_start_delay: u64,
    twap_initial_observation: u128,
    twap_step_max: u64,
    initial_outcome_amounts: Option<vector<u64>>,
    twap_threshold: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): (ID, ID, u8) {
    // Return proposal_id, market_state_id, and state
    let asset_value = balance::value(&initial_asset);
    let stable_value = balance::value(&initial_stable);

    assert!(asset_value >= min_asset_liquidity, EASSET_LIQUIDITY_TOO_LOW);
    assert!(stable_value >= min_stable_liquidity, ESTABLE_LIQUIDITY_TOO_LOW);

    let (asset_amounts, stable_amounts) = if (option::is_some(&initial_outcome_amounts)) {
        let amounts = option::destroy_some(initial_outcome_amounts);
        assert!(vector::length(&amounts) == outcome_count * 2, EINVALID_POOL_LENGTH);

        let mut asset_amounts = vector::empty();
        let mut stable_amounts = vector::empty();
        let mut max_asset = 0;
        let mut max_stable = 0;

        let mut i = 0;
        while (i < outcome_count) {
            let asset_amt = *vector::borrow(&amounts, i * 2);
            let stable_amt = *vector::borrow(&amounts, i * 2 + 1);

            assert!(asset_amt >= min_asset_liquidity, EINVALID_AMOUNT);
            assert!(stable_amt >= min_stable_liquidity, EINVALID_AMOUNT);

            // Track maximum amounts for each type to validate against deposits
            if (asset_amt > max_asset) {
                max_asset = asset_amt;
            };
            if (stable_amt > max_stable) {
                max_stable = stable_amt;
            };

            vector::push_back(&mut asset_amounts, asset_amt);
            vector::push_back(&mut stable_amounts, stable_amt);
            i = i + 1;
        };

        assert!(max_asset == asset_value, EINVALID_LIQUIDITY);
        assert!(max_stable == stable_value, EINVALID_LIQUIDITY);

        (asset_amounts, stable_amounts)
    } else {
        // Default to equal distribution if no initial amounts specified
        let mut asset_amounts = vector::empty();
        let mut stable_amounts = vector::empty();
        let mut i = 0;
        while (i < outcome_count) {
            vector::push_back(&mut asset_amounts, asset_value);
            vector::push_back(&mut stable_amounts, stable_value);
            i = i + 1;
        };
        (asset_amounts, stable_amounts)
    };

    let sender = tx_context::sender(ctx);
    let id = object::new(ctx);
    let proposal_id = object::uid_to_inner(&id);

    // Create market state with correct parameters
    let market_state = market_state::new(
        proposal_id, // market_id
        dao_id, // dao_id
        outcome_count,
        outcome_messages,
        clock,
        ctx,
    );
    let market_state_id = object::id(&market_state);

    // Create escrow with market state
    let mut escrow = coin_escrow::new<AssetType, StableType>(
        market_state,
        ctx,
    );

    let escrow_id = object::id(&escrow);

    let escrow_market_state_id = coin_escrow::get_market_state_id(&escrow);
    assert!(escrow_market_state_id == market_state_id, EINVALID_STATE);

    // Initialize supplies and AMM pools
    let (supply_ids, amm_pools) = liquidity_initialize::create_outcome_markets(
        &mut escrow,
        outcome_count,
        asset_amounts,
        stable_amounts,
        twap_start_delay,
        twap_initial_observation,
        twap_step_max,
        clock::timestamp_ms(clock),
        initial_asset,
        initial_stable,
        clock,
        ctx,
    );

    let proposal = Proposal<AssetType, StableType> {
        id,
        created_at: clock::timestamp_ms(clock),
        state: STATE_REVIEW,
        outcome_count,
        dao_id,
        proposer: sender,
        supply_ids,
        amm_pools,
        escrow_id,
        market_state_id,
        title,
        details,
        metadata,
        outcome_messages,
        twap_prices: vector::empty(),
        last_twap_update: clock::timestamp_ms(clock),
        review_period_ms,
        trading_period_ms,
        min_asset_liquidity,
        min_stable_liquidity,
        twap_threshold,
        winning_outcome: option::none(),
    };

    // Build oracle_ids vector from each liquidity pool's oracle.
    let amm_pools_ref = &proposal.amm_pools; // Create a reference to the proposal's amm_pools
    let mut oracle_ids = vector::empty<ID>();
    let mut i = 0;
    while (i < vector::length(amm_pools_ref)) {
        let pool = vector::borrow(amm_pools_ref, i);
        let oracle_ref = amm::get_oracle(pool);
        let oracle_uid_ref = oracle::get_id(oracle_ref);
        let oracle_id = object::uid_to_inner(oracle_uid_ref);
        vector::push_back(&mut oracle_ids, oracle_id);
        i = i + 1;
    };

    event::emit(ProposalCreated {
        proposal_id,
        dao_id,
        proposer: sender,
        outcome_count,
        outcome_messages,
        created_at: proposal.created_at,
        escrow_id: escrow_id,
        market_state_id: market_state_id,
        asset_value: asset_value,
        stable_value: stable_value,
        asset_type: type_name::into_string(type_name::get<AssetType>()),
        stable_type: type_name::into_string(type_name::get<StableType>()),
        review_period_ms: review_period_ms,
        trading_period_ms: trading_period_ms,
        title, // New field
        details, // Renamed from description
        metadata,
        initial_outcome_amounts,
        twap_start_delay,
        twap_initial_observation,
        twap_step_max,
        twap_threshold,
        oracle_ids,
    });

    let state = proposal.state;

    // Share escrow object
    transfer::public_share_object(escrow);

    transfer::public_share_object(proposal);

    (proposal_id, market_state_id, state)
}

/// Searches the proposal's liquidity pools for an oracle matching the target ID.
/// Returns a reference to that oracle; aborts if not found.
public fun get_twaps_for_proposal<AssetType, StableType>(
    proposal: &mut Proposal<AssetType, StableType>,
    clock: &Clock,
): vector<u128> {
    let pools = &mut proposal.amm_pools;
    let mut twaps = vector::empty<u128>();
    let mut i = 0;
    while (i < vector::length(pools)) {
        let pool = vector::borrow_mut(pools, i);
        let twap = amm::get_twap(pool, clock);
        vector::push_back(&mut twaps, twap);
        i = i + 1;
    };
    twaps
}

// ====== Internal Helpers ======
fun get_pool_mut(pools: &mut vector<LiquidityPool>, outcome_idx: u8): &mut LiquidityPool {
    let mut i = 0;
    let len = vector::length(pools);
    while (i < len) {
        let pool = vector::borrow_mut(pools, i);
        if (amm::get_outcome_idx(pool) == outcome_idx) {
            return pool
        };
        i = i + 1;
    };
    abort EPOOL_NOT_FOUND
}

// ====== Query Functions ======
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

// ====== Getters ======
public fun state<AssetType, StableType>(proposal: &Proposal<AssetType, StableType>): u8 {
    proposal.state
}

public fun get_winning_outcome<AssetType, StableType>(
    proposal: &Proposal<AssetType, StableType>,
): u64 {
    assert!(option::is_some(&proposal.winning_outcome), EINVALID_STATE);
    *option::borrow(&proposal.winning_outcome)
}

/// Checks if winning outcome has been set
public fun is_winning_outcome_set<AssetType, StableType>(
    proposal: &Proposal<AssetType, StableType>,
): bool {
    option::is_some(&proposal.winning_outcome)
}

public fun get_id<AssetType, StableType>(proposal: &Proposal<AssetType, StableType>): ID {
    object::uid_to_inner(&proposal.id)
}

public fun escrow_id<AssetType, StableType>(proposal: &Proposal<AssetType, StableType>): ID {
    proposal.escrow_id
}

public fun market_state_id<AssetType, StableType>(proposal: &Proposal<AssetType, StableType>): ID {
    proposal.market_state_id
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

public fun get_details<AssetType, StableType>(proposal: &Proposal<AssetType, StableType>): &String {
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
    let mut ids = vector::empty();
    let mut i = 0;
    let len = vector::length(&proposal.amm_pools);
    while (i < len) {
        let pool = vector::borrow(&proposal.amm_pools, i);
        vector::push_back(&mut ids, amm::get_id(pool));
        i = i + 1;
    };
    ids
}

public(package) fun get_pool_mut_by_outcome<AssetType, StableType>(
    proposal: &mut Proposal<AssetType, StableType>,
    outcome_idx: u8,
): &mut LiquidityPool {
    assert!((outcome_idx as u64) < proposal.outcome_count, EOUTCOME_OUT_OF_BOUNDS);
    get_pool_mut(&mut proposal.amm_pools, outcome_idx)
}

public fun get_state<AssetType, StableType>(proposal: &Proposal<AssetType, StableType>): u8 {
    proposal.state
}

public fun get_dao_id<AssetType, StableType>(proposal: &Proposal<AssetType, StableType>): ID {
    proposal.dao_id
}

public fun proposal_id<AssetType, StableType>(proposal: &Proposal<AssetType, StableType>): ID {
    object::uid_to_inner(&proposal.id)
}

public fun get_amm_pools<AssetType, StableType>(
    proposal: &Proposal<AssetType, StableType>,
): &vector<LiquidityPool> {
    &proposal.amm_pools
}

public(package) fun get_amm_pools_mut<AssetType, StableType>(
    proposal: &mut Proposal<AssetType, StableType>,
): &mut vector<LiquidityPool> {
    &mut proposal.amm_pools
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

// Mutator functions
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

// === Test Functions ===
#[test_only]
/// Gets a mutable reference to the token escrow of the proposal
public fun test_get_coin_escrow<AssetType, StableType>(
    escrow: &mut coin_escrow::TokenEscrow<AssetType, StableType>,
): &mut coin_escrow::TokenEscrow<AssetType, StableType> {
    // The function now directly returns the mutable reference passed in.
    escrow
}

#[test_only]
/// Gets the market state through the token escrow
public fun test_get_market_state<AssetType, StableType>(
    escrow: &coin_escrow::TokenEscrow<AssetType, StableType>,
): &market_state::MarketState {
    coin_escrow::get_market_state<AssetType, StableType>(escrow)
}
