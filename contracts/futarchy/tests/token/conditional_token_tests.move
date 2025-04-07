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
