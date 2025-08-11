#[test_only]
module futarchy::basic_flow_test;

use std::{string, ascii};
use sui::balance;
use sui::{
    test_scenario::{Self as test, ctx},
    clock::{Self, Clock},
    coin,
    sui::SUI,
};
use futarchy::{
    factory::{Self, Factory, FactoryOwnerCap},
    fee::{Self, FeeManager},
    futarchy_config::{Self, FutarchyConfig},
    futarchy_vault,
    proposal::{Self, Proposal},
    proposal_lifecycle,
    market_state::{Self},
    coin_escrow::{Self, TokenEscrow},
    swap,
    version,
};
use account_protocol::{
    account::{Self, Account},
};

// Test constants
const ADMIN: address = @0xA;
const USER: address = @0x1;

// Test stable coin
public struct STABLE has drop {}

/// Test basic factory and DAO creation flow without complex proposal/market logic
#[test]
fun test_basic_dao_creation() {
    let mut scenario = test::begin(ADMIN);
    
    // Create factory and fee manager
    test::next_tx(&mut scenario, ADMIN);
    {
        factory::create_factory(ctx(&mut scenario));
        fee::create_fee_manager_for_testing(ctx(&mut scenario));
        let clock = clock::create_for_testing(ctx(&mut scenario));
        clock::share_for_testing(clock);
    };
    
    // Add STABLE as allowed stable type
    test::next_tx(&mut scenario, ADMIN);
    {
        let mut factory = test::take_shared<Factory>(&scenario);
        let owner_cap = test::take_from_address<FactoryOwnerCap>(&scenario, ADMIN);
        let clock = test::take_shared<Clock>(&scenario);
        
        factory::add_allowed_stable_type<STABLE>(
            &mut factory,
            &owner_cap,
            &clock,
            ctx(&mut scenario),
        );
        
        test::return_shared(factory);
        test::return_to_address(ADMIN, owner_cap);
        test::return_shared(clock);
    };
    
    // Create a DAO
    test::next_tx(&mut scenario, ADMIN);
    {
        let mut factory = test::take_shared<Factory>(&scenario);
        let mut fee_manager = test::take_shared<FeeManager>(&scenario);
        let clock = test::take_shared<Clock>(&scenario);
        
        let payment = coin::mint_for_testing<SUI>(10_000, ctx(&mut scenario)); // Match DEFAULT_DAO_CREATION_FEE
        
        factory::create_dao_test<SUI, STABLE>(
            &mut factory,
            &mut fee_manager,
            payment,
            1_000_000, // min_asset_amount
            1_000_000, // min_stable_amount
            b"Test DAO".to_ascii_string(),
            b"https://test.com/icon.png".to_ascii_string(),
            1000, // review_period_ms
            70_000, // trading_period_ms (must be > twap_start_delay + 60_000)
            0, // twap_start_delay
            10, // twap_step_max
            1_000_000_000_000, // twap_initial_observation
            100_000, // twap_threshold
            30, // amm_total_fee_bps
            b"Basic test DAO".to_string(),
            2, // max_outcomes
            vector[],
            vector[],
            &clock,
            ctx(&mut scenario),
        );
        
        test::return_shared(factory);
        test::return_shared(fee_manager);
        test::return_shared(clock);
    };
    
    test::end(scenario);
}

/// Test factory owner capabilities
#[test]
fun test_factory_owner_cap() {
    let mut scenario = test::begin(ADMIN);
    
    // Create factory
    test::next_tx(&mut scenario, ADMIN);
    {
        factory::create_factory(ctx(&mut scenario));
        let clock = clock::create_for_testing(ctx(&mut scenario));
        clock::share_for_testing(clock);
    };
    
    // Verify owner cap was created
    test::next_tx(&mut scenario, ADMIN);
    {
        let owner_cap = test::take_from_address<FactoryOwnerCap>(&scenario, ADMIN);
        // Just verify we have the cap - that's sufficient
        test::return_to_address(ADMIN, owner_cap);
    };
    
    test::end(scenario);
}

/// Test fee manager initialization  
#[test]
fun test_fee_manager_init() {
    let mut scenario = test::begin(ADMIN);
    
    test::next_tx(&mut scenario, ADMIN);
    {
        fee::create_fee_manager_for_testing(ctx(&mut scenario));
    };
    
    // Verify fee manager was created and shared
    test::next_tx(&mut scenario, ADMIN);
    {
        let fee_manager = test::take_shared<FeeManager>(&scenario);
        // Just verify we can take it - means it was created successfully
        test::return_shared(fee_manager);
    };
    
    test::end(scenario);
}

/// Test full proposal lifecycle with simplified approach
#[test]
fun test_proposal_with_market() {
    let mut scenario = test::begin(ADMIN);
    
    // Setup factory and clock
    test::next_tx(&mut scenario, ADMIN);
    {
        factory::create_factory(ctx(&mut scenario));
        fee::create_fee_manager_for_testing(ctx(&mut scenario));
        let clock = clock::create_for_testing(ctx(&mut scenario));
        clock::share_for_testing(clock);
    };
    
    // Add STABLE as allowed stable type
    test::next_tx(&mut scenario, ADMIN);
    {
        let mut factory = test::take_shared<Factory>(&scenario);
        let owner_cap = test::take_from_address<FactoryOwnerCap>(&scenario, ADMIN);
        let clock = test::take_shared<Clock>(&scenario);
        
        factory::add_allowed_stable_type<STABLE>(
            &mut factory,
            &owner_cap,
            &clock,
            ctx(&mut scenario),
        );
        
        test::return_shared(factory);
        test::return_to_address(ADMIN, owner_cap);
        test::return_shared(clock);
    };
    
    // Create DAO
    test::next_tx(&mut scenario, ADMIN);
    {
        let mut factory = test::take_shared<Factory>(&scenario);
        let mut fee_manager = test::take_shared<FeeManager>(&scenario);
        let clock = test::take_shared<Clock>(&scenario);
        
        let payment = coin::mint_for_testing<SUI>(10_000, ctx(&mut scenario)); // Match DEFAULT_DAO_CREATION_FEE
        
        factory::create_dao_test<SUI, STABLE>(
            &mut factory,
            &mut fee_manager,
            payment,
            1_000_000,
            1_000_000,
            b"Test DAO".to_ascii_string(),
            b"https://test.com/icon.png".to_ascii_string(),
            1000, // short review period (minimum allowed)
            70_000, // trading period (must be > twap_start_delay + 60_000)
            0,
            1,
            1_000_000_000_000,
            100_000,
            30,
            b"Test DAO for proposals".to_string(),
            2,
            vector[],
            vector[],
            &clock,
            ctx(&mut scenario),
        );
        
        test::return_shared(factory);
        test::return_shared(fee_manager);
        test::return_shared(clock);
    };
    
    // Create a proposal with initial liquidity
    // Note: Vault is already initialized during DAO creation
    test::next_tx(&mut scenario, USER);
    {
        let account = test::take_shared<Account<FutarchyConfig>>(&scenario);
        let clock = test::take_shared<Clock>(&scenario);
        
        // Create coins for liquidity
        // For 2 outcomes with 1M min each, we provide 2M total
        // (Each outcome gets 1M when split evenly)
        let asset_coin = coin::mint_for_testing<SUI>(2_000_000, ctx(&mut scenario));
        let stable_coin = coin::mint_for_testing<STABLE>(2_000_000, ctx(&mut scenario));
        
        // Initialize a market for the proposal
        // Generate a proposal ID for testing
        let proposal_uid = object::new(ctx(&mut scenario));
        let proposal_id = object::uid_to_inner(&proposal_uid);
        object::delete(proposal_uid);
        
        let (_proposal_id, _market_state_id, _state) = proposal::initialize_market<SUI, STABLE>(
            proposal_id, // proposal_id
            object::id(&account), // dao_id
            1000, // review_period_ms (minimum allowed)
            70_000, // trading_period_ms
            1_000_000, // min_asset_liquidity
            1_000_000, // min_stable_liquidity
            0, // twap_start_delay
            1_000_000_000_000, // twap_initial_observation
            1, // twap_step_max
            100_000, // twap_threshold
            30, // amm_total_fee_bps
            ADMIN, // treasury_address
            b"Test Proposal".to_string(), // title
            b"Testing lifecycle".to_string(), // metadata
            vector[b"YES".to_string(), b"NO".to_string()], // initial_outcome_messages
            vector[b"Execute action".to_string(), b"No action".to_string()], // initial_outcome_details
            asset_coin, // asset_coin
            stable_coin, // stable_coin
            USER, // proposer
            false, // uses_dao_liquidity
            balance::zero<STABLE>(), // fee_escrow
            option::none(), // intent_key_for_yes
            &clock,
            ctx(&mut scenario),
        );
        
        test::return_shared(account);
        test::return_shared(clock);
    };
    
    // Verify proposal was created
    test::next_tx(&mut scenario, ADMIN);
    {
        let proposal = test::take_shared<Proposal<SUI, STABLE>>(&scenario);
        let escrow = test::take_shared<TokenEscrow<SUI, STABLE>>(&scenario);
        
        // Verify proposal exists and is in review state (STATE_REVIEW = 1)
        assert!(proposal::state(&proposal) == 1, 0);
        // MarketState is inside escrow, verify via escrow
        let market = coin_escrow::get_market_state(&escrow);
        assert!(market_state::outcome_count(market) == 2, 1);
        
        test::return_shared(proposal);
        test::return_shared(escrow);
    };
    
    // Move to trading phase using advance_state
    test::next_tx(&mut scenario, ADMIN);
    {
        let mut proposal = test::take_shared<Proposal<SUI, STABLE>>(&scenario);
        let mut escrow = test::take_shared<TokenEscrow<SUI, STABLE>>(&scenario);
        let mut clock = test::take_shared<Clock>(&scenario);
        
        // Check initial state and timestamps
        let _created_at = proposal::created_at(&proposal);
        let _review_period = proposal::get_review_period_ms(&proposal);
        assert!(proposal::state(&proposal) == 1, 30); // Should be in REVIEW initially
        
        // Advance clock past review period (1000ms review period)
        clock::increment_for_testing(&mut clock, 1001);
        
        // Use advance_state to properly transition from REVIEW to TRADING
        let state_changed = proposal::advance_state(&mut proposal, &mut escrow, &clock);
        assert!(state_changed, 10); // Verify state actually changed
        assert!(proposal::state(&proposal) == 2, 11); // Verify we're in TRADING state
        
        test::return_shared(proposal);
        test::return_shared(escrow);
        test::return_shared(clock);
    };
    
    // Trade to make outcome 1 (YES) win by pushing its price above threshold
    test::next_tx(&mut scenario, USER);
    {
        let mut proposal = test::take_shared<Proposal<SUI, STABLE>>(&scenario);
        let mut escrow = test::take_shared<TokenEscrow<SUI, STABLE>>(&scenario);
        let clock = test::take_shared<Clock>(&scenario);
        
        // Debug: Verify we're in TRADING state before swap
        assert!(proposal::state(&proposal) == 2, 20); // STATE_TRADING = 2
        
        // Buy a significant amount of outcome 1 (YES) tokens to push price up
        // This will increase the TWAP for YES above the threshold
        let stable_for_trade = coin::mint_for_testing<STABLE>(500_000, ctx(&mut scenario));
        
        // Swap stable to asset for outcome 0 (YES) to push its price up
        let (mut other_tokens, yes_token) = swap::create_and_swap_stable_to_asset(
            &mut proposal,
            &mut escrow,
            0, // outcome_idx = 0 for YES
            0, // min_amount_out = 0 (accept any amount for testing)
            stable_for_trade,
            &clock,
            ctx(&mut scenario)
        );
        
        // Transfer the YES token to USER
        transfer::public_transfer(yes_token, USER);
        
        // Transfer other outcome tokens too
        while (!other_tokens.is_empty()) {
            transfer::public_transfer(other_tokens.pop_back(), USER);
        };
        other_tokens.destroy_empty();
        
        test::return_shared(proposal);
        test::return_shared(escrow);
        test::return_shared(clock);
    };
    
    // Advance time for TWAP observations
    test::next_tx(&mut scenario, ADMIN);
    {
        let mut clock = test::take_shared<Clock>(&scenario);
        
        // Advance clock to allow TWAP to update with the new higher price
        clock::increment_for_testing(&mut clock, 10_000);
        
        test::return_shared(clock);
    };
    
    // Make another trade to update TWAP observation
    test::next_tx(&mut scenario, USER);
    {
        let mut proposal = test::take_shared<Proposal<SUI, STABLE>>(&scenario);
        let mut escrow = test::take_shared<TokenEscrow<SUI, STABLE>>(&scenario);
        let clock = test::take_shared<Clock>(&scenario);
        
        // Small trade to trigger TWAP update
        let small_stable = coin::mint_for_testing<STABLE>(1_000, ctx(&mut scenario));
        let (mut other_tokens, yes_token) = swap::create_and_swap_stable_to_asset(
            &mut proposal,
            &mut escrow,
            0, // YES outcome (index 0)
            0,
            small_stable,
            &clock,
            ctx(&mut scenario)
        );
        transfer::public_transfer(yes_token, USER);
        while (!other_tokens.is_empty()) {
            transfer::public_transfer(other_tokens.pop_back(), USER);
        };
        other_tokens.destroy_empty();
        
        test::return_shared(proposal);
        test::return_shared(escrow);
        test::return_shared(clock);
    };
    
    // Finalize market based on TWAP prices
    test::next_tx(&mut scenario, ADMIN);
    {
        let mut proposal = test::take_shared<Proposal<SUI, STABLE>>(&scenario);
        let mut escrow = test::take_shared<TokenEscrow<SUI, STABLE>>(&scenario);
        let mut clock = test::take_shared<Clock>(&scenario);
        
        // Advance clock past trading period (70_000ms trading period)
        // We're currently at ~10,101ms, need to reach 70,100ms (100ms review + 70,000ms trading)
        clock::increment_for_testing(&mut clock, 60_000);
        
        // Use advance_state to end trading properly
        let state_changed = proposal::advance_state(&mut proposal, &mut escrow, &clock);
        assert!(state_changed, 12); // Verify trading was ended
        
        // Calculate the winner based on TWAP prices
        let winning_outcome = proposal_lifecycle::calculate_winning_outcome(&mut proposal, &clock);
        
        // Finalize the proposal and market atomically
        proposal::finalize_proposal(&mut proposal, &mut escrow, winning_outcome, &clock);
        
        // Verify finalization
        let market = coin_escrow::get_market_state(&escrow);
        assert!(market_state::is_finalized(market), 2);
        assert!(proposal::is_finalized(&proposal), 3);
        
        // Verify YES won (outcome 0) due to our trading
        assert!(winning_outcome == 0, 13); // Verify YES won through trading
        
        test::return_shared(proposal);
        test::return_shared(escrow);
        test::return_shared(clock);
    };
    
    // Verify final state
    test::next_tx(&mut scenario, ADMIN);
    {
        let proposal = test::take_shared<Proposal<SUI, STABLE>>(&scenario);
        let escrow = test::take_shared<TokenEscrow<SUI, STABLE>>(&scenario);
        
        // Verify finalized state
        assert!(proposal::is_finalized(&proposal), 3);
        assert!(proposal::is_winning_outcome_set(&proposal), 4);
        
        let market = coin_escrow::get_market_state(&escrow);
        assert!(market_state::is_finalized(market), 5);
        
        test::return_shared(proposal);
        test::return_shared(escrow);
    };
    
    test::end(scenario);
}