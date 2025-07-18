#[test_only]
module futarchy::dao_additional_tests;

use futarchy::coin_escrow;
use futarchy::dao::{Self, DAO};
use futarchy::fee::{Self, FeeManager};
use futarchy::market_state;
use futarchy::oracle;
use futarchy::proposal::{Self, Proposal};
use std::ascii::{Self, String as AsciiString};
use std::option;
use std::string::String;
use sui::clock::{Self, Clock, create_for_testing, destroy_for_testing};
use sui::coin::{Self, Coin, mint_for_testing};
use sui::test_scenario::{Self as test, Scenario, ctx, next_tx, take_shared, return_shared, end};
use sui::transfer;

// Test coins
public struct ASSET has copy, drop {}
public struct STABLE has copy, drop {}
public struct WRONG_ASSET has copy, drop {}
public struct WRONG_STABLE has copy, drop {}

// Test constants (same as in dao_tests)
const DEFAULT_TWAP_INITIAL_OBSERVATION: u128 = 1_000_000;
const TEST_DAO_NAME: vector<u8> = b"TestDAO";
const TEST_DAO_URL: vector<u8> = b"https://test.com";
const TEST_REVIEW_PERIOD: u64 = 2_000_000; // 2 seconds
const TEST_TRADING_PERIOD: u64 = 2_000_00; // 1 second
const TWAP_THESHOLD: u64 = 1_000;

// Reuse helper functions from dao_tests
fun setup_test(sender: address): (Clock, Scenario) {
    let mut scenario = test::begin(sender);
    fee::create_fee_manager_for_testing(ctx(&mut scenario));
    let clock = create_for_testing(ctx(&mut scenario));
    (clock, scenario)
}


fun mint_test_coins(amount: u64, ctx: &mut tx_context::TxContext): (Coin<ASSET>, Coin<STABLE>) {
    (mint_for_testing<ASSET>(amount, ctx), mint_for_testing<STABLE>(amount, ctx))
}

fun create_default_outcome_messages(): vector<String> {
    vector[b"Reject".to_string(), b"Accept".to_string()]
}


// Test: Create proposal with title too long
#[test]
#[expected_failure(abort_code = dao::ETitleTooLong)]
fun test_create_proposal_with_title_too_long() {
    let admin = @0xA;
    let (clock, mut scenario) = setup_test(admin);

    // First create the DAO
    next_tx(&mut scenario, admin);
    {
        let dao_name = ascii::string(TEST_DAO_NAME);
        let icon_url = ascii::string(TEST_DAO_URL);
        

        let dao = dao::create<ASSET, STABLE>(
            2000,
            2000,
            dao_name,
            icon_url,
            TEST_REVIEW_PERIOD,
            TEST_TRADING_PERIOD,
            60_000,
            300_000,
            DEFAULT_TWAP_INITIAL_OBSERVATION,
            TWAP_THESHOLD,
            b"DAO description".to_string(),
            3,
            vector::empty<String>(),
            &clock,
            ctx(&mut scenario),
        );
        transfer::public_share_object(dao);
    };

    // Then try to create a proposal with a title that's too long
    next_tx(&mut scenario, admin);
    {
        let mut dao = take_shared<DAO>(&scenario);
        let (asset_coin, stable_coin) = mint_test_coins(2000, ctx(&mut scenario));
        let mut fee_manager = take_shared<FeeManager>(&scenario);
        let payment = mint_for_testing(
            fee::get_verification_fee(&fee_manager),
            ctx(&mut scenario),
        );

        // Create a long string more efficiently with a pre-defined string instead of concatenation
        // This is just slightly longer than TITLE_MAX_LENGTH (512)
        let long_title_bytes =
            b"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";
        let long_title = long_title_bytes.to_string();

        // Try to create a proposal with too long title - should fail
        dao::create_proposal(
            &mut dao,
            &mut fee_manager,
            payment,
            2,
            asset_coin,
            stable_coin,
            long_title,
            vector[b"Test Details for Reject".to_string(), b"Test Details for Accept".to_string()],
            b"{}".to_string(),
            create_default_outcome_messages(),
            vector[2000, 2000, 2000, 2000],
            &clock,
            ctx(&mut scenario),
        );

        return_shared(dao);
        return_shared(fee_manager);
    };

    destroy_for_testing(clock);
    end(scenario);
}

// Test: Create proposal with metadata too long
#[test]
#[expected_failure(abort_code = dao::EMetadataTooLong)]
fun test_create_proposal_with_metadata_too_long() {
    let admin = @0xA;
    let (clock, mut scenario) = setup_test(admin);

    // First create the DAO
    next_tx(&mut scenario, admin);
    {
        let dao_name = ascii::string(TEST_DAO_NAME);
        let icon_url = ascii::string(TEST_DAO_URL);
        

        let dao = dao::create<ASSET, STABLE>(
            2000,
            2000,
            dao_name,
            icon_url,
            TEST_REVIEW_PERIOD,
            TEST_TRADING_PERIOD,
            60_000,
            300_000,
            DEFAULT_TWAP_INITIAL_OBSERVATION,
            TWAP_THESHOLD,
            b"DAO description".to_string(),
            3,
            vector::empty<String>(),
            &clock,
            ctx(&mut scenario),
        );
        transfer::public_share_object(dao);
    };

    // Then try to create a proposal with metadata that's too long
    next_tx(&mut scenario, admin);
    {
        let mut dao = take_shared<DAO>(&scenario);
        let (asset_coin, stable_coin) = mint_test_coins(2000, ctx(&mut scenario));
        let mut fee_manager = take_shared<FeeManager>(&scenario);
        let payment = mint_for_testing(
            fee::get_verification_fee(&fee_manager),
            ctx(&mut scenario),
        );

        // Create a metadata string directly that exceeds METADATA_MAX_LENGTH (1024)
        // The following string is approximately 1030 characters long
        let long_metadata_bytes =
            b"{\"data\":{\"lorem\":\"ipsum dolor sit amet, consectetur adipiscing elit. Sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea commodo consequat. Duis aute irure dolor in reprehenderit in voluptate velit esse cillum dolore eu fugiat nulla pariatur. Excepteur sint occaecat cupidatat non proident, sunt in culpa qui officia deserunt mollit anim id est laborum. Lorem ipsum dolor sit amet, consectetur adipiscing elit. Sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea commodo consequat. Duis aute irure dolor in reprehenderit in voluptate velit esse cillum dolore eu fugiat nulla pariatur. Excepteur sint occaecat cupidatat non proident, sunt in culpa qui officia deserunt mollit anim id est laborum. Lorem ipsum dolor sit amet, consectetur adipiscing elit. Sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea commodo consequat. Duis aute irure dolor in reprehenderit in voluptate velit esse cillum dolore.\"}}";
        let long_metadata = long_metadata_bytes.to_string();

        // Try to create a proposal with too long metadata - should fail
        dao::create_proposal(
            &mut dao,
            &mut fee_manager,
            payment,
            2,
            asset_coin,
            stable_coin,
            b"Test Proposal".to_string(),
            vector[b"Test Details for Reject".to_string(), b"Test Details for Accept".to_string()],
            long_metadata,
            create_default_outcome_messages(),
            vector[2000, 2000, 2000, 2000],
            &clock,
            ctx(&mut scenario),
        );

        return_shared(dao);
        return_shared(fee_manager);
    };

    destroy_for_testing(clock);
    end(scenario);
}

//  Test: Create proposal with empty title
#[test]
#[expected_failure(abort_code = dao::ETitleTooShort)]
fun test_create_proposal_with_empty_title() {
    let admin = @0xA;
    let (clock, mut scenario) = setup_test(admin);

    // First create the DAO
    next_tx(&mut scenario, admin);
    {
        let dao_name = ascii::string(TEST_DAO_NAME);
        let icon_url = ascii::string(TEST_DAO_URL);
        

        let dao = dao::create<ASSET, STABLE>(
            2000,
            2000,
            dao_name,
            icon_url,
            TEST_REVIEW_PERIOD,
            TEST_TRADING_PERIOD,
            60_000,
            300_000,
            DEFAULT_TWAP_INITIAL_OBSERVATION,
            TWAP_THESHOLD,
            b"DAO description".to_string(),
            3,
            vector::empty<String>(),
            &clock,
            ctx(&mut scenario),
        );
        transfer::public_share_object(dao);
    };

    // Then try to create a proposal with an empty title
    next_tx(&mut scenario, admin);
    {
        let mut dao = take_shared<DAO>(&scenario);
        let (asset_coin, stable_coin) = mint_test_coins(2000, ctx(&mut scenario));
        let mut fee_manager = take_shared<FeeManager>(&scenario);
        let payment = mint_for_testing(
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
            b"".to_string(), // Empty title
            vector[b"Test Details for Reject".to_string(), b"Test Details for Accept".to_string()],
            b"{}".to_string(),
            create_default_outcome_messages(),
            vector[2000, 2000, 2000, 2000],
            &clock,
            ctx(&mut scenario),
        );

        return_shared(dao);
        return_shared(fee_manager);
    };

    destroy_for_testing(clock);
    end(scenario);
}

// Test: Create proposal with wrong asset type
#[test]
#[expected_failure(abort_code = dao::EInvalidAssetType)]
fun test_create_proposal_with_wrong_asset_type() {
    let admin = @0xA;
    let (clock, mut scenario) = setup_test(admin);

    // First create the DAO with ASSET and STABLE
    next_tx(&mut scenario, admin);
    {
        let dao_name = ascii::string(TEST_DAO_NAME);
        let icon_url = ascii::string(TEST_DAO_URL);
        

        let dao = dao::create<ASSET, STABLE>(
            2000,
            2000,
            dao_name,
            icon_url,
            TEST_REVIEW_PERIOD,
            TEST_TRADING_PERIOD,
            60_000,
            300_000,
            DEFAULT_TWAP_INITIAL_OBSERVATION,
            TWAP_THESHOLD,
            b"DAO description".to_string(),
            3,
            vector::empty<String>(),
            &clock,
            ctx(&mut scenario),
        );
        transfer::public_share_object(dao);
    };

    // Then try to create a proposal with WRONG_ASSET and STABLE
    next_tx(&mut scenario, admin);
    {
        let mut dao = take_shared<DAO>(&scenario);

        // Create coins with wrong asset type
        let wrong_asset_coin = mint_for_testing<WRONG_ASSET>(
            2000,
            ctx(&mut scenario),
        );
        let stable_coin = mint_for_testing<STABLE>(2000, ctx(&mut scenario));

        let mut fee_manager = take_shared<FeeManager>(&scenario);
        let payment = mint_for_testing(
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
            b"Test Proposal".to_string(),
            vector[b"Test Details for Reject".to_string(), b"Test Details for Accept".to_string()],
            b"{}".to_string(),
            create_default_outcome_messages(),
            vector[2000, 2000, 2000, 2000],
            &clock,
            ctx(&mut scenario),
        );

        return_shared(dao);
        return_shared(fee_manager);
    };

    destroy_for_testing(clock);
    end(scenario);
}

//  Test: Create proposal with wrong stable type
#[test]
#[expected_failure(abort_code = dao::EInvalidStableType)]
fun test_create_proposal_with_wrong_stable_type() {
    let admin = @0xA;
    let (clock, mut scenario) = setup_test(admin);

    // First create the DAO with ASSET and STABLE
    next_tx(&mut scenario, admin);
    {
        let dao_name = ascii::string(TEST_DAO_NAME);
        let icon_url = ascii::string(TEST_DAO_URL);
        

        let dao = dao::create<ASSET, STABLE>(
            2000,
            2000,
            dao_name,
            icon_url,
            TEST_REVIEW_PERIOD,
            TEST_TRADING_PERIOD,
            60_000,
            300_000,
            DEFAULT_TWAP_INITIAL_OBSERVATION,
            TWAP_THESHOLD,
            b"DAO description".to_string(),
            3,
            vector::empty<String>(),
            &clock,
            ctx(&mut scenario),
        );
        transfer::public_share_object(dao);
    };

    // Then try to create a proposal with ASSET and WRONG_STABLE
    next_tx(&mut scenario, admin);
    {
        let mut dao = take_shared<DAO>(&scenario);

        // Create coins with wrong stable type
        let asset_coin = mint_for_testing<ASSET>(2000, ctx(&mut scenario));
        let wrong_stable_coin = mint_for_testing<WRONG_STABLE>(
            2000,
            ctx(&mut scenario),
        );

        let mut fee_manager = take_shared<FeeManager>(&scenario);
        let payment = mint_for_testing(
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
            b"Test Proposal".to_string(),
            vector[b"Test Details for Reject".to_string(), b"Test Details for Accept".to_string()],
            b"{}".to_string(),
            create_default_outcome_messages(),
            vector[2000, 2000, 2000, 2000],
            &clock,
            ctx(&mut scenario),
        );

        return_shared(dao);
        return_shared(fee_manager);
    };

    destroy_for_testing(clock);
    end(scenario);
}

// Test: Create proposal when creation is disabled
#[test]
#[expected_failure(abort_code = dao::EProposalCreationDisabled)]
fun test_create_proposal_when_disabled() {
    let admin = @0xA;
    let (clock, mut scenario) = setup_test(admin);

    // First create the DAO
    next_tx(&mut scenario, admin);
    {
        let dao_name = ascii::string(TEST_DAO_NAME);
        let icon_url = ascii::string(TEST_DAO_URL);
        

        let dao = dao::create<ASSET, STABLE>(
            2000,
            2000,
            dao_name,
            icon_url,
            TEST_REVIEW_PERIOD,
            TEST_TRADING_PERIOD,
            60_000,
            300_000,
            DEFAULT_TWAP_INITIAL_OBSERVATION,
            TWAP_THESHOLD,
            b"DAO description".to_string(),
            3,
            vector::empty<String>(),
            &clock,
            ctx(&mut scenario),
        );
        transfer::public_share_object(dao);
    };

    // Disable proposal creation and then immediately try to create a proposal in the same transaction
    next_tx(&mut scenario, admin);
    {
        // Take the DAO and disable proposals
        let mut dao = take_shared<DAO>(&scenario);
        dao::disable_proposals(&mut dao);

        // Verify proposals are now disabled
        assert!(!dao::are_proposals_enabled(&dao), 0);

        // Try to create a proposal in the same transaction - this should fail with EPROPOSAL_CREATION_DISABLED
        let mut fee_manager = take_shared<FeeManager>(&scenario);
        let (asset_coin, stable_coin) = mint_test_coins(2000, ctx(&mut scenario));
        let payment = mint_for_testing(
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
            b"Test Proposal".to_string(),
            vector[b"Test Details for Reject".to_string(), b"Test Details for Accept".to_string()],
            b"{}".to_string(),
            create_default_outcome_messages(),
            vector[2000, 2000, 2000, 2000],
            &clock,
            ctx(&mut scenario),
        );

        // These returns won't actually be executed because the test should fail above
        return_shared(dao);
        return_shared(fee_manager);
    };

    destroy_for_testing(clock);
    end(scenario);
}

// Test: Try to sign result for non-existent proposal
#[test]
#[expected_failure(abort_code = dao::EProposalNotFound)]
fun test_sign_result_nonexistent_proposal() {
    let admin = @0xA;
    let (clock, mut scenario) = setup_test(admin);

    // First create the DAO
    next_tx(&mut scenario, admin);
    {
        let dao_name = ascii::string(TEST_DAO_NAME);
        let icon_url = ascii::string(TEST_DAO_URL);
        

        let dao = dao::create<ASSET, STABLE>(
            2000,
            2000,
            dao_name,
            icon_url,
            TEST_REVIEW_PERIOD,
            TEST_TRADING_PERIOD,
            60_000,
            300_000,
            DEFAULT_TWAP_INITIAL_OBSERVATION,
            TWAP_THESHOLD,
            b"DAO description".to_string(),
            3,
            vector::empty<String>(),
            &clock,
            ctx(&mut scenario),
        );
        transfer::public_share_object(dao);
    };

    // Create a proposal
    next_tx(&mut scenario, admin);
    {
        let mut dao = take_shared<DAO>(&scenario);
        let (asset_coin, stable_coin) = mint_test_coins(2000, ctx(&mut scenario));
        let mut fee_manager = take_shared<FeeManager>(&scenario);
        let payment = mint_for_testing(
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
            b"Test Proposal".to_string(),
            vector[b"Test Details for Reject".to_string(), b"Test Details for Accept".to_string()],
            b"{}".to_string(),
            create_default_outcome_messages(),
            vector[2000, 2000, 2000, 2000],
            &clock,
            ctx(&mut scenario),
        );

        return_shared(dao);
        return_shared(fee_manager);
    };

    // Now try to sign result with a non-existent proposal ID
    next_tx(&mut scenario, admin);
    {
        let mut dao = take_shared<DAO>(&scenario);
        let mut escrow = take_shared<coin_escrow::TokenEscrow<ASSET, STABLE>>(
            &scenario,
        );

        // Create a random/non-existent proposal ID
        let fake_proposal_id = object::id_from_address(@0xDEADBEEF);

        // Try to sign result for non-existent proposal - should fail
        // Note: This test expects to fail because there's no proposal with fake_proposal_id
        // We need to create a dummy proposal object for the call, but it will fail on validation
        let dummy_proposal = take_shared<Proposal<ASSET, STABLE>>(&scenario);
        dao::sign_result_entry<ASSET, STABLE>(
            &mut dao,
            fake_proposal_id,
            &dummy_proposal,
            &mut escrow,
            &clock,
            ctx(&mut scenario),
        );
        return_shared(dummy_proposal);

        return_shared(dao);
        return_shared(escrow);
    };

    destroy_for_testing(clock);
    end(scenario);
}

// 1Test: Try to sign result for already executed proposal
#[test]
#[expected_failure(abort_code = dao::EAlreadyExecuted)]
fun test_sign_result_already_executed() {
    let admin = @0xA;
    let (clock, mut scenario) = setup_test(admin);

    // First create the DAO
    next_tx(&mut scenario, admin);
    {
        let dao_name = ascii::string(TEST_DAO_NAME);
        let icon_url = ascii::string(TEST_DAO_URL);
        

        let dao = dao::create<ASSET, STABLE>(
            2000,
            2000,
            dao_name,
            icon_url,
            TEST_REVIEW_PERIOD,
            TEST_TRADING_PERIOD,
            60_000,
            300_000,
            DEFAULT_TWAP_INITIAL_OBSERVATION,
            TWAP_THESHOLD,
            b"DAO description".to_string(),
            3,
            vector::empty<String>(),
            &clock,
            ctx(&mut scenario),
        );
        transfer::public_share_object(dao);
    };

    // Create a proposal
    next_tx(&mut scenario, admin);
    {
        let mut dao = take_shared<DAO>(&scenario);
        let (asset_coin, stable_coin) = mint_test_coins(2000, ctx(&mut scenario));
        let mut fee_manager = take_shared<FeeManager>(&scenario);
        let payment = mint_for_testing(
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
            b"Test Proposal".to_string(),
            vector[b"Test Details for Reject".to_string(), b"Test Details for Accept".to_string()],
            b"{}".to_string(),
            create_default_outcome_messages(),
            vector[2000, 2000, 2000, 2000],
            &clock,
            ctx(&mut scenario),
        );

        return_shared(dao);
        return_shared(fee_manager);
    };

    // Sign the result for the first time
    next_tx(&mut scenario, admin);
    {
        let mut dao = take_shared<DAO>(&scenario);
        let proposal = take_shared<Proposal<ASSET, STABLE>>(&scenario);
        let proposal_id = object::id(&proposal);

        // Get escrow from proposal
        let mut escrow = take_shared<coin_escrow::TokenEscrow<ASSET, STABLE>>(
            &scenario,
        );

        // Set proposal state to Settlement (2)
        dao::test_set_proposal_state(&mut dao, proposal_id, 2);

        // Properly finalize the market through state transition
        let market_state = coin_escrow::get_market_state_mut(&mut escrow);

        // Start trading first (needed before finalization)
        market_state::start_trading(market_state, 1000, &clock);

        {
            let test_oracle = oracle::test_oracle(ctx(&mut scenario));

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
            &proposal,
            &mut escrow,
            &clock,
            ctx(&mut scenario),
        );

        // Verify the result was signed
        let info = dao::get_proposal_info(&dao, proposal_id);
        assert!(dao::is_executed(info), 0);

        return_shared(escrow);
        return_shared(proposal);
        return_shared(dao);
    };

    // Try to sign the result again - should fail
    next_tx(&mut scenario, admin);
    {
        let mut dao = take_shared<DAO>(&scenario);
        let proposal = take_shared<Proposal<ASSET, STABLE>>(&scenario);
        let proposal_id = object::id(&proposal);
        let mut escrow = take_shared<coin_escrow::TokenEscrow<ASSET, STABLE>>(
            &scenario,
        );

        // Try to sign result again for already executed proposal - should fail
        dao::sign_result_entry<ASSET, STABLE>(
            &mut dao,
            proposal_id,
            &proposal,
            &mut escrow,
            &clock,
            ctx(&mut scenario),
        );

        return_shared(escrow);
        return_shared(proposal);
        return_shared(dao);
    };

    destroy_for_testing(clock);
    end(scenario);
}

#[test]
fun test_verification_functions() {
    let admin = @0xA;
    let (clock, mut scenario) = setup_test(admin);

    // First create the DAO
    next_tx(&mut scenario, admin);
    {
        let dao_name = ascii::string(TEST_DAO_NAME);
        let icon_url = ascii::string(TEST_DAO_URL);
        

        let dao = dao::create<ASSET, STABLE>(
            2000,
            2000,
            dao_name,
            icon_url,
            TEST_REVIEW_PERIOD,
            TEST_TRADING_PERIOD,
            60_000,
            300_000,
            DEFAULT_TWAP_INITIAL_OBSERVATION,
            TWAP_THESHOLD,
            b"DAO description".to_string(),
            3,
            vector::empty<String>(),
            &clock,
            ctx(&mut scenario),
        );
        transfer::public_share_object(dao);
    };

    // Test the verification functions
    next_tx(&mut scenario, admin);
    {
        let dao = take_shared<DAO>(&scenario);

        // Initially verification should not be pending and not verified
        assert!(!dao::is_verification_pending(&dao), 0);
        assert!(!dao::is_verified(&dao), 1);

        // Attestation URL should be empty initially
        assert!(dao::get_attestation_url(&dao) == &b"".to_string(), 2);

        return_shared(dao);
    };

    // Note: We can't directly test set_pending_verification and set_verification
    // because they are package-private functions that we can't call from outside the package.
    // In a real test within the futarchy package, we would need to create
    // test-only wrappers for these functions.

    destroy_for_testing(clock);
    end(scenario);
}

// Test 2: Create proposal with insufficient amounts
#[test]
#[expected_failure(abort_code = dao::EInvalidAmount)]
fun test_create_proposal_with_insufficient_amounts() {
    let admin = @0xA;
    let (clock, mut scenario) = setup_test(admin);

    // First create the DAO
    next_tx(&mut scenario, admin);
    {
        let dao_name = ascii::string(TEST_DAO_NAME);
        let icon_url = ascii::string(TEST_DAO_URL);
        

        let dao = dao::create<ASSET, STABLE>(
            2000, // min_asset_amount
            2000, // min_stable_amount
            dao_name,
            icon_url,
            TEST_REVIEW_PERIOD,
            TEST_TRADING_PERIOD,
            60_000,
            300_000,
            DEFAULT_TWAP_INITIAL_OBSERVATION,
            TWAP_THESHOLD,
            b"DAO description".to_string(),
            3,
            vector::empty<String>(),
            &clock,
            ctx(&mut scenario),
        );
        transfer::public_share_object(dao);
    };

    // Try to create a proposal with insufficient asset amount
    next_tx(&mut scenario, admin);
    {
        let mut dao = take_shared<DAO>(&scenario);

        // Create coins with insufficient asset amount (only 1000, but minimum is 2000)
        let asset_coin = mint_for_testing<ASSET>(1000, ctx(&mut scenario));
        let stable_coin = mint_for_testing<STABLE>(2000, ctx(&mut scenario));

        let mut fee_manager = take_shared<FeeManager>(&scenario);
        let payment = mint_for_testing(
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
            b"Test Proposal".to_string(),
            vector[b"Test Details for Reject".to_string(), b"Test Details for Accept".to_string()],
            b"{}".to_string(),
            create_default_outcome_messages(),
            vector[2000, 2000, 2000, 2000],
            &clock,
            ctx(&mut scenario),
        );

        return_shared(dao);
        return_shared(fee_manager);
    };

    destroy_for_testing(clock);
    end(scenario);
}

// Test 3: Create proposal with invalid outcome count
#[test]
#[expected_failure(abort_code = dao::EInvalidOutcomeCount)]
fun test_create_proposal_with_invalid_outcome_count() {
    let admin = @0xA;
    let (clock, mut scenario) = setup_test(admin);

    // First create the DAO
    next_tx(&mut scenario, admin);
    {
        let dao_name = ascii::string(TEST_DAO_NAME);
        let icon_url = ascii::string(TEST_DAO_URL);
        

        let dao = dao::create<ASSET, STABLE>(
            2000,
            2000,
            dao_name,
            icon_url,
            TEST_REVIEW_PERIOD,
            TEST_TRADING_PERIOD,
            60_000,
            300_000,
            DEFAULT_TWAP_INITIAL_OBSERVATION,
            TWAP_THESHOLD,
            b"DAO description".to_string(),
            3,
            vector::empty<String>(),
            &clock,
            ctx(&mut scenario),
        );
        transfer::public_share_object(dao);
    };

    // Try to create a proposal with invalid outcome count (3, but maximum is 3)
    next_tx(&mut scenario, admin);
    {
        let mut dao = take_shared<DAO>(&scenario);
        let (asset_coin, stable_coin) = mint_test_coins(2000, ctx(&mut scenario));
        let mut fee_manager = take_shared<FeeManager>(&scenario);
        let payment = mint_for_testing(
            fee::get_verification_fee(&fee_manager),
            ctx(&mut scenario),
        );

        // Create outcome messages for 3 outcomes
        let outcome_messages = vector[
            b"Reject".to_string(),
            b"Accept".to_string(),
            b"3".to_string(),
            b"4".to_string(),
            b"5".to_string(),
            b"6".to_string(),
            b"7".to_string(),
            b"8".to_string(),
            b"9".to_string(),
            b"10".to_string(),
            b"11".to_string(),
        ];

        // Try to create a proposal with too many outcomes - should fail
        dao::create_proposal(
            &mut dao,
            &mut fee_manager,
            payment,
            11, // outcome_count exceeds MAX_OUTCOMES
            asset_coin,
            stable_coin,
            b"Test Proposal".to_string(),
            vector[
                b"Details for outcome 1".to_string(),
                b"Details for outcome 2".to_string(),
                b"Details for outcome 3".to_string(),
                b"Details for outcome 4".to_string(),
                b"Details for outcome 5".to_string(),
                b"Details for outcome 6".to_string(),
                b"Details for outcome 7".to_string(),
                b"Details for outcome 8".to_string(),
                b"Details for outcome 9".to_string(),
                b"Details for outcome 10".to_string(),
                b"Details for outcome 11".to_string()
            ],
            b"{}".to_string(),
            outcome_messages,
            vector[2000, 2000, 2000, 2000, 2000, 2000, 2000, 2000, 2000, 2000, 2000, 2000, 2000, 2000, 2000, 2000, 2000, 2000, 2000, 2000, 2000, 2000],
            &clock,
            ctx(&mut scenario),
        );

        return_shared(dao);
        return_shared(fee_manager);
    };

    destroy_for_testing(clock);
    end(scenario);
}
