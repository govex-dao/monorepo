#[test_only]
module futarchy_markets_core::reward_claiming_tests;

use sui::test_scenario::{Self as ts};
use sui::clock::{Self, Clock};
use sui::coin::{Self, Coin};
use sui::sui::SUI;
use sui::balance;
use futarchy_markets_core::subsidy_escrow;
use futarchy_core::subsidy_config;
use futarchy_markets_primitives::conditional_amm::{Self, LiquidityPool};
use futarchy_markets_primitives::coin_escrow::{Self, TokenEscrow};
use futarchy_markets_primitives::market_state;
use futarchy_markets_core::proposal::{Self, Proposal};

// === Test Constants ===
const MIN_CRANK_INTERVAL_MS: u64 = 300_000; // 5 minutes
const DEFAULT_KEEPER_FEE: u64 = 100_000_000; // 0.1 SUI
const DEFAULT_SUBSIDY_PER_OUTCOME_PER_CRANK: u64 = 100_000_000; // 0.1 SUI

// === Test Helpers ===

/// Create a test pool with specified reserves
#[test_only]
fun create_test_pool(
    market_id: ID,
    outcome_idx: u8,
    asset_reserve: u64,
    stable_reserve: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): LiquidityPool {
    conditional_amm::create_test_pool(
        market_id,
        outcome_idx,
        30, // 0.3% fee
        asset_reserve,
        stable_reserve,
        clock,
        ctx,
    )
}

/// Create multiple test pools for testing
#[test_only]
fun create_test_pools(
    market_id: ID,
    outcome_count: u64,
    asset_reserve: u64,
    stable_reserve: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): vector<LiquidityPool> {
    let mut pools = vector::empty<LiquidityPool>();
    let mut i = 0;
    while (i < outcome_count) {
        let pool = create_test_pool(
            market_id,
            (i as u8),
            asset_reserve,
            stable_reserve,
            clock,
            ctx,
        );
        vector::push_back(&mut pools, pool);
        i = i + 1;
    };
    pools
}

/// Cleanup pools
#[test_only]
fun destroy_pools(mut pools: vector<LiquidityPool>) {
    while (!vector::is_empty(&pools)) {
        let pool = vector::pop_back(&mut pools);
        conditional_amm::destroy_for_testing(pool);
    };
    vector::destroy_empty(pools);
}

// === Reward Accumulation Tests ===

#[test]
fun test_accumulate_subsidy_rewards() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    let market_id = object::id_from_address(@0x300);
    let mut clock = clock::create_for_testing(ctx);
    clock::set_for_testing(&mut clock, 1_000_000);

    let mut pool = create_test_pool(market_id, 0, 1_000_000_000, 1_000_000_000, &clock, ctx);

    // Verify initial state: no rewards
    let initial_rewards = conditional_amm::get_lp_rewards(&pool);
    assert!(initial_rewards == 0, 0);

    // Add 1 SUI as rewards
    let reward_amount = 1_000_000_000u64;
    let reward_balance = balance::create_for_testing<SUI>(reward_amount);
    conditional_amm::accumulate_subsidy_rewards(&mut pool, reward_balance);

    // Verify rewards accumulated
    let after_rewards = conditional_amm::get_lp_rewards(&pool);
    assert!(after_rewards == reward_amount, 1);

    // Verify reserves unchanged (rewards separate from AMM reserves)
    let (asset, stable) = conditional_amm::get_reserves(&pool);
    assert!(asset == 1_000_000_000, 2);
    assert!(stable == 1_000_000_000, 3);

    conditional_amm::destroy_for_testing(pool);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
fun test_multiple_reward_accumulations() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    let market_id = object::id_from_address(@0x300);
    let mut clock = clock::create_for_testing(ctx);
    clock::set_for_testing(&mut clock, 1_000_000);

    let mut pool = create_test_pool(market_id, 0, 1_000_000_000, 1_000_000_000, &clock, ctx);

    // Add rewards 3 times
    let reward1 = balance::create_for_testing<SUI>(100_000_000); // 0.1 SUI
    conditional_amm::accumulate_subsidy_rewards(&mut pool, reward1);

    let reward2 = balance::create_for_testing<SUI>(200_000_000); // 0.2 SUI
    conditional_amm::accumulate_subsidy_rewards(&mut pool, reward2);

    let reward3 = balance::create_for_testing<SUI>(300_000_000); // 0.3 SUI
    conditional_amm::accumulate_subsidy_rewards(&mut pool, reward3);

    // Verify total rewards = 0.6 SUI
    let total_rewards = conditional_amm::get_lp_rewards(&pool);
    assert!(total_rewards == 600_000_000, 0);

    conditional_amm::destroy_for_testing(pool);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

// === Reward Extraction Tests ===

#[test]
fun test_extract_all_rewards() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    let market_id = object::id_from_address(@0x300);
    let mut clock = clock::create_for_testing(ctx);
    clock::set_for_testing(&mut clock, 1_000_000);

    let mut pool = create_test_pool(market_id, 0, 1_000_000_000, 1_000_000_000, &clock, ctx);

    // Add rewards
    let reward_amount = 500_000_000u64;
    let reward_balance = balance::create_for_testing<SUI>(reward_amount);
    conditional_amm::accumulate_subsidy_rewards(&mut pool, reward_balance);

    // Extract all rewards
    let extracted = conditional_amm::extract_all_rewards(&mut pool);
    assert!(balance::value(&extracted) == reward_amount, 0);

    // Verify pool has zero rewards remaining
    let remaining_rewards = conditional_amm::get_lp_rewards(&pool);
    assert!(remaining_rewards == 0, 1);

    // Verify reserves unchanged
    let (asset, stable) = conditional_amm::get_reserves(&pool);
    assert!(asset == 1_000_000_000, 2);
    assert!(stable == 1_000_000_000, 3);

    balance::destroy_for_testing(extracted);
    conditional_amm::destroy_for_testing(pool);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
fun test_extract_rewards_from_empty_pool() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    let market_id = object::id_from_address(@0x300);
    let mut clock = clock::create_for_testing(ctx);
    clock::set_for_testing(&mut clock, 1_000_000);

    let mut pool = create_test_pool(market_id, 0, 1_000_000_000, 1_000_000_000, &clock, ctx);

    // Extract from pool with no rewards
    let extracted = conditional_amm::extract_all_rewards(&mut pool);
    assert!(balance::value(&extracted) == 0, 0);

    // Destroy zero balance
    balance::destroy_zero(extracted);
    conditional_amm::destroy_for_testing(pool);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

// === Integration Tests: Cranking + Reward Accumulation ===

#[test]
fun test_crank_accumulates_rewards_in_pools() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    let proposal_id = object::id_from_address(@0x100);
    let dao_id = object::id_from_address(@0x200);
    let market_id = object::id_from_address(@0x300);

    let mut clock = clock::create_for_testing(ctx);
    clock::set_for_testing(&mut clock, 1_000_000);

    // Create 2 pools
    let mut pools = create_test_pools(market_id, 2, 1_000_000_000, 1_000_000_000, &clock, ctx);

    let mut amm_ids = vector::empty<ID>();
    vector::push_back(&mut amm_ids, conditional_amm::get_id(vector::borrow(&pools, 0)));
    vector::push_back(&mut amm_ids, conditional_amm::get_id(vector::borrow(&pools, 1)));

    // Create escrow with 10 cranks, 0.1 SUI per outcome per crank
    let total_subsidy = 2 * 100_000_000 * 10; // 2 SUI total
    let mut escrow = subsidy_escrow::create_test_escrow(
        proposal_id,
        dao_id,
        amm_ids,
        total_subsidy,
        10,
        ctx,
    );

    // Verify pools have zero rewards initially
    assert!(conditional_amm::get_lp_rewards(vector::borrow(&pools, 0)) == 0, 0);
    assert!(conditional_amm::get_lp_rewards(vector::borrow(&pools, 1)) == 0, 1);

    // Crank subsidy (should accumulate rewards in pools)
    let keeper_fee = subsidy_escrow::crank_subsidy(
        &mut escrow,
        proposal_id,
        &mut pools,
        &clock,
        ctx,
    );

    // Verify pools now have rewards
    let rewards0 = conditional_amm::get_lp_rewards(vector::borrow(&pools, 0));
    let rewards1 = conditional_amm::get_lp_rewards(vector::borrow(&pools, 1));

    assert!(rewards0 > 0, 2);
    assert!(rewards1 > 0, 3);

    // Both pools should receive equal rewards
    assert!(rewards0 == rewards1, 4);

    coin::burn_for_testing(keeper_fee);
    subsidy_escrow::destroy_test_escrow(escrow);
    destroy_pools(pools);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
fun test_multiple_cranks_accumulate_rewards() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    let proposal_id = object::id_from_address(@0x100);
    let dao_id = object::id_from_address(@0x200);
    let market_id = object::id_from_address(@0x300);

    let mut clock = clock::create_for_testing(ctx);
    let mut current_time = 1_000_000u64;
    clock::set_for_testing(&mut clock, current_time);

    let mut pools = create_test_pools(market_id, 2, 1_000_000_000, 1_000_000_000, &clock, ctx);

    let mut amm_ids = vector::empty<ID>();
    vector::push_back(&mut amm_ids, conditional_amm::get_id(vector::borrow(&pools, 0)));
    vector::push_back(&mut amm_ids, conditional_amm::get_id(vector::borrow(&pools, 1)));

    let total_subsidy = 2 * 100_000_000 * 10; // 2 SUI
    let mut escrow = subsidy_escrow::create_test_escrow(
        proposal_id,
        dao_id,
        amm_ids,
        total_subsidy,
        10,
        ctx,
    );

    // Do 3 cranks
    let mut crank_count = 0;
    while (crank_count < 3) {
        let fee = subsidy_escrow::crank_subsidy(&mut escrow, proposal_id, &mut pools, &clock, ctx);
        coin::burn_for_testing(fee);

        current_time = current_time + MIN_CRANK_INTERVAL_MS;
        clock::set_for_testing(&mut clock, current_time);
        crank_count = crank_count + 1;
    };

    // Verify rewards accumulated from multiple cranks
    let rewards0 = conditional_amm::get_lp_rewards(vector::borrow(&pools, 0));
    let rewards1 = conditional_amm::get_lp_rewards(vector::borrow(&pools, 1));

    // After 3 cranks, each pool should have received 3 * subsidy_per_outcome_per_crank
    // Total per pool = 3 * (crank_amount / 2 pools) where crank_amount excludes keeper fee
    assert!(rewards0 > 0, 0);
    assert!(rewards1 > 0, 1);
    assert!(rewards0 == rewards1, 2);

    subsidy_escrow::destroy_test_escrow(escrow);
    destroy_pools(pools);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

// === Reward Extraction from Multiple Pools ===

#[test]
fun test_extract_rewards_from_multiple_pools() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    let market_id = object::id_from_address(@0x300);
    let mut clock = clock::create_for_testing(ctx);
    clock::set_for_testing(&mut clock, 1_000_000);

    // Create 3 pools with different reward amounts
    let mut pools = create_test_pools(market_id, 3, 1_000_000_000, 1_000_000_000, &clock, ctx);

    // Add different rewards to each pool
    let reward1 = balance::create_for_testing<SUI>(100_000_000); // 0.1 SUI
    conditional_amm::accumulate_subsidy_rewards(vector::borrow_mut(&mut pools, 0), reward1);

    let reward2 = balance::create_for_testing<SUI>(200_000_000); // 0.2 SUI
    conditional_amm::accumulate_subsidy_rewards(vector::borrow_mut(&mut pools, 1), reward2);

    let reward3 = balance::create_for_testing<SUI>(300_000_000); // 0.3 SUI
    conditional_amm::accumulate_subsidy_rewards(vector::borrow_mut(&mut pools, 2), reward3);

    // Extract from all pools and aggregate
    let mut total_rewards = balance::zero<SUI>();

    let extract1 = conditional_amm::extract_all_rewards(vector::borrow_mut(&mut pools, 0));
    balance::join(&mut total_rewards, extract1);

    let extract2 = conditional_amm::extract_all_rewards(vector::borrow_mut(&mut pools, 1));
    balance::join(&mut total_rewards, extract2);

    let extract3 = conditional_amm::extract_all_rewards(vector::borrow_mut(&mut pools, 2));
    balance::join(&mut total_rewards, extract3);

    // Verify total = 0.6 SUI
    assert!(balance::value(&total_rewards) == 600_000_000, 0);

    // Verify all pools have zero rewards
    assert!(conditional_amm::get_lp_rewards(vector::borrow(&pools, 0)) == 0, 1);
    assert!(conditional_amm::get_lp_rewards(vector::borrow(&pools, 1)) == 0, 2);
    assert!(conditional_amm::get_lp_rewards(vector::borrow(&pools, 2)) == 0, 3);

    balance::destroy_for_testing(total_rewards);
    destroy_pools(pools);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

// === Accounting Integrity Tests ===

#[test]
fun test_reward_accounting_integrity() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    let proposal_id = object::id_from_address(@0x100);
    let dao_id = object::id_from_address(@0x200);
    let market_id = object::id_from_address(@0x300);

    let mut clock = clock::create_for_testing(ctx);
    let mut current_time = 1_000_000u64;
    clock::set_for_testing(&mut clock, current_time);

    let mut pools = create_test_pools(market_id, 2, 1_000_000_000, 1_000_000_000, &clock, ctx);

    let mut amm_ids = vector::empty<ID>();
    vector::push_back(&mut amm_ids, conditional_amm::get_id(vector::borrow(&pools, 0)));
    vector::push_back(&mut amm_ids, conditional_amm::get_id(vector::borrow(&pools, 1)));

    let total_subsidy = 2_000_000_000u64; // 2 SUI
    let total_cranks = 10u64;
    let mut escrow = subsidy_escrow::create_test_escrow(
        proposal_id,
        dao_id,
        amm_ids,
        total_subsidy,
        total_cranks,
        ctx,
    );

    let initial_escrow_balance = subsidy_escrow::escrow_remaining_balance(&escrow);

    // Do all cranks and track keeper fees
    let mut total_keeper_fees = 0u64;
    let mut crank_count = 0;
    while (crank_count < total_cranks) {
        let fee = subsidy_escrow::crank_subsidy(&mut escrow, proposal_id, &mut pools, &clock, ctx);
        total_keeper_fees = total_keeper_fees + coin::value(&fee);
        coin::burn_for_testing(fee);

        current_time = current_time + MIN_CRANK_INTERVAL_MS;
        clock::set_for_testing(&mut clock, current_time);
        crank_count = crank_count + 1;
    };

    // Extract all rewards from pools
    let extracted0 = conditional_amm::extract_all_rewards(vector::borrow_mut(&mut pools, 0));
    let extracted1 = conditional_amm::extract_all_rewards(vector::borrow_mut(&mut pools, 1));
    let total_pool_rewards = balance::value(&extracted0) + balance::value(&extracted1);

    // Finalize escrow and get remainder
    let remaining_coin = subsidy_escrow::finalize_escrow(&mut escrow, &clock, ctx);
    let remaining_balance = coin::value(&remaining_coin);

    // CRITICAL: Accounting must balance
    // initial_escrow_balance = total_keeper_fees + total_pool_rewards + remaining_balance
    let accounted_total = total_keeper_fees + total_pool_rewards + remaining_balance;
    assert!(accounted_total == initial_escrow_balance, 0);

    balance::destroy_for_testing(extracted0);
    balance::destroy_for_testing(extracted1);
    coin::burn_for_testing(remaining_coin);
    subsidy_escrow::destroy_test_escrow(escrow);
    destroy_pools(pools);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
fun test_rewards_do_not_affect_reserves() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    let market_id = object::id_from_address(@0x300);
    let mut clock = clock::create_for_testing(ctx);
    clock::set_for_testing(&mut clock, 1_000_000);

    let initial_asset = 1_000_000_000u64;
    let initial_stable = 2_000_000_000u64;
    let mut pool = create_test_pool(market_id, 0, initial_asset, initial_stable, &clock, ctx);

    // Get initial reserves and price
    let (asset_before, stable_before) = conditional_amm::get_reserves(&pool);
    let price_before = conditional_amm::get_current_price(&pool);

    // Add substantial rewards (1 SUI)
    let reward = balance::create_for_testing<SUI>(1_000_000_000);
    conditional_amm::accumulate_subsidy_rewards(&mut pool, reward);

    // Get reserves and price after rewards
    let (asset_after, stable_after) = conditional_amm::get_reserves(&pool);
    let price_after = conditional_amm::get_current_price(&pool);

    // Reserves should be unchanged
    assert!(asset_before == asset_after, 0);
    assert!(stable_before == stable_after, 1);

    // Price should be unchanged
    assert!(price_before == price_after, 2);

    // But rewards should be present
    assert!(conditional_amm::get_lp_rewards(&pool) == 1_000_000_000, 3);

    conditional_amm::destroy_for_testing(pool);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

// === Hard Backing Verification ===

#[test]
fun test_rewards_are_hard_backed() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    let proposal_id = object::id_from_address(@0x100);
    let dao_id = object::id_from_address(@0x200);
    let market_id = object::id_from_address(@0x300);

    let mut clock = clock::create_for_testing(ctx);
    clock::set_for_testing(&mut clock, 1_000_000);

    let mut pools = create_test_pools(market_id, 2, 1_000_000_000, 1_000_000_000, &clock, ctx);

    let mut amm_ids = vector::empty<ID>();
    vector::push_back(&mut amm_ids, conditional_amm::get_id(vector::borrow(&pools, 0)));
    vector::push_back(&mut amm_ids, conditional_amm::get_id(vector::borrow(&pools, 1)));

    let total_subsidy = 2_000_000_000u64;
    let mut escrow = subsidy_escrow::create_test_escrow(
        proposal_id,
        dao_id,
        amm_ids,
        total_subsidy,
        10,
        ctx,
    );

    // Crank once
    let fee = subsidy_escrow::crank_subsidy(&mut escrow, proposal_id, &mut pools, &clock, ctx);
    let keeper_fee_amount = coin::value(&fee);
    coin::burn_for_testing(fee);

    // Calculate expected distribution
    let crank_amount = total_subsidy / 10; // First crank: 200_000_000
    let subsidy_to_pools = crank_amount - keeper_fee_amount;
    let per_pool = subsidy_to_pools / 2;

    // Each pool should have hard-backed rewards equal to per_pool
    let rewards0 = conditional_amm::get_lp_rewards(vector::borrow(&pools, 0));
    let rewards1 = conditional_amm::get_lp_rewards(vector::borrow(&pools, 1));

    // Rewards should match expected distribution (allowing for rounding)
    assert!(rewards0 == per_pool, 0);
    assert!(rewards1 == per_pool, 1);

    // Extract rewards and verify they're actual Balance<SUI> objects
    let extracted0 = conditional_amm::extract_all_rewards(vector::borrow_mut(&mut pools, 0));
    let extracted1 = conditional_amm::extract_all_rewards(vector::borrow_mut(&mut pools, 1));

    // Should be able to convert to coins (proof of hard backing)
    let coin0 = coin::from_balance(extracted0, ctx);
    let coin1 = coin::from_balance(extracted1, ctx);

    assert!(coin::value(&coin0) == per_pool, 2);
    assert!(coin::value(&coin1) == per_pool, 3);

    coin::burn_for_testing(coin0);
    coin::burn_for_testing(coin1);
    subsidy_escrow::destroy_test_escrow(escrow);
    destroy_pools(pools);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}
