/// Comprehensive tests for custody_actions.move
/// Tests action constructors, getters, destroy functions
#[test_only]
module futarchy_vault::custody_actions_tests;

use futarchy_vault::custody_actions;
use std::string;
use sui::object;
use sui::test_utils::assert_eq;

// Test resource type - phantom marker only
public struct TestResource has drop {}

// === ApproveCustodyAction Tests ===

#[test]
fun test_create_approve_custody_basic() {
    let dao_id = object::id_from_address(@0x1);
    let obj_id = object::id_from_address(@0x2);
    let key = string::utf8(b"test_key");
    let context = string::utf8(b"approval context");
    let expires_at = 1000u64;

    let action = custody_actions::create_approve_custody<TestResource>(
        dao_id,
        obj_id,
        key,
        context,
        expires_at,
    );

    let (
        act_dao_id,
        act_obj_id,
        act_key,
        act_context,
        act_expires,
    ) = custody_actions::get_approve_custody_params(&action);
    assert_eq(act_dao_id, dao_id);
    assert_eq(act_obj_id, obj_id);
    assert_eq(*act_key, key);
    assert_eq(*act_context, context);
    assert_eq(act_expires, expires_at);

    custody_actions::destroy_approve_custody(action);
}

#[test]
fun test_approve_custody_copy_ability() {
    let dao_id = object::id_from_address(@0x1);
    let obj_id = object::id_from_address(@0x2);
    let key = string::utf8(b"key");
    let context = string::utf8(b"context");

    let action1 = custody_actions::create_approve_custody<TestResource>(
        dao_id,
        obj_id,
        key,
        context,
        1000,
    );

    let action2 = action1; // Test copy
    let action3 = action1; // Test copy again

    // All should have same values
    let (dao1, _, _, _, _) = custody_actions::get_approve_custody_params(&action1);
    let (dao2, _, _, _, _) = custody_actions::get_approve_custody_params(&action2);
    let (dao3, _, _, _, _) = custody_actions::get_approve_custody_params(&action3);

    assert_eq(dao1, dao_id);
    assert_eq(dao2, dao_id);
    assert_eq(dao3, dao_id);

    custody_actions::destroy_approve_custody(action1);
    custody_actions::destroy_approve_custody(action2);
    custody_actions::destroy_approve_custody(action3);
}

#[test]
fun test_approve_custody_empty_strings() {
    let dao_id = object::id_from_address(@0x1);
    let obj_id = object::id_from_address(@0x2);
    let empty = string::utf8(b"");

    let action = custody_actions::create_approve_custody<TestResource>(
        dao_id,
        obj_id,
        empty,
        empty,
        0,
    );

    let (_, _, act_key, act_context, act_expires) = custody_actions::get_approve_custody_params(
        &action,
    );
    assert_eq(act_key.length(), 0);
    assert_eq(act_context.length(), 0);
    assert_eq(act_expires, 0);

    custody_actions::destroy_approve_custody(action);
}

#[test]
fun test_approve_custody_unicode() {
    let dao_id = object::id_from_address(@0x1);
    let obj_id = object::id_from_address(@0x2);
    let unicode_key = string::utf8(b"\xE2\x9C\x85 key"); // ✅ key
    let unicode_context = string::utf8(b"\xF0\x9F\x94\x90 context"); // 🔐 context

    let action = custody_actions::create_approve_custody<TestResource>(
        dao_id,
        obj_id,
        unicode_key,
        unicode_context,
        5000,
    );

    let (_, _, act_key, act_context, _) = custody_actions::get_approve_custody_params(&action);
    assert_eq(*act_key, unicode_key);
    assert_eq(*act_context, unicode_context);

    custody_actions::destroy_approve_custody(action);
}

#[test]
fun test_approve_custody_max_timestamp() {
    let dao_id = object::id_from_address(@0x1);
    let obj_id = object::id_from_address(@0x2);
    let key = string::utf8(b"key");
    let context = string::utf8(b"context");
    let max_time = 18446744073709551615u64; // u64::MAX

    let action = custody_actions::create_approve_custody<TestResource>(
        dao_id,
        obj_id,
        key,
        context,
        max_time,
    );

    let (_, _, _, _, act_expires) = custody_actions::get_approve_custody_params(&action);
    assert_eq(act_expires, max_time);

    custody_actions::destroy_approve_custody(action);
}

// === AcceptIntoCustodyAction Tests ===

#[test]
fun test_create_accept_into_custody_basic() {
    let obj_id = object::id_from_address(@0x3);
    let key = string::utf8(b"accept_key");
    let context = string::utf8(b"accept context");

    let action = custody_actions::create_accept_into_custody<TestResource>(
        obj_id,
        key,
        context,
    );

    let (act_obj_id, act_key, act_context) = custody_actions::get_accept_params(&action);
    assert_eq(act_obj_id, obj_id);
    assert_eq(*act_key, key);
    assert_eq(*act_context, context);

    custody_actions::destroy_accept_into_custody(action);
}

#[test]
fun test_accept_into_custody_copy_ability() {
    let obj_id = object::id_from_address(@0x3);
    let key = string::utf8(b"key");
    let context = string::utf8(b"context");

    let action1 = custody_actions::create_accept_into_custody<TestResource>(
        obj_id,
        key,
        context,
    );

    let action2 = action1; // Copy
    let action3 = action1; // Copy again

    let (obj1, _, _) = custody_actions::get_accept_params(&action1);
    let (obj2, _, _) = custody_actions::get_accept_params(&action2);
    let (obj3, _, _) = custody_actions::get_accept_params(&action3);

    assert_eq(obj1, obj_id);
    assert_eq(obj2, obj_id);
    assert_eq(obj3, obj_id);

    custody_actions::destroy_accept_into_custody(action1);
    custody_actions::destroy_accept_into_custody(action2);
    custody_actions::destroy_accept_into_custody(action3);
}

#[test]
fun test_accept_into_custody_long_strings() {
    let obj_id = object::id_from_address(@0x3);
    let long_key = string::utf8(
        b"very_long_resource_key_with_lots_of_characters_for_testing_edge_cases_1234567890",
    );
    let long_context = string::utf8(
        b"very_long_context_string_with_detailed_information_about_custody_acceptance_process",
    );

    let action = custody_actions::create_accept_into_custody<TestResource>(
        obj_id,
        long_key,
        long_context,
    );

    let (_, act_key, act_context) = custody_actions::get_accept_params(&action);
    assert!(act_key.length() > 50, 0);
    assert!(act_context.length() > 50, 1);

    custody_actions::destroy_accept_into_custody(action);
}

// === Workflow Simulation Test ===

#[test]
fun test_custody_workflow_simulation() {
    let dao_id = object::id_from_address(@0xDAD);
    let resource_id = object::id_from_address(@0xABC);
    let key = string::utf8(b"TreasuryKey");
    let approve_context = string::utf8(b"DAO approves transfer");
    let accept_context = string::utf8(b"Council accepts custody");

    // Step 1: DAO approves custody transfer
    let approve_action = custody_actions::create_approve_custody<TestResource>(
        dao_id,
        resource_id,
        key,
        approve_context,
        1000000,
    );

    // Verify approval
    let (act_dao_id, act_obj_id, _, _, _) = custody_actions::get_approve_custody_params(
        &approve_action,
    );
    assert_eq(act_dao_id, dao_id);
    assert_eq(act_obj_id, resource_id);

    // Step 2: Council accepts into custody
    let accept_action = custody_actions::create_accept_into_custody<TestResource>(
        resource_id,
        key,
        accept_context,
    );

    // Verify acceptance
    let (accept_obj_id, accept_key, _) = custody_actions::get_accept_params(&accept_action);
    assert_eq(accept_obj_id, resource_id);

    // Verify both actions use same key
    let (_, _, approve_key, _, _) = custody_actions::get_approve_custody_params(&approve_action);
    assert_eq(*approve_key, *accept_key);

    custody_actions::destroy_approve_custody(approve_action);
    custody_actions::destroy_accept_into_custody(accept_action);
}
