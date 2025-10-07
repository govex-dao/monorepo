/// Comprehensive tests for dissolution_intents.move
/// Tests intent building, distribution calculations, and helper functions
#[test_only]
module futarchy_lifecycle::dissolution_intents_tests {
    use std::string;
    use sui::test_scenario::{Self as ts};
    use sui::test_utils::assert_eq;
    use sui::clock::{Self, Clock};
    use account_protocol::intents::{Self, Intent};
    use account_extensions::extensions::{Self, Extensions};
    use futarchy_lifecycle::dissolution_intents;

    // === Test Addresses ===
    const ADMIN: address = @0xAD;
    const ALICE: address = @0xA1;
    const BOB: address = @0xB2;
    const CAROL: address = @0xC3;

    // === Test Coin Type ===
    public struct TEST_COIN has drop {}

    // === Witness Tests ===

    #[test]
    fun test_create_witness() {
        let witness = dissolution_intents::witness();
        let _ = witness;
    }

    // === Intent Building Tests ===

    #[test]
    fun test_initiate_dissolution_in_intent() {
        let mut scenario = ts::begin(ADMIN);

        let mut intent = intents::empty<u8>(extensions::empty(ts::ctx(&mut scenario)), ts::ctx(&mut scenario));

        dissolution_intents::initiate_dissolution_in_intent(
            &mut intent,
            string::utf8(b"Market price below NAV"),
            0,  // Pro-rata
            true,  // Burn unsold tokens
            1000000,  // Deadline
            extensions::empty(ts::ctx(&mut scenario))
        );

        // Verify action was added
        let specs = intents::action_specs(&intent);
        assert_eq(specs.length(), 1);

        intents::destroy_empty_for_testing(intent);
        ts::end(scenario);
    }

    #[test]
    fun test_batch_distribute_in_intent() {
        let mut scenario = ts::begin(ADMIN);

        let mut intent = intents::empty<u8>(extensions::empty(ts::ctx(&mut scenario)), ts::ctx(&mut scenario));

        let asset_types = vector[
            string::utf8(b"0x2::sui::SUI"),
            string::utf8(b"0x2::usdc::USDC"),
        ];

        dissolution_intents::batch_distribute_in_intent(
            &mut intent,
            asset_types,
            extensions::empty(ts::ctx(&mut scenario))
        );

        // Verify action was added
        let specs = intents::action_specs(&intent);
        assert_eq(specs.length(), 1);

        intents::destroy_empty_for_testing(intent);
        ts::end(scenario);
    }

    #[test]
    fun test_finalize_dissolution_in_intent() {
        let mut scenario = ts::begin(ADMIN);

        let mut intent = intents::empty<u8>(extensions::empty(ts::ctx(&mut scenario)), ts::ctx(&mut scenario));

        dissolution_intents::finalize_dissolution_in_intent(
            &mut intent,
            ALICE,  // Final recipient
            false,  // Don't destroy account
            extensions::empty(ts::ctx(&mut scenario))
        );

        // Verify action was added
        let specs = intents::action_specs(&intent);
        assert_eq(specs.length(), 1);

        intents::destroy_empty_for_testing(intent);
        ts::end(scenario);
    }

    #[test]
    fun test_cancel_dissolution_in_intent() {
        let mut scenario = ts::begin(ADMIN);

        let mut intent = intents::empty<u8>(extensions::empty(ts::ctx(&mut scenario)), ts::ctx(&mut scenario));

        dissolution_intents::cancel_dissolution_in_intent(
            &mut intent,
            string::utf8(b"Community voted to continue"),
            extensions::empty(ts::ctx(&mut scenario))
        );

        // Verify action was added
        let specs = intents::action_specs(&intent);
        assert_eq(specs.length(), 1);

        intents::destroy_empty_for_testing(intent);
        ts::end(scenario);
    }

    #[test]
    fun test_multiple_actions_in_intent() {
        let mut scenario = ts::begin(ADMIN);

        let mut intent = intents::empty<u8>(extensions::empty(ts::ctx(&mut scenario)), ts::ctx(&mut scenario));

        // Add multiple dissolution actions
        dissolution_intents::initiate_dissolution_in_intent(
            &mut intent,
            string::utf8(b"Test"),
            0, true, 1000000,
            extensions::empty(ts::ctx(&mut scenario))
        );

        dissolution_intents::batch_distribute_in_intent(
            &mut intent,
            vector[string::utf8(b"0x2::sui::SUI")],
            extensions::empty(ts::ctx(&mut scenario))
        );

        dissolution_intents::finalize_dissolution_in_intent(
            &mut intent,
            ALICE, false,
            extensions::empty(ts::ctx(&mut scenario))
        );

        // Verify all actions were added
        let specs = intents::action_specs(&intent);
        assert_eq(specs.length(), 3);

        intents::destroy_empty_for_testing(intent);
        ts::end(scenario);
    }

    // === Dissolution Key Tests ===

    #[test]
    fun test_create_dissolution_key() {
        let mut scenario = ts::begin(ADMIN);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));

        clock.set_for_testing(1000);

        let key = dissolution_intents::create_dissolution_key(
            string::utf8(b"initiate"),
            &clock
        );

        // Key should be "dissolution_initiate_1000"
        assert_eq(key, string::utf8(b"dissolution_initiate_1000"));

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    fun test_create_dissolution_key_different_operations() {
        let mut scenario = ts::begin(ADMIN);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));

        clock.set_for_testing(5000);

        let key1 = dissolution_intents::create_dissolution_key(
            string::utf8(b"initiate"),
            &clock
        );

        let key2 = dissolution_intents::create_dissolution_key(
            string::utf8(b"finalize"),
            &clock
        );

        // Keys should be different (different operations)
        assert!(key1 != key2);

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    fun test_create_dissolution_key_different_timestamps() {
        let mut scenario = ts::begin(ADMIN);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));

        clock.set_for_testing(1000);
        let key1 = dissolution_intents::create_dissolution_key(
            string::utf8(b"initiate"),
            &clock
        );

        clock.set_for_testing(2000);
        let key2 = dissolution_intents::create_dissolution_key(
            string::utf8(b"initiate"),
            &clock
        );

        // Keys should be different (different timestamps)
        assert!(key1 != key2);

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    // === Pro-Rata Distribution Tests ===

    #[test]
    fun test_create_prorata_distribution_simple() {
        let total_amount = 1000u64;
        let holders = vector[ALICE, BOB];
        let balances = vector[100u64, 200u64];  // 1:2 ratio

        let (recipients, amounts) = dissolution_intents::create_prorata_distribution<TEST_COIN>(
            total_amount,
            holders,
            balances
        );

        // ALICE should get 333 (100/300 * 1000)
        // BOB should get 666 (200/300 * 1000)
        assert_eq(recipients.length(), 2);
        assert_eq(amounts.length(), 2);
        assert_eq(*recipients.borrow(0), ALICE);
        assert_eq(*recipients.borrow(1), BOB);
        assert_eq(*amounts.borrow(0), 333u64);  // 100/300 * 1000
        assert_eq(*amounts.borrow(1), 666u64);  // 200/300 * 1000
    }

    #[test]
    fun test_create_prorata_distribution_equal_balances() {
        let total_amount = 1000u64;
        let holders = vector[ALICE, BOB, CAROL];
        let balances = vector[100u64, 100u64, 100u64];  // Equal

        let (recipients, amounts) = dissolution_intents::create_prorata_distribution<TEST_COIN>(
            total_amount,
            holders,
            balances
        );

        // Each should get 333 (1000/3)
        assert_eq(recipients.length(), 3);
        assert_eq(*amounts.borrow(0), 333u64);
        assert_eq(*amounts.borrow(1), 333u64);
        assert_eq(*amounts.borrow(2), 333u64);
    }

    #[test]
    fun test_create_prorata_distribution_with_zero_balance() {
        let total_amount = 1000u64;
        let holders = vector[ALICE, BOB, CAROL];
        let balances = vector[100u64, 0u64, 200u64];  // BOB has 0

        let (recipients, amounts) = dissolution_intents::create_prorata_distribution<TEST_COIN>(
            total_amount,
            holders,
            balances
        );

        // BOB should be filtered out (has 0 balance)
        assert_eq(recipients.length(), 2);
        assert_eq(*recipients.borrow(0), ALICE);
        assert_eq(*recipients.borrow(1), CAROL);
        assert_eq(*amounts.borrow(0), 333u64);  // 100/300 * 1000
        assert_eq(*amounts.borrow(1), 666u64);  // 200/300 * 1000
    }

    #[test]
    fun test_create_prorata_distribution_all_zero_balances() {
        let total_amount = 1000u64;
        let holders = vector[ALICE, BOB];
        let balances = vector[0u64, 0u64];  // All zero

        let (recipients, amounts) = dissolution_intents::create_prorata_distribution<TEST_COIN>(
            total_amount,
            holders,
            balances
        );

        // No recipients should be included
        assert_eq(recipients.length(), 0);
        assert_eq(amounts.length(), 0);
    }

    #[test]
    fun test_create_prorata_distribution_rounding() {
        let total_amount = 100u64;
        let holders = vector[ALICE, BOB, CAROL];
        let balances = vector[1u64, 1u64, 1u64];  // Equal but causes rounding

        let (recipients, amounts) = dissolution_intents::create_prorata_distribution<TEST_COIN>(
            total_amount,
            holders,
            balances
        );

        // Each should get 33 (100/3 rounded down)
        assert_eq(recipients.length(), 3);
        assert_eq(*amounts.borrow(0), 33u64);
        assert_eq(*amounts.borrow(1), 33u64);
        assert_eq(*amounts.borrow(2), 33u64);
        // Note: 1 unit will be lost due to rounding (33+33+33 = 99, not 100)
    }

    #[test]
    fun test_create_prorata_distribution_large_numbers() {
        let total_amount = 1000000000u64;  // 1 billion
        let holders = vector[ALICE, BOB];
        let balances = vector[1000000u64, 2000000u64];  // 1M and 2M

        let (recipients, amounts) = dissolution_intents::create_prorata_distribution<TEST_COIN>(
            total_amount,
            holders,
            balances
        );

        assert_eq(recipients.length(), 2);
        assert_eq(*amounts.borrow(0), 333333333u64);  // 1M/3M * 1B
        assert_eq(*amounts.borrow(1), 666666666u64);  // 2M/3M * 1B
    }

    // === Equal Distribution Tests ===

    #[test]
    fun test_create_equal_distribution() {
        let total_amount = 1000u64;
        let recipients = vector[ALICE, BOB, CAROL];

        let amounts = dissolution_intents::create_equal_distribution(
            total_amount,
            recipients
        );

        // Each should get 333 (1000/3)
        assert_eq(amounts.length(), 3);
        assert_eq(*amounts.borrow(0), 333u64);
        assert_eq(*amounts.borrow(1), 333u64);
        assert_eq(*amounts.borrow(2), 333u64);
    }

    #[test]
    fun test_create_equal_distribution_two_recipients() {
        let total_amount = 100u64;
        let recipients = vector[ALICE, BOB];

        let amounts = dissolution_intents::create_equal_distribution(
            total_amount,
            recipients
        );

        // Each should get 50
        assert_eq(amounts.length(), 2);
        assert_eq(*amounts.borrow(0), 50u64);
        assert_eq(*amounts.borrow(1), 50u64);
    }

    #[test]
    fun test_create_equal_distribution_single_recipient() {
        let total_amount = 1000u64;
        let recipients = vector[ALICE];

        let amounts = dissolution_intents::create_equal_distribution(
            total_amount,
            recipients
        );

        // Single recipient gets everything
        assert_eq(amounts.length(), 1);
        assert_eq(*amounts.borrow(0), 1000u64);
    }

    #[test]
    fun test_create_equal_distribution_rounding() {
        let total_amount = 100u64;
        let recipients = vector[ALICE, BOB, CAROL, @0xD4, @0xE5];  // 5 recipients

        let amounts = dissolution_intents::create_equal_distribution(
            total_amount,
            recipients
        );

        // Each should get 20 (100/5)
        assert_eq(amounts.length(), 5);
        assert_eq(*amounts.borrow(0), 20u64);
        assert_eq(*amounts.borrow(1), 20u64);
        assert_eq(*amounts.borrow(2), 20u64);
        assert_eq(*amounts.borrow(3), 20u64);
        assert_eq(*amounts.borrow(4), 20u64);
    }

    #[test]
    fun test_create_equal_distribution_many_recipients() {
        let total_amount = 10000u64;
        let mut recipients = vector::empty();
        let mut i = 0;
        while (i < 10) {
            recipients.push_back(@0x1);
            i = i + 1;
        };

        let amounts = dissolution_intents::create_equal_distribution(
            total_amount,
            recipients
        );

        // Each should get 1000 (10000/10)
        assert_eq(amounts.length(), 10);
        let mut j = 0;
        while (j < 10) {
            assert_eq(*amounts.borrow(j), 1000u64);
            j = j + 1;
        };
    }
}
