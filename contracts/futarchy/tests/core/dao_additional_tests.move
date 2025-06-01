#[test_only]
module futarchy::dao_additional_tests;

use futarchy::coin_escrow;
use futarchy::dao::{Self, DAO};
use futarchy::fee::{Self, FeeManager};
use futarchy::market_state;
use futarchy::oracle;
use futarchy::proposal::{Self, Proposal};
use std::ascii::String as AsciiString;
use std::option;
use std::string::{Self, String};
use sui::clock::{Self, Clock};
use sui::coin::{Self, Coin};
use sui::object;
use sui::test_scenario::{Self, Scenario, ctx};
use sui::tx_context;
use sui::url;

// Test coins
public struct ASSET has copy, drop {}
public struct STABLE has copy, drop {}
public struct WRONG_ASSET has copy, drop {}
public struct WRONG_STABLE has copy, drop {}

// Test constants (same as in dao_tests)
const DEFAULT_TWAP_START_DELAY: u64 = 60_000;
const DEFAULT_TWAP_STEP_MAX: u64 = 300_000;
const DEFAULT_TWAP_INITIAL_OBSERVATION: u128 = 1_000_000;
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

// Reuse helper functions from dao_tests
fun setup_test(sender: address): (Clock, Scenario) {
    let mut scenario = test_scenario::begin(sender);
    fee::create_fee_manager_for_testing(test_scenario::ctx(&mut scenario));
    let clock = clock::create_for_testing(test_scenario::ctx(&mut scenario));
    (clock, scenario)
}

fun setup_test_metadata(): (AsciiString, AsciiString) {
    (std::ascii::string(b""), std::ascii::string(b""))
}

fun mint_test_coins(amount: u64, ctx: &mut tx_context::TxContext): (Coin<ASSET>, Coin<STABLE>) {
    (coin::mint_for_testing<ASSET>(amount, ctx), coin::mint_for_testing<STABLE>(amount, ctx))
}

fun create_default_outcome_messages(): vector<String> {
    vector[string::utf8(b"Reject"), string::utf8(b"Accept")]
}

// Test: Create DAO with invalid decimals difference
#[test]
#[expected_failure(abort_code = dao::EINVALID_DECIMALS_DIFF)]
fun test_create_dao_with_invalid_decimals_diff() {
    let admin = @0xA;
    let (clock, mut scenario) = setup_test(admin);

    test_scenario::next_tx(&mut scenario, admin);
    {
        let dao_name = std::ascii::string(TEST_DAO_NAME);
        let icon_url = std::ascii::string(TEST_DAO_URL);
        let (asset_icon_url, stable_icon_url) = setup_test_metadata();

        // Set asset_decimals and stable_decimals with difference > 9
        let too_high_decimals: u8 = 21;
        let too_low_decimals: u8 = 1;

        // This should fail due to the difference being more than 9
        dao::create<ASSET, STABLE>(
            2000,
            2000,
            dao_name,
            icon_url,
            TEST_REVIEW_PERIOD,
            TEST_TRADING_PERIOD,
            too_low_decimals, // asset_decimals
            too_high_decimals, // stable_decimals (diff = 20, which is > 9)
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

    clock::destroy_for_testing(clock);
    test_scenario::end(scenario);
}

// Test: Create DAO with decimals that are too large
#[test]
#[expected_failure(abort_code = dao::EINVALID_DECIMALS_DIFF)]
fun test_create_dao_with_large_decimals() {
    let admin = @0xA;
    let (clock, mut scenario) = setup_test(admin);

    test_scenario::next_tx(&mut scenario, admin);
    {
        let dao_name = std::ascii::string(TEST_DAO_NAME);
        let icon_url = std::ascii::string(TEST_DAO_URL);
        let (asset_icon_url, stable_icon_url) = setup_test_metadata();

        // Set decimals above the MAX_DECIMALS (which is 21)
        let too_large_decimals: u8 = 22;

        // This should fail because asset_decimals is too large
        dao::create<ASSET, STABLE>(
            2000,
            2000,
            dao_name,
            icon_url,
            TEST_REVIEW_PERIOD,
            TEST_TRADING_PERIOD,
            too_large_decimals, // asset_decimals too large
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

    clock::destroy_for_testing(clock);
    test_scenario::end(scenario);
}

// Test: Create proposal with title too long
#[test]
#[expected_failure(abort_code = dao::ETITLE_TOO_LONG)]
fun test_create_proposal_with_title_too_long() {
    let admin = @0xA;
    let (clock, mut scenario) = setup_test(admin);

    // First create the DAO
    test_scenario::next_tx(&mut scenario, admin);
    {
        let dao_name = std::ascii::string(TEST_DAO_NAME);
        let icon_url = std::ascii::string(TEST_DAO_URL);
        let (asset_icon_url, stable_icon_url) = setup_test_metadata();

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

    // Then try to create a proposal with a title that's too long
    test_scenario::next_tx(&mut scenario, admin);
    {
        let mut dao = test_scenario::take_shared<DAO>(&scenario);
        let (asset_coin, stable_coin) = mint_test_coins(2000, test_scenario::ctx(&mut scenario));
        let mut fee_manager = test_scenario::take_shared<FeeManager>(&scenario);
        let payment = coin::mint_for_testing(
            fee::get_verification_fee(&fee_manager),
            ctx(&mut scenario),
        );

        // Create a long string more efficiently with a pre-defined string instead of concatenation
        // This is just slightly longer than TITLE_MAX_LENGTH (512)
        let long_title_bytes =
            b"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";
        let long_title = string::utf8(long_title_bytes);

        // Try to create a proposal with too long title - should fail
        dao::create_proposal(
            &mut dao,
            &mut fee_manager,
            payment,
            2,
            asset_coin,
            stable_coin,
            long_title,
            string::utf8(b"Test Details"),
            string::utf8(b"{}"),
            create_default_outcome_messages(),
            option::none(),
            &clock,
            test_scenario::ctx(&mut scenario),
        );

        test_scenario::return_shared(dao);
        test_scenario::return_shared(fee_manager);
    };

    clock::destroy_for_testing(clock);
    test_scenario::end(scenario);
}

// Test: Create proposal with metadata too long
#[test]
#[expected_failure(abort_code = dao::EMETADATA_TOO_LONG)]
fun test_create_proposal_with_metadata_too_long() {
    let admin = @0xA;
    let (clock, mut scenario) = setup_test(admin);

    // First create the DAO
    test_scenario::next_tx(&mut scenario, admin);
    {
        let dao_name = std::ascii::string(TEST_DAO_NAME);
        let icon_url = std::ascii::string(TEST_DAO_URL);
        let (asset_icon_url, stable_icon_url) = setup_test_metadata();

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

    // Then try to create a proposal with metadata that's too long
    test_scenario::next_tx(&mut scenario, admin);
    {
        let mut dao = test_scenario::take_shared<DAO>(&scenario);
        let (asset_coin, stable_coin) = mint_test_coins(2000, test_scenario::ctx(&mut scenario));
        let mut fee_manager = test_scenario::take_shared<FeeManager>(&scenario);
        let payment = coin::mint_for_testing(
            fee::get_verification_fee(&fee_manager),
            ctx(&mut scenario),
        );

        // Create a metadata string directly that exceeds METADATA_MAX_LENGTH (1024)
        // The following string is approximately 1030 characters long
        let long_metadata_bytes =
            b"{\"data\":{\"lorem\":\"ipsum dolor sit amet, consectetur adipiscing elit. Sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea commodo consequat. Duis aute irure dolor in reprehenderit in voluptate velit esse cillum dolore eu fugiat nulla pariatur. Excepteur sint occaecat cupidatat non proident, sunt in culpa qui officia deserunt mollit anim id est laborum. Lorem ipsum dolor sit amet, consectetur adipiscing elit. Sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea commodo consequat. Duis aute irure dolor in reprehenderit in voluptate velit esse cillum dolore eu fugiat nulla pariatur. Excepteur sint occaecat cupidatat non proident, sunt in culpa qui officia deserunt mollit anim id est laborum. Lorem ipsum dolor sit amet, consectetur adipiscing elit. Sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea commodo consequat. Duis aute irure dolor in reprehenderit in voluptate velit esse cillum dolore.\"}}";
        let long_metadata = string::utf8(long_metadata_bytes);

        // Try to create a proposal with too long metadata - should fail
        dao::create_proposal(
            &mut dao,
            &mut fee_manager,
            payment,
            2,
            asset_coin,
            stable_coin,
            string::utf8(b"Test Proposal"),
            string::utf8(b"Test Details"),
            long_metadata,
            create_default_outcome_messages(),
            option::none(),
            &clock,
            test_scenario::ctx(&mut scenario),
        );

        test_scenario::return_shared(dao);
        test_scenario::return_shared(fee_manager);
    };

    clock::destroy_for_testing(clock);
    test_scenario::end(scenario);
}

//  Test: Create proposal with empty title
#[test]
#[expected_failure(abort_code = dao::ETITLE_TOO_SHORT)]
fun test_create_proposal_with_empty_title() {
    let admin = @0xA;
    let (clock, mut scenario) = setup_test(admin);

    // First create the DAO
    test_scenario::next_tx(&mut scenario, admin);
    {
        let dao_name = std::ascii::string(TEST_DAO_NAME);
        let icon_url = std::ascii::string(TEST_DAO_URL);
        let (asset_icon_url, stable_icon_url) = setup_test_metadata();

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

    // Then try to create a proposal with an empty title
    test_scenario::next_tx(&mut scenario, admin);
    {
        let mut dao = test_scenario::take_shared<DAO>(&scenario);
        let (asset_coin, stable_coin) = mint_test_coins(2000, test_scenario::ctx(&mut scenario));
        let mut fee_manager = test_scenario::take_shared<FeeManager>(&scenario);
        let payment = coin::mint_for_testing(
            fee::get_verification_fee(&fee_manager),
            ctx(&mut scenario),
        );

        // Try to create a proposal with empty title - should fail
        dao::create_proposal(
            &mut dao,
            &mut fee_manager,
            payment,
            2,
            asset_coin,
            stable_coin,
            string::utf8(b""), // Empty title
            string::utf8(b"Test Details"),
            string::utf8(b"{}"),
            create_default_outcome_messages(),
            option::none(),
            &clock,
            test_scenario::ctx(&mut scenario),
        );

        test_scenario::return_shared(dao);
        test_scenario::return_shared(fee_manager);
    };

    clock::destroy_for_testing(clock);
    test_scenario::end(scenario);
}

// Test: Create proposal with wrong asset type
#[test]
#[expected_failure(abort_code = dao::EINVALID_ASSET_TYPE)]
fun test_create_proposal_with_wrong_asset_type() {
    let admin = @0xA;
    let (clock, mut scenario) = setup_test(admin);

    // First create the DAO with ASSET and STABLE
    test_scenario::next_tx(&mut scenario, admin);
    {
        let dao_name = std::ascii::string(TEST_DAO_NAME);
        let icon_url = std::ascii::string(TEST_DAO_URL);
        let (asset_icon_url, stable_icon_url) = setup_test_metadata();

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

    // Then try to create a proposal with WRONG_ASSET and STABLE
    test_scenario::next_tx(&mut scenario, admin);
    {
        let mut dao = test_scenario::take_shared<DAO>(&scenario);

        // Create coins with wrong asset type
        let wrong_asset_coin = coin::mint_for_testing<WRONG_ASSET>(
            2000,
            test_scenario::ctx(&mut scenario),
        );
        let stable_coin = coin::mint_for_testing<STABLE>(2000, test_scenario::ctx(&mut scenario));

        let mut fee_manager = test_scenario::take_shared<FeeManager>(&scenario);
        let payment = coin::mint_for_testing(
            fee::get_verification_fee(&fee_manager),
            ctx(&mut scenario),
        );

        // Try to create a proposal with wrong asset type - should fail
        dao::create_proposal<WRONG_ASSET, STABLE>(
            &mut dao,
            &mut fee_manager,
            payment,
            2,
            wrong_asset_coin,
            stable_coin,
            string::utf8(b"Test Proposal"),
            string::utf8(b"Test Details"),
            string::utf8(b"{}"),
            create_default_outcome_messages(),
            option::none(),
            &clock,
            test_scenario::ctx(&mut scenario),
        );

        test_scenario::return_shared(dao);
        test_scenario::return_shared(fee_manager);
    };

    clock::destroy_for_testing(clock);
    test_scenario::end(scenario);
}

//  Test: Create proposal with wrong stable type
#[test]
#[expected_failure(abort_code = dao::EINVALID_STABLE_TYPE)]
fun test_create_proposal_with_wrong_stable_type() {
    let admin = @0xA;
    let (clock, mut scenario) = setup_test(admin);

    // First create the DAO with ASSET and STABLE
    test_scenario::next_tx(&mut scenario, admin);
    {
        let dao_name = std::ascii::string(TEST_DAO_NAME);
        let icon_url = std::ascii::string(TEST_DAO_URL);
        let (asset_icon_url, stable_icon_url) = setup_test_metadata();

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

    // Then try to create a proposal with ASSET and WRONG_STABLE
    test_scenario::next_tx(&mut scenario, admin);
    {
        let mut dao = test_scenario::take_shared<DAO>(&scenario);

        // Create coins with wrong stable type
        let asset_coin = coin::mint_for_testing<ASSET>(2000, test_scenario::ctx(&mut scenario));
        let wrong_stable_coin = coin::mint_for_testing<WRONG_STABLE>(
            2000,
            test_scenario::ctx(&mut scenario),
        );

        let mut fee_manager = test_scenario::take_shared<FeeManager>(&scenario);
        let payment = coin::mint_for_testing(
            fee::get_verification_fee(&fee_manager),
            ctx(&mut scenario),
        );

        // Try to create a proposal with wrong stable type - should fail
        dao::create_proposal<ASSET, WRONG_STABLE>(
            &mut dao,
            &mut fee_manager,
            payment,
            2,
            asset_coin,
            wrong_stable_coin,
            string::utf8(b"Test Proposal"),
            string::utf8(b"Test Details"),
            string::utf8(b"{}"),
            create_default_outcome_messages(),
            option::none(),
            &clock,
            test_scenario::ctx(&mut scenario),
        );

        test_scenario::return_shared(dao);
        test_scenario::return_shared(fee_manager);
    };

    clock::destroy_for_testing(clock);
    test_scenario::end(scenario);
}

// Test: Create proposal when creation is disabled
#[test]
#[expected_failure(abort_code = dao::EPROPOSAL_CREATION_DISABLED)]
fun test_create_proposal_when_disabled() {
    let admin = @0xA;
    let (clock, mut scenario) = setup_test(admin);

    // First create the DAO
    test_scenario::next_tx(&mut scenario, admin);
    {
        let dao_name = std::ascii::string(TEST_DAO_NAME);
        let icon_url = std::ascii::string(TEST_DAO_URL);
        let (asset_icon_url, stable_icon_url) = setup_test_metadata();

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

    // Disable proposal creation and then immediately try to create a proposal in the same transaction
    test_scenario::next_tx(&mut scenario, admin);
    {
        // Take the DAO and disable proposals
        let mut dao = test_scenario::take_shared<DAO>(&scenario);
        dao::disable_proposals(&mut dao);

        // Verify proposals are now disabled
        assert!(!dao::are_proposals_enabled(&dao), 0);

        // Try to create a proposal in the same transaction - this should fail with EPROPOSAL_CREATION_DISABLED
        let mut fee_manager = test_scenario::take_shared<FeeManager>(&scenario);
        let (asset_coin, stable_coin) = mint_test_coins(2000, test_scenario::ctx(&mut scenario));
        let payment = coin::mint_for_testing(
            fee::get_verification_fee(&fee_manager),
            test_scenario::ctx(&mut scenario),
        );

        dao::create_proposal(
            &mut dao,
            &mut fee_manager,
            payment,
            2,
            asset_coin,
            stable_coin,
            string::utf8(b"Test Proposal"),
            string::utf8(b"Test Details"),
            string::utf8(b"{}"),
            create_default_outcome_messages(),
            option::none(),
            &clock,
            test_scenario::ctx(&mut scenario),
        );

        // These returns won't actually be executed because the test should fail above
        test_scenario::return_shared(dao);
        test_scenario::return_shared(fee_manager);
    };

    clock::destroy_for_testing(clock);
    test_scenario::end(scenario);
}

// Test: Try to sign result for non-existent proposal
#[test]
#[expected_failure(abort_code = dao::EPROPOSAL_NOT_FOUND)]
fun test_sign_result_nonexistent_proposal() {
    let admin = @0xA;
    let (clock, mut scenario) = setup_test(admin);

    // First create the DAO
    test_scenario::next_tx(&mut scenario, admin);
    {
        let dao_name = std::ascii::string(TEST_DAO_NAME);
        let icon_url = std::ascii::string(TEST_DAO_URL);
        let (asset_icon_url, stable_icon_url) = setup_test_metadata();

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

    // Create a proposal
    test_scenario::next_tx(&mut scenario, admin);
    {
        let mut dao = test_scenario::take_shared<DAO>(&scenario);
        let (asset_coin, stable_coin) = mint_test_coins(2000, test_scenario::ctx(&mut scenario));
        let mut fee_manager = test_scenario::take_shared<FeeManager>(&scenario);
        let payment = coin::mint_for_testing(
            fee::get_verification_fee(&fee_manager),
            ctx(&mut scenario),
        );

        dao::create_proposal(
            &mut dao,
            &mut fee_manager,
            payment,
            2,
            asset_coin,
            stable_coin,
            string::utf8(b"Test Proposal"),
            string::utf8(b"Test Details"),
            string::utf8(b"{}"),
            create_default_outcome_messages(),
            option::none(),
            &clock,
            test_scenario::ctx(&mut scenario),
        );

        test_scenario::return_shared(dao);
        test_scenario::return_shared(fee_manager);
    };

    // Now try to sign result with a non-existent proposal ID
    test_scenario::next_tx(&mut scenario, admin);
    {
        let mut dao = test_scenario::take_shared<DAO>(&scenario);
        let mut escrow = test_scenario::take_shared<coin_escrow::TokenEscrow<ASSET, STABLE>>(
            &scenario,
        );

        // Create a random/non-existent proposal ID
        let fake_proposal_id = object::id_from_address(@0xDEADBEEF);

        // Try to sign result for non-existent proposal - should fail
        dao::sign_result_entry<ASSET, STABLE>(
            &mut dao,
            fake_proposal_id,
            &mut escrow,
            &clock,
            test_scenario::ctx(&mut scenario),
        );

        test_scenario::return_shared(dao);
        test_scenario::return_shared(escrow);
    };

    clock::destroy_for_testing(clock);
    test_scenario::end(scenario);
}

// 1Test: Try to sign result for already executed proposal
#[test]
#[expected_failure(abort_code = dao::EALREADY_EXECUTED)]
fun test_sign_result_already_executed() {
    let admin = @0xA;
    let (clock, mut scenario) = setup_test(admin);

    // First create the DAO
    test_scenario::next_tx(&mut scenario, admin);
    {
        let dao_name = std::ascii::string(TEST_DAO_NAME);
        let icon_url = std::ascii::string(TEST_DAO_URL);
        let (asset_icon_url, stable_icon_url) = setup_test_metadata();

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

    // Create a proposal
    test_scenario::next_tx(&mut scenario, admin);
    {
        let mut dao = test_scenario::take_shared<DAO>(&scenario);
        let (asset_coin, stable_coin) = mint_test_coins(2000, test_scenario::ctx(&mut scenario));
        let mut fee_manager = test_scenario::take_shared<FeeManager>(&scenario);
        let payment = coin::mint_for_testing(
            fee::get_verification_fee(&fee_manager),
            ctx(&mut scenario),
        );

        dao::create_proposal(
            &mut dao,
            &mut fee_manager,
            payment,
            2,
            asset_coin,
            stable_coin,
            string::utf8(b"Test Proposal"),
            string::utf8(b"Test Details"),
            string::utf8(b"{}"),
            create_default_outcome_messages(),
            option::none(),
            &clock,
            test_scenario::ctx(&mut scenario),
        );

        test_scenario::return_shared(dao);
        test_scenario::return_shared(fee_manager);
    };

    // Sign the result for the first time
    test_scenario::next_tx(&mut scenario, admin);
    {
        let mut dao = test_scenario::take_shared<DAO>(&scenario);
        let proposal = test_scenario::take_shared<Proposal<ASSET, STABLE>>(&scenario);
        let proposal_id = object::id(&proposal);

        // Get escrow from proposal
        let mut escrow = test_scenario::take_shared<coin_escrow::TokenEscrow<ASSET, STABLE>>(
            &scenario,
        );

        // Set proposal state to Settlement (2)
        dao::test_set_proposal_state(&mut dao, proposal_id, 2);

        // Properly finalize the market through state transition
        let market_state = coin_escrow::get_market_state_mut(&mut escrow);

        // Start trading first (needed before finalization)
        market_state::start_trading(market_state, 1000, &clock);

        {
            let test_oracle = oracle::test_oracle(test_scenario::ctx(&mut scenario));

            // End trading and move to settlement
            market_state::end_trading(market_state, &clock);

            // Finalize with outcome 1 as winner
            market_state::finalize(market_state, 1, &clock);

            // Clean up the test oracle
            oracle::destroy_for_testing(test_oracle);
        };

        // Set proposal state to finalized (3)
        dao::test_set_proposal_state(&mut dao, proposal_id, 3);

        // Sign the result for the first time
        dao::sign_result_entry<ASSET, STABLE>(
            &mut dao,
            proposal_id,
            &mut escrow,
            &clock,
            test_scenario::ctx(&mut scenario),
        );

        // Verify the result was signed
        let info = dao::get_proposal_info(&dao, proposal_id);
        assert!(dao::is_executed(info), 0);

        test_scenario::return_shared(escrow);
        test_scenario::return_shared(proposal);
        test_scenario::return_shared(dao);
    };

    // Try to sign the result again - should fail
    test_scenario::next_tx(&mut scenario, admin);
    {
        let mut dao = test_scenario::take_shared<DAO>(&scenario);
        let proposal = test_scenario::take_shared<Proposal<ASSET, STABLE>>(&scenario);
        let proposal_id = object::id(&proposal);
        let mut escrow = test_scenario::take_shared<coin_escrow::TokenEscrow<ASSET, STABLE>>(
            &scenario,
        );

        // Try to sign result again for already executed proposal - should fail
        dao::sign_result_entry<ASSET, STABLE>(
            &mut dao,
            proposal_id,
            &mut escrow,
            &clock,
            test_scenario::ctx(&mut scenario),
        );

        test_scenario::return_shared(escrow);
        test_scenario::return_shared(proposal);
        test_scenario::return_shared(dao);
    };

    clock::destroy_for_testing(clock);
    test_scenario::end(scenario);
}

#[test]
fun test_verification_functions() {
    let admin = @0xA;
    let (clock, mut scenario) = setup_test(admin);

    // First create the DAO
    test_scenario::next_tx(&mut scenario, admin);
    {
        let dao_name = std::ascii::string(TEST_DAO_NAME);
        let icon_url = std::ascii::string(TEST_DAO_URL);
        let (asset_icon_url, stable_icon_url) = setup_test_metadata();

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

    // Test the verification functions
    test_scenario::next_tx(&mut scenario, admin);
    {
        let dao = test_scenario::take_shared<DAO>(&scenario);

        // Initially verification should not be pending and not verified
        assert!(!dao::is_verification_pending(&dao), 0);
        assert!(!dao::is_verified(&dao), 1);

        // Attestation URL should be empty initially
        assert!(dao::get_attestation_url(&dao) == &string::utf8(b""), 2);

        test_scenario::return_shared(dao);
    };

    // Note: We can't directly test set_pending_verification and set_verification
    // because they are package-private functions that we can't call from outside the package.
    // In a real test within the futarchy package, we would need to create
    // test-only wrappers for these functions.

    clock::destroy_for_testing(clock);
    test_scenario::end(scenario);
}

// Test 2: Create proposal with insufficient amounts
#[test]
#[expected_failure(abort_code = dao::EINVALID_AMOUNT)]
fun test_create_proposal_with_insufficient_amounts() {
    let admin = @0xA;
    let (clock, mut scenario) = setup_test(admin);

    // First create the DAO
    test_scenario::next_tx(&mut scenario, admin);
    {
        let dao_name = std::ascii::string(TEST_DAO_NAME);
        let icon_url = std::ascii::string(TEST_DAO_URL);
        let (asset_icon_url, stable_icon_url) = setup_test_metadata();

        dao::create<ASSET, STABLE>(
            2000, // min_asset_amount
            2000, // min_stable_amount
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

    // Try to create a proposal with insufficient asset amount
    test_scenario::next_tx(&mut scenario, admin);
    {
        let mut dao = test_scenario::take_shared<DAO>(&scenario);

        // Create coins with insufficient asset amount (only 1000, but minimum is 2000)
        let asset_coin = coin::mint_for_testing<ASSET>(1000, test_scenario::ctx(&mut scenario));
        let stable_coin = coin::mint_for_testing<STABLE>(2000, test_scenario::ctx(&mut scenario));

        let mut fee_manager = test_scenario::take_shared<FeeManager>(&scenario);
        let payment = coin::mint_for_testing(
            fee::get_verification_fee(&fee_manager),
            ctx(&mut scenario),
        );

        // Try to create a proposal with insufficient asset amount - should fail
        dao::create_proposal(
            &mut dao,
            &mut fee_manager,
            payment,
            2,
            asset_coin,
            stable_coin,
            string::utf8(b"Test Proposal"),
            string::utf8(b"Test Details"),
            string::utf8(b"{}"),
            create_default_outcome_messages(),
            option::none(),
            &clock,
            test_scenario::ctx(&mut scenario),
        );

        test_scenario::return_shared(dao);
        test_scenario::return_shared(fee_manager);
    };

    clock::destroy_for_testing(clock);
    test_scenario::end(scenario);
}

// Test 3: Create proposal with invalid outcome count
#[test]
#[expected_failure(abort_code = dao::EINVALID_OUTCOME_COUNT)]
fun test_create_proposal_with_invalid_outcome_count() {
    let admin = @0xA;
    let (clock, mut scenario) = setup_test(admin);

    // First create the DAO
    test_scenario::next_tx(&mut scenario, admin);
    {
        let dao_name = std::ascii::string(TEST_DAO_NAME);
        let icon_url = std::ascii::string(TEST_DAO_URL);
        let (asset_icon_url, stable_icon_url) = setup_test_metadata();

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

    // Try to create a proposal with invalid outcome count (3, but maximum is 3)
    test_scenario::next_tx(&mut scenario, admin);
    {
        let mut dao = test_scenario::take_shared<DAO>(&scenario);
        let (asset_coin, stable_coin) = mint_test_coins(2000, test_scenario::ctx(&mut scenario));
        let mut fee_manager = test_scenario::take_shared<FeeManager>(&scenario);
        let payment = coin::mint_for_testing(
            fee::get_verification_fee(&fee_manager),
            ctx(&mut scenario),
        );

        // Create outcome messages for 3 outcomes
        let outcome_messages = vector[
            string::utf8(b"Reject"),
            string::utf8(b"Accept"),
            string::utf8(b"3"),
            string::utf8(b"4"),
            string::utf8(b"5"),
            string::utf8(b"6"),
            string::utf8(b"7"),
            string::utf8(b"8"),
            string::utf8(b"9"),
            string::utf8(b"10"),
            string::utf8(b"11"),
        ];

        // Try to create a proposal with too many outcomes - should fail
        dao::create_proposal(
            &mut dao,
            &mut fee_manager,
            payment,
            11, // outcome_count exceeds MAX_OUTCOMES
            asset_coin,
            stable_coin,
            string::utf8(b"Test Proposal"),
            string::utf8(b"Test Details"),
            string::utf8(b"{}"),
            outcome_messages,
            option::none(),
            &clock,
            test_scenario::ctx(&mut scenario),
        );

        test_scenario::return_shared(dao);
        test_scenario::return_shared(fee_manager);
    };

    clock::destroy_for_testing(clock);
    test_scenario::end(scenario);
}
