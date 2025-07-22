#[test_only]
module futarchy::capability_deposit_tests;

use sui::{
    test_scenario::{Self as test, Scenario, next_tx, ctx},
    coin::{Self, TreasuryCap},
    clock::{Self, Clock},
    test_utils::assert_eq,
};
use futarchy::{
    capability_manager::{Self, CapabilityManager},
    treasury_actions::{Self, ActionRegistry},
    dao::{Self, DAO},
    fee,
    factory,
};

// Test coin types
#[test_only]
public struct TestAssetCoin has drop {}

#[test_only]
public struct TestStableCoin has drop {}

const ADMIN: address = @0xAD;
const USER1: address = @0x1;

fun setup_complete_system(scenario: &mut Scenario): ID {
    // Create clock
    next_tx(scenario, ADMIN);
    {
        let clock = clock::create_for_testing(ctx(scenario));
        clock::share_for_testing(clock);
    };

    // Create DAO factory and fee manager
    next_tx(scenario, ADMIN);
    {
        factory::create_factory(ctx(scenario));
        fee::create_fee_manager_for_testing(ctx(scenario));
    };

    // Create action registry
    next_tx(scenario, ADMIN);
    {
        treasury_actions::create_for_testing(ctx(scenario));
    };

    // Create capability manager
    next_tx(scenario, ADMIN);
    {
        let manager_id = capability_manager::initialize(ctx(scenario));
        manager_id
    };

    // Create DAO
    next_tx(scenario, ADMIN);
    {
        let mut factory = test::take_shared<factory::Factory>(scenario);
        let mut fee_manager = test::take_shared<fee::FeeManager>(scenario);
        let payment = coin::mint_for_testing<sui::sui::SUI>(10_000, ctx(scenario));
        let clock = test::take_shared<Clock>(scenario);
        
        // Add our test stable coin to allowed list
        let factory_owner_cap = test::take_from_address<factory::FactoryOwnerCap>(scenario, ADMIN);
        factory::add_allowed_stable_type<TestStableCoin>(
            &mut factory,
            &factory_owner_cap,
            &clock,
            ctx(scenario)
        );
        test::return_to_address(ADMIN, factory_owner_cap);
        
        factory::create_dao<TestAssetCoin, TestStableCoin>(
            &mut factory,
            &mut fee_manager,
            payment,
            1_000_000, // min_asset_amount
            1_000_000, // min_stable_amount
            std::ascii::string(b"Test DAO"),
            std::ascii::string(b"https://test.com/icon.png"),
            86400000, // review_period_ms
            604800000, // trading_period_ms (7 days)
            3600000, // amm_twap_start_delay (1 hour)
            10, // amm_twap_step_max
            1_000_000_000_000, // amm_twap_initial_observation
            100_000, // twap_threshold
            b"Test DAO for capability deposits".to_string(),
            3, // max_outcomes
            vector[b"Test metadata".to_string()], // metadata
            &clock,
            ctx(scenario)
        );
        
        test::return_shared(factory);
        test::return_shared(fee_manager);
        test::return_shared(clock);
    };

    // Return manager ID
    next_tx(scenario, ADMIN);
    {
        let manager = test::take_shared<CapabilityManager>(scenario);
        let id = object::id(&manager);
        test::return_shared(manager);
        id
    }
}


#[test]
fun test_capability_manager_deposit_directly() {
    let mut scenario = test::begin(ADMIN);
    let _manager_id = setup_complete_system(&mut scenario);
    
    // Test direct deposit to capability manager
    next_tx(&mut scenario, USER1);
    {
        let mut manager = test::take_shared<CapabilityManager>(&scenario);
        let clock = test::take_shared<Clock>(&scenario);
        
        // Create treasury cap
        let treasury_cap = coin::create_treasury_cap_for_testing<TestAssetCoin>(ctx(&mut scenario));
        
        // Create rules
        let rules = capability_manager::new_mint_burn_rules(
            option::some(10_000_000), // max_supply
            true, // can_mint
            true, // can_burn
            option::some(100_000), // max_mint_per_proposal
            3600000, // mint_cooldown_ms
        );
        
        // Deposit directly
        capability_manager::deposit_capability<TestAssetCoin>(
            &mut manager,
            treasury_cap,
            rules,
            &clock,
            ctx(&mut scenario)
        );
        
        test::return_shared(manager);
        test::return_shared(clock);
    };
    
    // Verify capability was deposited
    next_tx(&mut scenario, ADMIN);
    {
        let manager = test::take_shared<CapabilityManager>(&scenario);
        assert!(capability_manager::has_capability<TestAssetCoin>(&manager), 0);
        
        let (total_minted, total_burned, max_supply) = capability_manager::get_supply_info<TestAssetCoin>(&manager);
        assert_eq(total_minted, 0);
        assert_eq(total_burned, 0);
        assert!(max_supply.is_some() && *max_supply.borrow() == 10_000_000, 1);
        
        test::return_shared(manager);
    };
    
    test::end(scenario);
}


