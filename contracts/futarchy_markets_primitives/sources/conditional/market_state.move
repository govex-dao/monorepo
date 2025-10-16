module futarchy_markets_primitives::market_state;

use futarchy_markets_primitives::conditional_amm::LiquidityPool;
use futarchy_markets_primitives::price_leaderboard::{Self, PriceLeaderboard};
use std::string::String;
use sui::clock::Clock;
use sui::event;

// === Introduction ===
// This module tracks proposal life cycle and acts as a source of truth for proposal state

// === Errors ===
const ETradingAlreadyStarted: u64 = 0;
const EOutcomeOutOfBounds: u64 = 1;
const EAlreadyFinalized: u64 = 2;
const ETradingAlreadyEnded: u64 = 3;
const ETradingNotEnded: u64 = 4;
const ENotFinalized: u64 = 5;
const ETradingNotStarted: u64 = 6;
const EInvalidDuration: u64 = 7;

// === Constants ===
const MAX_TRADING_DURATION_MS: u64 = 30 * 24 * 60 * 60 * 1000; // 30 days

// === Structs ===
public struct MarketStatus has copy, drop, store {
    trading_started: bool,
    trading_ended: bool,
    finalized: bool,
}

/// Records a single flip event for analysis
public struct FlipEvent has copy, drop, store {
    timestamp_ms: u64,
    old_winner: u64,
    new_winner: u64,
    instant_price_spread: u128, // Spread at flip time (for analysis)
}

/// Early resolution metrics for tracking proposal stability
/// Tracks flip history across ALL N markets
public struct EarlyResolveMetrics has copy, drop, store {
    current_winner_index: u64, // Which outcome is currently winning
    last_flip_time_ms: u64, // When did winner last change
    recent_flips: vector<FlipEvent>, // Last N flips (for window-based checks)
}

public struct MarketState has key, store {
    id: UID,
    market_id: ID,
    dao_id: ID,
    outcome_count: u64,
    outcome_messages: vector<String>,
    // Market infrastructure - AMM pools for price discovery
    amm_pools: Option<vector<LiquidityPool>>,
    // Lifecycle state
    status: MarketStatus,
    winning_outcome: Option<u64>,
    creation_time: u64,
    trading_start: u64,
    trading_end: Option<u64>,
    finalization_time: Option<u64>,
    // Early resolution metrics (optional)
    early_resolve_metrics: Option<EarlyResolveMetrics>,
    // Price leaderboard cache for O(1) winner lookups and O(log N) updates
    // Initialized lazily on first swap (after init actions complete)
    price_leaderboard: Option<PriceLeaderboard>,
}

// === Events ===
public struct TradingStartedEvent has copy, drop {
    market_id: ID,
    start_time: u64,
}

public struct TradingEndedEvent has copy, drop {
    market_id: ID,
    timestamp_ms: u64,
}

public struct MarketStateFinalizedEvent has copy, drop {
    market_id: ID,
    winning_outcome: u64,
    timestamp_ms: u64,
}

// === Public Package Functions ===
public fun new(
    market_id: ID,
    dao_id: ID,
    outcome_count: u64,
    outcome_messages: vector<String>,
    clock: &Clock,
    ctx: &mut TxContext,
): MarketState {
    let timestamp = clock.timestamp_ms();

    MarketState {
        id: object::new(ctx),
        market_id,
        dao_id,
        outcome_count,
        outcome_messages,
        amm_pools: option::none(), // Pools added later during market initialization
        status: MarketStatus {
            trading_started: false,
            trading_ended: false,
            finalized: false,
        },
        winning_outcome: option::none(),
        creation_time: timestamp,
        trading_start: 0,
        trading_end: option::none(),
        finalization_time: option::none(),
        early_resolve_metrics: option::none(), // Initialized when trading starts
        price_leaderboard: option::none(), // Initialized lazily on first swap (after init actions)
    }
}

public fun start_trading(state: &mut MarketState, duration_ms: u64, clock: &Clock) {
    assert!(!state.status.trading_started, ETradingAlreadyStarted);
    assert!(duration_ms > 0 && duration_ms <= MAX_TRADING_DURATION_MS, EInvalidDuration);

    let start_time = clock.timestamp_ms();
    let end_time = start_time + duration_ms;

    state.status.trading_started = true;
    state.trading_start = start_time;
    state.trading_end = option::some(end_time);

    event::emit(TradingStartedEvent {
        market_id: state.market_id,
        start_time,
    });
}

// === Public Functions ===
public fun assert_trading_active(state: &MarketState) {
    assert!(state.status.trading_started, ETradingNotStarted);
    assert!(!state.status.trading_ended, ETradingAlreadyEnded);
}

public fun assert_in_trading_or_pre_trading(state: &MarketState) {
    assert!(!state.status.trading_ended, ETradingAlreadyEnded);
    assert!(!state.status.finalized, EAlreadyFinalized);
}

public fun end_trading(state: &mut MarketState, clock: &Clock) {
    assert!(state.status.trading_started, ETradingNotStarted);
    assert!(!state.status.trading_ended, ETradingAlreadyEnded);

    let timestamp = clock.timestamp_ms();
    state.status.trading_ended = true;

    event::emit(TradingEndedEvent {
        market_id: state.market_id,
        timestamp_ms: timestamp,
    });
}

public fun finalize(state: &mut MarketState, winner: u64, clock: &Clock) {
    assert!(state.status.trading_ended, ETradingNotEnded);
    assert!(!state.status.finalized, EAlreadyFinalized);
    assert!(winner < state.outcome_count, EOutcomeOutOfBounds);

    let timestamp = clock.timestamp_ms();
    state.status.finalized = true;
    state.winning_outcome = option::some(winner);
    state.finalization_time = option::some(timestamp);

    event::emit(MarketStateFinalizedEvent {
        market_id: state.market_id,
        winning_outcome: winner,
        timestamp_ms: timestamp,
    });
}

// === Pool Management Functions ===

/// Initialize AMM pools for the market
/// Called once when market transitions to TRADING state
public fun set_amm_pools(state: &mut MarketState, pools: vector<LiquidityPool>) {
    assert!(state.amm_pools.is_none(), 0); // Pools can only be set once
    option::fill(&mut state.amm_pools, pools);
}

/// Check if market has AMM pools initialized
public fun has_amm_pools(state: &MarketState): bool {
    state.amm_pools.is_some()
}

/// Borrow AMM pools immutably
public fun borrow_amm_pools(state: &MarketState): &vector<LiquidityPool> {
    state.amm_pools.borrow()
}

/// Borrow AMM pools mutably
public fun borrow_amm_pools_mut(state: &mut MarketState): &mut vector<LiquidityPool> {
    state.amm_pools.borrow_mut()
}

/// Get a specific pool by outcome index
public fun get_pool_by_outcome(state: &MarketState, outcome_idx: u8): &LiquidityPool {
    let pools = state.amm_pools.borrow();
    &pools[(outcome_idx as u64)]
}

/// Get a specific pool mutably by outcome index
public fun get_pool_mut_by_outcome(state: &mut MarketState, outcome_idx: u8): &mut LiquidityPool {
    let pools = state.amm_pools.borrow_mut();
    &mut pools[(outcome_idx as u64)]
}

/// Get all pools (for cleanup/migration)
public(package) fun extract_amm_pools(state: &mut MarketState): vector<LiquidityPool> {
    state.amm_pools.extract()
}

// === Assertion Functions ===
public fun assert_market_finalized(state: &MarketState) {
    assert!(state.status.finalized, ENotFinalized);
}

public fun assert_not_finalized(state: &MarketState) {
    assert!(!state.status.finalized, EAlreadyFinalized);
}

public fun validate_outcome(state: &MarketState, outcome: u64) {
    assert!(outcome < state.outcome_count, EOutcomeOutOfBounds);
}

// === View Functions (Getters) ===
public fun market_id(state: &MarketState): ID {
    state.market_id
}

public fun outcome_count(state: &MarketState): u64 {
    state.outcome_count
}

// === View Functions (Predicates) ===
public fun is_trading_active(state: &MarketState): bool {
    state.status.trading_started && !state.status.trading_ended
}

public fun is_finalized(state: &MarketState): bool {
    state.status.finalized
}

public fun dao_id(state: &MarketState): ID {
    state.dao_id
}

public fun get_winning_outcome(state: &MarketState): u64 {
    use std::option;
    assert!(state.status.finalized, ENotFinalized);
    let opt_ref = &state.winning_outcome;
    assert!(option::is_some(opt_ref), ENotFinalized);
    *option::borrow(opt_ref)
}

public fun get_outcome_message(state: &MarketState, outcome_idx: u64): String {
    assert!(outcome_idx < state.outcome_count, EOutcomeOutOfBounds);
    state.outcome_messages[outcome_idx]
}

public fun get_creation_time(state: &MarketState): u64 {
    state.creation_time
}

public fun get_trading_end_time(state: &MarketState): Option<u64> {
    state.trading_end
}

public fun get_trading_start(state: &MarketState): u64 {
    state.trading_start
}

public fun get_finalization_time(state: &MarketState): Option<u64> {
    state.finalization_time
}

// === Early Resolve Metrics Functions ===

/// Create a new EarlyResolveMetrics struct (helper for initialization)
public fun new_early_resolve_metrics(
    initial_winner_index: u64,
    current_time_ms: u64,
): EarlyResolveMetrics {
    EarlyResolveMetrics {
        current_winner_index: initial_winner_index,
        last_flip_time_ms: current_time_ms,
        recent_flips: vector::empty(), // Start with no flip history
    }
}

/// Check if early resolve metrics are initialized
public fun has_early_resolve_metrics(state: &MarketState): bool {
    state.early_resolve_metrics.is_some()
}

/// Initialize early resolve metrics when proposal starts
public(package) fun init_early_resolve_metrics(
    state: &mut MarketState,
    initial_winner_index: u64,
    current_time_ms: u64,
) {
    assert!(state.early_resolve_metrics.is_none(), 0); // Can only init once
    let metrics = EarlyResolveMetrics {
        current_winner_index: initial_winner_index,
        last_flip_time_ms: current_time_ms,
        recent_flips: vector::empty(),
    };
    option::fill(&mut state.early_resolve_metrics, metrics);
}

/// Borrow early resolve metrics immutably
public fun borrow_early_resolve_metrics(state: &MarketState): &EarlyResolveMetrics {
    state.early_resolve_metrics.borrow()
}

/// Borrow early resolve metrics mutably
public(package) fun borrow_early_resolve_metrics_mut(
    state: &mut MarketState,
): &mut EarlyResolveMetrics {
    state.early_resolve_metrics.borrow_mut()
}

/// Get current winner index from metrics
public fun get_current_winner_index(state: &MarketState): u64 {
    let metrics = state.early_resolve_metrics.borrow();
    metrics.current_winner_index
}

/// Get last flip time from metrics
public fun get_last_flip_time_ms(state: &MarketState): u64 {
    let metrics = state.early_resolve_metrics.borrow();
    metrics.last_flip_time_ms
}

/// Update metrics when winner changes (called by early_resolve module)
/// Records the flip event and updates current winner
public fun update_winner_metrics(
    state: &mut MarketState,
    new_winner_index: u64,
    current_time_ms: u64,
    instant_price_spread: u128, // Spread at time of flip
) {
    let metrics = state.early_resolve_metrics.borrow_mut();

    // Record the flip event
    let flip_event = FlipEvent {
        timestamp_ms: current_time_ms,
        old_winner: metrics.current_winner_index,
        new_winner: new_winner_index,
        instant_price_spread,
    };

    // Add to flip history (keep last 100 for memory efficiency)
    vector::push_back(&mut metrics.recent_flips, flip_event);
    if (vector::length(&metrics.recent_flips) > 100) {
        vector::remove(&mut metrics.recent_flips, 0); // Remove oldest
    };

    // Update current state
    metrics.current_winner_index = new_winner_index;
    metrics.last_flip_time_ms = current_time_ms;
}

/// Get flip history for analysis
public fun get_flip_history(state: &MarketState): &vector<FlipEvent> {
    let metrics = state.early_resolve_metrics.borrow();
    &metrics.recent_flips
}

/// Count flips within a time window
/// Returns number of flips that occurred after cutoff_time_ms
public fun count_flips_in_window(state: &MarketState, cutoff_time_ms: u64): u64 {
    let metrics = state.early_resolve_metrics.borrow();
    let flips = &metrics.recent_flips;
    let mut count = 0u64;
    let mut i = 0u64;

    while (i < vector::length(flips)) {
        let flip = vector::borrow(flips, i);
        if (flip.timestamp_ms >= cutoff_time_ms) {
            count = count + 1;
        };
        i = i + 1;
    };

    count
}

// === Price Leaderboard Functions ===

/// Check if price leaderboard is initialized
public fun has_price_leaderboard(state: &MarketState): bool {
    state.price_leaderboard.is_some()
}

/// Initialize price leaderboard from current pool prices
/// Called lazily on first swap (after init actions complete)
/// Complexity: O(N) using Floyd's heapify algorithm
public fun init_price_leaderboard(state: &mut MarketState, ctx: &mut TxContext) {
    assert!(state.price_leaderboard.is_none(), 0); // Can only init once
    assert!(state.amm_pools.is_some(), 1); // Need pools to get prices

    // Extract prices from all pools
    let pools = state.amm_pools.borrow();
    let n = pools.length();
    let mut prices = vector::empty<u128>();

    let mut i = 0u64;
    while (i < n) {
        let pool = &pools[i];
        let price = futarchy_markets_primitives::conditional_amm::get_current_price(pool);
        vector::push_back(&mut prices, price);
        i = i + 1;
    };

    // Create leaderboard from prices
    let leaderboard = price_leaderboard::init_from_prices(prices, ctx);
    option::fill(&mut state.price_leaderboard, leaderboard);
}

/// Update price for an outcome in the leaderboard
/// Called after each swap to maintain O(log N) performance
/// Complexity: O(log N)
public fun update_price_in_leaderboard(
    state: &mut MarketState,
    outcome_index: u64,
    new_price: u128,
) {
    let leaderboard = state.price_leaderboard.borrow_mut();
    price_leaderboard::update_price(leaderboard, outcome_index, new_price);
}

/// Get winner and spread from leaderboard
/// Returns (winner_index, winner_price, spread)
/// Complexity: O(1)
public fun get_winner_from_leaderboard(state: &MarketState): (u64, u128, u128) {
    let leaderboard = state.price_leaderboard.borrow();
    price_leaderboard::get_winner_and_spread(leaderboard)
}

/// Destroy price leaderboard and clean up table resources
/// Called during market cleanup, dissolution, or migration
/// Safe to call even if leaderboard not initialized
public fun destroy_price_leaderboard(state: &mut MarketState) {
    if (state.price_leaderboard.is_some()) {
        let leaderboard = state.price_leaderboard.extract();
        price_leaderboard::destroy(leaderboard);
    };
}

// === Test Functions ===
#[test_only]
public fun create_for_testing(outcomes: u64, ctx: &mut TxContext): MarketState {
    let dummy_id = object::new(ctx);
    let market_id = dummy_id.uid_to_inner();
    dummy_id.delete();

    MarketState {
        id: object::new(ctx),
        market_id,
        dao_id: market_id,
        outcome_messages: vector[],
        outcome_count: outcomes,
        amm_pools: option::none(),
        status: MarketStatus {
            trading_started: false,
            trading_ended: false,
            finalized: false,
        },
        winning_outcome: option::none(),
        creation_time: 0,
        trading_start: 0,
        trading_end: option::none(),
        finalization_time: option::none(),
        early_resolve_metrics: option::none(),
        price_leaderboard: option::none(),
    }
}

#[test_only]
public fun init_trading_for_testing(state: &mut MarketState) {
    state.status.trading_started = true;
    state.trading_start = 0;
    state.trading_end = option::some(9999999999999);
}
#[test_only]
public fun reset_state_for_testing(state: &mut MarketState) {
    state.status.trading_started = false;
    state.trading_start = 0;
}

#[test_only]
public fun finalize_for_testing(state: &mut MarketState) {
    state.status.trading_ended = true;
    state.status.finalized = true;
    state.winning_outcome = option::some(0);
    state.finalization_time = option::some(0);
}

#[test_only]
public fun destroy_for_testing(state: MarketState) {
    sui::test_utils::destroy(state);
}

#[test_only]
public fun copy_market_id(state: &MarketState): ID {
    state.market_id
}

#[test_only]
public fun copy_status(state: &MarketState): MarketStatus {
    state.status
}

#[test_only]
public fun copy_winning_outcome(state: &MarketState): Option<u64> {
    state.winning_outcome
}

#[test_only]
public fun test_set_winning_outcome(state: &mut MarketState, outcome: u64) {
    state.winning_outcome = option::some(outcome);
}

#[test_only]
public fun test_set_finalized(state: &mut MarketState) {
    state.status.finalized = true;
    state.status.trading_ended = true;
    state.finalization_time = option::some(0);
}

#[test_only]
/// Test helper to borrow AMM pool mutably by outcome index (u64 instead of u8)
public fun borrow_amm_pool_mut(state: &mut MarketState, outcome_idx: u64): &mut LiquidityPool {
    let pools = state.amm_pools.borrow_mut();
    &mut pools[outcome_idx]
}

#[test_only]
/// Test helper to set early resolve metrics directly (bypasses initialization check)
public fun set_early_resolve_metrics(state: &mut MarketState, metrics: EarlyResolveMetrics) {
    if (state.early_resolve_metrics.is_some()) {
        state.early_resolve_metrics.extract();
    };
    option::fill(&mut state.early_resolve_metrics, metrics);
}

#[test_only]
/// Test helper to destroy early resolve metrics
public fun destroy_early_resolve_metrics_for_testing(state: &mut MarketState) {
    if (state.early_resolve_metrics.is_some()) {
        state.early_resolve_metrics.extract();
    };
}

#[test_only]
/// Test helper to update last flip time directly
public fun update_last_flip_time_for_testing(state: &mut MarketState, time_ms: u64) {
    let metrics = state.early_resolve_metrics.borrow_mut();
    metrics.last_flip_time_ms = time_ms;
}

#[test_only]
/// Test helper to get current winner index
public fun get_current_winner_index_for_testing(state: &MarketState): u64 {
    let metrics = state.early_resolve_metrics.borrow();
    metrics.current_winner_index
}
