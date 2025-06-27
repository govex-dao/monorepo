module futarchy::proposal;

use futarchy::amm::LiquidityPool;
use futarchy::coin_escrow;
use futarchy::liquidity_initialize;
use futarchy::market_state;
use futarchy::oracle;
use std::ascii::String as AsciiString;
use std::string::String;
use std::type_name;
use sui::balance::Balance;
use sui::clock::Clock;
use sui::event;

// === Introduction ===
// This defines the core proposal logic and details

// === Errors ===

const EInvalidPoolLength: u64 = 0;
const EInvalidAmount: u64 = 1;
const EInvalidState: u64 = 2;
const EInvalidLiquidity: u64 = 3;
const EAssetLiquidityTooLow: u64 = 4;
const EStableLiquidityTooLow: u64 = 5;
const EPoolNotFound: u64 = 6;
const EOutcomeOutOfBounds: u64 = 7;

// === Constants ===

const STATE_REVIEW: u8 = 0;
const STATE_FINALIZED: u8 = 2;

// === Structs ===

/// Core proposal object that owns AMM pools
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
    title: String,
    details: String,
    metadata: String,
    outcome_messages: vector<String>,
    twap_prices: vector<u128>, // Historical TWAP prices
    last_twap_update: u64,
    review_period_ms: u64,
    trading_period_ms: u64,
    min_asset_liquidity: u64,
    min_stable_liquidity: u64,
    twap_threshold: u64,
    winning_outcome: Option<u64>,
}

// === Events ===

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
    oracle_ids: vector<ID>,
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
    let asset_value = initial_asset.value();
    let stable_value = initial_stable.value();

    assert!(asset_value >= min_asset_liquidity, EAssetLiquidityTooLow);
    assert!(stable_value >= min_stable_liquidity, EStableLiquidityTooLow);

    let (asset_amounts, stable_amounts) = if (initial_outcome_amounts.is_some()) {
        let amounts = initial_outcome_amounts.destroy_some();
        assert!(amounts.length() == outcome_count * 2, EInvalidPoolLength);

        let mut asset_amounts = vector[];
        let mut stable_amounts = vector[];
        let mut max_asset = 0;
        let mut max_stable = 0;

        let mut i = 0;
        while (i < outcome_count) {
            let asset_amt = amounts[i * 2];
            let stable_amt = amounts[i * 2 + 1];

            assert!(asset_amt >= min_asset_liquidity, EInvalidAmount);
            assert!(stable_amt >= min_stable_liquidity, EInvalidAmount);

            // Track maximum amounts for each type to validate against deposits
            if (asset_amt > max_asset) {
                max_asset = asset_amt;
            };
            if (stable_amt > max_stable) {
                max_stable = stable_amt;
            };

            asset_amounts.push_back(asset_amt);
            stable_amounts.push_back(stable_amt);
            i = i + 1;
        };

        assert!(max_asset == asset_value, EInvalidLiquidity);
        assert!(max_stable == stable_value, EInvalidLiquidity);

        (asset_amounts, stable_amounts)
    } else {
        // Default to equal distribution if no initial amounts specified
        let mut asset_amounts = vector[];
        let mut stable_amounts = vector[];
        let mut i = 0;
        while (i < outcome_count) {
            asset_amounts.push_back(asset_value);
            stable_amounts.push_back(stable_value);
            i = i + 1;
        };
        (asset_amounts, stable_amounts)
    };

    let sender = ctx.sender();
    let id = object::new(ctx);
    let proposal_id = id.to_inner();

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

    let escrow_market_state_id = escrow.get_market_state_id();
    assert!(escrow_market_state_id == market_state_id, EInvalidState);

    // Initialize supplies and AMM pools
    let (supply_ids, amm_pools) = liquidity_initialize::create_outcome_markets(
        &mut escrow,
        outcome_count,
        asset_amounts,
        stable_amounts,
        twap_start_delay,
        twap_initial_observation,
        twap_step_max,
        initial_asset,
        initial_stable,
        clock,
        ctx,
    );

    let proposal = Proposal<AssetType, StableType> {
        id,
        created_at: clock.timestamp_ms(),
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
        twap_prices: vector[],
        last_twap_update: clock.timestamp_ms(),
        review_period_ms,
        trading_period_ms,
        min_asset_liquidity,
        min_stable_liquidity,
        twap_threshold,
        winning_outcome: option::none(),
    };

    // Build oracle_ids vector from each liquidity pool's oracle.
    let amm_pools_ref = &proposal.amm_pools;
    let mut oracle_ids = vector[];
    let mut i = 0;
    while (i < amm_pools_ref.length()) {
        let pool = &amm_pools_ref[i];
        let oracle_ref = pool.get_oracle();
        let oracle_uid_ref = oracle::id(oracle_ref);
        let oracle_id = oracle_uid_ref.to_inner();
        oracle_ids.push_back(oracle_id);
        i = i + 1;
    };

    event::emit(ProposalCreated {
        proposal_id,
        dao_id,
        proposer: sender,
        outcome_count,
        outcome_messages,
        created_at: proposal.created_at,
        escrow_id,
        market_state_id,
        asset_value,
        stable_value,
        asset_type: type_name::get<AssetType>().into_string(),
        stable_type: type_name::get<StableType>().into_string(),
        review_period_ms,
        trading_period_ms,
        title,
        details,
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

public fun get_id<AssetType, StableType>(proposal: &Proposal<AssetType, StableType>): ID {
    proposal.id.to_inner()
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
    let mut ids = vector[];
    let mut i = 0;
    let len = proposal.amm_pools.length();
    while (i < len) {
        let pool = &proposal.amm_pools[i];
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
    get_pool_mut(&mut proposal.amm_pools, outcome_idx)
}

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
