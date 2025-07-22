#[test_only]
module futarchy::treasury_action_test;

use futarchy::{
    dao::{Self, DAO},
    treasury::{Self, Treasury},
    treasury_actions::{Self, ActionRegistry},
    treasury_initialization,
    capability_manager::{Self, CapabilityManager},
    advance_stage,
    market_state::{Self, MarketState},
    amm::{Self, LiquidityPool},
    fee::{Self, FeeManager},
    transfer_proposals,
};
use sui::{
    test_scenario::{Self as test},
    clock::{Self, Clock},
    coin::{Self, Coin},
    sui::SUI,
    transfer,
    object::{Self, ID},
};

// Test coin type
public struct USDC has drop {}

// Helper function to mark a proposal as executed for testing
fun mark_proposal_executed(
    dao: &mut DAO,
    proposal_id: ID,
    winning_outcome: u64,
) {
    // Use the test helper to mark the proposal as executed
    dao::test_mark_proposal_executed(dao, proposal_id, winning_outcome);
}

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
    
    // Create fee manager
    fee::create_fee_manager_for_testing(scenario.ctx());
    
    // Create a real proposal with treasury actions
    scenario.next_tx(admin);
    let (proposal_id, market_state_id) = {
        let mut dao = scenario.take_shared<DAO>();
        let mut fee_manager = scenario.take_shared<FeeManager>();
        let mut registry = scenario.take_shared<ActionRegistry>();
        
        let payment = coin::mint_for_testing<SUI>(2_000, scenario.ctx()); // 2 outcomes * 1000 per outcome
        let dao_fee_payment = coin::mint_for_testing<SUI>(0, scenario.ctx());
        let asset_coin = coin::mint_for_testing<SUI>(10_000_000_000, scenario.ctx());
        let stable_coin = coin::mint_for_testing<SUI>(10_000_000_000, scenario.ctx());
        
        // Create a transfer proposal using dao::create_proposal_internal
        let (prop_id, market_state_id, _) = dao::create_proposal_internal<SUI, SUI>(
            &mut dao,
            &mut fee_manager,
            payment,
            dao_fee_payment,
            2, // outcome_count
            asset_coin,
            stable_coin,
            b"Test Transfer Proposal".to_string(),
            vector[
                b"Reject transfers".to_string(),
                b"Transfer SUI and USDC to Bob".to_string(),
            ],
            b"Transfer funds to Bob".to_string(),
            vector[
                b"Reject".to_string(),
                b"Accept".to_string(),
            ],
            vector[10_000_000_000, 10_000_000_000, 10_000_000_000, 10_000_000_000],
            &clock,
            scenario.ctx(),
        );
        
        // Initialize actions for the proposal
        treasury_actions::init_proposal_actions(
            &mut registry,
            prop_id,
            2, // outcome_count
            scenario.ctx()
        );
        
        // Add no-op for reject outcome (0)
        treasury_actions::add_no_op_action(
            &mut registry,
            prop_id,
            0,
            scenario.ctx()
        );
        
        // Add SUI transfer action for accept outcome (1)
        treasury_actions::add_transfer_action<SUI>(
            &mut registry,
            prop_id,
            1,
            bob,
            25_000_000_000, // 25 SUI
            scenario.ctx(),
        );
        
        // Also add USDC transfer action
        treasury_actions::add_transfer_action<USDC>(
            &mut registry,
            prop_id,
            1,
            bob,
            10_000_000_000, // 10 USDC
            scenario.ctx(),
        );
        
        test::return_shared(dao);
        test::return_shared(fee_manager);
        test::return_shared(registry);
        
        (prop_id, market_state_id)
    };
    
    // Create capability manager for execution
    scenario.next_tx(admin);
    {
        capability_manager::initialize(scenario.ctx());
    };
    
    // Advance time past review and trading periods
    clock.increment_for_testing(86400000 + 604800000 + 1000); // review + trading + buffer
    
    // Advance proposal through lifecycle and finalize it
    scenario.next_tx(admin);
    {
        let mut dao = scenario.take_shared<DAO>();
        mark_proposal_executed(
            &mut dao,
            proposal_id,
            1 // winning outcome
        );
        test::return_shared(dao);
    };
    
    // Now execute the treasury actions properly
    scenario.next_tx(admin);
    {
        let dao = scenario.take_shared<DAO>();
        let mut registry = scenario.take_shared<ActionRegistry>();
        let mut treasury = scenario.take_shared_by_id<Treasury>(treasury_id);
        let mut cap_manager = scenario.take_shared<CapabilityManager>();
        
        // Execute SUI transfer with proper authorization
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
    
    // Verify Bob received the SUI funds (USDC won't be transferred due to execution limitation)
    scenario.next_tx(bob);
    {
        let sui_coin = scenario.take_from_sender<Coin<SUI>>();
        assert!(sui_coin.value() == 25_000_000_000, 1);
        scenario.return_to_sender(sui_coin);
        
        // USDC transfer was not executed due to the design limitation
        // where only one coin type can be executed per outcome
    };
    
    // Verify treasury balances
    scenario.next_tx(admin);
    {
        let treasury = scenario.take_shared_by_id<Treasury>(treasury_id);
        
        let sui_balance = treasury::coin_type_value<SUI>(&treasury);
        assert!(sui_balance == 85_000_000_000, 3); // 100 + 10 (fee) - 25 = 85
        
        let usdc_balance = treasury::coin_type_value<USDC>(&treasury);
        assert!(usdc_balance == 50_000_000_000, 4); // 50 (no transfer executed)
        
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
    
    // Add the proposal to the DAO
    scenario.next_tx(admin);
    {
        let mut dao = scenario.take_shared<DAO>();
        dao::add_proposal_for_testing(&mut dao, proposal_id, 2, &clock, scenario.ctx());
        test::return_shared(dao);
    };
    
    // Setup no-op action
    scenario.next_tx(admin);
    {
        let mut registry = scenario.take_shared<ActionRegistry>();
        
        treasury_actions::init_proposal_actions(&mut registry, proposal_id, 2, scenario.ctx());
        
        // Add no-op action for outcome 0 (reject)
        treasury_actions::add_no_op_action(&mut registry, proposal_id, 0, scenario.ctx());
        
        test::return_shared(registry);
    };
    
    // Create capability manager for execution
    scenario.next_tx(admin);
    {
        capability_manager::initialize(scenario.ctx());
    };
    
    // Execute no-op action
    scenario.next_tx(admin);
    {
        let dao = scenario.take_shared<DAO>();
        let mut registry = scenario.take_shared<ActionRegistry>();
        let mut treasury = scenario.take_shared_by_id<Treasury>(treasury_id);
        let mut cap_manager = scenario.take_shared<CapabilityManager>();
        
        // Execute no-op (should succeed without doing anything)
        treasury_actions::execute_outcome_actions_sui(
            &mut registry,
            &mut treasury,
            &dao,
            &mut cap_manager,
            &clock,
            proposal_id,
            0, // reject outcome
            scenario.ctx()
        );
        
        test::return_shared(dao);
        test::return_shared(registry);
        test::return_shared(treasury);
        test::return_shared(cap_manager);
    };
    
    clock.destroy_for_testing();
    scenario.end();
}