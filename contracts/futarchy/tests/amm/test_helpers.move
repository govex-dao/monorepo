#[test_only]
module futarchy::test_helpers;

use futarchy::amm::{Self, LiquidityPool};
use sui::{
    test_scenario::{Self as test, Scenario, ctx},
    coin::{Self, Coin},
    clock::{Self, Clock},
    object::{Self, ID},
};

// Common test addresses
const ADMIN: address = @0xA;
const USER_1: address = @0x1;
const USER_2: address = @0x2;

// Default test values
const DEFAULT_SWAP_FEE: u64 = 30; // 0.3%
const INITIAL_RESERVE: u64 = 1_000_000;

/// Creates a test AMM pool
public fun create_test_pool_with_reserves(
    asset_reserve: u64,
    stable_reserve: u64,
    scenario: &mut Scenario
): LiquidityPool {
    let dummy_market_id = object::id_from_address(ADMIN);
    amm::create_test_pool(
        dummy_market_id,
        0,
        DEFAULT_SWAP_FEE,
        asset_reserve,
        stable_reserve,
        ctx(scenario)
    )
}

/// Creates a standard test pool with default reserves
public fun create_standard_test_pool(scenario: &mut Scenario): LiquidityPool {
    create_test_pool_with_reserves(INITIAL_RESERVE, INITIAL_RESERVE, scenario)
}

/// Helper to create test coins
public fun mint_test_coin<T>(amount: u64, scenario: &mut Scenario): Coin<T> {
    coin::mint_for_testing<T>(amount, ctx(scenario))
}

/// Creates a test clock
public fun create_test_clock(scenario: &mut Scenario): Clock {
    clock::create_for_testing(ctx(scenario))
}

/// Advances clock by duration
public fun advance_clock(clock: &mut Clock, duration_ms: u64) {
    clock::increment_for_testing(clock, duration_ms);
}

/// Destroys test clock
public fun destroy_test_clock(clock: Clock) {
    clock::destroy_for_testing(clock);
}