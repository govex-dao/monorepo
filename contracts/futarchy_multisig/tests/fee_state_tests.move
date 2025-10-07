/// Comprehensive tests for fee_state.move
/// Tests fee initialization, checking, payment marking, and grace periods
#[test_only]
module futarchy_multisig::fee_state_tests {
    use sui::test_scenario::{Self as ts};
    use sui::test_utils::assert_eq;
    use sui::clock::{Self, Clock};
    use account_protocol::account::Account;
    use account_extensions::extensions;
    use futarchy_multisig::weighted_multisig::{Self, WeightedMultisig};
    use futarchy_multisig::fee_state;

    // === Test Addresses ===
    const ADMIN: address = @0xAD;
    const ALICE: address = @0xA1;

    // === Constants (from fee_state.move) ===
    const MONTHLY_FEE_PERIOD_MS: u64 = 2_592_000_000; // 30 days
    const GRACE_PERIOD_MS: u64 = 432_000_000; // 5 days

    // === Helper Functions ===

    fun create_test_multisig(scenario: &mut ts::Scenario): Account<WeightedMultisig> {
        let members = vector[ALICE];
        let weights = vector[100u128];

        weighted_multisig::new(
            members,
            weights,
            extensions::empty(ts::ctx(scenario)),
            ts::ctx(scenario)
        )
    }

    // === Init Fee State Tests ===

    #[test]
    fun test_init_fee_state() {
        let mut scenario = ts::begin(ADMIN);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));

        clock.set_for_testing(1000000);

        let mut account = create_test_multisig(&mut scenario);

        fee_state::init_fee_state(&mut account, &clock);

        // Verify fees are current (should have grace period)
        assert!(fee_state::are_fees_current(&account, &clock));

        // Get fee info
        let (last_payment, paid_until) = fee_state::get_fee_info(&account);
        assert_eq(last_payment, 1000000);
        assert_eq(paid_until, 1000000 + MONTHLY_FEE_PERIOD_MS + GRACE_PERIOD_MS);

        weighted_multisig::destroy_for_testing(account);
        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    fun test_init_fee_state_different_times() {
        let mut scenario = ts::begin(ADMIN);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));

        // Test at time 0
        clock.set_for_testing(0);
        let mut account1 = create_test_multisig(&mut scenario);
        fee_state::init_fee_state(&mut account1, &clock);

        let (last_payment1, paid_until1) = fee_state::get_fee_info(&account1);
        assert_eq(last_payment1, 0);
        assert_eq(paid_until1, MONTHLY_FEE_PERIOD_MS + GRACE_PERIOD_MS);

        // Test at later time
        clock.set_for_testing(5000000);
        let mut account2 = create_test_multisig(&mut scenario);
        fee_state::init_fee_state(&mut account2, &clock);

        let (last_payment2, paid_until2) = fee_state::get_fee_info(&account2);
        assert_eq(last_payment2, 5000000);
        assert_eq(paid_until2, 5000000 + MONTHLY_FEE_PERIOD_MS + GRACE_PERIOD_MS);

        weighted_multisig::destroy_for_testing(account1);
        weighted_multisig::destroy_for_testing(account2);
        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    // === Assert Fees Current Tests ===

    #[test]
    fun test_assert_fees_current_within_period() {
        let mut scenario = ts::begin(ADMIN);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));

        clock.set_for_testing(1000000);
        let mut account = create_test_multisig(&mut scenario);
        fee_state::init_fee_state(&mut account, &clock);

        // Should pass - within grace period
        fee_state::assert_fees_current(&account, &clock);

        // Move forward but still within grace period
        clock.set_for_testing(1000000 + MONTHLY_FEE_PERIOD_MS);
        fee_state::assert_fees_current(&account, &clock);

        // At edge of grace period
        clock.set_for_testing(1000000 + MONTHLY_FEE_PERIOD_MS + GRACE_PERIOD_MS);
        fee_state::assert_fees_current(&account, &clock);

        weighted_multisig::destroy_for_testing(account);
        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = fee_state::EFeeOverdue)]
    fun test_assert_fees_current_overdue() {
        let mut scenario = ts::begin(ADMIN);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));

        clock.set_for_testing(1000000);
        let mut account = create_test_multisig(&mut scenario);
        fee_state::init_fee_state(&mut account, &clock);

        // Move past grace period
        clock.set_for_testing(1000000 + MONTHLY_FEE_PERIOD_MS + GRACE_PERIOD_MS + 1);

        // Should fail
        fee_state::assert_fees_current(&account, &clock);

        weighted_multisig::destroy_for_testing(account);
        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    // === Mark Fees Paid Tests ===

    #[test]
    fun test_mark_fees_paid_single_period() {
        let mut scenario = ts::begin(ADMIN);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));

        clock.set_for_testing(1000000);
        let mut account = create_test_multisig(&mut scenario);
        fee_state::init_fee_state(&mut account, &clock);

        // Pay 1 month
        clock.set_for_testing(2000000);
        fee_state::mark_fees_paid(&mut account, 1, &clock);

        let (last_payment, paid_until) = fee_state::get_fee_info(&account);
        assert_eq(last_payment, 2000000);
        assert_eq(paid_until, 2000000 + MONTHLY_FEE_PERIOD_MS + GRACE_PERIOD_MS);

        weighted_multisig::destroy_for_testing(account);
        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    fun test_mark_fees_paid_multiple_periods() {
        let mut scenario = ts::begin(ADMIN);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));

        clock.set_for_testing(1000000);
        let mut account = create_test_multisig(&mut scenario);
        fee_state::init_fee_state(&mut account, &clock);

        // Pay 3 months at once
        clock.set_for_testing(2000000);
        fee_state::mark_fees_paid(&mut account, 3, &clock);

        let (last_payment, paid_until) = fee_state::get_fee_info(&account);
        assert_eq(last_payment, 2000000);
        // Should be extended by 3 months + grace period
        assert_eq(paid_until, 2000000 + (3 * MONTHLY_FEE_PERIOD_MS) + GRACE_PERIOD_MS);

        // Verify fees are still current much later
        clock.set_for_testing(2000000 + (2 * MONTHLY_FEE_PERIOD_MS));
        assert!(fee_state::are_fees_current(&account, &clock));

        weighted_multisig::destroy_for_testing(account);
        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    fun test_mark_fees_paid_zero_periods() {
        let mut scenario = ts::begin(ADMIN);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));

        clock.set_for_testing(1000000);
        let mut account = create_test_multisig(&mut scenario);
        fee_state::init_fee_state(&mut account, &clock);

        let (before_payment, before_until) = fee_state::get_fee_info(&account);

        // Mark 0 periods paid (edge case)
        clock.set_for_testing(2000000);
        fee_state::mark_fees_paid(&mut account, 0, &clock);

        let (after_payment, after_until) = fee_state::get_fee_info(&account);
        // Last payment should update to current time
        assert_eq(after_payment, 2000000);
        // But paid_until should only extend by grace period (0 periods)
        assert_eq(after_until, 2000000 + GRACE_PERIOD_MS);

        weighted_multisig::destroy_for_testing(account);
        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    fun test_mark_fees_paid_many_periods() {
        let mut scenario = ts::begin(ADMIN);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));

        clock.set_for_testing(1000000);
        let mut account = create_test_multisig(&mut scenario);
        fee_state::init_fee_state(&mut account, &clock);

        // Pay 12 months (1 year)
        clock.set_for_testing(2000000);
        fee_state::mark_fees_paid(&mut account, 12, &clock);

        let (last_payment, paid_until) = fee_state::get_fee_info(&account);
        assert_eq(paid_until, 2000000 + (12 * MONTHLY_FEE_PERIOD_MS) + GRACE_PERIOD_MS);

        // Verify still current 6 months later
        clock.set_for_testing(2000000 + (6 * MONTHLY_FEE_PERIOD_MS));
        assert!(fee_state::are_fees_current(&account, &clock));

        weighted_multisig::destroy_for_testing(account);
        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    // === Are Fees Current Tests ===

    #[test]
    fun test_are_fees_current_true() {
        let mut scenario = ts::begin(ADMIN);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));

        clock.set_for_testing(1000000);
        let mut account = create_test_multisig(&mut scenario);
        fee_state::init_fee_state(&mut account, &clock);

        // Initially true
        assert!(fee_state::are_fees_current(&account, &clock));

        // Still true within period
        clock.set_for_testing(1000000 + (MONTHLY_FEE_PERIOD_MS / 2));
        assert!(fee_state::are_fees_current(&account, &clock));

        // True at exact edge of grace period
        clock.set_for_testing(1000000 + MONTHLY_FEE_PERIOD_MS + GRACE_PERIOD_MS);
        assert!(fee_state::are_fees_current(&account, &clock));

        weighted_multisig::destroy_for_testing(account);
        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    fun test_are_fees_current_false() {
        let mut scenario = ts::begin(ADMIN);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));

        clock.set_for_testing(1000000);
        let mut account = create_test_multisig(&mut scenario);
        fee_state::init_fee_state(&mut account, &clock);

        // Move past grace period
        clock.set_for_testing(1000000 + MONTHLY_FEE_PERIOD_MS + GRACE_PERIOD_MS + 1);
        assert!(!fee_state::are_fees_current(&account, &clock));

        // Still false even further in the future
        clock.set_for_testing(1000000 + (2 * MONTHLY_FEE_PERIOD_MS));
        assert!(!fee_state::are_fees_current(&account, &clock));

        weighted_multisig::destroy_for_testing(account);
        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    // === Get Fee Info Tests ===

    #[test]
    fun test_get_fee_info_after_init() {
        let mut scenario = ts::begin(ADMIN);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));

        clock.set_for_testing(5000000);
        let mut account = create_test_multisig(&mut scenario);
        fee_state::init_fee_state(&mut account, &clock);

        let (last_payment, paid_until) = fee_state::get_fee_info(&account);
        assert_eq(last_payment, 5000000);
        assert_eq(paid_until, 5000000 + MONTHLY_FEE_PERIOD_MS + GRACE_PERIOD_MS);

        weighted_multisig::destroy_for_testing(account);
        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    fun test_get_fee_info_after_payment() {
        let mut scenario = ts::begin(ADMIN);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));

        clock.set_for_testing(1000000);
        let mut account = create_test_multisig(&mut scenario);
        fee_state::init_fee_state(&mut account, &clock);

        // Make payment
        clock.set_for_testing(2000000);
        fee_state::mark_fees_paid(&mut account, 2, &clock);

        let (last_payment, paid_until) = fee_state::get_fee_info(&account);
        assert_eq(last_payment, 2000000);
        assert_eq(paid_until, 2000000 + (2 * MONTHLY_FEE_PERIOD_MS) + GRACE_PERIOD_MS);

        weighted_multisig::destroy_for_testing(account);
        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    // === Integration Tests ===

    #[test]
    fun test_payment_sequence() {
        let mut scenario = ts::begin(ADMIN);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));

        // Create multisig at T=0
        clock.set_for_testing(0);
        let mut account = create_test_multisig(&mut scenario);
        fee_state::init_fee_state(&mut account, &clock);

        // After 1 month, pay for 1 month
        clock.set_for_testing(MONTHLY_FEE_PERIOD_MS);
        fee_state::mark_fees_paid(&mut account, 1, &clock);
        assert!(fee_state::are_fees_current(&account, &clock));

        // After another month, pay for 1 month again
        clock.set_for_testing(2 * MONTHLY_FEE_PERIOD_MS);
        fee_state::mark_fees_paid(&mut account, 1, &clock);
        assert!(fee_state::are_fees_current(&account, &clock));

        // After 3rd month, pay for 3 months at once
        clock.set_for_testing(3 * MONTHLY_FEE_PERIOD_MS);
        fee_state::mark_fees_paid(&mut account, 3, &clock);

        // Verify still current 2 months later
        clock.set_for_testing(5 * MONTHLY_FEE_PERIOD_MS);
        assert!(fee_state::are_fees_current(&account, &clock));

        weighted_multisig::destroy_for_testing(account);
        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    fun test_grace_period_behavior() {
        let mut scenario = ts::begin(ADMIN);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));

        clock.set_for_testing(0);
        let mut account = create_test_multisig(&mut scenario);
        fee_state::init_fee_state(&mut account, &clock);

        // At end of first month - still in grace period
        clock.set_for_testing(MONTHLY_FEE_PERIOD_MS);
        assert!(fee_state::are_fees_current(&account, &clock));

        // 1 day into grace period
        clock.set_for_testing(MONTHLY_FEE_PERIOD_MS + 86_400_000);
        assert!(fee_state::are_fees_current(&account, &clock));

        // Last moment of grace period
        clock.set_for_testing(MONTHLY_FEE_PERIOD_MS + GRACE_PERIOD_MS);
        assert!(fee_state::are_fees_current(&account, &clock));

        // 1ms past grace period
        clock.set_for_testing(MONTHLY_FEE_PERIOD_MS + GRACE_PERIOD_MS + 1);
        assert!(!fee_state::are_fees_current(&account, &clock));

        weighted_multisig::destroy_for_testing(account);
        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }
}
