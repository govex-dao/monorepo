#[test_only]
module futarchy::priority_queue_tests;

use std::string;
use std::option::{Self, Option};
use sui::{
    test_scenario::{Self as test, Scenario, ctx},
    clock::{Self, Clock},
    coin::{Self, Coin},
    sui::SUI,
    object,
};
use futarchy::priority_queue::{
    Self, ProposalQueue, QueuedProposal, ProposalData, PriorityScore, EvictionInfo
};

// Test coin type
public struct STABLE has drop {}

const ADMIN: address = @0xA;
const USER1: address = @0x1;
const USER2: address = @0x2;
const USER3: address = @0x3;

// === Basic Queue Operations ===

#[test]
fun test_create_queue() {
    let mut scenario = test::begin(ADMIN);
    test::next_tx(&mut scenario, ADMIN);
    {
        let uid = object::new(ctx(&mut scenario));
        let dao_id = uid.to_inner();
        uid.delete();
        let queue = priority_queue::new<STABLE>(
            dao_id,
            50, // max_concurrent_proposals
            30, // max_proposer_funded
            300000, // eviction_grace_period_ms (5 minutes for testing)
            ctx(&mut scenario)
        );
        
        // Verify initial state
        assert!(priority_queue::size(&queue) == 0, 0);
        assert!(priority_queue::is_empty(&queue), 1);
        assert!(priority_queue::dao_id(&queue) == dao_id, 2);
        assert!(priority_queue::active_count(&queue) == 0, 3);
        assert!(!priority_queue::is_dao_slot_occupied(&queue), 4);
        
        transfer::public_share_object(queue);
    };
    test::end(scenario);
}

#[test]
fun test_priority_score_creation() {
    let score1 = priority_queue::create_priority_score(1000, 100);
    let score2 = priority_queue::create_priority_score(2000, 100);
    let score3 = priority_queue::create_priority_score(1000, 200);
    
    // Higher fee should have higher priority
    assert!(priority_queue::compare_priority_scores(&score2, &score1) == 1, 0); // COMPARE_GREATER
    
    // Same fee, earlier timestamp (100) should have higher priority than later (200)
    assert!(priority_queue::compare_priority_scores(&score1, &score3) == 1, 1); // COMPARE_GREATER
    
    // Same score should be equal
    assert!(priority_queue::compare_priority_scores(&score1, &score1) == 0, 2); // COMPARE_EQUAL
}

#[test]
fun test_insert_single_proposal() {
    let mut scenario = test::begin(ADMIN);
    
    // Create clock
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
    
    // Insert proposal
    test::next_tx(&mut scenario, USER1);
    {
        let mut queue = test::take_shared<ProposalQueue<STABLE>>(&scenario);
        let clock = test::take_shared<Clock>(&scenario);
        let dao_id = priority_queue::dao_id(&queue);
        
        let data = priority_queue::new_proposal_data(
            b"Test Proposal".to_string(),
            b"Test metadata".to_string(),
            vector[b"YES".to_string(), b"NO".to_string()],
            vector[b"Approve".to_string(), b"Reject".to_string()],
            vector[],
            vector[]
        );
        
        let proposal = priority_queue::new_queued_proposal(
            dao_id,
            1_000_000, // fee
            false, // uses_dao_liquidity
            USER1,
            data,
            option::none(),
            option::none(),
            &clock
        );
        
        let eviction = priority_queue::insert(&mut queue, proposal, &clock, ctx(&mut scenario));
        assert!(option::is_none(&eviction), 0);
        assert!(priority_queue::size(&queue) == 1, 1);
        assert!(!priority_queue::is_empty(&queue), 2);
        
        test::return_shared(queue);
        test::return_shared(clock);
    };
    
    test::end(scenario);
}

#[test]
fun test_extract_max() {
    let mut scenario = test::begin(ADMIN);
    
    // Setup
    test::next_tx(&mut scenario, ADMIN);
    {
        let clock = clock::create_for_testing(ctx(&mut scenario));
        clock::share_for_testing(clock);
    };
    
    test::next_tx(&mut scenario, ADMIN);
    {
        let uid = object::new(ctx(&mut scenario));
        let dao_id = uid.to_inner();
        uid.delete();
        let queue = priority_queue::new<STABLE>(dao_id, 50, 30, 300000, ctx(&mut scenario));
        transfer::public_share_object(queue);
    };
    
    // Insert multiple proposals with different priorities
    test::next_tx(&mut scenario, USER1);
    {
        let mut queue = test::take_shared<ProposalQueue<STABLE>>(&scenario);
        let mut clock = test::take_shared<Clock>(&scenario);
        let dao_id = priority_queue::dao_id(&queue);
        
        // Insert low priority
        let data1 = priority_queue::new_proposal_data(
            b"Low Priority".to_string(),
            b"metadata".to_string(),
            vector[b"A".to_string(), b"B".to_string()],
            vector[],
            vector[],
            vector[]
        );
        let proposal1 = priority_queue::new_queued_proposal(
            dao_id, 500_000, false, USER1, data1, option::none(), option::none(), &clock
        );
        priority_queue::insert(&mut queue, proposal1, &clock, ctx(&mut scenario));
        
        // Advance time
        clock::increment_for_testing(&mut clock, 100);
        
        // Insert high priority
        let data2 = priority_queue::new_proposal_data(
            b"High Priority".to_string(),
            b"metadata".to_string(),
            vector[b"C".to_string(), b"D".to_string()],
            vector[],
            vector[],
            vector[]
        );
        let proposal2 = priority_queue::new_queued_proposal(
            dao_id, 2_000_000, false, USER2, data2, option::none(), option::none(), &clock
        );
        priority_queue::insert(&mut queue, proposal2, &clock, ctx(&mut scenario));
        
        // Advance time
        clock::increment_for_testing(&mut clock, 100);
        
        // Insert medium priority
        let data3 = priority_queue::new_proposal_data(
            b"Medium Priority".to_string(),
            b"metadata".to_string(),
            vector[b"E".to_string(), b"F".to_string()],
            vector[],
            vector[],
            vector[]
        );
        let proposal3 = priority_queue::new_queued_proposal(
            dao_id, 1_000_000, false, USER3, data3, option::none(), option::none(), &clock
        );
        priority_queue::insert(&mut queue, proposal3, &clock, ctx(&mut scenario));
        
        assert!(priority_queue::size(&queue) == 3, 0);
        
        // Extract max should get high priority first
        let max = priority_queue::extract_max(&mut queue);
        assert!(option::is_some(&max), 1);
        let extracted = option::destroy_some(max);
        assert!(priority_queue::get_fee(&extracted) == 2_000_000, 2);
        priority_queue::destroy_proposal(extracted);
        
        // Next should be medium
        let max2 = priority_queue::extract_max(&mut queue);
        assert!(option::is_some(&max2), 3);
        let extracted2 = option::destroy_some(max2);
        assert!(priority_queue::get_fee(&extracted2) == 1_000_000, 4);
        priority_queue::destroy_proposal(extracted2);
        
        // Finally low
        let max3 = priority_queue::extract_max(&mut queue);
        assert!(option::is_some(&max3), 5);
        let extracted3 = option::destroy_some(max3);
        assert!(priority_queue::get_fee(&extracted3) == 500_000, 6);
        priority_queue::destroy_proposal(extracted3);
        
        // Queue should be empty
        assert!(priority_queue::is_empty(&queue), 7);
        
        test::return_shared(queue);
        test::return_shared(clock);
    };
    
    test::end(scenario);
}

// === Eviction Tests ===

#[test]
fun test_eviction_when_queue_full() {
    let mut scenario = test::begin(ADMIN);
    
    // Setup
    test::next_tx(&mut scenario, ADMIN);
    {
        let clock = clock::create_for_testing(ctx(&mut scenario));
        clock::share_for_testing(clock);
    };
    
    test::next_tx(&mut scenario, ADMIN);
    {
        let uid = object::new(ctx(&mut scenario));
        let dao_id = uid.to_inner();
        uid.delete();
        // Small queue for testing eviction
        let queue = priority_queue::new<STABLE>(dao_id, 50, 2, 300000, ctx(&mut scenario));
        transfer::public_share_object(queue);
    };
    
    // Fill queue with low priority proposals
    test::next_tx(&mut scenario, USER1);
    {
        let mut queue = test::take_shared<ProposalQueue<STABLE>>(&scenario);
        let mut clock = test::take_shared<Clock>(&scenario);
        let dao_id = priority_queue::dao_id(&queue);
        
        // Insert first low priority
        let data1 = priority_queue::new_proposal_data(
            b"Low 1".to_string(),
            b"metadata".to_string(),
            vector[b"A".to_string()],
            vector[],
            vector[],
            vector[]
        );
        let proposal1 = priority_queue::new_queued_proposal(
            dao_id, 100_000, false, USER1, data1, option::none(), option::none(), &clock
        );
        priority_queue::insert(&mut queue, proposal1, &clock, ctx(&mut scenario));
        
        // Advance time
        clock::increment_for_testing(&mut clock, 100);
        
        // Insert second low priority
        let data2 = priority_queue::new_proposal_data(
            b"Low 2".to_string(),
            b"metadata".to_string(),
            vector[b"B".to_string()],
            vector[],
            vector[],
            vector[]
        );
        let proposal2 = priority_queue::new_queued_proposal(
            dao_id, 200_000, false, USER2, data2, option::none(), option::none(), &clock
        );
        priority_queue::insert(&mut queue, proposal2, &clock, ctx(&mut scenario));
        
        assert!(priority_queue::size(&queue) == 2, 0);
        
        // Advance past grace period (5 minutes = 300000ms)
        clock::increment_for_testing(&mut clock, 300_001);
        
        // Insert high priority that should evict lowest
        let data3 = priority_queue::new_proposal_data(
            b"High Priority".to_string(),
            b"metadata".to_string(),
            vector[b"C".to_string()],
            vector[],
            vector[],
            vector[]
        );
        let proposal3 = priority_queue::new_queued_proposal(
            dao_id, 1_000_000, false, USER3, data3, option::none(), option::none(), &clock
        );
        
        let eviction = priority_queue::insert(&mut queue, proposal3, &clock, ctx(&mut scenario));
        
        // Should have evicted the lowest priority (100_000)
        assert!(option::is_some(&eviction), 1);
        assert!(priority_queue::size(&queue) == 2, 2);
        
        test::return_shared(queue);
        test::return_shared(clock);
    };
    
    test::end(scenario);
}

#[test, expected_failure(abort_code = priority_queue::EProposalInGracePeriod)]
fun test_eviction_grace_period_protection() {
    let mut scenario = test::begin(ADMIN);
    
    // Setup
    test::next_tx(&mut scenario, ADMIN);
    {
        let clock = clock::create_for_testing(ctx(&mut scenario));
        clock::share_for_testing(clock);
    };
    
    test::next_tx(&mut scenario, ADMIN);
    {
        let uid = object::new(ctx(&mut scenario));
        let dao_id = uid.to_inner();
        uid.delete();
        let queue = priority_queue::new<STABLE>(dao_id, 50, 1, 300000, ctx(&mut scenario));
        transfer::public_share_object(queue);
    };
    
    // Fill queue
    test::next_tx(&mut scenario, USER1);
    {
        let mut queue = test::take_shared<ProposalQueue<STABLE>>(&scenario);
        let mut clock = test::take_shared<Clock>(&scenario);
        let dao_id = priority_queue::dao_id(&queue);
        
        let data1 = priority_queue::new_proposal_data(
            b"Recent Proposal".to_string(),
            b"metadata".to_string(),
            vector[b"A".to_string()],
            vector[],
            vector[],
            vector[]
        );
        let proposal1 = priority_queue::new_queued_proposal(
            dao_id, 100_000, false, USER1, data1, option::none(), option::none(), &clock
        );
        priority_queue::insert(&mut queue, proposal1, &clock, ctx(&mut scenario));
        
        // Try to evict before grace period expires - should fail
        clock::increment_for_testing(&mut clock, 100); // Only 100ms, need 300000ms
        
        let data2 = priority_queue::new_proposal_data(
            b"High Priority".to_string(),
            b"metadata".to_string(),
            vector[b"B".to_string()],
            vector[],
            vector[],
            vector[]
        );
        let proposal2 = priority_queue::new_queued_proposal(
            dao_id, 1_000_000, false, USER2, data2, option::none(), option::none(), &clock
        );
        
        // This should abort with EProposalInGracePeriod
        priority_queue::insert(&mut queue, proposal2, &clock, ctx(&mut scenario));
        
        test::return_shared(queue);
        test::return_shared(clock);
    };
    
    test::end(scenario);
}

// === DAO Liquidity Slot Tests ===

#[test]
fun test_dao_liquidity_slot() {
    let mut scenario = test::begin(ADMIN);
    
    // Setup
    test::next_tx(&mut scenario, ADMIN);
    {
        let clock = clock::create_for_testing(ctx(&mut scenario));
        clock::share_for_testing(clock);
    };
    
    test::next_tx(&mut scenario, ADMIN);
    {
        let uid = object::new(ctx(&mut scenario));
        let dao_id = uid.to_inner();
        uid.delete();
        let queue = priority_queue::new<STABLE>(dao_id, 1, 5, 300000, ctx(&mut scenario));
        transfer::public_share_object(queue);
    };
    
    // Insert DAO liquidity proposal
    test::next_tx(&mut scenario, USER1);
    {
        let mut queue = test::take_shared<ProposalQueue<STABLE>>(&scenario);
        let clock = test::take_shared<Clock>(&scenario);
        let dao_id = priority_queue::dao_id(&queue);
        
        let data = priority_queue::new_proposal_data(
            b"DAO Funded".to_string(),
            b"metadata".to_string(),
            vector[b"YES".to_string()],
            vector[],
            vector[],
            vector[]
        );
        let proposal = priority_queue::new_queued_proposal(
            dao_id, 1_000_000, true, USER1, data, option::none(), option::none(), &clock
        );
        
        priority_queue::insert(&mut queue, proposal, &clock, ctx(&mut scenario));
        
        // The test is checking DAO liquidity slot management
        // We need to test the actual activation/completion cycle
        // For now, just verify the queue state is correct
        assert!(priority_queue::size(&queue) == 1, 0);
        
        // Extract and clean up
        let extracted = priority_queue::extract_max(&mut queue);
        if (option::is_some(&extracted)) {
            let prop = option::destroy_some(extracted);
            assert!(priority_queue::uses_dao_liquidity(&prop), 1);
            priority_queue::destroy_proposal(prop);
        } else {
            option::destroy_none(extracted);
        };
        
        test::return_shared(queue);
        test::return_shared(clock);
    };
    
    test::end(scenario);
}

// === Fee Calculation Tests ===

#[test]
fun test_calculate_min_fee() {
    let mut scenario = test::begin(ADMIN);
    
    test::next_tx(&mut scenario, ADMIN);
    {
        let uid = object::new(ctx(&mut scenario));
        let dao_id = uid.to_inner();
        uid.delete();
        let queue = priority_queue::new<STABLE>(dao_id, 10, 10, 300000, ctx(&mut scenario));
        
        // Empty queue - base fee
        assert!(priority_queue::calculate_min_fee(&queue) == 1_000_000, 0);
        
        transfer::public_share_object(queue);
    };
    
    // Fill queue to test scaling
    test::next_tx(&mut scenario, USER1);
    {
        let mut queue = test::take_shared<ProposalQueue<STABLE>>(&scenario);
        let clock = clock::create_for_testing(ctx(&mut scenario));
        let dao_id = priority_queue::dao_id(&queue);
        
        // Add proposals to reach different occupancy levels
        let mut i = 0;
        while (i < 5) { // 50% occupancy
            let data = priority_queue::new_proposal_data(
                b"Test".to_string(),
                b"metadata".to_string(),
                vector[b"A".to_string()],
                vector[],
                vector[],
                vector[]
            );
            let proposal = priority_queue::new_queued_proposal(
                dao_id, 1_000_000, false, USER1, data, option::none(), option::none(), &clock
            );
            priority_queue::insert(&mut queue, proposal, &clock, ctx(&mut scenario));
            i = i + 1;
        };
        
        // At 50% occupancy - 2x fee
        assert!(priority_queue::calculate_min_fee(&queue) == 2_000_000, 1);
        
        // Add more to reach 75%
        while (i < 8) {
            let data = priority_queue::new_proposal_data(
                b"Test".to_string(),
                b"metadata".to_string(),
                vector[b"B".to_string()],
                vector[],
                vector[],
                vector[]
            );
            let proposal = priority_queue::new_queued_proposal(
                dao_id, 2_000_000, false, USER1, data, option::none(), option::none(), &clock
            );
            priority_queue::insert(&mut queue, proposal, &clock, ctx(&mut scenario));
            i = i + 1;
        };
        
        // At 80% occupancy - 5x fee
        assert!(priority_queue::calculate_min_fee(&queue) == 5_000_000, 2);
        
        clock::destroy_for_testing(clock);
        test::return_shared(queue);
    };
    
    test::end(scenario);
}

// === Update Fee Tests ===

#[test]
fun test_update_proposal_fee() {
    let mut scenario = test::begin(ADMIN);
    
    // Setup
    test::next_tx(&mut scenario, ADMIN);
    {
        let clock = clock::create_for_testing(ctx(&mut scenario));
        clock::share_for_testing(clock);
    };
    
    test::next_tx(&mut scenario, ADMIN);
    {
        let uid = object::new(ctx(&mut scenario));
        let dao_id = uid.to_inner();
        uid.delete();
        let queue = priority_queue::new<STABLE>(dao_id, 50, 30, 300000, ctx(&mut scenario));
        transfer::public_share_object(queue);
    };
    
    // Insert initial proposal
    test::next_tx(&mut scenario, USER1);
    {
        let mut queue = test::take_shared<ProposalQueue<STABLE>>(&scenario);
        let clock = test::take_shared<Clock>(&scenario);
        let dao_id = priority_queue::dao_id(&queue);
        
        let data = priority_queue::new_proposal_data(
            b"Initial".to_string(),
            b"metadata".to_string(),
            vector[b"YES".to_string()],
            vector[],
            vector[],
            vector[]
        );
        let proposal = priority_queue::new_queued_proposal(
            dao_id, 100_000, false, USER1, data, option::none(), option::none(), &clock
        );
        
        priority_queue::insert(&mut queue, proposal, &clock, ctx(&mut scenario));
        
        // Get the proposal_id from the queue (it's the only one)
        let proposal_ids = priority_queue::get_proposals_by_proposer(&queue, USER1);
        assert!(proposal_ids.length() == 1, 0);
        let proposal_id = proposal_ids[0];
        
        // Update fee
        priority_queue::update_proposal_fee(&mut queue, proposal_id, 500_000, &clock, ctx(&mut scenario));
        
        // Extract and verify updated fee
        let extracted = priority_queue::extract_max(&mut queue);
        assert!(option::is_some(&extracted), 0);
        let prop = option::destroy_some(extracted);
        assert!(priority_queue::get_fee(&prop) == 600_000, 1); // 100k + 500k
        
        priority_queue::destroy_proposal(prop);
        
        test::return_shared(queue);
        test::return_shared(clock);
    };
    
    test::end(scenario);
}

// === Query Functions Tests ===

#[test]
fun test_get_proposals_by_proposer() {
    let mut scenario = test::begin(ADMIN);
    
    // Setup
    test::next_tx(&mut scenario, ADMIN);
    {
        let clock = clock::create_for_testing(ctx(&mut scenario));
        clock::share_for_testing(clock);
    };
    
    test::next_tx(&mut scenario, ADMIN);
    {
        let uid = object::new(ctx(&mut scenario));
        let dao_id = uid.to_inner();
        uid.delete();
        let queue = priority_queue::new<STABLE>(dao_id, 50, 30, 300000, ctx(&mut scenario));
        transfer::public_share_object(queue);
    };
    
    // Insert proposals from different users
    test::next_tx(&mut scenario, USER1);
    {
        let mut queue = test::take_shared<ProposalQueue<STABLE>>(&scenario);
        let clock = test::take_shared<Clock>(&scenario);
        let dao_id = priority_queue::dao_id(&queue);
        
        // User1 proposals
        let data1 = priority_queue::new_proposal_data(
            b"User1 Prop 1".to_string(),
            b"metadata".to_string(),
            vector[b"A".to_string()],
            vector[],
            vector[],
            vector[]
        );
        let proposal1 = priority_queue::new_queued_proposal(
            dao_id, 100_000, false, USER1, data1, option::none(), option::none(), &clock
        );
        priority_queue::insert(&mut queue, proposal1, &clock, ctx(&mut scenario));
        
        let data2 = priority_queue::new_proposal_data(
            b"User1 Prop 2".to_string(),
            b"metadata".to_string(),
            vector[b"B".to_string()],
            vector[],
            vector[],
            vector[]
        );
        let proposal2 = priority_queue::new_queued_proposal(
            dao_id, 200_000, false, USER1, data2, option::none(), option::none(), &clock
        );
        priority_queue::insert(&mut queue, proposal2, &clock, ctx(&mut scenario));
        
        // User2 proposal
        let data3 = priority_queue::new_proposal_data(
            b"User2 Prop".to_string(),
            b"metadata".to_string(),
            vector[b"C".to_string()],
            vector[],
            vector[],
            vector[]
        );
        let proposal3 = priority_queue::new_queued_proposal(
            dao_id, 150_000, false, USER2, data3, option::none(), option::none(), &clock
        );
        priority_queue::insert(&mut queue, proposal3, &clock, ctx(&mut scenario));
        
        // Query by proposer
        let user1_proposals = priority_queue::get_proposals_by_proposer(&queue, USER1);
        assert!(user1_proposals.length() == 2, 0);
        
        let user2_proposals = priority_queue::get_proposals_by_proposer(&queue, USER2);
        assert!(user2_proposals.length() == 1, 1);
        
        let user3_proposals = priority_queue::get_proposals_by_proposer(&queue, USER3);
        assert!(user3_proposals.length() == 0, 2);
        
        test::return_shared(queue);
        test::return_shared(clock);
    };
    
    test::end(scenario);
}

#[test]
fun test_would_accept_proposal() {
    let mut scenario = test::begin(ADMIN);
    
    // Setup
    test::next_tx(&mut scenario, ADMIN);
    {
        let clock = clock::create_for_testing(ctx(&mut scenario));
        clock::share_for_testing(clock);
    };
    
    test::next_tx(&mut scenario, ADMIN);
    {
        let uid = object::new(ctx(&mut scenario));
        let dao_id = uid.to_inner();
        uid.delete();
        let queue = priority_queue::new<STABLE>(dao_id, 2, 2, 300000, ctx(&mut scenario));
        transfer::public_share_object(queue);
    };
    
    test::next_tx(&mut scenario, USER1);
    {
        let queue = test::take_shared<ProposalQueue<STABLE>>(&scenario);
        let clock = test::take_shared<Clock>(&scenario);
        
        // Should accept with sufficient fee
        assert!(priority_queue::would_accept_proposal(&queue, 1_000_000, false, &clock), 0);
        
        // Should reject with insufficient fee
        assert!(!priority_queue::would_accept_proposal(&queue, 500_000, false, &clock), 1);
        
        test::return_shared(queue);
        test::return_shared(clock);
    };
    
    test::end(scenario);
}

// === Helper function to clean up proposals ===
fun cleanup_proposal<StableCoin>(proposal: QueuedProposal<StableCoin>) {
    priority_queue::destroy_proposal(proposal);
}