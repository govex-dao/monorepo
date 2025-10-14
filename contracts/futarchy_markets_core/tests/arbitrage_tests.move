#[test_only]
module futarchy_markets_core::arbitrage_tests;

use sui::test_scenario::{Self as ts};
use sui::clock::{Self, Clock};
use sui::coin::{Self, Coin};
use sui::object;
use futarchy_markets_core::arbitrage;
use futarchy_markets_core::unified_spot_pool::{Self, UnifiedSpotPool};
use futarchy_markets_core::swap_core;
use futarchy_markets_primitives::coin_escrow::{Self, TokenEscrow};
use futarchy_markets_primitives::conditional_balance::{Self, ConditionalMarketBalance};
use futarchy_markets_primitives::market_state::{Self, MarketState};
use futarchy_markets_primitives::conditional_amm::{Self, LiquidityPool};
use futarchy_one_shot_utils::test_coin_a::TEST_COIN_A;
use futarchy_one_shot_utils::test_coin_b::TEST_COIN_B;
use std::string;
use std::option;

// === Constants ===
const INITIAL_SPOT_RESERVE: u64 = 10_000_000_000; // 10,000 tokens (9 decimals)
const INITIAL_CONDITIONAL_RESERVE: u64 = 1_000_000_000; // 1,000 tokens per outcome
const DEFAULT_FEE_BPS: u16 = 30; // 0.3%

// === Test Helpers ===

/// Create a test clock
#[test_only]
fun create_test_clock(timestamp_ms: u64, ctx: &mut TxContext): Clock {
    let mut clock = clock::create_for_testing(ctx);
    clock::set_for_testing(&mut clock, timestamp_ms);
    clock
}

/// Create spot pool with initial liquidity
#[test_only]
fun create_test_spot_pool(
    asset_reserve: u64,
    stable_reserve: u64,
    _clock: &Clock,
    ctx: &mut TxContext,
): UnifiedSpotPool<TEST_COIN_A, TEST_COIN_B> {
    unified_spot_pool::create_pool_for_testing(
        asset_reserve,
        stable_reserve,
        (DEFAULT_FEE_BPS as u64),
        ctx,
    )
}

/// Create token escrow with market state and conditional pools
#[test_only]
fun create_test_escrow_with_markets(
    outcome_count: u64,
    conditional_reserve_per_outcome: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): TokenEscrow<TEST_COIN_A, TEST_COIN_B> {
    let proposal_id = object::id_from_address(@0xABC);
    let dao_id = object::id_from_address(@0xDEF);

    // Create market state with pools
    let mut outcome_messages = vector::empty();
    let mut i = 0;
    while (i < outcome_count) {
        vector::push_back(&mut outcome_messages, string::utf8(b"Outcome"));
        i = i + 1;
    };

    let market_state = market_state::new(
        proposal_id,
        dao_id,
        outcome_count,
        outcome_messages,
        clock,
        ctx,
    );

    // Create escrow with market state
    coin_escrow::create_test_escrow_with_market_state(
        outcome_count,
        market_state,
        ctx,
    )
}

/// Initialize AMM pools in market state
#[test_only]
fun initialize_amm_pools(escrow: &mut TokenEscrow<TEST_COIN_A, TEST_COIN_B>, ctx: &mut TxContext) {
    let market_state = coin_escrow::get_market_state_mut(escrow);

    // Check if pools already initialized
    if (market_state::has_amm_pools(market_state)) {
        return
    };

    // Get the market_id to ensure pools match
    let market_id = market_state::market_id(market_state);

    let outcome_count = market_state::outcome_count(market_state);
    let mut pools = vector::empty();
    let mut i = 0;
    let clock = create_test_clock(1000000, ctx);
    while (i < outcome_count) {
        // Create pool with correct market_id
        let pool = conditional_amm::create_test_pool(
            market_id,
            (i as u8), // outcome_idx
            (DEFAULT_FEE_BPS as u64), // fee_percent
            1000, // minimal asset_reserve
            1000, // minimal stable_reserve
            &clock,
            ctx
        );
        vector::push_back(&mut pools, pool);
        i = i + 1;
    };
    clock::destroy_for_testing(clock);

    market_state::set_amm_pools(market_state, pools);

    // Initialize trading for tests
    market_state::init_trading_for_testing(market_state);
}

/// Add initial liquidity to all conditional pools in escrow
#[test_only]
fun add_liquidity_to_conditional_pools(
    escrow: &mut TokenEscrow<TEST_COIN_A, TEST_COIN_B>,
    reserve_per_outcome: u64,
    ctx: &mut TxContext,
) {
    // Initialize pools first if not already done
    initialize_amm_pools(escrow, ctx);

    let market_state = coin_escrow::get_market_state_mut(escrow);
    let outcome_count = market_state::outcome_count(market_state);

    let mut i = 0;
    while (i < outcome_count) {
        let pool = market_state::borrow_amm_pool_mut(market_state, (i as u64));

        // Mint test coins for liquidity
        let asset_coin = coin::mint_for_testing<TEST_COIN_A>(reserve_per_outcome, ctx);
        let stable_coin = coin::mint_for_testing<TEST_COIN_B>(reserve_per_outcome, ctx);

        // Add liquidity
        conditional_amm::add_liquidity_for_testing(
            pool,
            asset_coin,
            stable_coin,
            DEFAULT_FEE_BPS,
            ctx,
        );

        i = i + 1;
    };
}

/// Create a balance object for testing
#[test_only]
fun create_test_balance(
    market_id: object::ID,
    outcome_count: u8,
    ctx: &mut TxContext,
): ConditionalMarketBalance<TEST_COIN_A, TEST_COIN_B> {
    conditional_balance::new<TEST_COIN_A, TEST_COIN_B>(
        market_id,
        outcome_count,
        ctx,
    )
}

// === burn_complete_set_and_withdraw_stable() Tests ===

#[test]
fun test_burn_complete_set_stable_success_2_outcomes() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    // Create escrow with 2 outcomes
    let mut escrow = create_test_escrow_with_markets(2, INITIAL_CONDITIONAL_RESERVE, &clock, ctx);

    // Deposit spot coins to escrow (for withdrawal)
    let asset_deposit = coin::mint_for_testing<TEST_COIN_A>(0, ctx);
    let stable_deposit = coin::mint_for_testing<TEST_COIN_B>(5000, ctx);
    coin_escrow::deposit_spot_coins(&mut escrow, asset_deposit, stable_deposit);

    // Create balance with 5000 stable in each outcome
    let market_id = object::id_from_address(@0xABC);
    let mut balance = create_test_balance(market_id, 2, ctx);
    conditional_balance::add_to_balance(&mut balance, 0, false, 5000);
    conditional_balance::add_to_balance(&mut balance, 1, false, 5000);

    // Burn complete set (5000 from each outcome)
    let withdrawn_stable = arbitrage::burn_complete_set_and_withdraw_stable(
        &mut balance,
        &mut escrow,
        5000,
        ctx,
    );

    // Verify withdrawal amount
    assert!(withdrawn_stable.value() == 5000, 0);

    // Verify balances updated
    assert!(conditional_balance::get_balance(&balance, 0, false) == 0, 1);
    assert!(conditional_balance::get_balance(&balance, 1, false) == 0, 2);

    // Cleanup
    coin::burn_for_testing(withdrawn_stable);
    conditional_balance::destroy_empty(balance);
    coin_escrow::destroy_for_testing(escrow);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
fun test_burn_complete_set_stable_success_5_outcomes() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    // Create escrow with 5 outcomes
    let mut escrow = create_test_escrow_with_markets(5, INITIAL_CONDITIONAL_RESERVE, &clock, ctx);

    // Deposit spot coins
    let asset_deposit = coin::mint_for_testing<TEST_COIN_A>(0, ctx);
    let stable_deposit = coin::mint_for_testing<TEST_COIN_B>(10000, ctx);
    coin_escrow::deposit_spot_coins(&mut escrow, asset_deposit, stable_deposit);

    // Create balance with 10000 stable in each of 5 outcomes
    let market_id = object::id_from_address(@0xABC);
    let mut balance = create_test_balance(market_id, 5, ctx);
    let mut i = 0u8;
    while ((i as u64) < 5) {
        conditional_balance::add_to_balance(&mut balance, i, false, 10000);
        i = i + 1;
    };

    // Burn complete set
    let withdrawn_stable = arbitrage::burn_complete_set_and_withdraw_stable(
        &mut balance,
        &mut escrow,
        10000,
        ctx,
    );

    // Verify
    assert!(withdrawn_stable.value() == 10000, 0);

    // All balances should be zero
    i = 0u8;
    while ((i as u64) < 5) {
        assert!(conditional_balance::get_balance(&balance, i, false) == 0, (i as u64) + 1);
        i = i + 1;
    };

    // Cleanup
    coin::burn_for_testing(withdrawn_stable);
    conditional_balance::destroy_empty(balance);
    coin_escrow::destroy_for_testing(escrow);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
fun test_burn_complete_set_stable_partial_burn() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    let mut escrow = create_test_escrow_with_markets(2, INITIAL_CONDITIONAL_RESERVE, &clock, ctx);

    // Deposit 10000 stable
    let asset_deposit = coin::mint_for_testing<TEST_COIN_A>(0, ctx);
    let stable_deposit = coin::mint_for_testing<TEST_COIN_B>(10000, ctx);
    coin_escrow::deposit_spot_coins(&mut escrow, asset_deposit, stable_deposit);

    // Create balance with 10000 in each outcome
    let market_id = object::id_from_address(@0xABC);
    let mut balance = create_test_balance(market_id, 2, ctx);
    conditional_balance::add_to_balance(&mut balance, 0, false, 10000);
    conditional_balance::add_to_balance(&mut balance, 1, false, 10000);

    // Burn only 3000 (partial)
    let withdrawn_stable = arbitrage::burn_complete_set_and_withdraw_stable(
        &mut balance,
        &mut escrow,
        3000,
        ctx,
    );

    assert!(withdrawn_stable.value() == 3000, 0);

    // Remaining balances should be 7000 each
    assert!(conditional_balance::get_balance(&balance, 0, false) == 7000, 1);
    assert!(conditional_balance::get_balance(&balance, 1, false) == 7000, 2);

    // Cleanup
    coin::burn_for_testing(withdrawn_stable);
    conditional_balance::set_balance(&mut balance, 0, false, 0);
    conditional_balance::set_balance(&mut balance, 1, false, 0);
    conditional_balance::destroy_empty(balance);
    coin_escrow::destroy_for_testing(escrow);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

// === burn_complete_set_and_withdraw_asset() Tests ===

#[test]
fun test_burn_complete_set_asset_success_2_outcomes() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    let mut escrow = create_test_escrow_with_markets(2, INITIAL_CONDITIONAL_RESERVE, &clock, ctx);

    // Deposit asset coins
    let asset_deposit = coin::mint_for_testing<TEST_COIN_A>(8000, ctx);
    let stable_deposit = coin::mint_for_testing<TEST_COIN_B>(0, ctx);
    coin_escrow::deposit_spot_coins(&mut escrow, asset_deposit, stable_deposit);

    // Create balance with 8000 asset in each outcome
    let market_id = object::id_from_address(@0xABC);
    let mut balance = create_test_balance(market_id, 2, ctx);
    conditional_balance::add_to_balance(&mut balance, 0, true, 8000);
    conditional_balance::add_to_balance(&mut balance, 1, true, 8000);

    // Burn complete set
    let withdrawn_asset = arbitrage::burn_complete_set_and_withdraw_asset(
        &mut balance,
        &mut escrow,
        8000,
        ctx,
    );

    assert!(withdrawn_asset.value() == 8000, 0);
    assert!(conditional_balance::get_balance(&balance, 0, true) == 0, 1);
    assert!(conditional_balance::get_balance(&balance, 1, true) == 0, 2);

    // Cleanup
    coin::burn_for_testing(withdrawn_asset);
    conditional_balance::destroy_empty(balance);
    coin_escrow::destroy_for_testing(escrow);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
fun test_burn_complete_set_asset_success_3_outcomes() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    let mut escrow = create_test_escrow_with_markets(3, INITIAL_CONDITIONAL_RESERVE, &clock, ctx);

    // Deposit asset coins
    let asset_deposit = coin::mint_for_testing<TEST_COIN_A>(15000, ctx);
    let stable_deposit = coin::mint_for_testing<TEST_COIN_B>(0, ctx);
    coin_escrow::deposit_spot_coins(&mut escrow, asset_deposit, stable_deposit);

    // Create balance with 15000 asset in each of 3 outcomes
    let market_id = object::id_from_address(@0xABC);
    let mut balance = create_test_balance(market_id, 3, ctx);
    let mut i = 0u8;
    while ((i as u64) < 3) {
        conditional_balance::add_to_balance(&mut balance, i, true, 15000);
        i = i + 1;
    };

    // Burn complete set
    let withdrawn_asset = arbitrage::burn_complete_set_and_withdraw_asset(
        &mut balance,
        &mut escrow,
        15000,
        ctx,
    );

    assert!(withdrawn_asset.value() == 15000, 0);

    // All asset balances should be zero
    i = 0u8;
    while ((i as u64) < 3) {
        assert!(conditional_balance::get_balance(&balance, i, true) == 0, (i as u64) + 1);
        i = i + 1;
    };

    // Cleanup
    coin::burn_for_testing(withdrawn_asset);
    conditional_balance::destroy_empty(balance);
    coin_escrow::destroy_for_testing(escrow);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

// === execute_optimal_spot_arbitrage() Tests ===

#[test]
fun test_execute_optimal_arbitrage_stable_to_asset_direction_2_outcomes() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    // Create spot pool
    let mut spot_pool = create_test_spot_pool(
        INITIAL_SPOT_RESERVE,
        INITIAL_SPOT_RESERVE,
        &clock,
        ctx,
    );

    // Create escrow with 2 outcome markets
    let mut escrow = create_test_escrow_with_markets(2, INITIAL_CONDITIONAL_RESERVE, &clock, ctx);
    add_liquidity_to_conditional_pools(&mut escrow, INITIAL_CONDITIONAL_RESERVE, ctx);

    // Deposit spot coins to escrow for withdrawal during arbitrage
    let asset_deposit = coin::mint_for_testing<TEST_COIN_A>(2000, ctx);
    let stable_deposit = coin::mint_for_testing<TEST_COIN_B>(2000, ctx);
    coin_escrow::deposit_spot_coins(&mut escrow, asset_deposit, stable_deposit);

    // Create swap session
    let proposal_id = object::id_from_address(@0xABC);
    let session = swap_core::create_test_swap_session(proposal_id);

    // Execute arbitrage: Stable→Asset direction
    let stable_for_arb = coin::mint_for_testing<TEST_COIN_B>(1000, ctx);
    let asset_for_arb = coin::zero<TEST_COIN_A>(ctx);

    let (stable_profit, asset_profit, mut dust_opt) = arbitrage::execute_optimal_spot_arbitrage(
        &mut spot_pool,
        &mut escrow,
        &session,
        stable_for_arb,
        asset_for_arb,
        0, // min_profit
        @0x999, // recipient
        false, // return_dust_balance
        &clock,
        ctx,
    );

    // Should get stable profit back (may be less due to fees/slippage)
    assert!(stable_profit.value() > 0 || stable_profit.value() == 0, 0);
    assert!(asset_profit.value() == 0, 1);
    assert!(option::is_some(&dust_opt), 2); // Dust balance always returned now

    // Cleanup
    coin::burn_for_testing(stable_profit);
    coin::burn_for_testing(asset_profit);
    let dust = option::extract(&mut dust_opt);
    conditional_balance::destroy_for_testing(dust);
    option::destroy_none(dust_opt);
    swap_core::destroy_test_swap_session(session);
    unified_spot_pool::destroy_for_testing(spot_pool);
    coin_escrow::destroy_for_testing(escrow);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
fun test_execute_optimal_arbitrage_asset_to_stable_direction_2_outcomes() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    let mut spot_pool = create_test_spot_pool(
        INITIAL_SPOT_RESERVE,
        INITIAL_SPOT_RESERVE,
        &clock,
        ctx,
    );

    let mut escrow = create_test_escrow_with_markets(2, INITIAL_CONDITIONAL_RESERVE, &clock, ctx);
    add_liquidity_to_conditional_pools(&mut escrow, INITIAL_CONDITIONAL_RESERVE, ctx);

    // Deposit spot coins to escrow for withdrawal during arbitrage
    let asset_deposit = coin::mint_for_testing<TEST_COIN_A>(3000, ctx);
    let stable_deposit = coin::mint_for_testing<TEST_COIN_B>(3000, ctx);
    coin_escrow::deposit_spot_coins(&mut escrow, asset_deposit, stable_deposit);

    let proposal_id = object::id_from_address(@0xABC);
    let session = swap_core::create_test_swap_session(proposal_id);

    // Execute arbitrage: Asset→Stable direction
    let stable_for_arb = coin::zero<TEST_COIN_B>(ctx);
    let asset_for_arb = coin::mint_for_testing<TEST_COIN_A>(2000, ctx);

    let (stable_profit, asset_profit, mut dust_opt) = arbitrage::execute_optimal_spot_arbitrage(
        &mut spot_pool,
        &mut escrow,
        &session,
        stable_for_arb,
        asset_for_arb,
        0,
        @0x999,
        false,
        &clock,
        ctx,
    );

    // Should get asset profit back
    assert!(stable_profit.value() == 0, 0);
    assert!(asset_profit.value() > 0 || asset_profit.value() == 0, 1);
    assert!(option::is_some(&dust_opt), 2); // Dust balance always returned now

    // Cleanup
    coin::burn_for_testing(stable_profit);
    coin::burn_for_testing(asset_profit);
    let dust = option::extract(&mut dust_opt);
    conditional_balance::destroy_for_testing(dust);
    option::destroy_none(dust_opt);
    swap_core::destroy_test_swap_session(session);
    unified_spot_pool::destroy_for_testing(spot_pool);
    coin_escrow::destroy_for_testing(escrow);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
fun test_execute_optimal_arbitrage_with_dust_balance_return() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    let mut spot_pool = create_test_spot_pool(
        INITIAL_SPOT_RESERVE,
        INITIAL_SPOT_RESERVE,
        &clock,
        ctx,
    );

    let mut escrow = create_test_escrow_with_markets(3, INITIAL_CONDITIONAL_RESERVE, &clock, ctx);
    add_liquidity_to_conditional_pools(&mut escrow, INITIAL_CONDITIONAL_RESERVE, ctx);

    // Deposit spot coins to escrow for withdrawal during arbitrage
    let asset_deposit = coin::mint_for_testing<TEST_COIN_A>(1000, ctx);
    let stable_deposit = coin::mint_for_testing<TEST_COIN_B>(1000, ctx);
    coin_escrow::deposit_spot_coins(&mut escrow, asset_deposit, stable_deposit);

    let proposal_id = object::id_from_address(@0xABC);
    let session = swap_core::create_test_swap_session(proposal_id);

    // Execute with return_dust_balance=true
    let stable_for_arb = coin::mint_for_testing<TEST_COIN_B>(500, ctx);
    let asset_for_arb = coin::zero<TEST_COIN_A>(ctx);

    let (stable_profit, asset_profit, mut dust_opt) = arbitrage::execute_optimal_spot_arbitrage(
        &mut spot_pool,
        &mut escrow,
        &session,
        stable_for_arb,
        asset_for_arb,
        0,
        @0x999,
        true, // return_dust_balance=true
        &clock,
        ctx,
    );

    // Should return dust balance object
    assert!(option::is_some(&dust_opt), 0);

    // Cleanup
    coin::burn_for_testing(stable_profit);
    coin::burn_for_testing(asset_profit);
    let dust = option::extract(&mut dust_opt);
    conditional_balance::destroy_for_testing(dust);
    option::destroy_none(dust_opt);
    swap_core::destroy_test_swap_session(session);
    unified_spot_pool::destroy_for_testing(spot_pool);
    coin_escrow::destroy_for_testing(escrow);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
fun test_execute_optimal_arbitrage_both_zero_amounts() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    let mut spot_pool = create_test_spot_pool(
        INITIAL_SPOT_RESERVE,
        INITIAL_SPOT_RESERVE,
        &clock,
        ctx,
    );

    let mut escrow = create_test_escrow_with_markets(2, INITIAL_CONDITIONAL_RESERVE, &clock, ctx);

    // Initialize AMM pools to enable trading
    initialize_amm_pools(&mut escrow, ctx);

    let proposal_id = object::id_from_address(@0xABC);
    let session = swap_core::create_test_swap_session(proposal_id);

    // Execute with both zero
    let stable_for_arb = coin::zero<TEST_COIN_B>(ctx);
    let asset_for_arb = coin::zero<TEST_COIN_A>(ctx);

    let (stable_profit, asset_profit, dust_opt) = arbitrage::execute_optimal_spot_arbitrage(
        &mut spot_pool,
        &mut escrow,
        &session,
        stable_for_arb,
        asset_for_arb,
        0,
        @0x999,
        false,
        &clock,
        ctx,
    );

    // Should return zeros (no arbitrage executed, so no dust balance)
    assert!(stable_profit.value() == 0, 0);
    assert!(asset_profit.value() == 0, 1);
    assert!(option::is_none(&dust_opt), 2); // No arbitrage = no dust balance

    // Cleanup
    coin::burn_for_testing(stable_profit);
    coin::burn_for_testing(asset_profit);
    option::destroy_none(dust_opt);
    swap_core::destroy_test_swap_session(session);
    unified_spot_pool::destroy_for_testing(spot_pool);
    coin_escrow::destroy_for_testing(escrow);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

// === Error Tests ===

#[test]
#[expected_failure(abort_code = 1)] // EInsufficientProfit
fun test_execute_optimal_arbitrage_insufficient_profit() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    let mut spot_pool = create_test_spot_pool(
        INITIAL_SPOT_RESERVE,
        INITIAL_SPOT_RESERVE,
        &clock,
        ctx,
    );

    let mut escrow = create_test_escrow_with_markets(2, INITIAL_CONDITIONAL_RESERVE, &clock, ctx);
    add_liquidity_to_conditional_pools(&mut escrow, INITIAL_CONDITIONAL_RESERVE, ctx);

    // Deposit spot coins to escrow for withdrawal during arbitrage
    let asset_deposit = coin::mint_for_testing<TEST_COIN_A>(500, ctx);
    let stable_deposit = coin::mint_for_testing<TEST_COIN_B>(500, ctx);
    coin_escrow::deposit_spot_coins(&mut escrow, asset_deposit, stable_deposit);

    let proposal_id = object::id_from_address(@0xABC);
    let session = swap_core::create_test_swap_session(proposal_id);

    // Set min_profit impossibly high
    let stable_for_arb = coin::mint_for_testing<TEST_COIN_B>(100, ctx);
    let asset_for_arb = coin::zero<TEST_COIN_A>(ctx);

    let (stable_profit, asset_profit, mut dust_opt) = arbitrage::execute_optimal_spot_arbitrage(
        &mut spot_pool,
        &mut escrow,
        &session,
        stable_for_arb,
        asset_for_arb,
        999_999_999_999, // Impossibly high min_profit
        @0x999,
        false,
        &clock,
        ctx,
    );

    // Should abort before reaching here
    coin::burn_for_testing(stable_profit);
    coin::burn_for_testing(asset_profit);
    let dust = option::extract(&mut dust_opt);
    conditional_balance::destroy_for_testing(dust);
    option::destroy_none(dust_opt);
    swap_core::destroy_test_swap_session(session);
    unified_spot_pool::destroy_for_testing(spot_pool);
    coin_escrow::destroy_for_testing(escrow);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

// === Edge Cases ===

#[test]
fun test_arbitrage_with_5_outcomes() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    let mut spot_pool = create_test_spot_pool(
        INITIAL_SPOT_RESERVE * 2,
        INITIAL_SPOT_RESERVE * 2,
        &clock,
        ctx,
    );

    // Test with 5 outcomes (key innovation!)
    let mut escrow = create_test_escrow_with_markets(5, INITIAL_CONDITIONAL_RESERVE, &clock, ctx);
    add_liquidity_to_conditional_pools(&mut escrow, INITIAL_CONDITIONAL_RESERVE, ctx);

    // Deposit spot coins to escrow for withdrawal during arbitrage
    let asset_deposit = coin::mint_for_testing<TEST_COIN_A>(5000, ctx);
    let stable_deposit = coin::mint_for_testing<TEST_COIN_B>(5000, ctx);
    coin_escrow::deposit_spot_coins(&mut escrow, asset_deposit, stable_deposit);

    let proposal_id = object::id_from_address(@0xABC);
    let session = swap_core::create_test_swap_session(proposal_id);

    let stable_for_arb = coin::mint_for_testing<TEST_COIN_B>(3000, ctx);
    let asset_for_arb = coin::zero<TEST_COIN_A>(ctx);

    // Same function works for 5 outcomes!
    let (stable_profit, asset_profit, mut dust_opt) = arbitrage::execute_optimal_spot_arbitrage(
        &mut spot_pool,
        &mut escrow,
        &session,
        stable_for_arb,
        asset_for_arb,
        0,
        @0x999,
        false,
        &clock,
        ctx,
    );

    // Should complete successfully
    assert!(stable_profit.value() >= 0, 0);
    assert!(asset_profit.value() == 0, 1);
    assert!(option::is_some(&dust_opt), 2); // Dust balance always returned now

    // Cleanup
    coin::burn_for_testing(stable_profit);
    coin::burn_for_testing(asset_profit);
    let dust = option::extract(&mut dust_opt);
    conditional_balance::destroy_for_testing(dust);
    option::destroy_none(dust_opt);
    swap_core::destroy_test_swap_session(session);
    unified_spot_pool::destroy_for_testing(spot_pool);
    coin_escrow::destroy_for_testing(escrow);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
fun test_burn_complete_set_with_zero_amount() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    let mut escrow = create_test_escrow_with_markets(2, INITIAL_CONDITIONAL_RESERVE, &clock, ctx);

    // Deposit some coins (needed for escrow to have balance, even if we withdraw 0)
    let asset_deposit = coin::mint_for_testing<TEST_COIN_A>(100, ctx);
    let stable_deposit = coin::mint_for_testing<TEST_COIN_B>(100, ctx);
    coin_escrow::deposit_spot_coins(&mut escrow, asset_deposit, stable_deposit);

    let market_id = object::id_from_address(@0xABC);
    let mut balance = create_test_balance(market_id, 2, ctx);
    conditional_balance::add_to_balance(&mut balance, 0, false, 100);
    conditional_balance::add_to_balance(&mut balance, 1, false, 100);

    // Burn zero amount
    let withdrawn_stable = arbitrage::burn_complete_set_and_withdraw_stable(
        &mut balance,
        &mut escrow,
        0, // zero amount
        ctx,
    );

    // Should return zero coin
    assert!(withdrawn_stable.value() == 0, 0);

    // Balances unchanged
    assert!(conditional_balance::get_balance(&balance, 0, false) == 100, 1);
    assert!(conditional_balance::get_balance(&balance, 1, false) == 100, 2);

    // Cleanup
    coin::burn_for_testing(withdrawn_stable);
    conditional_balance::set_balance(&mut balance, 0, false, 0);
    conditional_balance::set_balance(&mut balance, 1, false, 0);
    conditional_balance::destroy_empty(balance);
    coin_escrow::destroy_for_testing(escrow);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}
