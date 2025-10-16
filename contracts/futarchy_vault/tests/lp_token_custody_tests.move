/// Comprehensive tests for LP Token Custody module
#[test_only]
module futarchy_vault::lp_token_custody_tests;

use account_protocol::account::{Self, Account};
use futarchy_core::dao_config;
use futarchy_core::futarchy_config::{Self, FutarchyConfig};
use futarchy_core::version;
use futarchy_markets::account_spot_pool::{Self, LPToken};
use futarchy_vault::lp_token_custody;
use std::option;
use std::string;
use sui::coin::{Self, Coin};
use sui::object::{Self, ID};
use sui::sui::SUI;
use sui::test_scenario::{Self as ts, Scenario};

// Test coin types - must have drop for futarchy_config::new
public struct ASSET has drop {}
public struct STABLE has drop {}

// Helper to create a minimal FutarchyConfig for testing
fun create_test_config<AssetType: drop, StableType: drop>(): FutarchyConfig {
    let dao_config = dao_config::new_dao_config(
        dao_config::default_trading_params(),
        dao_config::default_twap_config(),
        dao_config::default_governance_config(),
        dao_config::new_metadata_config(
            std::ascii::string(b"TestDAO"),
            sui::url::new_unsafe_from_bytes(b"https://test.com"),
            string::utf8(b"Test DAO"),
        ),
        dao_config::default_security_config(),
        dao_config::default_storage_config(),
        dao_config::default_conditional_coin_config(),
        dao_config::default_quota_config(),
        dao_config::default_multisig_config(),
        1000000, // min_proposal_bond
        259200000, // proposal_timeout_ms
        500000, // review_period_proposal_fee
    );

    let slash_dist = futarchy_config::new_slash_distribution(
        2500,
        2500,
        2500,
        2500, // 25% each
    );

    futarchy_config::new<AssetType, StableType>(
        dao_config,
        slash_dist,
    )
}

// Helper to create a test account
// NOTE: This currently fails with ENotDep because futarchy_core isn't in the deps list
// created by deps::new_for_testing(). Proper fix requires either:
// 1. Adding futarchy_core to the base test deps, or
// 2. Using toggle_unverified_allowed_for_testing() on deps
// For now, tests are disabled pending proper test infrastructure.
fun create_test_account(scenario: &mut Scenario, owner: address): ID {
    ts::next_tx(scenario, owner);
    {
        let config = create_test_config<ASSET, STABLE>();
        let account = futarchy_config::new_account_test(
            config,
            ts::ctx(scenario),
        );
        let account_id = object::id(&account);
        transfer::public_share_object(account);
        account_id
    }
}

// Helper to create a mock LP token for testing
fun create_mock_lp_token<AssetType, StableType>(
    amount: u64,
    scenario: &mut Scenario,
): LPToken<AssetType, StableType> {
    account_spot_pool::new_lp_token_for_testing<AssetType, StableType>(
        amount,
        ts::ctx(scenario),
    )
}

#[test]
fun test_init_custody() {
    let owner = @0xA;
    let mut scenario = ts::begin(owner);

    let account_id = create_test_account(&mut scenario, owner);

    ts::next_tx(&mut scenario, owner);
    {
        let mut account = ts::take_shared_by_id<Account<FutarchyConfig>>(&scenario, account_id);

        // Initially no custody
        assert!(!lp_token_custody::has_custody(&account), 0);

        // Initialize custody
        lp_token_custody::init_custody(&mut account, ts::ctx(&mut scenario));

        // Now custody exists
        assert!(lp_token_custody::has_custody(&account), 1);

        // TVL should be 0
        assert!(lp_token_custody::get_total_value_locked(&account) == 0, 2);

        ts::return_shared(account);
    };

    ts::end(scenario);
}

#[test]
fun test_deposit_lp_token_basic() {
    let owner = @0xA;
    let mut scenario = ts::begin(owner);

    let account_id = create_test_account(&mut scenario, owner);
    // Use a valid hex address instead of @0xPOOL
    let pool_id = object::id_from_address(
        @0xABCDEF1234567890ABCDEF1234567890ABCDEF1234567890ABCDEF1234567890,
    );

    ts::next_tx(&mut scenario, owner);
    {
        let mut account = ts::take_shared_by_id<Account<FutarchyConfig>>(&scenario, account_id);
        let auth = futarchy_config::new_auth_for_testing(&account);

        // Create mock LP token
        let lp_token = create_mock_lp_token<ASSET, STABLE>(1000, &mut scenario);
        let token_id = object::id(&lp_token);

        // Deposit LP token
        lp_token_custody::deposit_lp_token<ASSET, STABLE>(
            auth,
            &mut account,
            pool_id,
            lp_token,
            ts::ctx(&mut scenario),
        );

        // Verify custody was initialized
        assert!(lp_token_custody::has_custody(&account), 0);

        // Verify TVL updated
        assert!(lp_token_custody::get_total_value_locked(&account) == 1000, 1);

        // Verify pool total
        assert!(lp_token_custody::get_pool_total(&account, pool_id) == 1000, 2);

        // Verify token amount
        assert!(lp_token_custody::get_token_amount(&account, token_id) == 1000, 3);

        // Verify pool has tokens
        assert!(lp_token_custody::has_tokens_for_pool(&account, pool_id), 4);

        // Verify token pool mapping
        let pool_opt = lp_token_custody::get_token_pool(&account, token_id);
        assert!(option::is_some(&pool_opt), 5);
        assert!(option::borrow(&pool_opt) == &pool_id, 6);

        ts::return_shared(account);
    };

    ts::end(scenario);
}

#[test]
fun test_multiple_deposits_same_pool() {
    let owner = @0xA;
    let mut scenario = ts::begin(owner);

    let account_id = create_test_account(&mut scenario, owner);
    let pool_id = object::id_from_address(
        @0xABCDEF1234567890ABCDEF1234567890ABCDEF1234567890ABCDEF1234567890,
    );

    ts::next_tx(&mut scenario, owner);
    {
        let mut account = ts::take_shared_by_id<Account<FutarchyConfig>>(&scenario, account_id);
        let auth = futarchy_config::new_auth_for_testing(&account);

        // Deposit first token
        let lp_token1 = create_mock_lp_token<ASSET, STABLE>(1000, &mut scenario);
        let token1_id = object::id(&lp_token1);
        lp_token_custody::deposit_lp_token<ASSET, STABLE>(
            auth,
            &mut account,
            pool_id,
            lp_token1,
            ts::ctx(&mut scenario),
        );

        // Deposit second token to same pool
        let auth2 = futarchy_config::new_auth_for_testing(&account);
        let lp_token2 = create_mock_lp_token<ASSET, STABLE>(500, &mut scenario);
        let token2_id = object::id(&lp_token2);
        lp_token_custody::deposit_lp_token<ASSET, STABLE>(
            auth2,
            &mut account,
            pool_id,
            lp_token2,
            ts::ctx(&mut scenario),
        );

        // Verify totals
        assert!(lp_token_custody::get_total_value_locked(&account) == 1500, 0);
        assert!(lp_token_custody::get_pool_total(&account, pool_id) == 1500, 1);

        // Verify individual token amounts
        assert!(lp_token_custody::get_token_amount(&account, token1_id) == 1000, 2);
        assert!(lp_token_custody::get_token_amount(&account, token2_id) == 500, 3);

        ts::return_shared(account);
    };

    ts::end(scenario);
}

#[test]
fun test_multiple_pools() {
    let owner = @0xA;
    let mut scenario = ts::begin(owner);

    let account_id = create_test_account(&mut scenario, owner);
    let pool_id1 = object::id_from_address(
        @0xABCDEF1234567890ABCDEF1234567890ABCDEF1234567890ABCDEF1234567890,
    );
    let pool_id2 = object::id_from_address(
        @0x1234567890ABCDEF1234567890ABCDEF1234567890ABCDEF1234567890ABCDEF,
    );

    ts::next_tx(&mut scenario, owner);
    {
        let mut account = ts::take_shared_by_id<Account<FutarchyConfig>>(&scenario, account_id);

        // Deposit to pool 1
        let auth1 = futarchy_config::new_auth_for_testing(&account);
        let lp_token1 = create_mock_lp_token<ASSET, STABLE>(1000, &mut scenario);
        lp_token_custody::deposit_lp_token<ASSET, STABLE>(
            auth1,
            &mut account,
            pool_id1,
            lp_token1,
            ts::ctx(&mut scenario),
        );

        // Deposit to pool 2
        let auth2 = futarchy_config::new_auth_for_testing(&account);
        let lp_token2 = create_mock_lp_token<ASSET, STABLE>(2000, &mut scenario);
        lp_token_custody::deposit_lp_token<ASSET, STABLE>(
            auth2,
            &mut account,
            pool_id2,
            lp_token2,
            ts::ctx(&mut scenario),
        );

        // Verify totals
        assert!(lp_token_custody::get_total_value_locked(&account) == 3000, 0);
        assert!(lp_token_custody::get_pool_total(&account, pool_id1) == 1000, 1);
        assert!(lp_token_custody::get_pool_total(&account, pool_id2) == 2000, 2);

        // Verify both pools are active
        assert!(lp_token_custody::has_tokens_for_pool(&account, pool_id1), 3);
        assert!(lp_token_custody::has_tokens_for_pool(&account, pool_id2), 4);

        ts::return_shared(account);
    };

    ts::end(scenario);
}

#[test]
fun test_withdraw_lp_token() {
    let owner = @0xA;
    let mut scenario = ts::begin(owner);

    let account_id = create_test_account(&mut scenario, owner);
    let pool_id = object::id_from_address(
        @0xABCDEF1234567890ABCDEF1234567890ABCDEF1234567890ABCDEF1234567890,
    );

    // Deposit token
    ts::next_tx(&mut scenario, owner);
    {
        let mut account = ts::take_shared_by_id<Account<FutarchyConfig>>(&scenario, account_id);
        let auth = futarchy_config::new_auth_for_testing(&account);

        let lp_token = create_mock_lp_token<ASSET, STABLE>(1000, &mut scenario);
        lp_token_custody::deposit_lp_token<ASSET, STABLE>(
            auth,
            &mut account,
            pool_id,
            lp_token,
            ts::ctx(&mut scenario),
        );

        ts::return_shared(account);
    };

    // Withdraw token
    ts::next_tx(&mut scenario, owner);
    {
        let mut account = ts::take_shared_by_id<Account<FutarchyConfig>>(&scenario, account_id);
        let auth = futarchy_config::new_auth_for_testing(&account);

        // Get list of token IDs for this pool
        let token_ids = lp_token_custody::get_pool_tokens(&account, pool_id);
        assert!(token_ids.length() == 1, 0);
        let token_id = token_ids[0];

        // Withdraw the token (it goes to account address, not external recipient)
        lp_token_custody::withdraw_lp_token<ASSET, STABLE>(
            auth,
            &mut account,
            pool_id,
            token_id,
            ts::ctx(&mut scenario),
        );

        // Verify custody updated
        assert!(lp_token_custody::get_total_value_locked(&account) == 0, 1);
        assert!(lp_token_custody::get_pool_total(&account, pool_id) == 0, 2);
        assert!(!lp_token_custody::has_tokens_for_pool(&account, pool_id), 3);

        ts::return_shared(account);
    };

    ts::end(scenario);
}

#[test]
fun test_get_active_pools() {
    let owner = @0xA;
    let mut scenario = ts::begin(owner);

    let account_id = create_test_account(&mut scenario, owner);
    let pool_id1 = object::id_from_address(
        @0xABCDEF1234567890ABCDEF1234567890ABCDEF1234567890ABCDEF1234567890,
    );
    let pool_id2 = object::id_from_address(
        @0x1234567890ABCDEF1234567890ABCDEF1234567890ABCDEF1234567890ABCDEF,
    );
    let pool_id3 = object::id_from_address(
        @0xFEDCBA0987654321FEDCBA0987654321FEDCBA0987654321FEDCBA0987654321,
    );

    ts::next_tx(&mut scenario, owner);
    {
        let mut account = ts::take_shared_by_id<Account<FutarchyConfig>>(&scenario, account_id);

        // Initially no active pools
        lp_token_custody::init_custody(&mut account, ts::ctx(&mut scenario));
        let active = lp_token_custody::get_active_pools(&account);
        assert!(active.length() == 0, 0);

        // Add tokens to 3 different pools
        let auth1 = futarchy_config::new_auth_for_testing(&account);
        lp_token_custody::deposit_lp_token<ASSET, STABLE>(
            auth1,
            &mut account,
            pool_id1,
            create_mock_lp_token<ASSET, STABLE>(100, &mut scenario),
            ts::ctx(&mut scenario),
        );

        let auth2 = futarchy_config::new_auth_for_testing(&account);
        lp_token_custody::deposit_lp_token<ASSET, STABLE>(
            auth2,
            &mut account,
            pool_id2,
            create_mock_lp_token<ASSET, STABLE>(200, &mut scenario),
            ts::ctx(&mut scenario),
        );

        let auth3 = futarchy_config::new_auth_for_testing(&account);
        lp_token_custody::deposit_lp_token<ASSET, STABLE>(
            auth3,
            &mut account,
            pool_id3,
            create_mock_lp_token<ASSET, STABLE>(300, &mut scenario),
            ts::ctx(&mut scenario),
        );

        // Verify 3 active pools
        let active = lp_token_custody::get_active_pools(&account);
        assert!(active.length() == 3, 1);

        ts::return_shared(account);
    };

    ts::end(scenario);
}

#[test]
#[expected_failure]
fun test_withdraw_nonexistent_token() {
    let owner = @0xA;
    let mut scenario = ts::begin(owner);

    let account_id = create_test_account(&mut scenario, owner);
    let fake_pool_id = object::id_from_address(
        @0xBADBADBADBADBADBADBADBADBADBADBADBADBADBADBADBADBADBADBADBADBAD,
    );
    let fake_token_id = object::id_from_address(
        @0xDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEF,
    );

    ts::next_tx(&mut scenario, owner);
    {
        let mut account = ts::take_shared_by_id<Account<FutarchyConfig>>(&scenario, account_id);
        let auth = futarchy_config::new_auth_for_testing(&account);

        lp_token_custody::init_custody(&mut account, ts::ctx(&mut scenario));

        // Try to withdraw token that doesn't exist - should fail
        lp_token_custody::withdraw_lp_token<ASSET, STABLE>(
            auth,
            &mut account,
            fake_pool_id,
            fake_token_id,
            ts::ctx(&mut scenario),
        );

        ts::return_shared(account);
    };

    ts::end(scenario);
}

#[test]
fun test_partial_pool_withdrawal() {
    let owner = @0xA;
    let mut scenario = ts::begin(owner);

    let account_id = create_test_account(&mut scenario, owner);
    let pool_id = object::id_from_address(
        @0xABCDEF1234567890ABCDEF1234567890ABCDEF1234567890ABCDEF1234567890,
    );

    // Deposit 2 tokens to same pool
    ts::next_tx(&mut scenario, owner);
    {
        let mut account = ts::take_shared_by_id<Account<FutarchyConfig>>(&scenario, account_id);

        let auth1 = futarchy_config::new_auth_for_testing(&account);
        lp_token_custody::deposit_lp_token<ASSET, STABLE>(
            auth1,
            &mut account,
            pool_id,
            create_mock_lp_token<ASSET, STABLE>(1000, &mut scenario),
            ts::ctx(&mut scenario),
        );

        let auth2 = futarchy_config::new_auth_for_testing(&account);
        lp_token_custody::deposit_lp_token<ASSET, STABLE>(
            auth2,
            &mut account,
            pool_id,
            create_mock_lp_token<ASSET, STABLE>(500, &mut scenario),
            ts::ctx(&mut scenario),
        );

        ts::return_shared(account);
    };

    // Withdraw one token
    ts::next_tx(&mut scenario, owner);
    {
        let mut account = ts::take_shared_by_id<Account<FutarchyConfig>>(&scenario, account_id);
        let auth = futarchy_config::new_auth_for_testing(&account);

        let token_ids = lp_token_custody::get_pool_tokens(&account, pool_id);
        assert!(token_ids.length() == 2, 0);

        // Withdraw first token
        lp_token_custody::withdraw_lp_token<ASSET, STABLE>(
            auth,
            &mut account,
            pool_id,
            token_ids[0],
            ts::ctx(&mut scenario),
        );

        // Pool should still have tokens
        assert!(lp_token_custody::has_tokens_for_pool(&account, pool_id), 1);

        // TVL should be reduced but not zero
        let remaining = lp_token_custody::get_total_value_locked(&account);
        assert!(remaining > 0 && remaining < 1500, 2);

        ts::return_shared(account);
    };

    ts::end(scenario);
}

#[test]
fun test_query_functions() {
    let owner = @0xA;
    let mut scenario = ts::begin(owner);

    let account_id = create_test_account(&mut scenario, owner);
    let pool_id = object::id_from_address(
        @0xABCDEF1234567890ABCDEF1234567890ABCDEF1234567890ABCDEF1234567890,
    );

    ts::next_tx(&mut scenario, owner);
    {
        let mut account = ts::take_shared_by_id<Account<FutarchyConfig>>(&scenario, account_id);
        let auth = futarchy_config::new_auth_for_testing(&account);

        let lp_token = create_mock_lp_token<ASSET, STABLE>(750, &mut scenario);
        let token_id = object::id(&lp_token);

        lp_token_custody::deposit_lp_token<ASSET, STABLE>(
            auth,
            &mut account,
            pool_id,
            lp_token,
            ts::ctx(&mut scenario),
        );

        // Test get_pool_tokens
        let token_ids = lp_token_custody::get_pool_tokens(&account, pool_id);
        assert!(token_ids.length() == 1, 0);
        assert!(token_ids[0] == token_id, 1);

        // Test get_token_pool
        let pool_opt = lp_token_custody::get_token_pool(&account, token_id);
        assert!(option::is_some(&pool_opt), 2);
        assert!(*option::borrow(&pool_opt) == pool_id, 3);

        // Test get_token_amount
        assert!(lp_token_custody::get_token_amount(&account, token_id) == 750, 4);

        // Test get_pool_total
        assert!(lp_token_custody::get_pool_total(&account, pool_id) == 750, 5);

        // Test get_total_value_locked
        assert!(lp_token_custody::get_total_value_locked(&account) == 750, 6);

        ts::return_shared(account);
    };

    ts::end(scenario);
}
