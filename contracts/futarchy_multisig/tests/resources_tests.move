/// Comprehensive tests for resources.move
/// Tests resource key generation, wildcard matching, and categorization
#[test_only]
module futarchy_multisig::resources_tests {
    use std::string;
    use std::type_name;
    use sui::test_utils::assert_eq;
    use sui::sui::SUI;
    use futarchy_multisig::resources;

    // Test coin type for generic testing
    public struct TEST_COIN has drop {}
    public struct OTHER_COIN has drop {}

    // === Basic Validation Tests ===

    #[test]
    fun test_is_valid_positive() {
        let key = resources::package_publish();
        assert!(resources::is_valid(&key));

        let key2 = resources::vault_config();
        assert!(resources::is_valid(&key2));

        let key3 = resources::governance_propose();
        assert!(resources::is_valid(&key3));
    }

    #[test]
    fun test_is_valid_negative() {
        let invalid1 = string::utf8(b"not_a_resource_key");
        assert!(!resources::is_valid(&invalid1));

        let invalid2 = string::utf8(b"resource");
        assert!(!resources::is_valid(&invalid2));

        let invalid3 = string::utf8(b"");
        assert!(!resources::is_valid(&invalid3));
    }

    // === Package Resource Tests ===

    #[test]
    fun test_package_upgrade() {
        let key = resources::package_upgrade(@0x123, string::utf8(b"my_package"));
        assert!(resources::is_valid(&key));
        assert_eq(resources::get_category(&key), string::utf8(b"package"));
        assert!(key.index_of(&string::utf8(b"upgrade")) < key.length());
    }

    #[test]
    fun test_package_restrict() {
        let key = resources::package_restrict(@0xABC, string::utf8(b"core"));
        assert!(resources::is_valid(&key));
        assert!(key.index_of(&string::utf8(b"restrict")) < key.length());
        // Should be critical resource
        assert!(resources::is_critical_resource(&key));
    }

    #[test]
    fun test_package_publish() {
        let key = resources::package_publish();
        assert_eq(key, string::utf8(b"resource:/package/publish"));
        assert_eq(resources::get_category(&key), string::utf8(b"package"));
    }

    // === Vault Resource Tests ===

    #[test]
    fun test_vault_spend_generic() {
        let key = resources::vault_spend<SUI>();
        assert!(resources::is_valid(&key));
        assert_eq(resources::get_category(&key), string::utf8(b"vault"));
        assert!(key.index_of(&string::utf8(b"spend")) < key.length());
    }

    #[test]
    fun test_vault_spend_by_type() {
        let sui_type = type_name::with_defining_ids<SUI>();
        let key = resources::vault_spend_by_type(sui_type);
        assert!(resources::is_valid(&key));
        assert!(key.index_of(&string::utf8(b"vault/spend")) < key.length());
    }

    #[test]
    fun test_vault_mint_generic() {
        let key = resources::vault_mint<TEST_COIN>();
        assert!(resources::is_valid(&key));
        assert!(key.index_of(&string::utf8(b"mint")) < key.length());
        // Mint should be critical resource
        assert!(resources::is_critical_resource(&key));
    }

    #[test]
    fun test_vault_mint_by_type() {
        let test_type = type_name::with_defining_ids<TEST_COIN>();
        let key = resources::vault_mint_by_type(test_type);
        assert!(resources::is_valid(&key));
        assert_eq(resources::get_category(&key), string::utf8(b"vault"));
    }

    #[test]
    fun test_vault_burn() {
        let key = resources::vault_burn<SUI>();
        assert!(resources::is_valid(&key));
        assert!(key.index_of(&string::utf8(b"burn")) < key.length());
    }

    #[test]
    fun test_vault_config() {
        let key = resources::vault_config();
        assert_eq(key, string::utf8(b"resource:/vault/config"));
    }

    // === Governance Resource Tests ===

    #[test]
    fun test_governance_propose() {
        let key = resources::governance_propose();
        assert_eq(key, string::utf8(b"resource:/governance/propose"));
        assert_eq(resources::get_category(&key), string::utf8(b"governance"));
    }

    #[test]
    fun test_governance_cancel() {
        let key = resources::governance_cancel();
        assert_eq(key, string::utf8(b"resource:/governance/cancel"));
    }

    #[test]
    fun test_governance_params() {
        let key = resources::governance_params();
        assert_eq(key, string::utf8(b"resource:/governance/params"));
    }

    #[test]
    fun test_governance_emergency() {
        let key = resources::governance_emergency();
        assert_eq(key, string::utf8(b"resource:/governance/emergency"));
        // Emergency should be critical resource
        assert!(resources::is_critical_resource(&key));
    }

    // === Operations Resource Tests ===

    #[test]
    fun test_operations_agreement() {
        let key = resources::operations_agreement();
        assert_eq(key, string::utf8(b"resource:/operations/agreement"));
        assert_eq(resources::get_category(&key), string::utf8(b"operations"));
    }

    #[test]
    fun test_operations_membership() {
        let key = resources::operations_membership();
        assert_eq(key, string::utf8(b"resource:/operations/membership"));
    }

    #[test]
    fun test_operations_roles() {
        let key = resources::operations_roles();
        assert_eq(key, string::utf8(b"resource:/operations/roles"));
    }

    // === Liquidity Resource Tests ===

    #[test]
    fun test_liquidity_create_pool() {
        let key = resources::liquidity_create_pool<TEST_COIN, SUI>();
        assert!(resources::is_valid(&key));
        assert_eq(resources::get_category(&key), string::utf8(b"liquidity"));
        assert!(key.index_of(&string::utf8(b"create")) < key.length());
    }

    #[test]
    fun test_liquidity_add() {
        let key = resources::liquidity_add<TEST_COIN, SUI>();
        assert!(resources::is_valid(&key));
        assert!(key.index_of(&string::utf8(b"add")) < key.length());
    }

    #[test]
    fun test_liquidity_remove() {
        let key = resources::liquidity_remove<TEST_COIN, SUI>();
        assert!(resources::is_valid(&key));
        assert!(key.index_of(&string::utf8(b"remove")) < key.length());
    }

    #[test]
    fun test_liquidity_params() {
        let key = resources::liquidity_params();
        assert_eq(key, string::utf8(b"resource:/liquidity/params"));
    }

    // === Security Resource Tests ===

    #[test]
    fun test_security_emergency_action() {
        let key = resources::security_emergency_action();
        assert_eq(key, string::utf8(b"resource:/security/emergency"));
        assert_eq(resources::get_category(&key), string::utf8(b"security"));
        // Security actions should be critical
        assert!(resources::is_critical_resource(&key));
    }

    #[test]
    fun test_security_council_membership() {
        let key = resources::security_council_membership();
        assert_eq(key, string::utf8(b"resource:/security/membership"));
    }

    #[test]
    fun test_security_veto() {
        let key = resources::security_veto();
        assert_eq(key, string::utf8(b"resource:/security/veto"));
    }

    // === Streams Resource Tests ===

    #[test]
    fun test_streams_create() {
        let key = resources::streams_create<SUI>();
        assert!(resources::is_valid(&key));
        assert_eq(resources::get_category(&key), string::utf8(b"streams"));
        assert!(key.index_of(&string::utf8(b"create")) < key.length());
    }

    #[test]
    fun test_streams_cancel() {
        let key = resources::streams_cancel();
        assert_eq(key, string::utf8(b"resource:/streams/cancel"));
    }

    // === Extension and Catch-All Tests ===

    #[test]
    fun test_ext() {
        let key = resources::ext(
            @0xABC,
            string::utf8(b"custom_module"),
            string::utf8(b"custom_action")
        );
        assert!(resources::is_valid(&key));
        assert!(key.index_of(&string::utf8(b"ext")) < key.length());
        assert!(key.index_of(&string::utf8(b"custom_module")) < key.length());
        assert!(key.index_of(&string::utf8(b"custom_action")) < key.length());
    }

    #[test]
    fun test_other() {
        let key = resources::other(string::utf8(b"custom/path/here"));
        assert!(resources::is_valid(&key));
        assert!(key.index_of(&string::utf8(b"other")) < key.length());
        assert!(key.index_of(&string::utf8(b"custom/path/here")) < key.length());
    }

    #[test]
    fun test_any() {
        let key = resources::any();
        assert_eq(key, string::utf8(b"resource:/*"));
        assert!(resources::is_valid(&key));
    }

    // === Wildcard Tests ===

    #[test]
    fun test_wildcard_prefix() {
        let base = resources::vault_config();
        let wildcard = resources::wildcard_prefix(base);
        assert!(wildcard.length() == base.length() + 1);
        assert!(wildcard.index_of(&string::utf8(b"*")) == wildcard.length() - 1);
    }

    #[test]
    fun test_matches_exact() {
        let key = resources::vault_config();
        assert!(resources::matches(&key, &key));

        let different = resources::governance_propose();
        assert!(!resources::matches(&key, &different));
    }

    #[test]
    fun test_matches_wildcard_any() {
        let any = resources::any();
        let key1 = resources::vault_config();
        let key2 = resources::governance_propose();
        let key3 = resources::package_publish();

        assert!(resources::matches(&any, &key1));
        assert!(resources::matches(&any, &key2));
        assert!(resources::matches(&any, &key3));
    }

    #[test]
    fun test_matches_prefix_wildcard() {
        let vault_config = resources::vault_config();
        let vault_pattern = resources::wildcard_prefix(vault_config);

        // Should match itself
        assert!(resources::matches(&vault_pattern, &vault_config));

        // Should not match different category
        let governance = resources::governance_propose();
        assert!(!resources::matches(&vault_pattern, &governance));
    }

    #[test]
    fun test_matches_embedded_wildcard_fails() {
        // Embedded * should not match
        let invalid_pattern = string::utf8(b"resource:/vault/*/spend");
        let key = resources::vault_config();
        assert!(!resources::matches(&invalid_pattern, &key));
    }

    // === Scoped Resource Tests ===

    #[test]
    fun test_for_proposal() {
        let proposal_key = string::utf8(b"prop_123");
        let resource = resources::vault_config();
        let scoped = resources::for_proposal(proposal_key, resource);

        assert!(resources::is_valid(&scoped));
        assert!(scoped.index_of(&string::utf8(b"proposal/prop_123")) < scoped.length());
        assert!(scoped.index_of(&string::utf8(b"vault/config")) < scoped.length());
    }

    #[test]
    fun test_for_role() {
        let role = string::utf8(b"admin");
        let resource = resources::vault_spend<SUI>();
        let role_scoped = resources::for_role(role, resource);

        assert!(resources::is_valid(&role_scoped));
        assert!(role_scoped.index_of(&string::utf8(b"role/admin")) < role_scoped.length());
        assert!(role_scoped.index_of(&string::utf8(b"vault/spend")) < role_scoped.length());
    }

    #[test]
    fun test_with_timelock() {
        let delay_ms = 86400000u64; // 24 hours
        let resource = resources::package_upgrade(@0x123, string::utf8(b"core"));
        let timelocked = resources::with_timelock(delay_ms, resource);

        assert!(resources::is_valid(&timelocked));
        assert!(timelocked.index_of(&string::utf8(b"timelock/86400000")) < timelocked.length());
        assert!(timelocked.index_of(&string::utf8(b"package/upgrade")) < timelocked.length());
    }

    #[test]
    fun test_with_threshold() {
        let required = 3u64;
        let total = 5u64;
        let resource = resources::governance_params();
        let threshold = resources::with_threshold(required, total, resource);

        assert!(resources::is_valid(&threshold));
        assert!(threshold.index_of(&string::utf8(b"threshold/3of5")) < threshold.length());
        assert!(threshold.index_of(&string::utf8(b"governance/params")) < threshold.length());
    }

    // === Critical Resource Detection Tests ===

    #[test]
    fun test_is_critical_resource_emergency() {
        let emergency = resources::governance_emergency();
        assert!(resources::is_critical_resource(&emergency));

        let security = resources::security_emergency_action();
        assert!(resources::is_critical_resource(&security));
    }

    #[test]
    fun test_is_critical_resource_restrict() {
        let restrict = resources::package_restrict(@0x1, string::utf8(b"pkg"));
        assert!(resources::is_critical_resource(&restrict));
    }

    #[test]
    fun test_is_critical_resource_mint() {
        let mint = resources::vault_mint<SUI>();
        assert!(resources::is_critical_resource(&mint));
    }

    #[test]
    fun test_is_not_critical_resource() {
        let regular1 = resources::vault_config();
        assert!(!resources::is_critical_resource(&regular1));

        let regular2 = resources::governance_propose();
        assert!(!resources::is_critical_resource(&regular2));

        let regular3 = resources::operations_agreement();
        assert!(!resources::is_critical_resource(&regular3));
    }

    // === Category Extraction Tests ===

    #[test]
    fun test_get_category_package() {
        let key = resources::package_publish();
        assert_eq(resources::get_category(&key), string::utf8(b"package"));
    }

    #[test]
    fun test_get_category_vault() {
        let key = resources::vault_config();
        assert_eq(resources::get_category(&key), string::utf8(b"vault"));
    }

    #[test]
    fun test_get_category_governance() {
        let key = resources::governance_propose();
        assert_eq(resources::get_category(&key), string::utf8(b"governance"));
    }

    #[test]
    fun test_get_category_operations() {
        let key = resources::operations_agreement();
        assert_eq(resources::get_category(&key), string::utf8(b"operations"));
    }

    #[test]
    fun test_get_category_liquidity() {
        let key = resources::liquidity_params();
        assert_eq(resources::get_category(&key), string::utf8(b"liquidity"));
    }

    #[test]
    fun test_get_category_security() {
        let key = resources::security_veto();
        assert_eq(resources::get_category(&key), string::utf8(b"security"));
    }

    #[test]
    fun test_get_category_streams() {
        let key = resources::streams_cancel();
        assert_eq(resources::get_category(&key), string::utf8(b"streams"));
    }

    #[test]
    fun test_get_category_ext() {
        let key = resources::ext(@0x1, string::utf8(b"mod"), string::utf8(b"act"));
        assert_eq(resources::get_category(&key), string::utf8(b"ext"));
    }

    #[test]
    fun test_get_category_other() {
        let key = resources::other(string::utf8(b"path"));
        assert_eq(resources::get_category(&key), string::utf8(b"other"));
    }

    #[test]
    fun test_get_category_invalid() {
        let invalid = string::utf8(b"not_a_resource_key");
        assert_eq(resources::get_category(&invalid), string::utf8(b"unknown"));
    }

    // === Edge Case Tests ===

    #[test]
    fun test_different_coin_types_produce_different_keys() {
        let key1 = resources::vault_spend<TEST_COIN>();
        let key2 = resources::vault_spend<OTHER_COIN>();
        assert!(key1 != key2);

        let key3 = resources::vault_mint<TEST_COIN>();
        let key4 = resources::vault_mint<OTHER_COIN>();
        assert!(key3 != key4);
    }

    #[test]
    fun test_zero_address_package_keys() {
        let key = resources::package_upgrade(@0x0, string::utf8(b"test"));
        assert!(resources::is_valid(&key));
        assert!(key.index_of(&string::utf8(b"0000000000000000000000000000000000000000000000000000000000000000")) < key.length());
    }

    #[test]
    fun test_empty_string_parameters() {
        let key1 = resources::package_upgrade(@0x123, string::utf8(b""));
        assert!(resources::is_valid(&key1));

        let key2 = resources::other(string::utf8(b""));
        assert!(resources::is_valid(&key2));
    }

    #[test]
    fun test_long_string_parameters() {
        let long_name = string::utf8(b"very_long_package_name_that_is_quite_descriptive_and_contains_many_characters");
        let key = resources::package_upgrade(@0x123, long_name);
        assert!(resources::is_valid(&key));
        assert!(key.length() > 100);
    }

    #[test]
    fun test_unicode_in_names() {
        let unicode_name = string::utf8(b"test_\xF0\x9F\x9A\x80_rocket");
        let key = resources::other(unicode_name);
        assert!(resources::is_valid(&key));
    }

    #[test]
    fun test_threshold_zero_values() {
        let resource = resources::governance_params();
        let threshold = resources::with_threshold(0, 0, resource);
        assert!(resources::is_valid(&threshold));
        assert!(threshold.index_of(&string::utf8(b"threshold/0of0")) < threshold.length());
    }

    #[test]
    fun test_timelock_zero_delay() {
        let resource = resources::package_publish();
        let timelocked = resources::with_timelock(0, resource);
        assert!(resources::is_valid(&timelocked));
        assert!(timelocked.index_of(&string::utf8(b"timelock/0")) < timelocked.length());
    }

    #[test]
    fun test_timelock_max_delay() {
        let max_delay = 18446744073709551615u64; // u64::MAX
        let resource = resources::vault_config();
        let timelocked = resources::with_timelock(max_delay, resource);
        assert!(resources::is_valid(&timelocked));
    }

    // === Integration Tests ===

    #[test]
    fun test_complete_workflow_package_upgrade() {
        // Create base resource key
        let resource = resources::package_upgrade(@0xABC, string::utf8(b"core"));

        // Apply role scoping
        let admin_resource = resources::for_role(string::utf8(b"admin"), resource);

        // Apply timelock
        let timelocked = resources::with_timelock(86400000, admin_resource);

        // Verify all components present
        assert!(resources::is_valid(&timelocked));
        assert!(timelocked.index_of(&string::utf8(b"timelock")) < timelocked.length());
        assert!(timelocked.index_of(&string::utf8(b"role/admin")) < timelocked.length());
        assert!(timelocked.index_of(&string::utf8(b"package/upgrade")) < timelocked.length());
    }

    #[test]
    fun test_complete_workflow_vault_spending() {
        // Create vault spend key
        let resource = resources::vault_spend<SUI>();

        // Create threshold requirement
        let threshold = resources::with_threshold(3, 5, resource);

        // Scope to proposal
        let proposal_scoped = resources::for_proposal(string::utf8(b"prop_123"), threshold);

        // Verify composability
        assert!(resources::is_valid(&proposal_scoped));
        assert!(proposal_scoped.index_of(&string::utf8(b"proposal/prop_123")) < proposal_scoped.length());
        assert!(proposal_scoped.index_of(&string::utf8(b"threshold/3of5")) < proposal_scoped.length());
        assert!(proposal_scoped.index_of(&string::utf8(b"vault/spend")) < proposal_scoped.length());
    }
}
