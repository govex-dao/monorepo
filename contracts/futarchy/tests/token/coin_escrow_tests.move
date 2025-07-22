#[test_only]
module futarchy::coin_escrow_tests;

use futarchy::coin_escrow;
use futarchy::conditional_token::{Self as token, ConditionalToken}; // Alias needed
use futarchy::market_state;
use futarchy::liquidity_interact; 
use futarchy::proposal::{Self, Proposal}; // Added
use futarchy::fee; 
use futarchy::advance_stage;
use futarchy::swap;
use sui::balance::{Self, Balance}; // Alias needed
use sui::clock::{Self, Clock};
use sui::coin::{Self, Coin}; // Alias needed
use sui::test_utils;
use sui::test_scenario::{Self as test, Scenario, next_tx}; 
use std::string::{Self, String}; 

// Define dummy types to stand in for actual asset and stable types.
public struct DummyAsset has copy, drop, store {}
public struct DummyStable has copy, drop, store {}

// These are the constants defined in the coin_escrow module
// We need to define them here since constants are internal to their module
const TOKEN_TYPE_STABLE: u8 = 1;
const TOKEN_TYPE_ASSET: u8 = 0;

// Test constants for scenario setup
const ADMIN: address = @0xcafe; // Or any suitable test address
const DAO: address = @0xda0; // Or any suitable test address
const MIN_ASSET_LIQUIDITY: u64 = 1_000_000; // Example value
const MIN_STABLE_LIQUIDITY: u64 = 1_000_000; // Example value
const STARTING_TIMESTAMP: u64 = 1_000_000_000; // Example value
const REVIEW_PERIOD_MS: u64 = 2_000; // Short for testing
const TRADING_PERIOD_MS: u64 = 2_000; // Short for testing
const TWAP_START_DELAY: u64 = 180_000;
const TWAP_INITIAL_OBSERVATION: u128 = 1_000_000;
const TWAP_STEP_MAX: u64 = 10000;
const TWAP_THRESHOLD: u64 = 1_000;

// Create a dummy MarketState instance for testing.
fun create_dummy_market_state(ctx: &mut TxContext): market_state::MarketState {
    // For simplicity, create a market with 1 outcome.
    market_state::create_for_testing(1, ctx)
}

// Create a dummy TxContext.
fun create_test_context(): TxContext {
    tx_context::dummy()
}

// Helper function to setup a market with multiple outcomes (still useful)
fun setup_market_with_escrow(
    outcome_count: u64,
    ctx: &mut TxContext,
): (market_state::MarketState, coin_escrow::TokenEscrow<DummyAsset, DummyStable>) {
    // 1. Create the initial MarketState
    let ms_original = market_state::create_for_testing(outcome_count, ctx);

    // 2. Pass the original MarketState to new (it gets moved)
    // We need a local copy to pass if we want to recreate it later,
    // but since create_for_testing is cheap, we can just recreate it.
    let escrow = coin_escrow::new<DummyAsset, DummyStable>(ms_original, ctx);

    // 3. Create a *new* MarketState instance with the same parameters to return
    // This ensures the caller gets a valid MarketState object, even though
    // the original one was moved into the escrow. For testing purposes,
    // having an identical new instance is usually sufficient.
    let ms_to_return = market_state::create_for_testing(outcome_count, ctx);

    // 4. Return the newly created MarketState and the escrow
    (ms_to_return, escrow)
}


// Helper to register supplies for all outcomes
fun register_all_supplies(
    escrow: &mut coin_escrow::TokenEscrow<DummyAsset, DummyStable>,
    outcome_count: u64,
    ctx: &mut TxContext,
) {
    let mut i = 0;
    while (i < outcome_count) {
        let market_state = coin_escrow::get_market_state(escrow); // Borrow read-only
        let asset_supply = token::new_supply(
            copy market_state, // Copy for first use
            TOKEN_TYPE_ASSET,
            (i as u8),
            ctx,
        );
        let stable_supply = token::new_supply(
            market_state, // Use original borrow for second use
            TOKEN_TYPE_STABLE,
            (i as u8),
            ctx,
        );

        coin_escrow::register_supplies(escrow, i, asset_supply, stable_supply);
        i = i + 1;
    }
}

// Helper function to add asset balance to escrow
// Calls coin_escrow::mint_complete_set_asset directly
#[test_only]
fun add_asset_balance<AssetType, StableType>(
    escrow: &mut coin_escrow::TokenEscrow<AssetType, StableType>,
    amount: u64,
    ctx: &mut TxContext,
) {
    let coin_in = coin::mint_for_testing<AssetType>(amount, ctx);
    let clock = clock::create_for_testing(ctx);

    // Initialize trading if not already initialized (required for minting)
    // Note: This might need adjustment depending on test context
    // If called *before* register_all_supplies, this will fail.
    // Assuming it's called after supplies are registered.
    if (!market_state::is_trading_active(coin_escrow::get_market_state(escrow))) {
         market_state::init_trading_for_testing(coin_escrow::get_market_state_mut(escrow));
    };

    let mut tokens = coin_escrow::mint_complete_set_asset(escrow, coin_in, &clock, ctx);

    // Clean up returned tokens (transfer to sender/burn)
    let sender = tx_context::sender(ctx);
    while (!vector::is_empty(&tokens)) {
        let t = vector::pop_back(&mut tokens);
        transfer::public_transfer(t, sender); // Or burn if preferred
    };
    vector::destroy_empty(tokens);
    clock::destroy_for_testing(clock);
}

// Helper function to add stable balance to escrow
// Calls coin_escrow::mint_complete_set_stable directly
#[test_only]
fun add_stable_balance<AssetType, StableType>(
    escrow: &mut coin_escrow::TokenEscrow<AssetType, StableType>,
    amount: u64,
    ctx: &mut TxContext,
) {
    let coin_in = coin::mint_for_testing<StableType>(amount, ctx);
    let clock = clock::create_for_testing(ctx);

     // Initialize trading if not already initialized
     if (!market_state::is_trading_active(coin_escrow::get_market_state(escrow))) {
          market_state::init_trading_for_testing(coin_escrow::get_market_state_mut(escrow));
     };


    let mut tokens = coin_escrow::mint_complete_set_stable(escrow, coin_in, &clock, ctx);

    // Clean up returned tokens
    let sender = tx_context::sender(ctx);
    while (!vector::is_empty(&tokens)) {
        let t = vector::pop_back(&mut tokens);
        transfer::public_transfer(t, sender); // Or burn if preferred
    };
    vector::destroy_empty(tokens);
    clock::destroy_for_testing(clock);
}

#[test]
fun test_register_supplies() {
    let mut ctx = create_test_context();
    let outcome_count = 1; // Simplest case
    let (ms, mut escrow) = setup_market_with_escrow(outcome_count, &mut ctx);

    // Create dummy supplies for testing - using our local constants
    let market_state_ref = coin_escrow::get_market_state(&escrow); // Use ref
    let asset_supply = token::new_supply(copy market_state_ref, TOKEN_TYPE_ASSET, 0, &mut ctx);
    let stable_supply = token::new_supply(market_state_ref, TOKEN_TYPE_STABLE, 0, &mut ctx);

    // Register the supplies
    coin_escrow::register_supplies(&mut escrow, 0, asset_supply, stable_supply);

    // Get separate references to avoid borrowing errors
    let asset_supply_ref = coin_escrow::get_asset_supply(&mut escrow, 0);

    // Verify the asset supply has expected property
    assert!(token::total_supply(asset_supply_ref) == 0, 0);

    // Get stable supply reference after we're done with asset supply
    let stable_supply_ref = coin_escrow::get_stable_supply(&mut escrow, 0);

    // Verify the stable supply has expected property
    assert!(token::total_supply(stable_supply_ref) == 0, 0);

    market_state::destroy_for_testing(ms);
    test_utils::destroy(escrow);
}

#[test]
fun test_mint_and_redeem_complete_set() {
    let mut ctx = create_test_context();
    let outcome_count = 1;
    let (ms, mut escrow) = setup_market_with_escrow(outcome_count, &mut ctx);

    // Register supplies for the outcome
    register_all_supplies(&mut escrow, outcome_count, &mut ctx);

    // Initialize trading for the market (needed for minting)
    market_state::init_trading_for_testing(coin_escrow::get_market_state_mut(&mut escrow));

    // Create a dummy clock
    let clock = sui::clock::create_for_testing(&mut ctx);

    // Create a dummy asset coin with a value of 100
    let asset_coin = sui::coin::mint_for_testing<DummyAsset>(100, &mut ctx);

    // Mint a complete set of tokens using the core function
    let tokens = coin_escrow::mint_complete_set_asset(
        &mut escrow,
        asset_coin,
        &clock,
        &mut ctx,
    );

    // Verify we received the expected number of tokens (1 in this case for a single outcome)
    assert!(vector::length(&tokens) == 1, 0);

    // Check balances after minting
    let (asset_balance, _) = coin_escrow::get_balances(&escrow);
    assert!(asset_balance == 100, 0);

    // Redeem the complete set of tokens
    let redeemed_balance = coin_escrow::redeem_complete_set_asset(
        &mut escrow,
        tokens, // Function consumes the vector
        &clock,
        &mut ctx,
    );

    // Verify redeemed amount matches the original deposit
    assert!(balance::value(&redeemed_balance) == 100, 0);

    // Check escrow balances after redemption
    let (asset_balance_after, _) = coin_escrow::get_balances(&escrow);
    assert!(asset_balance_after == 0, 0);

    // Clean up resources
    balance::destroy_for_testing(redeemed_balance);
    sui::clock::destroy_for_testing(clock);
    market_state::destroy_for_testing(ms);
    test_utils::destroy(escrow);
}

#[test]
fun test_deposit_initial_liquidity() {
    let mut ctx = create_test_context();
    let outcome_count = 2;
    let (ms, mut escrow) = setup_market_with_escrow(outcome_count, &mut ctx);

    // Register supplies for all outcomes
    register_all_supplies(&mut escrow, outcome_count, &mut ctx);

    // Create initial balances to deposit
    let initial_asset = balance::create_for_testing<DummyAsset>(1000); // Max asset needed
    let initial_stable = balance::create_for_testing<DummyStable>(2000); // Max stable needed

    // Create asset and stable amounts vectors for each outcome
    let mut asset_amounts = vector::empty<u64>();
    let mut stable_amounts = vector::empty<u64>();

    // Configure different amounts per outcome
    vector::push_back(&mut asset_amounts, 500); // Outcome 0 asset amount
    vector::push_back(&mut asset_amounts, 1000); // Outcome 1 asset amount (Max)

    vector::push_back(&mut stable_amounts, 2000); // Outcome 0 stable amount (Max)
    vector::push_back(&mut stable_amounts, 1000); // Outcome 1 stable amount

    // Create clock for timestamp
    let clock = clock::create_for_testing(&mut ctx);

    // Initialize trading for the market (needed for minting within deposit)
    market_state::init_trading_for_testing(coin_escrow::get_market_state_mut(&mut escrow));

    // Deposit initial liquidity
    coin_escrow::deposit_initial_liquidity(
        &mut escrow,
        outcome_count,
        &asset_amounts,
        &stable_amounts,
        initial_asset,
        initial_stable,
        &clock,
        &mut ctx,
    );

    // Check balances after deposit
    let (asset_balance, stable_balance) = coin_escrow::get_balances(&escrow);
    assert!(asset_balance == 1000, 0);
    assert!(stable_balance == 2000, 1);

    // Clean up
    clock::destroy_for_testing(clock);
    market_state::destroy_for_testing(ms);
    test_utils::destroy(escrow);
}

#[test]
fun test_remove_liquidity() {
    let mut ctx = create_test_context();
    let outcome_count = 1;
    let (ms, mut escrow) = setup_market_with_escrow(outcome_count, &mut ctx);

    // Register supplies for all outcomes
    register_all_supplies(&mut escrow, outcome_count, &mut ctx);

    // Add some initial liquidity to the escrow using helpers
    // These helpers now call the coin_escrow mint functions directly
    add_asset_balance(&mut escrow, 1000, &mut ctx);
    add_stable_balance(&mut escrow, 2000, &mut ctx);

    // Now test removal using coin_escrow::remove_liquidity
    let (asset_coin_out, stable_coin_out) = coin_escrow::remove_liquidity(
        &mut escrow,
        500, // asset amount to remove
        1000, // stable amount to remove
        &mut ctx,
    );

    // Verify balances after removal
    let (asset_balance, stable_balance) = coin_escrow::get_balances(&escrow);
    assert!(asset_balance == 500, 0); // 1000 - 500 = 500
    assert!(stable_balance == 1000, 1); // 2000 - 1000 = 1000

    // Clean up returned coins
    coin::burn_for_testing(asset_coin_out);
    coin::burn_for_testing(stable_coin_out);

    market_state::destroy_for_testing(ms);
    test_utils::destroy(escrow);
}

#[test]
fun test_mint_and_redeem_complete_set_stable() {
    let mut ctx = create_test_context();
    let outcome_count = 1;
    let (ms, mut escrow) = setup_market_with_escrow(outcome_count, &mut ctx);

    // Register supplies for the outcome
    register_all_supplies(&mut escrow, outcome_count, &mut ctx);

    // Initialize trading for the market
    market_state::init_trading_for_testing(coin_escrow::get_market_state_mut(&mut escrow));

    // Create clock for timestamps
    let clock = clock::create_for_testing(&mut ctx);

    // Create a stable coin to mint tokens
    let stable_coin = coin::mint_for_testing<DummyStable>(500, &mut ctx);

    // Mint complete set of stable tokens using core function
    let tokens = coin_escrow::mint_complete_set_stable(
        &mut escrow,
        stable_coin,
        &clock,
        &mut ctx,
    );

    // Verify we received the right number of tokens
    assert!(vector::length(&tokens) == outcome_count, 0);

    // Check escrow balances
    let (_, stable_balance) = coin_escrow::get_balances(&escrow);
    assert!(stable_balance == 500, 1);

    // Redeem the complete set
    let redeemed_balance = coin_escrow::redeem_complete_set_stable(
        &mut escrow,
        tokens, // Consumed
        &clock,
        &mut ctx,
    );

    // Verify redeemed amount
    assert!(balance::value(&redeemed_balance) == 500, 2);

    // Verify escrow balance is back to zero
    let (_, stable_balance_after) = coin_escrow::get_balances(&escrow);
    assert!(stable_balance_after == 0, 3);

    // Clean up
    balance::destroy_for_testing(redeemed_balance);
    clock::destroy_for_testing(clock);
    market_state::destroy_for_testing(ms);
    test_utils::destroy(escrow);
}

#[test]
fun test_extract_stable_fees() {
    let mut ctx = create_test_context();
    let outcome_count = 1;
    let (ms, mut escrow) = setup_market_with_escrow(outcome_count, &mut ctx);

    // Register supplies
    register_all_supplies(&mut escrow, outcome_count, &mut ctx);

    // Finalize market (needed for fee extraction)

    // Add stable coins to the escrow
    add_stable_balance(&mut escrow, 1000, &mut ctx);

    // Get a mutable reference to the MarketState *inside* the escrow
    let internal_market_state = coin_escrow::get_market_state_mut(&mut escrow);
    // Finalize this internal MarketState
    market_state::finalize_for_testing(internal_market_state);

    // Extract fees
    let fees = coin_escrow::extract_stable_fees(&mut escrow, 200);

    // Verify fee amount
    assert!(balance::value(&fees) == 200, 0);

    // Verify remaining escrow balance
    let (_, stable_balance_after) = coin_escrow::get_balances(&escrow);
    assert!(stable_balance_after == 800, 1); // 1000 - 200 = 800

    // Clean up
    balance::destroy_for_testing(fees);
    market_state::destroy_for_testing(ms);
    test_utils::destroy(escrow);
}


#[test]
fun test_swap_token_asset_to_stable() {
    let mut ctx = create_test_context();
    let outcome_count = 1; // Single outcome for simplicity
    let (ms, mut escrow) = setup_market_with_escrow(outcome_count, &mut ctx);

    // Register supplies for all outcomes
    register_all_supplies(&mut escrow, outcome_count, &mut ctx);

    // Create clock for timestamps
    let clock = clock::create_for_testing(&mut ctx);

    // Add asset and stable balance using helpers
    add_asset_balance(&mut escrow, 1000, &mut ctx);
    add_stable_balance(&mut escrow, 1000, &mut ctx);

    // Initialize trading for the market (already done by helpers, but explicit is okay)
    market_state::init_trading_for_testing(coin_escrow::get_market_state_mut(&mut escrow));

    // Create token values
    let asset_value = 500;
    let outcome_idx = 0;

    // Use our new helper function to create a token directly
    let token = coin_escrow::create_asset_token_for_testing(
        &mut escrow,
        outcome_idx,
        asset_value,
        &clock,
        &mut ctx
    );

    // Swap the asset token for a stable token
    let stable_token = coin_escrow::swap_token_asset_to_stable(
        &mut escrow,
        token,
        outcome_idx,
        asset_value, // Assuming 1:1 swap for simplicity in test
        &clock,
        &mut ctx
    );

    // Verify the stable token properties
    assert!(token::value(&stable_token) == asset_value, 0);
    assert!(token::asset_type(&stable_token) == TOKEN_TYPE_STABLE, 1);
    assert!(token::outcome(&stable_token) == (outcome_idx as u8), 2);

    // Now swap back to asset to test the reverse function
    let asset_token = coin_escrow::swap_token_stable_to_asset(
        &mut escrow,
        stable_token,
        outcome_idx,
        asset_value, // Assuming 1:1 swap
        &clock,
        &mut ctx
    );

    // Verify the asset token properties
    assert!(token::value(&asset_token) == asset_value, 3);
    assert!(token::asset_type(&asset_token) == TOKEN_TYPE_ASSET, 4);
    assert!(token::outcome(&asset_token) == (outcome_idx as u8), 5);

    // Clean up - we need to transfer the token to sender as we can't directly destroy it
    transfer::public_transfer(asset_token, tx_context::sender(&mut ctx));

    clock::destroy_for_testing(clock);
    market_state::destroy_for_testing(ms);
    test_utils::destroy(escrow);
}

#[test]
fun test_redeem_winning_tokens() {
    let mut ctx = create_test_context();
    let outcome_count = 2; // Two outcomes for minimum complexity
    let (ms, mut escrow) = setup_market_with_escrow(outcome_count, &mut ctx);

    // Register supplies for all outcomes
    register_all_supplies(&mut escrow, outcome_count, &mut ctx);

    // Create clock for timestamps
    let clock = clock::create_for_testing(&mut ctx);

    // Initialize trading for the market
    market_state::init_trading_for_testing(coin_escrow::get_market_state_mut(&mut escrow));

    // Add asset and stable balances using helpers
    add_asset_balance(&mut escrow, 1000, &mut ctx);
    add_stable_balance(&mut escrow, 1000, &mut ctx);

    // Values for creating tokens
    let asset_value = 500;
    let outcome_idx = 0;

    // Use our new helper functions to create tokens directly
    let asset_token = coin_escrow::create_asset_token_for_testing(
        &mut escrow,
        outcome_idx,
        asset_value,
        &clock,
        &mut ctx
    );

    let stable_token = coin_escrow::create_stable_token_for_testing(
        &mut escrow,
        outcome_idx,
        asset_value,
        &clock,
        &mut ctx
    );

    // Now finalize the market with outcome 0 as winner
    market_state::finalize_for_testing(coin_escrow::get_market_state_mut(&mut escrow));

    // Redeem the winning asset token
    let redeemed_asset = coin_escrow::redeem_winning_tokens_asset(
        &mut escrow,
        asset_token, // Consumed
        &clock,
        &mut ctx
    );

    // Verify the redeemed asset amount
    assert!(balance::value(&redeemed_asset) == asset_value, 0);

    // Redeem the winning stable token
    let redeemed_stable = coin_escrow::redeem_winning_tokens_stable(
        &mut escrow,
        stable_token, // Consumed
        &clock,
        &mut ctx
    );

    // Verify the redeemed stable amount
    assert!(balance::value(&redeemed_stable) == asset_value, 1);

    // Clean up
    balance::destroy_for_testing(redeemed_asset);
    balance::destroy_for_testing(redeemed_stable);
    clock::destroy_for_testing(clock);
    market_state::destroy_for_testing(ms);
    test_utils::destroy(escrow);
}

#[test]
#[expected_failure(abort_code = market_state::EOutcomeOutOfBounds)] // Use named constant
fun test_register_supplies_invalid_outcome() {
    let mut ctx = create_test_context();
    let outcome_count = 2;
    let (ms, mut escrow) = setup_market_with_escrow(outcome_count, &mut ctx);

    // Try to register supplies for outcome index 2, which is out of bounds
    let market_state_ref = coin_escrow::get_market_state(&escrow);
    let asset_supply = token::new_supply(copy market_state_ref, TOKEN_TYPE_ASSET, 2, &mut ctx);
    let stable_supply = token::new_supply(market_state_ref, TOKEN_TYPE_STABLE, 2, &mut ctx);

    coin_escrow::register_supplies(&mut escrow, 2, asset_supply, stable_supply);

    // Cleanup in case of unexpected success (won't be reached)
    market_state::destroy_for_testing(ms);
    test_utils::destroy(escrow);
}

#[test]
#[expected_failure(abort_code = coin_escrow::EIncorrectSequence)] // Use named constant
fun test_register_supplies_incorrect_sequence() {
    let mut ctx = create_test_context();
    let outcome_count = 3;
    let (ms, mut escrow) = setup_market_with_escrow(outcome_count, &mut ctx);

    // Create supplies for outcome 0
    let market_state_ref0 = coin_escrow::get_market_state(&escrow);
    let asset_supply0 = token::new_supply(copy market_state_ref0, TOKEN_TYPE_ASSET, 0, &mut ctx);
    let stable_supply0 = token::new_supply(market_state_ref0, TOKEN_TYPE_STABLE, 0, &mut ctx);

    // Create supplies for outcome 2 (skipping 1)
    let market_state_ref2 = coin_escrow::get_market_state(&escrow);
    let asset_supply2 = token::new_supply(copy market_state_ref2, TOKEN_TYPE_ASSET, 2, &mut ctx);
    let stable_supply2 = token::new_supply(market_state_ref2, TOKEN_TYPE_STABLE, 2, &mut ctx);

    // Register outcome 0
    coin_escrow::register_supplies(&mut escrow, 0, asset_supply0, stable_supply0);

    // Try to register outcome 2 (skipping 1) - should fail
    coin_escrow::register_supplies(&mut escrow, 2, asset_supply2, stable_supply2);

     // Cleanup in case of unexpected success (won't be reached)
    market_state::destroy_for_testing(ms);
    test_utils::destroy(escrow);
}

#[test]
fun test_multi_outcome_market() {
    let mut ctx = create_test_context();
    let outcome_count = 4; // Test with more outcomes
    let (ms, mut escrow) = setup_market_with_escrow(outcome_count, &mut ctx);

    // Register supplies for all outcomes
    register_all_supplies(&mut escrow, outcome_count, &mut ctx);

    // Create clock for timestamps
    let clock = clock::create_for_testing(&mut ctx);

    // Initialize trading
    market_state::init_trading_for_testing(coin_escrow::get_market_state_mut(&mut escrow));

    // Mint tokens for all outcomes
    let asset_coin = coin::mint_for_testing<DummyAsset>(1000, &mut ctx);
    let tokens = coin_escrow::mint_complete_set_asset(&mut escrow, asset_coin, &clock, &mut ctx);

    // Verify we get a token for each outcome
    assert!(vector::length(&tokens) == outcome_count, 0);

    // Redeem the complete set
    let redeemed = coin_escrow::redeem_complete_set_asset(&mut escrow, tokens, &clock, &mut ctx);
    assert!(balance::value(&redeemed) == 1000, 1);

    // Clean up
    balance::destroy_for_testing(redeemed);
    clock::destroy_for_testing(clock);
    market_state::destroy_for_testing(ms);
    test_utils::destroy(escrow);
}

#[test]
#[expected_failure(abort_code = coin_escrow::ENotEnough)] // Use named constant
fun test_extract_fees_insufficient_balance() {
    let mut ctx = create_test_context();
    let outcome_count = 1;
    let (ms, mut escrow) = setup_market_with_escrow(outcome_count, &mut ctx);

    // Register supplies
    register_all_supplies(&mut escrow, outcome_count, &mut ctx);

    // Add stable coins to the escrow
    add_stable_balance(&mut escrow, 100, &mut ctx);

    // Get a mutable reference to the MarketState *inside* the escrow
    let internal_market_state = coin_escrow::get_market_state_mut(&mut escrow);
    // Finalize this internal MarketState
    market_state::finalize_for_testing(internal_market_state);

    // Try to extract more fees than available
    let fees = coin_escrow::extract_stable_fees(&mut escrow, 200);

    // Should not reach here
    balance::destroy_for_testing(fees);
    market_state::destroy_for_testing(ms);
    test_utils::destroy(escrow);
}

#[test]
fun test_entry_functions() {
    let mut scenario = test::begin(ADMIN); // Use scenario
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock::set_for_testing(&mut clock, STARTING_TIMESTAMP);

    let outcome_count = 2;

    // Transaction 1: Setup Proposal, Escrow, FeeManager
    next_tx(&mut scenario, ADMIN);
    {
        let asset_balance = balance::create_for_testing<DummyAsset>(MIN_ASSET_LIQUIDITY);
        let stable_balance = balance::create_for_testing<DummyStable>(MIN_STABLE_LIQUIDITY);
        let dao_id = object::id_from_address(DAO);

        let mut outcome_messages = vector::empty<String>();
        vector::push_back(&mut outcome_messages, string::utf8(b"Outcome 0"));
        vector::push_back(&mut outcome_messages, string::utf8(b"Outcome 1"));

        // Create proposal (assume it shares Proposal & Escrow internally)
        // We don't need to capture the return values if we take them later
        let fee_escrow = balance::zero<DummyStable>(); // No DAO fee for testing
        let treasury_address = @0x0; // Default treasury address
        
        proposal::create<DummyAsset, DummyStable>(
            fee_escrow,
            dao_id, 
            outcome_count, 
            asset_balance, 
            stable_balance, 
            REVIEW_PERIOD_MS, 
            TRADING_PERIOD_MS,
            MIN_ASSET_LIQUIDITY, 
            MIN_STABLE_LIQUIDITY, 
            string::utf8(b"Entry Test"), 
            vector[string::utf8(b"Details for Outcome 0"), string::utf8(b"Details for Outcome 1")],
            string::utf8(b"Meta"), 
            outcome_messages, 
            TWAP_START_DELAY, 
            TWAP_INITIAL_OBSERVATION,
            TWAP_STEP_MAX, 
            vector[1_000_000, 1_000_000, 1_000_000, 1_000_000], 
            TWAP_THRESHOLD, 
            treasury_address,
            &clock, 
            scenario.ctx()
        );

        // Create Fee Manager (assume it shares FeeManager internally)
        fee::create_fee_manager_for_testing(scenario.ctx());
        // --- End of Tx 1: Objects are created and shared ---
    };

    // Transaction 2: Advance state
    next_tx(&mut scenario, ADMIN);
    {
        // Advance clock past review period
        clock::set_for_testing(&mut clock, STARTING_TIMESTAMP + REVIEW_PERIOD_MS + 100);

        // Take shared objects created in Tx 1
        let mut proposal = test::take_shared<Proposal<DummyAsset, DummyStable>>(&scenario);
        let mut escrow = test::take_shared<coin_escrow::TokenEscrow<DummyAsset, DummyStable>>(&scenario);
        // Also take FeeManager, although unused here, to ensure it's tracked and returned
        let fee_manager = test::take_shared<fee::FeeManager>(&scenario);

        let market_state = coin_escrow::get_market_state_mut(&mut escrow);

        // Advance the state
        advance_stage::try_advance_state(
            &mut proposal,
            market_state,
            &clock,
        );

        // Return modified/unmodified objects for the next transaction
        test::return_shared(proposal);
        test::return_shared(escrow);
        test::return_shared(fee_manager); // Return fee manager too
        // --- End of Tx 2: State advanced, objects returned ---
    };

    // Transaction 3: Test mint_complete_set_asset_entry
    next_tx(&mut scenario, ADMIN);
    {
        // Take shared objects returned from Tx 2
        let proposal = test::take_shared<Proposal<DummyAsset, DummyStable>>(&scenario);
        // Use fully qualified name just to be safe, although it should work without now
        let mut escrow = test::take_shared<coin_escrow::TokenEscrow<DummyAsset, DummyStable>>(&scenario);
        let fee_manager = test::take_shared<fee::FeeManager>(&scenario); // Take it again

        let asset_coin = coin::mint_for_testing<DummyAsset>(500, scenario.ctx());

        // Call the entry function (requires proposal state == TRADING, which it should be)
        liquidity_interact::mint_complete_set_asset_entry<DummyAsset, DummyStable>(
            &proposal,
            &mut escrow,
            asset_coin,
            &clock,
            scenario.ctx()
        );

        // Check balance inside escrow
        let (asset_balance, _) = coin_escrow::get_balances(&escrow);
        assert!(asset_balance == 500 + MIN_ASSET_LIQUIDITY, 0); // Initial liquidity + minted

        // Return objects for the next transaction
        test::return_shared(proposal);
        test::return_shared(escrow);
        test::return_shared(fee_manager);
        // --- End of Tx 3 ---
    };

     // Transaction 4: Test mint_complete_set_stable_entry
    next_tx(&mut scenario, ADMIN);
    {
        // Take shared objects returned from Tx 3
        let proposal = test::take_shared<Proposal<DummyAsset, DummyStable>>(&scenario);
        let mut escrow = test::take_shared<coin_escrow::TokenEscrow<DummyAsset, DummyStable>>(&scenario);
        let fee_manager = test::take_shared<fee::FeeManager>(&scenario); // Take it again

        let stable_coin = coin::mint_for_testing<DummyStable>(500, scenario.ctx());

        // Call the entry function
        liquidity_interact::mint_complete_set_stable_entry<DummyAsset, DummyStable>(
            &proposal,
            &mut escrow,
            stable_coin,
            &clock,
            scenario.ctx()
        );

        // Check balances
        let (asset_balance, stable_balance) = coin_escrow::get_balances(&escrow);
        assert!(asset_balance == 500 + MIN_ASSET_LIQUIDITY, 1); // Unchanged from previous step
        assert!(stable_balance == 500 + MIN_STABLE_LIQUIDITY, 2); // Initial liquidity + minted

        // Return objects (optional if this is the last step using them, but good practice)
        test::return_shared(proposal);
        test::return_shared(escrow);
        test::return_shared(fee_manager);
        // --- End of Tx 4 ---
    };

    // Clean up scenario clock
    clock::destroy_for_testing(clock);
    test::end(scenario); // Scenario handles cleanup of returned shared objects
}

#[test]
#[expected_failure(abort_code = market_state::ENotFinalized)] // Check market_state error code
fun test_redeem_winning_tokens_market_not_finalized() {
    let mut ctx = create_test_context();
    let outcome_count = 2;
    let (ms, mut escrow) = setup_market_with_escrow(outcome_count, &mut ctx);

    // Register supplies
    register_all_supplies(&mut escrow, outcome_count, &mut ctx);

    // Create clock for timestamps
    let clock = clock::create_for_testing(&mut ctx);

    // Initialize trading (but don't finalize)
    market_state::init_trading_for_testing(coin_escrow::get_market_state_mut(&mut escrow));

    // Create asset token using helper
    let token = coin_escrow::create_asset_token_for_testing(
        &mut escrow,
        0,
        100,
        &clock,
        &mut ctx
    );

    // Try to redeem winning token without finalizing the market
    let redeemed = coin_escrow::redeem_winning_tokens_asset(
        &mut escrow,
        token,
        &clock,
        &mut ctx
    );

    // Should not reach here
    balance::destroy_for_testing(redeemed);
    clock::destroy_for_testing(clock);
    market_state::destroy_for_testing(ms);
    test_utils::destroy(escrow);
}

#[test]
#[expected_failure(abort_code = coin_escrow::EWrongOutcome)] // Use named constant
fun test_redeem_wrong_outcome_token() {
    let mut ctx = create_test_context();
    let outcome_count = 2;
    let (ms, mut escrow) = setup_market_with_escrow(outcome_count, &mut ctx);

    // Register supplies
    register_all_supplies(&mut escrow, outcome_count, &mut ctx);

    // Create clock for timestamps
    let clock = clock::create_for_testing(&mut ctx);

    // Initialize trading
    market_state::init_trading_for_testing(coin_escrow::get_market_state_mut(&mut escrow));

    // Create token for outcome 1 (BEFORE finalizing)
    let token = coin_escrow::create_asset_token_for_testing(
        &mut escrow,
        1, // Non-winning outcome
        100,
        &clock,
        &mut ctx
    );

    // Finalize with outcome 0 as winner
    market_state::finalize_for_testing(coin_escrow::get_market_state_mut(&mut escrow)); // Assuming this sets winner to 0

    // Try to redeem non-winning token
    let redeemed = coin_escrow::redeem_winning_tokens_asset(
        &mut escrow,
        token, // Consumed
        &clock,
        &mut ctx
    );

    // Should not reach here
    balance::destroy_for_testing(redeemed);
    clock::destroy_for_testing(clock);
    market_state::destroy_for_testing(ms);
    test_utils::destroy(escrow);
}

#[test]
fun test_deposit_initial_liquidity_with_imbalanced_outcomes() {
    let mut ctx = create_test_context();
    let outcome_count = 3;
    let (ms, mut escrow) = setup_market_with_escrow(outcome_count, &mut ctx);

    // Register supplies for all outcomes
    register_all_supplies(&mut escrow, outcome_count, &mut ctx);

    // Determine max amounts needed first
    let max_asset = 1000;
    let max_stable = 2000;

    // Create initial balances matching the max needed
    let initial_asset = balance::create_for_testing<DummyAsset>(max_asset);
    let initial_stable = balance::create_for_testing<DummyStable>(max_stable);

    // Create highly imbalanced asset and stable amounts
    let mut asset_amounts = vector::empty<u64>();
    let mut stable_amounts = vector::empty<u64>();

    vector::push_back(&mut asset_amounts, 100);  // Outcome 0
    vector::push_back(&mut asset_amounts, 1000); // Outcome 1 (Max Asset)
    vector::push_back(&mut asset_amounts, 500);  // Outcome 2

    vector::push_back(&mut stable_amounts, 2000); // Outcome 0 (Max Stable)
    vector::push_back(&mut stable_amounts, 200);  // Outcome 1
    vector::push_back(&mut stable_amounts, 1000); // Outcome 2

    // Create clock for timestamp
    let clock = clock::create_for_testing(&mut ctx);

    // Initialize trading
    market_state::init_trading_for_testing(coin_escrow::get_market_state_mut(&mut escrow));

    // Deposit initial liquidity
    coin_escrow::deposit_initial_liquidity(
        &mut escrow,
        outcome_count,
        &asset_amounts,
        &stable_amounts,
        initial_asset,
        initial_stable,
        &clock,
        &mut ctx
    );

    // Check balances after deposit (should equal max amounts provided)
    let (asset_balance, stable_balance) = coin_escrow::get_balances(&escrow);
    assert!(asset_balance == max_asset, 0);
    assert!(stable_balance == max_stable, 1);

    // Clean up
    clock::destroy_for_testing(clock);
    market_state::destroy_for_testing(ms);
    test_utils::destroy(escrow);
}

#[test]
#[expected_failure(abort_code = coin_escrow::ENotEnoughLiquidity)] // Use named constant
fun test_remove_liquidity_insufficient_funds() {
    let mut ctx = create_test_context();
    let outcome_count = 1;
    let (ms, mut escrow) = setup_market_with_escrow(outcome_count, &mut ctx);

    // Register supplies
    register_all_supplies(&mut escrow, outcome_count, &mut ctx);

    // Add some initial liquidity
    add_asset_balance(&mut escrow, 500, &mut ctx);
    add_stable_balance(&mut escrow, 1000, &mut ctx);

    // Try to remove more than available using coin_escrow::remove_liquidity
    let (asset_coin_out, stable_coin_out) = coin_escrow::remove_liquidity(
        &mut escrow,
        1000, // more than available asset
        500,  // less than available stable (but asset check fails first)
        &mut ctx
    );

    // Should not reach here
    coin::burn_for_testing(asset_coin_out);
    coin::burn_for_testing(stable_coin_out);
    market_state::destroy_for_testing(ms);
    test_utils::destroy(escrow);
}

#[test]
#[expected_failure(abort_code = coin_escrow::EWrongOutcome)] // verify_token_set fails with this
fun test_verify_token_set_duplicate_outcomes() {
    let mut ctx = create_test_context();
    let outcome_count = 3;
    let (ms, mut escrow) = setup_market_with_escrow(outcome_count, &mut ctx);

    // Register supplies
    register_all_supplies(&mut escrow, outcome_count, &mut ctx);

    // Create clock for timestamps
    let clock = clock::create_for_testing(&mut ctx);

    // Initialize trading
    market_state::init_trading_for_testing(coin_escrow::get_market_state_mut(&mut escrow));

    // Create tokens for testing using the helper (which mints complete sets internally)
    let token0a = coin_escrow::create_asset_token_for_testing(
        &mut escrow, 0, 100, &clock, &mut ctx
    );

    // Need to mint another *complete set* to get another token 0 reliably
    let token0b = coin_escrow::create_asset_token_for_testing(
        &mut escrow, 0, 100, &clock, &mut ctx
    );

    let token1 = coin_escrow::create_asset_token_for_testing(
        &mut escrow, 1, 100, &clock, &mut ctx
    );


    // Create a token set with duplicate outcomes (0, 0, 1) - missing outcome 2
    let mut tokens = vector::empty<ConditionalToken>();
    vector::push_back(&mut tokens, token0a);
    vector::push_back(&mut tokens, token0b); // Duplicate outcome 0
    vector::push_back(&mut tokens, token1);  // Missing outcome 2

    // Try to redeem set with duplicate/missing outcomes - should fail in verify_token_set
    let redeemed = coin_escrow::redeem_complete_set_asset(
        &mut escrow,
        tokens, // Consumed
        &clock,
        &mut ctx
    );

    // Should not reach here
    balance::destroy_for_testing(redeemed);
    clock::destroy_for_testing(clock);
    market_state::destroy_for_testing(ms);
    test_utils::destroy(escrow);
}

// ===== Market State Tests =====

#[test]
#[expected_failure(abort_code = market_state::EAlreadyFinalized)] // Check market_state code
fun test_mint_after_finalization() {
    let mut ctx = create_test_context();
    let outcome_count = 2;
    let (ms, mut escrow) = setup_market_with_escrow(outcome_count, &mut ctx);

    // Register supplies
    register_all_supplies(&mut escrow, outcome_count, &mut ctx);

    // Create clock for timestamps
    let clock = clock::create_for_testing(&mut ctx);

    // Initialize trading and finalize
    market_state::init_trading_for_testing(coin_escrow::get_market_state_mut(&mut escrow));
    market_state::finalize_for_testing(coin_escrow::get_market_state_mut(&mut escrow));

    // Try to mint after finalization - should fail in coin_escrow::mint_* due to market state check
    let asset_coin = coin::mint_for_testing<DummyAsset>(100, &mut ctx);
    let mut tokens = coin_escrow::mint_complete_set_asset(
        &mut escrow,
        asset_coin,
        &clock,
        &mut ctx
    );

    // Should not reach here
    let sender = tx_context::sender(&mut ctx);
    while (!vector::is_empty(&tokens)) { transfer::public_transfer(vector::pop_back(&mut tokens), sender)};
    vector::destroy_empty(tokens);
    clock::destroy_for_testing(clock);
    market_state::destroy_for_testing(ms);
    test_utils::destroy(escrow);
}

#[test]
#[expected_failure(abort_code = market_state::ETradingAlreadyEnded)] // Check market_state code
fun test_swap_after_trading_ended() {
    let mut ctx = create_test_context();
    let outcome_count = 2;
    let (ms, mut escrow) = setup_market_with_escrow(outcome_count, &mut ctx);

    // Register supplies
    register_all_supplies(&mut escrow, outcome_count, &mut ctx);

    // Create clock for timestamps
    let clock = clock::create_for_testing(&mut ctx);

    // Initialize trading
    market_state::init_trading_for_testing(coin_escrow::get_market_state_mut(&mut escrow));

    // Add balance (requires trading active)
    add_asset_balance(&mut escrow, 1000, &mut ctx);
    add_stable_balance(&mut escrow, 1000, &mut ctx);

    // Create token (requires trading active)
    let token = coin_escrow::create_asset_token_for_testing(
        &mut escrow, 0, 100, &clock, &mut ctx
    );

    // End trading
    market_state::finalize_for_testing(coin_escrow::get_market_state_mut(&mut escrow));


    // Attempt swap - should fail
    let stable_token = coin_escrow::swap_token_asset_to_stable(
        &mut escrow,
        token, // Consumed
        0,
        100,
        &clock,
        &mut ctx
    );

    // Should not reach here
    transfer::public_transfer(stable_token, tx_context::sender(&mut ctx));
    clock::destroy_for_testing(clock);
    market_state::destroy_for_testing(ms);
    test_utils::destroy(escrow);
}

// ===== Token Operations Tests =====

#[test]
fun test_mint_redeem_large_outcome_set() {
    let mut ctx = create_test_context();
    let outcome_count = 10; // Test with a large number of outcomes
    let (ms, mut escrow) = setup_market_with_escrow(outcome_count, &mut ctx);

    // Register supplies for all outcomes
    register_all_supplies(&mut escrow, outcome_count, &mut ctx);

    // Create clock for timestamps
    let clock = clock::create_for_testing(&mut ctx);

    // Initialize trading
    market_state::init_trading_for_testing(coin_escrow::get_market_state_mut(&mut escrow));

    // Mint tokens for all outcomes
    let asset_coin = coin::mint_for_testing<DummyAsset>(1000, &mut ctx);
    let tokens = coin_escrow::mint_complete_set_asset(&mut escrow, asset_coin, &clock, &mut ctx);

    // Verify we get a token for each outcome
    assert!(vector::length(&tokens) == outcome_count, 0);

    // Redeem the complete set
    let redeemed = coin_escrow::redeem_complete_set_asset(&mut escrow, tokens, &clock, &mut ctx);
    assert!(balance::value(&redeemed) == 1000, 1);

    // Clean up
    balance::destroy_for_testing(redeemed);
    clock::destroy_for_testing(clock);
    market_state::destroy_for_testing(ms);
    test_utils::destroy(escrow);
}

// ===== Edge Cases and Error Conditions =====

#[test]
#[expected_failure(abort_code = coin_escrow::EIncorrectSequence)] // verify_token_set expects full set
fun test_redeem_incomplete_token_set() {
    let mut ctx = create_test_context();
    let outcome_count = 3;
    let (ms, mut escrow) = setup_market_with_escrow(outcome_count, &mut ctx);

    // Register supplies
    register_all_supplies(&mut escrow, outcome_count, &mut ctx);

    // Create clock for timestamps
    let clock = clock::create_for_testing(&mut ctx);

    // Initialize trading
    market_state::init_trading_for_testing(coin_escrow::get_market_state_mut(&mut escrow));

    // Create tokens for only 2 of the 3 outcomes using the helper
    let token0 = coin_escrow::create_asset_token_for_testing(
        &mut escrow, 0, 100, &clock, &mut ctx
    );

    let token1 = coin_escrow::create_asset_token_for_testing(
        &mut escrow, 1, 100, &clock, &mut ctx
    );

    // Create an incomplete set (missing outcome 2)
    let mut tokens = vector::empty<ConditionalToken>();
    vector::push_back(&mut tokens, token0);
    vector::push_back(&mut tokens, token1);

    // Try to redeem incomplete set - should fail in verify_token_set
    let redeemed = coin_escrow::redeem_complete_set_asset(
        &mut escrow,
        tokens, // Consumed
        &clock,
        &mut ctx
    );

    // Should not reach here
    balance::destroy_for_testing(redeemed);
    clock::destroy_for_testing(clock);
    market_state::destroy_for_testing(ms);
    test_utils::destroy(escrow);
}

#[test]
fun test_init_market_with_max_outcomes() {
    let mut ctx = create_test_context();
    let outcome_count = 100; // Test with a very large number of outcomes
    let (ms, mut escrow) = setup_market_with_escrow(outcome_count, &mut ctx);

    // Register supplies (only register a few to avoid test timeout)
    let mut i = 0;
    while (i < 10) { // Register only first 10 for performance
        let market_state_ref = coin_escrow::get_market_state(&escrow);
        let asset_supply = token::new_supply(
            copy market_state_ref,
            TOKEN_TYPE_ASSET,
            (i as u8),
            &mut ctx,
        );
        let stable_supply = token::new_supply(
            market_state_ref,
            TOKEN_TYPE_STABLE,
            (i as u8),
            &mut ctx,
        );

        coin_escrow::register_supplies(&mut escrow, i, asset_supply, stable_supply);
        i = i + 1;
    };

    // Verify market state has correct outcome count
    let state = coin_escrow::get_market_state(&escrow);
    assert!(market_state::outcome_count(state) == outcome_count, 0);

    // Clean up
    market_state::destroy_for_testing(ms);
    test_utils::destroy(escrow);
}

#[test]
fun test_liquidity_deposit_and_withdrawal_sequence() {
    let mut ctx = create_test_context();
    let outcome_count = 2;
    let (ms, mut escrow) = setup_market_with_escrow(outcome_count, &mut ctx);

    // Register supplies
    register_all_supplies(&mut escrow, outcome_count, &mut ctx);

    // Create initial balances to deposit (matching max needed)
    let initial_asset_val = 1000;
    let initial_stable_val = 2000;
    let initial_asset = balance::create_for_testing<DummyAsset>(initial_asset_val);
    let initial_stable = balance::create_for_testing<DummyStable>(initial_stable_val);

    // Create asset and stable amounts vectors
    let mut asset_amounts = vector::empty<u64>();
    let mut stable_amounts = vector::empty<u64>();

    vector::push_back(&mut asset_amounts, 500);
    vector::push_back(&mut asset_amounts, 1000); // Max asset

    vector::push_back(&mut stable_amounts, 1000);
    vector::push_back(&mut stable_amounts, 2000); // Max stable

    // Create clock for timestamp
    let clock = clock::create_for_testing(&mut ctx);

    // Initialize trading
    market_state::init_trading_for_testing(coin_escrow::get_market_state_mut(&mut escrow));

    // Deposit initial liquidity
    coin_escrow::deposit_initial_liquidity(
        &mut escrow,
        outcome_count,
        &asset_amounts,
        &stable_amounts,
        initial_asset,
        initial_stable,
        &clock,
        &mut ctx
    );

    // Check balances after deposit
    let (asset_balance1, stable_balance1) = coin_escrow::get_balances(&escrow);
    assert!(asset_balance1 == initial_asset_val, 0);
    assert!(stable_balance1 == initial_stable_val, 1);

    // Remove partial liquidity
    let (asset_coin1, stable_coin1) = coin_escrow::remove_liquidity(
        &mut escrow, 300, 600, &mut ctx
    );

    // Check balances after first withdrawal
    let (asset_balance2, stable_balance2) = coin_escrow::get_balances(&escrow);
    assert!(asset_balance2 == 700, 2); // 1000 - 300
    assert!(stable_balance2 == 1400, 3); // 2000 - 600

    // Remove remaining liquidity
    let (asset_coin2, stable_coin2) = coin_escrow::remove_liquidity(
        &mut escrow, 700, 1400, &mut ctx
    );

    // Check balances after second withdrawal
    let (asset_balance3, stable_balance3) = coin_escrow::get_balances(&escrow);
    assert!(asset_balance3 == 0, 4);
    assert!(stable_balance3 == 0, 5);

    // Clean up
    coin::burn_for_testing(asset_coin1);
    coin::burn_for_testing(stable_coin1);
    coin::burn_for_testing(asset_coin2);
    coin::burn_for_testing(stable_coin2);
    clock::destroy_for_testing(clock);
    market_state::destroy_for_testing(ms);
    test_utils::destroy(escrow);
}

#[test]
fun test_swap_token_value_changes() {
    let mut ctx = create_test_context();
    let outcome_count = 2;
    let (ms, mut escrow) = setup_market_with_escrow(outcome_count, &mut ctx);

    // Register supplies
    register_all_supplies(&mut escrow, outcome_count, &mut ctx);

    // Create clock for timestamps
    let clock = clock::create_for_testing(&mut ctx);

    // Initialize trading
    market_state::init_trading_for_testing(coin_escrow::get_market_state_mut(&mut escrow));

    // Add balances
    add_asset_balance(&mut escrow, 10000, &mut ctx);
    add_stable_balance(&mut escrow, 10000, &mut ctx);

    // Create token for testing
    let token_in = coin_escrow::create_asset_token_for_testing(
        &mut escrow, 0, 1000, &clock, &mut ctx
    );

    // Perform swap with amount_out different from token value
    let token_out = coin_escrow::swap_token_asset_to_stable(
        &mut escrow,
        token_in, // Consumed
        0,
        1500, // Different value than input token had
        &clock,
        &mut ctx
    );

    // Verify output token has the specified amount
    assert!(token::value(&token_out) == 1500, 0);
    assert!(token::asset_type(&token_out) == TOKEN_TYPE_STABLE, 1);

    // Swap back with another value change
    let token_final = coin_escrow::swap_token_stable_to_asset(
        &mut escrow,
        token_out, // Consumed
        0,
        800, // Different value again
        &clock,
        &mut ctx
    );

    assert!(token::value(&token_final) == 800, 2);
    assert!(token::asset_type(&token_final) == TOKEN_TYPE_ASSET, 3);

    // Clean up
    transfer::public_transfer(token_final, tx_context::sender(&mut ctx));
    clock::destroy_for_testing(clock);
    market_state::destroy_for_testing(ms);
    test_utils::destroy(escrow);
}

#[test]
fun test_winning_redemption_with_multiple_tokens() {
    let mut ctx = create_test_context();
    let outcome_count = 3;
    let (ms, mut escrow) = setup_market_with_escrow(outcome_count, &mut ctx);

    // Register supplies
    register_all_supplies(&mut escrow, outcome_count, &mut ctx);

    // Create clock for timestamps
    let clock = clock::create_for_testing(&mut ctx);

    // Initialize trading
    market_state::init_trading_for_testing(coin_escrow::get_market_state_mut(&mut escrow));

    // Add balances
    add_asset_balance(&mut escrow, 5000, &mut ctx);
    add_stable_balance(&mut escrow, 5000, &mut ctx);

    // Create tokens for outcome 0 (which will be the winner)
    let token1 = coin_escrow::create_asset_token_for_testing(
        &mut escrow, 0, 1000, &clock, &mut ctx
    );

    let token2 = coin_escrow::create_asset_token_for_testing(
        &mut escrow, 0, 2000, &clock, &mut ctx
    );

    // Also create some tokens for other outcomes
    let losing_token = coin_escrow::create_asset_token_for_testing(
        &mut escrow, 1, 1500, &clock, &mut ctx
    );

    // Finalize market with outcome 0 as winner
    market_state::finalize_for_testing(coin_escrow::get_market_state_mut(&mut escrow));

    // Redeem the winning tokens
    let balance1 = coin_escrow::redeem_winning_tokens_asset(
        &mut escrow, token1, &clock, &mut ctx // Consumed
    );

    let balance2 = coin_escrow::redeem_winning_tokens_asset(
        &mut escrow, token2, &clock, &mut ctx // Consumed
    );

    // Verify redeemed amounts
    assert!(balance::value(&balance1) == 1000, 0);
    assert!(balance::value(&balance2) == 2000, 1);

    // Attempt to redeem losing token (should fail)
    // This is tested separately in test_redeem_wrong_outcome_token

    // Clean up
    balance::destroy_for_testing(balance1);
    balance::destroy_for_testing(balance2);
    // Losing token needs cleanup as it wasn't consumed
    transfer::public_transfer(losing_token, tx_context::sender(&mut ctx));
    clock::destroy_for_testing(clock);
    market_state::destroy_for_testing(ms);
    test_utils::destroy(escrow);
}

#[test]
fun test_boundary_values() {
    let mut ctx = create_test_context();
    let outcome_count = 1;
    let (ms, mut escrow) = setup_market_with_escrow(outcome_count, &mut ctx);

    // Register supplies
    register_all_supplies(&mut escrow, outcome_count, &mut ctx);

    // Create clock for timestamps
    let clock = clock::create_for_testing(&mut ctx);

    // Initialize trading
    market_state::init_trading_for_testing(coin_escrow::get_market_state_mut(&mut escrow));

    // Test with a very small amount (1)
    let small_coin = coin::mint_for_testing<DummyAsset>(1, &mut ctx);
    let small_tokens = coin_escrow::mint_complete_set_asset(
        &mut escrow, small_coin, &clock, &mut ctx
    );

    // Check that small amount was minted correctly (vector has 1 element)
    assert!(token::value(vector::borrow(&small_tokens, 0)) == 1, 0);

    // Redeem the small amount
    let small_balance = coin_escrow::redeem_complete_set_asset(
        &mut escrow, small_tokens, &clock, &mut ctx // Consumed
    );

    assert!(balance::value(&small_balance) == 1, 1);

    // Test with a very large amount (u64::MAX / 2)
    let large_amount = 9223372036854775807u64; // u64::MAX / 2 = 2^63 - 1
    let large_coin = coin::mint_for_testing<DummyAsset>(large_amount, &mut ctx);
    let large_tokens = coin_escrow::mint_complete_set_asset(
        &mut escrow, large_coin, &clock, &mut ctx
    );

    // Check that large amount was minted correctly
    assert!(token::value(vector::borrow(&large_tokens, 0)) == large_amount, 2);

    // Redeem the large amount
    let large_balance = coin_escrow::redeem_complete_set_asset(
        &mut escrow, large_tokens, &clock, &mut ctx // Consumed
    );

    assert!(balance::value(&large_balance) == large_amount, 3);

    // Clean up
    balance::destroy_for_testing(small_balance);
    balance::destroy_for_testing(large_balance);
    clock::destroy_for_testing(clock);
    market_state::destroy_for_testing(ms);
    test_utils::destroy(escrow);
}

// ----- Fixed Tests based on original diagnostics -----

#[test]
#[expected_failure(abort_code = market_state::EOutcomeOutOfBounds)]
fun test_register_supplies_invalid_outcome_fixed() { // Renamed slightly
    let mut ctx = create_test_context();
    let outcome_count = 2;
    let (ms, mut escrow) = setup_market_with_escrow(outcome_count, &mut ctx);

    let market_state_ref = coin_escrow::get_market_state(&escrow);
    let asset_supply = token::new_supply(copy market_state_ref, TOKEN_TYPE_ASSET, 2, &mut ctx);
    let stable_supply = token::new_supply(market_state_ref, TOKEN_TYPE_STABLE, 2, &mut ctx);

    coin_escrow::register_supplies(&mut escrow, 2, asset_supply, stable_supply);

    market_state::destroy_for_testing(ms);
    test_utils::destroy(escrow);
}

#[test]
#[expected_failure(abort_code = coin_escrow::EWrongOutcome)]
fun test_redeem_wrong_outcome_token_fixed() { // Already fixed above, this is just confirmation
    let mut ctx = create_test_context();
    let outcome_count = 2;
    let (ms, mut escrow) = setup_market_with_escrow(outcome_count, &mut ctx);

    register_all_supplies(&mut escrow, outcome_count, &mut ctx);
    let clock = clock::create_for_testing(&mut ctx);
    market_state::init_trading_for_testing(coin_escrow::get_market_state_mut(&mut escrow));

    let token = coin_escrow::create_asset_token_for_testing(
        &mut escrow, 1, 100, &clock, &mut ctx
    );

    market_state::finalize_for_testing(coin_escrow::get_market_state_mut(&mut escrow));

    let redeemed = coin_escrow::redeem_winning_tokens_asset(
        &mut escrow, token, &clock, &mut ctx
    );

    balance::destroy_for_testing(redeemed);
    clock::destroy_for_testing(clock);
    market_state::destroy_for_testing(ms);
    test_utils::destroy(escrow);
}

#[test]
fun test_supply_tracking_fixed() {
    let mut ctx = create_test_context();
    let outcome_count = 1;
    let (ms, mut escrow) = setup_market_with_escrow(outcome_count, &mut ctx);

    register_all_supplies(&mut escrow, outcome_count, &mut ctx);
    let clock = clock::create_for_testing(&mut ctx);
    market_state::init_trading_for_testing(coin_escrow::get_market_state_mut(&mut escrow));

    // Check initial supply
    {
        let asset_supply = coin_escrow::get_asset_supply(&mut escrow, 0);
        assert!(token::total_supply(asset_supply) == 0, 0);
    }; // End borrow

    // Mint tokens
    let asset_coin = coin::mint_for_testing<DummyAsset>(1000, &mut ctx);
    let mut tokens = coin_escrow::mint_complete_set_asset(&mut escrow, asset_coin, &clock, &mut ctx);

    // Check supply after minting
    {
        let asset_supply = coin_escrow::get_asset_supply(&mut escrow, 0);
        assert!(token::total_supply(asset_supply) == 1000, 1);
    }; // End borrow

    // Burn the token (need mutable borrow of supply)
    {
        let asset_supply = coin_escrow::get_asset_supply(&mut escrow, 0); // Get mut borrow again
        let token_to_burn = vector::pop_back(&mut tokens); // Take the single token
        token_to_burn.burn(asset_supply,  &clock, &mut ctx); // Burn it

        // Check supply after burning (re-borrow needed if burn didn't extend borrow)
        let asset_supply = coin_escrow::get_asset_supply(&mut escrow, 0); // Re-borrow mutably
        assert!(token::total_supply(asset_supply) == 0, 2);
    }; // End borrow

    // Clean up
    vector::destroy_empty(tokens);
    clock::destroy_for_testing(clock);
    market_state::destroy_for_testing(ms);
    test_utils::destroy(escrow);
}


#[test]
#[expected_failure(abort_code = coin_escrow::EWrongMarket)]
fun test_verify_token_set_wrong_market_fixed() {
    let mut ctx = create_test_context();
    let outcome_count = 2;
    // Create two independent markets/escrows
    let (ms1, mut escrow1) = setup_market_with_escrow(outcome_count, &mut ctx);
    let (ms2, mut escrow2) = setup_market_with_escrow(outcome_count, &mut ctx);

    register_all_supplies(&mut escrow1, outcome_count, &mut ctx);
    register_all_supplies(&mut escrow2, outcome_count, &mut ctx);
    let clock = clock::create_for_testing(&mut ctx);
    market_state::init_trading_for_testing(coin_escrow::get_market_state_mut(&mut escrow1));
    market_state::init_trading_for_testing(coin_escrow::get_market_state_mut(&mut escrow2));

    // Create a token from market 1
    let token1 = coin_escrow::create_asset_token_for_testing(&mut escrow1, 0, 100, &clock, &mut ctx);
    // Create a token from market 2
    let token2 = coin_escrow::create_asset_token_for_testing(&mut escrow2, 1, 100, &clock, &mut ctx);

    // Create a mixed vector
    let mut tokens = vector::empty<ConditionalToken>();
    vector::push_back(&mut tokens, token1);
    vector::push_back(&mut tokens, token2);

    // Try to redeem mixed tokens in market 1 - should fail in verify_token_set
    let redeemed = coin_escrow::redeem_complete_set_asset(&mut escrow1, tokens, &clock, &mut ctx);

    balance::destroy_for_testing(redeemed); // Should not reach
    clock::destroy_for_testing(clock);
    market_state::destroy_for_testing(ms1);
    market_state::destroy_for_testing(ms2);
    test_utils::destroy(escrow1);
    test_utils::destroy(escrow2);
}

#[test]
#[expected_failure(abort_code = coin_escrow::EWrongTokenType)]
fun test_verify_token_set_mixed_types_fixed() {
    let mut ctx = create_test_context();
    let outcome_count = 2;
    let (ms, mut escrow) = setup_market_with_escrow(outcome_count, &mut ctx);

    register_all_supplies(&mut escrow, outcome_count, &mut ctx);
    let clock = clock::create_for_testing(&mut ctx);
    market_state::init_trading_for_testing(coin_escrow::get_market_state_mut(&mut escrow));

    // Create an asset token
    let asset_token = coin_escrow::create_asset_token_for_testing(&mut escrow, 0, 100, &clock, &mut ctx);
    // Create a stable token
    let stable_token = coin_escrow::create_stable_token_for_testing(&mut escrow, 1, 100, &clock, &mut ctx);

    // Create a mixed vector
    let mut tokens = vector::empty<ConditionalToken>();
    vector::push_back(&mut tokens, asset_token);
    vector::push_back(&mut tokens, stable_token);

    // Try to redeem ASSET set with mixed types - should fail in verify_token_set
    let redeemed = coin_escrow::redeem_complete_set_asset(&mut escrow, tokens, &clock, &mut ctx);

    balance::destroy_for_testing(redeemed); // Should not reach
    clock::destroy_for_testing(clock);
    market_state::destroy_for_testing(ms);
    test_utils::destroy(escrow);
}


#[test]
#[expected_failure(abort_code = coin_escrow::EInsufficientBalance)] // verify_token_set amount check
fun test_verify_token_set_different_amounts_fixed() {
    let mut ctx = create_test_context();
    let outcome_count = 2;
    let (ms, mut escrow) = setup_market_with_escrow(outcome_count, &mut ctx);

    register_all_supplies(&mut escrow, outcome_count, &mut ctx);
    let clock = clock::create_for_testing(&mut ctx);
    market_state::init_trading_for_testing(coin_escrow::get_market_state_mut(&mut escrow));

    // Create tokens with different underlying amounts using the helper
    let token_100_outcome0 = coin_escrow::create_asset_token_for_testing(&mut escrow, 0, 100, &clock, &mut ctx);
    let token_200_outcome1 = coin_escrow::create_asset_token_for_testing(&mut escrow, 1, 200, &clock, &mut ctx);

    // Create a vector with tokens representing different mint amounts
    let mut mixed_tokens = vector::empty<ConditionalToken>();
    vector::push_back(&mut mixed_tokens, token_100_outcome0);
    vector::push_back(&mut mixed_tokens, token_200_outcome1);

    // Try to redeem tokens with different amounts - should fail in verify_token_set
    let redeemed = coin_escrow::redeem_complete_set_asset(&mut escrow, mixed_tokens, &clock, &mut ctx);

    balance::destroy_for_testing(redeemed); // Should not reach
    clock::destroy_for_testing(clock);
    market_state::destroy_for_testing(ms);
    test_utils::destroy(escrow);
}

// Note: The test originally named `test_verify_token_set_duplicate_outcomes_fixed`
// was actually testing different *amounts*. The real duplicate outcome test is
// `test_verify_token_set_duplicate_outcomes` above, which correctly expects EWRONG_OUTCOME.
// Removing the redundant/mislabeled `_fixed` version for amounts.

}