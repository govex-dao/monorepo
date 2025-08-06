#[test_only]
module futarchy::treasury_transfer_test;

use std::string::{Self, String};
use sui::{
    test_scenario::{Self as test, Scenario, ctx},
    clock::{Self, Clock},
    coin::{Self, Coin},
    sui::SUI,
    object,
};
use account_protocol::{
    account::{Self, Account},
    executable::{Self, Executable},
    intents::{Self, Intent},
};
use account_actions::{
    vault_intents,
    vault as vault_actions,
};
use futarchy::{
    futarchy_config::{Self, FutarchyConfig, FutarchyOutcome},
    factory::{Self, Factory},
    fee::{Self, FeeManager},
    proposal::{Self, Proposal},
    market_state::{Self, MarketState},
    market_tracker,
    action_dispatcher,
};
use futarchy_actions::{
    futarchy_vault,
    version as futarchy_actions_version,
};

// Test constants
const ADMIN: address = @0xA;
const USER1: address = @0x1;
const USER2: address = @0x2;
const TREASURY: address = @0x99;

const TREASURY_AMOUNT: u64 = 1_000_000_000; // 1 SUI

// Test stable coin
public struct USDC has drop {}

/// Integration test for treasury transfer flow using Account Protocol
#[test]
fun test_treasury_transfer_integration() {
    let mut scenario = test::begin(ADMIN);
    
    // Step 1: Setup factory and fee manager
    test::next_tx(&mut scenario, ADMIN);
    {
        factory::create_factory(ctx(&mut scenario));
        fee::create_fee_manager(ctx(&mut scenario));
        let clock = clock::create_for_testing(ctx(&mut scenario));
        clock::share_for_testing(clock);
    };
    
    // Step 2: Add USDC as allowed stable type
    test::next_tx(&mut scenario, ADMIN);
    {
        let mut factory = test::take_shared<Factory>(&scenario);
        let owner_cap = test::take_from_address<factory::FactoryOwnerCap>(&scenario, ADMIN);
        let clock = test::take_shared<Clock>(&scenario);
        
        factory::add_allowed_stable_type<USDC>(
            &mut factory,
            &owner_cap,
            1_000_000, // min_raise_amount
            &clock,
            ctx(&mut scenario),
        );
        
        test::return_shared(factory);
        test::return_to_address(ADMIN, owner_cap);
        test::return_shared(clock);
    };
    
    // Step 3: Create a DAO with treasury funds
    test::next_tx(&mut scenario, ADMIN);
    {
        let mut factory = test::take_shared<Factory>(&scenario);
        let mut fee_manager = test::take_shared<FeeManager>(&scenario);
        let clock = test::take_shared<Clock>(&scenario);
        
        // Create payment for DAO creation
        let payment = coin::mint_for_testing<SUI>(10_000_000, ctx(&mut scenario));
        
        // Create DAO with treasury funds (using SUI as AssetType)
        factory::create_dao_test<SUI, USDC>(
            &mut factory,
            &mut fee_manager,
            payment,
            100_000_000, // min_asset_amount
            100_000_000, // min_stable_amount
            b"Test DAO".to_ascii_string(),
            b"https://test.com/icon.png".to_ascii_string(),
            604_800_000, // review_period_ms (7 days)
            604_800_000, // trading_period_ms (7 days)
            60_000, // twap_start_delay
            10, // twap_step_max
            1_000_000_000_000, // twap_initial_observation
            100_000, // twap_threshold
            30, // amm_total_fee_bps
            b"Test DAO for treasury transfer".to_string(),
            10, // max_outcomes
            vector[],
            vector[],
            &clock,
            ctx(&mut scenario),
        );
        
        test::return_shared(factory);
        test::return_shared(fee_manager);
        test::return_shared(clock);
    };
    
    // Step 4: Get the DAO account and initialize vault
    test::next_tx(&mut scenario, ADMIN);
    {
        // Get the DAO account (should be the most recently created shared object)
        let mut account = test::take_shared<Account<FutarchyConfig>>(&scenario);
        
        // Initialize the vault
        futarchy_vault::init_vault(
            &mut account,
            ctx(&mut scenario)
        );
        
        // Deposit treasury funds into the vault
        let treasury_coin = coin::mint_for_testing<SUI>(TREASURY_AMOUNT, ctx(&mut scenario));
        futarchy_vault::deposit<SUI>(
            &mut account,
            treasury_coin,
            ctx(&mut scenario)
        );
        
        test::return_shared(account);
    };
    
    // Step 5: Create a transfer intent using Account Protocol's vault_intents
    test::next_tx(&mut scenario, USER1);
    {
        let mut account = test::take_shared<Account<FutarchyConfig>>(&scenario);
        let clock = test::take_shared<Clock>(&scenario);
        
        // Authenticate
        let auth = futarchy_config::authenticate(&account, ctx(&mut scenario));
        
        // Create intent params
        let params = intents::new_params(
            b"transfer_to_user2".to_string(),
            b"Transfer 0.5 SUI to USER2".to_string(),
            vector[clock.timestamp_ms() + 1000], // execution time
            clock.timestamp_ms() + 86_400_000, // expiration (1 day)
            &clock,
            ctx(&mut scenario)
        );
        
        // Create the FutarchyOutcome
        let outcome = FutarchyOutcome {
            proposal_id: object::id_from_address(@0x0), // dummy ID for test
            market_id: object::id_from_address(@0x0), // dummy ID for test
            approved: true,
            intent_key: b"transfer_to_user2".to_string(),
            min_execution_time: clock.timestamp_ms(),
        };
        
        // Use Account Protocol's vault_intents directly
        vault_intents::request_spend_and_transfer<FutarchyConfig, FutarchyOutcome, SUI>(
            auth,
            &mut account,
            params,
            outcome,
            b"main".to_string(), // vault name
            vector[500_000_000], // amounts (0.5 SUI)
            vector[USER2], // recipients
            ctx(&mut scenario)
        );
        
        test::return_shared(account);
        test::return_shared(clock);
    };
    
    // Step 6: Execute the intent using action_dispatcher
    test::next_tx(&mut scenario, USER1);
    {
        let mut account = test::take_shared<Account<FutarchyConfig>>(&scenario);
        let clock = test::take_shared<Clock>(&scenario);
        
        // Fast forward time to execution time
        clock::increment_for_testing(&mut clock, 2000);
        
        // Create executable from the intent
        let (outcome, executable) = account::create_executable<FutarchyConfig, FutarchyOutcome, futarchy_config::FutarchyConfigWitness>(
            &mut account,
            b"transfer_to_user2".to_string(),
            &clock,
            futarchy_actions_version::current(),
            futarchy_config::FutarchyConfigWitness {},
        );
        
        // Execute using the action dispatcher
        action_dispatcher::dispatch<futarchy_config::FutarchyConfigWitness>(
            executable,
            &mut account,
            ctx(&mut scenario)
        );
        
        // Verify outcome
        let FutarchyOutcome { proposal_id: _, market_id: _, approved: _, intent_key: _, min_execution_time: _ } = outcome;
        
        test::return_shared(account);
        test::return_shared(clock);
    };
    
    // Step 7: Verify the transfer was successful
    test::next_tx(&mut scenario, USER2);
    {
        // USER2 should have received the coin
        let coin = test::take_from_address<Coin<SUI>>(&scenario, USER2);
        assert!(coin.value() == 500_000_000, 0);
        test::return_to_address(USER2, coin);
    };
    
    // Step 8: Verify vault balance is reduced
    test::next_tx(&mut scenario, ADMIN);
    {
        let account = test::take_shared<Account<FutarchyConfig>>(&scenario);
        
        let remaining_balance = futarchy_vault::balance<FutarchyConfig, SUI>(
            &account,
            futarchy_actions_version::current()
        );
        
        assert!(remaining_balance == 500_000_000, 1); // Should have 0.5 SUI left
        
        test::return_shared(account);
    };
    
    test::end(scenario);
}

/// Test batch transfer functionality using Account Protocol
#[test]
fun test_batch_treasury_transfer() {
    let mut scenario = test::begin(ADMIN);
    
    // Setup (similar to above, abbreviated for brevity)
    setup_dao_with_treasury(&mut scenario);
    
    // Create batch transfer intent using Account Protocol
    test::next_tx(&mut scenario, USER1);
    {
        let mut account = test::take_shared<Account<FutarchyConfig>>(&scenario);
        let clock = test::take_shared<Clock>(&scenario);
        
        let auth = futarchy_config::authenticate(&account, ctx(&mut scenario));
        
        // Recipients and amounts for batch transfer
        let recipients = vector[USER1, USER2, TREASURY];
        let amounts = vector[200_000_000, 300_000_000, 100_000_000]; // Total: 0.6 SUI
        
        // Create intent params
        let params = intents::new_params(
            b"batch_transfer".to_string(),
            b"Batch transfer to multiple recipients".to_string(),
            vector[clock.timestamp_ms() + 1000],
            clock.timestamp_ms() + 86_400_000,
            &clock,
            ctx(&mut scenario)
        );
        
        let outcome = FutarchyOutcome {
            proposal_id: object::id_from_address(@0x0),
            market_id: object::id_from_address(@0x0),
            approved: true,
            intent_key: b"batch_transfer".to_string(),
            min_execution_time: clock.timestamp_ms(),
        };
        
        // Use Account Protocol's vault_intents for batch transfer
        vault_intents::request_spend_and_transfer<FutarchyConfig, FutarchyOutcome, SUI>(
            auth,
            &mut account,
            params,
            outcome,
            b"main".to_string(),
            amounts,
            recipients,
            ctx(&mut scenario)
        );
        
        test::return_shared(account);
        test::return_shared(clock);
    };
    
    // Execute batch transfer using action dispatcher
    test::next_tx(&mut scenario, USER1);
    {
        let mut account = test::take_shared<Account<FutarchyConfig>>(&scenario);
        let clock = test::take_shared<Clock>(&scenario);
        
        clock::increment_for_testing(&mut clock, 2000);
        
        let (outcome, executable) = account::create_executable<FutarchyConfig, FutarchyOutcome, futarchy_config::FutarchyConfigWitness>(
            &mut account,
            b"batch_transfer".to_string(),
            &clock,
            futarchy_actions_version::current(),
            futarchy_config::FutarchyConfigWitness {},
        );
        
        // Execute using action dispatcher
        action_dispatcher::dispatch<futarchy_config::FutarchyConfigWitness>(
            executable,
            &mut account,
            ctx(&mut scenario)
        );
        
        let FutarchyOutcome { proposal_id: _, market_id: _, approved: _, intent_key: _, min_execution_time: _ } = outcome;
        
        test::return_shared(account);
        test::return_shared(clock);
    };
    
    // Verify all recipients received their amounts
    test::next_tx(&mut scenario, USER1);
    {
        let coin = test::take_from_address<Coin<SUI>>(&scenario, USER1);
        assert!(coin.value() == 200_000_000, 0);
        test::return_to_address(USER1, coin);
    };
    
    test::next_tx(&mut scenario, USER2);
    {
        let coin = test::take_from_address<Coin<SUI>>(&scenario, USER2);
        assert!(coin.value() == 300_000_000, 0);
        test::return_to_address(USER2, coin);
    };
    
    test::next_tx(&mut scenario, TREASURY);
    {
        let coin = test::take_from_address<Coin<SUI>>(&scenario, TREASURY);
        assert!(coin.value() == 100_000_000, 0);
        test::return_to_address(TREASURY, coin);
    };
    
    test::end(scenario);
}

// Helper function to setup DAO with treasury
fun setup_dao_with_treasury(scenario: &mut Scenario) {
    // Setup factory and fee manager
    test::next_tx(scenario, ADMIN);
    {
        factory::create_factory(ctx(scenario));
        fee::create_fee_manager(ctx(scenario));
        let clock = clock::create_for_testing(ctx(scenario));
        clock::share_for_testing(clock);
    };
    
    // Add USDC as allowed stable type
    test::next_tx(scenario, ADMIN);
    {
        let mut factory = test::take_shared<Factory>(scenario);
        let owner_cap = test::take_from_address<factory::FactoryOwnerCap>(scenario, ADMIN);
        let clock = test::take_shared<Clock>(scenario);
        
        factory::add_allowed_stable_type<USDC>(
            &mut factory,
            &owner_cap,
            1_000_000,
            &clock,
            ctx(scenario),
        );
        
        test::return_shared(factory);
        test::return_to_address(ADMIN, owner_cap);
        test::return_shared(clock);
    };
    
    // Create DAO
    test::next_tx(scenario, ADMIN);
    {
        let mut factory = test::take_shared<Factory>(scenario);
        let mut fee_manager = test::take_shared<FeeManager>(scenario);
        let clock = test::take_shared<Clock>(scenario);
        
        let payment = coin::mint_for_testing<SUI>(10_000_000, ctx(scenario));
        
        factory::create_dao_test<SUI, USDC>(
            &mut factory,
            &mut fee_manager,
            payment,
            100_000_000,
            100_000_000,
            b"Test DAO".to_ascii_string(),
            b"https://test.com/icon.png".to_ascii_string(),
            604_800_000,
            604_800_000,
            60_000,
            10,
            1_000_000_000_000,
            100_000,
            30,
            b"Test DAO".to_string(),
            10,
            vector[],
            vector[],
            &clock,
            ctx(scenario),
        );
        
        test::return_shared(factory);
        test::return_shared(fee_manager);
        test::return_shared(clock);
    };
    
    // Initialize vault and deposit funds
    test::next_tx(scenario, ADMIN);
    {
        let mut account = test::take_shared<Account<FutarchyConfig>>(scenario);
        
        futarchy_vault::init_vault(
            &mut account,
            ctx(scenario)
        );
        
        let treasury_coin = coin::mint_for_testing<SUI>(TREASURY_AMOUNT, ctx(scenario));
        futarchy_vault::deposit<SUI>(
            &mut account,
            treasury_coin,
            ctx(scenario)
        );
        
        test::return_shared(account);
    };
}