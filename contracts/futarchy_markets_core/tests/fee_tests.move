/// Comprehensive test coverage for fee.move
/// Tests fee collection, admin operations, coin-specific fees, multisig fees, and all security mechanisms
#[test_only]
module futarchy_markets_core::fee_tests {
    use sui::test_scenario::{Self as test, Scenario, next_tx, ctx};
    use sui::clock::{Self, Clock};
    use sui::coin::{Self, Coin};
    use sui::sui::SUI;
    use sui::table;
    use sui::test_utils::assert_eq;
    use std::type_name;
    use futarchy_markets_core::fee::{Self, FeeManager, FeeAdminCap};
    use futarchy_core::dao_payment_tracker::{Self, DaoPaymentTracker};

    // Test coin types
    public struct USDC has drop {}
    public struct TEST_TOKEN has drop {}

    // ========== Constants ==========
    const MONTHLY_FEE_PERIOD_MS: u64 = 2_592_000_000; // 30 days
    const FEE_UPDATE_DELAY_MS: u64 = 15_552_000_000; // 6 months
    const MAX_FEE_COLLECTION_PERIOD_MS: u64 = 7_776_000_000; // 90 days
    const ABSOLUTE_MAX_MONTHLY_FEE: u64 = 10_000_000_000; // 10,000 USDC
    const MAX_FEE_MULTIPLIER: u64 = 10;
    const FEE_BASELINE_RESET_PERIOD_MS: u64 = 15_552_000_000; // 6 months

    // ========== Initialization Tests ==========

    #[test]
    fun test_fee_manager_init() {
        let mut scenario = test::begin(@0x1);

        // Init creates shared FeeManager and transfers FeeAdminCap
        fee::create_fee_manager_for_testing(ctx(&mut scenario));

        next_tx(&mut scenario, @0x1);
        {
            // Check FeeManager exists and has correct defaults
            let fee_manager = test::take_shared<FeeManager>(&scenario);

            assert_eq(fee::get_dao_creation_fee(&fee_manager), 10_000);
            assert_eq(fee::get_proposal_creation_fee_per_outcome(&fee_manager), 1_000);
            assert_eq(fee::has_verification_level(&fee_manager, 1), true);
            assert_eq(fee::get_verification_fee_for_level(&fee_manager, 1), 10_000);
            assert_eq(fee::get_dao_monthly_fee(&fee_manager), 10_000_000); // 10 USDC
            assert_eq(fee::get_recovery_fee(&fee_manager), 5_000_000_000); // 5 SUI
            assert_eq(fee::get_launchpad_creation_fee(&fee_manager), 10_000_000_000); // 10 SUI
            assert_eq(fee::get_sui_balance(&fee_manager), 0);

            test::return_shared(fee_manager);
        };

        // Check FeeAdminCap was transferred to sender
        next_tx(&mut scenario, @0x1);
        {
            assert_eq(test::has_most_recent_for_address<FeeAdminCap>(@0x1), true);
        };

        test::end(scenario);
    }

    // ========== Fee Deposit Tests ==========

    #[test]
    fun test_deposit_dao_creation_payment() {
        let mut scenario = test::begin(@0x1);
        let clock = clock::create_for_testing(ctx(&mut scenario));

        fee::create_fee_manager_for_testing(ctx(&mut scenario));

        next_tx(&mut scenario, @0x1);
        {
            let mut fee_manager = test::take_shared<FeeManager>(&scenario);
            let payment = coin::mint_for_testing<SUI>(10_000, ctx(&mut scenario));

            fee::deposit_dao_creation_payment(&mut fee_manager, payment, &clock, ctx(&mut scenario));

            assert_eq(fee::get_sui_balance(&fee_manager), 10_000);

            test::return_shared(fee_manager);
        };

        clock::destroy_for_testing(clock);
        test::end(scenario);
    }

    #[test]
    fun test_deposit_proposal_creation_payment() {
        let mut scenario = test::begin(@0x1);
        let clock = clock::create_for_testing(ctx(&mut scenario));

        fee::create_fee_manager_for_testing(ctx(&mut scenario));

        next_tx(&mut scenario, @0x1);
        {
            let mut fee_manager = test::take_shared<FeeManager>(&scenario);
            let outcome_count = 5;
            let expected_fee = 1_000 * 5; // 5,000
            let payment = coin::mint_for_testing<SUI>(expected_fee, ctx(&mut scenario));

            fee::deposit_proposal_creation_payment(&mut fee_manager, payment, outcome_count, &clock, ctx(&mut scenario));

            assert_eq(fee::get_sui_balance(&fee_manager), expected_fee);

            test::return_shared(fee_manager);
        };

        clock::destroy_for_testing(clock);
        test::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = fee::EInvalidPayment)]
    fun test_deposit_payment_wrong_amount() {
        let mut scenario = test::begin(@0x1);
        let clock = clock::create_for_testing(ctx(&mut scenario));

        fee::create_fee_manager_for_testing(ctx(&mut scenario));

        next_tx(&mut scenario, @0x1);
        {
            let mut fee_manager = test::take_shared<FeeManager>(&scenario);
            let payment = coin::mint_for_testing<SUI>(5_000, ctx(&mut scenario)); // Wrong amount

            fee::deposit_dao_creation_payment(&mut fee_manager, payment, &clock, ctx(&mut scenario));

            test::return_shared(fee_manager);
        };

        clock::destroy_for_testing(clock);
        test::end(scenario);
    }

    #[test]
    fun test_deposit_verification_payment() {
        let mut scenario = test::begin(@0x1);
        let clock = clock::create_for_testing(ctx(&mut scenario));

        fee::create_fee_manager_for_testing(ctx(&mut scenario));

        next_tx(&mut scenario, @0x1);
        {
            let mut fee_manager = test::take_shared<FeeManager>(&scenario);
            let payment = coin::mint_for_testing<SUI>(10_000, ctx(&mut scenario));

            fee::deposit_verification_payment(&mut fee_manager, payment, 1, &clock, ctx(&mut scenario));

            assert_eq(fee::get_sui_balance(&fee_manager), 10_000);

            test::return_shared(fee_manager);
        };

        clock::destroy_for_testing(clock);
        test::end(scenario);
    }

    #[test]
    fun test_deposit_recovery_payment() {
        let mut scenario = test::begin(@0x1);
        let clock = clock::create_for_testing(ctx(&mut scenario));

        fee::create_fee_manager_for_testing(ctx(&mut scenario));

        next_tx(&mut scenario, @0x1);
        {
            let mut fee_manager = test::take_shared<FeeManager>(&scenario);
            let payment = coin::mint_for_testing<SUI>(5_000_000_000, ctx(&mut scenario));
            let dao_id = object::id_from_address(@0xDA0);
            let council_id = object::id_from_address(@0xC04C11);

            fee::deposit_recovery_payment(&mut fee_manager, dao_id, council_id, payment, &clock, ctx(&mut scenario));

            assert_eq(fee::get_sui_balance(&fee_manager), 5_000_000_000);

            test::return_shared(fee_manager);
        };

        clock::destroy_for_testing(clock);
        test::end(scenario);
    }

    #[test]
    fun test_deposit_launchpad_creation_payment() {
        let mut scenario = test::begin(@0x1);
        let clock = clock::create_for_testing(ctx(&mut scenario));

        fee::create_fee_manager_for_testing(ctx(&mut scenario));

        next_tx(&mut scenario, @0x1);
        {
            let mut fee_manager = test::take_shared<FeeManager>(&scenario);
            let payment = coin::mint_for_testing<SUI>(10_000_000_000, ctx(&mut scenario));

            fee::deposit_launchpad_creation_payment(&mut fee_manager, payment, &clock, ctx(&mut scenario));

            assert_eq(fee::get_sui_balance(&fee_manager), 10_000_000_000);

            test::return_shared(fee_manager);
        };

        clock::destroy_for_testing(clock);
        test::end(scenario);
    }

    // ========== Admin Function Tests ==========

    #[test]
    fun test_withdraw_all_fees() {
        let mut scenario = test::begin(@0x1);
        let clock = clock::create_for_testing(ctx(&mut scenario));

        fee::create_fee_manager_for_testing(ctx(&mut scenario));

        next_tx(&mut scenario, @0x1);
        {
            let mut fee_manager = test::take_shared<FeeManager>(&scenario);
            let payment = coin::mint_for_testing<SUI>(100_000, ctx(&mut scenario));
            fee::deposit_dao_creation_payment(&mut fee_manager, payment, &clock, ctx(&mut scenario));
            test::return_shared(fee_manager);
        };

        next_tx(&mut scenario, @0x1);
        {
            let mut fee_manager = test::take_shared<FeeManager>(&scenario);
            let admin_cap = test::take_from_sender<FeeAdminCap>(&scenario);

            fee::withdraw_all_fees(&mut fee_manager, &admin_cap, &clock, ctx(&mut scenario));

            assert_eq(fee::get_sui_balance(&fee_manager), 0);

            test::return_to_sender(&scenario, admin_cap);
            test::return_shared(fee_manager);
        };

        // Check withdrawal was received
        next_tx(&mut scenario, @0x1);
        {
            let withdrawal = test::take_from_sender<Coin<SUI>>(&scenario);
            assert_eq(coin::value(&withdrawal), 100_000);
            test::return_to_sender(&scenario, withdrawal);
        };

        clock::destroy_for_testing(clock);
        test::end(scenario);
    }

    #[test]
    fun test_update_dao_creation_fee() {
        let mut scenario = test::begin(@0x1);
        let clock = clock::create_for_testing(ctx(&mut scenario));

        fee::create_fee_manager_for_testing(ctx(&mut scenario));

        next_tx(&mut scenario, @0x1);
        {
            let mut fee_manager = test::take_shared<FeeManager>(&scenario);
            let admin_cap = test::take_from_sender<FeeAdminCap>(&scenario);

            fee::update_dao_creation_fee(&mut fee_manager, &admin_cap, 20_000, &clock, ctx(&mut scenario));

            assert_eq(fee::get_dao_creation_fee(&fee_manager), 20_000);

            test::return_to_sender(&scenario, admin_cap);
            test::return_shared(fee_manager);
        };

        clock::destroy_for_testing(clock);
        test::end(scenario);
    }

    #[test]
    fun test_add_remove_verification_level() {
        let mut scenario = test::begin(@0x1);
        let clock = clock::create_for_testing(ctx(&mut scenario));

        fee::create_fee_manager_for_testing(ctx(&mut scenario));

        next_tx(&mut scenario, @0x1);
        {
            let mut fee_manager = test::take_shared<FeeManager>(&scenario);
            let admin_cap = test::take_from_sender<FeeAdminCap>(&scenario);

            // Add level 2
            fee::add_verification_level(&mut fee_manager, &admin_cap, 2, 50_000, &clock, ctx(&mut scenario));
            assert_eq(fee::has_verification_level(&fee_manager, 2), true);
            assert_eq(fee::get_verification_fee_for_level(&fee_manager, 2), 50_000);

            // Remove level 2
            fee::remove_verification_level(&mut fee_manager, &admin_cap, 2, &clock, ctx(&mut scenario));
            assert_eq(fee::has_verification_level(&fee_manager, 2), false);

            test::return_to_sender(&scenario, admin_cap);
            test::return_shared(fee_manager);
        };

        clock::destroy_for_testing(clock);
        test::end(scenario);
    }

    #[test]
    fun test_update_verification_fee() {
        let mut scenario = test::begin(@0x1);
        let clock = clock::create_for_testing(ctx(&mut scenario));

        fee::create_fee_manager_for_testing(ctx(&mut scenario));

        next_tx(&mut scenario, @0x1);
        {
            let mut fee_manager = test::take_shared<FeeManager>(&scenario);
            let admin_cap = test::take_from_sender<FeeAdminCap>(&scenario);

            fee::update_verification_fee(&mut fee_manager, &admin_cap, 1, 25_000, &clock, ctx(&mut scenario));

            assert_eq(fee::get_verification_fee_for_level(&fee_manager, 1), 25_000);

            test::return_to_sender(&scenario, admin_cap);
            test::return_shared(fee_manager);
        };

        clock::destroy_for_testing(clock);
        test::end(scenario);
    }

    #[test]
    fun test_update_recovery_fee() {
        let mut scenario = test::begin(@0x1);
        let clock = clock::create_for_testing(ctx(&mut scenario));

        fee::create_fee_manager_for_testing(ctx(&mut scenario));

        next_tx(&mut scenario, @0x1);
        {
            let mut fee_manager = test::take_shared<FeeManager>(&scenario);
            let admin_cap = test::take_from_sender<FeeAdminCap>(&scenario);

            fee::update_recovery_fee(&mut fee_manager, &admin_cap, 10_000_000_000, &clock, ctx(&mut scenario));

            assert_eq(fee::get_recovery_fee(&fee_manager), 10_000_000_000);

            test::return_to_sender(&scenario, admin_cap);
            test::return_shared(fee_manager);
        };

        clock::destroy_for_testing(clock);
        test::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = fee::EInvalidAdminCap)]
    fun test_admin_function_wrong_cap() {
        let mut scenario = test::begin(@0x1);
        let clock = clock::create_for_testing(ctx(&mut scenario));

        fee::create_fee_manager_for_testing(ctx(&mut scenario));

        next_tx(&mut scenario, @0x808);
        {
            let mut fee_manager = test::take_shared<FeeManager>(&scenario);
            let fake_cap = fee::create_fake_admin_cap_for_testing(ctx(&mut scenario));

            fee::update_dao_creation_fee(&mut fee_manager, &fake_cap, 20_000, &clock, ctx(&mut scenario));

            sui::test_utils::destroy(fake_cap);
            test::return_shared(fee_manager);
        };

        clock::destroy_for_testing(clock);
        test::end(scenario);
    }

    // ========== DAO Monthly Fee Tests ==========

    #[test]
    fun test_dao_monthly_fee_update_with_delay() {
        let mut scenario = test::begin(@0x1);
        let mut clock = clock::create_for_testing(ctx(&mut scenario));

        fee::create_fee_manager_for_testing(ctx(&mut scenario));

        next_tx(&mut scenario, @0x1);
        {
            let mut fee_manager = test::take_shared<FeeManager>(&scenario);
            let admin_cap = test::take_from_sender<FeeAdminCap>(&scenario);

            // Set pending fee
            fee::update_dao_monthly_fee(&mut fee_manager, &admin_cap, 20_000_000, &clock, ctx(&mut scenario));

            // Fee not applied yet
            assert_eq(fee::get_dao_monthly_fee(&fee_manager), 10_000_000);
            assert_eq(fee::get_pending_dao_monthly_fee(&fee_manager), option::some(20_000_000));

            test::return_to_sender(&scenario, admin_cap);
            test::return_shared(fee_manager);
        };

        // Advance time by 6 months
        clock::increment_for_testing(&mut clock, FEE_UPDATE_DELAY_MS);

        next_tx(&mut scenario, @0x1);
        {
            let mut fee_manager = test::take_shared<FeeManager>(&scenario);

            // Apply pending fee
            fee::apply_pending_fee_if_due(&mut fee_manager, &clock);

            // Fee now applied
            assert_eq(fee::get_dao_monthly_fee(&fee_manager), 20_000_000);
            assert_eq(fee::get_pending_dao_monthly_fee(&fee_manager), option::none());

            test::return_shared(fee_manager);
        };

        clock::destroy_for_testing(clock);
        test::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = fee::EFeeExceedsHardCap)]
    fun test_dao_monthly_fee_hard_cap() {
        let mut scenario = test::begin(@0x1);
        let clock = clock::create_for_testing(ctx(&mut scenario));

        fee::create_fee_manager_for_testing(ctx(&mut scenario));

        next_tx(&mut scenario, @0x1);
        {
            let mut fee_manager = test::take_shared<FeeManager>(&scenario);
            let admin_cap = test::take_from_sender<FeeAdminCap>(&scenario);

            // Try to set fee above hard cap
            fee::update_dao_monthly_fee(&mut fee_manager, &admin_cap, ABSOLUTE_MAX_MONTHLY_FEE + 1, &clock, ctx(&mut scenario));

            test::return_to_sender(&scenario, admin_cap);
            test::return_shared(fee_manager);
        };

        clock::destroy_for_testing(clock);
        test::end(scenario);
    }

    #[test]
    fun test_collect_dao_platform_fee_first_time() {
        let mut scenario = test::begin(@0x1);
        let clock = clock::create_for_testing(ctx(&mut scenario));

        fee::create_fee_manager_for_testing(ctx(&mut scenario));

        next_tx(&mut scenario, @0x1);
        {
            let mut fee_manager = test::take_shared<FeeManager>(&scenario);
            let dao_id = object::id_from_address(@0xDA0);

            // First collection should return (0, 0) - no retroactive fees
            let (fee_amount, periods) = fee::collect_dao_platform_fee<USDC>(&mut fee_manager, dao_id, &clock, ctx(&mut scenario));

            assert_eq(fee_amount, 0);
            assert_eq(periods, 0);

            test::return_shared(fee_manager);
        };

        clock::destroy_for_testing(clock);
        test::end(scenario);
    }

    #[test]
    fun test_collect_dao_platform_fee_one_month() {
        let mut scenario = test::begin(@0x1);
        let mut clock = clock::create_for_testing(ctx(&mut scenario));

        fee::create_fee_manager_for_testing(ctx(&mut scenario));

        let dao_id = object::id_from_address(@0xDA0);

        // First collection to create record
        next_tx(&mut scenario, @0x1);
        {
            let mut fee_manager = test::take_shared<FeeManager>(&scenario);
            fee::collect_dao_platform_fee<USDC>(&mut fee_manager, dao_id, &clock, ctx(&mut scenario));
            test::return_shared(fee_manager);
        };

        // Advance time by 1 month
        clock::increment_for_testing(&mut clock, MONTHLY_FEE_PERIOD_MS);

        next_tx(&mut scenario, @0x1);
        {
            let mut fee_manager = test::take_shared<FeeManager>(&scenario);

            let (fee_amount, periods) = fee::collect_dao_platform_fee<USDC>(&mut fee_manager, dao_id, &clock, ctx(&mut scenario));

            assert_eq(fee_amount, 10_000_000); // One month at default rate
            assert_eq(periods, 1);

            test::return_shared(fee_manager);
        };

        clock::destroy_for_testing(clock);
        test::end(scenario);
    }

    #[test]
    fun test_collect_dao_platform_fee_retroactive_cap() {
        let mut scenario = test::begin(@0x1);
        let mut clock = clock::create_for_testing(ctx(&mut scenario));

        fee::create_fee_manager_for_testing(ctx(&mut scenario));

        let dao_id = object::id_from_address(@0xDA0);

        // First collection
        next_tx(&mut scenario, @0x1);
        {
            let mut fee_manager = test::take_shared<FeeManager>(&scenario);
            fee::collect_dao_platform_fee<USDC>(&mut fee_manager, dao_id, &clock, ctx(&mut scenario));
            test::return_shared(fee_manager);
        };

        // Advance time by 6 months (way past 3 month cap)
        clock::increment_for_testing(&mut clock, 6 * MONTHLY_FEE_PERIOD_MS);

        next_tx(&mut scenario, @0x1);
        {
            let mut fee_manager = test::take_shared<FeeManager>(&scenario);

            let (fee_amount, periods) = fee::collect_dao_platform_fee<USDC>(&mut fee_manager, dao_id, &clock, ctx(&mut scenario));

            // Should cap at 3 months (90 days)
            let max_periods = MAX_FEE_COLLECTION_PERIOD_MS / MONTHLY_FEE_PERIOD_MS;
            assert_eq(periods, max_periods); // 3 periods
            assert_eq(fee_amount, 10_000_000 * max_periods); // 30M (3 months)

            test::return_shared(fee_manager);
        };

        clock::destroy_for_testing(clock);
        test::end(scenario);
    }

    #[test]
    fun test_dao_fee_retroactive_protection() {
        let mut scenario = test::begin(@0x1);
        let mut clock = clock::create_for_testing(ctx(&mut scenario));

        fee::create_fee_manager_for_testing(ctx(&mut scenario));

        let dao_id = object::id_from_address(@0xDA0);

        // First collection at old rate (10M)
        next_tx(&mut scenario, @0x1);
        {
            let mut fee_manager = test::take_shared<FeeManager>(&scenario);
            fee::collect_dao_platform_fee<USDC>(&mut fee_manager, dao_id, &clock, ctx(&mut scenario));
            test::return_shared(fee_manager);
        };

        // Admin increases fee (with delay)
        next_tx(&mut scenario, @0x1);
        {
            let mut fee_manager = test::take_shared<FeeManager>(&scenario);
            let admin_cap = test::take_from_sender<FeeAdminCap>(&scenario);

            fee::update_dao_monthly_fee(&mut fee_manager, &admin_cap, 30_000_000, &clock, ctx(&mut scenario));

            test::return_to_sender(&scenario, admin_cap);
            test::return_shared(fee_manager);
        };

        // Advance time to apply fee and accrue 1 month
        clock::increment_for_testing(&mut clock, FEE_UPDATE_DELAY_MS + MONTHLY_FEE_PERIOD_MS);

        next_tx(&mut scenario, @0x1);
        {
            let mut fee_manager = test::take_shared<FeeManager>(&scenario);

            // Apply the pending fee
            fee::apply_pending_fee_if_due(&mut fee_manager, &clock);

            // Collect - should use OLD rate (10M) for retroactive period
            let (fee_amount, periods) = fee::collect_dao_platform_fee<USDC>(&mut fee_manager, dao_id, &clock, ctx(&mut scenario));

            // DAO protected from retroactive increase
            assert_eq(fee_amount, 10_000_000); // Old rate!
            assert_eq(periods, 1);

            test::return_shared(fee_manager);
        };

        clock::destroy_for_testing(clock);
        test::end(scenario);
    }

    // ========== Coin-Specific Fee Tests ==========

    #[test]
    fun test_add_coin_fee_config() {
        let mut scenario = test::begin(@0x1);
        let clock = clock::create_for_testing(ctx(&mut scenario));

        fee::create_fee_manager_for_testing(ctx(&mut scenario));

        next_tx(&mut scenario, @0x1);
        {
            let mut fee_manager = test::take_shared<FeeManager>(&scenario);
            let admin_cap = test::take_from_sender<FeeAdminCap>(&scenario);

            let coin_type = type_name::get<USDC>();
            fee::add_coin_fee_config(
                &mut fee_manager,
                &admin_cap,
                coin_type,
                6, // decimals
                15_000_000, // monthly fee
                15_000, // creation fee
                1_500, // proposal fee
                7_500_000_000, // recovery fee
                2_000_000, // multisig creation
                500_000, // multisig monthly
                &clock,
                ctx(&mut scenario)
            );

            assert_eq(fee::get_coin_monthly_fee(&fee_manager, coin_type), 15_000_000);

            test::return_to_sender(&scenario, admin_cap);
            test::return_shared(fee_manager);
        };

        clock::destroy_for_testing(clock);
        test::end(scenario);
    }

    #[test]
    fun test_coin_fee_10x_cap() {
        let mut scenario = test::begin(@0x1);
        let mut clock = clock::create_for_testing(ctx(&mut scenario));

        fee::create_fee_manager_for_testing(ctx(&mut scenario));

        let coin_type = type_name::get<USDC>();

        // Add coin with baseline fee
        next_tx(&mut scenario, @0x1);
        {
            let mut fee_manager = test::take_shared<FeeManager>(&scenario);
            let admin_cap = test::take_from_sender<FeeAdminCap>(&scenario);

            fee::add_coin_fee_config(
                &mut fee_manager, &admin_cap, coin_type, 6,
                10_000_000, 10_000, 1_000, 5_000_000_000, 1_000_000, 250_000,
                &clock, ctx(&mut scenario)
            );

            test::return_to_sender(&scenario, admin_cap);
            test::return_shared(fee_manager);
        };

        // Try to increase to 10x (should work)
        next_tx(&mut scenario, @0x1);
        {
            let mut fee_manager = test::take_shared<FeeManager>(&scenario);
            let admin_cap = test::take_from_sender<FeeAdminCap>(&scenario);

            fee::update_coin_monthly_fee(&mut fee_manager, &admin_cap, coin_type, 100_000_000, &clock, ctx(&mut scenario));

            test::return_to_sender(&scenario, admin_cap);
            test::return_shared(fee_manager);
        };

        // Advance time to apply
        clock::increment_for_testing(&mut clock, FEE_UPDATE_DELAY_MS);

        next_tx(&mut scenario, @0x1);
        {
            let mut fee_manager = test::take_shared<FeeManager>(&scenario);

            fee::apply_pending_coin_fees(&mut fee_manager, coin_type, &clock);
            assert_eq(fee::get_coin_monthly_fee(&fee_manager, coin_type), 100_000_000);

            test::return_shared(fee_manager);
        };

        clock::destroy_for_testing(clock);
        test::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = fee::EFeeExceedsTenXCap)]
    fun test_coin_fee_exceeds_10x_cap() {
        let mut scenario = test::begin(@0x1);
        let clock = clock::create_for_testing(ctx(&mut scenario));

        fee::create_fee_manager_for_testing(ctx(&mut scenario));

        let coin_type = type_name::get<USDC>();

        // Add coin with baseline fee
        next_tx(&mut scenario, @0x1);
        {
            let mut fee_manager = test::take_shared<FeeManager>(&scenario);
            let admin_cap = test::take_from_sender<FeeAdminCap>(&scenario);

            fee::add_coin_fee_config(
                &mut fee_manager, &admin_cap, coin_type, 6,
                10_000_000, 10_000, 1_000, 5_000_000_000, 1_000_000, 250_000,
                &clock, ctx(&mut scenario)
            );

            test::return_to_sender(&scenario, admin_cap);
            test::return_shared(fee_manager);
        };

        // Try to increase beyond 10x
        next_tx(&mut scenario, @0x1);
        {
            let mut fee_manager = test::take_shared<FeeManager>(&scenario);
            let admin_cap = test::take_from_sender<FeeAdminCap>(&scenario);

            fee::update_coin_monthly_fee(&mut fee_manager, &admin_cap, coin_type, 100_000_001, &clock, ctx(&mut scenario));

            test::return_to_sender(&scenario, admin_cap);
            test::return_shared(fee_manager);
        };

        clock::destroy_for_testing(clock);
        test::end(scenario);
    }

    #[test]
    fun test_coin_fee_immediate_decrease() {
        let mut scenario = test::begin(@0x1);
        let clock = clock::create_for_testing(ctx(&mut scenario));

        fee::create_fee_manager_for_testing(ctx(&mut scenario));

        let coin_type = type_name::get<USDC>();

        // Add coin
        next_tx(&mut scenario, @0x1);
        {
            let mut fee_manager = test::take_shared<FeeManager>(&scenario);
            let admin_cap = test::take_from_sender<FeeAdminCap>(&scenario);

            fee::add_coin_fee_config(
                &mut fee_manager, &admin_cap, coin_type, 6,
                10_000_000, 10_000, 1_000, 5_000_000_000, 1_000_000, 250_000,
                &clock, ctx(&mut scenario)
            );

            test::return_to_sender(&scenario, admin_cap);
            test::return_shared(fee_manager);
        };

        // Decrease fee (should apply immediately)
        next_tx(&mut scenario, @0x1);
        {
            let mut fee_manager = test::take_shared<FeeManager>(&scenario);
            let admin_cap = test::take_from_sender<FeeAdminCap>(&scenario);

            fee::update_coin_monthly_fee(&mut fee_manager, &admin_cap, coin_type, 5_000_000, &clock, ctx(&mut scenario));

            // Fee applied immediately
            assert_eq(fee::get_coin_monthly_fee(&fee_manager, coin_type), 5_000_000);

            test::return_to_sender(&scenario, admin_cap);
            test::return_shared(fee_manager);
        };

        clock::destroy_for_testing(clock);
        test::end(scenario);
    }

    // ========== Multisig Fee Tests ==========

    #[test]
    fun test_collect_multisig_creation_fee() {
        let mut scenario = test::begin(@0x1);
        let clock = clock::create_for_testing(ctx(&mut scenario));

        fee::create_fee_manager_for_testing(ctx(&mut scenario));

        let coin_type = type_name::get<USDC>();

        // Add coin config
        next_tx(&mut scenario, @0x1);
        {
            let mut fee_manager = test::take_shared<FeeManager>(&scenario);
            let admin_cap = test::take_from_sender<FeeAdminCap>(&scenario);

            fee::add_coin_fee_config(
                &mut fee_manager, &admin_cap, coin_type, 6,
                10_000_000, 10_000, 1_000, 5_000_000_000, 2_000_000, 500_000,
                &clock, ctx(&mut scenario)
            );

            test::return_to_sender(&scenario, admin_cap);
            test::return_shared(fee_manager);
        };

        // Collect creation fee
        next_tx(&mut scenario, @0x1);
        {
            let mut fee_manager = test::take_shared<FeeManager>(&scenario);
            let dao_id = object::id_from_address(@0xDA0);
            let multisig_id = object::id_from_address(@0x3715167);
            let payment = coin::mint_for_testing<USDC>(2_000_000, ctx(&mut scenario));

            let remaining = fee::collect_multisig_creation_fee<USDC>(
                &mut fee_manager, dao_id, multisig_id, coin_type, payment, &clock, ctx(&mut scenario)
            );

            assert_eq(coin::value(&remaining), 0);
            coin::destroy_zero(remaining);

            test::return_shared(fee_manager);
        };

        clock::destroy_for_testing(clock);
        test::end(scenario);
    }

    #[test]
    fun test_multisig_forgiveness_mechanism() {
        let mut scenario = test::begin(@0x1);
        let mut clock = clock::create_for_testing(ctx(&mut scenario));

        fee::create_fee_manager_for_testing(ctx(&mut scenario));

        let usdc_type = type_name::get<USDC>();
        let test_type = type_name::get<TEST_TOKEN>();

        // Add both coin configs
        next_tx(&mut scenario, @0x1);
        {
            let mut fee_manager = test::take_shared<FeeManager>(&scenario);
            let admin_cap = test::take_from_sender<FeeAdminCap>(&scenario);

            fee::add_coin_fee_config(
                &mut fee_manager, &admin_cap, usdc_type, 6,
                10_000_000, 10_000, 1_000, 5_000_000_000, 1_000_000, 500_000,
                &clock, ctx(&mut scenario)
            );

            fee::add_coin_fee_config(
                &mut fee_manager, &admin_cap, test_type, 6,
                10_000_000, 10_000, 1_000, 5_000_000_000, 1_000_000, 500_000,
                &clock, ctx(&mut scenario)
            );

            test::return_to_sender(&scenario, admin_cap);
            test::return_shared(fee_manager);
        };

        let multisig_id = object::id_from_address(@0x3715167);
        let all_coins = vector[usdc_type, test_type];

        // First collection for USDC (creates record)
        next_tx(&mut scenario, @0x1);
        {
            let mut fee_manager = test::take_shared<FeeManager>(&scenario);
            let payment = coin::mint_for_testing<USDC>(0, ctx(&mut scenario));

            let (remaining, _periods) = fee::collect_multisig_fee<USDC>(
                &mut fee_manager, multisig_id, usdc_type, payment, all_coins, &clock, ctx(&mut scenario)
            );
            coin::destroy_zero(remaining);

            test::return_shared(fee_manager);
        };

        // Advance time by 1 month
        clock::increment_for_testing(&mut clock, MONTHLY_FEE_PERIOD_MS);

        // Pay USDC fee (forgives TEST_TOKEN debt)
        next_tx(&mut scenario, @0x1);
        {
            let mut fee_manager = test::take_shared<FeeManager>(&scenario);
            let payment = coin::mint_for_testing<USDC>(500_000, ctx(&mut scenario));

            let (remaining, periods) = fee::collect_multisig_fee<USDC>(
                &mut fee_manager, multisig_id, usdc_type, payment, all_coins, &clock, ctx(&mut scenario)
            );

            assert_eq(periods, 1);
            coin::destroy_zero(remaining);

            test::return_shared(fee_manager);
        };

        // Advance another month
        clock::increment_for_testing(&mut clock, MONTHLY_FEE_PERIOD_MS);

        // TEST_TOKEN should only owe 1 month (not 2) due to forgiveness
        next_tx(&mut scenario, @0x1);
        {
            let mut fee_manager = test::take_shared<FeeManager>(&scenario);
            let payment = coin::mint_for_testing<TEST_TOKEN>(500_000, ctx(&mut scenario));

            let (remaining, periods) = fee::collect_multisig_fee<TEST_TOKEN>(
                &mut fee_manager, multisig_id, test_type, payment, all_coins, &clock, ctx(&mut scenario)
            );

            // Should only collect 1 period (forgiveness worked)
            assert_eq(periods, 1);
            coin::destroy_zero(remaining);

            test::return_shared(fee_manager);
        };

        clock::destroy_for_testing(clock);
        test::end(scenario);
    }

    #[test]
    fun test_multisig_pause_logic() {
        let mut scenario = test::begin(@0x1);
        let mut clock = clock::create_for_testing(ctx(&mut scenario));

        fee::create_fee_manager_for_testing(ctx(&mut scenario));

        let usdc_type = type_name::get<USDC>();
        let test_type = type_name::get<TEST_TOKEN>();

        // Add both coin configs
        next_tx(&mut scenario, @0x1);
        {
            let mut fee_manager = test::take_shared<FeeManager>(&scenario);
            let admin_cap = test::take_from_sender<FeeAdminCap>(&scenario);

            fee::add_coin_fee_config(
                &mut fee_manager, &admin_cap, usdc_type, 6,
                10_000_000, 10_000, 1_000, 5_000_000_000, 1_000_000, 500_000,
                &clock, ctx(&mut scenario)
            );

            fee::add_coin_fee_config(
                &mut fee_manager, &admin_cap, test_type, 6,
                10_000_000, 10_000, 1_000, 5_000_000_000, 1_000_000, 500_000,
                &clock, ctx(&mut scenario)
            );

            test::return_to_sender(&scenario, admin_cap);
            test::return_shared(fee_manager);
        };

        let multisig_id = object::id_from_address(@0x3715167);
        let all_coins = vector[usdc_type, test_type];

        // Initialize records
        next_tx(&mut scenario, @0x1);
        {
            let mut fee_manager = test::take_shared<FeeManager>(&scenario);
            let payment1 = coin::mint_for_testing<USDC>(0, ctx(&mut scenario));
            let payment2 = coin::mint_for_testing<TEST_TOKEN>(0, ctx(&mut scenario));

            let (remaining1, _) = fee::collect_multisig_fee<USDC>(
                &mut fee_manager, multisig_id, usdc_type, payment1, all_coins, &clock, ctx(&mut scenario)
            );
            let (remaining2, _) = fee::collect_multisig_fee<TEST_TOKEN>(
                &mut fee_manager, multisig_id, test_type, payment2, all_coins, &clock, ctx(&mut scenario)
            );

            coin::destroy_zero(remaining1);
            coin::destroy_zero(remaining2);
            test::return_shared(fee_manager);
        };

        // Not paused initially
        next_tx(&mut scenario, @0x1);
        {
            let fee_manager = test::take_shared<FeeManager>(&scenario);
            assert_eq(fee::is_multisig_paused(&fee_manager, multisig_id, all_coins, &clock), false);
            test::return_shared(fee_manager);
        };

        // Advance time by 2 months (both coins overdue)
        clock::increment_for_testing(&mut clock, 2 * MONTHLY_FEE_PERIOD_MS);

        // Should be paused (ALL coins overdue)
        next_tx(&mut scenario, @0x1);
        {
            let fee_manager = test::take_shared<FeeManager>(&scenario);
            assert_eq(fee::is_multisig_paused(&fee_manager, multisig_id, all_coins, &clock), true);
            test::return_shared(fee_manager);
        };

        // Pay one coin
        next_tx(&mut scenario, @0x1);
        {
            let mut fee_manager = test::take_shared<FeeManager>(&scenario);
            let payment = coin::mint_for_testing<USDC>(1_000_000, ctx(&mut scenario));

            let (remaining, _) = fee::collect_multisig_fee<USDC>(
                &mut fee_manager, multisig_id, usdc_type, payment, all_coins, &clock, ctx(&mut scenario)
            );
            coin::destroy_zero(remaining);

            test::return_shared(fee_manager);
        };

        // No longer paused (not ALL coins overdue)
        next_tx(&mut scenario, @0x1);
        {
            let fee_manager = test::take_shared<FeeManager>(&scenario);
            assert_eq(fee::is_multisig_paused(&fee_manager, multisig_id, all_coins, &clock), false);
            test::return_shared(fee_manager);
        };

        clock::destroy_for_testing(clock);
        test::end(scenario);
    }

    // ========== Stable Fee Tests ==========

    #[test]
    fun test_deposit_and_withdraw_stable_fees() {
        let mut scenario = test::begin(@0x1);
        let clock = clock::create_for_testing(ctx(&mut scenario));

        fee::create_fee_manager_for_testing(ctx(&mut scenario));

        let proposal_id = object::id_from_address(@0x12045a1);

        // Deposit stable fees
        next_tx(&mut scenario, @0x1);
        {
            let mut fee_manager = test::take_shared<FeeManager>(&scenario);
            let stable_coin = coin::mint_for_testing<USDC>(1_000_000, ctx(&mut scenario));

            fee::deposit_stable_fees(&mut fee_manager, coin::into_balance(stable_coin), proposal_id, &clock);

            assert_eq(fee::get_stable_fee_balance<USDC>(&fee_manager), 1_000_000);

            test::return_shared(fee_manager);
        };

        // Withdraw stable fees
        next_tx(&mut scenario, @0x1);
        {
            let mut fee_manager = test::take_shared<FeeManager>(&scenario);
            let admin_cap = test::take_from_sender<FeeAdminCap>(&scenario);

            fee::withdraw_stable_fees<USDC>(&mut fee_manager, &admin_cap, &clock, ctx(&mut scenario));

            assert_eq(fee::get_stable_fee_balance<USDC>(&fee_manager), 0);

            test::return_to_sender(&scenario, admin_cap);
            test::return_shared(fee_manager);
        };

        // Check withdrawal received
        next_tx(&mut scenario, @0x1);
        {
            let withdrawal = test::take_from_sender<Coin<USDC>>(&scenario);
            assert_eq(coin::value(&withdrawal), 1_000_000);
            test::return_to_sender(&scenario, withdrawal);
        };

        clock::destroy_for_testing(clock);
        test::end(scenario);
    }

    // ========== View Function Tests ==========

    #[test]
    fun test_view_functions() {
        let mut scenario = test::begin(@0x1);
        let clock = clock::create_for_testing(ctx(&mut scenario));

        fee::create_fee_manager_for_testing(ctx(&mut scenario));

        next_tx(&mut scenario, @0x1);
        {
            let fee_manager = test::take_shared<FeeManager>(&scenario);

            // Test all view functions
            assert_eq(fee::get_dao_creation_fee(&fee_manager), 10_000);
            assert_eq(fee::get_proposal_creation_fee_per_outcome(&fee_manager), 1_000);
            assert_eq(fee::get_launchpad_creation_fee(&fee_manager), 10_000_000_000);
            assert_eq(fee::get_dao_monthly_fee(&fee_manager), 10_000_000);
            assert_eq(fee::get_recovery_fee(&fee_manager), 5_000_000_000);
            assert_eq(fee::get_sui_balance(&fee_manager), 0);
            assert_eq(fee::get_pending_dao_monthly_fee(&fee_manager), option::none());
            assert_eq(fee::get_pending_fee_effective_timestamp(&fee_manager), option::none());
            assert_eq(fee::has_verification_level(&fee_manager, 1), true);
            assert_eq(fee::get_verification_fee_for_level(&fee_manager, 1), 10_000);
            assert_eq(fee::get_max_monthly_fee_cap(), ABSOLUTE_MAX_MONTHLY_FEE);

            test::return_shared(fee_manager);
        };

        clock::destroy_for_testing(clock);
        test::end(scenario);
    }
}
