#[test_only]
module futarchy::fee_tests;

use futarchy::fee::{Self, FeeManager, FeeAdminCap};
use futarchy::futarchy_vault::{Self};
use futarchy::factory::{Self, Factory, FactoryOwnerCap};
use std::ascii;
use std::string;
use std::vector;
use sui::balance;
use sui::clock::{Self, Clock};
use sui::coin::{Self, Coin};
use sui::object;
use sui::sui::SUI;
use sui::test_scenario::{Self, Scenario};
use sui::transfer;

// Test coin type for stable coin tests
public struct USDC has drop {}
public struct USDT has drop {}

// Test constants (matching those from the fee module)
const DEFAULT_DAO_CREATION_FEE: u64 = 10_000;
const DEFAULT_PROPOSAL_CREATION_FEE_PER_OUTCOME: u64 = 1000;
const DEFAULT_VERIFICATION_FEE: u64 = 10_000;
const ADMIN: address = @0xA;
const USER: address = @0xB;

// Test initialization helper
fun test_init(): (Scenario, address) {
    let mut scenario = test_scenario::begin(ADMIN);
    test_scenario::next_tx(&mut scenario, ADMIN);
    {
        fee::create_fee_manager_for_testing(test_scenario::ctx(&mut scenario));
    };
    (scenario, ADMIN)
}

// Create a clock for testing
fun create_clock(scenario: &mut Scenario): Clock {
    test_scenario::next_tx(scenario, ADMIN);
    clock::create_for_testing(test_scenario::ctx(scenario))
}

// Helper to create SUI coins
fun mint_sui(amount: u64, ctx: &mut tx_context::TxContext): Coin<SUI> {
    coin::mint_for_testing<SUI>(amount, ctx)
}

// Helper to create USDC coins
fun mint_usdc(amount: u64, ctx: &mut tx_context::TxContext): Coin<USDC> {
    coin::mint_for_testing<USDC>(amount, ctx)
}

// Helper to create USDT coins (add this near your other mint functions)
fun mint_usdt(amount: u64, ctx: &mut tx_context::TxContext): Coin<USDT> {
    coin::mint_for_testing<USDT>(amount, ctx)
}

// Test fee manager initialization
#[test]
fun test_fee_manager_initialization() {
    let (mut scenario, admin) = test_init();
    test_scenario::next_tx(&mut scenario, admin);
    {
        let fee_manager = test_scenario::take_shared<FeeManager>(&scenario);
        let admin_cap = test_scenario::take_from_address<FeeAdminCap>(&scenario, admin);

        // Verify initial fees
        assert!(fee::get_dao_creation_fee(&fee_manager) == DEFAULT_DAO_CREATION_FEE, 0);
        assert!(fee::get_proposal_creation_fee_per_outcome(&fee_manager) == DEFAULT_PROPOSAL_CREATION_FEE_PER_OUTCOME, 0);
        assert!(fee::get_verification_fee(&fee_manager) == DEFAULT_VERIFICATION_FEE, 0);
        assert!(fee::get_sui_balance(&fee_manager) == 0, 0);

        test_scenario::return_shared(fee_manager);
        test_scenario::return_to_address(admin, admin_cap);
    };
    test_scenario::end(scenario);
}

// Test collecting DAO creation fee
#[test]
fun test_deposit_dao_creation_payment() {
    let (mut scenario, _admin) = test_init();
    let clock = create_clock(&mut scenario);

    test_scenario::next_tx(&mut scenario, USER);
    {
        let mut fee_manager = test_scenario::take_shared<FeeManager>(&scenario);
        let ctx = test_scenario::ctx(&mut scenario);
        let payment = mint_sui(DEFAULT_DAO_CREATION_FEE, ctx);

        fee::deposit_dao_creation_payment(&mut fee_manager, payment, &clock, ctx);
        assert!(fee::get_sui_balance(&fee_manager) == DEFAULT_DAO_CREATION_FEE, 0);

        test_scenario::return_shared(fee_manager);
    };

    // Clean up
    test_scenario::next_tx(&mut scenario, ADMIN);
    clock::destroy_for_testing(clock);

    test_scenario::end(scenario);
}

// Test collecting proposal creation fee
#[test]
fun test_deposit_proposal_creation_payment() {
    let (mut scenario, _admin) = test_init();
    let clock = create_clock(&mut scenario);

    test_scenario::next_tx(&mut scenario, USER);
    {
        let mut fee_manager = test_scenario::take_shared<FeeManager>(&scenario);
        let ctx = test_scenario::ctx(&mut scenario);

        let outcome_count = 3;
        let payment = mint_sui(
            DEFAULT_PROPOSAL_CREATION_FEE_PER_OUTCOME * outcome_count,
            ctx,
        );

        fee::deposit_proposal_creation_payment(&mut fee_manager, payment, outcome_count, &clock, ctx);
        assert!(
            fee::get_sui_balance(&fee_manager) == DEFAULT_PROPOSAL_CREATION_FEE_PER_OUTCOME * outcome_count,
            0,
        );

        test_scenario::return_shared(fee_manager);
    };

    // Clean up
    test_scenario::next_tx(&mut scenario, ADMIN);
    clock::destroy_for_testing(clock);

    test_scenario::end(scenario);
}

// Test collecting verification fee
#[test]
fun test_deposit_verification_payment() {
    let (mut scenario, _admin) = test_init();
    let clock = create_clock(&mut scenario);

    test_scenario::next_tx(&mut scenario, USER);
    {
        let mut fee_manager = test_scenario::take_shared<FeeManager>(&scenario);
        let ctx = test_scenario::ctx(&mut scenario);
        let payment = mint_sui(DEFAULT_VERIFICATION_FEE, ctx);

        fee::deposit_verification_payment(&mut fee_manager, payment, &clock, ctx);
        assert!(fee::get_sui_balance(&fee_manager) == DEFAULT_VERIFICATION_FEE, 0);

        test_scenario::return_shared(fee_manager);
    };

    // Clean up
    test_scenario::next_tx(&mut scenario, ADMIN);
    clock::destroy_for_testing(clock);

    test_scenario::end(scenario);
}

// Test incorrect payment amount
#[test]
#[expected_failure(abort_code = 0)] // EInvalidPayment
fun test_incorrect_payment_amount() {
    let (mut scenario, _admin) = test_init();
    let clock = create_clock(&mut scenario);

    test_scenario::next_tx(&mut scenario, USER);
    {
        let mut fee_manager = test_scenario::take_shared<FeeManager>(&scenario);
        let ctx = test_scenario::ctx(&mut scenario);
        let payment = mint_sui(DEFAULT_DAO_CREATION_FEE - 1, ctx); // One less than required

        fee::deposit_dao_creation_payment(&mut fee_manager, payment, &clock, ctx);

        test_scenario::return_shared(fee_manager);
    };

    // Clean up
    test_scenario::next_tx(&mut scenario, ADMIN);
    clock::destroy_for_testing(clock);

    test_scenario::end(scenario);
}

// Test fee withdrawal by admin
#[test]
fun test_withdraw_fees() {
    let (mut scenario, admin) = test_init();
    let clock = create_clock(&mut scenario);

    // First collect some fees
    test_scenario::next_tx(&mut scenario, USER);
    {
        let mut fee_manager = test_scenario::take_shared<FeeManager>(&scenario);
        let ctx = test_scenario::ctx(&mut scenario);
        let payment = mint_sui(DEFAULT_DAO_CREATION_FEE, ctx);

        fee::deposit_dao_creation_payment(&mut fee_manager, payment, &clock, ctx);
        test_scenario::return_shared(fee_manager);
    };

    // Admin withdraws fees
    test_scenario::next_tx(&mut scenario, admin);
    {
        let mut fee_manager = test_scenario::take_shared<FeeManager>(&scenario);
        let admin_cap = test_scenario::take_from_address<FeeAdminCap>(&scenario, admin);

        fee::withdraw_all_fees(&mut fee_manager, &admin_cap, &clock, test_scenario::ctx(&mut scenario));
        assert!(fee::get_sui_balance(&fee_manager) == 0, 0);

        test_scenario::return_shared(fee_manager);
        test_scenario::return_to_address(admin, admin_cap);
    };

    // Verify admin received the withdrawn SUI
    test_scenario::next_tx(&mut scenario, admin);
    {
        let withdrawn_coin = test_scenario::take_from_address<Coin<SUI>>(&scenario, admin);
        assert!(coin::value(&withdrawn_coin) == DEFAULT_DAO_CREATION_FEE, 0);
        test_scenario::return_to_address(admin, withdrawn_coin);
    };

    // Clean up
    test_scenario::next_tx(&mut scenario, ADMIN);
    clock::destroy_for_testing(clock);

    test_scenario::end(scenario);
}

// Test that anyone with admin cap can withdraw
#[test]
fun test_admin_cap_holder_can_withdraw() {
    let (mut scenario, admin) = test_init();
    let clock = create_clock(&mut scenario);

    // First collect some fees
    test_scenario::next_tx(&mut scenario, USER);
    {
        let mut fee_manager = test_scenario::take_shared<FeeManager>(&scenario);
        let ctx = test_scenario::ctx(&mut scenario);
        let payment = mint_sui(DEFAULT_DAO_CREATION_FEE, ctx);

        fee::deposit_dao_creation_payment(&mut fee_manager, payment, &clock, ctx);
        test_scenario::return_shared(fee_manager);
    };

    // Move admin cap to USER
    test_scenario::next_tx(&mut scenario, admin);
    {
        let admin_cap = test_scenario::take_from_address<FeeAdminCap>(&scenario, admin);
        transfer::public_transfer(admin_cap, USER);
    };

    // USER tries to withdraw with admin cap - this should succeed
    test_scenario::next_tx(&mut scenario, USER);
    {
        let mut fee_manager = test_scenario::take_shared<FeeManager>(&scenario);
        let admin_cap = test_scenario::take_from_address<FeeAdminCap>(&scenario, USER);

        // This should work since they have the cap
        fee::withdraw_all_fees(&mut fee_manager, &admin_cap, &clock, test_scenario::ctx(&mut scenario));

        test_scenario::return_shared(fee_manager);
        test_scenario::return_to_address(USER, admin_cap);
    };

    // Clean up
    test_scenario::next_tx(&mut scenario, ADMIN);
    clock::destroy_for_testing(clock);

    test_scenario::end(scenario);
}

// Test fee updates
#[test]
fun test_update_fees() {
    let (mut scenario, admin) = test_init();
    let clock = create_clock(&mut scenario);

    test_scenario::next_tx(&mut scenario, admin);
    {
        let mut fee_manager = test_scenario::take_shared<FeeManager>(&scenario);
        let admin_cap = test_scenario::take_from_address<FeeAdminCap>(&scenario, admin);

        let new_dao_fee = 20_000;
        let new_proposal_fee = 2000;
        let new_verification_fee = 15_000;

        fee::update_dao_creation_fee(&mut fee_manager, &admin_cap, new_dao_fee, &clock, test_scenario::ctx(&mut scenario));
        fee::update_proposal_creation_fee(&mut fee_manager, &admin_cap, new_proposal_fee, &clock, test_scenario::ctx(&mut scenario));
        fee::update_verification_fee(&mut fee_manager, &admin_cap, new_verification_fee, &clock, test_scenario::ctx(&mut scenario));

        assert!(fee::get_dao_creation_fee(&fee_manager) == new_dao_fee, 0);
        assert!(fee::get_proposal_creation_fee_per_outcome(&fee_manager) == new_proposal_fee, 0);
        assert!(fee::get_verification_fee(&fee_manager) == new_verification_fee, 0);

        test_scenario::return_shared(fee_manager);
        test_scenario::return_to_address(admin, admin_cap);
    };

    // Clean up
    test_scenario::next_tx(&mut scenario, ADMIN);
    clock::destroy_for_testing(clock);

    test_scenario::end(scenario);
}

// Test stable coin fee deposits - multiple stable types
#[test]
fun test_deposit_stable_fees() {
    let (mut scenario, _admin) = test_init();
    let clock = create_clock(&mut scenario);

    test_scenario::next_tx(&mut scenario, USER);
    {
        let mut fee_manager = test_scenario::take_shared<FeeManager>(&scenario);
        let ctx = test_scenario::ctx(&mut scenario);

        // Deposit USDC fees
        let usdc_amount = 100_000;
        let usdc_fees = coin::into_balance(mint_usdc(usdc_amount, ctx));
        let proposal_id = object::id_from_address(@0x123);
        fee::deposit_stable_fees(&mut fee_manager, usdc_fees, proposal_id, &clock);

        // Verify balance
        assert!(fee::get_stable_fee_balance<USDC>(&fee_manager) == usdc_amount, 0);

        test_scenario::return_shared(fee_manager);
    };

    // Deposit additional USDC fees
    test_scenario::next_tx(&mut scenario, USER);
    {
        let mut fee_manager = test_scenario::take_shared<FeeManager>(&scenario);
        let ctx = test_scenario::ctx(&mut scenario);

        // Deposit more USDC fees
        let additional_usdc = 50_000;
        let usdc_fees = coin::into_balance(mint_usdc(additional_usdc, ctx));
        let proposal_id = object::id_from_address(@0x124);
        fee::deposit_stable_fees(&mut fee_manager, usdc_fees, proposal_id, &clock);

        // Verify cumulative balance
        assert!(fee::get_stable_fee_balance<USDC>(&fee_manager) == 150_000, 0);

        test_scenario::return_shared(fee_manager);
    };

    // Deposit USDT fees
    test_scenario::next_tx(&mut scenario, USER);
    {
        let mut fee_manager = test_scenario::take_shared<FeeManager>(&scenario);
        let ctx = test_scenario::ctx(&mut scenario);

        // Deposit USDT fees
        let usdt_amount = 75_000;
        let usdt_fees = coin::into_balance(mint_usdt(usdt_amount, ctx));
        let proposal_id = object::id_from_address(@0x125);
        fee::deposit_stable_fees(&mut fee_manager, usdt_fees, proposal_id, &clock);

        // Verify balances
        assert!(fee::get_stable_fee_balance<USDC>(&fee_manager) == 150_000, 0);
        assert!(fee::get_stable_fee_balance<USDT>(&fee_manager) == usdt_amount, 0);

        test_scenario::return_shared(fee_manager);
    };

    // Clean up
    test_scenario::next_tx(&mut scenario, ADMIN);
    clock::destroy_for_testing(clock);

    test_scenario::end(scenario);
}

// Test withdrawing stable fees
#[test]
fun test_withdraw_stable_fees() {
    let (mut scenario, admin) = test_init();
    let clock = create_clock(&mut scenario);

    // First deposit some stable fees
    test_scenario::next_tx(&mut scenario, USER);
    {
        let mut fee_manager = test_scenario::take_shared<FeeManager>(&scenario);
        let ctx = test_scenario::ctx(&mut scenario);

        // Deposit USDC fees
        let usdc_amount = 200_000;
        let usdc_fees = coin::into_balance(mint_usdc(usdc_amount, ctx));
        let proposal_id = object::id_from_address(@0x130);
        fee::deposit_stable_fees(&mut fee_manager, usdc_fees, proposal_id, &clock);

        test_scenario::return_shared(fee_manager);
    };

    // Admin withdraws stable fees
    test_scenario::next_tx(&mut scenario, admin);
    {
        let mut fee_manager = test_scenario::take_shared<FeeManager>(&scenario);
        let admin_cap = test_scenario::take_from_address<FeeAdminCap>(&scenario, admin);

        fee::withdraw_stable_fees<USDC>(
            &mut fee_manager,
            &admin_cap,
            &clock,
            test_scenario::ctx(&mut scenario),
        );

        // Verify balance is zero after withdrawal
        assert!(fee::get_stable_fee_balance<USDC>(&fee_manager) == 0, 0);

        test_scenario::return_shared(fee_manager);
        test_scenario::return_to_address(admin, admin_cap);
    };

    // Verify admin received the stable coins
    test_scenario::next_tx(&mut scenario, admin);
    {
        let withdrawn_coin = test_scenario::take_from_address<Coin<USDC>>(&scenario, admin);
        assert!(coin::value(&withdrawn_coin) == 200_000, 0);
        test_scenario::return_to_address(admin, withdrawn_coin);
    };

    // Clean up
    test_scenario::next_tx(&mut scenario, ADMIN);
    clock::destroy_for_testing(clock);

    test_scenario::end(scenario);
}

// Test withdrawing empty stable fees
#[test]
fun test_withdraw_empty_stable_fees() {
    let (mut scenario, admin) = test_init();
    let clock = create_clock(&mut scenario);

    // Try to withdraw without depositing
    test_scenario::next_tx(&mut scenario, admin);
    {
        let mut fee_manager = test_scenario::take_shared<FeeManager>(&scenario);
        let admin_cap = test_scenario::take_from_address<FeeAdminCap>(&scenario, admin);

        // This should succeed but send 0 coin
        fee::withdraw_stable_fees<USDC>(
            &mut fee_manager,
            &admin_cap,
            &clock,
            test_scenario::ctx(&mut scenario),
        );

        test_scenario::return_shared(fee_manager);
        test_scenario::return_to_address(admin, admin_cap);
    };

    // Verify admin received 0 coin
    test_scenario::next_tx(&mut scenario, admin);
    {
        assert!(!test_scenario::has_most_recent_for_address<Coin<USDC>>(admin), 0);
    };

    // Clean up
    test_scenario::next_tx(&mut scenario, ADMIN);
    clock::destroy_for_testing(clock);

    test_scenario::end(scenario);
}

// Test edge case: multiple deposits and partial withdrawals
#[test]
fun test_multiple_operations() {
    let (mut scenario, admin) = test_init();
    let clock = create_clock(&mut scenario);

    // Multiple users depositing fees
    test_scenario::next_tx(&mut scenario, USER);
    {
        let mut fee_manager = test_scenario::take_shared<FeeManager>(&scenario);
        let ctx = test_scenario::ctx(&mut scenario);

        // Collect DAO creation fee
        let payment1 = mint_sui(DEFAULT_DAO_CREATION_FEE, ctx);
        fee::deposit_dao_creation_payment(&mut fee_manager, payment1, &clock, ctx);

        // Need to get a new ctx for the second payment
        let ctx = test_scenario::ctx(&mut scenario);

        // Collect proposal creation fee
        let outcome_count = 2; // Binary proposal
        let proposal_fee = DEFAULT_PROPOSAL_CREATION_FEE_PER_OUTCOME * outcome_count;
        let payment2 = mint_sui(proposal_fee, ctx);
        fee::deposit_proposal_creation_payment(&mut fee_manager, payment2, outcome_count, &clock, ctx);

        // Verify total balance
        assert!(
            fee::get_sui_balance(&fee_manager) == DEFAULT_DAO_CREATION_FEE + (DEFAULT_PROPOSAL_CREATION_FEE_PER_OUTCOME * 2),
            0,
        );

        test_scenario::return_shared(fee_manager);
    };

    // Update fees
    test_scenario::next_tx(&mut scenario, admin);
    {
        let mut fee_manager = test_scenario::take_shared<FeeManager>(&scenario);
        let admin_cap = test_scenario::take_from_address<FeeAdminCap>(&scenario, admin);

        let new_dao_fee = 15_000;
        let new_proposal_fee = 20_000;
        let new_verification_fee = 25_000;

        fee::update_dao_creation_fee(
            &mut fee_manager,
            &admin_cap,
            new_dao_fee,
            &clock,
            test_scenario::ctx(&mut scenario),
        );
        fee::update_proposal_creation_fee(
            &mut fee_manager,
            &admin_cap,
            new_proposal_fee,
            &clock,
            test_scenario::ctx(&mut scenario),
        );
        fee::update_verification_fee(
            &mut fee_manager,
            &admin_cap,
            new_verification_fee,
            &clock,
            test_scenario::ctx(&mut scenario),
        );

        test_scenario::return_shared(fee_manager);
        test_scenario::return_to_address(admin, admin_cap);
    };

    // More deposits with new fees
    test_scenario::next_tx(&mut scenario, USER);
    {
        let mut fee_manager = test_scenario::take_shared<FeeManager>(&scenario);
        let ctx = test_scenario::ctx(&mut scenario);

        // Pay with new DAO creation fee
        let payment = mint_sui(15_000, ctx);
        fee::deposit_dao_creation_payment(&mut fee_manager, payment, &clock, ctx);

        // Total should be old fees + new fee
        assert!(
            fee::get_sui_balance(&fee_manager) ==
            DEFAULT_DAO_CREATION_FEE + (DEFAULT_PROPOSAL_CREATION_FEE_PER_OUTCOME * 2) + 15_000,
            0,
        );

        test_scenario::return_shared(fee_manager);
    };

    // Admin withdraws all
    test_scenario::next_tx(&mut scenario, admin);
    {
        let mut fee_manager = test_scenario::take_shared<FeeManager>(&scenario);
        let admin_cap = test_scenario::take_from_address<FeeAdminCap>(&scenario, admin);

        fee::withdraw_all_fees(&mut fee_manager, &admin_cap, &clock, test_scenario::ctx(&mut scenario));
        assert!(fee::get_sui_balance(&fee_manager) == 0, 0);

        test_scenario::return_shared(fee_manager);
        test_scenario::return_to_address(admin, admin_cap);
    };

    // Clean up
    test_scenario::next_tx(&mut scenario, ADMIN);
    clock::destroy_for_testing(clock);

    test_scenario::end(scenario);
}

// Test monthly fee update with 6-month delay
#[test]
fun test_dao_monthly_fee_update_with_delay() {
    let (mut scenario, admin) = test_init();
    let mut clock = create_clock(&mut scenario);
    
    // Constants
    let six_months_ms: u64 = 15_552_000_000; // 6 months in milliseconds
    let initial_fee = 10_000_000; // Default monthly fee
    let new_fee = 20_000_000; // New monthly fee
    
    // First, update the monthly fee
    test_scenario::next_tx(&mut scenario, admin);
    {
        let mut fee_manager = test_scenario::take_shared<FeeManager>(&scenario);
        let admin_cap = test_scenario::take_from_address<FeeAdminCap>(&scenario, admin);
        
        // Verify initial fee
        assert!(fee::get_dao_monthly_fee(&fee_manager) == initial_fee, 0);
        assert!(fee::get_pending_dao_monthly_fee(&fee_manager).is_none(), 0);
        
        // Update the fee (sets pending fee with 6-month delay)
        fee::update_dao_monthly_fee(
            &mut fee_manager,
            &admin_cap,
            new_fee,
            &clock,
            test_scenario::ctx(&mut scenario),
        );
        
        // Verify pending fee is set
        assert!(fee::get_dao_monthly_fee(&fee_manager) == initial_fee, 1); // Current fee unchanged
        assert!(fee::get_pending_dao_monthly_fee(&fee_manager).is_some(), 2);
        assert!(*fee::get_pending_dao_monthly_fee(&fee_manager).borrow() == new_fee, 3);
        
        test_scenario::return_shared(fee_manager);
        test_scenario::return_to_address(admin, admin_cap);
    };
    
    // Try to collect fee before 6 months - should use old fee
    test_scenario::next_tx(&mut scenario, admin);
    {
        let mut fee_manager = test_scenario::take_shared<FeeManager>(&scenario);
        
        // Apply pending fee (should not apply yet)
        fee::apply_pending_fee_if_due(&mut fee_manager, &clock);
        
        // Verify old fee is still active
        assert!(fee::get_dao_monthly_fee(&fee_manager) == initial_fee, 4);
        assert!(fee::get_pending_dao_monthly_fee(&fee_manager).is_some(), 5);
        
        test_scenario::return_shared(fee_manager);
    };
    
    // Advance clock by 6 months
    clock::increment_for_testing(&mut clock, six_months_ms);
    
    // Now collect fee after 6 months - should use new fee
    test_scenario::next_tx(&mut scenario, admin);
    {
        let mut fee_manager = test_scenario::take_shared<FeeManager>(&scenario);
        
        // Apply pending fee (should apply now)
        fee::apply_pending_fee_if_due(&mut fee_manager, &clock);
        
        // Verify new fee is active and pending is cleared
        assert!(fee::get_dao_monthly_fee(&fee_manager) == new_fee, 6);
        assert!(fee::get_pending_dao_monthly_fee(&fee_manager).is_none(), 7);
        
        test_scenario::return_shared(fee_manager);
    };
    
    // Clean up
    test_scenario::next_tx(&mut scenario, ADMIN);
    clock::destroy_for_testing(clock);
    
    test_scenario::end(scenario);
}