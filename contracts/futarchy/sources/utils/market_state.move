module futarchy::market_state;

use std::string::String;
use sui::clock::{Self, Clock};
use sui::event;

// === Introduction ===
// This tracks proposal life cycle and acts a source of truth for proposal state

// ======== Error Constants ========
const ETRADING_ALREADY_STARTED: u64 = 0;
const EOUTCOME_OUT_OF_BOUNDS: u64 = 1;
const EALREADY_FINALIZED: u64 = 2;
const ETRADING_ALREADY_ENDED: u64 = 3;
const ETRADING_NOT_ENDED: u64 = 4;
const ENOT_FINALIZED: u64 = 5;
const ETRADING_NOT_STARTED: u64 = 6;

// === Structs ===
public struct MarketStatus has copy, drop, store {
    trading_started: bool,
    trading_ended: bool,
    finalized: bool,
}

public struct MarketState has key, store {
    id: UID,
    market_id: ID,
    dao_id: ID,
    outcome_count: u64,
    outcome_messages: vector<String>,
    status: MarketStatus,
    winning_outcome: Option<u64>,
    creation_time: u64,
    trading_start: u64,
    trading_end: Option<u64>,
    finalization_time: Option<u64>,
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

// === Public Functions ===
public(package) fun new(
    market_id: ID,
    dao_id: ID,
    outcome_count: u64,
    outcome_messages: vector<String>,
    clock: &Clock,
    ctx: &mut TxContext,
): MarketState {
    let timestamp = clock::timestamp_ms(clock);

    let state = MarketState {
        id: object::new(ctx),
        market_id,
        dao_id,
        outcome_count,
        outcome_messages,
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
    };

    state
}

public(package) fun start_trading(state: &mut MarketState, duration_ms: u64, clock: &Clock) {
    assert!(!state.status.trading_started, ETRADING_ALREADY_STARTED);

    let start_time = clock::timestamp_ms(clock);
    let end_time = start_time + duration_ms;

    state.status.trading_started = true;
    state.trading_start = start_time;
    state.trading_end = option::some(end_time);

    event::emit(TradingStartedEvent {
        market_id: state.market_id,
        start_time,
    });
}

public fun assert_trading_active(state: &MarketState) {
    assert!(state.status.trading_started, ETRADING_NOT_STARTED);
    assert!(!state.status.trading_ended, ETRADING_ALREADY_ENDED);
}

public fun assert_in_trading_or_pre_trading(state: &MarketState) {
    assert!(!state.status.trading_ended, ETRADING_ALREADY_ENDED);
    assert!(!state.status.finalized, EALREADY_FINALIZED);
}

public(package) fun end_trading(state: &mut MarketState, clock: &Clock) {
    assert!(state.status.trading_started, ETRADING_NOT_STARTED);
    assert!(!state.status.trading_ended, ETRADING_ALREADY_ENDED);

    let timestamp = clock::timestamp_ms(clock);
    state.status.trading_ended = true;

    event::emit(TradingEndedEvent {
        market_id: state.market_id,
        timestamp_ms: timestamp,
    });
}

public(package) fun finalize(state: &mut MarketState, winner: u64, clock: &Clock) {
    assert!(state.status.trading_ended, ETRADING_NOT_ENDED);
    assert!(!state.status.finalized, EALREADY_FINALIZED);
    assert!(winner < state.outcome_count, EOUTCOME_OUT_OF_BOUNDS);

    let timestamp = clock::timestamp_ms(clock);
    state.status.finalized = true;
    state.winning_outcome = option::some(winner);
    state.finalization_time = option::some(timestamp);

    event::emit(MarketStateFinalizedEvent {
        market_id: state.market_id,
        winning_outcome: winner,
        timestamp_ms: timestamp,
    });
}

// ======== Validators ========
public fun assert_market_finalized(state: &MarketState) {
    assert!(state.status.finalized, ENOT_FINALIZED);
}

public fun assert_not_finalized(state: &MarketState) {
    assert!(!state.status.finalized, EALREADY_FINALIZED);
}

public fun validate_outcome(state: &MarketState, outcome: u64) {
    assert!(outcome < state.outcome_count, EOUTCOME_OUT_OF_BOUNDS);
}

// ======== Getter Functions ========
public fun market_id(state: &MarketState): ID {
    state.market_id
}

public fun outcome_count(state: &MarketState): u64 {
    state.outcome_count
}

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
    assert!(state.status.finalized, ENOT_FINALIZED);
    *option::borrow(&state.winning_outcome)
}

public fun get_outcome_message(state: &MarketState, outcome_idx: u64): String {
    assert!(outcome_idx < state.outcome_count, EOUTCOME_OUT_OF_BOUNDS);
    *vector::borrow(&state.outcome_messages, outcome_idx)
}

// === Test Functions ===
#[test_only]
public fun create_for_testing(outcomes: u64, ctx: &mut TxContext): MarketState {
    let dummy_id = object::new(ctx);
    let market_id = object::uid_to_inner(&dummy_id);
    object::delete(dummy_id);

    MarketState {
        id: object::new(ctx),
        market_id,
        dao_id: market_id,
        outcome_messages: vector::empty(),
        outcome_count: outcomes,
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
    }
}

#[test_only]
public fun init_trading_for_testing(state: &mut MarketState) {
    state.status.trading_started = true;
    state.trading_start = 0;
    state.trading_end = option::some(9999999999999);
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
    let MarketState {
        id,
        market_id: _,
        outcome_count: _,
        status: _,
        winning_outcome: _,
        creation_time: _,
        trading_start: _,
        trading_end: _,
        finalization_time: _,
        dao_id: _,
        outcome_messages: _,
    } = state;

    object::delete(id);
}
