#[test_only]
module futarchy::treasury_basic_test;

use futarchy::{
    treasury::{Self, Treasury},
    treasury_actions::{Self, ActionRegistry},
    treasury_initialization,
    dao::{Self, DAO},
    execution_context::{Self, ProposalExecutionContext},
};
use sui::{
    test_scenario::{Self as test},
    clock::{Self, Clock},
    coin::{Self, Coin},
    sui::SUI,
};

#[test]
fun test_treasury_deposit_withdraw() {
    let admin = @0xAD;
    let alice = @0xA11CE;
    let mut scenario = test::begin(admin);
    
    // Setup
    let mut clock = clock::create_for_testing(scenario.ctx());
    
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
        b"Test DAO".to_string(),
        2,
        vector[],
        &clock,
        scenario.ctx(),
    );
    
    // Initialize treasury
    treasury_initialization::initialize_treasury(&mut dao, admin, scenario.ctx());
    transfer::public_share_object(dao);
    
    // Get treasury ID and DAO ID
    scenario.next_tx(admin);
    let (treasury_id, dao_id) = {
        let dao = scenario.take_shared<DAO>();
        let treasury_id = *dao::get_treasury_id(&dao).borrow();
        let dao_id = object::id(&dao);
        test::return_shared(dao);
        (treasury_id, dao_id)
    };
    
    // Test deposit
    scenario.next_tx(alice);
    {
        let mut treasury = scenario.take_shared_by_id<Treasury>(treasury_id);
        let deposit = coin::mint_for_testing<SUI>(50_000_000_000, scenario.ctx());
        treasury::deposit_sui(&mut treasury, deposit, scenario.ctx());
        test::return_shared(treasury);
    };
    
    // Test withdrawal
    scenario.next_tx(admin);
    {
        let mut treasury = scenario.take_shared_by_id<Treasury>(treasury_id);
        // Create a test execution context
        let test_proposal_id = object::id_from_address(@0x123);
        let execution_context = execution_context::create_for_testing(
            test_proposal_id,
            0, // outcome
            dao_id
        );
        let auth = treasury::create_auth_for_proposal(&treasury, &execution_context);
        let withdrawn = treasury::withdraw<SUI>(
            auth,
            &mut treasury,
            25_000_000_000,
            scenario.ctx()
        );
        transfer::public_transfer(withdrawn, alice);
        test::return_shared(treasury);
    };
    
    // Verify balance
    scenario.next_tx(admin);
    {
        let treasury = scenario.take_shared_by_id<Treasury>(treasury_id);
        let balance = treasury::coin_type_value<SUI>(&treasury);
        assert!(balance == 25_000_000_000); // Remaining balance
        test::return_shared(treasury);
    };
    
    clock.destroy_for_testing();
    scenario.end();
}

#[test] 
fun test_action_registry() {
    let admin = @0xAD;
    let mut scenario = test::begin(admin);
    
    // Create ActionRegistry for testing
    treasury_actions::create_for_testing(scenario.ctx());
    
    scenario.next_tx(admin);
    {
        let mut registry = scenario.take_shared<ActionRegistry>();
        let proposal_id = object::id_from_address(@0x1234);
        
        // Initialize actions
        treasury_actions::init_proposal_actions(&mut registry, proposal_id, 2, scenario.ctx());
        
        // Add actions
        treasury_actions::add_no_op_action(&mut registry, proposal_id, 0, scenario.ctx());
        treasury_actions::add_transfer_action<SUI>(
            &mut registry,
            proposal_id,
            1,
            @0xBEEF,
            1_000_000_000,
            scenario.ctx()
        );
        
        // Check action count
        let count = treasury_actions::get_action_count(&registry, proposal_id, 1);
        assert!(count == 1);
        
        test::return_shared(registry);
    };
    
    scenario.end();
}