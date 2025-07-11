#[test_only]
module futarchy::proposal_tests;

use futarchy::advance_stage;
use futarchy::coin_escrow::{Self, TokenEscrow};
use futarchy::fee;
use futarchy::proposal::{Self, Proposal};
use std::string::{Self, String};
use sui::balance;
use sui::clock::{Self, Clock};
use sui::test_scenario::{Self as test, Scenario, next_tx, ctx};

const ADMIN: address = @0xcafe;
const DAO: address = @0xda0;

const MIN_ASSET_LIQUIDITY: u64 = 1_000_000;
const MIN_STABLE_LIQUIDITY: u64 = 1_000_000;
const STARTING_TIMESTAMP: u64 = 1_000_000_000;
const TWAP_INITIAL_OBSERVATION: u128 = 1_000_000;
const TWAP_START_DELAY: u64 = 60_000;
const TWAP_STEP_MAX: u64 = 10000;

// State constants
const STATE_REVIEW: u8 = 0;
const STATE_TRADING: u8 = 1;
const STATE_FINALIZED: u8 = 2;
const REVIEW_PERIOD_MS: u64 = 2_000_000; // 2 seconds
const TRADING_PERIOD_MS: u64 = 2_000_00; // 1 second
const TWAP_THESHOLD: u64 = 1_000;

fun setup_test_proposal(scenario: &mut Scenario, clock: &Clock) {
    let asset_balance = balance::create_for_testing<u64>(MIN_ASSET_LIQUIDITY);
    let stable_balance = balance::create_for_testing<u64>(MIN_STABLE_LIQUIDITY);
    let dao_id = object::id_from_address(DAO);

    let mut outcome_messages = vector::empty<String>();
    vector::push_back(&mut outcome_messages, string::utf8(b"Outcome 0"));
    vector::push_back(&mut outcome_messages, string::utf8(b"Outcome 1"));

    // The create function returns a tuple (proposal_id, market_state_id, state)
    // We don't need to do anything with the return values since the function
    // already shares the Proposal and TokenEscrow objects
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
        vector[1_000_000, 1_000_000, 1_000_000, 1_000_000], // initial_outcome_amounts
        TWAP_THESHOLD,
        clock,
        ctx(scenario),
    );

    // Create a FeeManager for testing
    fee::create_fee_manager_for_testing(ctx(scenario));
}

#[test]
fun test_create_proposal() {
    let mut scenario = test::begin(ADMIN);
    let mut clock = clock::create_for_testing(ctx(&mut scenario));
    clock::set_for_testing(&mut clock, STARTING_TIMESTAMP);

    next_tx(&mut scenario, ADMIN);
    {
        setup_test_proposal(&mut scenario, &clock);
    };

    next_tx(&mut scenario, ADMIN);
    {
        let proposal = test::take_shared<Proposal<u64, u64>>(&scenario);
        let escrow = test::take_shared<TokenEscrow<u64, u64>>(&scenario);

        assert!(proposal::state(&proposal) == STATE_REVIEW, 0);
        assert!(proposal::outcome_count(&proposal) == 2, 1);
        assert!(proposal::proposer(&proposal) == ADMIN, 2);
        assert!(string::length(proposal::get_details(&proposal)) > 0, 3);
        assert!(string::length(proposal::get_metadata(&proposal)) > 0, 4);
        assert!(proposal::created_at(&proposal) == STARTING_TIMESTAMP, 5);

        let (asset_bal, stable_bal) = coin_escrow::get_balances(&escrow);
        assert!(asset_bal == MIN_ASSET_LIQUIDITY, 7);
        assert!(stable_bal == MIN_STABLE_LIQUIDITY, 8);

        test::return_shared(proposal);
        test::return_shared(escrow);
    };

    clock::destroy_for_testing(clock);
    test::end(scenario);
}

#[test]
fun test_basic_state_transition() {
    let mut scenario = test::begin(ADMIN);
    let mut clock = clock::create_for_testing(ctx(&mut scenario));
    clock::set_for_testing(&mut clock, STARTING_TIMESTAMP);

    // Create proposal
    next_tx(&mut scenario, ADMIN);
    {
        let asset_balance = balance::create_for_testing<u64>(MIN_ASSET_LIQUIDITY);
        let stable_balance = balance::create_for_testing<u64>(MIN_STABLE_LIQUIDITY);
        let dao_id = object::id_from_address(DAO);

        let mut outcome_messages = vector::empty<String>();
        vector::push_back(&mut outcome_messages, string::utf8(b"Outcome 0"));
        vector::push_back(&mut outcome_messages, string::utf8(b"Outcome 1"));

        // Correctly capturing tuple return value
        let (_proposal_id, _market_state_id, _state) = proposal::create<u64, u64>(
            dao_id,
            2,
            asset_balance,
            stable_balance,
            REVIEW_PERIOD_MS,
            TRADING_PERIOD_MS,
            MIN_ASSET_LIQUIDITY,
            MIN_STABLE_LIQUIDITY,
            string::utf8(b"Test Proposal"),
            string::utf8(b"Test Details"),
            string::utf8(b"Test Metadata"),
            outcome_messages,
            TWAP_START_DELAY,
            TWAP_INITIAL_OBSERVATION,
            TWAP_STEP_MAX,
            vector[1_000_000, 1_000_000, 1_000_000, 1_000_000], // initial_outcome_amounts
            TWAP_THESHOLD,
            &clock,
            ctx(&mut scenario),
        );

        // No need to share - already done by create function
    };

    // Advance clock and transition to trading
    clock::set_for_testing(&mut clock, STARTING_TIMESTAMP + 2_000_100);
    next_tx(&mut scenario, ADMIN);
    {
        let mut proposal = test::take_shared<Proposal<u64, u64>>(&scenario);
        let mut escrow = test::take_shared<TokenEscrow<u64, u64>>(&scenario);
        let market_state = coin_escrow::get_market_state_mut(&mut escrow);

        advance_stage::try_advance_state(
            &mut proposal,
            market_state,
            &clock,
        );

        assert!(proposal::state(&proposal) == 1, 0); // STATE_TRADING

        test::return_shared(proposal);
        test::return_shared(escrow);
    };

    clock::destroy_for_testing(clock);
    test::end(scenario);
}

#[test]
fun test_state_transitions() {
    let mut scenario = test::begin(ADMIN);
    let mut clock = clock::create_for_testing(ctx(&mut scenario));
    clock::set_for_testing(&mut clock, STARTING_TIMESTAMP);

    next_tx(&mut scenario, ADMIN);
    {
        setup_test_proposal(&mut scenario, &clock);
    };

    // Test transition to TRADING
    clock::set_for_testing(&mut clock, STARTING_TIMESTAMP + REVIEW_PERIOD_MS + 100);
    next_tx(&mut scenario, ADMIN);
    {
        let mut proposal = test::take_shared<Proposal<u64, u64>>(&scenario);
        let mut escrow = test::take_shared<TokenEscrow<u64, u64>>(&scenario);
        let market_state = coin_escrow::get_market_state_mut(&mut escrow);

        advance_stage::try_advance_state(&mut proposal, market_state, &clock);
        assert!(proposal::state(&proposal) == STATE_TRADING, 0);

        test::return_shared(proposal);
        test::return_shared(escrow);
    };

    // Advance
    clock::set_for_testing(
        &mut clock,
        STARTING_TIMESTAMP + REVIEW_PERIOD_MS + TRADING_PERIOD_MS + 100,
    );

    // Test finalization
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
        assert!(proposal::state(&proposal) == STATE_FINALIZED, 2);

        test::return_shared(proposal);
        test::return_shared(escrow);
        test::return_shared(fee_manager);
    };

    clock::destroy_for_testing(clock);
    test::end(scenario);
}
