#[test_only]
module futarchy::treasury_action_test;

use futarchy::{
    dao::{Self, DAO},
    treasury::{Self, Treasury},
    treasury_actions::{Self, ActionRegistry},
    treasury_initialization,
};
use sui::{
    test_scenario::{Self as test},
    clock::{Self, Clock},
    coin::{Self, Coin},
    sui::SUI,
};

// Test coin type
public struct USDC has drop {}

#[test]
fun test_direct_treasury_actions() {
    let admin = @0xAD;
    let alice = @0xA11CE;
    let bob = @0xB0B;
    let mut scenario = test::begin(admin);
    
    // Setup
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(1_000_000);
    
    // Create DAO and treasury
    let mut dao = dao::create<SUI, SUI>(
        10_000_000_000,
        10_000_000_000,
        b"Test DAO".to_ascii_string(),
        b"https://test.com/icon.png".to_ascii_string(),
        3600000,
        86400000,
        60000,
        10,
        1000000000000000000,
        100,
        b"Treasury action test".to_string(),
        2,
        vector[],
        &clock,
        scenario.ctx(),
    );
    
    treasury_initialization::initialize_treasury(&mut dao, admin, scenario.ctx());
    transfer::public_share_object(dao);
    
    // Create ActionRegistry for testing
    treasury_actions::create_for_testing(scenario.ctx());
    
    // Get treasury ID
    scenario.next_tx(admin);
    let treasury_id = {
        let dao = scenario.take_shared<DAO>();
        let id = *dao::get_treasury_id(&dao).borrow();
        test::return_shared(dao);
        id
    };
    
    
    // Deposit funds to treasury
    scenario.next_tx(alice);
    {
        let mut treasury = scenario.take_shared_by_id<Treasury>(treasury_id);
        
        // Deposit SUI
        let sui_deposit = coin::mint_for_testing<SUI>(100_000_000_000, scenario.ctx());
        treasury::deposit_sui(&mut treasury, sui_deposit, scenario.ctx());
        
        // Deposit USDC with fee
        let usdc_deposit = coin::mint_for_testing<USDC>(50_000_000_000, scenario.ctx());
        let fee_payment = coin::mint_for_testing<SUI>(10_000_000_000, scenario.ctx());
        treasury::deposit_coin_with_fee<USDC>(
            &mut treasury,
            usdc_deposit,
            fee_payment,
            scenario.ctx()
        );
        
        test::return_shared(treasury);
    };
    
    // Create a mock proposal ID
    let proposal_id = object::id_from_address(@0x1234);
    
    // Setup actions in registry
    scenario.next_tx(admin);
    {
        let mut registry = scenario.take_shared<ActionRegistry>();
        
        // Initialize actions for proposal
        treasury_actions::init_proposal_actions(&mut registry, proposal_id, 2, scenario.ctx());
        
        // Add actions for outcome 1 (accept)
        treasury_actions::add_transfer_action<SUI>(
            &mut registry,
            proposal_id,
            1,
            bob,
            25_000_000_000, // 25 SUI
            scenario.ctx(),
        );
        
        treasury_actions::add_transfer_action<USDC>(
            &mut registry,
            proposal_id,
            1,
            bob,
            10_000_000_000, // 10 USDC
            scenario.ctx(),
        );
        
        test::return_shared(registry);
    };
    
    // Execute actions directly (simulating proposal execution)
    scenario.next_tx(admin);
    {
        let dao = scenario.take_shared<DAO>();
        let mut registry = scenario.take_shared<ActionRegistry>();
        let mut treasury = scenario.take_shared_by_id<Treasury>(treasury_id);
        
        // Execute SUI transfer
        treasury_actions::execute_outcome_actions_sui(
            &mut registry,
            &mut treasury,
            &dao,
            &clock,
            proposal_id,
            1, // winning outcome
            scenario.ctx()
        );
        
        // Execute USDC transfer
        treasury_actions::execute_outcome_actions<USDC>(
            &mut registry,
            &mut treasury,
            &dao,
            &clock,
            proposal_id,
            1, // winning outcome
            scenario.ctx()
        );
        
        test::return_shared(dao);
        test::return_shared(registry);
        test::return_shared(treasury);
    };
    
    // Verify Bob received the funds
    scenario.next_tx(bob);
    {
        let sui_coin = scenario.take_from_sender<Coin<SUI>>();
        assert!(sui_coin.value() == 25_000_000_000, 1);
        scenario.return_to_sender(sui_coin);
        
        let usdc_coin = scenario.take_from_sender<Coin<USDC>>();
        assert!(usdc_coin.value() == 10_000_000_000, 2);
        scenario.return_to_sender(usdc_coin);
    };
    
    // Verify treasury balances
    scenario.next_tx(admin);
    {
        let treasury = scenario.take_shared_by_id<Treasury>(treasury_id);
        
        let sui_balance = treasury::coin_type_value<SUI>(&treasury);
        assert!(sui_balance == 85_000_000_000, 3); // 100 + 10 (fee) - 25 = 85
        
        let usdc_balance = treasury::coin_type_value<USDC>(&treasury);
        assert!(usdc_balance == 40_000_000_000, 4); // 50 - 10 = 40
        
        test::return_shared(treasury);
    };
    
    clock.destroy_for_testing();
    scenario.end();
}

#[test]
fun test_no_op_action() {
    let admin = @0xAD;
    let mut scenario = test::begin(admin);
    
    // Setup
    let clock = clock::create_for_testing(scenario.ctx());
    
    // Create DAO
    let mut dao = dao::create<SUI, SUI>(
        10_000_000_000,
        10_000_000_000,
        b"Test DAO".to_ascii_string(),
        b"https://test.com/icon.png".to_ascii_string(),
        3600000,
        86400000,
        60000,
        10,
        1000000000000000000,
        100,
        b"No-op test".to_string(),
        2,
        vector[],
        &clock,
        scenario.ctx(),
    );
    
    treasury_initialization::initialize_treasury(&mut dao, admin, scenario.ctx());
    transfer::public_share_object(dao);
    
    // Create ActionRegistry for testing
    treasury_actions::create_for_testing(scenario.ctx());
    
    // Get treasury ID
    scenario.next_tx(admin);
    let treasury_id = {
        let dao = scenario.take_shared<DAO>();
        let id = *dao::get_treasury_id(&dao).borrow();
        test::return_shared(dao);
        id
    };
    
    
    // Create mock proposal ID
    let proposal_id = object::id_from_address(@0x9999);
    
    // Setup no-op action
    scenario.next_tx(admin);
    {
        let mut registry = scenario.take_shared<ActionRegistry>();
        
        treasury_actions::init_proposal_actions(&mut registry, proposal_id, 2, scenario.ctx());
        
        // Add no-op action for outcome 0 (reject)
        treasury_actions::add_no_op_action(&mut registry, proposal_id, 0, scenario.ctx());
        
        test::return_shared(registry);
    };
    
    // Execute no-op action
    scenario.next_tx(admin);
    {
        let dao = scenario.take_shared<DAO>();
        let mut registry = scenario.take_shared<ActionRegistry>();
        let mut treasury = scenario.take_shared_by_id<Treasury>(treasury_id);
        
        // Execute no-op (should succeed without doing anything)
        treasury_actions::execute_outcome_actions_sui(
            &mut registry,
            &mut treasury,
            &dao,
            &clock,
            proposal_id,
            0, // reject outcome
            scenario.ctx()
        );
        
        test::return_shared(dao);
        test::return_shared(registry);
        test::return_shared(treasury);
    };
    
    clock.destroy_for_testing();
    scenario.end();
}