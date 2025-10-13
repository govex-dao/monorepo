#[test_only]
module futarchy_markets_core::arbitrage_core_tests;

use sui::test_scenario::{Self as ts};
use sui::clock::{Self, Clock};
use sui::coin::{Self, Coin};
use futarchy_markets_core::arbitrage_core;
use futarchy_one_shot_utils::test_coin_a::TEST_COIN_A;

// === Test Helpers ===

/// Create a test clock at specific time
#[test_only]
fun create_test_clock(timestamp_ms: u64, ctx: &mut TxContext): Clock {
    let mut clock = clock::create_for_testing(ctx);
    clock::set_for_testing(&mut clock, timestamp_ms);
    clock
}

// === find_min_value() Tests ===

#[test]
fun test_find_min_value_single_coin() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    let mut coins = vector::empty<Coin<TEST_COIN_A>>();
    vector::push_back(&mut coins, coin::mint_for_testing<TEST_COIN_A>(100, ctx));

    let min = arbitrage_core::find_min_value(&coins);
    assert!(min == 100, 0);

    while (!vector::is_empty(&coins)) {
        let c = vector::pop_back(&mut coins);
        coin::burn_for_testing(c);
    };
    vector::destroy_empty(coins);
    ts::end(scenario);
}

#[test]
fun test_find_min_value_multiple_coins() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    let mut coins = vector::empty<Coin<TEST_COIN_A>>();
    vector::push_back(&mut coins, coin::mint_for_testing<TEST_COIN_A>(500, ctx));
    vector::push_back(&mut coins, coin::mint_for_testing<TEST_COIN_A>(100, ctx)); // Min
    vector::push_back(&mut coins, coin::mint_for_testing<TEST_COIN_A>(300, ctx));
    vector::push_back(&mut coins, coin::mint_for_testing<TEST_COIN_A>(200, ctx));

    let min = arbitrage_core::find_min_value(&coins);
    assert!(min == 100, 0);

    while (!vector::is_empty(&coins)) {
        let c = vector::pop_back(&mut coins);
        coin::burn_for_testing(c);
    };
    vector::destroy_empty(coins);
    ts::end(scenario);
}

#[test]
fun test_find_min_value_all_equal() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    let mut coins = vector::empty<Coin<TEST_COIN_A>>();
    vector::push_back(&mut coins, coin::mint_for_testing<TEST_COIN_A>(250, ctx));
    vector::push_back(&mut coins, coin::mint_for_testing<TEST_COIN_A>(250, ctx));
    vector::push_back(&mut coins, coin::mint_for_testing<TEST_COIN_A>(250, ctx));

    let min = arbitrage_core::find_min_value(&coins);
    assert!(min == 250, 0);

    while (!vector::is_empty(&coins)) {
        let c = vector::pop_back(&mut coins);
        coin::burn_for_testing(c);
    };
    vector::destroy_empty(coins);
    ts::end(scenario);
}

#[test]
fun test_find_min_value_with_zero() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    let mut coins = vector::empty<Coin<TEST_COIN_A>>();
    vector::push_back(&mut coins, coin::mint_for_testing<TEST_COIN_A>(1000, ctx));
    vector::push_back(&mut coins, coin::mint_for_testing<TEST_COIN_A>(0, ctx)); // Zero coin
    vector::push_back(&mut coins, coin::mint_for_testing<TEST_COIN_A>(500, ctx));

    let min = arbitrage_core::find_min_value(&coins);
    assert!(min == 0, 0);

    while (!vector::is_empty(&coins)) {
        let c = vector::pop_back(&mut coins);
        coin::burn_for_testing(c);
    };
    vector::destroy_empty(coins);
    ts::end(scenario);
}

#[test]
fun test_find_min_value_large_vector() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    let mut coins = vector::empty<Coin<TEST_COIN_A>>();

    // Create 10 coins with different values
    vector::push_back(&mut coins, coin::mint_for_testing<TEST_COIN_A>(1000, ctx));
    vector::push_back(&mut coins, coin::mint_for_testing<TEST_COIN_A>(900, ctx));
    vector::push_back(&mut coins, coin::mint_for_testing<TEST_COIN_A>(800, ctx));
    vector::push_back(&mut coins, coin::mint_for_testing<TEST_COIN_A>(700, ctx));
    vector::push_back(&mut coins, coin::mint_for_testing<TEST_COIN_A>(600, ctx));
    vector::push_back(&mut coins, coin::mint_for_testing<TEST_COIN_A>(500, ctx));
    vector::push_back(&mut coins, coin::mint_for_testing<TEST_COIN_A>(400, ctx));
    vector::push_back(&mut coins, coin::mint_for_testing<TEST_COIN_A>(300, ctx));
    vector::push_back(&mut coins, coin::mint_for_testing<TEST_COIN_A>(200, ctx));
    vector::push_back(&mut coins, coin::mint_for_testing<TEST_COIN_A>(50, ctx)); // Min

    let min = arbitrage_core::find_min_value(&coins);
    assert!(min == 50, 0);

    while (!vector::is_empty(&coins)) {
        let c = vector::pop_back(&mut coins);
        coin::burn_for_testing(c);
    };
    vector::destroy_empty(coins);
    ts::end(scenario);
}

#[test]
fun test_find_min_value_two_coins_different() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    let mut coins = vector::empty<Coin<TEST_COIN_A>>();
    vector::push_back(&mut coins, coin::mint_for_testing<TEST_COIN_A>(999, ctx));
    vector::push_back(&mut coins, coin::mint_for_testing<TEST_COIN_A>(1, ctx)); // Min

    let min = arbitrage_core::find_min_value(&coins);
    assert!(min == 1, 0);

    while (!vector::is_empty(&coins)) {
        let c = vector::pop_back(&mut coins);
        coin::burn_for_testing(c);
    };
    vector::destroy_empty(coins);
    ts::end(scenario);
}

#[test]
fun test_find_min_value_max_u64() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    let mut coins = vector::empty<Coin<TEST_COIN_A>>();

    // Create coins with large values
    vector::push_back(&mut coins, coin::mint_for_testing<TEST_COIN_A>(1_000_000_000_000, ctx));
    vector::push_back(&mut coins, coin::mint_for_testing<TEST_COIN_A>(500_000_000_000, ctx)); // Min
    vector::push_back(&mut coins, coin::mint_for_testing<TEST_COIN_A>(2_000_000_000_000, ctx));

    let min = arbitrage_core::find_min_value(&coins);
    assert!(min == 500_000_000_000, 0);

    while (!vector::is_empty(&coins)) {
        let c = vector::pop_back(&mut coins);
        coin::burn_for_testing(c);
    };
    vector::destroy_empty(coins);
    ts::end(scenario);
}

#[test]
fun test_find_min_value_descending_order() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    let mut coins = vector::empty<Coin<TEST_COIN_A>>();
    // Add in descending order
    vector::push_back(&mut coins, coin::mint_for_testing<TEST_COIN_A>(1000, ctx));
    vector::push_back(&mut coins, coin::mint_for_testing<TEST_COIN_A>(500, ctx));
    vector::push_back(&mut coins, coin::mint_for_testing<TEST_COIN_A>(100, ctx)); // Min
    vector::push_back(&mut coins, coin::mint_for_testing<TEST_COIN_A>(50, ctx)); // Min

    let min = arbitrage_core::find_min_value(&coins);
    assert!(min == 50, 0);

    while (!vector::is_empty(&coins)) {
        let c = vector::pop_back(&mut coins);
        coin::burn_for_testing(c);
    };
    vector::destroy_empty(coins);
    ts::end(scenario);
}

#[test]
fun test_find_min_value_ascending_order() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    let mut coins = vector::empty<Coin<TEST_COIN_A>>();
    // Add in ascending order
    vector::push_back(&mut coins, coin::mint_for_testing<TEST_COIN_A>(10, ctx)); // Min
    vector::push_back(&mut coins, coin::mint_for_testing<TEST_COIN_A>(100, ctx));
    vector::push_back(&mut coins, coin::mint_for_testing<TEST_COIN_A>(500, ctx));
    vector::push_back(&mut coins, coin::mint_for_testing<TEST_COIN_A>(1000, ctx));

    let min = arbitrage_core::find_min_value(&coins);
    assert!(min == 10, 0);

    while (!vector::is_empty(&coins)) {
        let c = vector::pop_back(&mut coins);
        coin::burn_for_testing(c);
    };
    vector::destroy_empty(coins);
    ts::end(scenario);
}

#[test]
fun test_find_min_value_min_at_beginning() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    let mut coins = vector::empty<Coin<TEST_COIN_A>>();
    vector::push_back(&mut coins, coin::mint_for_testing<TEST_COIN_A>(5, ctx)); // Min at start
    vector::push_back(&mut coins, coin::mint_for_testing<TEST_COIN_A>(500, ctx));
    vector::push_back(&mut coins, coin::mint_for_testing<TEST_COIN_A>(300, ctx));

    let min = arbitrage_core::find_min_value(&coins);
    assert!(min == 5, 0);

    while (!vector::is_empty(&coins)) {
        let c = vector::pop_back(&mut coins);
        coin::burn_for_testing(c);
    };
    vector::destroy_empty(coins);
    ts::end(scenario);
}

#[test]
fun test_find_min_value_min_at_end() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    let mut coins = vector::empty<Coin<TEST_COIN_A>>();
    vector::push_back(&mut coins, coin::mint_for_testing<TEST_COIN_A>(500, ctx));
    vector::push_back(&mut coins, coin::mint_for_testing<TEST_COIN_A>(300, ctx));
    vector::push_back(&mut coins, coin::mint_for_testing<TEST_COIN_A>(5, ctx)); // Min at end

    let min = arbitrage_core::find_min_value(&coins);
    assert!(min == 5, 0);

    while (!vector::is_empty(&coins)) {
        let c = vector::pop_back(&mut coins);
        coin::burn_for_testing(c);
    };
    vector::destroy_empty(coins);
    ts::end(scenario);
}

#[test]
fun test_find_min_value_min_in_middle() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    let mut coins = vector::empty<Coin<TEST_COIN_A>>();
    vector::push_back(&mut coins, coin::mint_for_testing<TEST_COIN_A>(500, ctx));
    vector::push_back(&mut coins, coin::mint_for_testing<TEST_COIN_A>(5, ctx)); // Min in middle
    vector::push_back(&mut coins, coin::mint_for_testing<TEST_COIN_A>(300, ctx));

    let min = arbitrage_core::find_min_value(&coins);
    assert!(min == 5, 0);

    while (!vector::is_empty(&coins)) {
        let c = vector::pop_back(&mut coins);
        coin::burn_for_testing(c);
    };
    vector::destroy_empty(coins);
    ts::end(scenario);
}

#[test]
fun test_find_min_value_multiple_minimums() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    let mut coins = vector::empty<Coin<TEST_COIN_A>>();
    // Multiple coins with the minimum value
    vector::push_back(&mut coins, coin::mint_for_testing<TEST_COIN_A>(100, ctx));
    vector::push_back(&mut coins, coin::mint_for_testing<TEST_COIN_A>(25, ctx)); // Min
    vector::push_back(&mut coins, coin::mint_for_testing<TEST_COIN_A>(500, ctx));
    vector::push_back(&mut coins, coin::mint_for_testing<TEST_COIN_A>(25, ctx)); // Min (duplicate)
    vector::push_back(&mut coins, coin::mint_for_testing<TEST_COIN_A>(300, ctx));

    let min = arbitrage_core::find_min_value(&coins);
    assert!(min == 25, 0);

    while (!vector::is_empty(&coins)) {
        let c = vector::pop_back(&mut coins);
        coin::burn_for_testing(c);
    };
    vector::destroy_empty(coins);
    ts::end(scenario);
}

#[test]
fun test_find_min_value_very_large_values() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    let mut coins = vector::empty<Coin<TEST_COIN_A>>();
    // Test with very large u64 values
    let max_u64 = 18_446_744_073_709_551_615u64;
    vector::push_back(&mut coins, coin::mint_for_testing<TEST_COIN_A>(max_u64 - 1000, ctx));
    vector::push_back(&mut coins, coin::mint_for_testing<TEST_COIN_A>(max_u64 - 5000, ctx)); // Min
    vector::push_back(&mut coins, coin::mint_for_testing<TEST_COIN_A>(max_u64 - 500, ctx));

    let min = arbitrage_core::find_min_value(&coins);
    assert!(min == max_u64 - 5000, 0);

    while (!vector::is_empty(&coins)) {
        let c = vector::pop_back(&mut coins);
        coin::burn_for_testing(c);
    };
    vector::destroy_empty(coins);
    ts::end(scenario);
}

// === Integration Test ===

#[test]
fun test_find_min_value_realistic_arbitrage_scenario() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    // Simulate finding minimum conditional token balance across 3 outcomes
    let mut conditional_balances = vector::empty<Coin<TEST_COIN_A>>();
    vector::push_back(&mut conditional_balances, coin::mint_for_testing<TEST_COIN_A>(150_000_000, ctx)); // Outcome 0
    vector::push_back(&mut conditional_balances, coin::mint_for_testing<TEST_COIN_A>(145_000_000, ctx)); // Outcome 1 (min - bottleneck)
    vector::push_back(&mut conditional_balances, coin::mint_for_testing<TEST_COIN_A>(148_000_000, ctx)); // Outcome 2

    // Find the bottleneck amount for complete set burning
    let complete_set_amount = arbitrage_core::find_min_value(&conditional_balances);

    // This is the maximum amount we can burn as complete sets
    assert!(complete_set_amount == 145_000_000, 0);

    // Remaining dust would be:
    // Outcome 0: 150M - 145M = 5M (dust)
    // Outcome 1: 145M - 145M = 0 (no dust)
    // Outcome 2: 148M - 145M = 3M (dust)

    while (!vector::is_empty(&conditional_balances)) {
        let c = vector::pop_back(&mut conditional_balances);
        coin::burn_for_testing(c);
    };
    vector::destroy_empty(conditional_balances);
    ts::end(scenario);
}
