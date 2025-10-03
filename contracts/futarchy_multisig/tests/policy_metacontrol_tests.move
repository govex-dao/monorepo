/// Comprehensive tests for metacontrol enforcement in the policy system
/// Tests that policies can govern themselves and prevent unauthorized changes
#[test_only]
module futarchy_multisig::policy_metacontrol_tests {
    use std::option;
    use sui::test_scenario::{Self as ts, Scenario};
    use sui::clock::{Self, Clock};
    use sui::object::{Self, ID};
    use sui::tx_context;
    use account_protocol::account::{Self, Account};
    use account_protocol::intents::{Self, Intent};
    use account_protocol::executable::{Self, Executable};
    use account_protocol::version_witness;
    use futarchy_core::futarchy_config::FutarchyConfig;
    use futarchy_core::version;
    use futarchy_multisig::policy_registry::{Self, PolicyRegistry};
    use futarchy_multisig::policy_actions;

    // Mock action types for testing
    public struct TestAction has drop, store {}
    public struct CriticalAction has drop, store {}

    const DAO_ADMIN: address = @0xDA0;
    const SECURITY_COUNCIL: address = @0x5EC;
    const TREASURY_COUNCIL: address = @0x7EA;
    const MALICIOUS_ACTOR: address = @0xBAD;

    // === Test Setup Helpers ===

    fun setup_test(): Scenario {
        let mut scenario = ts::begin(DAO_ADMIN);

        // Create a clock for time-based tests
        ts::next_tx(&mut scenario, DAO_ADMIN);
        {
            let clock = clock::create_for_testing(ts::ctx(&mut scenario));
            clock::share_for_testing(clock);
        };

        scenario
    }

    fun create_test_account(scenario: &mut Scenario): ID {
        ts::next_tx(scenario, DAO_ADMIN);
        let account = account::new<FutarchyConfig>(ts::ctx(scenario));
        let account_id = object::id(&account);

        // Initialize policy registry
        policy_registry::initialize(
            &mut account,
            version::current(),
            ts::ctx(scenario)
        );

        account::share_for_testing(account);
        account_id
    }

    fun register_test_councils(scenario: &mut Scenario, account_id: ID) {
        ts::next_tx(scenario, DAO_ADMIN);
        let mut account = ts::take_shared_by_id<Account<FutarchyConfig>>(scenario, account_id);
        let registry = policy_registry::borrow_registry_mut(&mut account, version::current());

        policy_registry::register_council(registry, account_id, object::id_from_address(SECURITY_COUNCIL));
        policy_registry::register_council(registry, account_id, object::id_from_address(TREASURY_COUNCIL));

        ts::return_shared(account);
    }

    // === Test 1: Basic Metacontrol - SetTypePolicyAction Governs Itself ===

    #[test]
    fun test_metacontrol_set_type_policy_action_dao_only() {
        let mut scenario = setup_test();
        let account_id = create_test_account(&mut scenario);
        register_test_councils(&mut scenario, account_id);

        // Set a metacontrol policy: Changing SetTypePolicyAction requires DAO approval
        ts::next_tx(&mut scenario, DAO_ADMIN);
        {
            let mut account = ts::take_shared_by_id<Account<FutarchyConfig>>(&mut scenario, account_id);
            let registry = policy_registry::borrow_registry_mut(&mut account, version::current());

            // Set policy: SetTypePolicyAction itself requires DAO-only to change
            policy_registry::set_type_policy<policy_actions::SetTypePolicyAction>(
                registry,
                account_id,
                option::none(), // No council for execution
                policy_registry::MODE_DAO_ONLY(),
                option::none(), // No council for changes
                policy_registry::MODE_DAO_ONLY(), // DAO must approve changes to this policy
                0 // No delay
            );

            ts::return_shared(account);
        };

        // Now attempt to change a policy from DAO - should succeed
        ts::next_tx(&mut scenario, DAO_ADMIN);
        {
            let mut account = ts::take_shared_by_id<Account<FutarchyConfig>>(&mut scenario, account_id);
            let registry = policy_registry::borrow_registry_mut(&mut account, version::current());

            // DAO can set policies because it has permission
            policy_registry::set_type_policy<TestAction>(
                registry,
                account_id,
                option::none(),
                policy_registry::MODE_DAO_ONLY(),
                option::none(),
                policy_registry::MODE_DAO_ONLY(),
                0
            );

            ts::return_shared(account);
        };

        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = policy_actions::EPolicyChangeRequiresDAO)]
    fun test_metacontrol_council_cannot_change_dao_only_policy() {
        let mut scenario = setup_test();
        let account_id = create_test_account(&mut scenario);
        register_test_councils(&mut scenario, account_id);

        // Set metacontrol: SetTypePolicyAction requires DAO-only
        ts::next_tx(&mut scenario, DAO_ADMIN);
        {
            let mut account = ts::take_shared_by_id<Account<FutarchyConfig>>(&mut scenario, account_id);
            let registry = policy_registry::borrow_registry_mut(&mut account, version::current());

            policy_registry::set_type_policy<policy_actions::SetTypePolicyAction>(
                registry,
                account_id,
                option::none(),
                policy_registry::MODE_DAO_ONLY(),
                option::none(),
                policy_registry::MODE_DAO_ONLY(),
                0
            );

            ts::return_shared(account);
        };

        // Create an intent from security council (not DAO)
        ts::next_tx(&mut scenario, SECURITY_COUNCIL);
        {
            let clock = ts::take_shared<Clock>(&mut scenario);
            let mut intent = intents::new<FutarchyConfig, ()>(
                object::id_from_address(SECURITY_COUNCIL), // Council creates intent, not DAO
                1, // version
                &clock,
                ts::ctx(&mut scenario)
            );

            // Try to add SetTypePolicyAction - this should fail validation
            policy_actions::new_set_type_policy<(), TestAction>(
                &mut intent,
                option::some(object::id_from_address(SECURITY_COUNCIL)),
                policy_registry::MODE_COUNCIL_ONLY(),
                option::none(),
                policy_registry::MODE_DAO_ONLY(),
                intents::witness(),
            );

            ts::return_shared(clock);
            intents::destroy_for_testing(intent);
        };

        ts::end(scenario);
    }

    // === Test 2: Metacontrol with Council Requirement ===

    #[test]
    fun test_metacontrol_council_and_dao_required() {
        let mut scenario = setup_test();
        let account_id = create_test_account(&mut scenario);
        register_test_councils(&mut scenario, account_id);

        // Set metacontrol: Changing SetTypePolicyAction requires both DAO and Security Council
        ts::next_tx(&mut scenario, DAO_ADMIN);
        {
            let mut account = ts::take_shared_by_id<Account<FutarchyConfig>>(&mut scenario, account_id);
            let registry = policy_registry::borrow_registry_mut(&mut account, version::current());

            policy_registry::set_type_policy<policy_actions::SetTypePolicyAction>(
                registry,
                account_id,
                option::none(),
                policy_registry::MODE_DAO_ONLY(),
                option::some(object::id_from_address(SECURITY_COUNCIL)),
                policy_registry::MODE_DAO_AND_COUNCIL(), // Both needed to change
                0
            );

            ts::return_shared(account);
        };

        // Security council can initiate the change (will need DAO co-approval)
        ts::next_tx(&mut scenario, SECURITY_COUNCIL);
        {
            let clock = ts::take_shared<Clock>(&mut scenario);
            let mut intent = intents::new<FutarchyConfig, ()>(
                object::id_from_address(SECURITY_COUNCIL),
                1,
                &clock,
                ts::ctx(&mut scenario)
            );

            policy_actions::new_set_type_policy<(), CriticalAction>(
                &mut intent,
                option::some(object::id_from_address(SECURITY_COUNCIL)),
                policy_registry::MODE_COUNCIL_ONLY(),
                option::some(object::id_from_address(SECURITY_COUNCIL)),
                policy_registry::MODE_DAO_AND_COUNCIL(),
                intents::witness(),
            );

            ts::return_shared(clock);
            intents::destroy_for_testing(intent);
        };

        ts::end(scenario);
    }

    // === Test 3: Metacontrol Prevents Privilege Escalation ===

    #[test]
    #[expected_failure(abort_code = policy_actions::EPolicyChangeRequiresDAO)]
    fun test_metacontrol_prevents_privilege_escalation() {
        let mut scenario = setup_test();
        let account_id = create_test_account(&mut scenario);
        register_test_councils(&mut scenario, account_id);

        // Set up: SetTypePolicyAction requires DAO approval
        ts::next_tx(&mut scenario, DAO_ADMIN);
        {
            let mut account = ts::take_shared_by_id<Account<FutarchyConfig>>(&mut scenario, account_id);
            let registry = policy_registry::borrow_registry_mut(&mut account, version::current());

            policy_registry::set_type_policy<policy_actions::SetTypePolicyAction>(
                registry,
                account_id,
                option::none(),
                policy_registry::MODE_DAO_ONLY(),
                option::none(),
                policy_registry::MODE_DAO_ONLY(),
                0
            );

            ts::return_shared(account);
        };

        // Malicious actor tries to create a policy that would give them control
        ts::next_tx(&mut scenario, MALICIOUS_ACTOR);
        {
            let clock = ts::take_shared<Clock>(&mut scenario);
            let mut intent = intents::new<FutarchyConfig, ()>(
                object::id_from_address(MALICIOUS_ACTOR),
                1,
                &clock,
                ts::ctx(&mut scenario)
            );

            // Try to make SetTypePolicyAction require malicious council
            // This should fail because only DAO can change SetTypePolicyAction policy
            policy_actions::new_set_type_policy<(), policy_actions::SetTypePolicyAction>(
                &mut intent,
                option::some(object::id_from_address(MALICIOUS_ACTOR)),
                policy_registry::MODE_COUNCIL_ONLY(),
                option::some(object::id_from_address(MALICIOUS_ACTOR)),
                policy_registry::MODE_COUNCIL_ONLY(),
                intents::witness(),
            );

            ts::return_shared(clock);
            intents::destroy_for_testing(intent);
        };

        ts::end(scenario);
    }

    // === Test 4: Metacontrol with Time Delays ===

    #[test]
    #[expected_failure(abort_code = policy_registry::EDelayNotElapsed)]
    fun test_metacontrol_respects_time_delays() {
        let mut scenario = setup_test();
        let account_id = create_test_account(&mut scenario);
        register_test_councils(&mut scenario, account_id);

        let delay_ms = 86400000; // 24 hours

        // Set metacontrol with time delay
        ts::next_tx(&mut scenario, DAO_ADMIN);
        {
            let mut account = ts::take_shared_by_id<Account<FutarchyConfig>>(&mut scenario, account_id);
            let registry = policy_registry::borrow_registry_mut(&mut account, version::current());

            policy_registry::set_type_policy<policy_actions::SetTypePolicyAction>(
                registry,
                account_id,
                option::none(),
                policy_registry::MODE_DAO_ONLY(),
                option::none(),
                policy_registry::MODE_DAO_ONLY(),
                delay_ms // 24 hour delay
            );

            ts::return_shared(account);
        };

        // Try to change policy - creates pending change
        ts::next_tx(&mut scenario, DAO_ADMIN);
        {
            let mut account = ts::take_shared_by_id<Account<FutarchyConfig>>(&mut scenario, account_id);
            let mut clock = ts::take_shared<Clock>(&mut scenario);
            let registry = policy_registry::borrow_registry_mut(&mut account, version::current());

            // This creates a pending change
            policy_registry::set_type_policy_by_string(
                registry,
                account_id,
                std::ascii::string(b"TestAction"),
                option::none(),
                policy_registry::MODE_DAO_ONLY(),
                option::none(),
                policy_registry::MODE_DAO_ONLY(),
                0,
                account_id,
                &clock,
            );

            ts::return_shared(account);
            ts::return_shared(clock);
        };

        // Try to finalize immediately - should fail
        ts::next_tx(&mut scenario, DAO_ADMIN);
        {
            let mut account = ts::take_shared_by_id<Account<FutarchyConfig>>(&mut scenario, account_id);
            let clock = ts::take_shared<Clock>(&mut scenario);
            let registry = policy_registry::borrow_registry_mut(&mut account, version::current());

            // This should abort because delay hasn't elapsed
            policy_registry::finalize_pending_type_policy(
                registry,
                std::ascii::string(b"TestAction"),
                &clock,
            );

            ts::return_shared(account);
            ts::return_shared(clock);
        };

        ts::end(scenario);
    }

    // === Test 5: Council Registration Validation ===

    #[test]
    #[expected_failure(abort_code = policy_actions::ECouncilNotRegistered)]
    fun test_metacontrol_prevents_unregistered_council() {
        let mut scenario = setup_test();
        let account_id = create_test_account(&mut scenario);
        // Note: Not registering any councils

        // Try to create a policy with an unregistered council
        ts::next_tx(&mut scenario, DAO_ADMIN);
        {
            let mut account = ts::take_shared_by_id<Account<FutarchyConfig>>(&mut scenario, account_id);
            let clock = ts::take_shared<Clock>(&mut scenario);
            let mut intent = intents::new<FutarchyConfig, ()>(
                account_id,
                1,
                &clock,
                ts::ctx(&mut scenario)
            );

            // This should fail because SECURITY_COUNCIL is not registered
            policy_actions::new_set_type_policy<(), TestAction>(
                &mut intent,
                option::some(object::id_from_address(SECURITY_COUNCIL)), // Not registered!
                policy_registry::MODE_COUNCIL_ONLY(),
                option::none(),
                policy_registry::MODE_DAO_ONLY(),
                intents::witness(),
            );

            ts::return_shared(account);
            ts::return_shared(clock);
            intents::destroy_for_testing(intent);
        };

        ts::end(scenario);
    }

    // === Test 6: Generic Fallback with Metacontrol ===

    #[test]
    fun test_metacontrol_respects_generic_fallback() {
        let mut scenario = setup_test();
        let account_id = create_test_account(&mut scenario);
        register_test_councils(&mut scenario, account_id);

        // Set policy on generic action
        ts::next_tx(&mut scenario, DAO_ADMIN);
        {
            let mut account = ts::take_shared_by_id<Account<FutarchyConfig>>(&mut scenario, account_id);
            let registry = policy_registry::borrow_registry_mut(&mut account, version::current());

            // Set generic policy (no type parameters)
            policy_registry::set_type_policy_by_string(
                registry,
                account_id,
                std::ascii::string(b"GenericAction"),
                option::some(object::id_from_address(SECURITY_COUNCIL)),
                policy_registry::MODE_COUNCIL_ONLY(),
                option::none(),
                policy_registry::MODE_DAO_ONLY(),
                0,
                account_id,
                &ts::take_shared<Clock>(&mut scenario),
            );

            ts::return_shared(account);
        };

        // Specific parameterized version should fall back to generic policy
        ts::next_tx(&mut scenario, DAO_ADMIN);
        {
            let account = ts::take_shared_by_id<Account<FutarchyConfig>>(&mut scenario, account_id);
            let registry = policy_registry::borrow_registry(&account, version::current());

            // Check that generic fallback works
            let has_policy = policy_registry::has_type_policy_by_string(
                registry,
                std::ascii::string(b"GenericAction<SomeType>")
            );
            assert!(has_policy, 0); // Should find via fallback

            ts::return_shared(account);
        };

        ts::end(scenario);
    }
}
