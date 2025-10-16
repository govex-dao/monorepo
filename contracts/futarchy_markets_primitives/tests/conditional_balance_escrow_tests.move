#[test_only]
module futarchy_markets_primitives::conditional_balance_escrow_tests;

use futarchy_markets_primitives::coin_escrow;
use futarchy_markets_primitives::cond0_asset::{Self, COND0_ASSET};
use futarchy_markets_primitives::cond0_stable::{Self, COND0_STABLE};
use futarchy_markets_primitives::cond1_asset::{Self, COND1_ASSET};
use futarchy_markets_primitives::cond1_stable::{Self, COND1_STABLE};
use futarchy_markets_primitives::conditional_balance;
use futarchy_markets_primitives::market_state;
use sui::coin::{Self, TreasuryCap, CoinMetadata};
use sui::object::{Self, ID};
use sui::sui::SUI;
use sui::test_scenario as ts;
use sui::test_utils::destroy;

// Test coin types
public struct USDC has drop {}

const ADMIN: address = @0xAD;

// === Test Helpers ===

fun start(): ts::Scenario {
    ts::begin(ADMIN)
}

fun end(scenario: ts::Scenario) {
    let effects = ts::end(scenario);
    destroy(effects);
}

// === Setup Helper ===

/// Creates escrow and registers conditional caps for 2-outcome market
/// Returns (market_id, escrow)
fun setup_escrow_with_caps(scenario: &mut ts::Scenario): (ID, coin_escrow::TokenEscrow<SUI, USDC>) {
    // Initialize conditional coin types (creates TreasuryCaps and transfers to sender)
    cond0_asset::init_for_testing(ts::ctx(scenario));
    cond0_stable::init_for_testing(ts::ctx(scenario));
    cond1_asset::init_for_testing(ts::ctx(scenario));
    cond1_stable::init_for_testing(ts::ctx(scenario));

    // Advance transaction to retrieve created objects
    ts::next_tx(scenario, ADMIN);

    // Take TreasuryCaps and metadata from sender
    let cond0_asset_cap = ts::take_from_sender<TreasuryCap<COND0_ASSET>>(scenario);
    let cond0_asset_metadata = ts::take_from_sender<CoinMetadata<COND0_ASSET>>(scenario);
    let cond0_stable_cap = ts::take_from_sender<TreasuryCap<COND0_STABLE>>(scenario);
    let cond0_stable_metadata = ts::take_from_sender<CoinMetadata<COND0_STABLE>>(scenario);
    let cond1_asset_cap = ts::take_from_sender<TreasuryCap<COND1_ASSET>>(scenario);
    let cond1_asset_metadata = ts::take_from_sender<CoinMetadata<COND1_ASSET>>(scenario);
    let cond1_stable_cap = ts::take_from_sender<TreasuryCap<COND1_STABLE>>(scenario);
    let cond1_stable_metadata = ts::take_from_sender<CoinMetadata<COND1_STABLE>>(scenario);

    // Create market state for 2 outcomes
    let market_state = market_state::create_for_testing(2, ts::ctx(scenario));
    let market_id = market_state::market_id(&market_state);

    // Create escrow (consumes market_state)
    let mut escrow = coin_escrow::new<SUI, USDC>(market_state, ts::ctx(scenario));

    // Register conditional caps for outcome 0
    coin_escrow::register_conditional_caps<SUI, USDC, COND0_ASSET, COND0_STABLE>(
        &mut escrow,
        0,
        cond0_asset_cap,
        cond0_stable_cap,
    );

    // Register conditional caps for outcome 1
    coin_escrow::register_conditional_caps<SUI, USDC, COND1_ASSET, COND1_STABLE>(
        &mut escrow,
        1,
        cond1_asset_cap,
        cond1_stable_cap,
    );

    // Destroy metadata (not needed for tests)
    destroy(cond0_asset_metadata);
    destroy(cond0_stable_metadata);
    destroy(cond1_asset_metadata);
    destroy(cond1_stable_metadata);

    (market_id, escrow)
}

// === unwrap_to_coin Tests ===

#[test]
fun test_unwrap_to_coin_basic() {
    let mut scenario = start();

    let (market_id, mut escrow) = setup_escrow_with_caps(&mut scenario);
    // market_id already available

    // Create balance and set some amount
    let mut balance = conditional_balance::new<SUI, USDC>(
        market_id,
        2,
        ts::ctx(&mut scenario),
    );

    conditional_balance::set_balance(&mut balance, 0, true, 1000);

    // Unwrap to coin
    let coin = conditional_balance::unwrap_to_coin<SUI, USDC, COND0_ASSET>(
        &mut balance,
        &mut escrow,
        0,
        true,
        ts::ctx(&mut scenario),
    );

    // Verify coin amount
    assert!(coin.value() == 1000, 0);

    // Verify balance is now zero
    assert!(conditional_balance::get_balance(&balance, 0, true) == 0, 1);

    // Cleanup
    coin::burn_for_testing(coin);
    conditional_balance::destroy_empty(balance);
    coin_escrow::destroy_for_testing(escrow);

    end(scenario);
}

#[test]
fun test_unwrap_to_coin_stable() {
    let mut scenario = start();

    let (market_id, mut escrow) = setup_escrow_with_caps(&mut scenario);
    // market_id already available

    // Create balance with stable balance
    let mut balance = conditional_balance::new<SUI, USDC>(
        market_id,
        2,
        ts::ctx(&mut scenario),
    );

    conditional_balance::set_balance(&mut balance, 1, false, 5000);

    // Unwrap stable coin
    let coin = conditional_balance::unwrap_to_coin<SUI, USDC, COND1_STABLE>(
        &mut balance,
        &mut escrow,
        1,
        false,
        ts::ctx(&mut scenario),
    );

    // Verify
    assert!(coin.value() == 5000, 0);
    assert!(conditional_balance::get_balance(&mut balance, 1, false) == 0, 1);

    // Cleanup
    coin::burn_for_testing(coin);
    conditional_balance::destroy_empty(balance);
    coin_escrow::destroy_for_testing(escrow);

    end(scenario);
}

#[test]
#[expected_failure(abort_code = conditional_balance::EProposalMismatch)]
fun test_unwrap_wrong_market_fails() {
    let mut scenario = start();

    let (market_id, mut escrow) = setup_escrow_with_caps(&mut scenario);

    // Create balance for DIFFERENT market
    let wrong_market_id = object::id_from_address(@0x9999);
    let mut balance = conditional_balance::new<SUI, USDC>(
        wrong_market_id,
        2,
        ts::ctx(&mut scenario),
    );

    conditional_balance::set_balance(&mut balance, 0, true, 1000);

    // Try to unwrap - should fail with EProposalMismatch
    let coin = conditional_balance::unwrap_to_coin<SUI, USDC, COND0_ASSET>(
        &mut balance,
        &mut escrow,
        0,
        true,
        ts::ctx(&mut scenario),
    );

    // Cleanup (won't reach here)
    coin::burn_for_testing(coin);
    conditional_balance::destroy_empty(balance);
    coin_escrow::destroy_for_testing(escrow);

    end(scenario);
}

#[test]
#[expected_failure(abort_code = conditional_balance::EOutcomeNotRegistered)]
fun test_unwrap_unregistered_outcome_fails() {
    let mut scenario = start();

    let (market_id, mut escrow) = setup_escrow_with_caps(&mut scenario);
    // market_id already available

    // Create balance with 3 outcomes (but escrow only has 2 registered)
    let mut balance = conditional_balance::new<SUI, USDC>(
        market_id,
        3,
        ts::ctx(&mut scenario),
    );

    conditional_balance::set_balance(&mut balance, 2, true, 1000);

    // Try to unwrap outcome 2 - should fail (only 0 and 1 registered)
    let coin = conditional_balance::unwrap_to_coin<SUI, USDC, COND0_ASSET>(
        &mut balance,
        &mut escrow,
        2, // Unregistered outcome
        true,
        ts::ctx(&mut scenario),
    );

    // Cleanup (won't reach here)
    coin::burn_for_testing(coin);
    conditional_balance::set_balance(&mut balance, 2, true, 0);
    conditional_balance::destroy_empty(balance);
    coin_escrow::destroy_for_testing(escrow);

    end(scenario);
}

#[test]
#[expected_failure(abort_code = conditional_balance::EInvalidBalanceAccess)]
fun test_unwrap_zero_balance_fails() {
    let mut scenario = start();

    let (market_id, mut escrow) = setup_escrow_with_caps(&mut scenario);
    // market_id already available

    // Create balance with zero balance
    let mut balance = conditional_balance::new<SUI, USDC>(
        market_id,
        2,
        ts::ctx(&mut scenario),
    );

    // Balance is 0, unwrap should fail
    let coin = conditional_balance::unwrap_to_coin<SUI, USDC, COND0_ASSET>(
        &mut balance,
        &mut escrow,
        0,
        true,
        ts::ctx(&mut scenario),
    );

    // Cleanup (won't reach here)
    coin::burn_for_testing(coin);
    conditional_balance::destroy_empty(balance);
    coin_escrow::destroy_for_testing(escrow);

    end(scenario);
}

// === wrap_coin Tests ===

#[test]
fun test_wrap_coin_basic() {
    let mut scenario = start();

    let (market_id, mut escrow) = setup_escrow_with_caps(&mut scenario);
    // market_id already available

    // Create balance with some amount
    let mut balance = conditional_balance::new<SUI, USDC>(
        market_id,
        2,
        ts::ctx(&mut scenario),
    );
    conditional_balance::set_balance(&mut balance, 0, true, 2000);

    // Unwrap to get a properly minted coin
    let coin = conditional_balance::unwrap_to_coin<SUI, USDC, COND0_ASSET>(
        &mut balance,
        &mut escrow,
        0,
        true,
        ts::ctx(&mut scenario),
    );

    // Balance should now be zero
    assert!(conditional_balance::get_balance(&balance, 0, true) == 0, 0);

    // Wrap coin back into balance
    conditional_balance::wrap_coin<SUI, USDC, COND0_ASSET>(
        &mut balance,
        &mut escrow,
        coin,
        0,
        true,
    );

    // Verify balance increased back to original
    assert!(conditional_balance::get_balance(&balance, 0, true) == 2000, 1);

    // Cleanup
    conditional_balance::set_balance(&mut balance, 0, true, 0);
    conditional_balance::destroy_empty(balance);
    coin_escrow::destroy_for_testing(escrow);

    end(scenario);
}

#[test]
fun test_wrap_coin_accumulates() {
    let mut scenario = start();

    let (market_id, mut escrow) = setup_escrow_with_caps(&mut scenario);
    // market_id already available

    // Create balance with existing amount
    let mut balance = conditional_balance::new<SUI, USDC>(
        market_id,
        2,
        ts::ctx(&mut scenario),
    );

    // Start with 1000
    conditional_balance::set_balance(&mut balance, 0, false, 1000);

    // Unwrap 500 to get a properly minted coin (need to set to 500 first, unwrap takes all)
    conditional_balance::set_balance(&mut balance, 0, false, 500);
    let coin = conditional_balance::unwrap_to_coin<SUI, USDC, COND0_STABLE>(
        &mut balance,
        &mut escrow,
        0,
        false,
        ts::ctx(&mut scenario),
    );

    // After unwrap, balance should be 0, set it back to 1000
    conditional_balance::set_balance(&mut balance, 0, false, 1000);

    // Wrap coin - should add to existing balance
    conditional_balance::wrap_coin<SUI, USDC, COND0_STABLE>(
        &mut balance,
        &mut escrow,
        coin,
        0,
        false,
    );

    // Verify accumulated (1000 + 500 = 1500)
    assert!(conditional_balance::get_balance(&balance, 0, false) == 1500, 1);

    // Cleanup
    conditional_balance::set_balance(&mut balance, 0, false, 0);
    conditional_balance::destroy_empty(balance);
    coin_escrow::destroy_for_testing(escrow);

    end(scenario);
}

#[test]
#[expected_failure(abort_code = conditional_balance::EProposalMismatch)]
fun test_wrap_coin_wrong_market_fails() {
    let mut scenario = start();

    let (market_id, mut escrow) = setup_escrow_with_caps(&mut scenario);

    // Create balance for DIFFERENT market
    let wrong_market_id = object::id_from_address(@0x9999);
    let mut balance = conditional_balance::new<SUI, USDC>(
        wrong_market_id,
        2,
        ts::ctx(&mut scenario),
    );

    let coin = coin::mint_for_testing<COND0_ASSET>(1000, ts::ctx(&mut scenario));

    // Try to wrap - should fail with EProposalMismatch
    conditional_balance::wrap_coin<SUI, USDC, COND0_ASSET>(
        &mut balance,
        &mut escrow,
        coin,
        0,
        true,
    );

    // Cleanup (won't reach here)
    conditional_balance::destroy_empty(balance);
    coin_escrow::destroy_for_testing(escrow);

    end(scenario);
}

#[test]
#[expected_failure(abort_code = conditional_balance::EInvalidBalanceAccess)]
fun test_wrap_coin_zero_amount_fails() {
    let mut scenario = start();

    let (market_id, mut escrow) = setup_escrow_with_caps(&mut scenario);
    // market_id already available

    let mut balance = conditional_balance::new<SUI, USDC>(
        market_id,
        2,
        ts::ctx(&mut scenario),
    );

    // Create zero-value coin
    let coin = coin::mint_for_testing<COND1_ASSET>(0, ts::ctx(&mut scenario));

    // Try to wrap zero coin - should fail
    conditional_balance::wrap_coin<SUI, USDC, COND1_ASSET>(
        &mut balance,
        &mut escrow,
        coin,
        1,
        true,
    );

    // Cleanup (won't reach here)
    conditional_balance::destroy_empty(balance);
    coin_escrow::destroy_for_testing(escrow);

    end(scenario);
}

// === Roundtrip Test ===

#[test]
fun test_unwrap_wrap_roundtrip() {
    let mut scenario = start();

    let (market_id, mut escrow) = setup_escrow_with_caps(&mut scenario);
    // market_id already available

    // Create balance
    let mut balance = conditional_balance::new<SUI, USDC>(
        market_id,
        2,
        ts::ctx(&mut scenario),
    );

    // Set initial balance
    conditional_balance::set_balance(&mut balance, 0, true, 3000);

    // Unwrap to coin
    let coin = conditional_balance::unwrap_to_coin<SUI, USDC, COND0_ASSET>(
        &mut balance,
        &mut escrow,
        0,
        true,
        ts::ctx(&mut scenario),
    );

    // Verify balance is now zero
    assert!(conditional_balance::get_balance(&balance, 0, true) == 0, 0);
    assert!(coin.value() == 3000, 1);

    // Wrap it back
    conditional_balance::wrap_coin<SUI, USDC, COND0_ASSET>(
        &mut balance,
        &mut escrow,
        coin,
        0,
        true,
    );

    // Verify back to original amount
    assert!(conditional_balance::get_balance(&balance, 0, true) == 3000, 2);

    // Cleanup
    conditional_balance::set_balance(&mut balance, 0, true, 0);
    conditional_balance::destroy_empty(balance);
    coin_escrow::destroy_for_testing(escrow);

    end(scenario);
}
