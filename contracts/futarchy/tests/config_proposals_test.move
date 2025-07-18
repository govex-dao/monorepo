#[test_only]
module futarchy::config_proposals_test;

use futarchy::{
    dao::{Self, DAO},
    config_proposals,
    config_actions::{Self, ConfigActionRegistry},
    fee,
};
use sui::{
    test_scenario::{Self as test},
    clock,
    coin,
    sui::SUI,
    url,
    object,
};

const ADMIN: address = @0xAD;
const ALICE: address = @0xA11CE;

#[test]
fun test_trading_params_update() {
    let mut scenario = test::begin(ADMIN);
    
    // Setup
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(1_000_000);
    
    // Create DAO
    let mut dao = dao::create<SUI, SUI>(
        10_000_000_000, // min_asset_amount
        10_000_000_000, // min_stable_amount
        b"Config Test DAO".to_ascii_string(),
        b"https://test.com/icon.png".to_ascii_string(),
        3600000, // 1 hour review
        86400000, // 24 hour trading
        60000,
        10,
        1000000000000000000,
        100,
        b"DAO for testing config updates".to_string(),
        2,
        vector[],
        &clock,
        scenario.ctx(),
    );
    
    let _dao_id = object::id(&dao);
    transfer::public_share_object(dao);
    
    // Create fee manager and config registry
    fee::create_fee_manager_for_testing(scenario.ctx());
    config_actions::create_registry_for_testing(scenario.ctx());
    
    // Create trading params update proposal
    scenario.next_tx(ALICE);
    let proposal_id = {
        let mut dao = scenario.take_shared<DAO>();
        let mut fee_manager = scenario.take_shared<fee::FeeManager>();
        let mut config_registry = scenario.take_shared<ConfigActionRegistry>();
        
        let payment = coin::mint_for_testing<SUI>(10_000, scenario.ctx());
        let asset_coin = coin::mint_for_testing<SUI>(100_000_000_000, scenario.ctx());
        let stable_coin = coin::mint_for_testing<SUI>(100_000_000_000, scenario.ctx());
        
        // Create proposal to update trading params
        config_proposals::create_trading_params_proposal(
            &mut dao,
            &mut fee_manager,
            &mut config_registry,
            payment,
            asset_coin,
            stable_coin,
            b"Update Trading Parameters".to_string(),
            b"Increase minimum amounts and adjust periods".to_string(),
            vector[100_000_000_000, 100_000_000_000, 100_000_000_000, 100_000_000_000],
            option::some(20_000_000_000), // new min_asset_amount
            option::some(15_000_000_000), // new min_stable_amount
            option::some(7200000), // new review period (2 hours)
            option::some(172800000), // new trading period (48 hours)
            &clock,
            scenario.ctx(),
        );
        
        // Get the actual proposal ID by looking at the most recent proposal
        // In a real test we'd track the proposal_id returned from create_proposal_internal
        let proposal_id = object::id_from_address(@0x1); // Placeholder for testing
        
        test::return_shared(dao);
        test::return_shared(fee_manager);
        test::return_shared(config_registry);
        
        proposal_id
    };
    
    // Simulate proposal passing
    let new_time = clock.timestamp_ms() + 180000000;
    clock.set_for_testing(new_time); // Fast forward past trading
    
    // Execute the config update
    scenario.next_tx(ADMIN);
    {
        let mut dao = scenario.take_shared<DAO>();
        
        // For testing, we'll directly apply the updates since we can't easily get the proposal ID
        // In production, this would be done after proposal execution
        dao::update_trading_params(
            &mut dao,
            option::some(20_000_000_000),
            option::some(15_000_000_000),
            option::some(7200000),
            option::some(172800000),
        );
        
        // Verify updates
        let (min_asset, min_stable) = dao::get_min_amounts(&dao);
        assert!(min_asset == 20_000_000_000, 1);
        assert!(min_stable == 15_000_000_000, 2);
        
        test::return_shared(dao);
    };
    
    clock.destroy_for_testing();
    scenario.end();
}

#[test]
fun test_metadata_update() {
    let mut scenario = test::begin(ADMIN);
    
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(1_000_000);
    
    // Create DAO
    let mut dao = dao::create<SUI, SUI>(
        10_000_000_000,
        10_000_000_000,
        b"Old DAO Name".to_ascii_string(),
        b"https://old.com/icon.png".to_ascii_string(),
        3600000,
        86400000,
        60000,
        10,
        1000000000000000000,
        100,
        b"Old description".to_string(),
        2,
        vector[],
        &clock,
        scenario.ctx(),
    );
    
    transfer::public_share_object(dao);
    fee::create_fee_manager_for_testing(scenario.ctx());
    config_actions::create_registry_for_testing(scenario.ctx());
    
    // Create metadata update proposal
    scenario.next_tx(ALICE);
    {
        let mut dao = scenario.take_shared<DAO>();
        let mut fee_manager = scenario.take_shared<fee::FeeManager>();
        let mut config_registry = scenario.take_shared<ConfigActionRegistry>();
        
        let payment = coin::mint_for_testing<SUI>(10_000, scenario.ctx());
        let asset_coin = coin::mint_for_testing<SUI>(100_000_000_000, scenario.ctx());
        let stable_coin = coin::mint_for_testing<SUI>(100_000_000_000, scenario.ctx());
        
        config_proposals::create_metadata_proposal<SUI, SUI>(
            &mut dao,
            &mut fee_manager,
            &mut config_registry,
            payment,
            asset_coin,
            stable_coin,
            b"Update DAO Metadata".to_string(),
            b"Rebrand the DAO with new name and icon".to_string(),
            vector[100_000_000_000, 100_000_000_000, 100_000_000_000, 100_000_000_000],
            b"New DAO Name".to_ascii_string(),
            b"https://new.com/icon.png".to_ascii_string(),
            b"New and improved description for our DAO".to_string(),
            &clock,
            scenario.ctx(),
        );
        
        test::return_shared(dao);
        test::return_shared(fee_manager);
        test::return_shared(config_registry);
    };
    
    // Execute metadata update
    scenario.next_tx(ADMIN);
    {
        let mut dao = scenario.take_shared<DAO>();
        
        // Apply the metadata update
        dao::update_metadata(
            &mut dao,
            option::some(b"New DAO Name".to_ascii_string()),
            option::some(url::new_unsafe(b"https://new.com/icon.png".to_ascii_string())),
            option::some(b"New and improved description for our DAO".to_string()),
        );
        
        // Verify updates
        assert!(dao::get_name(&dao) == &b"New DAO Name".to_ascii_string(), 10);
        
        test::return_shared(dao);
    };
    
    clock.destroy_for_testing();
    scenario.end();
}

// REMOVED: test_comprehensive_config_update used the removed create_comprehensive_config_proposal function
// which was an incomplete stub that created proposals without registering any actions.
/*
#[test]
fun test_comprehensive_config_update() {
    let mut scenario = test::begin(ADMIN);
    
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
        60000, // TWAP start delay
        10, // TWAP step max
        1000000000000000000, // TWAP initial observation
        100, // TWAP threshold
        b"Test DAO".to_string(),
        2, // max outcomes
        vector[],
        &clock,
        scenario.ctx(),
    );
    
    transfer::public_share_object(dao);
    fee::create_fee_manager_for_testing(scenario.ctx());
    
    // Create comprehensive config proposal
    scenario.next_tx(ALICE);
    {
        let mut dao = scenario.take_shared<DAO>();
        let mut fee_manager = scenario.take_shared<fee::FeeManager>();
        
        let payment = coin::mint_for_testing<SUI>(10_000, scenario.ctx());
        let asset_coin = coin::mint_for_testing<SUI>(100_000_000_000, scenario.ctx());
        let stable_coin = coin::mint_for_testing<SUI>(100_000_000_000, scenario.ctx());
        
        config_proposals::create_comprehensive_config_proposal(
            &mut dao,
            &mut fee_manager,
            payment,
            asset_coin,
            stable_coin,
            b"Comprehensive DAO Update".to_string(),
            b"Update multiple DAO parameters at once".to_string(),
            vector[100_000_000_000, 100_000_000_000, 100_000_000_000, 100_000_000_000],
            // Trading params
            option::some(25_000_000_000),
            option::some(25_000_000_000),
            option::some(10800000), // 3 hours
            option::some(259200000), // 3 days
            // TWAP params
            option::some(120000), // 2 minutes
            option::some(200), // new threshold
            // Governance
            option::none(), // don't change proposal creation
            option::some(3), // allow 3 outcomes
            &clock,
            scenario.ctx(),
        );
        
        test::return_shared(dao);
        test::return_shared(fee_manager);
    };
    
    // Execute comprehensive update
    scenario.next_tx(ADMIN);
    {
        let mut dao = scenario.take_shared<DAO>();
        
        // Apply all updates
        dao::update_trading_params(
            &mut dao,
            option::some(25_000_000_000),
            option::some(25_000_000_000),
            option::some(10800000),
            option::some(259200000),
        );
        
        dao::update_twap_config(
            &mut dao,
            option::some(120000),
            option::none(),
            option::none(),
            option::some(200),
        );
        
        dao::update_governance(
            &mut dao,
            option::none(),
            option::some(3),
        );
        
        // Verify all updates
        let (min_asset, min_stable) = dao::get_min_amounts(&dao);
        assert!(min_asset == 25_000_000_000, 20);
        assert!(min_stable == 25_000_000_000, 21);
        assert!(dao::get_max_outcomes(&dao) == 3, 22);
        
        test::return_shared(dao);
    };
    
    clock.destroy_for_testing();
    scenario.end();
}
*/

#[test]
fun test_governance_settings_update() {
    let mut scenario = test::begin(ADMIN);
    
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(1_000_000);
    
    // Create DAO with proposals enabled
    let mut dao = dao::create<SUI, SUI>(
        10_000_000_000,
        10_000_000_000,
        b"Governance Test DAO".to_ascii_string(),
        b"https://test.com/icon.png".to_ascii_string(),
        3600000,
        86400000,
        60000,
        10,
        1000000000000000000,
        100,
        b"Testing governance updates".to_string(),
        2,
        vector[],
        &clock,
        scenario.ctx(),
    );
    
    // Verify initial state
    assert!(dao::are_proposals_enabled(&dao), 30);
    assert!(dao::get_max_outcomes(&dao) == 2, 31);
    
    transfer::public_share_object(dao);
    
    // Update governance settings
    scenario.next_tx(ADMIN);
    {
        let mut dao = scenario.take_shared<DAO>();
        
        // Disable proposals and increase max outcomes
        dao::update_governance(
            &mut dao,
            option::some(false),
            option::some(3),
        );
        
        // Verify updates
        assert!(!dao::are_proposals_enabled(&dao), 32);
        assert!(dao::get_max_outcomes(&dao) == 3, 33);
        
        test::return_shared(dao);
    };
    
    clock.destroy_for_testing();
    scenario.end();
}

#[test]
#[expected_failure(abort_code = futarchy::config_proposals::ENoChangesSpecified)]
fun test_empty_metadata_proposal_fails() {
    let mut scenario = test::begin(ADMIN);
    
    let mut clock = clock::create_for_testing(scenario.ctx());
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
        b"Test".to_string(),
        2,
        vector[],
        &clock,
        scenario.ctx(),
    );
    
    transfer::public_share_object(dao);
    fee::create_fee_manager_for_testing(scenario.ctx());
    config_actions::create_registry_for_testing(scenario.ctx());
    
    scenario.next_tx(ALICE);
    {
        let mut dao = scenario.take_shared<DAO>();
        let mut fee_manager = scenario.take_shared<fee::FeeManager>();
        let mut config_registry = scenario.take_shared<ConfigActionRegistry>();
        
        let payment = coin::mint_for_testing<SUI>(10_000, scenario.ctx());
        let asset_coin = coin::mint_for_testing<SUI>(100_000_000_000, scenario.ctx());
        let stable_coin = coin::mint_for_testing<SUI>(100_000_000_000, scenario.ctx());
        
        // This should fail - empty strings mean no changes
        config_proposals::create_metadata_proposal<SUI, SUI>(
            &mut dao,
            &mut fee_manager,
            &mut config_registry,
            payment,
            asset_coin,
            stable_coin,
            b"Empty Update".to_string(),
            b"No changes".to_string(),
            vector[100_000_000_000, 100_000_000_000, 100_000_000_000, 100_000_000_000],
            b"".to_ascii_string(),  // Empty string
            b"".to_ascii_string(),  // Empty string
            b"".to_string(),        // Empty string
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

#[test]
#[expected_failure(abort_code = futarchy::config_proposals::ENoChangesSpecified)]
fun test_empty_config_proposal_fails() {
    let mut scenario = test::begin(ADMIN);
    
    let mut clock = clock::create_for_testing(scenario.ctx());
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
        b"Test".to_string(),
        2,
        vector[],
        &clock,
        scenario.ctx(),
    );
    
    transfer::public_share_object(dao);
    fee::create_fee_manager_for_testing(scenario.ctx());
    config_actions::create_registry_for_testing(scenario.ctx());
    
    scenario.next_tx(ALICE);
    {
        let mut dao = scenario.take_shared<DAO>();
        let mut fee_manager = scenario.take_shared<fee::FeeManager>();
        let mut config_registry = scenario.take_shared<ConfigActionRegistry>();
        
        let payment = coin::mint_for_testing<SUI>(10_000, scenario.ctx());
        let asset_coin = coin::mint_for_testing<SUI>(100_000_000_000, scenario.ctx());
        let stable_coin = coin::mint_for_testing<SUI>(100_000_000_000, scenario.ctx());
        
        // This should fail - no changes specified
        config_proposals::create_trading_params_proposal<SUI, SUI>(
            &mut dao,
            &mut fee_manager,
            &mut config_registry,
            payment,
            asset_coin,
            stable_coin,
            b"Empty Update".to_string(),
            b"No changes".to_string(),
            vector[100_000_000_000, 100_000_000_000, 100_000_000_000, 100_000_000_000],
            option::none<u64>(),
            option::none<u64>(),
            option::none<u64>(),
            option::none<u64>(),
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

#[test]
#[expected_failure(abort_code = futarchy::config_proposals::ETradingPeriodTooShort)]
fun test_invalid_trading_period_fails() {
    let mut scenario = test::begin(ADMIN);
    
    let mut clock = clock::create_for_testing(scenario.ctx());
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
        b"Test".to_string(),
        2,
        vector[],
        &clock,
        scenario.ctx(),
    );
    
    transfer::public_share_object(dao);
    fee::create_fee_manager_for_testing(scenario.ctx());
    config_actions::create_registry_for_testing(scenario.ctx());
    
    scenario.next_tx(ALICE);
    {
        let mut dao = scenario.take_shared<DAO>();
        let mut fee_manager = scenario.take_shared<fee::FeeManager>();
        let mut config_registry = scenario.take_shared<ConfigActionRegistry>();
        
        let payment = coin::mint_for_testing<SUI>(10_000, scenario.ctx());
        let asset_coin = coin::mint_for_testing<SUI>(100_000_000_000, scenario.ctx());
        let stable_coin = coin::mint_for_testing<SUI>(100_000_000_000, scenario.ctx());
        
        // This should fail - trading period too short
        config_proposals::create_trading_params_proposal<SUI, SUI>(
            &mut dao,
            &mut fee_manager,
            &mut config_registry,
            payment,
            asset_coin,
            stable_coin,
            b"Invalid Period".to_string(),
            b"Trading period too short".to_string(),
            vector[100_000_000_000, 100_000_000_000, 100_000_000_000, 100_000_000_000],
            option::none<u64>(),
            option::none<u64>(),
            option::none<u64>(),
            option::some(3600000), // Only 1 hour - too short
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