#[test_only]
module futarchy::fee_tests {
    use futarchy::fee::{Self, FeeManager, FeeAdminCap};
    use sui::test_scenario::{Self, Scenario};
    use sui::coin::{Self, Coin};
    use sui::sui::SUI;
    use sui::clock::{Self, Clock};
    
    // Test coin type for stable coin tests
    public struct USDC has drop {}
    public struct USDT has drop {}
    
    // Test constants (matching those from the fee module)
    const DEFAULT_DAO_CREATION_FEE: u64 = 10_000;
    const DEFAULT_PROPOSAL_CREATION_FEE: u64 = 10_000;
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
            assert!(fee::get_proposal_creation_fee(&fee_manager) == DEFAULT_PROPOSAL_CREATION_FEE, 0);
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
            let payment = mint_sui(DEFAULT_PROPOSAL_CREATION_FEE, ctx);
            
            fee::deposit_proposal_creation_payment(&mut fee_manager, payment, &clock, ctx);
            assert!(fee::get_sui_balance(&fee_manager) == DEFAULT_PROPOSAL_CREATION_FEE, 0);
            
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
    
    // Test error on invalid payment
    #[test]
    #[expected_failure(abort_code = fee::EINVALID_PAYMENT)]
    fun test_invalid_payment_amount() {
        let (mut scenario, _admin) = test_init();
        let clock = create_clock(&mut scenario);
        
        test_scenario::next_tx(&mut scenario, USER);
        {
            let mut fee_manager = test_scenario::take_shared<FeeManager>(&scenario);
            let ctx = test_scenario::ctx(&mut scenario);
            // Wrong amount (less than required)
            let payment = mint_sui(DEFAULT_DAO_CREATION_FEE - 1, ctx);
            
            fee::deposit_dao_creation_payment(&mut fee_manager, payment, &clock, ctx);
            
            test_scenario::return_shared(fee_manager);
        };
        
        // Clean up
        test_scenario::next_tx(&mut scenario, ADMIN);
        clock::destroy_for_testing(clock);
        
        test_scenario::end(scenario);
    }
    
    // Test updating DAO creation fee
    #[test]
    fun test_update_dao_creation_fee() {
        let (mut scenario, admin) = test_init();
        let clock = create_clock(&mut scenario);
        let new_fee = 20_000;
        
        test_scenario::next_tx(&mut scenario, admin);
        {
            let mut fee_manager = test_scenario::take_shared<FeeManager>(&scenario);
            let admin_cap = test_scenario::take_from_address<FeeAdminCap>(&scenario, admin);
            
            fee::update_dao_creation_fee(&mut fee_manager, &admin_cap, new_fee, &clock, test_scenario::ctx(&mut scenario));
            assert!(fee::get_dao_creation_fee(&fee_manager) == new_fee, 0);
            
            test_scenario::return_shared(fee_manager);
            test_scenario::return_to_address(admin, admin_cap);
        };
        
        // Clean up
        test_scenario::next_tx(&mut scenario, ADMIN);
                clock::destroy_for_testing(clock);
        
        test_scenario::end(scenario);
    }
    
    // Test updating proposal creation fee
    #[test]
    fun test_update_proposal_creation_fee() {
        let (mut scenario, admin) = test_init();
        let clock = create_clock(&mut scenario);
        let new_fee = 20_000;
        
        test_scenario::next_tx(&mut scenario, admin);
        {
            let mut fee_manager = test_scenario::take_shared<FeeManager>(&scenario);
            let admin_cap = test_scenario::take_from_address<FeeAdminCap>(&scenario, admin);
            
            fee::update_proposal_creation_fee(&mut fee_manager, &admin_cap, new_fee, &clock, test_scenario::ctx(&mut scenario));
            assert!(fee::get_proposal_creation_fee(&fee_manager) == new_fee, 0);
            
            test_scenario::return_shared(fee_manager);
            test_scenario::return_to_address(admin, admin_cap);
        };
        
        // Clean up
        test_scenario::next_tx(&mut scenario, ADMIN);
                clock::destroy_for_testing(clock);
        
        test_scenario::end(scenario);
    }
    
    // Test updating verification fee
    #[test]
    fun test_update_verification_fee() {
        let (mut scenario, admin) = test_init();
        let clock = create_clock(&mut scenario);
        let new_fee = 20_000;
        
        test_scenario::next_tx(&mut scenario, admin);
        {
            let mut fee_manager = test_scenario::take_shared<FeeManager>(&scenario);
            let admin_cap = test_scenario::take_from_address<FeeAdminCap>(&scenario, admin);
            
            fee::update_verification_fee(&mut fee_manager, &admin_cap, new_fee, &clock, test_scenario::ctx(&mut scenario));
            assert!(fee::get_verification_fee(&fee_manager) == new_fee, 0);
            
            test_scenario::return_shared(fee_manager);
            test_scenario::return_to_address(admin, admin_cap);
        };
        
        // Clean up
        test_scenario::next_tx(&mut scenario, ADMIN);
                clock::destroy_for_testing(clock);
        
        test_scenario::end(scenario);
    }
    
    // Test withdrawing SUI fees
    #[test]
    fun test_withdraw_fees() {
        let ( mut scenario, admin) = test_init();
        let clock = create_clock(&mut scenario);
        
        // First, collect some fees
        test_scenario::next_tx(&mut scenario, USER);
        {
            let mut fee_manager = test_scenario::take_shared<FeeManager>(&scenario);
            let ctx = test_scenario::ctx(&mut scenario);
            let payment = mint_sui(DEFAULT_DAO_CREATION_FEE, ctx);
            
            fee::deposit_dao_creation_payment(&mut fee_manager, payment, &clock, ctx);
            assert!(fee::get_sui_balance(&fee_manager) == DEFAULT_DAO_CREATION_FEE, 0);
            
            test_scenario::return_shared(fee_manager);
        };
        
        // Now withdraw the fees
        test_scenario::next_tx(&mut scenario, admin);
        {
            let mut fee_manager = test_scenario::take_shared<FeeManager>(&scenario);
            let admin_cap = test_scenario::take_from_address<FeeAdminCap>(&scenario, admin);
            
            // Before withdrawal, there are fees
            assert!(fee::get_sui_balance(&fee_manager) == DEFAULT_DAO_CREATION_FEE, 0);
            
            fee::withdraw_all_fees(&mut fee_manager, &admin_cap, &clock, test_scenario::ctx(&mut scenario));
            
            // After withdrawal, balance should be 0
            assert!(fee::get_sui_balance(&fee_manager) == 0, 0);
            
            test_scenario::return_shared(fee_manager);
            test_scenario::return_to_address(admin, admin_cap);
        };
        
        // Clean up
        test_scenario::next_tx(&mut scenario, ADMIN);
                clock::destroy_for_testing(clock);
        
        test_scenario::end(scenario);
    }
    
    // Test depositing stable fees
    #[test]
    fun test_deposit_stable_fees() {
        let ( mut scenario, _admin) = test_init();
        let clock = create_clock(&mut scenario);
        
        test_scenario::next_tx(&mut scenario, USER);
        {
            let mut fee_manager = test_scenario::take_shared<FeeManager>(&scenario);
            let ctx = test_scenario::ctx(&mut scenario);
            
            // Create a test proposal ID
            let id = object::id_from_address(@0xABC);
            
            let usdc = mint_usdc(1000, ctx);
            let usdc_balance = coin::into_balance(usdc);
            
            // Deposit USDC fees
            fee::deposit_stable_fees<USDC>(&mut fee_manager, usdc_balance, id, &clock);
            
            // Verify balance
            assert!(fee::get_stable_fee_balance<USDC>(&fee_manager) == 1000, 0);
            
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
        let ( mut scenario, admin) = test_init();
        let clock = create_clock(&mut scenario);
        
        // First, deposit some stable fees
        test_scenario::next_tx(&mut scenario, USER);
        {
            let mut fee_manager = test_scenario::take_shared<FeeManager>(&scenario);
            let ctx = test_scenario::ctx(&mut scenario);
            
            // Create a test proposal ID
            let id = object::id_from_address(@0xABC);
            
            let usdc = mint_usdc(1000, ctx);
            let usdc_balance = coin::into_balance(usdc);
            
            fee::deposit_stable_fees<USDC>(&mut fee_manager, usdc_balance, id, &clock);
            test_scenario::return_shared(fee_manager);
        };
        
        // Now withdraw the stable fees
        test_scenario::next_tx(&mut scenario, admin);
        {
            let mut fee_manager = test_scenario::take_shared<FeeManager>(&scenario);
            let admin_cap = test_scenario::take_from_address<FeeAdminCap>(&scenario, admin);
            
            fee::withdraw_stable_fees<USDC>(&mut fee_manager, &admin_cap, &clock, test_scenario::ctx(&mut scenario));
            
            // Verify balance is now 0
            assert!(fee::get_stable_fee_balance<USDC>(&fee_manager) == 0, 0);
            
            test_scenario::return_shared(fee_manager);
            test_scenario::return_to_address(admin, admin_cap);
        };
        
        // Check admin received the USDC
        test_scenario::next_tx(&mut scenario, admin);
        {
            let usdc_coins = test_scenario::take_from_address<Coin<USDC>>(&scenario, admin);
            assert!(coin::value(&usdc_coins) == 1000, 0);
            test_scenario::return_to_address(admin, usdc_coins);
        };
        
        // Clean up
        test_scenario::next_tx(&mut scenario, ADMIN);
                clock::destroy_for_testing(clock);
        
        test_scenario::end(scenario);
    }
    
    // Test error on nonexistent stable type
    #[test]
    #[expected_failure(abort_code = fee::ESTABLE_TYPE_NOT_FOUND)]
    fun test_withdraw_nonexistent_stable_fees() {
        let ( mut scenario, admin) = test_init();
        let clock = create_clock(&mut scenario);
        
        test_scenario::next_tx(&mut scenario, admin);
        {
            let mut fee_manager = test_scenario::take_shared<FeeManager>(&scenario);
            let admin_cap = test_scenario::take_from_address<FeeAdminCap>(&scenario, admin);
            
            // Try to withdraw USDC when none has been deposited
            fee::withdraw_stable_fees<USDC>(&mut fee_manager, &admin_cap, &clock, test_scenario::ctx(&mut scenario));
            
            test_scenario::return_shared(fee_manager);
            test_scenario::return_to_address(admin, admin_cap);
        };
        
        // Clean up
        test_scenario::next_tx(&mut scenario, ADMIN);
                clock::destroy_for_testing(clock);
        
        test_scenario::end(scenario);
    }
    
    // Test multiple deposit and withdraw operations
    #[test]
    fun test_multiple_operations() {
        let ( mut scenario, admin) = test_init();
        let clock = create_clock(&mut scenario);
        
        // Collect multiple types of fees
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
            let payment2 = mint_sui(DEFAULT_PROPOSAL_CREATION_FEE, ctx);
            fee::deposit_proposal_creation_payment(&mut fee_manager, payment2, &clock, ctx);
            
            // Verify total balance
            assert!(fee::get_sui_balance(&fee_manager) == DEFAULT_DAO_CREATION_FEE + DEFAULT_PROPOSAL_CREATION_FEE, 0);
            
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
            
            fee::update_dao_creation_fee(&mut fee_manager, &admin_cap, new_dao_fee, &clock, test_scenario::ctx(&mut scenario));
            fee::update_proposal_creation_fee(&mut fee_manager, &admin_cap, new_proposal_fee, &clock, test_scenario::ctx(&mut scenario));
            fee::update_verification_fee(&mut fee_manager, &admin_cap, new_verification_fee, &clock, test_scenario::ctx(&mut scenario));
            
            assert!(fee::get_dao_creation_fee(&fee_manager) == new_dao_fee, 0);
            assert!(fee::get_proposal_creation_fee(&fee_manager) == new_proposal_fee, 0);
            assert!(fee::get_verification_fee(&fee_manager) == new_verification_fee, 0);
            
            test_scenario::return_shared(fee_manager);
            test_scenario::return_to_address(admin, admin_cap);
        };
        
        // Withdraw fees
        test_scenario::next_tx(&mut scenario, admin);
        {
            let mut fee_manager = test_scenario::take_shared<FeeManager>(&scenario);
            let admin_cap = test_scenario::take_from_address<FeeAdminCap>(&scenario, admin);
            
            fee::withdraw_all_fees(&mut fee_manager, &admin_cap, &clock, test_scenario::ctx(&mut scenario));
            assert!(fee::get_sui_balance(&fee_manager) == 0, 0);
            
            test_scenario::return_shared(fee_manager);
            test_scenario::return_to_address(admin, admin_cap);
        };
        
        // Add some stable fees and withdraw them
        test_scenario::next_tx(&mut scenario, USER);
        {
            let mut fee_manager = test_scenario::take_shared<FeeManager>(&scenario);
            let ctx = test_scenario::ctx(&mut scenario);
            
            // Create a test proposal ID
            let id = object::id_from_address(@0xABC);
            
            let usdc = mint_usdc(5000, ctx);
            let usdc_balance = coin::into_balance(usdc);
            
            fee::deposit_stable_fees<USDC>(&mut fee_manager, usdc_balance, id, &clock);
            test_scenario::return_shared(fee_manager);
        };
        
        test_scenario::next_tx(&mut scenario, admin);
        {
            let mut fee_manager = test_scenario::take_shared<FeeManager>(&scenario);
            let admin_cap = test_scenario::take_from_address<FeeAdminCap>(&scenario, admin);
            
            fee::withdraw_stable_fees<USDC>(&mut fee_manager, &admin_cap, &clock, test_scenario::ctx(&mut scenario));
            assert!(fee::get_stable_fee_balance<USDC>(&fee_manager) == 0, 0);
            
            test_scenario::return_shared(fee_manager);
            test_scenario::return_to_address(admin, admin_cap);
        };
        
        // Clean up
        test_scenario::next_tx(&mut scenario, ADMIN);
        clock::destroy_for_testing(clock);
        
        test_scenario::end(scenario);
    }

    #[test]
    fun test_multiple_stable_coin_types() {
        let (mut scenario, admin) = test_init();
        let clock = create_clock(&mut scenario);
        
        // Deposit both USDC and USDT
        test_scenario::next_tx(&mut scenario, USER);
        {
            let mut fee_manager = test_scenario::take_shared<FeeManager>(&scenario);
            let ctx = test_scenario::ctx(&mut scenario);
            
            let id = object::id_from_address(@0xABC);
            
            // Deposit USDC
            let usdc = mint_usdc(1000, ctx);
            let usdc_balance = coin::into_balance(usdc);
            fee::deposit_stable_fees<USDC>(&mut fee_manager, usdc_balance, id, &clock);
            
            // Need to get a new ctx for the second minting
            let ctx = test_scenario::ctx(&mut scenario);
            
            // Deposit USDT
            let usdt = mint_usdt(2000, ctx);
            let usdt_balance = coin::into_balance(usdt);
            fee::deposit_stable_fees<USDT>(&mut fee_manager, usdt_balance, id, &clock);
            
            // Verify both balances
            assert!(fee::get_stable_fee_balance<USDC>(&fee_manager) == 1000, 0);
            assert!(fee::get_stable_fee_balance<USDT>(&fee_manager) == 2000, 0);
            
            test_scenario::return_shared(fee_manager);
        };
        
        // Withdraw both types of stable fees
        test_scenario::next_tx(&mut scenario, admin);
        {
            let mut fee_manager = test_scenario::take_shared<FeeManager>(&scenario);
            let admin_cap = test_scenario::take_from_address<FeeAdminCap>(&scenario, admin);
            
            // Withdraw USDC
            fee::withdraw_stable_fees<USDC>(&mut fee_manager, &admin_cap, &clock, test_scenario::ctx(&mut scenario));
            assert!(fee::get_stable_fee_balance<USDC>(&fee_manager) == 0, 0);
            
            // Withdraw USDT
            fee::withdraw_stable_fees<USDT>(&mut fee_manager, &admin_cap, &clock, test_scenario::ctx(&mut scenario));
            assert!(fee::get_stable_fee_balance<USDT>(&fee_manager) == 0, 0);
            
            test_scenario::return_shared(fee_manager);
            test_scenario::return_to_address(admin, admin_cap);
        };
        
        // Verify admin received both coin types
        test_scenario::next_tx(&mut scenario, admin);
        {
            let usdc_coins = test_scenario::take_from_address<Coin<USDC>>(&scenario, admin);
            let usdt_coins = test_scenario::take_from_address<Coin<USDT>>(&scenario, admin);
            
            assert!(coin::value(&usdc_coins) == 1000, 0);
            assert!(coin::value(&usdt_coins) == 2000, 0);
            
            test_scenario::return_to_address(admin, usdc_coins);
            test_scenario::return_to_address(admin, usdt_coins);
        };
        
        // Clean up
        test_scenario::next_tx(&mut scenario, ADMIN);
        clock::destroy_for_testing(clock);
        
        test_scenario::end(scenario);
    }

    #[test]
    fun test_zero_balance_withdraw() {
        let (mut scenario, admin) = test_init();
        let clock = create_clock(&mut scenario);
        
        // First deposit some stable fees
        test_scenario::next_tx(&mut scenario, USER);
        {
            let mut fee_manager = test_scenario::take_shared<FeeManager>(&scenario);
            let ctx = test_scenario::ctx(&mut scenario);
            
            let id = object::id_from_address(@0xABC);
            let usdc = mint_usdc(1000, ctx);
            let usdc_balance = coin::into_balance(usdc);
            
            fee::deposit_stable_fees<USDC>(&mut fee_manager, usdc_balance, id, &clock);
            test_scenario::return_shared(fee_manager);
        };
        
        // Withdraw all stable fees
        test_scenario::next_tx(&mut scenario, admin);
        {
            let mut fee_manager = test_scenario::take_shared<FeeManager>(&scenario);
            let admin_cap = test_scenario::take_from_address<FeeAdminCap>(&scenario, admin);
            
            fee::withdraw_stable_fees<USDC>(&mut fee_manager, &admin_cap, &clock, test_scenario::ctx(&mut scenario));
            assert!(fee::get_stable_fee_balance<USDC>(&fee_manager) == 0, 0);
            
            test_scenario::return_shared(fee_manager);
            test_scenario::return_to_address(admin, admin_cap);
        };
        
        // Try to withdraw again when balance is already zero
        // This should work without errors (just not transfer any coins)
        test_scenario::next_tx(&mut scenario, admin);
        {
            let mut fee_manager = test_scenario::take_shared<FeeManager>(&scenario);
            let admin_cap = test_scenario::take_from_address<FeeAdminCap>(&scenario, admin);
            
            // This should be a no-op since balance is already zero
            fee::withdraw_stable_fees<USDC>(&mut fee_manager, &admin_cap, &clock, test_scenario::ctx(&mut scenario));
            assert!(fee::get_stable_fee_balance<USDC>(&fee_manager) == 0, 0);
            
            test_scenario::return_shared(fee_manager);
            test_scenario::return_to_address(admin, admin_cap);
        };
        
        // Clean up
        test_scenario::next_tx(&mut scenario, ADMIN);
        clock::destroy_for_testing(clock);
        
        test_scenario::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = fee::EINVALID_PAYMENT)]
    fun test_payment_amount_too_large() {
        let (mut scenario, _admin) = test_init();
        let clock = create_clock(&mut scenario);
        
        test_scenario::next_tx(&mut scenario, USER);
        {
            let mut fee_manager = test_scenario::take_shared<FeeManager>(&scenario);
            let ctx = test_scenario::ctx(&mut scenario);
            
            // Too much payment (more than required)
            let payment = mint_sui(DEFAULT_DAO_CREATION_FEE + 100, ctx);
            
            // This should fail because payment amount > required fee
            fee::deposit_dao_creation_payment(&mut fee_manager, payment, &clock, ctx);
            
            test_scenario::return_shared(fee_manager);
        };
        
        // Clean up
        test_scenario::next_tx(&mut scenario, ADMIN);
        clock::destroy_for_testing(clock);
        
        test_scenario::end(scenario);
    }
}