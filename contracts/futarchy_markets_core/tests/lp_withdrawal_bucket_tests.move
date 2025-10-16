#[test_only]
module futarchy_markets_core::lp_withdrawal_bucket_tests;

use futarchy_markets_core::quantum_lp_manager;
use futarchy_markets_core::unified_spot_pool::{Self, UnifiedSpotPool};
use futarchy_markets_primitives::coin_escrow::{Self, TokenEscrow};
use futarchy_markets_primitives::conditional_amm::{Self, LiquidityPool};
use futarchy_one_shot_utils::test_coin_a::TEST_COIN_A;
use futarchy_one_shot_utils::test_coin_b::TEST_COIN_B;
use sui::clock::{Self, Clock};
use sui::coin;
use sui::test_scenario as ts;

// === Test Helpers ===

#[test_only]
fun create_test_clock(timestamp_ms: u64, ctx: &mut TxContext): Clock {
    let mut clock = clock::create_for_testing(ctx);
    clock::set_for_testing(&mut clock, timestamp_ms);
    clock
}

// === Bucket Tracking Tests ===

#[test]
fun test_conditional_pool_bucket_fields() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    // Create a conditional pool
    let pool = conditional_amm::new<TEST_COIN_A, TEST_COIN_B>(
        30, // fee_bps
        8000, // twap_start_delay
        100000, // twap_initial_observation
        1000, // twap_step_max
        &clock,
        ctx,
    );

    // Initially buckets should be zero
    let (
        asset_live,
        asset_transitioning,
        stable_live,
        stable_transitioning,
        lp_live,
        lp_transitioning,
    ) = conditional_amm::get_bucket_amounts(&pool);

    assert!(asset_live == 0, 0);
    assert!(asset_transitioning == 0, 1);
    assert!(stable_live == 0, 2);
    assert!(stable_transitioning == 0, 3);
    assert!(lp_live == 0, 4);
    assert!(lp_transitioning == 0, 5);

    // Cleanup
    conditional_amm::destroy_for_testing(pool);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
fun test_bucket_setter_with_invariant_check() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    // Create pool with liquidity
    let mut pool = conditional_amm::new<TEST_COIN_A, TEST_COIN_B>(
        30, // fee_bps
        8000, // twap_start_delay
        100000, // twap_initial_observation
        1000, // twap_step_max
        &clock,
        ctx,
    );

    // Add liquidity
    let asset_coin = coin::mint_for_testing<TEST_COIN_A>(100_000, ctx);
    let stable_coin = coin::mint_for_testing<TEST_COIN_B>(100_000, ctx);
    let _lp_amount = conditional_amm::add_liquidity_proportional(
        &mut pool,
        100_000,
        100_000,
        0,
        &clock,
        ctx,
    );

    // Consume the liquidity (would normally go into escrow)
    conditional_amm::burn_for_testing(asset_coin);
    conditional_amm::burn_for_testing(stable_coin);

    // Get current reserves
    let (asset_reserve, stable_reserve) = conditional_amm::get_reserves(&pool);
    let lp_supply = conditional_amm::lp_supply(&pool);

    // Set buckets (split 50/50 between LIVE and TRANSITIONING)
    conditional_amm::set_bucket_amounts(
        &mut pool,
        asset_reserve / 2,
        asset_reserve / 2,
        stable_reserve / 2,
        stable_reserve / 2,
        lp_supply / 2,
        lp_supply / 2,
    );

    // Verify buckets were set correctly
    let (
        asset_live,
        asset_trans,
        stable_live,
        stable_trans,
        lp_live,
        lp_trans,
    ) = conditional_amm::get_bucket_amounts(&pool);

    assert!(asset_live + asset_trans == asset_reserve, 0);
    assert!(stable_live + stable_trans == stable_reserve, 1);
    assert!(lp_live + lp_trans == lp_supply, 2);

    // Cleanup
    conditional_amm::destroy_for_testing(pool);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
#[expected_failure] // Should fail invariant check (buckets don't sum to total)
fun test_bucket_setter_invalid_amounts() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    let mut pool = conditional_amm::new<TEST_COIN_A, TEST_COIN_B>(
        30,
        8000,
        100000,
        1000,
        &clock,
        ctx,
    );

    // Add liquidity
    let asset_coin = coin::mint_for_testing<TEST_COIN_A>(100_000, ctx);
    let stable_coin = coin::mint_for_testing<TEST_COIN_B>(100_000, ctx);
    let _lp_amount = conditional_amm::add_liquidity_proportional(
        &mut pool,
        100_000,
        100_000,
        0,
        &clock,
        ctx,
    );
    conditional_amm::burn_for_testing(asset_coin);
    conditional_amm::burn_for_testing(stable_coin);

    let (asset_reserve, stable_reserve) = conditional_amm::get_reserves(&pool);
    let lp_supply = conditional_amm::lp_supply(&pool);

    // Try to set buckets with WRONG amounts (don't sum to total)
    conditional_amm::set_bucket_amounts(
        &mut pool,
        asset_reserve / 2,
        asset_reserve / 3, // Wrong: doesn't sum to total
        stable_reserve / 2,
        stable_reserve / 2,
        lp_supply / 2,
        lp_supply / 2,
    );

    // Should fail before reaching here
    conditional_amm::destroy_for_testing(pool);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

// === Quantum Split Bucket Tests ===

#[test]
fun test_quantum_split_bucket_calculation() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    // Create spot pool with liquidity
    let mut spot_pool = unified_spot_pool::new<TEST_COIN_A, TEST_COIN_B>(30, ctx);
    let asset_coin = coin::mint_for_testing<TEST_COIN_A>(1_000_000, ctx);
    let stable_coin = coin::mint_for_testing<TEST_COIN_B>(1_000_000, ctx);
    let lp_token = unified_spot_pool::add_liquidity(
        &mut spot_pool,
        asset_coin,
        stable_coin,
        0,
        ctx,
    );

    // Mark 40% of liquidity for withdrawal (goes to TRANSITIONING)
    unified_spot_pool::mark_for_withdrawal_for_testing(&mut spot_pool, 400_000, 400_000, 0);

    // Verify bucket amounts before split
    let (spot_asset_live, spot_stable_live) = unified_spot_pool::get_live_reserves(&spot_pool);
    let (spot_asset_trans, spot_stable_trans, _) = unified_spot_pool::get_transitioning_reserves(
        &spot_pool,
    );

    assert!(spot_asset_live == 600_000, 0);
    assert!(spot_stable_live == 600_000, 1);
    assert!(spot_asset_trans == 400_000, 2);
    assert!(spot_stable_trans == 400_000, 3);

    // Create escrow for quantum split
    let mut escrow = coin_escrow::create_test_escrow<TEST_COIN_A, TEST_COIN_B>(2, ctx);

    // Quantum split with 50% DAO ratio
    // LIVE: 50% of 600k = 300k
    // TRANSITIONING: 100% of 400k = 400k
    quantum_lp_manager::auto_quantum_split_on_proposal_start(
        &mut spot_pool,
        &mut escrow,
        50, // 50% DAO ratio
        &clock,
        ctx,
    );

    // Verify conditional pool buckets were set correctly
    // (In real scenario, we'd check the conditional pools created by quantum split)
    // For now, verify spot pool was depleted of the right amounts
    let (asset_reserve, stable_reserve) = unified_spot_pool::get_reserves(&spot_pool);
    let (spot_asset_live2, spot_stable_live2) = unified_spot_pool::get_live_reserves(&spot_pool);

    // LIVE should be reduced by 50% (300k removed, 300k remains)
    // TRANSITIONING should be fully removed (400k removed, 0 remains)
    assert!(spot_asset_live2 == 300_000, 4); // 600k - 300k
    assert!(spot_stable_live2 == 300_000, 5);

    // Cleanup
    unified_spot_pool::destroy_lp_token_for_testing(lp_token);
    unified_spot_pool::destroy_for_testing(spot_pool);
    coin_escrow::destroy_for_testing(escrow);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

// === Bucket-Aware Recombination Tests ===

#[test]
fun test_bucket_aware_recombination() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    // Create spot pool
    let mut spot_pool = unified_spot_pool::new<TEST_COIN_A, TEST_COIN_B>(30, ctx);

    // Simulate recombination from conditional pool
    // conditional.LIVE (200k) → spot.LIVE
    // conditional.TRANSITIONING (100k) → spot.WITHDRAW_ONLY
    let asset_coin = coin::mint_for_testing<TEST_COIN_A>(300_000, ctx);
    let stable_coin = coin::mint_for_testing<TEST_COIN_B>(300_000, ctx);

    unified_spot_pool::add_liquidity_from_quantum_redeem_with_buckets(
        &mut spot_pool,
        coin::into_balance(asset_coin),
        coin::into_balance(stable_coin),
        200_000, // asset_live
        100_000, // asset_transitioning
        200_000, // stable_live
        100_000, // stable_transitioning
    );

    // Verify buckets were populated correctly
    let (asset_live, stable_live) = unified_spot_pool::get_live_reserves(&spot_pool);
    let (asset_withdraw, stable_withdraw, _) = unified_spot_pool::get_withdraw_only_reserves(
        &spot_pool,
    );

    assert!(asset_live == 200_000, 0);
    assert!(stable_live == 200_000, 1);
    assert!(asset_withdraw == 100_000, 2);
    assert!(stable_withdraw == 100_000, 3);

    // Cleanup
    unified_spot_pool::destroy_for_testing(spot_pool);
    ts::end(scenario);
}

#[test]
#[expected_failure] // Should fail invariant check
fun test_bucket_aware_recombination_invalid_amounts() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    let mut spot_pool = unified_spot_pool::new<TEST_COIN_A, TEST_COIN_B>(30, ctx);

    let asset_coin = coin::mint_for_testing<TEST_COIN_A>(300_000, ctx);
    let stable_coin = coin::mint_for_testing<TEST_COIN_B>(300_000, ctx);

    // Buckets don't sum to total (200k + 50k != 300k)
    unified_spot_pool::add_liquidity_from_quantum_redeem_with_buckets(
        &mut spot_pool,
        coin::into_balance(asset_coin),
        coin::into_balance(stable_coin),
        200_000, // asset_live
        50_000, // asset_transitioning (WRONG: should be 100k)
        200_000, // stable_live
        100_000, // stable_transitioning
    );

    unified_spot_pool::destroy_for_testing(spot_pool);
    ts::end(scenario);
}

// === Crank Transition Tests ===

#[test]
fun test_transition_to_withdraw_only() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    // Create spot pool
    let mut spot_pool = unified_spot_pool::new<TEST_COIN_A, TEST_COIN_B>(30, ctx);

    // Add liquidity to LIVE and TRANSITIONING buckets
    let asset_coin = coin::mint_for_testing<TEST_COIN_A>(500_000, ctx);
    let stable_coin = coin::mint_for_testing<TEST_COIN_B>(500_000, ctx);
    let lp_token = unified_spot_pool::add_liquidity(
        &mut spot_pool,
        asset_coin,
        stable_coin,
        0,
        ctx,
    );

    // Mark some for withdrawal (goes to TRANSITIONING)
    unified_spot_pool::mark_for_withdrawal_for_testing(&mut spot_pool, 200_000, 200_000, 0);

    // Verify TRANSITIONING bucket has amounts
    let (
        asset_trans_before,
        stable_trans_before,
        lp_trans_before,
    ) = unified_spot_pool::get_transitioning_reserves(&spot_pool);
    assert!(asset_trans_before == 200_000, 0);
    assert!(stable_trans_before == 200_000, 1);

    // Call crank to transition TRANSITIONING → WITHDRAW_ONLY
    unified_spot_pool::transition_to_withdraw_only(&mut spot_pool);

    // Verify TRANSITIONING is now zero
    let (
        asset_trans_after,
        stable_trans_after,
        lp_trans_after,
    ) = unified_spot_pool::get_transitioning_reserves(&spot_pool);
    assert!(asset_trans_after == 0, 2);
    assert!(stable_trans_after == 0, 3);
    assert!(lp_trans_after == 0, 4);

    // Verify WITHDRAW_ONLY has the amounts
    let (
        asset_withdraw,
        stable_withdraw,
        lp_withdraw,
    ) = unified_spot_pool::get_withdraw_only_reserves(&spot_pool);
    assert!(asset_withdraw == 200_000, 5);
    assert!(stable_withdraw == 200_000, 6);

    // Cleanup
    unified_spot_pool::destroy_lp_token_for_testing(lp_token);
    unified_spot_pool::destroy_for_testing(spot_pool);
    ts::end(scenario);
}

// === Integration Test: Complete LP Withdrawal Flow ===

#[test]
fun test_complete_lp_withdrawal_flow() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    // 1. Create spot pool with initial liquidity (1M each)
    let mut spot_pool = unified_spot_pool::new<TEST_COIN_A, TEST_COIN_B>(30, ctx);
    let asset_coin = coin::mint_for_testing<TEST_COIN_A>(1_000_000, ctx);
    let stable_coin = coin::mint_for_testing<TEST_COIN_B>(1_000_000, ctx);
    let lp_token = unified_spot_pool::add_liquidity(
        &mut spot_pool,
        asset_coin,
        stable_coin,
        0,
        ctx,
    );

    // 2. LP marks 400k for withdrawal during active proposal
    unified_spot_pool::mark_for_withdrawal_for_testing(&mut spot_pool, 400_000, 400_000, 0);
    let (spot_asset_live, spot_stable_live) = unified_spot_pool::get_live_reserves(&spot_pool);
    let (spot_asset_trans, spot_stable_trans, _) = unified_spot_pool::get_transitioning_reserves(
        &spot_pool,
    );
    assert!(spot_asset_live == 600_000, 0);
    assert!(spot_asset_trans == 400_000, 1);

    // 3. Proposal starts → Quantum split
    // LIVE: 50% of 600k = 300k to conditional
    // TRANSITIONING: 100% of 400k = 400k to conditional
    let mut escrow = coin_escrow::create_test_escrow<TEST_COIN_A, TEST_COIN_B>(2, ctx);
    quantum_lp_manager::auto_quantum_split_on_proposal_start(
        &mut spot_pool,
        &mut escrow,
        50, // 50% DAO ratio
        &clock,
        ctx,
    );

    // Verify spot pool has reduced reserves
    let (spot_asset_live2, spot_stable_live2) = unified_spot_pool::get_live_reserves(&spot_pool);
    assert!(spot_asset_live2 == 300_000, 2); // 600k - 300k

    // 4. Proposal ends → Recombine winning conditional liquidity
    // Simulate recombination: 300k LIVE + 400k TRANSITIONING
    let asset_recombine = coin::mint_for_testing<TEST_COIN_A>(700_000, ctx);
    let stable_recombine = coin::mint_for_testing<TEST_COIN_B>(700_000, ctx);

    unified_spot_pool::add_liquidity_from_quantum_redeem_with_buckets(
        &mut spot_pool,
        coin::into_balance(asset_recombine),
        coin::into_balance(stable_recombine),
        300_000, // asset_live (goes to LIVE)
        400_000, // asset_transitioning (goes to WITHDRAW_ONLY)
        300_000, // stable_live
        400_000, // stable_transitioning
    );

    // Verify buckets after recombination
    let (asset_live3, stable_live3) = unified_spot_pool::get_live_reserves(&spot_pool);
    let (asset_withdraw, stable_withdraw, _) = unified_spot_pool::get_withdraw_only_reserves(
        &spot_pool,
    );
    assert!(asset_live3 == 600_000, 3); // 300k original + 300k recombined
    assert!(asset_withdraw == 400_000, 4); // conditional.TRANSITIONING → spot.WITHDRAW_ONLY

    // 5. Crank transitions spot.TRANSITIONING → spot.WITHDRAW_ONLY
    // (In this test, recombination already went to WITHDRAW_ONLY, so crank would be no-op)
    unified_spot_pool::transition_to_withdraw_only(&mut spot_pool);

    // 6. Verify final state: LP can now claim from WITHDRAW_ONLY bucket
    let (
        final_withdraw_asset,
        final_withdraw_stable,
        _,
    ) = unified_spot_pool::get_withdraw_only_reserves(&spot_pool);
    assert!(final_withdraw_asset == 400_000, 5);
    assert!(final_withdraw_stable == 400_000, 6);

    // Cleanup
    unified_spot_pool::destroy_lp_token_for_testing(lp_token);
    unified_spot_pool::destroy_for_testing(spot_pool);
    coin_escrow::destroy_for_testing(escrow);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

// === Test Edge Cases ===

#[test]
fun test_all_liquidity_transitioning() {
    // Test case where ALL liquidity is marked for withdrawal
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    let mut spot_pool = unified_spot_pool::new<TEST_COIN_A, TEST_COIN_B>(30, ctx);
    let asset_coin = coin::mint_for_testing<TEST_COIN_A>(1_000_000, ctx);
    let stable_coin = coin::mint_for_testing<TEST_COIN_B>(1_000_000, ctx);
    let lp_token = unified_spot_pool::add_liquidity(
        &mut spot_pool,
        asset_coin,
        stable_coin,
        0,
        ctx,
    );

    // Mark ALL liquidity for withdrawal
    unified_spot_pool::mark_for_withdrawal_for_testing(&mut spot_pool, 1_000_000, 1_000_000, 0);

    let (spot_asset_live, _) = unified_spot_pool::get_live_reserves(&spot_pool);
    let (spot_asset_trans, _, _) = unified_spot_pool::get_transitioning_reserves(&spot_pool);

    assert!(spot_asset_live == 0, 0);
    assert!(spot_asset_trans == 1_000_000, 1);

    // Cleanup
    unified_spot_pool::destroy_lp_token_for_testing(lp_token);
    unified_spot_pool::destroy_for_testing(spot_pool);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
fun test_no_liquidity_transitioning() {
    // Test case where NO liquidity is marked for withdrawal
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    let mut spot_pool = unified_spot_pool::new<TEST_COIN_A, TEST_COIN_B>(30, ctx);
    let asset_coin = coin::mint_for_testing<TEST_COIN_A>(1_000_000, ctx);
    let stable_coin = coin::mint_for_testing<TEST_COIN_B>(1_000_000, ctx);
    let lp_token = unified_spot_pool::add_liquidity(
        &mut spot_pool,
        asset_coin,
        stable_coin,
        0,
        ctx,
    );

    // Don't mark any liquidity for withdrawal
    let (spot_asset_live, _) = unified_spot_pool::get_live_reserves(&spot_pool);
    let (spot_asset_trans, _, _) = unified_spot_pool::get_transitioning_reserves(&spot_pool);

    assert!(spot_asset_live == 1_000_000, 0);
    assert!(spot_asset_trans == 0, 1);

    // Transition to withdraw-only should be no-op
    unified_spot_pool::transition_to_withdraw_only(&mut spot_pool);

    let (asset_withdraw, _, _) = unified_spot_pool::get_withdraw_only_reserves(&spot_pool);
    assert!(asset_withdraw == 0, 2);

    // Cleanup
    unified_spot_pool::destroy_lp_token_for_testing(lp_token);
    unified_spot_pool::destroy_for_testing(spot_pool);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}
