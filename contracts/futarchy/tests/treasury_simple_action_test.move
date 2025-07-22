#[test_only]
module futarchy::treasury_simple_action_test;

use futarchy::{
    dao::{Self, DAO},
    treasury::{Self, Treasury},
    treasury_actions::{Self, ActionRegistry},
    treasury_initialization,
    fee,
    capability_manager::{Self, CapabilityManager},
};
use sui::{
    test_scenario::{Self as test},
    clock::{Self, Clock},
    coin::{Self, Coin},
    sui::SUI,
};

// Test coin type
public struct TESTCOIN has drop {}

#[test]
fun test_treasury_transfer_action() {
    let admin = @0xAD;
    let alice = @0xA11CE;
    let bob = @0xB0B;
    let mut scenario = test::begin(admin);
    
    // Setup
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(1_000_000);
    
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
        b"Test DAO for treasury transfers".to_string(),
        2,
        vector[],
        &clock,
        scenario.ctx(),
    );
    
    // Initialize treasury
    treasury_initialization::initialize_treasury(&mut dao, admin, scenario.ctx());
    transfer::public_share_object(dao);
    
    // Create ActionRegistry for testing
    treasury_actions::create_for_testing(scenario.ctx());
    
    // Get treasury
    scenario.next_tx(admin);
    let treasury_id = {
        let dao = scenario.take_shared<DAO>();
        let treasury_id = *dao::get_treasury_id(&dao).borrow();
        test::return_shared(dao);
        treasury_id
    };
    
    // Deposit SUI to treasury
    scenario.next_tx(alice);
    {
        let mut treasury = scenario.take_shared_by_id<Treasury>(treasury_id);
        let deposit_coin = coin::mint_for_testing<SUI>(100_000_000_000, scenario.ctx());
        
        treasury::deposit_sui(
            &mut treasury,
            deposit_coin,
            scenario.ctx()
        );
        
        test::return_shared(treasury);
    };
    
    // Create a mock proposal ID
    let proposal_id = object::id_from_address(@0xABCD);
    
    // Add the proposal to the DAO
    scenario.next_tx(admin);
    {
        let mut dao = scenario.take_shared<DAO>();
        dao::add_proposal_for_testing(&mut dao, proposal_id, 2, &clock, scenario.ctx());
        test::return_shared(dao);
    };
    
    // Setup treasury actions
    scenario.next_tx(admin);
    {
        let mut registry = scenario.take_shared<ActionRegistry>();
        
        // Initialize actions for proposal
        treasury_actions::init_proposal_actions(&mut registry, proposal_id, 2, scenario.ctx());
        
        // Add transfer action for outcome 1
        treasury_actions::add_transfer_action<SUI>(
            &mut registry,
            proposal_id,
            1,
            bob,
            50_000_000_000, // 50 SUI
            scenario.ctx(),
        );
        
        test::return_shared(registry);
    };
    
    // Create capability manager
    scenario.next_tx(admin);
    {
        capability_manager::initialize(scenario.ctx());
    };
    
    // Execute the treasury action
    scenario.next_tx(admin);
    {
        let dao = scenario.take_shared<DAO>();
        let mut registry = scenario.take_shared<ActionRegistry>();
        let mut treasury = scenario.take_shared_by_id<Treasury>(treasury_id);
        let mut cap_manager = scenario.take_shared<CapabilityManager>();
        
        // Execute treasury actions for outcome 1
        treasury_actions::execute_outcome_actions_sui(
            &mut registry,
            &mut treasury,
            &dao,
            &mut cap_manager,
            &clock,
            proposal_id,
            1, // winning outcome
            scenario.ctx()
        );
        
        test::return_shared(dao);
        test::return_shared(registry);
        test::return_shared(treasury);
        test::return_shared(cap_manager);
    };
    
    // Verify Bob received the SUI
    scenario.next_tx(bob);
    {
        let coin = scenario.take_from_sender<Coin<SUI>>();
        assert!(coin.value() == 50_000_000_000, 1);
        scenario.return_to_sender(coin);
    };
    
    // Verify treasury balance
    scenario.next_tx(admin);
    {
        let treasury = scenario.take_shared_by_id<Treasury>(treasury_id);
        let balance = treasury::coin_type_value<SUI>(&treasury);
        assert!(balance == 50_000_000_000, 2); // 100 - 50 = 50 SUI remaining
        test::return_shared(treasury);
    };
    
    clock.destroy_for_testing();
    scenario.end();
}

#[test]
fun test_multi_coin_treasury_actions() {
    let admin = @0xAD;
    let alice = @0xA11CE;
    let bob = @0xB0B;
    let mut scenario = test::begin(admin);
    
    // Setup
    let clock = clock::create_for_testing(scenario.ctx());
    
    // Create DAO
    let mut dao = dao::create<SUI, SUI>(
        10_000_000_000,
        10_000_000_000,
        b"Multi Asset DAO".to_ascii_string(),
        b"https://test.com/icon.png".to_ascii_string(),
        3600000,
        86400000,
        60000,
        10,
        1000000000000000000,
        100,
        b"Test multi-asset treasury".to_string(),
        2,
        vector[],
        &clock,
        scenario.ctx(),
    );
    
    treasury_initialization::initialize_treasury(&mut dao, admin, scenario.ctx());
    transfer::public_share_object(dao);
    
    // Create ActionRegistry for testing
    treasury_actions::create_for_testing(scenario.ctx());
    
    // Get treasury
    scenario.next_tx(admin);
    let treasury_id = {
        let dao = scenario.take_shared<DAO>();
        let treasury_id = *dao::get_treasury_id(&dao).borrow();
        test::return_shared(dao);
        treasury_id
    };
    
    // Deposit multiple coin types
    scenario.next_tx(alice);
    {
        let mut treasury = scenario.take_shared_by_id<Treasury>(treasury_id);
        
        // Deposit SUI
        let sui_deposit = coin::mint_for_testing<SUI>(100_000_000_000, scenario.ctx());
        treasury::deposit_sui(&mut treasury, sui_deposit, scenario.ctx());
        
        // Deposit TESTCOIN with fee
        let testcoin_deposit = coin::mint_for_testing<TESTCOIN>(50_000_000_000, scenario.ctx());
        let fee_payment = coin::mint_for_testing<SUI>(10_000_000_000, scenario.ctx());
        treasury::deposit_coin_with_fee<TESTCOIN>(
            &mut treasury,
            testcoin_deposit,
            fee_payment,
            scenario.ctx()
        );
        
        test::return_shared(treasury);
    };
    
    // Create mock proposal ID
    let proposal_id = object::id_from_address(@0xDEF0);
    
    // Add the proposal to the DAO
    scenario.next_tx(admin);
    {
        let mut dao = scenario.take_shared<DAO>();
        dao::add_proposal_for_testing(&mut dao, proposal_id, 2, &clock, scenario.ctx());
        test::return_shared(dao);
    };
    
    // Setup actions for multiple coin types
    scenario.next_tx(admin);
    {
        let mut registry = scenario.take_shared<ActionRegistry>();
        
        treasury_actions::init_proposal_actions(&mut registry, proposal_id, 2, scenario.ctx());
        
        // Add SUI transfer
        treasury_actions::add_transfer_action<SUI>(
            &mut registry,
            proposal_id,
            1,
            bob,
            25_000_000_000,
            scenario.ctx(),
        );
        
        // Add TESTCOIN transfer
        treasury_actions::add_transfer_action<TESTCOIN>(
            &mut registry,
            proposal_id,
            1,
            bob,
            10_000_000_000,
            scenario.ctx(),
        );
        
        test::return_shared(registry);
    };
    
    // Create capability manager if not already created
    scenario.next_tx(admin);
    {
        capability_manager::initialize(scenario.ctx());
    };
    
    // Execute all actions
    scenario.next_tx(admin);
    {
        let dao = scenario.take_shared<DAO>();
        let mut registry = scenario.take_shared<ActionRegistry>();
        let mut treasury = scenario.take_shared_by_id<Treasury>(treasury_id);
        let mut cap_manager = scenario.take_shared<CapabilityManager>();
        
        // Execute SUI transfer only - the execution marks the outcome as executed
        treasury_actions::execute_outcome_actions_sui(
            &mut registry,
            &mut treasury,
            &dao,
            &mut cap_manager,
            &clock,
            proposal_id,
            1,
            scenario.ctx()
        );
        
        test::return_shared(dao);
        test::return_shared(registry);
        test::return_shared(treasury);
        test::return_shared(cap_manager);
    };
    
    // Verify Bob received SUI (TESTCOIN won't be transferred due to execution limitation)
    scenario.next_tx(bob);
    {
        let sui_coin = scenario.take_from_sender<Coin<SUI>>();
        assert!(sui_coin.value() == 25_000_000_000, 1);
        scenario.return_to_sender(sui_coin);
        
        // TESTCOIN transfer was not executed due to the design limitation
    };
    
    // Verify treasury balances
    scenario.next_tx(admin);
    {
        let treasury = scenario.take_shared_by_id<Treasury>(treasury_id);
        
        let sui_balance = treasury::coin_type_value<SUI>(&treasury);
        assert!(sui_balance == 85_000_000_000, 3); // 100 + 10 (fee) - 25 = 85
        
        let testcoin_balance = treasury::coin_type_value<TESTCOIN>(&treasury);
        assert!(testcoin_balance == 50_000_000_000, 4); // 50 (no transfer executed)
        
        test::return_shared(treasury);
    };
    
    clock.destroy_for_testing();
    scenario.end();
}