/// Tests for custody BCS serialization/deserialization
/// Note: Full decoder tests require decoder infrastructure. These tests focus on
/// the BCS serialization contract between custody_actions and custody_decoder.
#[test_only]
module futarchy_vault::custody_decoder_tests;

use std::string;
use sui::bcs;
use sui::object;
use futarchy_vault::custody_actions;

// Test resource type
public struct TestResource has drop {}

// === BCS Serialization Tests ===

#[test]
fun test_approve_custody_serialization_basic() {
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
        expires_at
    );

    // Serialize - this is the contract that decoder relies on
    let serialized = bcs::to_bytes(&action);

    // Verify serialization produces bytes
    assert!(serialized.length() > 0, 0);

    custody_actions::destroy_approve_custody(action);
}

#[test]
fun test_approve_custody_serialization_empty_strings() {
    let dao_id = object::id_from_address(@0x1);
    let obj_id = object::id_from_address(@0x2);
    let empty = string::utf8(b"");

    let action = custody_actions::create_approve_custody<TestResource>(
        dao_id,
        obj_id,
        empty,
        empty,
        0
    );

    let serialized = bcs::to_bytes(&action);
    assert!(serialized.length() > 0, 0);

    custody_actions::destroy_approve_custody(action);
}

#[test]
fun test_approve_custody_serialization_unicode() {
    let dao_id = object::id_from_address(@0x1);
    let obj_id = object::id_from_address(@0x2);
    let unicode_key = string::utf8(b"\xE2\x9C\x85 key"); // ✅ key
    let unicode_context = string::utf8(b"\xF0\x9F\x94\x90 context"); // 🔐 context

    let action = custody_actions::create_approve_custody<TestResource>(
        dao_id,
        obj_id,
        unicode_key,
        unicode_context,
        5000
    );

    let serialized = bcs::to_bytes(&action);
    assert!(serialized.length() > 0, 0);

    custody_actions::destroy_approve_custody(action);
}

#[test]
fun test_approve_custody_serialization_max_timestamp() {
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
        max_time
    );

    let serialized = bcs::to_bytes(&action);
    assert!(serialized.length() > 0, 0);

    custody_actions::destroy_approve_custody(action);
}

// === AcceptIntoCustodyAction Serialization Tests ===

#[test]
fun test_accept_into_custody_serialization_basic() {
    let obj_id = object::id_from_address(@0x3);
    let key = string::utf8(b"accept_key");
    let context = string::utf8(b"accept context");

    let action = custody_actions::create_accept_into_custody<TestResource>(
        obj_id,
        key,
        context
    );

    let serialized = bcs::to_bytes(&action);
    assert!(serialized.length() > 0, 0);

    custody_actions::destroy_accept_into_custody(action);
}

#[test]
fun test_accept_into_custody_serialization_empty_strings() {
    let obj_id = object::id_from_address(@0x3);
    let empty = string::utf8(b"");

    let action = custody_actions::create_accept_into_custody<TestResource>(
        obj_id,
        empty,
        empty
    );

    let serialized = bcs::to_bytes(&action);
    assert!(serialized.length() > 0, 0);

    custody_actions::destroy_accept_into_custody(action);
}

#[test]
fun test_accept_into_custody_serialization_long_strings() {
    let obj_id = object::id_from_address(@0x3);
    let long_key = string::utf8(b"very_long_resource_key_with_lots_of_characters_for_testing_edge_cases_1234567890");
    let long_context = string::utf8(b"very_long_context_string_with_detailed_information_about_custody_acceptance_process");

    let action = custody_actions::create_accept_into_custody<TestResource>(
        obj_id,
        long_key,
        long_context
    );

    let serialized = bcs::to_bytes(&action);
    assert!(serialized.length() > 0, 0);

    custody_actions::destroy_accept_into_custody(action);
}

// === Serialization Consistency Tests ===

#[test]
fun test_serialization_deterministic() {
    let dao_id = object::id_from_address(@0xDAD);
    let obj_id = object::id_from_address(@0xABC);
    let key = string::utf8(b"TreasuryKey");
    let context = string::utf8(b"Emergency fund custody transfer");
    let expires = 1000000u64;

    // Create same action twice
    let action1 = custody_actions::create_approve_custody<TestResource>(
        dao_id,
        obj_id,
        key,
        context,
        expires
    );

    let action2 = custody_actions::create_approve_custody<TestResource>(
        dao_id,
        obj_id,
        key,
        context,
        expires
    );

    // Serialize both
    let ser1 = bcs::to_bytes(&action1);
    let ser2 = bcs::to_bytes(&action2);

    // Serialization should be deterministic - same inputs = same bytes
    assert!(ser1 == ser2, 0);

    custody_actions::destroy_approve_custody(action1);
    custody_actions::destroy_approve_custody(action2);
}

#[test]
fun test_accept_serialization_deterministic() {
    let obj_id = object::id_from_address(@0xABC);
    let key = string::utf8(b"TreasuryKey");
    let context = string::utf8(b"Council acceptance");

    let action1 = custody_actions::create_accept_into_custody<TestResource>(
        obj_id,
        key,
        context
    );

    let action2 = custody_actions::create_accept_into_custody<TestResource>(
        obj_id,
        key,
        context
    );

    let ser1 = bcs::to_bytes(&action1);
    let ser2 = bcs::to_bytes(&action2);

    assert!(ser1 == ser2, 0);

    custody_actions::destroy_accept_into_custody(action1);
    custody_actions::destroy_accept_into_custody(action2);
}

// === Integration Test ===

#[test]
fun test_custody_workflow_serialization() {
    let dao_id = object::id_from_address(@0xDAD);
    let resource_id = object::id_from_address(@0xABC);
    let key = string::utf8(b"SharedKey");
    let approve_context = string::utf8(b"DAO approves transfer");
    let accept_context = string::utf8(b"Council accepts custody");

    // Create both actions
    let approve_action = custody_actions::create_approve_custody<TestResource>(
        dao_id,
        resource_id,
        key,
        approve_context,
        1000000
    );

    let accept_action = custody_actions::create_accept_into_custody<TestResource>(
        resource_id,
        key,
        accept_context
    );

    // Both should serialize successfully
    let approve_ser = bcs::to_bytes(&approve_action);
    let accept_ser = bcs::to_bytes(&accept_action);

    assert!(approve_ser.length() > 0, 0);
    assert!(accept_ser.length() > 0, 1);

    // Approve action should be larger (has more fields)
    assert!(approve_ser.length() > accept_ser.length(), 2);

    custody_actions::destroy_approve_custody(approve_action);
    custody_actions::destroy_accept_into_custody(accept_action);
}
