#[test_only]
module futarchy::conditional_token_tests;

use futarchy::conditional_token::{Self, Supply, ConditionalToken};
use futarchy::market_state::{Self, MarketState};
use sui::clock::{Self, Clock, create_for_testing, set_for_testing, share_for_testing};
use sui::test_scenario::{Self as test, next_tx, ctx, take_shared, return_shared, begin, end, take_from_sender, return_to_sender};

// Test constants
const ADMIN: address = @0xA;
const USER1: address = @0xB;
const USER2: address = @0xC;

const ASSET_TYPE_ASSET: u8 = 0;
#[allow(unused_const)]
const ASSET_TYPE_STABLE: u8 = 1;
const OUTCOME_ACCEPTED: u8 = 0;
#[allow(unused_const)]
const OUTCOME_REJECTED: u8 = 1;

// Test helper struct
public struct TestTradingCap has key, store {
    id: UID,
}

// Helper function to initialize market
fun init_market(ctx: &mut TxContext): MarketState {
    market_state::create_for_testing(2, ctx)
}

#[test]
fun test_supply_creation() {
    let mut scenario = begin(ADMIN);

    next_tx(&mut scenario, ADMIN);
    {
        let ctx = ctx(&mut scenario);
        let state = init_market(ctx);

        transfer::public_share_object(state);
    };

    // Test valid supply creation
    next_tx(&mut scenario, ADMIN);
    {
        let state = take_shared<MarketState>(&scenario);
        let ctx = ctx(&mut scenario);

        let supply = conditional_token::new_supply(
            &state,
            ASSET_TYPE_ASSET,
            OUTCOME_ACCEPTED,
            ctx,
        );

        assert!(conditional_token::total_supply(&supply) == 0, 0);
        transfer::public_transfer(supply, ADMIN);

        return_shared(state);
    };

    end(scenario);
}

#[test]
fun test_mint_and_burn() {
    let mut scenario = begin(ADMIN);

    next_tx(&mut scenario, ADMIN);
    {
        let ctx = ctx(&mut scenario);
        let (mut state) = init_market(ctx);
        let mut clock = create_for_testing(ctx);

        market_state::init_trading_for_testing(&mut state);
        set_for_testing(&mut clock, 1000);

        transfer::public_share_object(state);
        share_for_testing(clock);
    };

    next_tx(&mut scenario, ADMIN);
    {
        let state = take_shared<MarketState>(&scenario);
        let clock = take_shared<Clock>(&scenario);
        let ctx = ctx(&mut scenario);

        let mut supply = conditional_token::new_supply(
            &state,
            ASSET_TYPE_ASSET,
            OUTCOME_ACCEPTED,
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

        return_shared(state);
        return_shared(clock);
    };

    // Burn tokens
    next_tx(&mut scenario, USER1);
    let token = take_from_sender<ConditionalToken>(&scenario);

    let clock = take_shared<Clock>(&scenario);

    next_tx(&mut scenario, ADMIN);
    {
        let mut supply = take_from_sender<Supply>(&scenario);
        let ctx = ctx(&mut scenario);

        token.burn(
            &mut supply,
            &clock,
            ctx,
        );
        assert!(conditional_token::total_supply(&supply) == 0, 3);

        return_to_sender(&scenario, supply);
    };
    return_shared(clock);
    end(scenario);
}

#[test]
fun test_split_and_merge() {
    let mut scenario = begin(ADMIN);

    // Setup initial state
    next_tx(&mut scenario, ADMIN);
    {
        let ctx = ctx(&mut scenario);
        let (mut state) = init_market(ctx);
        let mut clock = create_for_testing(ctx);

        market_state::init_trading_for_testing(&mut state);
        set_for_testing(&mut clock, 1000);

        transfer::public_share_object(state);
        share_for_testing(clock);
    };

    // Mint initial token
    next_tx(&mut scenario, ADMIN);
    {
        let state = take_shared<MarketState>(&scenario);
        let clock = take_shared<Clock>(&scenario);
        let ctx = ctx(&mut scenario);

        let mut supply = conditional_token::new_supply(
            &state,
            ASSET_TYPE_ASSET,
            OUTCOME_ACCEPTED,
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

        return_shared(state);
        return_shared(clock);
    };

    // Split token
    next_tx(&mut scenario, USER1);
    {
        let mut token = take_from_sender<ConditionalToken>(&scenario);
        let clock = take_shared<Clock>(&scenario);
        let ctx = ctx(&mut scenario);

        conditional_token::split(
            &mut token,
            40,
            USER2,
            &clock,
            ctx,
        );

        assert!(conditional_token::value(&token) == 60, 4);
        return_to_sender(&scenario, token);
        return_shared(clock);
    };

    end(scenario);
}

#[test]
fun test_merge_many() {
    let mut scenario = begin(ADMIN);

    // Setup initial state
    next_tx(&mut scenario, ADMIN);
    {
        let ctx = ctx(&mut scenario);
        let (mut state) = init_market(ctx);
        let mut clock = create_for_testing(ctx);

        market_state::init_trading_for_testing(&mut state);
        set_for_testing(&mut clock, 1000);

        transfer::public_share_object(state);
        share_for_testing(clock);
    };

    // Mint multiple tokens to different users
    next_tx(&mut scenario, ADMIN);
    {
        let state = take_shared<MarketState>(&scenario);
        let clock = take_shared<Clock>(&scenario);
        let ctx = ctx(&mut scenario);

        let mut supply = conditional_token::new_supply(
            &state,
            ASSET_TYPE_ASSET,
            OUTCOME_ACCEPTED,
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

        return_shared(state);
        return_shared(clock);
    };

    // Prepare tokens for merge
    next_tx(&mut scenario, USER2);
    {
        let token2 = take_from_sender<ConditionalToken>(&scenario);
        let token3 = take_from_sender<ConditionalToken>(&scenario);
        let clock = take_shared<Clock>(&scenario);

        next_tx(&mut scenario, USER1);
        let mut base_token = take_from_sender<ConditionalToken>(&scenario);
        let ctx = ctx(&mut scenario);

        // Create vector of tokens to merge
        let mut tokens_to_merge = vector[];
        tokens_to_merge.push_back(token2);
        tokens_to_merge.push_back(token3);

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

        return_to_sender(&scenario, base_token);
        return_shared(clock);
    };

    end(scenario);
}

#[test]
fun test_merge_large_number_of_tokens() {
    let mut scenario = begin(ADMIN);
    
    // Setup
    next_tx(&mut scenario, ADMIN);
    {
        let ctx = ctx(&mut scenario);
        let (mut state) = init_market(ctx);
        let mut clock = create_for_testing(ctx);
        
        market_state::init_trading_for_testing(&mut state);
        
        transfer::public_share_object(state);
        share_for_testing(clock);
    };
    
    // Create base token and many small tokens
    next_tx(&mut scenario, ADMIN);
    {
        let state = take_shared<MarketState>(&scenario);
        let clock = take_shared<Clock>(&scenario);
        let ctx = ctx(&mut scenario);
        
        let mut supply = conditional_token::new_supply(
            &state,
            ASSET_TYPE_ASSET,
            OUTCOME_ACCEPTED,
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
        
        return_shared(state);
        return_shared(clock);
    };
    
    // Collect tokens for merging
    let mut tokens_to_merge = vector[];
    let token_count = 20;
    
    next_tx(&mut scenario, USER2);
    {
        let mut i = 0;
        while (i < token_count) {
            let token = take_from_sender<ConditionalToken>(&scenario);
            tokens_to_merge.push_back(token);
            i = i + 1;
        };
    };
    
    // Perform merge with the base token
    next_tx(&mut scenario, USER1);
    {
        let mut base_token = take_from_sender<ConditionalToken>(&scenario);
        let clock = take_shared<Clock>(&scenario);
        let ctx = ctx(&mut scenario);
        
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
        
        return_to_sender(&scenario, base_token);
        return_shared(clock);
    };
    
    end(scenario);
}

#[test]
#[expected_failure(abort_code = futarchy::market_state::ETradingAlreadyEnded)]
fun test_mint_after_trading_closed() {
    let mut scenario = begin(ADMIN);
    
    // Setup market and close trading
    next_tx(&mut scenario, ADMIN);
    {
        let ctx = ctx(&mut scenario);
        let (mut state) = init_market(ctx);
        let mut clock = create_for_testing(ctx);
        
        market_state::init_trading_for_testing(&mut state);
        market_state::end_trading(&mut state, &clock);

        transfer::public_share_object(state);
        share_for_testing(clock);
    };
    
    // Attempt to mint after trading closed
    next_tx(&mut scenario, ADMIN);
    {
        let state = take_shared<MarketState>(&scenario);
        let clock = take_shared<Clock>(&scenario);
        let ctx = ctx(&mut scenario);
        
        let mut supply = conditional_token::new_supply(
            &state,
            ASSET_TYPE_ASSET,
            OUTCOME_ACCEPTED,
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
        
        return_shared(state);
        return_shared(clock);
    };
    
    end(scenario);
}

#[test]
#[expected_failure(abort_code = futarchy::conditional_token::EInsufficientBalance)]
fun test_split_edge_cases() {
    let mut scenario = begin(ADMIN);
    
    // Setup
    next_tx(&mut scenario, ADMIN);
    {
        let ctx = ctx(&mut scenario);
        let (mut state) = init_market(ctx);
        let mut clock = create_for_testing(ctx);
        
        market_state::init_trading_for_testing(&mut state);
        
        transfer::public_share_object(state);
        share_for_testing(clock);
    };
    
    // Mint token
    next_tx(&mut scenario, ADMIN);
    {
        let state = take_shared<MarketState>(&scenario);
        let clock = take_shared<Clock>(&scenario);
        let ctx = ctx(&mut scenario);
        
        let mut supply = conditional_token::new_supply(
            &state,
            ASSET_TYPE_ASSET,
            OUTCOME_ACCEPTED,
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
        
        return_shared(state);
        return_shared(clock);
    };
    
    // Test splitting entire value
    next_tx(&mut scenario, USER1);
    {
        let mut token = take_from_sender<ConditionalToken>(&scenario);
        let clock = take_shared<Clock>(&scenario);
        let ctx = ctx(&mut scenario);
        
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
        
        return_to_sender(&scenario, token);
        return_shared(clock);
    };
    
    end(scenario);
}

// Note: test_split_and_return is not included because split_and_return is public(package)
// and the test module doesn't have friend access to conditional_token module

#[test]
fun test_destroy_zero_value_token() {
    let mut scenario = begin(ADMIN);
    
    // Setup
    next_tx(&mut scenario, ADMIN);
    {
        let ctx = ctx(&mut scenario);
        let (mut state) = init_market(ctx);
        let mut clock = create_for_testing(ctx);
        
        market_state::init_trading_for_testing(&mut state);
        
        transfer::public_share_object(state);
        share_for_testing(clock);
    };
    
    // Create and split token to get a zero value token
    next_tx(&mut scenario, ADMIN);
    {
        let state = take_shared<MarketState>(&scenario);
        let clock = take_shared<Clock>(&scenario);
        let ctx = ctx(&mut scenario);
        
        let mut supply = conditional_token::new_supply(
            &state,
            ASSET_TYPE_ASSET,
            OUTCOME_ACCEPTED,
            ctx,
        );
        
        let mut token = conditional_token::mint(
            &state,
            &mut supply,
            100,
            USER1,
            &clock,
            ctx,
        );
        
        // Burn the entire token to reduce supply
        conditional_token::burn(token, &mut supply, &clock, ctx);
        
        // Create a new zero-balance token for testing destroy
        let zero_token = conditional_token::mint_for_testing(
            state.market_id(),
            ASSET_TYPE_ASSET,
            OUTCOME_ACCEPTED,
            0, // zero balance
            ctx
        );
        
        // Now destroy the zero-value token
        conditional_token::destroy(zero_token);
        
        transfer::public_transfer(supply, ADMIN);
        
        return_shared(state);
        return_shared(clock);
    };
    
    end(scenario);
}

#[test]
#[expected_failure(abort_code = futarchy::conditional_token::ENonzeroBalance)]
fun test_destroy_non_zero_value_token_fails() {
    let mut scenario = begin(ADMIN);
    
    // Setup
    next_tx(&mut scenario, ADMIN);
    {
        let ctx = ctx(&mut scenario);
        let (mut state) = init_market(ctx);
        let mut clock = create_for_testing(ctx);
        
        market_state::init_trading_for_testing(&mut state);
        
        transfer::public_share_object(state);
        share_for_testing(clock);
    };
    
    // Create token with non-zero value
    next_tx(&mut scenario, ADMIN);
    {
        let state = take_shared<MarketState>(&scenario);
        let clock = take_shared<Clock>(&scenario);
        let ctx = ctx(&mut scenario);
        
        let mut supply = conditional_token::new_supply(
            &state,
            ASSET_TYPE_ASSET,
            OUTCOME_ACCEPTED,
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
        
        // This should fail because token has non-zero value
        conditional_token::destroy(token);
        
        transfer::public_transfer(supply, ADMIN);
        
        return_shared(state);
        return_shared(clock);
    };
    
    end(scenario);
}

#[test]
fun test_token_properties() {
    let mut scenario = begin(ADMIN);
    
    // Setup
    next_tx(&mut scenario, ADMIN);
    {
        let ctx = ctx(&mut scenario);
        let (mut state) = init_market(ctx);
        
        market_state::init_trading_for_testing(&mut state);
        transfer::public_share_object(state);
    };
    
    // Create token and verify properties
    next_tx(&mut scenario, ADMIN);
    {
        let state = take_shared<MarketState>(&scenario);
        let ctx = ctx(&mut scenario);
        let mut clock = create_for_testing(ctx);
        
        let mut supply = conditional_token::new_supply(
            &state,
            ASSET_TYPE_ASSET,
            OUTCOME_ACCEPTED,
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
        assert!(conditional_token::outcome(&token) == OUTCOME_ACCEPTED, 2);
        assert!(conditional_token::value(&token) == 100, 3);
        
        transfer::public_transfer(token, USER1);
        transfer::public_transfer(supply, ADMIN);
        share_for_testing(clock);
        
        return_shared(state);
    };
    
    end(scenario);
}

#[test]
#[expected_failure(abort_code = futarchy::conditional_token::EWrongMarket)]
fun test_merge_many_wrong_market() {
    let mut scenario = begin(ADMIN);
    
    // Setup two different markets
    next_tx(&mut scenario, ADMIN);
    {
        let ctx = ctx(&mut scenario);
        let (mut state1) = init_market(ctx);
        let (mut state2) = init_market(ctx);
        let mut clock = create_for_testing(ctx);
        
        market_state::init_trading_for_testing(&mut state1);
        market_state::init_trading_for_testing(&mut state2);
        
        transfer::public_share_object(state1);
        transfer::public_share_object(state2);
        share_for_testing(clock);
    };
    
    // Create tokens from different markets
    next_tx(&mut scenario, ADMIN);
    {
        let state1 = take_shared<MarketState>(&scenario);
        let state2 = take_shared<MarketState>(&scenario);
        let clock = take_shared<Clock>(&scenario);
        let ctx = ctx(&mut scenario);
        
        // Create supply and token from market 1
        let mut supply1 = conditional_token::new_supply(
            &state1,
            ASSET_TYPE_ASSET,
            OUTCOME_ACCEPTED,
            ctx,
        );
        
        let mut base_token = conditional_token::mint(
            &state1,
            &mut supply1,
            100,
            USER1,
            &clock,
            ctx,
        );
        
        // Create supply and token from market 2
        let mut supply2 = conditional_token::new_supply(
            &state2,
            ASSET_TYPE_ASSET,
            OUTCOME_ACCEPTED,
            ctx,
        );
        
        let wrong_market_token = conditional_token::mint(
            &state2,
            &mut supply2,
            50,
            USER1,
            &clock,
            ctx,
        );
        
        // Try to merge tokens from different markets - should fail
        let mut tokens_to_merge = vector[];
        tokens_to_merge.push_back(wrong_market_token);
        
        conditional_token::merge_many(
            &mut base_token,
            tokens_to_merge,
            &clock,
            ctx,
        );
        
        // Cleanup (won't reach here due to expected failure)
        return_to_sender(&scenario, base_token);
        transfer::public_transfer(supply1, ADMIN);
        transfer::public_transfer(supply2, ADMIN);
        
        return_shared(state1);
        return_shared(state2);
        return_shared(clock);
    };
    
    end(scenario);
}

#[test]
#[expected_failure(abort_code = futarchy::conditional_token::EWrongTokenType)]
fun test_merge_many_wrong_asset_type() {
    let mut scenario = begin(ADMIN);
    
    // Setup
    next_tx(&mut scenario, ADMIN);
    {
        let ctx = ctx(&mut scenario);
        let (mut state) = init_market(ctx);
        let mut clock = create_for_testing(ctx);
        
        market_state::init_trading_for_testing(&mut state);
        
        transfer::public_share_object(state);
        share_for_testing(clock);
    };
    
    // Create tokens with different asset types
    next_tx(&mut scenario, ADMIN);
    {
        let state = take_shared<MarketState>(&scenario);
        let clock = take_shared<Clock>(&scenario);
        let ctx = ctx(&mut scenario);
        
        // Create asset token
        let mut supply_asset = conditional_token::new_supply(
            &state,
            ASSET_TYPE_ASSET,
            OUTCOME_ACCEPTED,
            ctx,
        );
        
        let mut base_token = conditional_token::mint(
            &state,
            &mut supply_asset,
            100,
            USER1,
            &clock,
            ctx,
        );
        
        // Create stable token (different asset type)
        let mut supply_stable = conditional_token::new_supply(
            &state,
            ASSET_TYPE_STABLE,
            OUTCOME_ACCEPTED,
            ctx,
        );
        
        let wrong_type_token = conditional_token::mint(
            &state,
            &mut supply_stable,
            50,
            USER1,
            &clock,
            ctx,
        );
        
        // Try to merge different asset types - should fail
        let mut tokens_to_merge = vector[];
        tokens_to_merge.push_back(wrong_type_token);
        
        conditional_token::merge_many(
            &mut base_token,
            tokens_to_merge,
            &clock,
            ctx,
        );
        
        // Cleanup (won't reach here due to expected failure)
        return_to_sender(&scenario, base_token);
        transfer::public_transfer(supply_asset, ADMIN);
        transfer::public_transfer(supply_stable, ADMIN);
        
        return_shared(state);
        return_shared(clock);
    };
    
    end(scenario);
}

#[test]
#[expected_failure(abort_code = futarchy::conditional_token::EWrongOutcome)]
fun test_merge_many_wrong_outcome() {
    let mut scenario = begin(ADMIN);
    
    // Setup
    next_tx(&mut scenario, ADMIN);
    {
        let ctx = ctx(&mut scenario);
        let (mut state) = init_market(ctx);
        let mut clock = create_for_testing(ctx);
        
        market_state::init_trading_for_testing(&mut state);
        
        transfer::public_share_object(state);
        share_for_testing(clock);
    };
    
    // Create tokens with different outcomes
    next_tx(&mut scenario, ADMIN);
    {
        let state = take_shared<MarketState>(&scenario);
        let clock = take_shared<Clock>(&scenario);
        let ctx = ctx(&mut scenario);
        
        // Create token for outcome YES
        let mut supply_yes = conditional_token::new_supply(
            &state,
            ASSET_TYPE_ASSET,
            OUTCOME_ACCEPTED,
            ctx,
        );
        
        let mut base_token = conditional_token::mint(
            &state,
            &mut supply_yes,
            100,
            USER1,
            &clock,
            ctx,
        );
        
        // Create token for outcome NO (different outcome)
        let mut supply_no = conditional_token::new_supply(
            &state,
            ASSET_TYPE_ASSET,
            OUTCOME_REJECTED,
            ctx,
        );
        
        let wrong_outcome_token = conditional_token::mint(
            &state,
            &mut supply_no,
            50,
            USER1,
            &clock,
            ctx,
        );
        
        // Try to merge different outcomes - should fail
        let mut tokens_to_merge = vector[];
        tokens_to_merge.push_back(wrong_outcome_token);
        
        conditional_token::merge_many(
            &mut base_token,
            tokens_to_merge,
            &clock,
            ctx,
        );
        
        // Cleanup (won't reach here due to expected failure)
        return_to_sender(&scenario, base_token);
        transfer::public_transfer(supply_yes, ADMIN);
        transfer::public_transfer(supply_no, ADMIN);
        
        return_shared(state);
        return_shared(clock);
    };
    
    end(scenario);
}