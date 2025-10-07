/// Tests for vault_access module
#[test_only]
module futarchy_payments::vault_access_tests;

use std::string;
use sui::test_scenario::{Self as ts};
use sui::coin::{Self, Coin};
use sui::sui::SUI;
use sui::test_utils;
use account_protocol::{
    account::{Self, Account},
    version_witness,
};
use account_actions::vault;
use futarchy_core::futarchy_config::{Self, FutarchyConfig};
use futarchy_payments::vault_access;

const ADMIN: address = @0xAD;

// Test coin type
public struct USDC has drop {}

// Helper to create test account with treasury vault
fun create_account_with_treasury(ctx: &mut TxContext): Account<FutarchyConfig> {
    let config_id = futarchy_config::create_config_for_testing(
        string::utf8(b"Test DAO"),
        ctx
    );
    let mut account = account::create_for_testing<FutarchyConfig>(config_id, ctx);

    // Create treasury vault
    let version = version_witness::test_version();
    vault::new_vault(&mut account, string::utf8(b"treasury"), version, ctx);

    account
}

#[test]
fun test_get_treasury_vault_success() {
    let mut scenario = ts::begin(ADMIN);

    let account = create_account_with_treasury(ts::ctx(&mut scenario));

    let treasury = vault_access::get_treasury_vault(&account);
    assert!(vault::get_name(treasury) == string::utf8(b"treasury"), 0);

    test_utils::destroy(account);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = vault_access::e_treasury_vault_required())]
fun test_get_treasury_vault_not_found() {
    let mut scenario = ts::begin(ADMIN);

    // Create account without treasury vault
    let config_id = futarchy_config::create_config_for_testing(
        string::utf8(b"Test DAO"),
        ts::ctx(&mut scenario)
    );
    let account = account::create_for_testing<FutarchyConfig>(config_id, ts::ctx(&mut scenario));

    let _treasury = vault_access::get_treasury_vault(&account);

    test_utils::destroy(account);
    ts::end(scenario);
}

#[test]
fun test_get_treasury_balance_empty_vault() {
    let mut scenario = ts::begin(ADMIN);

    let account = create_account_with_treasury(ts::ctx(&mut scenario));

    let balance = vault_access::get_treasury_balance<FutarchyConfig, SUI>(&account);
    assert!(balance == 0, 0);

    test_utils::destroy(account);
    ts::end(scenario);
}

#[test]
fun test_get_treasury_balance_with_funds() {
    let mut scenario = ts::begin(ADMIN);

    let mut account = create_account_with_treasury(ts::ctx(&mut scenario));
    let version = version_witness::test_version();

    // Deposit some SUI
    let coin = coin::mint_for_testing<SUI>(1_000_000, ts::ctx(&mut scenario));
    vault::deposit<FutarchyConfig, SUI>(
        &mut account,
        string::utf8(b"treasury"),
        coin,
        version,
        ts::ctx(&mut scenario)
    );

    let balance = vault_access::get_treasury_balance<FutarchyConfig, SUI>(&account);
    assert!(balance == 1_000_000, 0);

    test_utils::destroy(account);
    ts::end(scenario);
}

#[test]
fun test_assert_treasury_balance_sufficient() {
    let mut scenario = ts::begin(ADMIN);

    let mut account = create_account_with_treasury(ts::ctx(&mut scenario));
    let version = version_witness::test_version();

    // Deposit some SUI
    let coin = coin::mint_for_testing<SUI>(1_000_000, ts::ctx(&mut scenario));
    vault::deposit<FutarchyConfig, SUI>(
        &mut account,
        string::utf8(b"treasury"),
        coin,
        version,
        ts::ctx(&mut scenario)
    );

    // Assert sufficient balance - should pass
    vault_access::assert_treasury_balance<FutarchyConfig, SUI>(&account, 500_000);
    vault_access::assert_treasury_balance<FutarchyConfig, SUI>(&account, 1_000_000);

    test_utils::destroy(account);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = vault_access::e_insufficient_treasury_balance())]
fun test_assert_treasury_balance_insufficient() {
    let mut scenario = ts::begin(ADMIN);

    let mut account = create_account_with_treasury(ts::ctx(&mut scenario));
    let version = version_witness::test_version();

    // Deposit 1M
    let coin = coin::mint_for_testing<SUI>(1_000_000, ts::ctx(&mut scenario));
    vault::deposit<FutarchyConfig, SUI>(
        &mut account,
        string::utf8(b"treasury"),
        coin,
        version,
        ts::ctx(&mut scenario)
    );

    // Try to assert 2M - should fail
    vault_access::assert_treasury_balance<FutarchyConfig, SUI>(&account, 2_000_000);

    test_utils::destroy(account);
    ts::end(scenario);
}

#[test]
fun test_error_message_treasury_not_found() {
    let msg = vault_access::error_message(vault_access::e_treasury_vault_not_found());
    assert!(msg == b"Account does not have a vault with the specified name. Ensure vault exists before using dividend actions.", 0);
}

#[test]
fun test_error_message_insufficient_balance() {
    let msg = vault_access::error_message(vault_access::e_insufficient_treasury_balance());
    assert!(msg == b"Treasury vault does not have sufficient balance for this operation.", 0);
}

#[test]
fun test_error_message_treasury_required() {
    let msg = vault_access::error_message(vault_access::e_treasury_vault_required());
    assert!(msg.length() > 0, 0); // Just verify it returns a message
}

#[test]
fun test_error_message_unknown_code() {
    let msg = vault_access::error_message(9999);
    assert!(msg == b"Unknown vault access error", 0);
}
