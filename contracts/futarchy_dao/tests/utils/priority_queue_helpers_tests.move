#[test_only]
module futarchy::priority_queue_helpers_tests;

use futarchy::priority_queue::{Self, ProposalQueue};
use futarchy::priority_queue_helpers;
use std::option;
use std::string;
use sui::clock::{Self, Clock};
use sui::coin::{Self, Coin};
use sui::test_scenario::{Self as test, ctx};
use sui::transfer;

// Test coin type
public struct STABLE has drop {}

const ADMIN: address = @0xA;
const USER1: address = @0x1;

#[test]
fun test_new_proposal_data() {
    let title = b"Test Proposal".to_string();
    let metadata = b"Test metadata".to_string();
    let outcome_messages = vector[b"YES".to_string(), b"NO".to_string()];
    let outcome_details = vector[b"Approve action".to_string(), b"Reject action".to_string()];
    let initial_asset_amounts = vector[1000, 2000];
    let initial_stable_amounts = vector[3000, 4000];

    let data = priority_queue_helpers::new_proposal_data(
        title,
        metadata,
        outcome_messages,
        outcome_details,
        initial_asset_amounts,
        initial_stable_amounts,
    );

    // Verify data was created
    assert!(priority_queue_helpers::get_title(&data) == &b"Test Proposal".to_string(), 0);
    assert!(priority_queue_helpers::get_metadata(&data) == &b"Test metadata".to_string(), 1);

    let messages = priority_queue_helpers::get_outcome_messages(&data);
    assert!(messages.length() == 2, 2);
    assert!(messages[0] == b"YES".to_string(), 3);
    assert!(messages[1] == b"NO".to_string(), 4);

    let details = priority_queue_helpers::get_outcome_details(&data);
    assert!(details.length() == 2, 5);
    assert!(details[0] == b"Approve action".to_string(), 6);
    assert!(details[1] == b"Reject action".to_string(), 7);

    // These should return empty vectors as they're not stored in new version
    let asset_amounts = priority_queue_helpers::get_initial_asset_amounts(&data);
    assert!(asset_amounts.is_empty(), 8);

    let stable_amounts = priority_queue_helpers::get_initial_stable_amounts(&data);
    assert!(stable_amounts.is_empty(), 9);
}

#[test]
fun test_extract_max_helper() {
    let mut scenario = test::begin(ADMIN);

    // Setup clock
    test::next_tx(&mut scenario, ADMIN);
    {
        let clock = clock::create_for_testing(ctx(&mut scenario));
        clock::share_for_testing(clock);
    };

    // Create queue
    test::next_tx(&mut scenario, ADMIN);
    {
        let uid = object::new(ctx(&mut scenario));
        let dao_id = uid.to_inner();
        uid.delete();
        let queue = priority_queue::new<STABLE>(dao_id, 50, 30, 300000, ctx(&mut scenario));
        transfer::public_share_object(queue);
    };

    // Insert proposal and extract using helper
    test::next_tx(&mut scenario, USER1);
    {
        let mut queue = test::take_shared<ProposalQueue<STABLE>>(&scenario);
        let clock = test::take_shared<Clock>(&scenario);
        let dao_id = priority_queue::dao_id(&queue);

        let data = priority_queue_helpers::new_proposal_data(
            b"Test".to_string(),
            b"metadata".to_string(),
            vector[b"A".to_string()],
            vector[],
            vector[],
            vector[],
        );

        let proposal = priority_queue::new_queued_proposal(
            dao_id,
            1_000_000,
            false,
            USER1,
            data,
            option::none(),
            option::none(),
            &clock,
        );

        priority_queue::insert(&mut queue, proposal, &clock, ctx(&mut scenario));

        // Extract using helper
        let extracted = priority_queue_helpers::extract_max(&mut queue);

        // Verify extraction
        assert!(priority_queue_helpers::get_proposer(&extracted) == USER1, 0);
        assert!(priority_queue_helpers::get_fee(&extracted) == 1_000_000, 1);
        assert!(!priority_queue_helpers::uses_dao_liquidity(&extracted), 2);

        priority_queue::destroy_proposal(extracted);

        test::return_shared(queue);
        test::return_shared(clock);
    };

    test::end(scenario);
}

#[test, expected_failure(abort_code = priority_queue_helpers::EQueueEmpty)]
fun test_extract_max_empty_queue() {
    let mut scenario = test::begin(ADMIN);

    test::next_tx(&mut scenario, ADMIN);
    {
        let uid = object::new(ctx(&mut scenario));
        let dao_id = uid.to_inner();
        uid.delete();
        let mut queue = priority_queue::new<STABLE>(dao_id, 50, 30, 300000, ctx(&mut scenario));

        // Should fail on empty queue
        let extracted = priority_queue_helpers::extract_max(&mut queue);
        // This line should never be reached due to the abort above
        priority_queue::destroy_proposal(extracted);
        transfer::public_share_object(queue);
    };

    test::end(scenario);
}

#[test]
fun test_proposal_getters() {
    let mut scenario = test::begin(ADMIN);

    test::next_tx(&mut scenario, ADMIN);
    {
        let clock = clock::create_for_testing(ctx(&mut scenario));

        let data = priority_queue_helpers::new_proposal_data(
            b"Test Proposal".to_string(),
            b"Test metadata".to_string(),
            vector[b"Option A".to_string(), b"Option B".to_string()],
            vector[b"Details A".to_string(), b"Details B".to_string()],
            vector[],
            vector[],
        );

        // Create DAO ID and queue
        let uid = object::new(ctx(&mut scenario));
        let dao_id = uid.to_inner();
        uid.delete();
        let mut queue = priority_queue::new<STABLE>(dao_id, 50, 30, 300000, ctx(&mut scenario));

        // Create proposal with bond
        let bond = coin::mint_for_testing<STABLE>(1000, ctx(&mut scenario));
        let mut proposal = priority_queue::new_queued_proposal(
            dao_id,
            500_000,
            true,
            USER1,
            data,
            option::some(bond),
            option::some(b"test_intent_key".to_string()),
            &clock,
        );

        // Insert the proposal to get an ID assigned
        priority_queue::insert(&mut queue, proposal, &clock, ctx(&mut scenario));
        let mut proposal = option::destroy_some(priority_queue::extract_max(&mut queue));
        let proposal_id = priority_queue_helpers::get_proposal_id(&proposal);

        // Test all getters
        assert!(priority_queue_helpers::get_proposal_id(&proposal) == proposal_id, 0);
        assert!(priority_queue_helpers::get_proposer(&proposal) == USER1, 1);
        assert!(priority_queue_helpers::get_fee(&proposal) == 500_000, 2);
        assert!(priority_queue_helpers::uses_dao_liquidity(&proposal), 3);
        assert!(priority_queue_helpers::get_timestamp(&proposal) == 0, 4); // Clock at 0

        // Test data getters
        let prop_data = priority_queue_helpers::get_data(&proposal);
        assert!(priority_queue_helpers::get_title(prop_data) == &b"Test Proposal".to_string(), 5);
        assert!(
            priority_queue_helpers::get_metadata(prop_data) == &b"Test metadata".to_string(),
            6,
        );

        // Test bond extraction
        let extracted_bond = priority_queue_helpers::get_bond(&mut proposal);
        assert!(option::is_some(&extracted_bond), 7);
        let bond_coin = option::destroy_some(extracted_bond);
        assert!(coin::value(&bond_coin) == 1000, 8);
        transfer::public_transfer(bond_coin, ADMIN);

        // Clean up
        priority_queue::destroy_proposal(proposal);
        transfer::public_share_object(queue);
        clock::destroy_for_testing(clock);
    };

    test::end(scenario);
}

#[test]
fun test_proposal_data_getters() {
    let data = priority_queue_helpers::new_proposal_data(
        b"Title".to_string(),
        b"Metadata".to_string(),
        vector[b"YES".to_string(), b"NO".to_string(), b"ABSTAIN".to_string()],
        vector[b"Approve".to_string(), b"Reject".to_string(), b"No action".to_string()],
        vector[100, 200, 300],
        vector[400, 500, 600],
    );

    // Test title
    assert!(priority_queue_helpers::get_title(&data) == &b"Title".to_string(), 0);

    // Test metadata
    assert!(priority_queue_helpers::get_metadata(&data) == &b"Metadata".to_string(), 1);

    // Test outcome messages
    let messages = priority_queue_helpers::get_outcome_messages(&data);
    assert!(messages.length() == 3, 2);
    assert!(messages[0] == b"YES".to_string(), 3);
    assert!(messages[1] == b"NO".to_string(), 4);
    assert!(messages[2] == b"ABSTAIN".to_string(), 5);

    // Test outcome details
    let details = priority_queue_helpers::get_outcome_details(&data);
    assert!(details.length() == 3, 6);
    assert!(details[0] == b"Approve".to_string(), 7);
    assert!(details[1] == b"Reject".to_string(), 8);
    assert!(details[2] == b"No action".to_string(), 9);

    // Test amounts (should return empty in new version)
    let asset_amounts = priority_queue_helpers::get_initial_asset_amounts(&data);
    assert!(asset_amounts.is_empty(), 10);

    let stable_amounts = priority_queue_helpers::get_initial_stable_amounts(&data);
    assert!(stable_amounts.is_empty(), 11);
}
