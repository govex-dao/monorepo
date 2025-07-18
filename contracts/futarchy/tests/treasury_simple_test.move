#[test_only]
module futarchy::treasury_simple_test;

use futarchy::{
    dao::{Self, DAO},
    treasury::{Self, Treasury},
    treasury_actions::{Self, ActionRegistry},
    treasury_initialization,
    fee,
};
use sui::{
    test_scenario::{Self as test},
    clock::{Self, Clock},
    coin::{Self, Coin},
    sui::SUI,
};

#[test]
fun test_treasury_integration() {
    let admin = @0xAD;
    let alice = @0xA11CE;
    let bob = @0xB0B;
    let mut scenario = test::begin(admin);
    
    // Setup
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(1_000_000);
    
    // Create DAO
    let mut dao = dao::create<SUI, SUI>(
        10_000_000_000, // min asset
        10_000_000_000, // min stable
        b"Test DAO".to_ascii_string(),
        b"https://test.com/icon.png".to_ascii_string(),
        3600000, // 1 hour review
        86400000, // 24 hour trading
        60000, // 1 minute TWAP delay
        10, // step max
        1000000000000000000, // initial observation
        100, // TWAP threshold
        b"Test DAO for treasury".to_string(),
        2, // max outcomes
        vector[],
        &clock,
        scenario.ctx(),
    );
    
    // Initialize treasury
    treasury_initialization::initialize_treasury(&mut dao, admin, scenario.ctx());
    
    // Create fee manager for testing
    fee::create_fee_manager_for_testing(scenario.ctx());
    
    transfer::public_share_object(dao);
    
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
        let deposit_coin = coin::mint_for_testing<SUI>(100_000_000_000, scenario.ctx()); // 100 SUI
        
        treasury::deposit_sui(
            &mut treasury,
            deposit_coin,
            scenario.ctx()
        );
        
        test::return_shared(treasury);
    };
    
    // Verify deposit
    scenario.next_tx(admin);
    {
        let treasury = scenario.take_shared_by_id<Treasury>(treasury_id);
        let balance = treasury::coin_type_value<SUI>(&treasury);
        assert!(balance == 100_000_000_000, 1);
        test::return_shared(treasury);
    };
    
    clock.destroy_for_testing();
    scenario.end();
}

#[test]
fun test_treasury_actions_registry() {
    let admin = @0xAD;
    let mut scenario = test::begin(admin);
    
    // Create registry
    treasury_actions::create_for_testing(scenario.ctx());
    
    scenario.next_tx(admin);
    let registry_id = {
        let registry = scenario.take_shared<ActionRegistry>();
        let id = object::id(&registry);
        test::return_shared(registry);
        id
    };
    
    // Test action storage
    scenario.next_tx(admin);
    {
        let mut registry = scenario.take_shared<ActionRegistry>();
        let proposal_id = object::id_from_address(@0x1234);
        
        // Initialize actions for a proposal
        treasury_actions::init_proposal_actions(
            &mut registry,
            proposal_id,
            2, // 2 outcomes
            scenario.ctx(),
        );
        
        // Add actions
        treasury_actions::add_no_op_action(
            &mut registry,
            proposal_id,
            0, // Reject outcome
            scenario.ctx(),
        );
        
        treasury_actions::add_transfer_action<SUI>(
            &mut registry,
            proposal_id,
            1, // Accept outcome
            @0xB0B,
            50_000_000_000, // 50 SUI
            scenario.ctx(),
        );
        
        // Verify action count
        let action_count = treasury_actions::get_action_count(&registry, proposal_id, 1);
        assert!(action_count == 1, 2);
        
        test::return_shared(registry);
    };
    
    scenario.end();
}