#[test_only]
module futarchy::proposal_path_tests;

use futarchy::advance_stage;
use futarchy::coin_escrow::{Self, TokenEscrow};
use futarchy::fee;
use futarchy::liquidity_interact;
use futarchy::market_state;
use futarchy::proposal::{Self, Proposal};
use futarchy::conditional_token;
use std::option;
use std::string::{Self, String};
use std::vector;
use sui::balance;
use sui::clock::{Self, Clock};
use sui::object::{Self, ID};
use sui::test_scenario::{Self as test, Scenario, next_tx, ctx};
use sui::transfer;
use sui::tx_context;
use sui::coin;
use futarchy::swap;

const ADMIN: address = @0xcafe;
const DAO: address = @0xda0;

const MIN_ASSET_LIQUIDITY: u64 = 1_000_000;
const MIN_STABLE_LIQUIDITY: u64 = 1_000_000;
const STARTING_TIMESTAMP: u64 = 1_000_000_000;
const TWAP_INITIAL_OBSERVATION: u128 = 1_000_000;
const TWAP_START_DELAY: u64 = 60_000;
const TWAP_STEP_MAX: u64 = 10_000_000;

// State constants
const STATE_REVIEW: u8 = 0;
const STATE_TRADING: u8 = 1;
const STATE_FINALIZED: u8 = 2;
const REVIEW_PERIOD_MS: u64 = 2_000_000; // 2 seconds
const TRADING_PERIOD_MS: u64 = 2_000_00; // 0.2 seconds
const TWAP_THRESHOLD: u64 = 1;

// Helper function to set up a test proposal
fun setup_test_proposal(scenario: &mut Scenario, clock: &Clock) {
    let asset_balance = balance::create_for_testing<u64>(MIN_ASSET_LIQUIDITY);
    let stable_balance = balance::create_for_testing<u64>(MIN_STABLE_LIQUIDITY);
    let dao_id = object::id_from_address(DAO);

    let mut outcome_messages = vector::empty<String>();
    vector::push_back(&mut outcome_messages, string::utf8(b"Outcome 0"));
    vector::push_back(&mut outcome_messages, string::utf8(b"Outcome 1"));

    let (_proposal_id, _market_state_id, _state) = proposal::create<u64, u64>(
        dao_id,
        2, // outcome_count
        asset_balance,
        stable_balance,
        REVIEW_PERIOD_MS,
        TRADING_PERIOD_MS,
        MIN_ASSET_LIQUIDITY,
        MIN_STABLE_LIQUIDITY,
        string::utf8(b"Test Proposal"), // title
        string::utf8(b"Test Details"), // details
        string::utf8(b"Test Metadata"), // metadata
        outcome_messages,
        TWAP_START_DELAY,
        TWAP_INITIAL_OBSERVATION,
        TWAP_STEP_MAX,
        option::none<vector<u64>>(), // initial_outcome_amounts
        TWAP_THRESHOLD,
        clock,
        ctx(scenario),
    );

    // Create a FeeManager for testing
    fee::create_fee_manager_for_testing(ctx(scenario));
}

#[test]
fun test_proposal_complete_happy_path() {
    let mut scenario = test::begin(ADMIN);
    let mut clock = clock::create_for_testing(ctx(&mut scenario));
    clock::set_for_testing(&mut clock, STARTING_TIMESTAMP);

    // Step 1: Create proposal
    next_tx(&mut scenario, ADMIN);
    {
        setup_test_proposal(&mut scenario, &clock);
    };

    // Step 2: Verify proposal was created correctly
    next_tx(&mut scenario, ADMIN);
    {
        let proposal = test::take_shared<Proposal<u64, u64>>(&scenario);
        let escrow = test::take_shared<TokenEscrow<u64, u64>>(&scenario);

        assert!(proposal::state(&proposal) == STATE_REVIEW, 0);
        assert!(proposal::outcome_count(&proposal) == 2, 1);
        assert!(proposal::proposer(&proposal) == ADMIN, 2);

        // Check initial liquidity
        let (asset_bal, stable_bal) = coin_escrow::get_balances(&escrow);
        assert!(asset_bal == MIN_ASSET_LIQUIDITY, 3);
        assert!(stable_bal == MIN_STABLE_LIQUIDITY, 4);

        test::return_shared(proposal);
        test::return_shared(escrow);
    };

    // Step 3: Transition to trading state
    clock::set_for_testing(&mut clock, STARTING_TIMESTAMP + REVIEW_PERIOD_MS + 100);
    next_tx(&mut scenario, ADMIN);
    {
        let mut proposal = test::take_shared<Proposal<u64, u64>>(&scenario);
        let mut escrow = test::take_shared<TokenEscrow<u64, u64>>(&scenario);
        let market_state = coin_escrow::get_market_state_mut(&mut escrow);

        advance_stage::try_advance_state(&mut proposal, market_state, &clock);
        assert!(proposal::state(&proposal) == STATE_TRADING, 5);

        test::return_shared(proposal);
        test::return_shared(escrow);
    };

    // Step 4: Advance to finalization
    clock::set_for_testing(
        &mut clock,
        STARTING_TIMESTAMP + REVIEW_PERIOD_MS + TRADING_PERIOD_MS + 100,
    );
    next_tx(&mut scenario, ADMIN);
    {
        let mut proposal = test::take_shared<Proposal<u64, u64>>(&scenario);
        let mut escrow = test::take_shared<TokenEscrow<u64, u64>>(&scenario);
        let mut fee_manager = test::take_shared<fee::FeeManager>(&scenario);

        advance_stage::try_advance_state_entry(
            &mut proposal,
            &mut escrow,
            &mut fee_manager,
            &clock,
        );
        assert!(proposal::state(&proposal) == STATE_FINALIZED, 6);
        assert!(proposal::is_winning_outcome_set(&proposal), 7);

        // Check that winning outcome was determined (most likely outcome 0 since we didn't trade)
        let winning_outcome = proposal::get_winning_outcome(&proposal);
        assert!(winning_outcome == 0, 8); // We expect outcome 0 to win by default

        test::return_shared(proposal);
        test::return_shared(escrow);
        test::return_shared(fee_manager);
    };

    // Step 5: Admin extracts liquidity from the winning outcome pool & Verify Balances
    next_tx(&mut scenario, ADMIN);
    {
        let mut proposal = test::take_shared<Proposal<u64, u64>>(&scenario);
        let mut escrow = test::take_shared<TokenEscrow<u64, u64>>(&scenario);
        let winning_outcome = proposal::get_winning_outcome(&proposal);

        // Extract liquidity (moves funds from AMM back to escrow)
        liquidity_interact::empty_all_amm_liquidity(
            &mut proposal,
            &mut escrow,
            winning_outcome,
            &clock,
            ctx(&mut scenario),
        );

        // ---- Start: Added Check ----
        // Call the function to get current escrow balances and winning token supplies
        let (
            escrow_asset,
            escrow_stable,
            winning_supply_asset,
            winning_supply_stable
        ) = coin_escrow::get_escrow_balances_and_supply(
            &escrow,
            winning_outcome, // Pass the winner index
        );

        // Assert that the escrow balances now match the total supply of the winning tokens
        // This verifies that after pulling liquidity back, the escrow holds exactly
        // what's needed to cover redemptions of winning tokens.
        assert!(escrow_asset == winning_supply_asset, 9); // New assertion code 9
        assert!(escrow_stable == winning_supply_stable, 10); // New assertion code 10
        // ---- End: Added Check ----


        // Note: The old assertions checking for balance decrease were removed as they
        // are generally incorrect after emptying liquidity (balances should increase/stay same).

        test::return_shared(proposal);
        test::return_shared(escrow);
    };

    // Step 6: Verify that stable fees were collected (or check function runs)
    next_tx(&mut scenario, ADMIN);
    {
        let fee_manager = test::take_shared<fee::FeeManager>(&scenario);
        let stable_fees = fee::get_stable_fee_balance<u64>(&fee_manager);
        // In the happy path with no swaps, fees should be 0.
        assert!(stable_fees == 0, 11); // Changed assertion code to 11

        test::return_shared(fee_manager);
    };

    clock::destroy_for_testing(clock);
    test::end(scenario);
}

#[test]
fun test_proposal_path_with_swaps() {
    let mut scenario = test::begin(ADMIN);
    let mut clock = clock::create_for_testing(ctx(&mut scenario));
    clock::set_for_testing(&mut clock, STARTING_TIMESTAMP);

    // Storage for values we need to compare across transactions
    let mut initial_asset_0 = 0;
    let mut initial_stable_0 = 0;
    let mut initial_asset_1 = 0;
    let mut initial_stable_1 = 0;

    // Step 1: Create proposal
    next_tx(&mut scenario, ADMIN);
    {
        setup_test_proposal(&mut scenario, &clock);
    };

    // Step 2: Transition to trading state and capture initial liquidity
    clock::set_for_testing(&mut clock, STARTING_TIMESTAMP + REVIEW_PERIOD_MS + 100);
    next_tx(&mut scenario, ADMIN);
    {
        let mut proposal = test::take_shared<Proposal<u64, u64>>(&scenario);
        let mut escrow = test::take_shared<TokenEscrow<u64, u64>>(&scenario);
        let market_state = coin_escrow::get_market_state_mut(&mut escrow);

        advance_stage::try_advance_state(&mut proposal, market_state, &clock);
        assert!(proposal::state(&proposal) == STATE_TRADING, 0);
        
        // Capture initial liquidity values
        let initial_liquidity = liquidity_interact::get_liquidity_for_proposal(&proposal);
        initial_asset_0 = *vector::borrow(&initial_liquidity, 0);
        initial_stable_0 = *vector::borrow(&initial_liquidity, 1);
        initial_asset_1 = *vector::borrow(&initial_liquidity, 2);
        initial_stable_1 = *vector::borrow(&initial_liquidity, 3);

        test::return_shared(proposal);
        test::return_shared(escrow);
    };

    // Step 3: Perform multiple swaps over time to influence TWAP
    
    // First batch of swaps - create_and_swap_asset_to_stable_entry
    next_tx(&mut scenario, ADMIN);
    {
        let mut proposal = test::take_shared<Proposal<u64, u64>>(&scenario);
        let mut escrow = test::take_shared<TokenEscrow<u64, u64>>(&scenario);
        
        // First swap - bet against outcome 0
        let asset_coin = coin::from_balance(balance::create_for_testing<u64>(1_000_000), ctx(&mut scenario));
        swap::create_and_swap_asset_to_stable_entry(
            &mut proposal,
            &mut escrow,
            0, // outcome_idx
            0, // min_amount_out
            asset_coin,
            &clock,
            ctx(&mut scenario),
        );
        
        test::return_shared(proposal);
        test::return_shared(escrow);
    };

    // Advance time a bit to let TWAP update
    clock::set_for_testing(
        &mut clock,
        STARTING_TIMESTAMP + REVIEW_PERIOD_MS + 200,
    );

    // Second batch - create_and_swap_stable_to_asset_entry and swap_stable_to_asset_entry
    next_tx(&mut scenario, ADMIN);
    {
        let mut proposal = test::take_shared<Proposal<u64, u64>>(&scenario);
        let mut escrow = test::take_shared<TokenEscrow<u64, u64>>(&scenario);
        
        // Create tokens for swap_stable_to_asset_entry
        let stable_coin = coin::from_balance(balance::create_for_testing<u64>(500_000), ctx(&mut scenario));
        let mut tokens = coin_escrow::mint_complete_set_stable(&mut escrow, stable_coin, &clock, ctx(&mut scenario));
        let token_to_swap = vector::remove(&mut tokens, 1); // Get outcome 1 stable token
        
        // Swap stable token for outcome 1
        swap::swap_stable_to_asset_entry(
            &mut proposal,
            &mut escrow,
            1, // outcome_idx
            token_to_swap,
            0,
            &clock,
            ctx(&mut scenario),
        );
        
        // Clean up remaining tokens
        while (!vector::is_empty(&tokens)) {
            let token = vector::pop_back(&mut tokens);
            transfer::public_transfer(token, ADMIN);
        };
        vector::destroy_empty(tokens);
        
        // Create more stable coins for the next swap
        let stable_coin = coin::from_balance(balance::create_for_testing<u64>(2_000_000), ctx(&mut scenario));
        swap::create_and_swap_stable_to_asset_entry(
            &mut proposal,
            &mut escrow,
            1, // outcome_idx
            0, // min_amount_out
            stable_coin,
            &clock,
            ctx(&mut scenario),
        );
        
        test::return_shared(proposal);
        test::return_shared(escrow);
    };

    // Advance time again to let TWAP update
    clock::set_for_testing(
        &mut clock,
        STARTING_TIMESTAMP + REVIEW_PERIOD_MS + 300,
    );

    // Third batch - swap_asset_to_stable_entry and create_and_swap_asset_to_stable_with_existing
    next_tx(&mut scenario, ADMIN);
    {
        let mut proposal = test::take_shared<Proposal<u64, u64>>(&scenario);
        let mut escrow = test::take_shared<TokenEscrow<u64, u64>>(&scenario);
        
        // Create tokens for swap_asset_to_stable_entry
        let asset_coin = coin::from_balance(balance::create_for_testing<u64>(500_000), ctx(&mut scenario));
        let mut tokens = coin_escrow::mint_complete_set_asset(&mut escrow, asset_coin, &clock, ctx(&mut scenario));
        let token_to_swap = vector::remove(&mut tokens, 0); // Get outcome 0 asset token
        
        // Swap asset token for outcome 0
        swap::swap_asset_to_stable_entry(
            &mut proposal,
            &mut escrow,
            0, // outcome_idx
            token_to_swap,
            0,
            &clock,
            ctx(&mut scenario),
        );
        
        // Clean up remaining tokens
        while (!vector::is_empty(&tokens)) {
            let token = vector::pop_back(&mut tokens);
            transfer::public_transfer(token, ADMIN);
        };
        vector::destroy_empty(tokens);
        
        // Create tokens for with_existing test
        let asset_coin = coin::from_balance(balance::create_for_testing<u64>(500_000), ctx(&mut scenario));
        let mut tokens = coin_escrow::mint_complete_set_asset(&mut escrow, asset_coin, &clock, ctx(&mut scenario));
        let existing_token = vector::remove(&mut tokens, 0); // Get outcome 0 asset token
        
        // Clean up remaining tokens
        while (!vector::is_empty(&tokens)) {
            let token = vector::pop_back(&mut tokens);
            transfer::public_transfer(token, ADMIN);
        };
        vector::destroy_empty(tokens);
        
        // Create and swap with existing asset token
        let asset_coin = coin::from_balance(balance::create_for_testing<u64>(1_500_000), ctx(&mut scenario));
        swap::create_and_swap_asset_to_stable_with_existing_entry(
            &mut proposal,
            &mut escrow,
            0, // outcome_idx
            existing_token,
            0, // min_amount_out
            asset_coin,
            &clock,
            ctx(&mut scenario),
        );
        
        test::return_shared(proposal);
        test::return_shared(escrow);
    };

    // Advance time again
    clock::set_for_testing(
        &mut clock,
        STARTING_TIMESTAMP + REVIEW_PERIOD_MS + 400,
    );

    // Fourth batch - create_and_swap_stable_to_asset_with_existing
    next_tx(&mut scenario, ADMIN);
    {
        let mut proposal = test::take_shared<Proposal<u64, u64>>(&scenario);
        let mut escrow = test::take_shared<TokenEscrow<u64, u64>>(&scenario);
        
        // Create tokens for with_existing test
        let stable_coin = coin::from_balance(balance::create_for_testing<u64>(500_000), ctx(&mut scenario));
        let mut tokens = coin_escrow::mint_complete_set_stable(&mut escrow, stable_coin, &clock, ctx(&mut scenario));
        let existing_token = vector::remove(&mut tokens, 1); // Get outcome 1 stable token
        
        // Clean up remaining tokens
        while (!vector::is_empty(&tokens)) {
            let token = vector::pop_back(&mut tokens);
            transfer::public_transfer(token, ADMIN);
        };
        vector::destroy_empty(tokens);
        
        // Create and swap with existing stable token
        let stable_coin = coin::from_balance(balance::create_for_testing<u64>(100_000_000), ctx(&mut scenario));
        swap::create_and_swap_stable_to_asset_with_existing_entry(
            &mut proposal,
            &mut escrow,
            1, // outcome_idx
            existing_token,
            0, // min_amount_out
            stable_coin,
            &clock,
            ctx(&mut scenario),
        );
        
        // Verify the liquidity has changed after our swaps
        let post_swap_liquidity = liquidity_interact::get_liquidity_for_proposal(&proposal);
        assert!(*vector::borrow(&post_swap_liquidity, 0) > initial_asset_0, 1); // More assets in pool 0
        assert!(*vector::borrow(&post_swap_liquidity, 3) > initial_stable_1, 2); // More stable in pool 1
        
        test::return_shared(proposal);
        test::return_shared(escrow);
    };

    // Step 4: Advance to finalization
    clock::set_for_testing(
        &mut clock,
        STARTING_TIMESTAMP + REVIEW_PERIOD_MS + TRADING_PERIOD_MS + 1_000_000_000,
    );
    next_tx(&mut scenario, ADMIN);
    {
        let mut proposal = test::take_shared<Proposal<u64, u64>>(&scenario);
        let mut escrow = test::take_shared<TokenEscrow<u64, u64>>(&scenario);
        let mut fee_manager = test::take_shared<fee::FeeManager>(&scenario);

        advance_stage::try_advance_state_entry(
            &mut proposal,
            &mut escrow,
            &mut fee_manager,
            &clock,
        );
        assert!(proposal::state(&proposal) == STATE_FINALIZED, 3);
        assert!(proposal::is_winning_outcome_set(&proposal), 4);

        let twaps = proposal::get_twaps_for_proposal(&mut proposal, &clock);
        
        // Print TWAP values to debug
        std::debug::print(&twaps);
        
        // Due to our trading, outcome 1 should now be the winner
        let winning_outcome = proposal::get_winning_outcome(&proposal);
        assert!(winning_outcome == 1, 5); // We expect outcome 1 to win based on our trading
        
        test::return_shared(proposal);
        test::return_shared(escrow);
        test::return_shared(fee_manager);
    };

    // Step 5: Check fees were collected
    next_tx(&mut scenario, ADMIN);
    {
        let fee_manager = test::take_shared<fee::FeeManager>(&scenario);
        let stable_fees = fee::get_stable_fee_balance<u64>(&fee_manager);
        assert!(stable_fees > 0, 6); // Should have collected fees from swaps

        test::return_shared(fee_manager);
    };

    // Step 6: Empty AMM liquidity for the winning outcome
    next_tx(&mut scenario, ADMIN);
    {
        let mut proposal = test::take_shared<Proposal<u64, u64>>(&scenario);
        let mut escrow = test::take_shared<TokenEscrow<u64, u64>>(&scenario);
        let winning_outcome = proposal::get_winning_outcome(&proposal);

        // Get escrow balances *before* emptying liquidity (optional comparison point)
        let (asset_before, stable_before) = coin_escrow::get_balances(&escrow);

        // Extract liquidity from the *winning* AMM pool
        liquidity_interact::empty_all_amm_liquidity(
            &mut proposal,
            &mut escrow,
            winning_outcome,
            &clock,
            ctx(&mut scenario),
        );

        // Verify escrow balances have *not* necessarily decreased here.
        // Emptying liquidity *returns* the underlying coins from the AMM *to* the escrow.
        // The total amount available for redemption *increases* (or stays same if pool was empty).
        // The balances only decrease when users redeem winning tokens.
        let (asset_after, stable_after) = coin_escrow::get_balances(&escrow);
        // We can't make simple assertions like asset_after < asset_before here.
        // We expect the balances might *increase* as liquidity returns to the escrow.
        // The critical check is the next step.

        test::return_shared(proposal);
        test::return_shared(escrow);
    };

    // Step 7: Verify Escrow Balances Match Winning Token Supplies via Tuple Return
    next_tx(&mut scenario, ADMIN);
    {
        let proposal = test::take_shared<Proposal<u64, u64>>(&scenario);
        let escrow = test::take_shared<TokenEscrow<u64, u64>>(&scenario);
        let winning_outcome = proposal::get_winning_outcome(&proposal);

        // Call the modified function, passing the winning_outcome
        // It now returns a tuple directly
        let (
            escrow_asset,
            escrow_stable,
            winning_supply_asset,
            winning_supply_stable
        ) = coin_escrow::get_escrow_balances_and_supply(
            &escrow,
            winning_outcome, // Pass the winner index
        );

        // Assert that the escrow balance for each type equals the total supply
        // of the winning token type using the unpacked tuple values
        assert!(escrow_asset == winning_supply_asset, 9); // Asset balance matches winning asset token supply
        assert!(escrow_stable == winning_supply_stable, 10); // Stable balance matches winning stable token supply

        // Optional: Print values for debugging
        // debug::print(&winning_outcome);
        // debug::print(&escrow_asset);
        // debug::print(&escrow_stable);
        // debug::print(&winning_supply_asset);
        // debug::print(&winning_supply_stable);

        test::return_shared(proposal);
        test::return_shared(escrow);
    };

    clock::destroy_for_testing(clock);
    test::end(scenario);
}