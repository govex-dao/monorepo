#[test_only]
module futarchy::dao_tests;

use futarchy::coin_escrow;
use futarchy::dao::{Self, DAO};
use futarchy::fee::{Self, FeeManager};
use futarchy::market_state;
use futarchy::oracle;
use futarchy::proposal::{Self, Proposal};
use std::ascii::String as AsciiString;
use std::string::{Self, String};
use sui::clock::{Self, Clock};
use sui::coin::{Self, Coin};
use sui::test_scenario::{Self, Scenario, ctx};

// Test coins
public struct ASSET has copy, drop {}
public struct STABLE has copy, drop {}

const DEFAULT_TWAP_START_DELAY: u64 = 60_000;
const DEFAULT_TWAP_INITIAL_OBSERVATION: u128 = 1_000_000;
const DEFAULT_TWAP_STEP_MAX: u64 = 300_000;
const TEST_DAO_NAME: vector<u8> = b"TestDAO";
const TEST_DAO_URL: vector<u8> = b"https://test.com";
const ASSET_DECIMALS: u8 = 5;
const STABLE_DECIMALS: u8 = 9;
const ASSET_NAME: vector<u8> = b"Test Asset";
const STABLE_NAME: vector<u8> = b"Test Stable";
const ASSET_SYMBOL: vector<u8> = b"TAST";
const STABLE_SYMBOL: vector<u8> = b"TSTB";
const TEST_REVIEW_PERIOD: u64 = 2_000_000; // 2 seconds
const TEST_TRADING_PERIOD: u64 = 2_000_00; // 1 second
const TWAP_THESHOLD: u64 = 1_000;

// Test helper function to set up basic scenario
fun setup_test(sender: address): (Clock, Scenario) {
    let mut scenario = test_scenario::begin(sender);
    fee::create_fee_manager_for_testing(test_scenario::ctx(&mut scenario));
    let clock = clock::create_for_testing(test_scenario::ctx(&mut scenario));
    (clock, scenario)
}

fun setup_test_metadata(): (AsciiString, AsciiString) {
    (std::ascii::string(b""), std::ascii::string(b""))
}

// Helper to create test coins
fun mint_test_coins(amount: u64, ctx: &mut tx_context::TxContext): (Coin<ASSET>, Coin<STABLE>) {
    (coin::mint_for_testing<ASSET>(amount, ctx), coin::mint_for_testing<STABLE>(amount, ctx))
}

// Helper to create default outcome messages
fun create_default_outcome_messages(): vector<String> {
    vector[string::utf8(b"Reject"), string::utf8(b"Accept")]
}

#[test]
fun test_create_dao() {
    let admin = @0xA;
    let (clock, mut scenario) = setup_test(admin);

    test_scenario::next_tx(&mut scenario, admin);
    {
        let dao_name = std::ascii::string(TEST_DAO_NAME);
        let icon_url = std::ascii::string(TEST_DAO_URL);
        let (asset_icon_url, stable_icon_url) = setup_test_metadata();

        // Call the dao::create function - it transfers the DAO via public_share_object
        dao::create<ASSET, STABLE>(
            2000, // min_asset_amount
            2000, // min_stable_amount
            dao_name,
            icon_url,
            TEST_REVIEW_PERIOD, // review_period_ms
            TEST_TRADING_PERIOD, // trading_period_ms
            ASSET_DECIMALS,
            STABLE_DECIMALS,
            string::utf8(ASSET_NAME), // asset_name as String
            string::utf8(STABLE_NAME), // stable_name as String
            asset_icon_url,
            stable_icon_url,
            std::ascii::string(ASSET_SYMBOL), // asset_symbol
            std::ascii::string(STABLE_SYMBOL), // stable_symbol
            60_000,
            300_000,
            DEFAULT_TWAP_INITIAL_OBSERVATION,
            TWAP_THESHOLD,
            string::utf8(b"DAO description"),
            &clock,
            test_scenario::ctx(&mut scenario),
        );
    };

    // Start a new transaction to retrieve the shared DAO object
    test_scenario::next_tx(&mut scenario, admin);
    {
        // Take the shared DAO object from the scenario
        let dao = test_scenario::take_shared<DAO>(&scenario);

        // Verify initial state
        let (active, total, _) = dao::get_stats(&dao);
        assert!(active == 0, 0);
        assert!(total == 0, 1);

        // Verify minimum amounts
        let (min_asset, min_stable) = dao::get_min_amounts(&dao);
        assert!(min_asset == 2000, 2);
        assert!(min_stable == 2000, 3);

        // Verify default AMM config
        let (twap_start_delay, twap_step_max, twap_initial_observation) = dao::get_amm_config(&dao);
        assert!(twap_start_delay == DEFAULT_TWAP_START_DELAY, 7);
        assert!(twap_step_max == DEFAULT_TWAP_STEP_MAX, 8);
        assert!(twap_initial_observation == DEFAULT_TWAP_INITIAL_OBSERVATION, 9);

        // Return the DAO to the scenario
        test_scenario::return_shared(dao);
    };

    clock::destroy_for_testing(clock);
    test_scenario::end(scenario);
}

#[test]
fun test_create_valid_proposal() {
    let admin = @0xA;
    let (clock, mut scenario) = setup_test(admin);

    // First transaction: Create the DAO
    test_scenario::next_tx(&mut scenario, admin);
    {
        let dao_name = std::ascii::string(TEST_DAO_NAME);
        let icon_url = std::ascii::string(TEST_DAO_URL);
        let (asset_icon_url, stable_icon_url) = setup_test_metadata();

        // Create the DAO - it gets shared automatically
        dao::create<ASSET, STABLE>(
            2000,
            2000,
            dao_name,
            icon_url,
            TEST_REVIEW_PERIOD, // review_period_ms
            TEST_TRADING_PERIOD, // trading_period_ms
            ASSET_DECIMALS,
            STABLE_DECIMALS,
            string::utf8(ASSET_NAME), // asset_name as String
            string::utf8(STABLE_NAME), // stable_name as String
            asset_icon_url,
            stable_icon_url,
            std::ascii::string(ASSET_SYMBOL), // asset_symbol
            std::ascii::string(STABLE_SYMBOL), // stable_symbol
            60_000,
            300_000,
            DEFAULT_TWAP_INITIAL_OBSERVATION,
            TWAP_THESHOLD,
            string::utf8(b"DAO description"),
            &clock,
            test_scenario::ctx(&mut scenario),
        );
    };

    // Second transaction: Create a proposal for the DAO
    test_scenario::next_tx(&mut scenario, admin);
    {
        // Take the shared DAO
        let mut dao = test_scenario::take_shared<DAO>(&scenario);

        // Create coins for proposal creation
        let (asset_coin, stable_coin) = mint_test_coins(2000, test_scenario::ctx(&mut scenario));
        let mut fee_manager = test_scenario::take_shared<FeeManager>(&scenario);
        let payment = coin::mint_for_testing(
            fee::get_verification_fee(&fee_manager),
            ctx(&mut scenario),
        );

        // Create a valid proposal
        dao::create_proposal(
            &mut dao,
            &mut fee_manager,
            payment,
            2, // outcome_count
            asset_coin,
            stable_coin,
            string::utf8(b"Test Proposal"), // title
            string::utf8(b"Test Details"), // details
            string::utf8(b"{}"), // metadata
            create_default_outcome_messages(), // outcome messages
            vector[2000, 2000, 2000, 2000],
            &clock,
            test_scenario::ctx(&mut scenario),
        );

        // Now check the stats after creating a proposal
        let (active, total, _) = dao::get_stats(&dao);
        assert!(active == 1, 0);
        assert!(total == 1, 1);

        // Return the DAO to the shared storage
        test_scenario::return_shared(dao);
        test_scenario::return_shared(fee_manager);
    };

    clock::destroy_for_testing(clock);
    test_scenario::end(scenario);
}

#[test]
#[expected_failure(abort_code = dao::EInvalidMessages)]
fun test_create_proposal_invalid_messages() {
    let admin = @0xA;
    let (clock, mut scenario) = setup_test(admin);

    // First transaction: Create the DAO
    test_scenario::next_tx(&mut scenario, admin);
    {
        let dao_name = std::ascii::string(TEST_DAO_NAME);
        let icon_url = std::ascii::string(TEST_DAO_URL);
        let (asset_icon_url, stable_icon_url) = setup_test_metadata();

        // Create the DAO - it gets shared automatically
        dao::create<ASSET, STABLE>(
            2000,
            2000,
            dao_name,
            icon_url,
            TEST_REVIEW_PERIOD, // review_period_ms
            TEST_TRADING_PERIOD, // trading_period_ms
            ASSET_DECIMALS,
            STABLE_DECIMALS,
            string::utf8(ASSET_NAME), // asset_name as String
            string::utf8(STABLE_NAME), // stable_name as String
            asset_icon_url,
            stable_icon_url,
            std::ascii::string(ASSET_SYMBOL), // asset_symbol
            std::ascii::string(STABLE_SYMBOL), // stable_symbol
            60_000,
            300_000,
            DEFAULT_TWAP_INITIAL_OBSERVATION,
            TWAP_THESHOLD,
            string::utf8(b"DAO description"),
            &clock,
            test_scenario::ctx(&mut scenario),
        );
    };

    // Second transaction: Try to create a proposal with invalid messages
    test_scenario::next_tx(&mut scenario, admin);
    {
        // Take the shared DAO
        let mut dao = test_scenario::take_shared<DAO>(&scenario);

        // Create coins for proposal creation
        let (asset_coin, stable_coin) = mint_test_coins(2000, test_scenario::ctx(&mut scenario));
        let mut fee_manager = test_scenario::take_shared<FeeManager>(&scenario);
        let payment = coin::mint_for_testing(
            fee::get_verification_fee(&fee_manager),
            ctx(&mut scenario),
        );

        // Create invalid outcome messages - first message is not "Reject"
        let invalid_messages = vector[
            string::utf8(b"Invalid"), // Should be "Reject"
            string::utf8(b"Accept"),
        ];

        // Try to create proposal with invalid messages - should abort
        dao::create_proposal(
            &mut dao,
            &mut fee_manager,
            payment,
            2, // outcome_count
            asset_coin,
            stable_coin,
            string::utf8(b"Test Proposal"),
            string::utf8(b"Test Details"),
            string::utf8(b"{}"),
            invalid_messages,
            vector[2000, 2000, 2000, 2000],
            &clock,
            test_scenario::ctx(&mut scenario),
        );

        // The code should not reach this point in the expected failure test,
        // but we include it for completeness
        test_scenario::return_shared(dao);
        test_scenario::return_shared(fee_manager);
    };

    clock::destroy_for_testing(clock);
    test_scenario::end(scenario);
}

#[test]
#[expected_failure(abort_code = dao::EDetailsTooShort)]
fun test_create_proposal_empty_details() {
    let admin = @0xA;
    let (clock, mut scenario) = setup_test(admin);

    // First transaction: Create the DAO
    test_scenario::next_tx(&mut scenario, admin);
    {
        let dao_name = std::ascii::string(TEST_DAO_NAME);
        let icon_url = std::ascii::string(TEST_DAO_URL);
        let (asset_icon_url, stable_icon_url) = setup_test_metadata();

        // Create the DAO - it gets shared automatically
        dao::create<ASSET, STABLE>(
            2000,
            2000,
            dao_name,
            icon_url,
            TEST_REVIEW_PERIOD,
            TEST_TRADING_PERIOD,
            ASSET_DECIMALS,
            STABLE_DECIMALS,
            string::utf8(ASSET_NAME),
            string::utf8(STABLE_NAME),
            asset_icon_url,
            stable_icon_url,
            std::ascii::string(ASSET_SYMBOL),
            std::ascii::string(STABLE_SYMBOL),
            60_000,
            300_000,
            DEFAULT_TWAP_INITIAL_OBSERVATION,
            TWAP_THESHOLD,
            string::utf8(b"DAO description"),
            &clock,
            test_scenario::ctx(&mut scenario),
        );
    };

    // Second transaction: Try to create a proposal with empty details
    test_scenario::next_tx(&mut scenario, admin);
    {
        // Take the shared DAO
        let mut dao = test_scenario::take_shared<DAO>(&scenario);

        // Create coins for proposal creation
        let (asset_coin, stable_coin) = mint_test_coins(2000, test_scenario::ctx(&mut scenario));
        let mut fee_manager = test_scenario::take_shared<FeeManager>(&scenario);
        let payment = coin::mint_for_testing(
            fee::get_verification_fee(&fee_manager),
            ctx(&mut scenario),
        );

        // Try to create a proposal with empty details - should abort
        dao::create_proposal(
            &mut dao,
            &mut fee_manager,
            payment,
            2, // outcome_count
            asset_coin,
            stable_coin,
            string::utf8(b"Test Proposal"), // title
            string::utf8(b""), // empty details - this should trigger the error
            string::utf8(b"{}"), // metadata
            create_default_outcome_messages(),
            vector[2000, 2000, 2000, 2000],
            &clock,
            test_scenario::ctx(&mut scenario),
        );

        // The code shouldn't reach here in the expected failure test
        test_scenario::return_shared(dao);
        test_scenario::return_shared(fee_manager);
    };

    clock::destroy_for_testing(clock);
    test_scenario::end(scenario);
}

#[test]
fun test_query_functions() {
    let admin = @0xA;
    let (clock, mut scenario) = setup_test(admin);

    // First transaction: Create the DAO and proposal
    test_scenario::next_tx(&mut scenario, admin);
    {
        let dao_name = std::ascii::string(TEST_DAO_NAME);
        let icon_url = std::ascii::string(TEST_DAO_URL);
        let (asset_icon_url, stable_icon_url) = setup_test_metadata();

        // Create the DAO - it gets shared automatically
        dao::create<ASSET, STABLE>(
            2000,
            2000,
            dao_name,
            icon_url,
            TEST_REVIEW_PERIOD,
            TEST_TRADING_PERIOD,
            ASSET_DECIMALS,
            STABLE_DECIMALS,
            string::utf8(ASSET_NAME),
            string::utf8(STABLE_NAME),
            asset_icon_url,
            stable_icon_url,
            std::ascii::string(ASSET_SYMBOL),
            std::ascii::string(STABLE_SYMBOL),
            60_000,
            300_000,
            DEFAULT_TWAP_INITIAL_OBSERVATION,
            TWAP_THESHOLD,
            string::utf8(b"DAO description"),
            &clock,
            test_scenario::ctx(&mut scenario),
        );
    };

    // Second transaction: Create the proposal
    test_scenario::next_tx(&mut scenario, admin);
    {
        // Take the shared DAO
        let mut dao = test_scenario::take_shared<DAO>(&scenario);

        // Create coins for proposal creation
        let (asset_coin, stable_coin) = mint_test_coins(2000, test_scenario::ctx(&mut scenario));
        let mut fee_manager = test_scenario::take_shared<FeeManager>(&scenario);
        let payment = coin::mint_for_testing(
            fee::get_verification_fee(&fee_manager),
            ctx(&mut scenario),
        );

        // Create a proposal
        dao::create_proposal(
            &mut dao,
            &mut fee_manager,
            payment,
            2, // outcome_count
            asset_coin,
            stable_coin,
            string::utf8(b"Test Proposal"),
            string::utf8(b"Test Details"),
            string::utf8(b"{}"),
            create_default_outcome_messages(),
            vector[2000, 2000, 2000, 2000],
            &clock,
            test_scenario::ctx(&mut scenario),
        );

        // Return the DAO to the shared object store
        test_scenario::return_shared(dao);
        test_scenario::return_shared(fee_manager);
    };

    // Third transaction: Query and verify the proposal info
    test_scenario::next_tx(&mut scenario, admin);
    {
        let dao = test_scenario::take_shared<DAO>(&scenario);

        // Take the proposal that was just created
        let proposal = test_scenario::take_shared<Proposal<ASSET, STABLE>>(&scenario);
        let proposal_id = object::id(&proposal);

        // Now verify the proposal info
        let info = dao::get_proposal_info(&dao, proposal_id);
        assert!(dao::get_proposer(info) == admin, 0);
        assert!(*dao::get_description(info) == string::utf8(b"Test Proposal"), 1);
        assert!(!dao::is_executed(info), 2);
        assert!(option::is_none(&dao::get_execution_time(info)), 3);
        assert!(option::is_none(dao::get_result(info)), 4);

        // Clean up
        test_scenario::return_shared(proposal);
        test_scenario::return_shared(dao);
    };

    clock::destroy_for_testing(clock);
    test_scenario::end(scenario);
}

#[test]
fun test_sign_result_entry() {
    let admin = @0xA;
    let (clock, mut scenario) = setup_test(admin);

    // First transaction: Create the DAO
    test_scenario::next_tx(&mut scenario, admin);
    {
        let dao_name = std::ascii::string(TEST_DAO_NAME);
        let icon_url = std::ascii::string(TEST_DAO_URL);
        let (asset_icon_url, stable_icon_url) = setup_test_metadata();

        // Create the DAO - it gets shared automatically
        dao::create<ASSET, STABLE>(
            2000,
            2000,
            dao_name,
            icon_url,
            TEST_REVIEW_PERIOD,
            TEST_TRADING_PERIOD,
            ASSET_DECIMALS,
            STABLE_DECIMALS,
            string::utf8(ASSET_NAME),
            string::utf8(STABLE_NAME),
            asset_icon_url,
            stable_icon_url,
            std::ascii::string(ASSET_SYMBOL),
            std::ascii::string(STABLE_SYMBOL),
            DEFAULT_TWAP_START_DELAY,
            300_000,
            DEFAULT_TWAP_INITIAL_OBSERVATION,
            TWAP_THESHOLD,
            string::utf8(b"DAO description"),
            &clock,
            test_scenario::ctx(&mut scenario),
        );
    };

    // Second transaction: Create the proposal
    test_scenario::next_tx(&mut scenario, admin);
    {
        // Take the shared DAO
        let mut dao = test_scenario::take_shared<DAO>(&scenario);

        // Create coins for proposal creation
        let (asset_coin, stable_coin) = mint_test_coins(2000, test_scenario::ctx(&mut scenario));
        let mut fee_manager = test_scenario::take_shared<FeeManager>(&scenario);
        let payment = coin::mint_for_testing(
            fee::get_verification_fee(&fee_manager),
            ctx(&mut scenario),
        );

        // Create a proposal
        dao::create_proposal(
            &mut dao,
            &mut fee_manager,
            payment,
            2, // outcome_count
            asset_coin,
            stable_coin,
            string::utf8(b"Test Proposal"),
            string::utf8(b"Test Details"),
            string::utf8(b"{}"),
            create_default_outcome_messages(),
            vector[2000, 2000, 2000, 2000],
            &clock,
            test_scenario::ctx(&mut scenario),
        );

        // Return the DAO to the shared object store
        test_scenario::return_shared(dao);
        test_scenario::return_shared(fee_manager);
    };

    // Third transaction: Sign the result
    test_scenario::next_tx(&mut scenario, admin);
    {
        let mut dao = test_scenario::take_shared<DAO>(&scenario);
        let proposal = test_scenario::take_shared<Proposal<ASSET, STABLE>>(&scenario);
        let proposal_id = object::id(&proposal);

        // Get escrow from proposal before setting up market state
        let mut escrow = test_scenario::take_shared<coin_escrow::TokenEscrow<ASSET, STABLE>>(
            &scenario,
        );

        // First set proposal state to Settlement (2)
        dao::test_set_proposal_state(&mut dao, proposal_id, 2);

        // We need to properly finalize the market through state transition
        let market_state = coin_escrow::get_market_state_mut(&mut escrow);

        // Start trading first (needs to happen before we can finalize)
        market_state::start_trading(market_state, 1000, &clock);

        {
            let test_oracle = oracle::test_oracle(test_scenario::ctx(&mut scenario));

            // End trading and move to settlement
            market_state::end_trading(market_state, &clock);

            // Now finalize with outcome 1 as winner
            market_state::finalize(market_state, 1, &clock);

            // Clean up the test oracle
            oracle::destroy_for_testing(test_oracle);
        };

        // Now set proposal state to finalized (3)
        dao::test_set_proposal_state(&mut dao, proposal_id, 3);

        // Test signing result
        dao::sign_result_entry<ASSET, STABLE>(
            &mut dao,
            proposal_id,
            &mut escrow,
            &clock,
            test_scenario::ctx(&mut scenario),
        );

        // Verify result was signed
        let info = dao::get_proposal_info(&dao, proposal_id);
        assert!(dao::is_executed(info), 0);
        assert!(option::is_some(&dao::get_execution_time(info)), 1);
        assert!(option::is_some(dao::get_result(info)), 2);

        // Clean up
        test_scenario::return_shared(escrow);
        test_scenario::return_shared(proposal);
        test_scenario::return_shared(dao);
    };

    clock::destroy_for_testing(clock);
    test_scenario::end(scenario);
}

#[test]
fun test_create_proposal_with_initial_amounts() {
    let admin = @0xA;
    let (clock, mut scenario) = setup_test(admin);

    // First transaction: Create the DAO
    test_scenario::next_tx(&mut scenario, admin);
    {
        let dao_name = std::ascii::string(TEST_DAO_NAME);
        let icon_url = std::ascii::string(TEST_DAO_URL);
        let (asset_icon_url, stable_icon_url) = setup_test_metadata();

        // Create the DAO - it gets shared automatically
        dao::create<ASSET, STABLE>(
            2000,
            2000,
            dao_name,
            icon_url,
            TEST_REVIEW_PERIOD,
            TEST_TRADING_PERIOD,
            ASSET_DECIMALS,
            STABLE_DECIMALS,
            string::utf8(ASSET_NAME),
            string::utf8(STABLE_NAME),
            asset_icon_url,
            stable_icon_url,
            std::ascii::string(ASSET_SYMBOL),
            std::ascii::string(STABLE_SYMBOL),
            60_000,
            300_000,
            DEFAULT_TWAP_INITIAL_OBSERVATION,
            TWAP_THESHOLD,
            string::utf8(b"DAO description"),
            &clock,
            test_scenario::ctx(&mut scenario),
        );
    };

    // Second transaction: Create a proposal with initial amounts
    test_scenario::next_tx(&mut scenario, admin);
    {
        // Take the shared DAO
        let mut dao = test_scenario::take_shared<DAO>(&scenario);

        // Create coins for proposal creation with sufficient amount for AMMs
        let (asset_coin, stable_coin) = mint_test_coins(2000, test_scenario::ctx(&mut scenario));
        let mut fee_manager = test_scenario::take_shared<FeeManager>(&scenario);
        let payment = coin::mint_for_testing(
            fee::get_verification_fee(&fee_manager),
            ctx(&mut scenario),
        );

        // Create initial amounts for a proposal with 2 outcomes
        // Each outcome needs two values: [asset_amount, stable_amount]
        // Format: [outcome0_asset, outcome0_stable, outcome1_asset, outcome1_stable]
        let initial_amounts = vector[
            2000,
            2000, // First outcome AMM (Reject)
            2000,
            2000, // Second outcome AMM (Accept)
        ];

        // Create a proposal with initial amounts
        dao::create_proposal(
            &mut dao,
            &mut fee_manager,
            payment,
            2, // outcome_count
            asset_coin,
            stable_coin,
            string::utf8(b"Test Proposal"),
            string::utf8(b"Test Details"),
            string::utf8(b"{}"),
            create_default_outcome_messages(),
            initial_amounts,
            &clock,
            test_scenario::ctx(&mut scenario),
        );

        // Return the shared DAO
        test_scenario::return_shared(dao);
        test_scenario::return_shared(fee_manager);
    };

    clock::destroy_for_testing(clock);
    test_scenario::end(scenario);
}

#[test]
#[expected_failure]
fun test_create_proposal_with_invalid_initial_amounts() {
    let admin = @0xA;
    let (clock, mut scenario) = setup_test(admin);

    // First transaction: Create the DAO
    test_scenario::next_tx(&mut scenario, admin);
    {
        let dao_name = std::ascii::string(TEST_DAO_NAME);
        let icon_url = std::ascii::string(TEST_DAO_URL);
        let (asset_icon_url, stable_icon_url) = setup_test_metadata();

        // Create the DAO - it gets shared automatically
        dao::create<ASSET, STABLE>(
            2000,
            2000,
            dao_name,
            icon_url,
            TEST_REVIEW_PERIOD,
            TEST_TRADING_PERIOD,
            ASSET_DECIMALS,
            STABLE_DECIMALS,
            string::utf8(ASSET_NAME),
            string::utf8(STABLE_NAME),
            asset_icon_url,
            stable_icon_url,
            std::ascii::string(ASSET_SYMBOL),
            std::ascii::string(STABLE_SYMBOL),
            60_000,
            300_000,
            DEFAULT_TWAP_INITIAL_OBSERVATION,
            TWAP_THESHOLD,
            string::utf8(b"DAO description"),
            &clock,
            test_scenario::ctx(&mut scenario),
        );
    };

    // Second transaction: Try to create a proposal with invalid initial amounts
    test_scenario::next_tx(&mut scenario, admin);
    {
        // Take the shared DAO
        let mut dao = test_scenario::take_shared<DAO>(&scenario);

        // Create coins for proposal creation
        let (asset_coin, stable_coin) = mint_test_coins(2000, test_scenario::ctx(&mut scenario));

        // Create invalid initial amounts (wrong number of values)
        // Should be 4 values for 2 outcomes (2 values per outcome)
        let initial_amounts = vector[2000, 2000, 2000]; // Missing one value
        let mut fee_manager = test_scenario::take_shared<FeeManager>(&scenario);
        let payment = coin::mint_for_testing(
            fee::get_verification_fee(&fee_manager),
            ctx(&mut scenario),
        );

        // This should fail because we don't have the correct number of initial amounts
        dao::create_proposal(
            &mut dao,
            &mut fee_manager,
            payment,
            2, // outcome_count
            asset_coin,
            stable_coin,
            string::utf8(b"Test Proposal"),
            string::utf8(b"Test Details"),
            string::utf8(b"{}"),
            create_default_outcome_messages(),
            initial_amounts,
            &clock,
            test_scenario::ctx(&mut scenario),
        );

        // The code shouldn't reach here in the expected failure test
        test_scenario::return_shared(dao);
        test_scenario::return_shared(fee_manager);
    };

    clock::destroy_for_testing(clock);
    test_scenario::end(scenario);
}

#[test]
#[expected_failure(abort_code = proposal::EInvalidAmount)]
fun test_create_proposal_with_insufficient_initial_amounts() {
    let admin = @0xA;
    let (clock, mut scenario) = setup_test(admin);

    // First transaction: Create the DAO
    test_scenario::next_tx(&mut scenario, admin);
    {
        let dao_name = std::ascii::string(TEST_DAO_NAME);
        let icon_url = std::ascii::string(TEST_DAO_URL);
        let (asset_icon_url, stable_icon_url) = setup_test_metadata();

        // Create the DAO - it gets shared automatically
        dao::create<ASSET, STABLE>(
            2000,
            2000,
            dao_name,
            icon_url,
            TEST_REVIEW_PERIOD,
            TEST_TRADING_PERIOD,
            ASSET_DECIMALS,
            STABLE_DECIMALS,
            string::utf8(ASSET_NAME),
            string::utf8(STABLE_NAME),
            asset_icon_url,
            stable_icon_url,
            std::ascii::string(ASSET_SYMBOL),
            std::ascii::string(STABLE_SYMBOL),
            60_000,
            300_000,
            DEFAULT_TWAP_INITIAL_OBSERVATION,
            TWAP_THESHOLD,
            string::utf8(b"DAO description"),
            &clock,
            test_scenario::ctx(&mut scenario),
        );
    };

    // Second transaction: Try to create a proposal with insufficient initial amounts
    test_scenario::next_tx(&mut scenario, admin);
    {
        // Take the shared DAO
        let mut dao = test_scenario::take_shared<DAO>(&scenario);

        // Create coins for proposal creation
        let (asset_coin, stable_coin) = mint_test_coins(2000, test_scenario::ctx(&mut scenario));
        let mut fee_manager = test_scenario::take_shared<FeeManager>(&scenario);
        let payment = coin::mint_for_testing(
            fee::get_verification_fee(&fee_manager),
            ctx(&mut scenario),
        );

        // Create initial amounts with values below minimum
        let initial_amounts = vector[
            100,
            100, // First outcome AMM (below minimum of 1000)
            2000,
            2000, // Second outcome AMM
        ];

        // This should fail because first AMM has insufficient amounts
        dao::create_proposal(
            &mut dao,
            &mut fee_manager,
            payment,
            2, // outcome_count
            asset_coin,
            stable_coin,
            string::utf8(b"Test Proposal"),
            string::utf8(b"Test Details"),
            string::utf8(b"{}"),
            create_default_outcome_messages(),
            initial_amounts,
            &clock,
            test_scenario::ctx(&mut scenario),
        );

        // The code shouldn't reach here in the expected failure test
        test_scenario::return_shared(dao);
        test_scenario::return_shared(fee_manager);
    };

    clock::destroy_for_testing(clock);
    test_scenario::end(scenario);
}
