#[test_only]
module futarchy::coin_escrow_tests;

use futarchy::coin_escrow;
use futarchy::conditional_token;
use futarchy::market_state;
use sui::balance;
use sui::clock::{Self, Clock};
use sui::coin;
use sui::object;
use sui::test_utils;
use sui::tx_context;

// Define dummy types to stand in for actual asset and stable types.
public struct DummyAsset has copy, drop, store {}
public struct DummyStable has copy, drop, store {}

// These are the constants defined in the coin_escrow module
// We need to define them here since constants are internal to their module
const TOKEN_TYPE_STABLE: u8 = 1;
const TOKEN_TYPE_ASSET: u8 = 0;

// Create a dummy MarketState instance for testing.
fun create_dummy_market_state(ctx: &mut tx_context::TxContext): market_state::MarketState {
    // For simplicity, create a market with 1 outcome.
    market_state::create_for_testing(1, ctx)
}

// Create a dummy TxContext.
fun create_test_context(): tx_context::TxContext {
    tx_context::dummy()
}

// Helper function to setup a market with multiple outcomes
fun setup_market_with_escrow(
    outcome_count: u64,
    ctx: &mut tx_context::TxContext,
): (market_state::MarketState, coin_escrow::TokenEscrow<DummyAsset, DummyStable>) {
    let ms = market_state::create_for_testing(outcome_count, ctx);
    // Create a reference to ms instead of trying to copy it
    let escrow = coin_escrow::new<DummyAsset, DummyStable>(ms, ctx);

    // Create a new MarketState since the original was moved
    let ms = market_state::create_for_testing(outcome_count, ctx);

    (ms, escrow)
}

// Helper to register supplies for all outcomes
fun register_all_supplies(
    escrow: &mut coin_escrow::TokenEscrow<DummyAsset, DummyStable>,
    outcome_count: u64,
    ctx: &mut tx_context::TxContext,
) {
    let mut i = 0;
    while (i < outcome_count) {
        let market_state = coin_escrow::get_market_state(escrow);
        let asset_supply = conditional_token::new_supply(
            copy market_state,
            TOKEN_TYPE_ASSET,
            (i as u8),
            ctx,
        );
        let stable_supply = conditional_token::new_supply(
            market_state,
            TOKEN_TYPE_STABLE,
            (i as u8),
            ctx,
        );

        coin_escrow::register_supplies(escrow, i, asset_supply, stable_supply);
        i = i + 1;
    }
}

// Helper function to add asset balance to escrow
#[test_only]
fun add_asset_balance<AssetType, StableType>(
    escrow: &mut coin_escrow::TokenEscrow<AssetType, StableType>,
    amount: u64,
    ctx: &mut tx_context::TxContext,
) {
    let coin = coin::mint_for_testing<AssetType>(amount, ctx);
    let clock = clock::create_for_testing(ctx);
    coin_escrow::mint_complete_set_asset_entry(escrow, coin, &clock, ctx);
    clock::destroy_for_testing(clock);
}

// Helper function to add stable balance to escrow
#[test_only]
fun add_stable_balance<AssetType, StableType>(
    escrow: &mut coin_escrow::TokenEscrow<AssetType, StableType>,
    amount: u64,
    ctx: &mut tx_context::TxContext,
) {
    let coin = coin::mint_for_testing<StableType>(amount, ctx);
    let clock = clock::create_for_testing(ctx);
    coin_escrow::mint_complete_set_stable_entry(escrow, coin, &clock, ctx);
    clock::destroy_for_testing(clock);
}

#[test]
fun test_register_supplies() {
    let mut ctx = create_test_context();
    let ms = create_dummy_market_state(&mut ctx);

    // Create a new token escrow instance
    let mut escrow = coin_escrow::new<DummyAsset, DummyStable>(ms, &mut ctx);

    // Create dummy supplies for testing - using our local constants
    let market_state = coin_escrow::get_market_state(&escrow);
    let asset_supply = conditional_token::new_supply(market_state, TOKEN_TYPE_ASSET, 0, &mut ctx);
    let stable_supply = conditional_token::new_supply(market_state, TOKEN_TYPE_STABLE, 0, &mut ctx);

    // Register the supplies
    coin_escrow::register_supplies(&mut escrow, 0, asset_supply, stable_supply);

    // Get separate references to avoid borrowing errors
    let asset_supply_ref = coin_escrow::get_asset_supply(&mut escrow, 0);

    // Verify the asset supply has expected property
    assert!(conditional_token::total_supply(asset_supply_ref) == 0, 0);

    // Get stable supply reference after we're done with asset supply
    let stable_supply_ref = coin_escrow::get_stable_supply(&mut escrow, 0);

    // Verify the stable supply has expected property
    assert!(conditional_token::total_supply(stable_supply_ref) == 0, 0);

    test_utils::destroy(escrow);
}

#[test]
fun test_mint_and_redeem_complete_set() {
    let mut ctx = create_test_context();
    let mut ms = create_dummy_market_state(&mut ctx);

    // Initialize trading for the market
    market_state::init_trading_for_testing(&mut ms);

    // Create a new token escrow instance
    let mut escrow = coin_escrow::new<DummyAsset, DummyStable>(ms, &mut ctx);

    // Create dummy supplies for testing - using our local constants
    let market_state = coin_escrow::get_market_state(&escrow);
    let asset_supply = conditional_token::new_supply(market_state, TOKEN_TYPE_ASSET, 0, &mut ctx);
    let stable_supply = conditional_token::new_supply(market_state, TOKEN_TYPE_STABLE, 0, &mut ctx);

    // Register the supplies
    coin_escrow::register_supplies(&mut escrow, 0, asset_supply, stable_supply);

    // Create a dummy clock
    let clock = sui::clock::create_for_testing(&mut ctx);

    // Create a dummy asset coin with a value of 100
    let asset_coin = sui::coin::mint_for_testing<DummyAsset>(100, &mut ctx);

    // Mint a complete set of tokens
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
        tokens,
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
    let initial_asset = balance::create_for_testing<DummyAsset>(1000);
    let initial_stable = balance::create_for_testing<DummyStable>(2000);

    // Create asset and stable amounts vectors for each outcome
    let mut asset_amounts = vector::empty<u64>();
    let mut stable_amounts = vector::empty<u64>();

    // Configure different amounts per outcome
    vector::push_back(&mut asset_amounts, 500); // Outcome 0 asset amount
    vector::push_back(&mut asset_amounts, 1000); // Outcome 1 asset amount

    vector::push_back(&mut stable_amounts, 2000); // Outcome 0 stable amount
    vector::push_back(&mut stable_amounts, 1000); // Outcome 1 stable amount

    // Create clock for timestamp
    let clock = clock::create_for_testing(&mut ctx);

    // Initialize trading for the market
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

    // Add some initial liquidity to the escrow

    let market_state = coin_escrow::get_market_state_mut(&mut escrow);

    // Setup empty vectors since we're not using deposit_initial_liquidity
    // Just directly joining the balances for simplicity
    // Add initial balances using the entry functions as workaround
    add_asset_balance(&mut escrow, 1000, &mut ctx);
    add_stable_balance(&mut escrow, 2000, &mut ctx);

    // Now test removal
    coin_escrow::remove_liquidity(
        &mut escrow,
        500, // asset amount to remove
        1000, // stable amount to remove
        &mut ctx,
    );

    // Verify balances after removal
    let (asset_balance, stable_balance) = coin_escrow::get_balances(&escrow);
    assert!(asset_balance == 500, 0); // 1000 - 500 = 500
    assert!(stable_balance == 1000, 1); // 2000 - 1000 = 1000
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

    // Mint complete set of stable tokens
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
        tokens,
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

    // Add stable coins to the escrow
    add_stable_balance(&mut escrow, 1000, &mut ctx);

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

    // Add asset and stable balance by minting complete sets
    add_asset_balance(&mut escrow, 1000, &mut ctx);
    add_stable_balance(&mut escrow, 1000, &mut ctx);
    
    // Initialize trading for the market
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
        asset_value,
        &clock,
        &mut ctx
    );
    
    // Verify the stable token properties
    assert!(conditional_token::value(&stable_token) == asset_value, 0);
    assert!(conditional_token::asset_type(&stable_token) == 1, 1); // TOKEN_TYPE_STABLE = 1
    assert!(conditional_token::outcome(&stable_token) == (outcome_idx as u8), 2);
    
    // Now swap back to asset to test the reverse function
    let asset_token = coin_escrow::swap_token_stable_to_asset(
        &mut escrow,
        stable_token,
        outcome_idx,
        asset_value,
        &clock,
        &mut ctx
    );
    
    // Verify the asset token properties
    assert!(conditional_token::value(&asset_token) == asset_value, 3);
    assert!(conditional_token::asset_type(&asset_token) == 0, 4); // TOKEN_TYPE_ASSET = 0
    assert!(conditional_token::outcome(&asset_token) == (outcome_idx as u8), 5);
    
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
    
    // Add asset and stable balances
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
        asset_token,
        &clock,
        &mut ctx
    );
    
    // Verify the redeemed asset amount
    assert!(balance::value(&redeemed_asset) == asset_value, 0);
    
    // Redeem the winning stable token
    let redeemed_stable = coin_escrow::redeem_winning_tokens_stable(
        &mut escrow,
        stable_token,
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
#[expected_failure(abort_code = 1)] // EOUTCOME_OUT_OF_BOUNDS
fun test_register_supplies_invalid_outcome() {
    let mut ctx = create_test_context();
    let outcome_count = 2;
    let (ms, mut escrow) = setup_market_with_escrow(outcome_count, &mut ctx);
    
    // Try to register supplies for outcome index 2, which is out of bounds
    let market_state = coin_escrow::get_market_state(&escrow);
    let asset_supply = conditional_token::new_supply(market_state, TOKEN_TYPE_ASSET, 2, &mut ctx);
    let stable_supply = conditional_token::new_supply(market_state, TOKEN_TYPE_STABLE, 2, &mut ctx);
    
    coin_escrow::register_supplies(&mut escrow, 2, asset_supply, stable_supply);
    market_state::destroy_for_testing(ms);
    test_utils::destroy(escrow);
}

#[test]
#[expected_failure(abort_code = 1)] // EINCORRECT_SEQUENCE
fun test_register_supplies_incorrect_sequence() {
    let mut ctx = create_test_context();
    let outcome_count = 3;
    let (ms, mut escrow) = setup_market_with_escrow(outcome_count, &mut ctx);
    
    // Create supplies for outcome 0
    let market_state = coin_escrow::get_market_state(&escrow);
    let asset_supply0 = conditional_token::new_supply(market_state, TOKEN_TYPE_ASSET, 0, &mut ctx);
    let stable_supply0 = conditional_token::new_supply(market_state, TOKEN_TYPE_STABLE, 0, &mut ctx);
    
    // Create supplies for outcome 2 (skipping 1)
    let market_state = coin_escrow::get_market_state(&escrow);
    let asset_supply2 = conditional_token::new_supply(market_state, TOKEN_TYPE_ASSET, 2, &mut ctx);
    let stable_supply2 = conditional_token::new_supply(market_state, TOKEN_TYPE_STABLE, 2, &mut ctx);
    
    // Register outcome 0
    coin_escrow::register_supplies(&mut escrow, 0, asset_supply0, stable_supply0);
    
    // Try to register outcome 2 (skipping 1) - should fail
    coin_escrow::register_supplies(&mut escrow, 2, asset_supply2, stable_supply2);
    
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
#[expected_failure(abort_code = 7)] // ENOT_ENOUGH
fun test_extract_fees_insufficient_balance() {
    let mut ctx = create_test_context();
    let outcome_count = 1;
    let (ms, mut escrow) = setup_market_with_escrow(outcome_count, &mut ctx);
    
    // Register supplies
    register_all_supplies(&mut escrow, outcome_count, &mut ctx);
    
    // Add stable coins to the escrow
    add_stable_balance(&mut escrow, 100, &mut ctx);
    
    // Try to extract more fees than available
    let fees = coin_escrow::extract_stable_fees(&mut escrow, 200);
    
    // Should not reach here
    balance::destroy_for_testing(fees);
    market_state::destroy_for_testing(ms);
    test_utils::destroy(escrow);
}

#[test]
fun test_entry_functions() {
    let mut ctx = create_test_context();
    let outcome_count = 2;
    let (ms, mut escrow) = setup_market_with_escrow(outcome_count, &mut ctx);
    
    // Register supplies
    register_all_supplies(&mut escrow, outcome_count, &mut ctx);
    
    // Create clock for timestamps
    let clock = clock::create_for_testing(&mut ctx);
    
    // Initialize trading
    market_state::init_trading_for_testing(coin_escrow::get_market_state_mut(&mut escrow));
    
    // Test mint_complete_set_asset_entry
    let asset_coin = coin::mint_for_testing<DummyAsset>(500, &mut ctx);
    coin_escrow::mint_complete_set_asset_entry(&mut escrow, asset_coin, &clock, &mut ctx);
    
    // Test mint_complete_set_stable_entry
    let stable_coin = coin::mint_for_testing<DummyStable>(500, &mut ctx);
    coin_escrow::mint_complete_set_stable_entry(&mut escrow, stable_coin, &clock, &mut ctx);
    
    // Check balances
    let (asset_balance, stable_balance) = coin_escrow::get_balances(&escrow);
    assert!(asset_balance == 500, 0);
    assert!(stable_balance == 500, 1);
    
    // Clean up
    clock::destroy_for_testing(clock);
    market_state::destroy_for_testing(ms);
    test_utils::destroy(escrow);
}

#[test]
#[expected_failure] // Market not finalized
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
    
    // Create asset token
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
#[expected_failure(abort_code = 6)] // EWRONG_OUTCOME
fun test_redeem_wrong_outcome_token() {
    let mut ctx = create_test_context();
    let outcome_count = 2;
    let (ms, mut escrow) = setup_market_with_escrow(outcome_count, &mut ctx);
    
    // Register supplies
    register_all_supplies(&mut escrow, outcome_count, &mut ctx);
    
    // Create clock for timestamps
    let clock = clock::create_for_testing(&mut ctx);
    
    // Initialize trading and finalize with outcome 0 as winner
    market_state::init_trading_for_testing(coin_escrow::get_market_state_mut(&mut escrow));
    
    // Create token for outcome 1 (not the winning outcome)
    let token = coin_escrow::create_asset_token_for_testing(
        &mut escrow,
        1,
        100,
        &clock,
        &mut ctx
    );
    
    market_state::finalize_for_testing(coin_escrow::get_market_state_mut(&mut escrow));
    
    // Try to redeem non-winning token
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
fun test_deposit_initial_liquidity_with_imbalanced_outcomes() {
    let mut ctx = create_test_context();
    let outcome_count = 3;
    let (ms, mut escrow) = setup_market_with_escrow(outcome_count, &mut ctx);
    
    // Register supplies for all outcomes
    register_all_supplies(&mut escrow, outcome_count, &mut ctx);
    
    // Create initial balances to deposit
    let initial_asset = balance::create_for_testing<DummyAsset>(1000);
    let initial_stable = balance::create_for_testing<DummyStable>(2000);
    
    // Create highly imbalanced asset and stable amounts
    let mut asset_amounts = vector::empty<u64>();
    let mut stable_amounts = vector::empty<u64>();
    
    vector::push_back(&mut asset_amounts, 100);  // Outcome 0
    vector::push_back(&mut asset_amounts, 1000);  // Outcome 1
    vector::push_back(&mut asset_amounts, 500);  // Outcome 2
    
    vector::push_back(&mut stable_amounts, 2000); // Outcome 0
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
#[expected_failure(abort_code = 8)] // ENOT_ENOUGH_LIQUIDITY
fun test_remove_liquidity_insufficient_funds() {
    let mut ctx = create_test_context();
    let outcome_count = 1;
    let (ms, mut escrow) = setup_market_with_escrow(outcome_count, &mut ctx);
    
    // Register supplies
    register_all_supplies(&mut escrow, outcome_count, &mut ctx);
    
    // Add some initial liquidity
    add_asset_balance(&mut escrow, 500, &mut ctx);
    add_stable_balance(&mut escrow, 1000, &mut ctx);
    
    // Try to remove more than available
    coin_escrow::remove_liquidity(
        &mut escrow,
        1000, // more than available asset
        500,  // less than available stable
        &mut ctx
    );
    
    // Should not reach here
    market_state::destroy_for_testing(ms);
    test_utils::destroy(escrow);
}

#[test]
#[expected_failure(abort_code = 6)] // EWRONG_OUTCOME
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
    
    // Create tokens for testing
    let token0a = coin_escrow::create_asset_token_for_testing(
        &mut escrow,
        0,
        100,
        &clock,
        &mut ctx
    );
    
    let token0b = coin_escrow::create_asset_token_for_testing(
        &mut escrow,
        0,
        100,
        &clock,
        &mut ctx
    );
    
    let token1 = coin_escrow::create_asset_token_for_testing(
        &mut escrow,
        1,
        100,
        &clock,
        &mut ctx
    );
    
    // Create a token set with duplicate outcomes (0, 0, 1) - missing outcome 2
    let mut tokens = vector::empty<conditional_token::ConditionalToken>();
    vector::push_back(&mut tokens, token0a);
    vector::push_back(&mut tokens, token0b);
    vector::push_back(&mut tokens, token1);
    
    // Try to redeem set with duplicate outcomes - should fail
    let redeemed = coin_escrow::redeem_complete_set_asset(
        &mut escrow,
        tokens,
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
#[expected_failure(abort_code = 2)] // EALREADY_FINALIZED
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
    
    // Try to mint after finalization - should fail
    let asset_coin = coin::mint_for_testing<DummyAsset>(100, &mut ctx);
    let tokens = coin_escrow::mint_complete_set_asset(
        &mut escrow,
        asset_coin,
        &clock,
        &mut ctx
    );
    
    // Should not reach here
    vector::destroy_empty(tokens);
    clock::destroy_for_testing(clock);
    market_state::destroy_for_testing(ms);
    test_utils::destroy(escrow);
}

#[test]
#[expected_failure(abort_code = 6)] // ETRADING_NOT_STARTED
fun test_swap_before_trading_started() {
    let mut ctx = create_test_context();
    let outcome_count = 2;
    let (ms, mut escrow) = setup_market_with_escrow(outcome_count, &mut ctx);
    
    // Register supplies
    register_all_supplies(&mut escrow, outcome_count, &mut ctx);
    
    // Create clock for timestamps
    let clock = clock::create_for_testing(&mut ctx);
    
    // Add balances (but don't start trading)
    add_asset_balance(&mut escrow, 1000, &mut ctx);
    add_stable_balance(&mut escrow, 1000, &mut ctx);
    
    // Try to perform a swap before trading is started
    let token = coin_escrow::create_asset_token_for_testing(
        &mut escrow,
        0,
        100,
        &clock,
        &mut ctx
    );
    
    // Attempt swap - should fail because trading hasn't started
    let stable_token = coin_escrow::swap_token_asset_to_stable(
        &mut escrow,
        token,
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

#[test]
#[expected_failure(abort_code = 3)] // ETRADING_ALREADY_ENDED
fun test_swap_after_trading_ended() {
    let mut ctx = create_test_context();
    let outcome_count = 2;
    let (ms, mut escrow) = setup_market_with_escrow(outcome_count, &mut ctx);
    
    // Register supplies
    register_all_supplies(&mut escrow, outcome_count, &mut ctx);
    
    // Create clock for timestamps
    let clock = clock::create_for_testing(&mut ctx);
    
    // Initialize trading and end it
    let market_state = coin_escrow::get_market_state_mut(&mut escrow);
    market_state::init_trading_for_testing(market_state);
    market_state::end_trading(market_state, &clock);
    
    // Try to perform a swap after trading is ended
    let token = coin_escrow::create_asset_token_for_testing(
        &mut escrow,
        0,
        100,
        &clock,
        &mut ctx
    );
    
    // Attempt swap - should fail
    let stable_token = coin_escrow::swap_token_asset_to_stable(
        &mut escrow,
        token,
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
#[expected_failure(abort_code = 1)] // EINCORRECT_SEQUENCE
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
    
    // Create tokens for only 2 of the 3 outcomes
    let token0 = coin_escrow::create_asset_token_for_testing(
        &mut escrow,
        0,
        100,
        &clock,
        &mut ctx
    );
    
    let token1 = coin_escrow::create_asset_token_for_testing(
        &mut escrow,
        1,
        100,
        &clock,
        &mut ctx
    );
    
    // Create an incomplete set (missing outcome 2)
    let mut tokens = vector::empty<conditional_token::ConditionalToken>();
    vector::push_back(&mut tokens, token0);
    vector::push_back(&mut tokens, token1);
    
    // Try to redeem incomplete set - should fail
    let redeemed = coin_escrow::redeem_complete_set_asset(
        &mut escrow,
        tokens,
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
        let market_state = coin_escrow::get_market_state(&escrow);
        let asset_supply = conditional_token::new_supply(
            copy market_state,
            TOKEN_TYPE_ASSET,
            (i as u8),
            &mut ctx,
        );
        let stable_supply = conditional_token::new_supply(
            market_state,
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
    
    // Create initial balances to deposit
    let initial_asset = balance::create_for_testing<DummyAsset>(1000);
    let initial_stable = balance::create_for_testing<DummyStable>(2000);
    
    // Create asset and stable amounts vectors
    let mut asset_amounts = vector::empty<u64>();
    let mut stable_amounts = vector::empty<u64>();
    
    vector::push_back(&mut asset_amounts, 500);
    vector::push_back(&mut asset_amounts, 1000);
    
    vector::push_back(&mut stable_amounts, 1000);
    vector::push_back(&mut stable_amounts, 2000);
    
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
    assert!(asset_balance1 == 1000, 0);
    assert!(stable_balance1 == 2000, 1);
    
    // Remove partial liquidity
    coin_escrow::remove_liquidity(
        &mut escrow,
        300,
        600,
        &mut ctx
    );
    
    // Check balances after first withdrawal
    let (asset_balance2, stable_balance2) = coin_escrow::get_balances(&escrow);
    assert!(asset_balance2 == 700, 2); // 1000 - 300
    assert!(stable_balance2 == 1400, 3); // 2000 - 600
    
    // Remove remaining liquidity
    coin_escrow::remove_liquidity(
        &mut escrow,
        700,
        1400,
        &mut ctx
    );
    
    // Check balances after second withdrawal
    let (asset_balance3, stable_balance3) = coin_escrow::get_balances(&escrow);
    assert!(asset_balance3 == 0, 4);
    assert!(stable_balance3 == 0, 5);
    
    // Clean up
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
        &mut escrow,
        0,
        1000,
        &clock,
        &mut ctx
    );
    
    // Perform swap with amount_out different from token value
    let token_out = coin_escrow::swap_token_asset_to_stable(
        &mut escrow,
        token_in,
        0,
        1500, // Different value than input
        &clock,
        &mut ctx
    );
    
    // Verify output token has the specified amount
    assert!(conditional_token::value(&token_out) == 1500, 0);
    assert!(conditional_token::asset_type(&token_out) == TOKEN_TYPE_STABLE, 1);
    
    // Swap back with another value change
    let token_final = coin_escrow::swap_token_stable_to_asset(
        &mut escrow,
        token_out,
        0,
        800, // Different value again
        &clock,
        &mut ctx
    );
    
    assert!(conditional_token::value(&token_final) == 800, 2);
    assert!(conditional_token::asset_type(&token_final) == TOKEN_TYPE_ASSET, 3);
    
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
        &mut escrow,
        0,
        1000,
        &clock,
        &mut ctx
    );
    
    let token2 = coin_escrow::create_asset_token_for_testing(
        &mut escrow,
        0,
        2000,
        &clock,
        &mut ctx
    );
    
    // Also create some tokens for other outcomes
    let losing_token = coin_escrow::create_asset_token_for_testing(
        &mut escrow,
        1,
        1500,
        &clock,
        &mut ctx
    );
    
    // Finalize market with outcome 0 as winner
    market_state::finalize_for_testing(coin_escrow::get_market_state_mut(&mut escrow));
    
    // Redeem the winning tokens
    let balance1 = coin_escrow::redeem_winning_tokens_asset(
        &mut escrow,
        token1,
        &clock,
        &mut ctx
    );
    
    let balance2 = coin_escrow::redeem_winning_tokens_asset(
        &mut escrow,
        token2,
        &clock,
        &mut ctx
    );
    
    // Verify redeemed amounts
    assert!(balance::value(&balance1) == 1000, 0);
    assert!(balance::value(&balance2) == 2000, 1);
    
    // Attempt to redeem losing token (should fail)
    // This is tested separately in test_redeem_wrong_outcome_token
    
    // Clean up
    balance::destroy_for_testing(balance1);
    balance::destroy_for_testing(balance2);
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
        &mut escrow,
        small_coin,
        &clock,
        &mut ctx
    );
    
    // Check that small amount was minted correctly
    assert!(conditional_token::value(vector::borrow(&small_tokens, 0)) == 1, 0);
    
    // Redeem the small amount
    let small_balance = coin_escrow::redeem_complete_set_asset(
        &mut escrow,
        small_tokens,
        &clock,
        &mut ctx
    );
    
    assert!(balance::value(&small_balance) == 1, 1);
    
    // Test with a very large amount (u64::MAX / 2)
    let large_amount = 9223372036854775807u64; // u64::MAX / 2
    let large_coin = coin::mint_for_testing<DummyAsset>(large_amount, &mut ctx);
    let large_tokens = coin_escrow::mint_complete_set_asset(
        &mut escrow,
        large_coin,
        &clock,
        &mut ctx
    );
    
    // Check that large amount was minted correctly
    assert!(conditional_token::value(vector::borrow(&large_tokens, 0)) == large_amount, 2);
    
    // Redeem the large amount
    let large_balance = coin_escrow::redeem_complete_set_asset(
        &mut escrow,
        large_tokens,
        &clock,
        &mut ctx
    );
    
    assert!(balance::value(&large_balance) == large_amount, 3);
    
    // Clean up
    balance::destroy_for_testing(small_balance);
    balance::destroy_for_testing(large_balance);
    clock::destroy_for_testing(clock);
    market_state::destroy_for_testing(ms);
    test_utils::destroy(escrow);
}

#[test]
#[expected_failure(abort_code = 1)] // EOUTCOME_OUT_OF_BOUNDS
fun test_register_supplies_invalid_outcome_fixed() {
    let mut ctx = create_test_context();
    let outcome_count = 2;
    let (ms, mut escrow) = setup_market_with_escrow(outcome_count, &mut ctx);
    
    // Try to register supplies for outcome index 2, which is out of bounds
    // This should fail with EOUTCOME_OUT_OF_BOUNDS (code 1)
    let market_state = coin_escrow::get_market_state(&escrow);
    let asset_supply = conditional_token::new_supply(market_state, TOKEN_TYPE_ASSET, 2, &mut ctx);
    let stable_supply = conditional_token::new_supply(market_state, TOKEN_TYPE_STABLE, 2, &mut ctx);
    
    coin_escrow::register_supplies(&mut escrow, 2, asset_supply, stable_supply);
    market_state::destroy_for_testing(ms);
    test_utils::destroy(escrow);
}

#[test]
#[expected_failure(abort_code = 6)] // EWRONG_OUTCOME
fun test_redeem_wrong_outcome_token_fixed() {
    let mut ctx = create_test_context();
    let outcome_count = 2;
    let (ms, mut escrow) = setup_market_with_escrow(outcome_count, &mut ctx);
    
    // Register supplies
    register_all_supplies(&mut escrow, outcome_count, &mut ctx);
    
    // Create clock for timestamps
    let clock = clock::create_for_testing(&mut ctx);
    
    // Initialize trading
    market_state::init_trading_for_testing(coin_escrow::get_market_state_mut(&mut escrow));
    
    // Create token for outcome 1 (not the winning outcome)
    let token = coin_escrow::create_asset_token_for_testing(
        &mut escrow,
        1,
        100,
        &clock,
        &mut ctx
    );
    
    // Finalize AFTER creating the token - this is key to fixing the test!
    market_state::finalize_for_testing(coin_escrow::get_market_state_mut(&mut escrow));
    
    // Try to redeem non-winning token - should fail with EWRONG_OUTCOME
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
fun test_supply_tracking_fixed() {
    let mut ctx = create_test_context();
    let outcome_count = 1;
    let (ms, mut escrow) = setup_market_with_escrow(outcome_count, &mut ctx);
    
    // Register supplies
    register_all_supplies(&mut escrow, outcome_count, &mut ctx);
    
    // Create clock for timestamps
    let clock = clock::create_for_testing(&mut ctx);
    
    // Initialize trading
    market_state::init_trading_for_testing(coin_escrow::get_market_state_mut(&mut escrow));
    
    // First check initial supply value (0)
    {
        let asset_supply = coin_escrow::get_asset_supply(&mut escrow, 0);
        assert!(conditional_token::total_supply(asset_supply) == 0, 0);
    };
    
    // Mint tokens
    let asset_coin = coin::mint_for_testing<DummyAsset>(1000, &mut ctx);
    let mut tokens = coin_escrow::mint_complete_set_asset(
        &mut escrow,
        asset_coin,
        &clock,
        &mut ctx
    );
    
    // Now check supply after minting
    {
        let asset_supply = coin_escrow::get_asset_supply(&mut escrow, 0);
        assert!(conditional_token::total_supply(asset_supply) == 1000, 1);
    };
    
    // Get the supply again for burning
    {
        let asset_supply = coin_escrow::get_asset_supply(&mut escrow, 0);
        
        // Burn the token
        let token = vector::pop_back(&mut tokens);
        conditional_token::burn(asset_supply, token, &clock, &mut ctx);
        
        // Check supply after burning
        assert!(conditional_token::total_supply(asset_supply) == 0, 2);
    };
    
    // Clean up
    vector::destroy_empty(tokens);
    clock::destroy_for_testing(clock);
    market_state::destroy_for_testing(ms);
    test_utils::destroy(escrow);
}

#[test]
#[expected_failure(abort_code = 2)] // EWRONG_MARKET (correct error code)
fun test_verify_token_set_wrong_market_fixed() {
    let mut ctx = create_test_context();
    let outcome_count = 2;
    let (ms1, mut escrow1) = setup_market_with_escrow(outcome_count, &mut ctx);
    let (ms2, mut escrow2) = setup_market_with_escrow(outcome_count, &mut ctx);
    
    // Register supplies for both escrows
    register_all_supplies(&mut escrow1, outcome_count, &mut ctx);
    register_all_supplies(&mut escrow2, outcome_count, &mut ctx);
    
    // Create clock for timestamps
    let clock = clock::create_for_testing(&mut ctx);
    
    // Initialize trading for both markets
    market_state::init_trading_for_testing(coin_escrow::get_market_state_mut(&mut escrow1));
    market_state::init_trading_for_testing(coin_escrow::get_market_state_mut(&mut escrow2));
    
    // Create a token from market 1
    let token1 = coin_escrow::create_asset_token_for_testing(
        &mut escrow1,
        0,
        100,
        &clock,
        &mut ctx
    );
    
    // Create a token from market 2
    let token2 = coin_escrow::create_asset_token_for_testing(
        &mut escrow2,
        1,
        100,
        &clock,
        &mut ctx
    );
    
    // Create a mixed vector of tokens from different markets
    let mut tokens = vector::empty<conditional_token::ConditionalToken>();
    vector::push_back(&mut tokens, token1);
    vector::push_back(&mut tokens, token2);
    
    // Try to redeem mixed tokens in market 1 - should fail with EWRONG_MARKET (code 2)
    let redeemed = coin_escrow::redeem_complete_set_asset(
        &mut escrow1,
        tokens,
        &clock,
        &mut ctx
    );
    
    // Should not reach here
    balance::destroy_for_testing(redeemed);
    clock::destroy_for_testing(clock);
    market_state::destroy_for_testing(ms1);
    market_state::destroy_for_testing(ms2);
    test_utils::destroy(escrow1);
    test_utils::destroy(escrow2);
}

#[test]
#[expected_failure(abort_code = 3)] // EWRONG_TOKEN_TYPE (correct error code)
fun test_verify_token_set_mixed_types_fixed() {
    let mut ctx = create_test_context();
    let outcome_count = 2;
    let (ms, mut escrow) = setup_market_with_escrow(outcome_count, &mut ctx);
    
    // Register supplies
    register_all_supplies(&mut escrow, outcome_count, &mut ctx);
    
    // Create clock for timestamps
    let clock = clock::create_for_testing(&mut ctx);
    
    // Initialize trading
    market_state::init_trading_for_testing(coin_escrow::get_market_state_mut(&mut escrow));
    
    // Create an asset token
    let asset_token = coin_escrow::create_asset_token_for_testing(
        &mut escrow,
        0,
        100,
        &clock,
        &mut ctx
    );
    
    // Create a stable token
    let stable_token = coin_escrow::create_stable_token_for_testing(
        &mut escrow,
        1,
        100,
        &clock,
        &mut ctx
    );
    
    // Create a mixed vector of token types
    let mut tokens = vector::empty<conditional_token::ConditionalToken>();
    vector::push_back(&mut tokens, asset_token);
    vector::push_back(&mut tokens, stable_token);
    
    // Try to redeem mixed token types - should fail with EWRONG_TOKEN_TYPE (code 3)
    let redeemed = coin_escrow::redeem_complete_set_asset(
        &mut escrow,
        tokens,
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
#[expected_failure(abort_code = 0)] // EINSUFFICIENT_BALANCE (correct error code)
fun test_verify_token_set_different_amounts_fixed() {
    let mut ctx = create_test_context();
    let outcome_count = 2;
    let (ms, mut escrow) = setup_market_with_escrow(outcome_count, &mut ctx);
    
    // Register supplies
    register_all_supplies(&mut escrow, outcome_count, &mut ctx);
    
    // Create clock for timestamps
    let clock = clock::create_for_testing(&mut ctx);
    
    // Initialize trading
    market_state::init_trading_for_testing(coin_escrow::get_market_state_mut(&mut escrow));
    
    // Create asset coin for first token
    let asset_coin1 = coin::mint_for_testing<DummyAsset>(100, &mut ctx);
    let mut tokens1 = coin_escrow::mint_complete_set_asset(
        &mut escrow, 
        asset_coin1, 
        &clock, 
        &mut ctx
    );
    
    // Create asset coin for second token with different amount
    let asset_coin2 = coin::mint_for_testing<DummyAsset>(200, &mut ctx);
    let mut tokens2 = coin_escrow::mint_complete_set_asset(
        &mut escrow, 
        asset_coin2, 
        &clock, 
        &mut ctx
    );
    
    // Create a mixed vector with different token amounts
    let mut mixed_tokens = vector::empty<conditional_token::ConditionalToken>();
    vector::push_back(&mut mixed_tokens, vector::pop_back(&mut tokens1)); // 100 amount
    vector::push_back(&mut mixed_tokens, vector::pop_back(&mut tokens2)); // 200 amount
    
    // Try to redeem tokens with different amounts - should fail with EINSUFFICIENT_BALANCE (code 0)
    let redeemed = coin_escrow::redeem_complete_set_asset(
        &mut escrow,
        mixed_tokens,
        &clock,
        &mut ctx
    );
    
    // Should not reach here
    balance::destroy_for_testing(redeemed);
    
    // Clean up remaining tokens
    while (!vector::is_empty(&tokens1)) {
        let token = vector::pop_back(&mut tokens1);
        transfer::public_transfer(token, tx_context::sender(&mut ctx));
    };
    while (!vector::is_empty(&tokens2)) {
        let token = vector::pop_back(&mut tokens2);
        transfer::public_transfer(token, tx_context::sender(&mut ctx));
    };
    
    vector::destroy_empty(tokens1);
    vector::destroy_empty(tokens2);
    clock::destroy_for_testing(clock);
    market_state::destroy_for_testing(ms);
    test_utils::destroy(escrow);
}
