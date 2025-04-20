#[test_only]
module futarchy::conditional_token_tests;

use futarchy::conditional_token::{Self, Supply, ConditionalToken};
use futarchy::market_state::{Self, MarketState};
use sui::clock::{Self, Clock};
use sui::test_scenario;

// Test constants
const ADMIN: address = @0xA;
const USER1: address = @0xB;
const USER2: address = @0xC;

const ASSET_TYPE_ASSET: u8 = 0;
#[allow(unused_const)]
const ASSET_TYPE_STABLE: u8 = 1;
const OUTCOME_YES: u8 = 0;
#[allow(unused_const)]
const OUTCOME_NO: u8 = 1;

// Test helper struct
public struct TestTradingCap has key, store {
    id: UID,
}

// Helper function to initialize market
fun init_market(ctx: &mut TxContext): (MarketState) {
    let market_state = market_state::create_for_testing(2, ctx);
    (market_state)
}

#[test]
fun test_supply_creation() {
    let mut scenario = test_scenario::begin(ADMIN); // Add mut

    test_scenario::next_tx(&mut scenario, ADMIN);
    {
        let ctx = test_scenario::ctx(&mut scenario);
        let (state) = init_market(ctx); // Add mut

        transfer::public_share_object(state);
    };

    // Test valid supply creation
    test_scenario::next_tx(&mut scenario, ADMIN);
    {
        let state = test_scenario::take_shared<MarketState>(&scenario);
        let ctx = test_scenario::ctx(&mut scenario);

        let supply = conditional_token::new_supply(
            &state,
            ASSET_TYPE_ASSET,
            OUTCOME_YES,
            ctx,
        );

        assert!(conditional_token::total_supply(&supply) == 0, 0);
        transfer::public_transfer(supply, ADMIN);

        test_scenario::return_shared(state);
    };

    test_scenario::end(scenario);
}

#[test]
fun test_mint_and_burn() {
    let mut scenario = test_scenario::begin(ADMIN);

    test_scenario::next_tx(&mut scenario, ADMIN);
    {
        let ctx = test_scenario::ctx(&mut scenario);
        let (mut state) = init_market(ctx);
        let mut clock = clock::create_for_testing(ctx);

        market_state::init_trading_for_testing(&mut state);
        clock::set_for_testing(&mut clock, 1000);

        transfer::public_share_object(state);
        clock::share_for_testing(clock);
    };

    test_scenario::next_tx(&mut scenario, ADMIN);
    {
        let state = test_scenario::take_shared<MarketState>(&scenario);
        let clock = test_scenario::take_shared<Clock>(&scenario);
        let ctx = test_scenario::ctx(&mut scenario);

        let mut supply = conditional_token::new_supply(
            &state,
            ASSET_TYPE_ASSET,
            OUTCOME_YES,
            ctx,
        );

        let token = conditional_token::mint(
            &state,
            &mut supply,
            100,
            USER1,
            &clock,
            ctx,
        );
        transfer::public_transfer(token, USER1);

        assert!(conditional_token::total_supply(&supply) == 100, 2);
        transfer::public_transfer(supply, ADMIN);

        test_scenario::return_shared(state);
        test_scenario::return_shared(clock);
    };

    // Burn tokens
    test_scenario::next_tx(&mut scenario, USER1);
    let token = test_scenario::take_from_sender<ConditionalToken>(&scenario);

    let clock = test_scenario::take_shared<Clock>(&scenario);

    test_scenario::next_tx(&mut scenario, ADMIN);
    {
        let mut supply = test_scenario::take_from_sender<Supply>(&scenario);
        let ctx = test_scenario::ctx(&mut scenario);

        conditional_token::burn(
            &mut supply,
            token,
            &clock,
            ctx,
        );
        assert!(conditional_token::total_supply(&supply) == 0, 3);

        test_scenario::return_to_sender(&scenario, supply);
    };
    test_scenario::return_shared(clock);
    test_scenario::end(scenario);
}

#[test]
fun test_split_and_merge() {
    let mut scenario = test_scenario::begin(ADMIN);

    // Setup initial state
    test_scenario::next_tx(&mut scenario, ADMIN);
    {
        let ctx = test_scenario::ctx(&mut scenario);
        let (mut state) = init_market(ctx);
        let mut clock = clock::create_for_testing(ctx);

        market_state::init_trading_for_testing(&mut state);
        clock::set_for_testing(&mut clock, 1000);

        transfer::public_share_object(state);
        clock::share_for_testing(clock);
    };

    // Mint initial token
    test_scenario::next_tx(&mut scenario, ADMIN);
    {
        let state = test_scenario::take_shared<MarketState>(&scenario);
        let clock = test_scenario::take_shared<Clock>(&scenario);
        let ctx = test_scenario::ctx(&mut scenario);

        let mut supply = conditional_token::new_supply(
            &state,
            ASSET_TYPE_ASSET,
            OUTCOME_YES,
            ctx,
        );

        let token = conditional_token::mint(
            &state,
            &mut supply,
            100,
            USER1,
            &clock,
            ctx,
        );

        transfer::public_transfer(token, USER1);
        transfer::public_transfer(supply, ADMIN);

        test_scenario::return_shared(state);
        test_scenario::return_shared(clock);
    };

    // Split token
    test_scenario::next_tx(&mut scenario, USER1);
    {
        let mut token = test_scenario::take_from_sender<ConditionalToken>(&scenario);
        let clock = test_scenario::take_shared<Clock>(&scenario);
        let ctx = test_scenario::ctx(&mut scenario);

        conditional_token::split(
            &mut token,
            40,
            USER2,
            &clock,
            ctx,
        );

        assert!(conditional_token::value(&token) == 60, 4);
        test_scenario::return_to_sender(&scenario, token);
        test_scenario::return_shared(clock);
    };

    test_scenario::end(scenario);
}

#[test]
fun test_merge_many() {
    let mut scenario = test_scenario::begin(ADMIN);

    // Setup initial state
    test_scenario::next_tx(&mut scenario, ADMIN);
    {
        let ctx = test_scenario::ctx(&mut scenario);
        let (mut state) = init_market(ctx);
        let mut clock = clock::create_for_testing(ctx);

        market_state::init_trading_for_testing(&mut state);
        clock::set_for_testing(&mut clock, 1000);

        transfer::public_share_object(state);
        clock::share_for_testing(clock);
    };

    // Mint multiple tokens to different users
    test_scenario::next_tx(&mut scenario, ADMIN);
    {
        let state = test_scenario::take_shared<MarketState>(&scenario);
        let clock = test_scenario::take_shared<Clock>(&scenario);
        let ctx = test_scenario::ctx(&mut scenario);

        let mut supply = conditional_token::new_supply(
            &state,
            ASSET_TYPE_ASSET,
            OUTCOME_YES,
            ctx,
        );

        // Mint base token for USER1
        let token1 = conditional_token::mint(
            &state,
            &mut supply,
            50,
            USER1,
            &clock,
            ctx,
        );
        transfer::public_transfer(token1, USER1);

        // Mint tokens to be merged
        let token2 = conditional_token::mint(
            &state,
            &mut supply,
            20,
            USER2,
            &clock,
            ctx,
        );
        transfer::public_transfer(token2, USER2);

        let token3 = conditional_token::mint(
            &state,
            &mut supply,
            30,
            USER2,
            &clock,
            ctx,
        );
        transfer::public_transfer(token3, USER2);

        transfer::public_transfer(supply, ADMIN);

        test_scenario::return_shared(state);
        test_scenario::return_shared(clock);
    };

    // Prepare tokens for merge
    test_scenario::next_tx(&mut scenario, USER2);
    {
        let token2 = test_scenario::take_from_sender<ConditionalToken>(&scenario);
        let token3 = test_scenario::take_from_sender<ConditionalToken>(&scenario);
        let clock = test_scenario::take_shared<Clock>(&scenario);

        test_scenario::next_tx(&mut scenario, USER1);
        let mut base_token = test_scenario::take_from_sender<ConditionalToken>(&scenario);
        let ctx = test_scenario::ctx(&mut scenario);

        // Create vector of tokens to merge
        let mut tokens_to_merge = vector::empty();
        vector::push_back(&mut tokens_to_merge, token2);
        vector::push_back(&mut tokens_to_merge, token3);

        // Verify initial values
        assert!(conditional_token::value(&base_token) == 50, 7);

        // Merge multiple tokens
        conditional_token::merge_many(
            &mut base_token,
            tokens_to_merge,
            &clock,
            ctx,
        );

        // Verify final merged amount
        assert!(conditional_token::value(&base_token) == 100, 8);

        test_scenario::return_to_sender(&scenario, base_token);
        test_scenario::return_shared(clock);
    };

    test_scenario::end(scenario);
}

#[test]
fun test_merge_large_number_of_tokens() {
    let mut scenario = test_scenario::begin(ADMIN);
    
    // Setup
    test_scenario::next_tx(&mut scenario, ADMIN);
    {
        let ctx = test_scenario::ctx(&mut scenario);
        let (mut state) = init_market(ctx);
        let mut clock = clock::create_for_testing(ctx);
        
        market_state::init_trading_for_testing(&mut state);
        
        transfer::public_share_object(state);
        clock::share_for_testing(clock);
    };
    
    // Create base token and many small tokens
    test_scenario::next_tx(&mut scenario, ADMIN);
    {
        let state = test_scenario::take_shared<MarketState>(&scenario);
        let clock = test_scenario::take_shared<Clock>(&scenario);
        let ctx = test_scenario::ctx(&mut scenario);
        
        let mut supply = conditional_token::new_supply(
            &state,
            ASSET_TYPE_ASSET,
            OUTCOME_YES,
            ctx,
        );
        
        // Create base token
        let base_token = conditional_token::mint(
            &state,
            &mut supply,
            1000,  // Large enough value
            USER1,
            &clock,
            ctx,
        );
        transfer::public_transfer(base_token, USER1);
        
        // Create 20 small tokens (simulating a real-world scenario)
        let token_count = 20;
        let mut i = 0;
        while (i < token_count) {
            let token = conditional_token::mint(
                &state,
                &mut supply,
                5, // Small value
                USER2,
                &clock,
                ctx,
            );
            transfer::public_transfer(token, USER2);
            i = i + 1;
        };
        
        transfer::public_transfer(supply, ADMIN);
        
        test_scenario::return_shared(state);
        test_scenario::return_shared(clock);
    };
    
    // Collect tokens for merging
    let mut tokens_to_merge = vector::empty<ConditionalToken>();
    let token_count = 20;
    
    test_scenario::next_tx(&mut scenario, USER2);
    {
        let mut i = 0;
        while (i < token_count) {
            let token = test_scenario::take_from_sender<ConditionalToken>(&scenario);
            vector::push_back(&mut tokens_to_merge, token);
            i = i + 1;
        };
    };
    
    // Perform merge with the base token
    test_scenario::next_tx(&mut scenario, USER1);
    {
        let mut base_token = test_scenario::take_from_sender<ConditionalToken>(&scenario);
        let clock = test_scenario::take_shared<Clock>(&scenario);
        let ctx = test_scenario::ctx(&mut scenario);
        
        // Initial value
        let initial_value = conditional_token::value(&base_token);
        
        // Merge many tokens
        conditional_token::merge_many(
            &mut base_token,
            tokens_to_merge,
            &clock,
            ctx,
        );
        
        // Verify final value: initial + (5 * 20)
        assert!(conditional_token::value(&base_token) == initial_value + (5 * 20), 1);
        
        test_scenario::return_to_sender(&scenario, base_token);
        test_scenario::return_shared(clock);
    };
    
    test_scenario::end(scenario);
}

#[test]
#[expected_failure(abort_code = 3)] // Use actual error code from your module
fun test_mint_after_trading_closed() {
    let mut scenario = test_scenario::begin(ADMIN);
    
    // Setup market and close trading
    test_scenario::next_tx(&mut scenario, ADMIN);
    {
        let ctx = test_scenario::ctx(&mut scenario);
        let (mut state) = init_market(ctx);
        let mut clock = clock::create_for_testing(ctx);
        
        market_state::init_trading_for_testing(&mut state);

        market_state::destroy_for_testing(state); // Assuming this exists
        clock::share_for_testing(clock);
    };
    
    // Attempt to mint after trading closed
    test_scenario::next_tx(&mut scenario, ADMIN);
    {
        let state = test_scenario::take_shared<MarketState>(&scenario);
        let clock = test_scenario::take_shared<Clock>(&scenario);
        let ctx = test_scenario::ctx(&mut scenario);
        
        let mut supply = conditional_token::new_supply(
            &state,
            ASSET_TYPE_ASSET,
            OUTCOME_YES,
            ctx,
        );
        
        // This should fail
        let token = conditional_token::mint(
            &state,
            &mut supply,
            100,
            USER1,
            &clock,
            ctx,
        );
        
        transfer::public_transfer(token, USER1);
        transfer::public_transfer(supply, ADMIN);
        
        test_scenario::return_shared(state);
        test_scenario::return_shared(clock);
    };
    
    test_scenario::end(scenario);
}

#[test]
#[expected_failure(abort_code = 5)]
fun test_split_edge_cases() {
    let mut scenario = test_scenario::begin(ADMIN);
    
    // Setup
    test_scenario::next_tx(&mut scenario, ADMIN);
    {
        let ctx = test_scenario::ctx(&mut scenario);
        let (mut state) = init_market(ctx);
        let mut clock = clock::create_for_testing(ctx);
        
        market_state::init_trading_for_testing(&mut state);
        
        transfer::public_share_object(state);
        clock::share_for_testing(clock);
    };
    
    // Mint token
    test_scenario::next_tx(&mut scenario, ADMIN);
    {
        let state = test_scenario::take_shared<MarketState>(&scenario);
        let clock = test_scenario::take_shared<Clock>(&scenario);
        let ctx = test_scenario::ctx(&mut scenario);
        
        let mut supply = conditional_token::new_supply(
            &state,
            ASSET_TYPE_ASSET,
            OUTCOME_YES,
            ctx,
        );
        
        let token = conditional_token::mint(
            &state,
            &mut supply,
            100,
            USER1,
            &clock,
            ctx,
        );
        
        transfer::public_transfer(token, USER1);
        transfer::public_transfer(supply, ADMIN);
        
        test_scenario::return_shared(state);
        test_scenario::return_shared(clock);
    };
    
    // Test splitting entire value
    test_scenario::next_tx(&mut scenario, USER1);
    {
        let mut token = test_scenario::take_from_sender<ConditionalToken>(&scenario);
        let clock = test_scenario::take_shared<Clock>(&scenario);
        let ctx = test_scenario::ctx(&mut scenario);
        
        // Split the entire value of the token
        conditional_token::split(
            &mut token,
            100,
            USER2,
            &clock,
            ctx,
        );
        
        // Original token should have 0 value
        assert!(conditional_token::value(&token) == 0, 1);
        
        test_scenario::return_to_sender(&scenario, token);
        test_scenario::return_shared(clock);
    };
    
    test_scenario::end(scenario);
}

#[test]
fun test_token_properties() {
    let mut scenario = test_scenario::begin(ADMIN);
    
    // Setup
    test_scenario::next_tx(&mut scenario, ADMIN);
    {
        let ctx = test_scenario::ctx(&mut scenario);
        let (mut state) = init_market(ctx);
        
        market_state::init_trading_for_testing(&mut state);
        transfer::public_share_object(state);
    };
    
    // Create token and verify properties
    test_scenario::next_tx(&mut scenario, ADMIN);
    {
        let state = test_scenario::take_shared<MarketState>(&scenario);
        let ctx = test_scenario::ctx(&mut scenario);
        let mut clock = clock::create_for_testing(ctx);
        
        let mut supply = conditional_token::new_supply(
            &state,
            ASSET_TYPE_ASSET,
            OUTCOME_YES,
            ctx,
        );
        
        let token = conditional_token::mint(
            &state,
            &mut supply,
            100,
            USER1,
            &clock,
            ctx,
        );
        
        // Verify token properties
        assert!(conditional_token::market_id(&token) == market_state::market_id(&state), 0);
        assert!(conditional_token::asset_type(&token) == ASSET_TYPE_ASSET, 1);
        assert!(conditional_token::outcome(&token) == OUTCOME_YES, 2);
        assert!(conditional_token::value(&token) == 100, 3);
        
        transfer::public_transfer(token, USER1);
        transfer::public_transfer(supply, ADMIN);
        clock::share_for_testing(clock);
        
        test_scenario::return_shared(state);
    };
    
    test_scenario::end(scenario);
}