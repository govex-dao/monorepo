/// Comprehensive tests for dividend_actions.move
/// Tests dividend creation, cranking, claiming, and all error paths
#[test_only]
module futarchy_dividend_actions::dividend_actions_tests;

use account_extensions::extensions::{Self, Extensions};
use account_protocol::account::{Self, Account};
use account_protocol::executable::{Self, Executable};
use account_protocol::intents::{Self, IntentSpec};
use account_protocol::version_witness;
use futarchy_core::futarchy_config::{Self, FutarchyConfig};
use futarchy_dividend_actions::dividend_actions;
use futarchy_dividend_actions::dividend_tree::{Self, DividendTree};
use std::string;
use sui::balance;
use sui::clock::{Self, Clock};
use sui::coin::{Self, Coin};
use sui::sui::SUI;
use sui::test_scenario as ts;
use sui::test_utils::assert_eq;

// === Test Addresses ===
const ADMIN: address = @0xAD;
const ALICE: address = @0xA1;
const BOB: address = @0xB2;
const CAROL: address = @0xC3;
const DAVE: address = @0xD4;
const EVE: address = @0xE5;

// === Test Helpers ===

fun create_test_account(scenario: &mut ts::Scenario): Account<FutarchyConfig> {
    let extensions = extensions::empty(ts::ctx(scenario));
    futarchy_config::new_account(
        string::utf8(b"Test DAO"),
        extensions,
        ts::ctx(scenario),
    )
}

fun create_test_tree_with_recipients(
    recipients: vector<address>,
    amounts: vector<u64>,
    scenario: &mut ts::Scenario,
): DividendTree {
    let mut tree = dividend_tree::create_tree<SUI>(
        string::utf8(b"Test Dividend"),
        ts::ctx(scenario),
    );

    // Add all recipients to a single bucket with prefix 0x00
    dividend_tree::add_bucket(
        &mut tree,
        vector[0x00],
        recipients,
        amounts,
        0,
        ts::ctx(scenario),
    );

    // Finalize tree
    dividend_tree::finalize_tree(&mut tree);

    tree
}

fun create_small_test_tree(scenario: &mut ts::Scenario): DividendTree {
    create_test_tree_with_recipients(
        vector[ALICE, BOB],
        vector[1000, 2000],
        scenario,
    )
}

// === CreateDividendAction Tests ===

#[test]
fun test_create_dividend_action_constructor() {
    let action = dividend_actions::new_create_dividend_action<SUI>(@0x123.to_id());
    dividend_actions::delete_create_dividend<SUI>(&mut intents::create_expired_for_testing());
}

#[test]
fun test_do_create_dividend_basic() {
    let mut scenario = ts::begin(ADMIN);
    let clock = clock::create_for_testing(ts::ctx(&mut scenario));

    // Create account
    let mut account = create_test_account(&mut scenario);

    // Create and finalize tree
    let tree = create_small_test_tree(&mut scenario);
    let tree_id = dividend_tree::tree_id(&tree);
    let total_amount = dividend_tree::total_amount(&tree);

    // Create action and executable
    let action = dividend_actions::new_create_dividend_action<SUI>(tree_id);
    let action_data = std::bcs::to_bytes(&action);

    // Create intent spec
    let mut builder = intents::intent_builder(ts::ctx(&mut scenario));
    intents::add_action(
        &mut builder,
        std::type_name::get<dividend_actions::CreateDividendAction<SUI>>(),
        action_data,
    );
    let intent_spec = intents::build(builder);

    // Create executable
    let mut executable = executable::test_new<u8>(intent_spec, 0);

    // Execute do_create_dividend
    let request = dividend_actions::do_create_dividend<FutarchyConfig, u8, SUI, Extensions>(
        &mut executable,
        &mut account,
        tree,
        version_witness::test_create(),
        extensions::empty(ts::ctx(&mut scenario)),
        &clock,
        ts::ctx(&mut scenario),
    );

    // Verify action index incremented
    assert_eq(executable::action_idx(&executable), 1);

    // Fulfill request with coin
    let coin = coin::mint_for_testing<SUI>(total_amount, ts::ctx(&mut scenario));
    let receipt = dividend_actions::fulfill_create_dividend(
        request,
        coin,
        &mut account,
        &clock,
        ts::ctx(&mut scenario),
    );

    // Verify dividend info
    let (total, sent, total_recipients, sent_count) = dividend_actions::get_dividend_info(
        &account,
        *dividend_actions::resource_receipt_dividend_id(&receipt),
    );
    assert_eq(total, 3000);
    assert_eq(sent, 0);
    assert_eq(total_recipients, 2);
    assert_eq(sent_count, 0);

    executable::test_destroy(executable);
    account::destroy_account_for_testing(account);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = dividend_actions::ETreeNotFinalized)]
fun test_do_create_dividend_unfinalized_tree() {
    let mut scenario = ts::begin(ADMIN);
    let clock = clock::create_for_testing(ts::ctx(&mut scenario));

    let mut account = create_test_account(&mut scenario);

    // Create tree but DON'T finalize it
    let tree = dividend_tree::create_tree<SUI>(
        string::utf8(b"Unfinalized"),
        ts::ctx(&mut scenario),
    );
    let tree_id = dividend_tree::tree_id(&tree);

    let action = dividend_actions::new_create_dividend_action<SUI>(tree_id);
    let action_data = std::bcs::to_bytes(&action);

    let mut builder = intents::intent_builder(ts::ctx(&mut scenario));
    intents::add_action(
        &mut builder,
        std::type_name::get<dividend_actions::CreateDividendAction<SUI>>(),
        action_data,
    );
    let intent_spec = intents::build(builder);

    let mut executable = executable::test_new<u8>(intent_spec, 0);

    // This should fail because tree is not finalized
    let _request = dividend_actions::do_create_dividend<FutarchyConfig, u8, SUI, Extensions>(
        &mut executable,
        &mut account,
        tree,
        version_witness::test_create(),
        extensions::empty(ts::ctx(&mut scenario)),
        &clock,
        ts::ctx(&mut scenario),
    );

    executable::test_destroy(executable);
    account::destroy_account_for_testing(account);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = dividend_actions::EInsufficientFunds)]
fun test_fulfill_create_dividend_insufficient_funds() {
    let mut scenario = ts::begin(ADMIN);
    let clock = clock::create_for_testing(ts::ctx(&mut scenario));

    let mut account = create_test_account(&mut scenario);

    let tree = create_small_test_tree(&mut scenario);
    let tree_id = dividend_tree::tree_id(&tree);

    let action = dividend_actions::new_create_dividend_action<SUI>(tree_id);
    let action_data = std::bcs::to_bytes(&action);

    let mut builder = intents::intent_builder(ts::ctx(&mut scenario));
    intents::add_action(
        &mut builder,
        std::type_name::get<dividend_actions::CreateDividendAction<SUI>>(),
        action_data,
    );
    let intent_spec = intents::build(builder);

    let mut executable = executable::test_new<u8>(intent_spec, 0);

    let request = dividend_actions::do_create_dividend<FutarchyConfig, u8, SUI, Extensions>(
        &mut executable,
        &mut account,
        tree,
        version_witness::test_create(),
        extensions::empty(ts::ctx(&mut scenario)),
        &clock,
        ts::ctx(&mut scenario),
    );

    // Provide LESS coin than required (need 3000, provide 1000)
    let coin = coin::mint_for_testing<SUI>(1000, ts::ctx(&mut scenario));

    // This should fail
    let _receipt = dividend_actions::fulfill_create_dividend(
        request,
        coin,
        &mut account,
        &clock,
        ts::ctx(&mut scenario),
    );

    executable::test_destroy(executable);
    account::destroy_account_for_testing(account);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

// === Claim Tests ===

#[test]
fun test_claim_my_dividend() {
    let mut scenario = ts::begin(ADMIN);
    let clock = clock::create_for_testing(ts::ctx(&mut scenario));

    let mut account = create_test_account(&mut scenario);

    // Create tree with ALICE as recipient
    let tree = create_test_tree_with_recipients(
        vector[ALICE, BOB],
        vector[1000, 2000],
        &mut scenario,
    );
    let tree_id = dividend_tree::tree_id(&tree);
    let total_amount = dividend_tree::total_amount(&tree);

    let action = dividend_actions::new_create_dividend_action<SUI>(tree_id);
    let action_data = std::bcs::to_bytes(&action);

    let mut builder = intents::intent_builder(ts::ctx(&mut scenario));
    intents::add_action(
        &mut builder,
        std::type_name::get<dividend_actions::CreateDividendAction<SUI>>(),
        action_data,
    );
    let intent_spec = intents::build(builder);

    let mut executable = executable::test_new<u8>(intent_spec, 0);

    let request = dividend_actions::do_create_dividend<FutarchyConfig, u8, SUI, Extensions>(
        &mut executable,
        &mut account,
        tree,
        version_witness::test_create(),
        extensions::empty(ts::ctx(&mut scenario)),
        &clock,
        ts::ctx(&mut scenario),
    );

    let coin = coin::mint_for_testing<SUI>(total_amount, ts::ctx(&mut scenario));
    let receipt = dividend_actions::fulfill_create_dividend(
        request,
        coin,
        &mut account,
        &clock,
        ts::ctx(&mut scenario),
    );

    let dividend_id = *dividend_actions::resource_receipt_dividend_id(&receipt);

    // Switch to ALICE and claim
    ts::next_tx(&mut scenario, ALICE);
    {
        let prefix = vector[0x00]; // ALICE is in bucket 0x00
        let claimed = dividend_actions::claim_my_dividend<FutarchyConfig, SUI>(
            &mut account,
            dividend_id,
            prefix,
            ts::ctx(&mut scenario),
        );

        assert!(claimed);

        // Verify ALICE received the coin
        // (In real scenario, would check transfer recipient)
    };

    // Verify dividend progress updated
    let (_, sent, _, sent_count) = dividend_actions::get_dividend_info(&account, dividend_id);
    assert_eq(sent, 1000);
    assert_eq(sent_count, 1);

    executable::test_destroy(executable);
    account::destroy_account_for_testing(account);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
fun test_claim_my_dividend_wrong_prefix() {
    let mut scenario = ts::begin(ADMIN);
    let clock = clock::create_for_testing(ts::ctx(&mut scenario));

    let mut account = create_test_account(&mut scenario);

    let tree = create_test_tree_with_recipients(
        vector[ALICE],
        vector[1000],
        &mut scenario,
    );
    let tree_id = dividend_tree::tree_id(&tree);

    let action = dividend_actions::new_create_dividend_action<SUI>(tree_id);
    let action_data = std::bcs::to_bytes(&action);

    let mut builder = intents::intent_builder(ts::ctx(&mut scenario));
    intents::add_action(
        &mut builder,
        std::type_name::get<dividend_actions::CreateDividendAction<SUI>>(),
        action_data,
    );
    let intent_spec = intents::build(builder);

    let mut executable = executable::test_new<u8>(intent_spec, 0);

    let request = dividend_actions::do_create_dividend<FutarchyConfig, u8, SUI, Extensions>(
        &mut executable,
        &mut account,
        tree,
        version_witness::test_create(),
        extensions::empty(ts::ctx(&mut scenario)),
        &clock,
        ts::ctx(&mut scenario),
    );

    let coin = coin::mint_for_testing<SUI>(1000, ts::ctx(&mut scenario));
    let receipt = dividend_actions::fulfill_create_dividend(
        request,
        coin,
        &mut account,
        &clock,
        ts::ctx(&mut scenario),
    );

    let dividend_id = *dividend_actions::resource_receipt_dividend_id(&receipt);

    // Try to claim with wrong prefix
    ts::next_tx(&mut scenario, ALICE);
    {
        let wrong_prefix = vector[0xFF]; // Wrong prefix
        let claimed = dividend_actions::claim_my_dividend<FutarchyConfig, SUI>(
            &mut account,
            dividend_id,
            wrong_prefix,
            ts::ctx(&mut scenario),
        );

        // Should return false
        assert!(!claimed);
    };

    executable::test_destroy(executable);
    account::destroy_account_for_testing(account);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
fun test_claim_my_dividend_twice() {
    let mut scenario = ts::begin(ADMIN);
    let clock = clock::create_for_testing(ts::ctx(&mut scenario));

    let mut account = create_test_account(&mut scenario);

    let tree = create_test_tree_with_recipients(
        vector[ALICE],
        vector[1000],
        &mut scenario,
    );
    let tree_id = dividend_tree::tree_id(&tree);

    let action = dividend_actions::new_create_dividend_action<SUI>(tree_id);
    let action_data = std::bcs::to_bytes(&action);

    let mut builder = intents::intent_builder(ts::ctx(&mut scenario));
    intents::add_action(
        &mut builder,
        std::type_name::get<dividend_actions::CreateDividendAction<SUI>>(),
        action_data,
    );
    let intent_spec = intents::build(builder);

    let mut executable = executable::test_new<u8>(intent_spec, 0);

    let request = dividend_actions::do_create_dividend<FutarchyConfig, u8, SUI, Extensions>(
        &mut executable,
        &mut account,
        tree,
        version_witness::test_create(),
        extensions::empty(ts::ctx(&mut scenario)),
        &clock,
        ts::ctx(&mut scenario),
    );

    let coin = coin::mint_for_testing<SUI>(1000, ts::ctx(&mut scenario));
    let receipt = dividend_actions::fulfill_create_dividend(
        request,
        coin,
        &mut account,
        &clock,
        ts::ctx(&mut scenario),
    );

    let dividend_id = *dividend_actions::resource_receipt_dividend_id(&receipt);
    let prefix = vector[0x00];

    // First claim
    ts::next_tx(&mut scenario, ALICE);
    {
        let claimed = dividend_actions::claim_my_dividend<FutarchyConfig, SUI>(
            &mut account,
            dividend_id,
            prefix,
            ts::ctx(&mut scenario),
        );
        assert!(claimed);
    };

    // Try to claim again
    ts::next_tx(&mut scenario, ALICE);
    {
        let claimed = dividend_actions::claim_my_dividend<FutarchyConfig, SUI>(
            &mut account,
            dividend_id,
            prefix,
            ts::ctx(&mut scenario),
        );
        // Should return false (already claimed)
        assert!(!claimed);
    };

    executable::test_destroy(executable);
    account::destroy_account_for_testing(account);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

// === Crank Tests ===

#[test]
fun test_crank_dividend_single_batch() {
    let mut scenario = ts::begin(ADMIN);
    let clock = clock::create_for_testing(ts::ctx(&mut scenario));

    let mut account = create_test_account(&mut scenario);

    let tree = create_test_tree_with_recipients(
        vector[ALICE, BOB],
        vector[1000, 2000],
        &mut scenario,
    );
    let tree_id = dividend_tree::tree_id(&tree);
    let total_amount = dividend_tree::total_amount(&tree);

    let action = dividend_actions::new_create_dividend_action<SUI>(tree_id);
    let action_data = std::bcs::to_bytes(&action);

    let mut builder = intents::intent_builder(ts::ctx(&mut scenario));
    intents::add_action(
        &mut builder,
        std::type_name::get<dividend_actions::CreateDividendAction<SUI>>(),
        action_data,
    );
    let intent_spec = intents::build(builder);

    let mut executable = executable::test_new<u8>(intent_spec, 0);

    let request = dividend_actions::do_create_dividend<FutarchyConfig, u8, SUI, Extensions>(
        &mut executable,
        &mut account,
        tree,
        version_witness::test_create(),
        extensions::empty(ts::ctx(&mut scenario)),
        &clock,
        ts::ctx(&mut scenario),
    );

    let coin = coin::mint_for_testing<SUI>(total_amount, ts::ctx(&mut scenario));
    let receipt = dividend_actions::fulfill_create_dividend(
        request,
        coin,
        &mut account,
        &clock,
        ts::ctx(&mut scenario),
    );

    let dividend_id = *dividend_actions::resource_receipt_dividend_id(&receipt);

    // Crank the dividend (process all recipients)
    ts::next_tx(&mut scenario, ADMIN);
    {
        dividend_actions::crank_dividend<FutarchyConfig, SUI>(
            &mut account,
            dividend_id,
            10, // max_recipients
            ts::ctx(&mut scenario),
        );
    };

    // Verify all recipients processed
    let (_, sent, _, sent_count) = dividend_actions::get_dividend_info(&account, dividend_id);
    assert_eq(sent, 3000);
    assert_eq(sent_count, 2);

    executable::test_destroy(executable);
    account::destroy_account_for_testing(account);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = dividend_actions::EAllRecipientsProcessed)]
fun test_crank_dividend_all_processed() {
    let mut scenario = ts::begin(ADMIN);
    let clock = clock::create_for_testing(ts::ctx(&mut scenario));

    let mut account = create_test_account(&mut scenario);

    let tree = create_small_test_tree(&mut scenario);
    let tree_id = dividend_tree::tree_id(&tree);
    let total_amount = dividend_tree::total_amount(&tree);

    let action = dividend_actions::new_create_dividend_action<SUI>(tree_id);
    let action_data = std::bcs::to_bytes(&action);

    let mut builder = intents::intent_builder(ts::ctx(&mut scenario));
    intents::add_action(
        &mut builder,
        std::type_name::get<dividend_actions::CreateDividendAction<SUI>>(),
        action_data,
    );
    let intent_spec = intents::build(builder);

    let mut executable = executable::test_new<u8>(intent_spec, 0);

    let request = dividend_actions::do_create_dividend<FutarchyConfig, u8, SUI, Extensions>(
        &mut executable,
        &mut account,
        tree,
        version_witness::test_create(),
        extensions::empty(ts::ctx(&mut scenario)),
        &clock,
        ts::ctx(&mut scenario),
    );

    let coin = coin::mint_for_testing<SUI>(total_amount, ts::ctx(&mut scenario));
    let receipt = dividend_actions::fulfill_create_dividend(
        request,
        coin,
        &mut account,
        &clock,
        ts::ctx(&mut scenario),
    );

    let dividend_id = *dividend_actions::resource_receipt_dividend_id(&receipt);

    // Crank once (processes all)
    ts::next_tx(&mut scenario, ADMIN);
    {
        dividend_actions::crank_dividend<FutarchyConfig, SUI>(
            &mut account,
            dividend_id,
            10,
            ts::ctx(&mut scenario),
        );
    };

    // Try to crank again - should fail
    ts::next_tx(&mut scenario, ADMIN);
    {
        dividend_actions::crank_dividend<FutarchyConfig, SUI>(
            &mut account,
            dividend_id,
            10,
            ts::ctx(&mut scenario),
        );
    };

    executable::test_destroy(executable);
    account::destroy_account_for_testing(account);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

// === Query Function Tests ===

#[test]
fun test_has_been_sent() {
    let mut scenario = ts::begin(ADMIN);
    let clock = clock::create_for_testing(ts::ctx(&mut scenario));

    let mut account = create_test_account(&mut scenario);

    let tree = create_test_tree_with_recipients(
        vector[ALICE],
        vector[1000],
        &mut scenario,
    );
    let tree_id = dividend_tree::tree_id(&tree);

    let action = dividend_actions::new_create_dividend_action<SUI>(tree_id);
    let action_data = std::bcs::to_bytes(&action);

    let mut builder = intents::intent_builder(ts::ctx(&mut scenario));
    intents::add_action(
        &mut builder,
        std::type_name::get<dividend_actions::CreateDividendAction<SUI>>(),
        action_data,
    );
    let intent_spec = intents::build(builder);

    let mut executable = executable::test_new<u8>(intent_spec, 0);

    let request = dividend_actions::do_create_dividend<FutarchyConfig, u8, SUI, Extensions>(
        &mut executable,
        &mut account,
        tree,
        version_witness::test_create(),
        extensions::empty(ts::ctx(&mut scenario)),
        &clock,
        ts::ctx(&mut scenario),
    );

    let coin = coin::mint_for_testing<SUI>(1000, ts::ctx(&mut scenario));
    let receipt = dividend_actions::fulfill_create_dividend(
        request,
        coin,
        &mut account,
        &clock,
        ts::ctx(&mut scenario),
    );

    let dividend_id = *dividend_actions::resource_receipt_dividend_id(&receipt);
    let prefix = vector[0x00];

    // Check before sending
    let sent_before = dividend_actions::has_been_sent<FutarchyConfig>(
        &account,
        dividend_id,
        prefix,
        ALICE,
    );
    assert!(!sent_before);

    // Crank to send
    dividend_actions::crank_dividend<FutarchyConfig, SUI>(
        &mut account,
        dividend_id,
        10,
        ts::ctx(&mut scenario),
    );

    // Check after sending
    let sent_after = dividend_actions::has_been_sent<FutarchyConfig>(
        &account,
        dividend_id,
        prefix,
        ALICE,
    );
    assert!(sent_after);

    executable::test_destroy(executable);
    account::destroy_account_for_testing(account);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
fun test_get_allocation_amount() {
    let mut scenario = ts::begin(ADMIN);
    let clock = clock::create_for_testing(ts::ctx(&mut scenario));

    let mut account = create_test_account(&mut scenario);

    let tree = create_test_tree_with_recipients(
        vector[ALICE, BOB],
        vector[1500, 2500],
        &mut scenario,
    );
    let tree_id = dividend_tree::tree_id(&tree);
    let total_amount = dividend_tree::total_amount(&tree);

    let action = dividend_actions::new_create_dividend_action<SUI>(tree_id);
    let action_data = std::bcs::to_bytes(&action);

    let mut builder = intents::intent_builder(ts::ctx(&mut scenario));
    intents::add_action(
        &mut builder,
        std::type_name::get<dividend_actions::CreateDividendAction<SUI>>(),
        action_data,
    );
    let intent_spec = intents::build(builder);

    let mut executable = executable::test_new<u8>(intent_spec, 0);

    let request = dividend_actions::do_create_dividend<FutarchyConfig, u8, SUI, Extensions>(
        &mut executable,
        &mut account,
        tree,
        version_witness::test_create(),
        extensions::empty(ts::ctx(&mut scenario)),
        &clock,
        ts::ctx(&mut scenario),
    );

    let coin = coin::mint_for_testing<SUI>(total_amount, ts::ctx(&mut scenario));
    let receipt = dividend_actions::fulfill_create_dividend(
        request,
        coin,
        &mut account,
        &clock,
        ts::ctx(&mut scenario),
    );

    let dividend_id = *dividend_actions::resource_receipt_dividend_id(&receipt);
    let prefix = vector[0x00];

    // Check ALICE's allocation
    let alice_amount = dividend_actions::get_allocation_amount<FutarchyConfig>(
        &account,
        dividend_id,
        prefix,
        ALICE,
    );
    assert_eq(alice_amount, 1500);

    // Check BOB's allocation
    let bob_amount = dividend_actions::get_allocation_amount<FutarchyConfig>(
        &account,
        dividend_id,
        prefix,
        BOB,
    );
    assert_eq(bob_amount, 2500);

    // Check non-existent recipient
    let carol_amount = dividend_actions::get_allocation_amount<FutarchyConfig>(
        &account,
        dividend_id,
        prefix,
        CAROL,
    );
    assert_eq(carol_amount, 0);

    executable::test_destroy(executable);
    account::destroy_account_for_testing(account);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

// === Helper accessor tests ===

#[test]
fun test_resource_receipt_dividend_id() {
    // This is tested implicitly in other tests, but let's be explicit
    let mut scenario = ts::begin(ADMIN);
    let clock = clock::create_for_testing(ts::ctx(&mut scenario));

    let mut account = create_test_account(&mut scenario);
    let tree = create_small_test_tree(&mut scenario);
    let tree_id = dividend_tree::tree_id(&tree);
    let total_amount = dividend_tree::total_amount(&tree);

    let action = dividend_actions::new_create_dividend_action<SUI>(tree_id);
    let action_data = std::bcs::to_bytes(&action);

    let mut builder = intents::intent_builder(ts::ctx(&mut scenario));
    intents::add_action(
        &mut builder,
        std::type_name::get<dividend_actions::CreateDividendAction<SUI>>(),
        action_data,
    );
    let intent_spec = intents::build(builder);

    let mut executable = executable::test_new<u8>(intent_spec, 0);

    let request = dividend_actions::do_create_dividend<FutarchyConfig, u8, SUI, Extensions>(
        &mut executable,
        &mut account,
        tree,
        version_witness::test_create(),
        extensions::empty(ts::ctx(&mut scenario)),
        &clock,
        ts::ctx(&mut scenario),
    );

    let coin = coin::mint_for_testing<SUI>(total_amount, ts::ctx(&mut scenario));
    let receipt = dividend_actions::fulfill_create_dividend(
        request,
        coin,
        &mut account,
        &clock,
        ts::ctx(&mut scenario),
    );

    // The dividend_id should be in format "DIV_<id>_T_<timestamp>"
    let id = *dividend_actions::resource_receipt_dividend_id(&receipt);
    // Just verify it's not empty
    assert!(string::length(&id) > 0);

    executable::test_destroy(executable);
    account::destroy_account_for_testing(account);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}
