#[test_only]
module futarchy_markets::spot_amm_tests;

use futarchy_markets::spot_amm::{Self, SpotAMM, SpotLP};
use sui::test_scenario::{Self as ts};
use sui::clock::{Self, Clock};
use sui::coin::{Self};

// Test coin types
public struct ASSET has drop {}
public struct STABLE has drop {}

// Helper to setup test scenario
fun setup_test(sender: address): (ts::Scenario, Clock) {
    let mut scenario = ts::begin(sender);
    ts::next_tx(&mut scenario, sender);
    let ctx = ts::ctx(&mut scenario);
    let clock = clock::create_for_testing(ctx);
    (scenario, clock)
}

// === Basic Pool Creation Tests ===

#[test]
fun test_create_pool() {
    let sender = @0xA;
    let (mut scenario, clock) = setup_test(sender);

    ts::next_tx(&mut scenario, sender);
    {
        let ctx = ts::ctx(&mut scenario);
        let pool = spot_amm::new<ASSET, STABLE>(30, ctx);  // 0.3% fee

        // Verify pool created with zero reserves
        let (asset_res, stable_res) = spot_amm::get_reserves(&pool);
        assert!(asset_res == 0, 0);
        assert!(stable_res == 0, 1);

        transfer::public_transfer(pool, sender);
    };

    clock.destroy_for_testing();
    ts::end(scenario);
}

#[test]
fun test_add_liquidity_first_time() {
    let sender = @0xA;
    let (mut scenario, mut clock) = setup_test(sender);

    ts::next_tx(&mut scenario, sender);
    {
        let ctx = ts::ctx(&mut scenario);
        let pool = spot_amm::new<ASSET, STABLE>(30, ctx);
        transfer::public_share_object(pool);
    };

    ts::next_tx(&mut scenario, sender);
    {
        let mut pool = ts::take_shared<SpotAMM<ASSET, STABLE>>(&scenario);
        let ctx = ts::ctx(&mut scenario);

        // Mint coins for liquidity
        let asset_coin = coin::mint_for_testing<ASSET>(1_000_000, ctx);
        let stable_coin = coin::mint_for_testing<STABLE>(10_000_000, ctx);

        // Add liquidity (first time - establishes price ratio)
        spot_amm::add_liquidity(
            &mut pool,
            asset_coin,
            stable_coin,
            0,  // min_lp_out (first time accepts any)
            &clock,
            ctx
        );

        // Verify reserves
        let (asset_res, stable_res) = spot_amm::get_reserves(&pool);
        assert!(asset_res == 1_000_000, 0);
        assert!(stable_res == 10_000_000, 1);

        ts::return_shared(pool);
    };

    // Check LP token received
    ts::next_tx(&mut scenario, sender);
    {
        let lp = ts::take_from_sender<SpotLP<ASSET, STABLE>>(&scenario);
        let lp_amount = spot_amm::get_lp_amount(&lp);
        // First LP gets sqrt(x*y) - MINIMUM_LIQUIDITY
        // sqrt(1M * 10M) = sqrt(10^13) ≈ 3,162,277
        // Minus 1000 minimum liquidity = 3,161,277
        assert!(lp_amount > 3_000_000, 0);
        assert!(lp_amount < 3_200_000, 1);
        ts::return_to_sender(&scenario, lp);
    };

    clock.destroy_for_testing();
    ts::end(scenario);
}

#[test]
fun test_add_liquidity_second_time() {
    let sender = @0xA;
    let (mut scenario, mut clock) = setup_test(sender);

    // Create pool
    ts::next_tx(&mut scenario, sender);
    {
        let ctx = ts::ctx(&mut scenario);
        let pool = spot_amm::new<ASSET, STABLE>(30, ctx);
        transfer::public_share_object(pool);
    };

    // Add initial liquidity
    ts::next_tx(&mut scenario, sender);
    {
        let mut pool = ts::take_shared<SpotAMM<ASSET, STABLE>>(&scenario);
        let ctx = ts::ctx(&mut scenario);
        let asset_coin = coin::mint_for_testing<ASSET>(1_000_000, ctx);
        let stable_coin = coin::mint_for_testing<STABLE>(10_000_000, ctx);
        spot_amm::add_liquidity(&mut pool, asset_coin, stable_coin, 0, &clock, ctx);
        ts::return_shared(pool);
    };

    // Add second liquidity (proportional)
    ts::next_tx(&mut scenario, sender);
    {
        let mut pool = ts::take_shared<SpotAMM<ASSET, STABLE>>(&scenario);
        let ctx = ts::ctx(&mut scenario);
        let asset_coin = coin::mint_for_testing<ASSET>(500_000, ctx);  // Half of initial
        let stable_coin = coin::mint_for_testing<STABLE>(5_000_000, ctx);  // Half of initial
        spot_amm::add_liquidity(&mut pool, asset_coin, stable_coin, 0, &clock, ctx);

        // Verify reserves increased
        let (asset_res, stable_res) = spot_amm::get_reserves(&pool);
        assert!(asset_res == 1_500_000, 0);
        assert!(stable_res == 15_000_000, 1);

        ts::return_shared(pool);
    };

    clock.destroy_for_testing();
    ts::end(scenario);
}

// === Swap Tests ===

#[test]
fun test_swap_asset_for_stable() {
    let sender = @0xA;
    let (mut scenario, mut clock) = setup_test(sender);

    // Create pool and add liquidity
    ts::next_tx(&mut scenario, sender);
    {
        let ctx = ts::ctx(&mut scenario);
        let pool = spot_amm::new<ASSET, STABLE>(30, ctx);
        transfer::public_share_object(pool);
    };

    ts::next_tx(&mut scenario, sender);
    {
        let mut pool = ts::take_shared<SpotAMM<ASSET, STABLE>>(&scenario);
        let ctx = ts::ctx(&mut scenario);
        let asset_coin = coin::mint_for_testing<ASSET>(1_000_000, ctx);
        let stable_coin = coin::mint_for_testing<STABLE>(10_000_000, ctx);
        spot_amm::add_liquidity(&mut pool, asset_coin, stable_coin, 0, &clock, ctx);
        ts::return_shared(pool);
    };

    // Perform swap
    ts::next_tx(&mut scenario, sender);
    {
        let mut pool = ts::take_shared<SpotAMM<ASSET, STABLE>>(&scenario);
        let ctx = ts::ctx(&mut scenario);
        let asset_in = coin::mint_for_testing<ASSET>(100_000, ctx);

        spot_amm::swap_asset_for_stable(
            &mut pool,
            asset_in,
            0,  // min_stable_out (no slippage check for test)
            &clock,
            ctx
        );

        // Verify reserves changed
        let (asset_res, stable_res) = spot_amm::get_reserves(&pool);
        assert!(asset_res > 1_000_000, 0);  // Asset increased
        assert!(stable_res < 10_000_000, 1);  // Stable decreased

        ts::return_shared(pool);
    };

    // Check received stable coins
    ts::next_tx(&mut scenario, sender);
    {
        let stable_out = ts::take_from_sender<coin::Coin<STABLE>>(&scenario);
        let amount = coin::value(&stable_out);
        // With 100k asset in and 1M:10M ratio, expect ~800-900k stable out (after fees)
        assert!(amount > 800_000, 0);
        assert!(amount < 910_000, 1);
        ts::return_to_sender(&scenario, stable_out);
    };

    clock.destroy_for_testing();
    ts::end(scenario);
}

#[test]
fun test_swap_stable_for_asset() {
    let sender = @0xA;
    let (mut scenario, mut clock) = setup_test(sender);

    // Create pool and add liquidity
    ts::next_tx(&mut scenario, sender);
    {
        let ctx = ts::ctx(&mut scenario);
        let pool = spot_amm::new<ASSET, STABLE>(30, ctx);
        transfer::public_share_object(pool);
    };

    ts::next_tx(&mut scenario, sender);
    {
        let mut pool = ts::take_shared<SpotAMM<ASSET, STABLE>>(&scenario);
        let ctx = ts::ctx(&mut scenario);
        let asset_coin = coin::mint_for_testing<ASSET>(1_000_000, ctx);
        let stable_coin = coin::mint_for_testing<STABLE>(10_000_000, ctx);
        spot_amm::add_liquidity(&mut pool, asset_coin, stable_coin, 0, &clock, ctx);
        ts::return_shared(pool);
    };

    // Perform swap
    ts::next_tx(&mut scenario, sender);
    {
        let mut pool = ts::take_shared<SpotAMM<ASSET, STABLE>>(&scenario);
        let ctx = ts::ctx(&mut scenario);
        let stable_in = coin::mint_for_testing<STABLE>(1_000_000, ctx);

        spot_amm::swap_stable_for_asset(
            &mut pool,
            stable_in,
            0,  // min_asset_out
            &clock,
            ctx
        );

        // Verify reserves changed
        let (asset_res, stable_res) = spot_amm::get_reserves(&pool);
        assert!(asset_res < 1_000_000, 0);  // Asset decreased
        assert!(stable_res > 10_000_000, 1);  // Stable increased

        ts::return_shared(pool);
    };

    // Check received asset coins
    ts::next_tx(&mut scenario, sender);
    {
        let asset_out = ts::take_from_sender<coin::Coin<ASSET>>(&scenario);
        let amount = coin::value(&asset_out);
        // With 1M stable in and 1M:10M ratio, expect ~80-90k asset out (after fees)
        assert!(amount > 80_000, 0);
        assert!(amount < 91_000, 1);
        ts::return_to_sender(&scenario, asset_out);
    };

    clock.destroy_for_testing();
    ts::end(scenario);
}

// === Liquidity Removal Tests ===

#[test]
fun test_remove_liquidity() {
    let sender = @0xA;
    let (mut scenario, mut clock) = setup_test(sender);

    // Create pool and add liquidity
    ts::next_tx(&mut scenario, sender);
    {
        let ctx = ts::ctx(&mut scenario);
        let pool = spot_amm::new<ASSET, STABLE>(30, ctx);
        transfer::public_share_object(pool);
    };

    ts::next_tx(&mut scenario, sender);
    {
        let mut pool = ts::take_shared<SpotAMM<ASSET, STABLE>>(&scenario);
        let ctx = ts::ctx(&mut scenario);
        let asset_coin = coin::mint_for_testing<ASSET>(1_000_000, ctx);
        let stable_coin = coin::mint_for_testing<STABLE>(10_000_000, ctx);
        spot_amm::add_liquidity(&mut pool, asset_coin, stable_coin, 0, &clock, ctx);
        ts::return_shared(pool);
    };

    // Remove all liquidity
    ts::next_tx(&mut scenario, sender);
    {
        let mut pool = ts::take_shared<SpotAMM<ASSET, STABLE>>(&scenario);
        let lp = ts::take_from_sender<SpotLP<ASSET, STABLE>>(&scenario);
        let ctx = ts::ctx(&mut scenario);

        spot_amm::remove_liquidity(
            &mut pool,
            lp,
            0,  // min_asset_out
            0,  // min_stable_out
            &clock,
            ctx
        );

        // Verify reserves decreased (some minimum liquidity remains locked)
        let (asset_res, stable_res) = spot_amm::get_reserves(&pool);
        // Should be close to zero but minimum liquidity (1000) remains locked
        assert!(asset_res < 5_000, 0);  // Very small remaining
        assert!(stable_res < 50_000, 1);  // Very small remaining

        ts::return_shared(pool);
    };

    clock.destroy_for_testing();
    ts::end(scenario);
}

// === Price and TWAP Tests ===

#[test]
fun test_get_spot_price() {
    let sender = @0xA;
    let (mut scenario, mut clock) = setup_test(sender);

    ts::next_tx(&mut scenario, sender);
    {
        let ctx = ts::ctx(&mut scenario);
        let pool = spot_amm::new<ASSET, STABLE>(30, ctx);
        transfer::public_share_object(pool);
    };

    ts::next_tx(&mut scenario, sender);
    {
        let mut pool = ts::take_shared<SpotAMM<ASSET, STABLE>>(&scenario);
        let ctx = ts::ctx(&mut scenario);
        let asset_coin = coin::mint_for_testing<ASSET>(1_000_000, ctx);
        let stable_coin = coin::mint_for_testing<STABLE>(10_000_000, ctx);
        spot_amm::add_liquidity(&mut pool, asset_coin, stable_coin, 0, &clock, ctx);

        // Get spot price (stable/asset ratio)
        let price = spot_amm::get_spot_price(&pool);
        // Price should be roughly 10 (10M stable / 1M asset)
        // Scaled by PRICE_SCALE (10^12)
        // Expected: 10 * 10^12 = 10_000_000_000_000
        assert!(price > 9_000_000_000_000, 0);  // ~9
        assert!(price < 11_000_000_000_000, 1);  // ~11

        ts::return_shared(pool);
    };

    clock.destroy_for_testing();
    ts::end(scenario);
}

#[test]
fun test_price_changes_after_swap() {
    let sender = @0xA;
    let (mut scenario, mut clock) = setup_test(sender);

    ts::next_tx(&mut scenario, sender);
    {
        let ctx = ts::ctx(&mut scenario);
        let pool = spot_amm::new<ASSET, STABLE>(30, ctx);
        transfer::public_share_object(pool);
    };

    ts::next_tx(&mut scenario, sender);
    {
        let mut pool = ts::take_shared<SpotAMM<ASSET, STABLE>>(&scenario);
        let ctx = ts::ctx(&mut scenario);
        let asset_coin = coin::mint_for_testing<ASSET>(1_000_000, ctx);
        let stable_coin = coin::mint_for_testing<STABLE>(10_000_000, ctx);
        spot_amm::add_liquidity(&mut pool, asset_coin, stable_coin, 0, &clock, ctx);

        // Get initial price
        let price_before = spot_amm::get_spot_price(&pool);

        // Swap asset for stable (increases asset reserve, decreases stable reserve)
        // This should DECREASE price (stable/asset ratio goes down)
        let asset_in = coin::mint_for_testing<ASSET>(100_000, ctx);
        spot_amm::swap_asset_for_stable(&mut pool, asset_in, 0, &clock, ctx);

        // Get new price
        let price_after = spot_amm::get_spot_price(&pool);

        // Price should have decreased
        assert!(price_after < price_before, 0);

        ts::return_shared(pool);
    };

    clock.destroy_for_testing();
    ts::end(scenario);
}

// === Edge Case Tests ===

#[test]
fun test_minimum_liquidity_locked() {
    let sender = @0xA;
    let (mut scenario, mut clock) = setup_test(sender);

    ts::next_tx(&mut scenario, sender);
    {
        let ctx = ts::ctx(&mut scenario);
        let pool = spot_amm::new<ASSET, STABLE>(30, ctx);
        transfer::public_share_object(pool);
    };

    ts::next_tx(&mut scenario, sender);
    {
        let mut pool = ts::take_shared<SpotAMM<ASSET, STABLE>>(&scenario);
        let ctx = ts::ctx(&mut scenario);
        let asset_coin = coin::mint_for_testing<ASSET>(100_000, ctx);
        let stable_coin = coin::mint_for_testing<STABLE>(100_000, ctx);
        spot_amm::add_liquidity(&mut pool, asset_coin, stable_coin, 0, &clock, ctx);

        // Check LP received
        ts::return_shared(pool);
    };

    ts::next_tx(&mut scenario, sender);
    {
        let lp = ts::take_from_sender<SpotLP<ASSET, STABLE>>(&scenario);
        let lp_amount = spot_amm::get_lp_amount(&lp);

        // First LP gets sqrt(x*y) - MINIMUM_LIQUIDITY (1000)
        // sqrt(100k * 100k) = 100k
        // So LP should get 100k - 1k = 99k
        assert!(lp_amount == 99_000, 0);

        ts::return_to_sender(&scenario, lp);
    };

    clock.destroy_for_testing();
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = 1)]  // EZeroAmount
fun test_swap_zero_amount_fails() {
    let sender = @0xA;
    let (mut scenario, mut clock) = setup_test(sender);

    ts::next_tx(&mut scenario, sender);
    {
        let ctx = ts::ctx(&mut scenario);
        let pool = spot_amm::new<ASSET, STABLE>(30, ctx);
        transfer::public_share_object(pool);
    };

    ts::next_tx(&mut scenario, sender);
    {
        let mut pool = ts::take_shared<SpotAMM<ASSET, STABLE>>(&scenario);
        let ctx = ts::ctx(&mut scenario);
        let asset_coin = coin::mint_for_testing<ASSET>(1_000_000, ctx);
        let stable_coin = coin::mint_for_testing<STABLE>(10_000_000, ctx);
        spot_amm::add_liquidity(&mut pool, asset_coin, stable_coin, 0, &clock, ctx);

        // Try to swap zero amount - should fail
        let zero_coin = coin::zero<ASSET>(ctx);
        spot_amm::swap_asset_for_stable(&mut pool, zero_coin, 0, &clock, ctx);

        ts::return_shared(pool);
    };

    clock.destroy_for_testing();
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = 3)]  // ESlippageExceeded
fun test_remove_liquidity_slippage_protection() {
    let sender = @0xA;
    let (mut scenario, mut clock) = setup_test(sender);

    ts::next_tx(&mut scenario, sender);
    {
        let ctx = ts::ctx(&mut scenario);
        let pool = spot_amm::new<ASSET, STABLE>(30, ctx);
        transfer::public_share_object(pool);
    };

    ts::next_tx(&mut scenario, sender);
    {
        let mut pool = ts::take_shared<SpotAMM<ASSET, STABLE>>(&scenario);
        let ctx = ts::ctx(&mut scenario);
        let asset_coin = coin::mint_for_testing<ASSET>(1_000_000, ctx);
        let stable_coin = coin::mint_for_testing<STABLE>(10_000_000, ctx);
        spot_amm::add_liquidity(&mut pool, asset_coin, stable_coin, 0, &clock, ctx);
        ts::return_shared(pool);
    };

    ts::next_tx(&mut scenario, sender);
    {
        let mut pool = ts::take_shared<SpotAMM<ASSET, STABLE>>(&scenario);
        let lp = ts::take_from_sender<SpotLP<ASSET, STABLE>>(&scenario);
        let ctx = ts::ctx(&mut scenario);

        // Try to remove with impossibly high min_asset_out
        spot_amm::remove_liquidity(
            &mut pool,
            lp,
            10_000_000,  // min_asset_out way too high
            0,
            &clock,
            ctx
        );

        ts::return_shared(pool);
    };

    clock.destroy_for_testing();
    ts::end(scenario);
}
