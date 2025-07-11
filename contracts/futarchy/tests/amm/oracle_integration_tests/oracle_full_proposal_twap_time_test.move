#[test_only]
module futarchy::oracle_full_proposal_twap_time_test;

// === Imports ===
use sui::test_scenario::{Self as test, Scenario, next_tx, ctx};
use sui::clock::{Self, Clock};
use sui::balance;
use sui::coin;
use sui::object; // For id_from_address

use std::string::{Self, String};
use std::vector;
use std::option;
use std::u256;

use futarchy::proposal::{Self, Proposal};
use futarchy::coin_escrow::{Self, TokenEscrow};
use futarchy::fee::{Self, FeeManager};
use futarchy::advance_stage;
use futarchy::amm; // For get_oracle
use futarchy::oracle as ft_oracle; // For get_total_cumulative_price

// === Test-Specific Constants ===
const ADMIN: address = @0xcafe;
const DAO: address = @0xda0;

const STARTING_TIMESTAMP: u64 = 1_000_000_000;

const MIN_ASSET_LIQUIDITY_FOR_TEST: u64 = 1_000_000;
const MIN_STABLE_LIQUIDITY_FOR_TEST: u64 = 1_000_000;

const ONE_MINUTE_MS: u64 = 60_000;
const ONE_HOUR_MS: u64 = 60 * ONE_MINUTE_MS;
const ONE_DAY_MS: u64 = 24 * ONE_HOUR_MS;

const TEST_REVIEW_PERIOD_MS: u64 = 12 * ONE_HOUR_MS;
const TEST_TWAP_START_DELAY_MS: u64 = 2 * ONE_DAY_MS; // Must be multiple of ft_oracle::TWAP_PRICE_CAP_WINDOW
const TEST_TRADING_PERIOD_MS: u64 = 5 * ONE_DAY_MS;

const EXPECTED_TWAP_DURATION_MS: u64 = TEST_TRADING_PERIOD_MS - TEST_TWAP_START_DELAY_MS;

const CONSTANT_PRICE_U128: u128 = 1_000_000_000_000u128; // Value of AMM price if reserves are 1:1 (amm::BASIS_POINTS)
const TEST_TWAP_STEP_MAX: u64 = 1_000_000_000; // Large step to avoid capping with constant price
const TEST_TWAP_THRESHOLD: u64 = 1; // Default, outcome 0 wins if no trades

const STATE_REVIEW: u8 = 0;
const STATE_TRADING: u8 = 1;
const STATE_FINALIZED: u8 = 2;

fun setup_test_proposal_for_oracle_check(
    scenario: &mut Scenario,
    clock: &Clock,
) {
    let asset_balance = balance::create_for_testing<u64>(MIN_ASSET_LIQUIDITY_FOR_TEST);
    let stable_balance = balance::create_for_testing<u64>(MIN_STABLE_LIQUIDITY_FOR_TEST);
    let dao_id = object::id_from_address(DAO);

    let mut outcome_messages = vector::empty<String>();
    vector::push_back(&mut outcome_messages, string::utf8(b"Outcome 0"));
    vector::push_back(&mut outcome_messages, string::utf8(b"Outcome 1"));

    let (_proposal_id, _market_state_id, _state) = proposal::create<u64, u64>(
        dao_id,
        2, // outcome_count
        asset_balance,
        stable_balance,
        TEST_REVIEW_PERIOD_MS,
        TEST_TRADING_PERIOD_MS,
        MIN_ASSET_LIQUIDITY_FOR_TEST,
        MIN_STABLE_LIQUIDITY_FOR_TEST,
        string::utf8(b"Oracle TWAP Check Proposal"),
        vector[string::utf8(b"Details for outcome 0"), string::utf8(b"Details for outcome 1")],
        string::utf8(b"Metadata for oracle TWAP check"),
        outcome_messages,
        TEST_TWAP_START_DELAY_MS,
        CONSTANT_PRICE_U128,
        TEST_TWAP_STEP_MAX,
        vector[1_000_000, 1_000_000, 1_000_000, 1_000_000],
        TEST_TWAP_THRESHOLD,
        clock,
        ctx(scenario),
    );
    fee::create_fee_manager_for_testing(ctx(scenario));
}

#[test]
fun test_twap_accumulation_value_matches_expected_duration_constant_price() {
    assert!(TEST_TRADING_PERIOD_MS > TEST_TWAP_START_DELAY_MS, 0); // Precondition for valid duration

    let mut scenario = test::begin(ADMIN);
    let mut clock = clock::create_for_testing(ctx(&mut scenario));
    clock::set_for_testing(&mut clock, STARTING_TIMESTAMP);

    let mut market_start_actual_time = 0;

    // --- TX 1: Create Proposal ---
    next_tx(&mut scenario, ADMIN);
    {
        setup_test_proposal_for_oracle_check(&mut scenario, &clock);
    };

    // --- TX 2: Advance to Trading State ---
    let calculated_market_start_time = STARTING_TIMESTAMP + TEST_REVIEW_PERIOD_MS;
    clock::set_for_testing(&mut clock, calculated_market_start_time);
    market_start_actual_time = clock::timestamp_ms(&clock);
    assert!(market_start_actual_time == calculated_market_start_time, 100);

    next_tx(&mut scenario, ADMIN);
    {
        let mut proposal_obj = test::take_shared<Proposal<u64, u64>>(&scenario);
        let mut escrow_obj = test::take_shared<TokenEscrow<u64, u64>>(&scenario);
        let mut fee_manager_obj = test::take_shared<FeeManager>(&scenario);

        advance_stage::try_advance_state_entry(
            &mut proposal_obj, &mut escrow_obj, &mut fee_manager_obj, &clock,
        );
        assert!(proposal::state(&proposal_obj) == STATE_TRADING, 1);

        test::return_shared(proposal_obj);
        test::return_shared(escrow_obj);
        test::return_shared(fee_manager_obj);
    };

    // --- TX 3: Advance to Finalized State ---
    let finalization_time = market_start_actual_time + TEST_TRADING_PERIOD_MS;
    clock::set_for_testing(&mut clock, finalization_time);
    assert!(clock::timestamp_ms(&clock) == finalization_time, 101);

    next_tx(&mut scenario, ADMIN);
    {
        let mut proposal_obj = test::take_shared<Proposal<u64, u64>>(&scenario);
        let mut escrow_obj = test::take_shared<TokenEscrow<u64, u64>>(&scenario);
        let mut fee_manager_obj = test::take_shared<FeeManager>(&scenario);

        advance_stage::try_advance_state_entry(
            &mut proposal_obj, &mut escrow_obj, &mut fee_manager_obj, &clock,
        );
        assert!(proposal::state(&proposal_obj) == STATE_FINALIZED, 2);

        test::return_shared(proposal_obj);
        test::return_shared(escrow_obj);
        test::return_shared(fee_manager_obj);
    };

    // --- TX 4: Verification ---
    next_tx(&mut scenario, ADMIN);
    {
        let mut proposal_obj = test::take_shared<Proposal<u64, u64>>(&scenario);
        let pools = proposal::get_amm_pools(&proposal_obj);
        let pool0 = vector::borrow(pools, 0);

        let oracle_ref = amm::get_oracle(pool0);
        let total_cumulative_price_val = ft_oracle::total_cumulative_price(oracle_ref);

        let final_twaps_vec = proposal::get_twaps_for_proposal(&mut proposal_obj, &clock);
        let average_price_val = *vector::borrow(&final_twaps_vec, 0);

        assert!(average_price_val == CONSTANT_PRICE_U128, 3);

        let calculated_duration_from_twap_parts = if (average_price_val == 0) {
            0u256
        } else {
            total_cumulative_price_val / (average_price_val as u256)
        };

        std::debug::print(&b"Test: Oracle Full Flow TWAP Check");
        std::debug::print(&b"Total Cumulative Price (Oracle)");
        std::debug::print(&total_cumulative_price_val);
        std::debug::print(&b"Average Price (TWAP from Proposal)");
        std::debug::print(&average_price_val);
        std::debug::print(&b"Calculated Duration from TWAP parts (ms)");
        std::debug::print(&calculated_duration_from_twap_parts);
        std::debug::print(&b"Expected TWAP Duration (ms)");
        std::debug::print(&(EXPECTED_TWAP_DURATION_MS as u256));

        assert!(
            calculated_duration_from_twap_parts == (EXPECTED_TWAP_DURATION_MS as u256),
            4
        );

        test::return_shared(proposal_obj);
        let escrow_obj = test::take_shared<TokenEscrow<u64, u64>>(&scenario);
        let fee_manager_obj = test::take_shared<FeeManager>(&scenario);
        test::return_shared(escrow_obj);
        test::return_shared(fee_manager_obj);
    };

    clock::destroy_for_testing(clock);
    test::end(scenario);
}