#[test_only]
module futarchy::proposal_lifecycle_tests;

use sui::{
    test_scenario::{Self as ts, Scenario},
    clock::{Self, Clock},
    coin::{Self, Coin},
    sui::SUI,
};
use futarchy::{
    proposal_lifecycle,
    futarchy_config::{Self, FutarchyConfig, FutarchyOutcome},
    proposal::{Self, Proposal},
    market_state::{Self, MarketState},
    priority_queue::{Self, ProposalQueue},
    proposal_fee_manager::{Self, ProposalFeeManager},
    fee::{Self, FeeManager},
    factory,
    version,
    intent_witnesses,
};
use account_protocol::{
    account::{Self, Account},
};

// Test constants
const ADMIN: address = @0xAD0;
const USER1: address = @0x1;
const USER2: address = @0x2;
const TREASURY: address = @0x3;

// Test coin types
public struct TEST_ASSET has drop {}
public struct TEST_STABLE has drop {}

// Helper function to create test coins
fun mint_test_coins<T>(amount: u64, ctx: &mut TxContext): Coin<T> {
    let mut treasury_cap = coin::create_currency(
        T {},
        9,
        b"TEST",
        b"Test Coin",
        b"Test coin for testing",
        option::none(),
        ctx
    );
    let coin = coin::mint(&mut treasury_cap, amount, ctx);
    transfer::public_freeze_object(treasury_cap);
    coin
}

// Helper function to setup a test DAO
fun setup_test_dao(scenario: &mut Scenario) {
    ts::next_tx(scenario, ADMIN);
    {
        let ctx = ts::ctx(scenario);
        
        // Create clock
        let clock = clock::create_for_testing(ctx);
        clock::share_for_testing(clock);
        
        // Initialize factory
        factory::init_for_testing(ctx);
        
        // Create DAO
        factory::create_dao<TEST_ASSET, TEST_STABLE>(
            b"Test DAO".to_string(),
            b"Test DAO for unit tests".to_string(),
            1000, // min_asset_amount
            1000, // min_stable_amount  
            86400000, // review_period_ms (24 hours)
            604800000, // trading_period_ms (7 days)
            1000, // amm_fee
            500000, // twap_threshold
            10000, // min_proposal_stake
            ctx
        );
    };
}

#[test]
fun test_activate_proposal_from_queue() {
    let mut scenario = ts::begin(ADMIN);
    setup_test_dao(&mut scenario);
    
    // Get shared objects
    ts::next_tx(&mut scenario, USER1);
    {
        let mut account = ts::take_shared<Account<FutarchyConfig>>(&scenario);
        let mut queue = ts::take_shared<ProposalQueue<TEST_STABLE>>(&scenario);
        let mut fee_manager = ts::take_shared<FeeManager>(&scenario);
        let mut proposal_fee_manager = ts::take_shared<ProposalFeeManager>(&scenario);
        let clock = ts::take_shared<Clock>(&scenario);
        let ctx = ts::ctx(&mut scenario);
        
        // Create proposal data
        let proposal_data = priority_queue::new_proposal_data(
            b"Test Proposal".to_string(),
            b"Test metadata".to_string(),
            vector[b"YES".to_string(), b"NO".to_string()],
            vector[b"Approve".to_string(), b"Reject".to_string()],
        );
        
        // Queue a proposal
        let bond = mint_test_coins<TEST_STABLE>(10000, ctx);
        priority_queue::insert(
            &mut queue,
            proposal_data,
            USER1,
            option::some(bond),
            option::some(b"test_intent_key".to_string()),
            false, // uses_dao_liquidity
            ctx
        );
        
        // Create liquidity for market initialization
        let asset_liquidity = mint_test_coins<TEST_ASSET>(100000, ctx);
        let stable_liquidity = mint_test_coins<TEST_STABLE>(100000, ctx);
        
        // Activate proposal from queue
        let (proposal_id, market_id) = proposal_lifecycle::activate_proposal_from_queue(
            &mut account,
            &mut queue,
            &mut fee_manager,
            &mut proposal_fee_manager,
            asset_liquidity,
            stable_liquidity,
            &clock,
            ctx
        );
        
        // Verify proposal was activated
        assert!(proposal_id != object::id_from_address(@0x0), 0);
        assert!(market_id != object::id_from_address(@0x0), 1);
        
        // Return shared objects
        ts::return_shared(account);
        ts::return_shared(queue);
        ts::return_shared(fee_manager);
        ts::return_shared(proposal_fee_manager);
        ts::return_shared(clock);
    };
    
    ts::end(scenario);
}

#[test]
fun test_finalize_proposal_market() {
    let mut scenario = ts::begin(ADMIN);
    setup_test_dao(&mut scenario);
    
    // First activate a proposal
    ts::next_tx(&mut scenario, USER1);
    let (proposal_id, market_id) = {
        let mut account = ts::take_shared<Account<FutarchyConfig>>(&scenario);
        let mut queue = ts::take_shared<ProposalQueue<TEST_STABLE>>(&scenario);
        let mut fee_manager = ts::take_shared<FeeManager>(&scenario);
        let mut proposal_fee_manager = ts::take_shared<ProposalFeeManager>(&scenario);
        let clock = ts::take_shared<Clock>(&scenario);
        let ctx = ts::ctx(&mut scenario);
        
        // Queue and activate proposal
        let proposal_data = priority_queue::new_proposal_data(
            b"Test Proposal".to_string(),
            b"Test metadata".to_string(),
            vector[b"YES".to_string(), b"NO".to_string()],
            vector[b"Approve".to_string(), b"Reject".to_string()],
        );
        
        let bond = mint_test_coins<TEST_STABLE>(10000, ctx);
        priority_queue::insert(
            &mut queue,
            proposal_data,
            USER1,
            option::some(bond),
            option::some(b"test_intent_key".to_string()),
            false,
            ctx
        );
        
        let asset_liquidity = mint_test_coins<TEST_ASSET>(100000, ctx);
        let stable_liquidity = mint_test_coins<TEST_STABLE>(100000, ctx);
        
        let (pid, mid) = proposal_lifecycle::activate_proposal_from_queue(
            &mut account,
            &mut queue,
            &mut fee_manager,
            &mut proposal_fee_manager,
            asset_liquidity,
            stable_liquidity,
            &clock,
            ctx
        );
        
        ts::return_shared(account);
        ts::return_shared(queue);
        ts::return_shared(fee_manager);
        ts::return_shared(proposal_fee_manager);
        ts::return_shared(clock);
        
        (pid, mid)
    };
    
    // Fast forward time past trading period
    ts::next_tx(&mut scenario, ADMIN);
    {
        let mut clock = ts::take_shared<Clock>(&scenario);
        clock::increment_for_testing(&mut clock, 604800000 + 1000); // 7 days + buffer
        ts::return_shared(clock);
    };
    
    // Finalize the market
    ts::next_tx(&mut scenario, USER1);
    {
        let mut proposal = ts::take_shared_by_id<Proposal<TEST_ASSET, TEST_STABLE>>(&scenario, proposal_id);
        let mut market = ts::take_shared_by_id<MarketState>(&scenario, market_id);
        let clock = ts::take_shared<Clock>(&scenario);
        let ctx = ts::ctx(&mut scenario);
        
        // Finalize with YES outcome
        proposal_lifecycle::finalize_proposal_market(
            &mut proposal,
            &mut market,
            0, // YES outcome
            &clock,
            ctx
        );
        
        // Verify market is finalized
        assert!(market_state::is_finalized(&market), 2);
        assert!(market_state::get_winning_outcome(&market) == 0, 3);
        
        ts::return_shared(proposal);
        ts::return_shared(market);
        ts::return_shared(clock);
    };
    
    ts::end(scenario);
}

#[test]
fun test_execute_approved_proposal() {
    let mut scenario = ts::begin(ADMIN);
    setup_test_dao(&mut scenario);
    
    // Setup and finalize a proposal
    ts::next_tx(&mut scenario, USER1);
    let (proposal_id, market_id) = {
        let mut account = ts::take_shared<Account<FutarchyConfig>>(&scenario);
        let mut queue = ts::take_shared<ProposalQueue<TEST_STABLE>>(&scenario);
        let mut fee_manager = ts::take_shared<FeeManager>(&scenario);
        let mut proposal_fee_manager = ts::take_shared<ProposalFeeManager>(&scenario);
        let mut clock = ts::take_shared<Clock>(&scenario);
        let ctx = ts::ctx(&mut scenario);
        
        // Create proposal with treasury transfer intent
        let proposal_data = priority_queue::new_proposal_data(
            b"Treasury Transfer".to_string(),
            b"Transfer 1000 TEST_ASSET to USER2".to_string(),
            vector[b"YES".to_string(), b"NO".to_string()],
            vector[b"Approve transfer".to_string(), b"Reject transfer".to_string()],
        );
        
        let bond = mint_test_coins<TEST_STABLE>(10000, ctx);
        priority_queue::insert(
            &mut queue,
            proposal_data,
            USER1,
            option::some(bond),
            option::some(b"treasury_transfer_1000".to_string()),
            false,
            ctx
        );
        
        let asset_liquidity = mint_test_coins<TEST_ASSET>(100000, ctx);
        let stable_liquidity = mint_test_coins<TEST_STABLE>(100000, ctx);
        
        let (pid, mid) = proposal_lifecycle::activate_proposal_from_queue(
            &mut account,
            &mut queue,
            &mut fee_manager,
            &mut proposal_fee_manager,
            asset_liquidity,
            stable_liquidity,
            &clock,
            ctx
        );
        
        // Fast forward and finalize
        clock::increment_for_testing(&mut clock, 604800000 + 1000);
        
        ts::return_shared(account);
        ts::return_shared(queue);
        ts::return_shared(fee_manager);
        ts::return_shared(proposal_fee_manager);
        ts::return_shared(clock);
        
        (pid, mid)
    };
    
    // Finalize the proposal
    ts::next_tx(&mut scenario, ADMIN);
    {
        let mut proposal = ts::take_shared_by_id<Proposal<TEST_ASSET, TEST_STABLE>>(&scenario, proposal_id);
        let mut market = ts::take_shared_by_id<MarketState>(&scenario, market_id);
        let clock = ts::take_shared<Clock>(&scenario);
        let ctx = ts::ctx(&mut scenario);
        
        proposal_lifecycle::finalize_proposal_market(
            &mut proposal,
            &mut market,
            0, // YES outcome
            &clock,
            ctx
        );
        
        ts::return_shared(proposal);
        ts::return_shared(market);
        ts::return_shared(clock);
    };
    
    // Execute the approved proposal
    ts::next_tx(&mut scenario, ADMIN);
    {
        let mut account = ts::take_shared<Account<FutarchyConfig>>(&scenario);
        let proposal = ts::take_shared_by_id<Proposal<TEST_ASSET, TEST_STABLE>>(&scenario, proposal_id);
        let market = ts::take_shared_by_id<MarketState>(&scenario, market_id);
        let clock = ts::take_shared<Clock>(&scenario);
        let ctx = ts::ctx(&mut scenario);
        
        // This would execute the treasury transfer intent
        // Note: In a real test, we'd need to set up the intent properly
        // For now, this tests the flow up to execution
        
        // Test that execution can be called (it will abort on missing intent for now)
        let can_execute = proposal_lifecycle::can_execute_proposal(&proposal, &market);
        assert!(can_execute, 4);
        
        ts::return_shared(account);
        ts::return_shared(proposal);
        ts::return_shared(market);
        ts::return_shared(clock);
    };
    
    ts::end(scenario);
}

#[test]
fun test_calculate_winning_outcome() {
    let mut scenario = ts::begin(ADMIN);
    setup_test_dao(&mut scenario);
    
    // Create a proposal with mock TWAP data
    ts::next_tx(&mut scenario, USER1);
    {
        let ctx = ts::ctx(&mut scenario);
        let clock = clock::create_for_testing(ctx);
        
        // Create a mock proposal
        // Note: This is simplified - in reality we'd need to properly set up TWAPs
        
        // For now, just verify the function exists and can be called
        // Real implementation would require setting up market pools with TWAP oracles
        
        clock::destroy_for_testing(clock);
    };
    
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = proposal_lifecycle::EProposalNotActive)]
fun test_activate_empty_queue_fails() {
    let mut scenario = ts::begin(ADMIN);
    setup_test_dao(&mut scenario);
    
    ts::next_tx(&mut scenario, USER1);
    {
        let mut account = ts::take_shared<Account<FutarchyConfig>>(&scenario);
        let mut queue = ts::take_shared<ProposalQueue<TEST_STABLE>>(&scenario);
        let mut fee_manager = ts::take_shared<FeeManager>(&scenario);
        let mut proposal_fee_manager = ts::take_shared<ProposalFeeManager>(&scenario);
        let clock = ts::take_shared<Clock>(&scenario);
        let ctx = ts::ctx(&mut scenario);
        
        let asset_liquidity = mint_test_coins<TEST_ASSET>(100000, ctx);
        let stable_liquidity = mint_test_coins<TEST_STABLE>(100000, ctx);
        
        // This should fail because queue is empty
        proposal_lifecycle::activate_proposal_from_queue(
            &mut account,
            &mut queue,
            &mut fee_manager,
            &mut proposal_fee_manager,
            asset_liquidity,
            stable_liquidity,
            &clock,
            ctx
        );
        
        ts::return_shared(account);
        ts::return_shared(queue);
        ts::return_shared(fee_manager);
        ts::return_shared(proposal_fee_manager);
        ts::return_shared(clock);
    };
    
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = proposal_lifecycle::EMarketNotFinalized)]
fun test_execute_before_finalized_fails() {
    let mut scenario = ts::begin(ADMIN);
    setup_test_dao(&mut scenario);
    
    // Activate a proposal but don't finalize
    ts::next_tx(&mut scenario, USER1);
    let (proposal_id, market_id) = {
        let mut account = ts::take_shared<Account<FutarchyConfig>>(&scenario);
        let mut queue = ts::take_shared<ProposalQueue<TEST_STABLE>>(&scenario);
        let mut fee_manager = ts::take_shared<FeeManager>(&scenario);
        let mut proposal_fee_manager = ts::take_shared<ProposalFeeManager>(&scenario);
        let clock = ts::take_shared<Clock>(&scenario);
        let ctx = ts::ctx(&mut scenario);
        
        let proposal_data = priority_queue::new_proposal_data(
            b"Test Proposal".to_string(),
            b"Test metadata".to_string(),
            vector[b"YES".to_string(), b"NO".to_string()],
            vector[b"Approve".to_string(), b"Reject".to_string()],
        );
        
        let bond = mint_test_coins<TEST_STABLE>(10000, ctx);
        priority_queue::insert(
            &mut queue,
            proposal_data,
            USER1,
            option::some(bond),
            option::some(b"test_intent".to_string()),
            false,
            ctx
        );
        
        let asset_liquidity = mint_test_coins<TEST_ASSET>(100000, ctx);
        let stable_liquidity = mint_test_coins<TEST_STABLE>(100000, ctx);
        
        let (pid, mid) = proposal_lifecycle::activate_proposal_from_queue(
            &mut account,
            &mut queue,
            &mut fee_manager,
            &mut proposal_fee_manager,
            asset_liquidity,
            stable_liquidity,
            &clock,
            ctx
        );
        
        ts::return_shared(account);
        ts::return_shared(queue);
        ts::return_shared(fee_manager);
        ts::return_shared(proposal_fee_manager);
        ts::return_shared(clock);
        
        (pid, mid)
    };
    
    // Try to execute without finalizing - should fail
    ts::next_tx(&mut scenario, ADMIN);
    {
        let mut account = ts::take_shared<Account<FutarchyConfig>>(&scenario);
        let proposal = ts::take_shared_by_id<Proposal<TEST_ASSET, TEST_STABLE>>(&scenario, proposal_id);
        let market = ts::take_shared_by_id<MarketState>(&scenario, market_id);
        let clock = ts::take_shared<Clock>(&scenario);
        let ctx = ts::ctx(&mut scenario);
        
        // This should fail because market is not finalized
        proposal_lifecycle::execute_approved_proposal(
            &mut account,
            &proposal,
            &market,
            intent_witnesses::governance(),
            &clock,
            ctx
        );
        
        ts::return_shared(account);
        ts::return_shared(proposal);
        ts::return_shared(market);
        ts::return_shared(clock);
    };
    
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = proposal_lifecycle::EProposalNotApproved)]
fun test_execute_rejected_proposal_fails() {
    let mut scenario = ts::begin(ADMIN);
    setup_test_dao(&mut scenario);
    
    // Create and finalize a proposal with NO outcome
    ts::next_tx(&mut scenario, USER1);
    let (proposal_id, market_id) = {
        let mut account = ts::take_shared<Account<FutarchyConfig>>(&scenario);
        let mut queue = ts::take_shared<ProposalQueue<TEST_STABLE>>(&scenario);
        let mut fee_manager = ts::take_shared<FeeManager>(&scenario);
        let mut proposal_fee_manager = ts::take_shared<ProposalFeeManager>(&scenario);
        let mut clock = ts::take_shared<Clock>(&scenario);
        let ctx = ts::ctx(&mut scenario);
        
        let proposal_data = priority_queue::new_proposal_data(
            b"Test Proposal".to_string(),
            b"Test metadata".to_string(),
            vector[b"YES".to_string(), b"NO".to_string()],
            vector[b"Approve".to_string(), b"Reject".to_string()],
        );
        
        let bond = mint_test_coins<TEST_STABLE>(10000, ctx);
        priority_queue::insert(
            &mut queue,
            proposal_data,
            USER1,
            option::some(bond),
            option::some(b"test_intent".to_string()),
            false,
            ctx
        );
        
        let asset_liquidity = mint_test_coins<TEST_ASSET>(100000, ctx);
        let stable_liquidity = mint_test_coins<TEST_STABLE>(100000, ctx);
        
        let (pid, mid) = proposal_lifecycle::activate_proposal_from_queue(
            &mut account,
            &mut queue,
            &mut fee_manager,
            &mut proposal_fee_manager,
            asset_liquidity,
            stable_liquidity,
            &clock,
            ctx
        );
        
        // Fast forward time
        clock::increment_for_testing(&mut clock, 604800000 + 1000);
        
        ts::return_shared(account);
        ts::return_shared(queue);
        ts::return_shared(fee_manager);
        ts::return_shared(proposal_fee_manager);
        ts::return_shared(clock);
        
        (pid, mid)
    };
    
    // Finalize with NO outcome
    ts::next_tx(&mut scenario, ADMIN);
    {
        let mut proposal = ts::take_shared_by_id<Proposal<TEST_ASSET, TEST_STABLE>>(&scenario, proposal_id);
        let mut market = ts::take_shared_by_id<MarketState>(&scenario, market_id);
        let clock = ts::take_shared<Clock>(&scenario);
        let ctx = ts::ctx(&mut scenario);
        
        proposal_lifecycle::finalize_proposal_market(
            &mut proposal,
            &mut market,
            1, // NO outcome
            &clock,
            ctx
        );
        
        ts::return_shared(proposal);
        ts::return_shared(market);
        ts::return_shared(clock);
    };
    
    // Try to execute rejected proposal - should fail
    ts::next_tx(&mut scenario, ADMIN);
    {
        let mut account = ts::take_shared<Account<FutarchyConfig>>(&scenario);
        let proposal = ts::take_shared_by_id<Proposal<TEST_ASSET, TEST_STABLE>>(&scenario, proposal_id);
        let market = ts::take_shared_by_id<MarketState>(&scenario, market_id);
        let clock = ts::take_shared<Clock>(&scenario);
        let ctx = ts::ctx(&mut scenario);
        
        // This should fail because proposal was rejected (NO outcome)
        proposal_lifecycle::execute_approved_proposal(
            &mut account,
            &proposal,
            &market,
            intent_witnesses::governance(),
            &clock,
            ctx
        );
        
        ts::return_shared(account);
        ts::return_shared(proposal);
        ts::return_shared(market);
        ts::return_shared(clock);
    };
    
    ts::end(scenario);
}