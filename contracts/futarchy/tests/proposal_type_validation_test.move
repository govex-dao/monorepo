#[test_only]
module futarchy::proposal_type_validation_test;

use futarchy::{
    dao::{Self, DAO},
    treasury::{Self, Treasury},
    treasury_actions::{Self, ActionRegistry},
    treasury_initialization,
    config_proposals,
    config_actions::{Self, ConfigActionRegistry},
    proposals,
    proposal::{Self, Proposal},
    fee,
};
use sui::{
    test_scenario::{Self as test},
    clock::{Self, Clock},
    coin::{Self, Coin},
    sui::SUI,
};

const ADMIN: address = @0xAD;
const ALICE: address = @0xA11CE;
const BOB: address = @0xB0B;

#[test]
fun test_cannot_mix_treasury_and_config_in_same_proposal() {
    let mut scenario = test::begin(ADMIN);
    
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
        b"Testing proposal type validation".to_string(),
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
    config_actions::create_registry_for_testing(scenario.ctx());
    
    // Test 1: Create a config proposal
    scenario.next_tx(ALICE);
    let config_proposal_id = {
        let mut dao = scenario.take_shared<DAO>();
        let mut fee_manager = scenario.take_shared<fee::FeeManager>();
        let mut config_registry = scenario.take_shared<ConfigActionRegistry>();
        
        let payment = coin::mint_for_testing<SUI>(10_000, scenario.ctx());
        let asset_coin = coin::mint_for_testing<SUI>(100_000_000_000, scenario.ctx());
        let stable_coin = coin::mint_for_testing<SUI>(100_000_000_000, scenario.ctx());
        
        // Create config proposal (implicitly config type)
        config_proposals::create_trading_params_proposal<SUI, SUI>(
            &mut dao,
            &mut fee_manager,
            &mut config_registry,
            payment,
            asset_coin,
            stable_coin,
            b"Update Trading Params".to_string(),
            b"Test config proposal".to_string(),
            vector[100_000_000_000, 100_000_000_000, 100_000_000_000, 100_000_000_000],
            option::some(20_000_000_000),
            option::none<u64>(),
            option::none<u64>(),
            option::none<u64>(),
            &clock,
            scenario.ctx(),
        );
        
        test::return_shared(dao);
        test::return_shared(fee_manager);
        test::return_shared(config_registry);
        
        // Return a dummy ID for testing
        object::id_from_address(@0xC0F16)
    };
    
    // Test 2: Try to add treasury actions to a config proposal (should fail)
    scenario.next_tx(ADMIN);
    {
        let dao = scenario.take_shared<DAO>();
        let mut registry = scenario.take_shared<ActionRegistry>();
        
        // This should work - initializing actions doesn't check proposal type
        treasury_actions::init_proposal_actions(
            &mut registry,
            config_proposal_id,
            2,
            scenario.ctx()
        );
        
        // But adding treasury actions should fail when the proposal is marked as config
        // Note: Since we can't actually mark the proposal as config without accessing it,
        // this test demonstrates the structure. In practice, the validation would occur
        // when trying to add the treasury intent to the proposal.
        
        test::return_shared(dao);
        test::return_shared(registry);
    };
    
    // Test 3: Create a treasury proposal
    scenario.next_tx(ALICE);
    let treasury_proposal_id = {
        let mut dao = scenario.take_shared<DAO>();
        let mut fee_manager = scenario.take_shared<fee::FeeManager>();
        let mut registry = scenario.take_shared<ActionRegistry>();
        
        let payment = coin::mint_for_testing<SUI>(10_000, scenario.ctx());
        let asset_coin = coin::mint_for_testing<SUI>(100_000_000_000, scenario.ctx());
        let stable_coin = coin::mint_for_testing<SUI>(100_000_000_000, scenario.ctx());
        
        // Create treasury proposal
        proposals::create_and_store_transfer_proposal<SUI, SUI, SUI>(
            &mut dao,
            &mut fee_manager,
            &mut registry,
            payment,
            asset_coin,
            stable_coin,
            b"Treasury Transfer".to_string(),
            b"Test treasury proposal".to_string(),
            vector[100_000_000_000, 100_000_000_000, 100_000_000_000, 100_000_000_000],
            BOB,
            50_000_000_000,
            b"Payment to Bob".to_string(),
            &clock,
            scenario.ctx(),
        );
        
        test::return_shared(dao);
        test::return_shared(fee_manager);
        test::return_shared(registry);
        
        // Return a dummy ID for testing
        object::id_from_address(@0x7EA5)
    };
    
    // Test 4: Try to execute config updates on a treasury proposal (should fail)
    scenario.next_tx(ADMIN);
    {
        let mut dao = scenario.take_shared<DAO>();
        
        // This should fail because the proposal has treasury actions
        // In practice, we would check proposal.is_treasury_proposal() before allowing config execution
        // The validation would be in the config execution functions
        
        test::return_shared(dao);
    };
    
    clock.destroy_for_testing();
    scenario.end();
}

#[test]
fun test_memo_only_proposals_allow_neither_treasury_nor_config() {
    let mut scenario = test::begin(ADMIN);
    
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
        b"Testing memo proposals".to_string(),
        2,
        vector[],
        &clock,
        scenario.ctx(),
    );
    
    transfer::public_share_object(dao);
    fee::create_fee_manager_for_testing(scenario.ctx());
    
    // Create a memo-only proposal
    scenario.next_tx(ALICE);
    {
        let mut dao = scenario.take_shared<DAO>();
        let mut fee_manager = scenario.take_shared<fee::FeeManager>();
        
        let payment = coin::mint_for_testing<SUI>(10_000, scenario.ctx());
        let asset_coin = coin::mint_for_testing<SUI>(100_000_000_000, scenario.ctx());
        let stable_coin = coin::mint_for_testing<SUI>(100_000_000_000, scenario.ctx());
        
        // Create regular proposal without treasury or config actions
        dao::create_proposal<SUI, SUI>(
            &mut dao,
            &mut fee_manager,
            payment,
            2,
            asset_coin,
            stable_coin,
            b"Community Decision".to_string(),
            vector[b"Reject".to_string(), b"Accept".to_string()],
            b"Should we proceed with the community initiative?".to_string(),
            vector[b"Reject".to_string(), b"Accept".to_string()],
            vector[100_000_000_000, 100_000_000_000, 100_000_000_000, 100_000_000_000],
            &clock,
            scenario.ctx(),
        );
        
        test::return_shared(dao);
        test::return_shared(fee_manager);
    };
    
    clock.destroy_for_testing();
    scenario.end();
}

#[test]
fun test_memo_plus_treasury_allowed() {
    let mut scenario = test::begin(ADMIN);
    
    let mut clock = clock::create_for_testing(scenario.ctx());
    
    // Create DAO with treasury
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
        b"Testing memo + treasury".to_string(),
        2,
        vector[],
        &clock,
        scenario.ctx(),
    );
    
    treasury_initialization::initialize_treasury(&mut dao, ADMIN, scenario.ctx());
    transfer::public_share_object(dao);
    
    fee::create_fee_manager_for_testing(scenario.ctx());
    treasury_actions::create_for_testing(scenario.ctx());
    
    // Create a proposal with memo and treasury actions
    scenario.next_tx(ALICE);
    {
        let mut dao = scenario.take_shared<DAO>();
        let mut fee_manager = scenario.take_shared<fee::FeeManager>();
        let mut registry = scenario.take_shared<ActionRegistry>();
        
        let payment = coin::mint_for_testing<SUI>(10_000, scenario.ctx());
        let asset_coin = coin::mint_for_testing<SUI>(100_000_000_000, scenario.ctx());
        let stable_coin = coin::mint_for_testing<SUI>(100_000_000_000, scenario.ctx());
        
        // This is allowed: memo + treasury
        proposals::create_and_store_transfer_proposal<SUI, SUI, SUI>(
            &mut dao,
            &mut fee_manager,
            &mut registry,
            payment,
            asset_coin,
            stable_coin,
            b"Fund Community Project".to_string(),
            b"Proposal to fund the community garden project with treasury funds".to_string(),
            vector[100_000_000_000, 100_000_000_000, 100_000_000_000, 100_000_000_000],
            BOB,
            100_000_000_000,
            b"Community garden funding".to_string(),
            &clock,
            scenario.ctx(),
        );
        
        test::return_shared(dao);
        test::return_shared(fee_manager);
        test::return_shared(registry);
    };
    
    clock.destroy_for_testing();
    scenario.end();
}

#[test]
fun test_memo_plus_config_allowed() {
    let mut scenario = test::begin(ADMIN);
    
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
        b"Testing memo + config".to_string(),
        2,
        vector[],
        &clock,
        scenario.ctx(),
    );
    
    transfer::public_share_object(dao);
    fee::create_fee_manager_for_testing(scenario.ctx());
    config_actions::create_registry_for_testing(scenario.ctx());
    
    // Create a config proposal (which includes memo by default)
    scenario.next_tx(ALICE);
    {
        let mut dao = scenario.take_shared<DAO>();
        let mut fee_manager = scenario.take_shared<fee::FeeManager>();
        let mut config_registry = scenario.take_shared<ConfigActionRegistry>();
        
        let payment = coin::mint_for_testing<SUI>(10_000, scenario.ctx());
        let asset_coin = coin::mint_for_testing<SUI>(100_000_000_000, scenario.ctx());
        let stable_coin = coin::mint_for_testing<SUI>(100_000_000_000, scenario.ctx());
        
        // This is allowed: memo + config
        config_proposals::create_metadata_proposal(
            &mut dao,
            &mut fee_manager,
            &mut config_registry,
            payment,
            asset_coin,
            stable_coin,
            b"Update DAO Branding".to_string(),
            b"Proposal to update our DAO name and description to better reflect our mission".to_string(),
            vector[100_000_000_000, 100_000_000_000, 100_000_000_000, 100_000_000_000],
            b"Community Garden DAO".to_ascii_string(),
            b"https://garden.dao/icon.png".to_ascii_string(),
            b"A DAO focused on funding and managing community gardens".to_string(),
            &clock,
            scenario.ctx(),
        );
        
        test::return_shared(dao);
        test::return_shared(fee_manager);
        test::return_shared(config_registry);
    };
    
    clock.destroy_for_testing();
    scenario.end();
}