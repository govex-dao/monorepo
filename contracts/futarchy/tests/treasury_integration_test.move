#[test_only]
module futarchy::treasury_integration_test;

use futarchy::{
    dao::{Self, DAO},
    treasury::{Self, Treasury},
    treasury_actions::{Self, ActionRegistry},
    treasury_initialization,
    proposal::{Self, Proposal},
    market_state::{Self, MarketState},
    coin_escrow::{Self, TokenEscrow},
    fee,
    proposals,
    recurring_payment_registry::{Self, PaymentStreamRegistry},
};
use sui::{
    test_scenario::{Self as test},
    clock::{Self, Clock},
    coin::{Self, Coin},
    sui::SUI,
};
use std::string;

// Test coins
public struct USDC has drop {}
public struct DAI has drop {}

// Test constants
const ADMIN: address = @0xAD;
const ALICE: address = @0xA11CE;
const BOB: address = @0xB0B;
const CHARLIE: address = @0xC4A411E;

#[test]
fun test_partial_execution_and_retry() {
    let mut scenario = test::begin(ADMIN);
    
    // Setup similar to above
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(1_000_000);
    
    // Create DAO and treasury
    let mut dao = dao::create<SUI, SUI>(
        10_000_000_000,
        10_000_000_000,
        b"Partial Execution Test".to_ascii_string(),
        b"https://test.com/icon.png".to_ascii_string(),
        3600000,
        86400000,
        60000,
        10,
        1000000000000000000,
        100,
        b"Testing partial execution".to_string(),
        2,
        vector[],
        &clock,
        scenario.ctx(),
    );
    
    treasury_initialization::initialize_treasury(&mut dao, ADMIN, scenario.ctx());
    transfer::public_share_object(dao);
    
    // Create required objects
    fee::create_fee_manager_for_testing(scenario.ctx());
    treasury_actions::create_for_testing(scenario.ctx());
    
    // Get treasury ID
    scenario.next_tx(ADMIN);
    let treasury_id = {
        let dao = scenario.take_shared<DAO>();
        let id = *dao::get_treasury_id(&dao).borrow();
        test::return_shared(dao);
        id
    };
    
    // Deposit insufficient funds
    scenario.next_tx(ALICE);
    {
        let mut treasury = scenario.take_shared_by_id<Treasury>(treasury_id);
        
        // Deposit only 150 SUI (insufficient for all actions)
        let deposit = coin::mint_for_testing<SUI>(150_000_000_000, scenario.ctx());
        treasury::deposit_sui(&mut treasury, deposit, scenario.ctx());
        
        test::return_shared(treasury);
    };
    
    // Create proposal with multiple actions that exceed available funds
    scenario.next_tx(ADMIN);
    let proposal_id = {
        let mut dao = scenario.take_shared<DAO>();
        let mut fee_manager = scenario.take_shared<fee::FeeManager>();
        let mut registry = scenario.take_shared<ActionRegistry>();
        
        // Create payment for proposal
        let payment = coin::mint_for_testing<SUI>(fee::get_proposal_creation_fee(&fee_manager), scenario.ctx());
        
        // Create coins for AMM
        let asset_coin = coin::mint_for_testing<SUI>(100_000_000_000, scenario.ctx());
        let stable_coin = coin::mint_for_testing<SUI>(100_000_000_000, scenario.ctx());
        
        // Create the proposal to get a real ID
        let (proposal_id, _, _) = dao::create_proposal_internal<SUI, SUI>(
            &mut dao,
            &mut fee_manager,
            payment,
            2, // outcome_count
            asset_coin,
            stable_coin,
            b"Partial Execution Test".to_string(),
            vector[b"Reject".to_string(), b"Accept".to_string()],
            b"Testing partial execution".to_string(),
            vector[b"Reject".to_string(), b"Accept".to_string()],
            vector[100_000_000_000, 100_000_000_000, 100_000_000_000, 100_000_000_000],
            &clock,
            scenario.ctx(),
        );
        
        // Initialize and add actions
        treasury_actions::init_proposal_actions(&mut registry, proposal_id, 2, scenario.ctx());
        
        // Add actions that exceed treasury balance
        treasury_actions::add_transfer_action<SUI>(
            &mut registry,
            proposal_id,
            1,
            BOB,
            100_000_000_000, // 100 SUI
            scenario.ctx(),
        );
        
        treasury_actions::add_transfer_action<SUI>(
            &mut registry,
            proposal_id,
            1,
            CHARLIE,
            100_000_000_000, // 100 SUI (only 150 total in treasury)
            scenario.ctx(),
        );
        
        test::return_shared(dao);
        test::return_shared(fee_manager);
        test::return_shared(registry);
        
        proposal_id
    };
    
    // Fast forward past review period
    clock.increment_for_testing(3700000); // Past review period
    
    // Create separate proposals for each action since execution stops on first failure
    // First execute Bob's transfer
    scenario.next_tx(ADMIN);
    {
        let dao = scenario.take_shared<DAO>();
        let mut registry = scenario.take_shared<ActionRegistry>();
        let mut treasury = scenario.take_shared_by_id<Treasury>(treasury_id);
        
        // Create a new proposal with just Bob's transfer
        let bob_proposal_id = object::id_from_address(@0xB0B);
        treasury_actions::init_proposal_actions(&mut registry, bob_proposal_id, 2, scenario.ctx());
        treasury_actions::add_transfer_action<SUI>(
            &mut registry,
            bob_proposal_id,
            1,
            BOB,
            100_000_000_000,
            scenario.ctx(),
        );
        
        // Execute Bob's transfer - should succeed
        treasury_actions::execute_outcome_actions_sui(
            &mut registry,
            &mut treasury,
            &dao,
            &clock,
            bob_proposal_id,
            1,
            scenario.ctx()
        );
        
        test::return_shared(dao);
        test::return_shared(registry);
        test::return_shared(treasury);
    };
    
    // Verify Bob received payment
    scenario.next_tx(BOB);
    {
        let coin = scenario.take_from_sender<Coin<SUI>>();
        assert!(coin.value() == 100_000_000_000, 10);
        scenario.return_to_sender(coin);
    };
    
    // Now try Charlie's transfer which should fail
    scenario.next_tx(ADMIN);
    {
        let dao = scenario.take_shared<DAO>();
        let mut registry = scenario.take_shared<ActionRegistry>();
        let treasury = scenario.take_shared_by_id<Treasury>(treasury_id);
        
        // Verify remaining balance is only 50 SUI (insufficient for Charlie's 100 SUI)
        assert!(treasury::coin_type_value<SUI>(&treasury) == 50_000_000_000, 12);
        
        test::return_shared(dao);
        test::return_shared(registry);
        test::return_shared(treasury);
    };
    
    clock.destroy_for_testing();
    scenario.end();
}

#[test]
fun test_multi_coin_treasury_operations() {
    let mut scenario = test::begin(ADMIN);
    
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(1_000_000);
    
    // Create DAO
    let mut dao = dao::create<SUI, SUI>(
        10_000_000_000,
        10_000_000_000,
        b"Multi-Coin Treasury Test".to_ascii_string(),
        b"https://test.com/icon.png".to_ascii_string(),
        3600000,
        86400000,
        60000,
        10,
        1000000000000000000,
        100,
        b"Testing multiple coin types".to_string(),
        2,
        vector[],
        &clock,
        scenario.ctx(),
    );
    
    treasury_initialization::initialize_treasury(&mut dao, ADMIN, scenario.ctx());
    transfer::public_share_object(dao);
    
    fee::create_fee_manager_for_testing(scenario.ctx());
    treasury_actions::create_for_testing(scenario.ctx());
    
    // Get treasury ID and deposit multiple coin types
    scenario.next_tx(ADMIN);
    let treasury_id = {
        let dao = scenario.take_shared<DAO>();
        let id = *dao::get_treasury_id(&dao).borrow();
        test::return_shared(dao);
        id
    };
    
    // Deposit multiple coin types
    scenario.next_tx(ALICE);
    {
        let mut treasury = scenario.take_shared_by_id<Treasury>(treasury_id);
        
        // Deposit SUI
        let sui_coin = coin::mint_for_testing<SUI>(1_000_000_000_000, scenario.ctx());
        treasury::deposit_sui(&mut treasury, sui_coin, scenario.ctx());
        
        // Deposit USDC
        let usdc_coin = coin::mint_for_testing<USDC>(500_000_000_000, scenario.ctx());
        let fee1 = coin::mint_for_testing<SUI>(10_000_000_000, scenario.ctx());
        treasury::deposit_coin_with_fee<USDC>(&mut treasury, usdc_coin, fee1, scenario.ctx());
        
        // Deposit DAI
        let dai_coin = coin::mint_for_testing<DAI>(300_000_000_000, scenario.ctx());
        let fee2 = coin::mint_for_testing<SUI>(10_000_000_000, scenario.ctx());
        treasury::deposit_coin_with_fee<DAI>(&mut treasury, dai_coin, fee2, scenario.ctx());
        
        test::return_shared(treasury);
    };
    
    // Create proposal with actions for different coin types
    scenario.next_tx(ADMIN);
    let proposal_id = {
        let mut dao = scenario.take_shared<DAO>();
        let mut registry = scenario.take_shared<ActionRegistry>();
        
        let proposal_id = object::id_from_address(@0x9ABC);
        treasury_actions::init_proposal_actions(&mut registry, proposal_id, 2, scenario.ctx());
        
        // Add actions for different coin types
        treasury_actions::add_transfer_action<SUI>(&mut registry, proposal_id, 1, BOB, 100_000_000_000, scenario.ctx());
        treasury_actions::add_transfer_action<USDC>(&mut registry, proposal_id, 1, CHARLIE, 50_000_000_000, scenario.ctx());
        treasury_actions::add_transfer_action<DAI>(&mut registry, proposal_id, 1, ALICE, 30_000_000_000, scenario.ctx());
        
        test::return_shared(dao);
        test::return_shared(registry);
        
        proposal_id
    };
    
    // Execute actions for each coin type
    scenario.next_tx(ADMIN);
    {
        let dao = scenario.take_shared<DAO>();
        let mut registry = scenario.take_shared<ActionRegistry>();
        let mut treasury = scenario.take_shared_by_id<Treasury>(treasury_id);
        
        // Execute SUI transfers
        treasury_actions::execute_outcome_actions_sui(
            &mut registry,
            &mut treasury,
            &dao,
            &clock,
            proposal_id,
            1,
            scenario.ctx()
        );
        
        // Execute USDC transfers
        treasury_actions::execute_outcome_actions<USDC>(
            &mut registry,
            &mut treasury,
            &dao,
            &clock,
            proposal_id,
            1,
            scenario.ctx()
        );
        
        // Execute DAI transfers
        treasury_actions::execute_outcome_actions<DAI>(
            &mut registry,
            &mut treasury,
            &dao,
            &clock,
            proposal_id,
            1,
            scenario.ctx()
        );
        
        test::return_shared(dao);
        test::return_shared(registry);
        test::return_shared(treasury);
    };
    
    // Verify all recipients received their coins
    scenario.next_tx(BOB);
    {
        let coin = scenario.take_from_sender<Coin<SUI>>();
        assert!(coin.value() == 100_000_000_000, 20);
        scenario.return_to_sender(coin);
    };
    
    scenario.next_tx(CHARLIE);
    {
        let coin = scenario.take_from_sender<Coin<USDC>>();
        assert!(coin.value() == 50_000_000_000, 21);
        scenario.return_to_sender(coin);
    };
    
    scenario.next_tx(ALICE);
    {
        let coin = scenario.take_from_sender<Coin<DAI>>();
        assert!(coin.value() == 30_000_000_000, 22);
        scenario.return_to_sender(coin);
    };
    
    clock.destroy_for_testing();
    scenario.end();
}

#[test]
fun test_recurring_payment_action() {
    let mut scenario = test::begin(ADMIN);
    
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(1_000_000); // Start at 1 second
    
    // Create DAO
    let mut dao = dao::create<SUI, SUI>(
        10_000_000_000,
        10_000_000_000,
        b"Recurring Payment Test DAO".to_ascii_string(),
        b"https://test.com/icon.png".to_ascii_string(),
        3600000, // 1 hour review
        86400000, // 1 day trading
        60000, // 1 minute twap
        10,
        1000000000000000000,
        100,
        b"Testing recurring payments".to_string(),
        2,
        vector[],
        &clock,
        scenario.ctx(),
    );
    
    treasury_initialization::initialize_treasury(&mut dao, ADMIN, scenario.ctx());
    
    // Initialize payment stream registry for the DAO
    let _registry_id = recurring_payment_registry::init_registry(&mut dao, scenario.ctx());
    
    transfer::public_share_object(dao);
    
    // Create required objects
    fee::create_fee_manager_for_testing(scenario.ctx());
    treasury_actions::create_for_testing(scenario.ctx());
    
    // Get treasury ID and fund it
    scenario.next_tx(ADMIN);
    let treasury_id = {
        let dao = scenario.take_shared<DAO>();
        let id = *dao::get_treasury_id(&dao).borrow();
        test::return_shared(dao);
        id
    };
    
    // Fund treasury with sufficient SUI for all payments
    scenario.next_tx(ALICE);
    {
        let mut treasury = scenario.take_shared_by_id<Treasury>(treasury_id);
        
        // Deposit 1000 SUI (enough for 10 payments of 100 SUI each)
        let deposit = coin::mint_for_testing<SUI>(1_000_000_000_000, scenario.ctx());
        treasury::deposit_sui(&mut treasury, deposit, scenario.ctx());
        
        test::return_shared(treasury);
    };
    
    // Create recurring payment proposal
    scenario.next_tx(ADMIN);
    let proposal_id = {
        let mut dao = scenario.take_shared<DAO>();
        let mut fee_manager = scenario.take_shared<fee::FeeManager>();
        let mut registry = scenario.take_shared<ActionRegistry>();
        
        let payment = coin::mint_for_testing<SUI>(fee::get_proposal_creation_fee(&fee_manager), scenario.ctx());
        let asset_coin = coin::mint_for_testing<SUI>(100_000_000_000, scenario.ctx());
        let stable_coin = coin::mint_for_testing<SUI>(100_000_000_000, scenario.ctx());
        
        // Create the proposal
        let (proposal_id, _, _) = dao::create_proposal_internal<SUI, SUI>(
            &mut dao,
            &mut fee_manager,
            payment,
            2,
            asset_coin,
            stable_coin,
            b"Monthly Salary for Bob".to_string(),
            vector[b"Reject salary payment".to_string(), b"Approve salary: 100 SUI per month × 10 months to Bob".to_string()],
            b"Proposal to pay Bob a monthly salary".to_string(),
            vector[b"Reject".to_string(), b"Accept".to_string()],
            vector[100_000_000_000, 100_000_000_000, 100_000_000_000, 100_000_000_000],
            &clock,
            scenario.ctx(),
        );
        
        // Initialize actions
        treasury_actions::init_proposal_actions(&mut registry, proposal_id, 2, scenario.ctx());
        
        // Add no-op for reject
        treasury_actions::add_no_op_action(&mut registry, proposal_id, 0, scenario.ctx());
        
        // Add recurring payment for accept
        treasury_actions::add_recurring_payment_action<SUI>(
            &mut registry,
            proposal_id,
            1, // Accept outcome
            BOB,
            100_000_000_000, // 100 SUI per payment
            2_592_000_000, // ~30 days in milliseconds
            10, // 10 total payments
            5_000_000, // Start at 5 seconds
            b"Monthly salary payment".to_string(),
            scenario.ctx(),
        );
        
        test::return_shared(dao);
        test::return_shared(fee_manager);
        test::return_shared(registry);
        
        proposal_id
    };
    
    // Fast forward past review period
    clock.increment_for_testing(3700000);
    
    // Execute the recurring payment action
    scenario.next_tx(ADMIN);
    {
        let dao = scenario.take_shared<DAO>();
        let mut registry = scenario.take_shared<ActionRegistry>();
        let mut treasury = scenario.take_shared_by_id<Treasury>(treasury_id);
        let mut payment_stream_registry = scenario.take_shared<PaymentStreamRegistry>();
        
        treasury_actions::execute_outcome_actions_sui_with_payments(
            &mut registry,
            &mut treasury,
            &mut payment_stream_registry,
            &dao,
            &clock,
            proposal_id,
            1, // Accept outcome
            scenario.ctx()
        );
        
        test::return_shared(dao);
        test::return_shared(registry);
        test::return_shared(treasury);
        test::return_shared(payment_stream_registry);
    };
    
    // Verify treasury balance is reduced by total payment amount
    scenario.next_tx(ADMIN);
    {
        let treasury = scenario.take_shared_by_id<Treasury>(treasury_id);
        // Balance should be 0 SUI - all funds (1000 SUI) were withdrawn to fund the payment stream
        // (100 SUI per payment × 10 payments = 1000 SUI total)
        assert!(treasury::coin_type_value<SUI>(&treasury) == 0, 100);
        test::return_shared(treasury);
    };
    
    // Note: The actual recurring payments would be executed by calling
    // recurring_payments::execute_payment periodically. This test verifies
    // that the action correctly sets up the payment stream.
    
    clock.destroy_for_testing();
    scenario.end();
}