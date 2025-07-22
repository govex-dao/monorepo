#[test_only]
module futarchy::operating_agreement_simple_tests;

use futarchy::operating_agreement::{Self, OperatingAgreement};
use futarchy::operating_agreement_actions::{Self, ActionRegistry};
use futarchy::init_operating_agreement_actions::{Self, InitActionRegistry};
use futarchy::dao::{Self, DAO};
use std::string::{Self, String};
use sui::test_scenario::{Self, ctx};
use sui::test_utils;

// Test coins
public struct ASSET has copy, drop {}
public struct STABLE has copy, drop {}

const ADMIN: address = @0xAD;

#[test]
fun test_operating_agreement_basic() {
    let mut scenario = test_scenario::begin(ADMIN);
    
    // Create test operating agreement
    let lines = vector[
        string::utf8(b"Article 1: Purpose"),
        string::utf8(b"Article 2: Governance"),
        string::utf8(b"Article 3: Treasury")
    ];
    let difficulties = vector[10000, 30000, 50000]; // 10%, 30%, 50%
    
    let dao_id = object::id_from_address(@0x123);
    let agreement = operating_agreement::new(
        dao_id,
        lines,
        difficulties,
        ctx(&mut scenario)
    );
    
    // Test basic getters
    assert!(operating_agreement::get_dao_id(&agreement) == dao_id, 0);
    
    // Note: We can't test line-specific functions without access to line IDs
    // In production, these would be tracked when lines are created
    
    transfer::public_share_object(agreement);
    test_scenario::end(scenario);
}

#[test]
fun test_action_registry_creation() {
    let mut scenario = test_scenario::begin(ADMIN);
    
    // Create registries
    operating_agreement_actions::create_registry(ctx(&mut scenario));
    init_operating_agreement_actions::create_registry(ctx(&mut scenario));
    
    test_scenario::next_tx(&mut scenario, ADMIN);
    
    // Verify registries exist
    assert!(test_scenario::has_most_recent_shared<ActionRegistry>(), 0);
    assert!(test_scenario::has_most_recent_shared<InitActionRegistry>(), 1);
    
    test_scenario::end(scenario);
}

#[test]
fun test_action_creation() {
    let mut scenario = test_scenario::begin(ADMIN);
    
    let line_id = object::id_from_address(@0x111);
    let new_text = string::utf8(b"Updated article text");
    
    // Test update action
    let update_action = operating_agreement_actions::new_update_action(line_id, new_text);
    
    // Test insert after action
    let insert_after_action = operating_agreement_actions::new_insert_after_action(
        line_id,
        string::utf8(b"New line after"),
        25000 // 25% difficulty
    );
    
    // Test insert at beginning action
    let insert_beginning_action = operating_agreement_actions::new_insert_at_beginning_action(
        string::utf8(b"New first line"),
        15000 // 15% difficulty
    );
    
    // Test remove action
    let remove_action = operating_agreement_actions::new_remove_action(line_id);
    
    // Actions created successfully (fields are private so we can't inspect)
    
    test_scenario::end(scenario);
}

#[test]
fun test_init_agreement_action_creation() {
    let mut scenario = test_scenario::begin(ADMIN);
    
    let lines = vector[
        string::utf8(b"Line 1"),
        string::utf8(b"Line 2")
    ];
    let difficulties = vector[20000, 40000];
    
    // Create action
    let action = init_operating_agreement_actions::new_init_agreement_action(
        lines,
        difficulties
    );
    
    // Action created successfully
    
    test_scenario::end(scenario);
}

#[test]
fun test_difficulty_calculations() {
    // Test basis points math
    let basis_points: u256 = 100_000;
    
    // Test 50% difficulty (50,000 basis points)
    let difficulty_50: u256 = 50_000;
    let reject_price: u256 = 1_000_000;
    let accept_price_exact: u256 = 1_500_000; // Exactly 1.5x
    let accept_price_high: u256 = 1_600_000;  // 1.6x
    let accept_price_low: u256 = 1_400_000;   // 1.4x
    
    // Calculate thresholds
    let accept_val_exact = accept_price_exact * basis_points;
    let accept_val_high = accept_price_high * basis_points;
    let accept_val_low = accept_price_low * basis_points;
    let required_reject_val = reject_price * (basis_points + difficulty_50);
    
    // Test exact match
    assert!(accept_val_exact == required_reject_val, 0);
    
    // Test above threshold (should pass)
    assert!(accept_val_high > required_reject_val, 1);
    
    // Test below threshold (should fail)
    assert!(accept_val_low < required_reject_val, 2);
    
    // Test 30% difficulty
    let difficulty_30: u256 = 30_000;
    let accept_price_30: u256 = 1_300_000; // 1.3x
    let accept_val_30 = accept_price_30 * basis_points;
    let required_reject_val_30 = reject_price * (basis_points + difficulty_30);
    
    assert!(accept_val_30 == required_reject_val_30, 3);
}

#[test]
#[expected_failure(abort_code = 1)] // EIncorrectLengths
fun test_mismatched_lines_difficulties() {
    let mut scenario = test_scenario::begin(ADMIN);
    
    let lines = vector[
        string::utf8(b"Line 1"),
        string::utf8(b"Line 2")
    ];
    let difficulties = vector[10000]; // Only one difficulty for two lines
    
    // This should fail
    let dao_id = object::id_from_address(@0x123);
    let agreement = operating_agreement::new(
        dao_id,
        lines,
        difficulties,
        ctx(&mut scenario)
    );
    
    transfer::public_share_object(agreement);
    test_scenario::end(scenario);
}

#[test]
fun test_operating_agreement_with_empty_lines() {
    let mut scenario = test_scenario::begin(ADMIN);
    
    let lines = vector<String>[];
    let difficulties = vector<u64>[];
    
    // Should succeed with empty agreement
    let dao_id = object::id_from_address(@0x123);
    let agreement = operating_agreement::new(
        dao_id,
        lines,
        difficulties,
        ctx(&mut scenario)
    );
    
    assert!(operating_agreement::get_dao_id(&agreement) == dao_id, 0);
    
    transfer::public_share_object(agreement);
    test_scenario::end(scenario);
}

#[test]
fun test_high_difficulty_thresholds() {
    // Test extreme difficulty values
    let basis_points: u256 = 100_000;
    
    // 100% difficulty (100,000 basis points) - price must double
    let difficulty_100: u256 = 100_000;
    let reject_price: u256 = 1_000_000;
    let accept_price_2x: u256 = 2_000_000;
    
    let accept_val = accept_price_2x * basis_points;
    let required_val = reject_price * (basis_points + difficulty_100);
    
    assert!(accept_val == required_val, 0);
    
    // 200% difficulty - price must triple
    let difficulty_200: u256 = 200_000;
    let accept_price_3x: u256 = 3_000_000;
    
    let accept_val_3x = accept_price_3x * basis_points;
    let required_val_3x = reject_price * (basis_points + difficulty_200);
    
    assert!(accept_val_3x == required_val_3x, 1);
}