#[test_only]
module futarchy::capability_manager_tests;

use sui::{
    test_scenario::{Self as test, Scenario, next_tx, ctx},
    coin::{Self, TreasuryCap, Coin},
    clock::{Self, Clock},
    test_utils::assert_eq,
};
use futarchy::{
    capability_manager::{Self, CapabilityManager},
    execution_context::{Self, ProposalExecutionContext},
};

// Test coin type
#[test_only]
public struct TestAssetCoin has drop {}

const ADMIN: address = @0xAD;
const USER1: address = @0x1;
const USER2: address = @0x2;

fun setup_capability_manager(scenario: &mut Scenario): ID {
    next_tx(scenario, ADMIN);
    {
        let manager_id = capability_manager::initialize(ctx(scenario));
        manager_id
    }
}

fun setup_with_treasury_cap(scenario: &mut Scenario) {
    let _manager_id = setup_capability_manager(scenario);
    
    // Create clock with non-zero timestamp
    next_tx(scenario, ADMIN);
    {
        let mut clock = clock::create_for_testing(ctx(scenario));
        clock::set_for_testing(&mut clock, 1000); // Set to 1 second
        clock::share_for_testing(clock);
    };
    
    // Create and deposit TreasuryCap
    next_tx(scenario, USER1);
    {
        let mut manager = test::take_shared<CapabilityManager>(scenario);
        let clock = test::take_shared<Clock>(scenario);
        
        // Create treasury cap for testing
        let treasury_cap = coin::create_treasury_cap_for_testing<TestAssetCoin>(ctx(scenario));
        
        // Create rules
        let rules = capability_manager::new_mint_burn_rules(
            option::some(1_000_000), // max_supply: 1M tokens
            true, // can_mint
            true, // can_burn
            option::some(100_000), // max_mint_per_proposal: 100k
            3600000, // mint_cooldown_ms: 1 hour
        );
        
        capability_manager::deposit_capability<TestAssetCoin>(
            &mut manager,
            treasury_cap,
            rules,
            &clock,
            ctx(scenario)
        );
        
        test::return_shared(manager);
        test::return_shared(clock);
    };
}

#[test]
fun test_initialize_capability_manager() {
    let mut scenario = test::begin(ADMIN);
    let manager_id = setup_capability_manager(&mut scenario);
    
    // Verify manager was created
    next_tx(&mut scenario, ADMIN);
    {
        let manager = test::take_shared<CapabilityManager>(&scenario);
        assert!(object::id(&manager) == manager_id, 0);
        test::return_shared(manager);
    };
    
    test::end(scenario);
}

#[test]
fun test_deposit_capability() {
    let mut scenario = test::begin(ADMIN);
    setup_with_treasury_cap(&mut scenario);
    
    // Verify capability was deposited
    next_tx(&mut scenario, ADMIN);
    {
        let manager = test::take_shared<CapabilityManager>(&scenario);
        assert!(capability_manager::has_capability<TestAssetCoin>(&manager), 0);
        
        // Capability was deposited successfully (has_capability already checked this)
        
        // Check supply info
        let (total_minted, total_burned, max_supply) = capability_manager::get_supply_info<TestAssetCoin>(&manager);
        assert_eq(total_minted, 0);
        assert_eq(total_burned, 0);
        assert!(max_supply.is_some() && *max_supply.borrow() == 1_000_000, 3);
        
        test::return_shared(manager);
    };
    
    test::end(scenario);
}

#[test]
fun test_mint_tokens() {
    let mut scenario = test::begin(ADMIN);
    setup_with_treasury_cap(&mut scenario);
    
    // Mint tokens
    next_tx(&mut scenario, ADMIN);
    {
        let mut manager = test::take_shared<CapabilityManager>(&scenario);
        let clock = test::take_shared<Clock>(&scenario);
        
        // Create test execution context
        let proposal_id = object::id_from_address(@0x123);
        let dao_id = object::id_from_address(@0x456);
        let execution_context = execution_context::create_for_testing(
            proposal_id,
            0, // outcome
            dao_id
        );
        
        capability_manager::mint_tokens<TestAssetCoin>(
            &mut manager,
            &execution_context,
            50_000, // Mint 50k tokens
            USER2, // Recipient
            &clock,
            ctx(&mut scenario)
        );
        
        test::return_shared(manager);
        test::return_shared(clock);
    };
    
    // Verify tokens were minted
    next_tx(&mut scenario, USER2);
    {
        let minted_coin = test::take_from_sender<Coin<TestAssetCoin>>(&scenario);
        assert_eq(coin::value(&minted_coin), 50_000);
        test::return_to_sender(&scenario, minted_coin);
        
        // Check updated supply info
        let manager = test::take_shared<CapabilityManager>(&scenario);
        let (total_minted, total_burned, _) = capability_manager::get_supply_info<TestAssetCoin>(&manager);
        assert_eq(total_minted, 50_000);
        assert_eq(total_burned, 0);
        
        test::return_shared(manager);
    };
    
    test::end(scenario);
}

#[test]
fun test_burn_tokens() {
    let mut scenario = test::begin(ADMIN);
    setup_with_treasury_cap(&mut scenario);
    
    // First mint some tokens
    next_tx(&mut scenario, ADMIN);
    {
        let mut manager = test::take_shared<CapabilityManager>(&scenario);
        let clock = test::take_shared<Clock>(&scenario);
        
        // Create test execution context
        let proposal_id = object::id_from_address(@0x124);
        let dao_id = object::id_from_address(@0x456);
        let execution_context = execution_context::create_for_testing(
            proposal_id,
            0, // outcome
            dao_id
        );
        
        capability_manager::mint_tokens<TestAssetCoin>(
            &mut manager,
            &execution_context,
            100_000,
            USER2,
            &clock,
            ctx(&mut scenario)
        );
        
        test::return_shared(manager);
        test::return_shared(clock);
    };
    
    // Burn tokens
    next_tx(&mut scenario, USER2);
    {
        let mut manager = test::take_shared<CapabilityManager>(&scenario);
        let mut coin_to_burn = test::take_from_sender<Coin<TestAssetCoin>>(&scenario);
        let burn_coin = coin::split(&mut coin_to_burn, 30_000, ctx(&mut scenario));
        
        // Create test execution context for burn
        let proposal_id = object::id_from_address(@0x125);
        let dao_id = object::id_from_address(@0x456);
        let execution_context = execution_context::create_for_testing(
            proposal_id,
            0, // outcome
            dao_id
        );
        
        capability_manager::burn_tokens<TestAssetCoin>(
            &mut manager,
            &execution_context,
            burn_coin,
            ctx(&mut scenario)
        );
        
        // Return remaining coins
        test::return_to_sender(&scenario, coin_to_burn);
        
        // Check updated supply info
        let (total_minted, total_burned, _) = capability_manager::get_supply_info<TestAssetCoin>(&manager);
        assert_eq(total_minted, 100_000);
        assert_eq(total_burned, 30_000);
        
        test::return_shared(manager);
    };
    
    test::end(scenario);
}

#[test]
#[expected_failure(abort_code = capability_manager::EExceedsMaxMintPerProposal)]
fun test_mint_exceeds_max_supply() {
    let mut scenario = test::begin(ADMIN);
    setup_with_treasury_cap(&mut scenario);
    
    // Try to mint more than max supply
    next_tx(&mut scenario, ADMIN);
    {
        let mut manager = test::take_shared<CapabilityManager>(&scenario);
        let clock = test::take_shared<Clock>(&scenario);
        // Create test execution context
        let proposal_id = object::id_from_address(@0x201);
        let dao_id = object::id_from_address(@0x456);
        let execution_context = execution_context::create_for_testing(
            proposal_id,
            0, // outcome
            dao_id
        );
        
        // Should fail - exceeds max supply of 1M
        capability_manager::mint_tokens<TestAssetCoin>(
            &mut manager,
            &execution_context,
            1_500_000, // Exceeds max supply
            USER2,
            &clock,
            ctx(&mut scenario)
        );
        
        test::return_shared(manager);
        test::return_shared(clock);
    };
    
    test::end(scenario);
}

#[test]
#[expected_failure(abort_code = capability_manager::EExceedsMaxMintPerProposal)]
fun test_mint_exceeds_per_proposal_limit() {
    let mut scenario = test::begin(ADMIN);
    setup_with_treasury_cap(&mut scenario);
    
    // Try to mint more than per-proposal limit
    next_tx(&mut scenario, ADMIN);
    {
        let mut manager = test::take_shared<CapabilityManager>(&scenario);
        let clock = test::take_shared<Clock>(&scenario);
        // Create test execution context
        let proposal_id = object::id_from_address(@0x202);
        let dao_id = object::id_from_address(@0x456);
        let execution_context = execution_context::create_for_testing(
            proposal_id,
            0, // outcome
            dao_id
        );
        
        // Should fail - exceeds per-proposal limit of 100k
        capability_manager::mint_tokens<TestAssetCoin>(
            &mut manager,
            &execution_context,
            150_000, // Exceeds per-proposal limit
            USER2,
            &clock,
            ctx(&mut scenario)
        );
        
        test::return_shared(manager);
        test::return_shared(clock);
    };
    
    test::end(scenario);
}

#[test]
#[expected_failure(abort_code = capability_manager::EMintCooldownNotMet)]
fun test_mint_cooldown_not_met() {
    let mut scenario = test::begin(ADMIN);
    setup_with_treasury_cap(&mut scenario);
    
    // First mint
    next_tx(&mut scenario, ADMIN);
    {
        let mut manager = test::take_shared<CapabilityManager>(&scenario);
        let clock = test::take_shared<Clock>(&scenario);
        // Create test execution context
        let proposal_id = object::id_from_address(@0x0c8);
        let dao_id = object::id_from_address(@0x456);
        let execution_context = execution_context::create_for_testing(
            proposal_id,
            0, // outcome
            dao_id
        );
        
        capability_manager::mint_tokens<TestAssetCoin>(
            &mut manager,
            &execution_context,
            50_000,
            USER2,
            &clock,
            ctx(&mut scenario)
        );
        
        test::return_shared(manager);
        test::return_shared(clock);
    };
    
    // Try to mint again immediately (should fail due to cooldown)
    next_tx(&mut scenario, ADMIN);
    {
        let mut manager = test::take_shared<CapabilityManager>(&scenario);
        let clock = test::take_shared<Clock>(&scenario);
        // Create test execution context with different proposal ID
        let proposal_id = object::id_from_address(@0x203);
        let dao_id = object::id_from_address(@0x456);
        let execution_context = execution_context::create_for_testing(
            proposal_id,
            0, // outcome
            dao_id
        );
        
        // Should fail - cooldown period not met
        capability_manager::mint_tokens<TestAssetCoin>(
            &mut manager,
            &execution_context,
            10_000,
            USER2,
            &clock,
            ctx(&mut scenario)
        );
        
        test::return_shared(manager);
        test::return_shared(clock);
    };
    
    test::end(scenario);
}

#[test]
fun test_mint_after_cooldown() {
    let mut scenario = test::begin(ADMIN);
    setup_with_treasury_cap(&mut scenario);
    
    // First mint
    next_tx(&mut scenario, ADMIN);
    {
        let mut manager = test::take_shared<CapabilityManager>(&scenario);
        let clock = test::take_shared<Clock>(&scenario);
        // Create test execution context
        let proposal_id = object::id_from_address(@0x0c9);
        let dao_id = object::id_from_address(@0x456);
        let execution_context = execution_context::create_for_testing(
            proposal_id,
            0, // outcome
            dao_id
        );
        
        capability_manager::mint_tokens<TestAssetCoin>(
            &mut manager,
            &execution_context,
            50_000,
            USER2,
            &clock,
            ctx(&mut scenario)
        );
        
        test::return_shared(manager);
        test::return_shared(clock);
    };
    
    // Advance time past cooldown period
    next_tx(&mut scenario, ADMIN);
    {
        let mut clock = test::take_shared<Clock>(&scenario);
        clock::increment_for_testing(&mut clock, 3600001); // 1 hour + 1ms
        test::return_shared(clock);
    };
    
    // Second mint after cooldown
    next_tx(&mut scenario, ADMIN);
    {
        let mut manager = test::take_shared<CapabilityManager>(&scenario);
        let clock = test::take_shared<Clock>(&scenario);
        // Create test execution context with different proposal ID
        let proposal_id = object::id_from_address(@0x204);
        let dao_id = object::id_from_address(@0x456);
        let execution_context = execution_context::create_for_testing(
            proposal_id,
            0, // outcome
            dao_id
        );
        
        // Should succeed - cooldown period met
        capability_manager::mint_tokens<TestAssetCoin>(
            &mut manager,
            &execution_context,
            30_000,
            USER2,
            &clock,
            ctx(&mut scenario)
        );
        
        // Check total minted
        let (total_minted, _, _) = capability_manager::get_supply_info<TestAssetCoin>(&manager);
        assert_eq(total_minted, 80_000); // 50k + 30k
        
        test::return_shared(manager);
        test::return_shared(clock);
    };
    
    test::end(scenario);
}

#[test]
#[expected_failure(abort_code = capability_manager::EMintDisabled)]
fun test_mint_when_disabled() {
    let mut scenario = test::begin(ADMIN);
    let _manager_id = setup_capability_manager(&mut scenario);
    
    // Create clock
    next_tx(&mut scenario, ADMIN);
    {
        let clock = clock::create_for_testing(ctx(&mut scenario));
        clock::share_for_testing(clock);
    };
    
    // Deposit capability with minting disabled
    next_tx(&mut scenario, USER1);
    {
        let mut manager = test::take_shared<CapabilityManager>(&scenario);
        let clock = test::take_shared<Clock>(&scenario);
        let treasury_cap = coin::create_treasury_cap_for_testing<TestAssetCoin>(ctx(&mut scenario));
        
        let rules = capability_manager::new_mint_burn_rules(
            option::none(),
            false, // can_mint = false
            true,
            option::none(),
            0,
        );
        
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
    
    // Try to mint (should fail)
    next_tx(&mut scenario, ADMIN);
    {
        let mut manager = test::take_shared<CapabilityManager>(&scenario);
        let clock = test::take_shared<Clock>(&scenario);
        // Create test execution context
        let proposal_id = object::id_from_address(@0x0ca);
        let dao_id = object::id_from_address(@0x456);
        let execution_context = execution_context::create_for_testing(
            proposal_id,
            0, // outcome
            dao_id
        );
        
        capability_manager::mint_tokens<TestAssetCoin>(
            &mut manager,
            &execution_context,
            1000,
            USER2,
            &clock,
            ctx(&mut scenario)
        );
        
        test::return_shared(manager);
        test::return_shared(clock);
    };
    
    test::end(scenario);
}

#[test]
#[expected_failure(abort_code = capability_manager::EBurnDisabled)]
fun test_burn_when_disabled() {
    let mut scenario = test::begin(ADMIN);
    let _manager_id = setup_capability_manager(&mut scenario);
    
    // Create clock
    next_tx(&mut scenario, ADMIN);
    {
        let clock = clock::create_for_testing(ctx(&mut scenario));
        clock::share_for_testing(clock);
    };
    
    // Deposit capability with burning disabled
    next_tx(&mut scenario, USER1);
    {
        let mut manager = test::take_shared<CapabilityManager>(&scenario);
        let clock = test::take_shared<Clock>(&scenario);
        let treasury_cap = coin::create_treasury_cap_for_testing<TestAssetCoin>(ctx(&mut scenario));
        
        let rules = capability_manager::new_mint_burn_rules(
            option::none(),
            true,
            false, // can_burn = false
            option::none(),
            0,
        );
        
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
    
    // Mint some tokens first
    next_tx(&mut scenario, ADMIN);
    {
        let mut manager = test::take_shared<CapabilityManager>(&scenario);
        let clock = test::take_shared<Clock>(&scenario);
        // Create test execution context
        let proposal_id = object::id_from_address(@0x0cb);
        let dao_id = object::id_from_address(@0x456);
        let execution_context = execution_context::create_for_testing(
            proposal_id,
            0, // outcome
            dao_id
        );
        
        capability_manager::mint_tokens<TestAssetCoin>(
            &mut manager,
            &execution_context,
            1000,
            USER2,
            &clock,
            ctx(&mut scenario)
        );
        
        test::return_shared(manager);
        test::return_shared(clock);
    };
    
    // Try to burn (should fail)
    next_tx(&mut scenario, USER2);
    {
        let mut manager = test::take_shared<CapabilityManager>(&scenario);
        let coin_to_burn = test::take_from_sender<Coin<TestAssetCoin>>(&scenario);
        
        // Create test execution context for burn
        let proposal_id = object::id_from_address(@0x205);
        let dao_id = object::id_from_address(@0x456);
        let execution_context = execution_context::create_for_testing(
            proposal_id,
            0, // outcome
            dao_id
        );
        
        capability_manager::burn_tokens<TestAssetCoin>(
            &mut manager,
            &execution_context,
            coin_to_burn,
            ctx(&mut scenario)
        );
        
        test::return_shared(manager);
    };
    
    test::end(scenario);
}

#[test]
#[expected_failure(abort_code = capability_manager::ECapabilityAlreadyExists)]
fun test_duplicate_capability_deposit() {
    let mut scenario = test::begin(ADMIN);
    setup_with_treasury_cap(&mut scenario);
    
    // Try to deposit another capability for the same coin type
    next_tx(&mut scenario, USER2);
    {
        let mut manager = test::take_shared<CapabilityManager>(&scenario);
        let clock = test::take_shared<Clock>(&scenario);
        let treasury_cap = coin::create_treasury_cap_for_testing<TestAssetCoin>(ctx(&mut scenario));
        
        let rules = capability_manager::new_mint_burn_rules(
            option::none(),
            true,
            true,
            option::none(),
            0,
        );
        
        // Should fail - capability already exists
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
    
    test::end(scenario);
}