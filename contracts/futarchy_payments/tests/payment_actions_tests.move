/// Comprehensive tests for payment_actions.move
/// Tests action construction, getters, serialization, and destruction
#[test_only]
module futarchy_payments::payment_actions_tests {
    use std::string;
    use std::option;
    use sui::test_utils::assert_eq;
    use sui::sui::SUI;
    use futarchy_payments::payment_actions;

    // === Test Addresses ===
    const ALICE: address = @0xA1;

    // === CreatePaymentAction Tests ===

    #[test]
    fun test_create_payment_action_constructor() {
        let action = payment_actions::new_create_payment_action<SUI>(
            1u8,  // payment_type
            2u8,  // source_mode
            ALICE,  // recipient
            1000u64,  // amount
            100u64,  // start_timestamp
            200u64,  // end_timestamp
            option::some(50u64),  // interval_or_cliff
            10u64,  // total_payments
            true,  // cancellable
            string::utf8(b"Test payment"),  // description
            100u64,  // max_per_withdrawal
            1000u64,  // min_interval_ms
            5u64,  // max_beneficiaries
        );

        assert_eq(payment_actions::payment_type(&action), 1u8);
        assert_eq(payment_actions::source_mode(&action), 2u8);
        assert_eq(payment_actions::recipient(&action), ALICE);
        assert_eq(payment_actions::amount(&action), 1000u64);
        assert_eq(payment_actions::start_timestamp(&action), 100u64);
        assert_eq(payment_actions::end_timestamp(&action), 200u64);
        assert_eq(payment_actions::total_payments(&action), 10u64);
        assert_eq(payment_actions::cancellable(&action), true);
        assert_eq(*payment_actions::description(&action), string::utf8(b"Test payment"));
        assert_eq(payment_actions::max_per_withdrawal(&action), 100u64);
        assert_eq(payment_actions::min_interval_ms(&action), 1000u64);
        assert_eq(payment_actions::max_beneficiaries(&action), 5u64);

        let interval = payment_actions::interval_or_cliff(&action);
        assert!(interval.is_some());
        assert_eq(*interval.borrow(), 50u64);

        payment_actions::destroy_create_payment_action(action);
    }

    #[test]
    fun test_create_payment_action_with_none_interval() {
        let action = payment_actions::new_create_payment_action<SUI>(
            1u8,  // payment_type
            2u8,  // source_mode
            ALICE,  // recipient
            1000u64,  // amount
            100u64,  // start_timestamp
            200u64,  // end_timestamp
            option::none(),  // interval_or_cliff (none)
            10u64,  // total_payments
            true,  // cancellable
            string::utf8(b"Test payment"),  // description
            100u64,  // max_per_withdrawal
            1000u64,  // min_interval_ms
            5u64,  // max_beneficiaries
        );

        let interval = payment_actions::interval_or_cliff(&action);
        assert!(interval.is_none());

        payment_actions::destroy_create_payment_action(action);
    }

    #[test]
    fun test_create_payment_action_zero_values() {
        let action = payment_actions::new_create_payment_action<SUI>(
            0u8,  // payment_type
            0u8,  // source_mode
            @0x0,  // recipient (zero address)
            0u64,  // amount (zero)
            0u64,  // start_timestamp
            0u64,  // end_timestamp
            option::none(),  // interval_or_cliff
            0u64,  // total_payments
            false,  // cancellable
            string::utf8(b""),  // empty description
            0u64,  // max_per_withdrawal
            0u64,  // min_interval_ms
            0u64,  // max_beneficiaries
        );

        assert_eq(payment_actions::payment_type(&action), 0u8);
        assert_eq(payment_actions::source_mode(&action), 0u8);
        assert_eq(payment_actions::recipient(&action), @0x0);
        assert_eq(payment_actions::amount(&action), 0u64);
        assert_eq(payment_actions::start_timestamp(&action), 0u64);
        assert_eq(payment_actions::end_timestamp(&action), 0u64);
        assert_eq(payment_actions::total_payments(&action), 0u64);
        assert_eq(payment_actions::cancellable(&action), false);
        assert_eq(*payment_actions::description(&action), string::utf8(b""));
        assert_eq(payment_actions::max_per_withdrawal(&action), 0u64);
        assert_eq(payment_actions::min_interval_ms(&action), 0u64);
        assert_eq(payment_actions::max_beneficiaries(&action), 0u64);

        payment_actions::destroy_create_payment_action(action);
    }

    #[test]
    fun test_create_payment_action_max_values() {
        let action = payment_actions::new_create_payment_action<SUI>(
            255u8,  // payment_type (max u8)
            255u8,  // source_mode (max u8)
            ALICE,  // recipient
            18446744073709551615u64,  // amount (max u64)
            18446744073709551615u64,  // start_timestamp (max u64)
            18446744073709551615u64,  // end_timestamp (max u64)
            option::some(18446744073709551615u64),  // interval_or_cliff (max u64)
            18446744073709551615u64,  // total_payments (max u64)
            true,  // cancellable
            string::utf8(b"Max values test"),  // description
            18446744073709551615u64,  // max_per_withdrawal (max u64)
            18446744073709551615u64,  // min_interval_ms (max u64)
            18446744073709551615u64,  // max_beneficiaries (max u64)
        );

        assert_eq(payment_actions::payment_type(&action), 255u8);
        assert_eq(payment_actions::source_mode(&action), 255u8);
        assert_eq(payment_actions::amount(&action), 18446744073709551615u64);

        payment_actions::destroy_create_payment_action(action);
    }

    #[test]
    fun test_create_payment_action_copy_ability() {
        let action1 = payment_actions::new_create_payment_action<SUI>(
            1u8,  // payment_type
            2u8,  // source_mode
            ALICE,  // recipient
            1000u64,  // amount
            100u64,  // start_timestamp
            200u64,  // end_timestamp
            option::some(50u64),  // interval_or_cliff
            10u64,  // total_payments
            true,  // cancellable
            string::utf8(b"Test payment"),  // description
            100u64,  // max_per_withdrawal
            1000u64,  // min_interval_ms
            5u64,  // max_beneficiaries
        );

        // Test copy ability
        let action2 = action1;

        // Both should have the same values
        assert_eq(payment_actions::payment_type(&action1), 1u8);
        assert_eq(payment_actions::payment_type(&action2), 1u8);
        assert_eq(payment_actions::amount(&action1), 1000u64);
        assert_eq(payment_actions::amount(&action2), 1000u64);

        payment_actions::destroy_create_payment_action(action1);
        payment_actions::destroy_create_payment_action(action2);
    }

    // === CancelPaymentAction Tests ===

    #[test]
    fun test_cancel_payment_action_constructor() {
        let payment_id = string::utf8(b"PAYMENT_123_T_1000");
        let action = payment_actions::new_cancel_payment_action(payment_id);

        assert_eq(*payment_actions::payment_id(&action), string::utf8(b"PAYMENT_123_T_1000"));

        payment_actions::destroy_cancel_payment_action(action);
    }

    #[test]
    fun test_cancel_payment_action_empty_id() {
        let payment_id = string::utf8(b"");
        let action = payment_actions::new_cancel_payment_action(payment_id);

        assert_eq(*payment_actions::payment_id(&action), string::utf8(b""));

        payment_actions::destroy_cancel_payment_action(action);
    }

    #[test]
    fun test_cancel_payment_action_long_id() {
        let payment_id = string::utf8(b"PAYMENT_123456789_T_1234567890_WITH_VERY_LONG_IDENTIFIER");
        let action = payment_actions::new_cancel_payment_action(payment_id);

        assert_eq(
            *payment_actions::payment_id(&action),
            string::utf8(b"PAYMENT_123456789_T_1234567890_WITH_VERY_LONG_IDENTIFIER")
        );

        payment_actions::destroy_cancel_payment_action(action);
    }

    #[test]
    fun test_cancel_payment_action_copy_ability() {
        let payment_id = string::utf8(b"PAYMENT_123_T_1000");
        let action1 = payment_actions::new_cancel_payment_action(payment_id);

        // Test copy ability
        let action2 = action1;

        // Both should have the same payment_id
        assert_eq(*payment_actions::payment_id(&action1), string::utf8(b"PAYMENT_123_T_1000"));
        assert_eq(*payment_actions::payment_id(&action2), string::utf8(b"PAYMENT_123_T_1000"));

        payment_actions::destroy_cancel_payment_action(action1);
        payment_actions::destroy_cancel_payment_action(action2);
    }

    // === Edge Case Tests ===

    #[test]
    fun test_create_payment_action_with_different_coin_types() {
        use sui::sui::SUI;

        // Test with SUI
        let action_sui = payment_actions::new_create_payment_action<SUI>(
            1u8, 2u8, ALICE, 1000u64, 100u64, 200u64,
            option::some(50u64), 10u64, true,
            string::utf8(b"SUI payment"), 100u64, 1000u64, 5u64
        );

        assert_eq(payment_actions::amount(&action_sui), 1000u64);
        payment_actions::destroy_create_payment_action(action_sui);

        // Test with different phantom type (using address as placeholder)
        public struct TestCoin has drop {}

        let action_test = payment_actions::new_create_payment_action<TestCoin>(
            1u8, 2u8, ALICE, 2000u64, 100u64, 200u64,
            option::some(50u64), 10u64, true,
            string::utf8(b"Test coin payment"), 100u64, 1000u64, 5u64
        );

        assert_eq(payment_actions::amount(&action_test), 2000u64);
        payment_actions::destroy_create_payment_action(action_test);
    }

    #[test]
    fun test_payment_actions_destruction_pattern() {
        // Test that destruction works correctly for serialize-then-destroy pattern

        let create_action = payment_actions::new_create_payment_action<SUI>(
            1u8, 2u8, ALICE, 1000u64, 100u64, 200u64,
            option::some(50u64), 10u64, true,
            string::utf8(b"Test"), 100u64, 1000u64, 5u64
        );

        let cancel_action = payment_actions::new_cancel_payment_action(
            string::utf8(b"PAYMENT_123")
        );

        // Destroy both without issues
        payment_actions::destroy_create_payment_action(create_action);
        payment_actions::destroy_cancel_payment_action(cancel_action);
    }

    #[test]
    fun test_create_payment_action_unicode_description() {
        let action = payment_actions::new_create_payment_action<SUI>(
            1u8, 2u8, ALICE, 1000u64, 100u64, 200u64,
            option::some(50u64), 10u64, true,
            string::utf8(b"Payment for \xF0\x9F\x92\xB0 services"),  // Unicode emoji
            100u64, 1000u64, 5u64
        );

        assert_eq(
            *payment_actions::description(&action),
            string::utf8(b"Payment for \xF0\x9F\x92\xB0 services")
        );

        payment_actions::destroy_create_payment_action(action);
    }

    #[test]
    fun test_timestamps_ordering() {
        // Test when end_timestamp < start_timestamp (edge case, validation should happen elsewhere)
        let action = payment_actions::new_create_payment_action<SUI>(
            1u8, 2u8, ALICE, 1000u64,
            200u64,  // start_timestamp
            100u64,  // end_timestamp (before start)
            option::some(50u64), 10u64, true,
            string::utf8(b"Invalid timing"), 100u64, 1000u64, 5u64
        );

        assert_eq(payment_actions::start_timestamp(&action), 200u64);
        assert_eq(payment_actions::end_timestamp(&action), 100u64);

        payment_actions::destroy_create_payment_action(action);
    }
}
