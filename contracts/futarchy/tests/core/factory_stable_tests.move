#[test_only]
module futarchy::test_stable_coin {
    public struct TEST_STABLE_COIN has drop {}

    public fun create(): TEST_STABLE_COIN {
        TEST_STABLE_COIN {}
    }
}

#[test_only]
module futarchy::allowed_stable_tests {
    use futarchy::factory::{Self, Factory, FactoryOwnerCap};
    use futarchy::test_stable_coin::TEST_STABLE_COIN;
    use sui::clock;
    use sui::test_scenario::{Self as test, ctx};

    /// Helper to set up the factory.
    fun setup_factory(scenario: &mut test::Scenario) {
        test::next_tx(scenario, @0xA);
        {
            // Factory is initialized; its default allowed stable type is MY_STABLE.
            futarchy::factory::create_factory(ctx(scenario));
        }
    }

    /// Test that by default, TEST_STABLE_COIN is not allowed.
    #[test]
    fun test_default_disallows_test_stable_coin() {
        let mut scenario = test::begin(@0xA);
        setup_factory(&mut scenario);

        test::next_tx(&mut scenario, @0xA);
        {
            let factory = test::take_shared<Factory>(&scenario);
            // This should return false because TEST_STABLE_COIN is not allowed.
            assert!(!factory::is_stable_type_allowed<TEST_STABLE_COIN>(&factory), 0);
            test::return_shared(factory);
        };
        test::end(scenario);
    }

    /// Test that after adding TEST_STABLE_COIN, it becomes allowed.
    #[test]
    fun test_add_and_check_test_stable_coin() {
        let mut scenario = test::begin(@0xA);
        setup_factory(&mut scenario);

        test::next_tx(&mut scenario, @0xA);
        {
            let mut factory = test::take_shared<Factory>(&scenario);
            let owner_cap = test::take_from_address<FactoryOwnerCap>(&scenario, @0xA);
            let clock = clock::create_for_testing(ctx(&mut scenario));

            // Add TEST_STABLE_COIN to the allowed list.
            factory::add_allowed_stable_type<TEST_STABLE_COIN>(
                &mut factory,
                &owner_cap,
                1000000, // min_raise_amount
                &clock,
                ctx(&mut scenario),
            );
            clock::destroy_for_testing(clock);

            // Now check that TEST_STABLE_COIN is allowed (this should not abort).
            factory::is_stable_type_allowed<TEST_STABLE_COIN>(&factory);
            test::return_shared(factory);
            test::return_to_address(@0xA, owner_cap);
        };
        test::end(scenario);
    }

    /// Test that after adding then removing TEST_STABLE_COIN, it is disallowed again.
    #[test]
    fun test_add_remove_and_check_test_stable_coin() {
        let mut scenario = test::begin(@0xA);
        setup_factory(&mut scenario);

        test::next_tx(&mut scenario, @0xA);
        {
            let mut factory = test::take_shared<Factory>(&scenario);
            let owner_cap = test::take_from_address<FactoryOwnerCap>(&scenario, @0xA);
            let clock = clock::create_for_testing(ctx(&mut scenario));

            // Add then remove TEST_STABLE_COIN.
            factory::add_allowed_stable_type<TEST_STABLE_COIN>(
                &mut factory,
                &owner_cap,
                1000000, // min_raise_amount
                &clock,
                ctx(&mut scenario),
            );
            factory::remove_allowed_stable_type<TEST_STABLE_COIN>(
                &mut factory,
                &owner_cap,
                &clock,
                ctx(&mut scenario),
            );
            clock::destroy_for_testing(clock);

            // Now this should return false because TEST_STABLE_COIN is no longer allowed.
            assert!(!factory::is_stable_type_allowed<TEST_STABLE_COIN>(&factory), 0);
            test::return_shared(factory);
            test::return_to_address(@0xA, owner_cap);
        };
        test::end(scenario);
    }

    #[test]
    fun test_remove_nonexistent_stable_type() {
        let mut scenario = test::begin(@0xA);

        test::next_tx(&mut scenario, @0xA);
        {
            futarchy::factory::create_factory(ctx(&mut scenario));
        };

        test::next_tx(&mut scenario, @0xA);
        {
            let mut factory = test::take_shared<Factory>(&scenario);
            let owner_cap = test::take_from_address<FactoryOwnerCap>(&scenario, @0xA);
            let clock = clock::create_for_testing(ctx(&mut scenario));

            // TEST_STABLE_COIN is not in allowed list by default
            assert!(!factory::is_stable_type_allowed<TEST_STABLE_COIN>(&factory), 0);

            // Remove it anyway - should be idempotent
            factory::remove_allowed_stable_type<TEST_STABLE_COIN>(
                &mut factory,
                &owner_cap,
                &clock,
                ctx(&mut scenario),
            );
            assert!(!factory::is_stable_type_allowed<TEST_STABLE_COIN>(&factory), 1);

            clock::destroy_for_testing(clock);
            test::return_shared(factory);
            test::return_to_address(@0xA, owner_cap);
        };
        test::end(scenario);
    }

    #[test]
    fun test_add_allowed_stable_type_idempotent() {
        let mut scenario = test::begin(@0xA);

        test::next_tx(&mut scenario, @0xA);
        {
            futarchy::factory::create_factory(ctx(&mut scenario));
        };

        test::next_tx(&mut scenario, @0xA);
        {
            let mut factory = test::take_shared<Factory>(&scenario);
            let owner_cap = test::take_from_address<FactoryOwnerCap>(&scenario, @0xA);
            let clock = clock::create_for_testing(ctx(&mut scenario));

            // Add TEST_STABLE_COIN to allowed list
            factory::add_allowed_stable_type<TEST_STABLE_COIN>(
                &mut factory,
                &owner_cap,
                1000000, // min_raise_amount
                &clock,
                ctx(&mut scenario),
            );
            assert!(factory::is_stable_type_allowed<TEST_STABLE_COIN>(&factory), 0);

            // Add it again - should be idempotent
            factory::add_allowed_stable_type<TEST_STABLE_COIN>(
                &mut factory,
                &owner_cap,
                1000000, // min_raise_amount
                &clock,
                ctx(&mut scenario),
            );
            assert!(factory::is_stable_type_allowed<TEST_STABLE_COIN>(&factory), 1);

            clock::destroy_for_testing(clock);
            test::return_shared(factory);
            test::return_to_address(@0xA, owner_cap);
        };
        test::end(scenario);
    }
}
