#[test_only]
module futarchy_types::init_action_specs_tests;

use futarchy_types::init_action_specs;
use futarchy_types::coin_types::{USDC, USDT};
use std::type_name;

// === Test Structs ===

// Mock action types for testing
public struct CreateCouncilAction has drop {}
public struct UpdateConfigAction has drop {}
public struct TransferAction has drop {}

// === Constructor Tests ===

#[test]
fun test_new_action_spec() {
    let action_type = type_name::get<CreateCouncilAction>();
    let action_data = b"serialized_data";

    let spec = action_specs::new_action_spec(action_type, action_data);

    assert!(action_specs::action_type(&spec) == action_type, 0);
    assert!(action_specs::action_data(&spec) == &action_data, 1);
}

#[test]
fun test_new_action_spec_empty_data() {
    let action_type = type_name::get<UpdateConfigAction>();
    let empty_data = vector::empty<u8>();

    let spec = action_specs::new_action_spec(action_type, empty_data);

    assert!(action_specs::action_type(&spec) == action_type, 0);
    assert!(vector::length(action_specs::action_data(&spec)) == 0, 1);
}

#[test]
fun test_new_init_specs() {
    let specs = action_specs::new_init_specs();

    assert!(action_specs::action_count(&specs) == 0, 0);
    assert!(vector::length(action_specs::actions(&specs)) == 0, 1);
}

// === Add Action Tests ===

#[test]
fun test_add_single_action() {
    let mut specs = action_specs::new_init_specs();
    let action_type = type_name::get<CreateCouncilAction>();
    let action_data = b"council_data";

    action_specs::add_action(&mut specs, action_type, action_data);

    assert!(action_specs::action_count(&specs) == 1, 0);

    let retrieved = action_specs::get_action(&specs, 0);
    assert!(action_specs::action_type(retrieved) == action_type, 1);
    assert!(action_specs::action_data(retrieved) == &action_data, 2);
}

#[test]
fun test_add_multiple_actions() {
    let mut specs = action_specs::new_init_specs();

    // Add first action
    let type1 = type_name::get<CreateCouncilAction>();
    let data1 = b"council_data";
    action_specs::add_action(&mut specs, type1, data1);

    // Add second action
    let type2 = type_name::get<UpdateConfigAction>();
    let data2 = b"config_data";
    action_specs::add_action(&mut specs, type2, data2);

    // Add third action
    let type3 = type_name::get<TransferAction>();
    let data3 = b"transfer_data";
    action_specs::add_action(&mut specs, type3, data3);

    assert!(action_specs::action_count(&specs) == 3, 0);

    // Verify first action
    let action1 = action_specs::get_action(&specs, 0);
    assert!(action_specs::action_type(action1) == type1, 1);
    assert!(action_specs::action_data(action1) == &data1, 2);

    // Verify second action
    let action2 = action_specs::get_action(&specs, 1);
    assert!(action_specs::action_type(action2) == type2, 3);
    assert!(action_specs::action_data(action2) == &data2, 4);

    // Verify third action
    let action3 = action_specs::get_action(&specs, 2);
    assert!(action_specs::action_type(action3) == type3, 5);
    assert!(action_specs::action_data(action3) == &data3, 6);
}

#[test]
fun test_add_actions_with_same_type() {
    let mut specs = action_specs::new_init_specs();
    let action_type = type_name::get<TransferAction>();

    // Add multiple actions of the same type with different data
    action_specs::add_action(&mut specs, action_type, b"transfer_1");
    action_specs::add_action(&mut specs, action_type, b"transfer_2");
    action_specs::add_action(&mut specs, action_type, b"transfer_3");

    assert!(action_specs::action_count(&specs) == 3, 0);

    // Verify all have same type but different data
    let action1 = action_specs::get_action(&specs, 0);
    let action2 = action_specs::get_action(&specs, 1);
    let action3 = action_specs::get_action(&specs, 2);

    assert!(action_specs::action_type(action1) == action_type, 1);
    assert!(action_specs::action_type(action2) == action_type, 2);
    assert!(action_specs::action_type(action3) == action_type, 3);

    assert!(action_specs::action_data(action1) == &b"transfer_1", 4);
    assert!(action_specs::action_data(action2) == &b"transfer_2", 5);
    assert!(action_specs::action_data(action3) == &b"transfer_3", 6);
}

#[test]
fun test_add_action_with_large_data() {
    let mut specs = action_specs::new_init_specs();
    let action_type = type_name::get<CreateCouncilAction>();

    // Create large data vector (1000 bytes)
    let mut large_data = vector::empty<u8>();
    let mut i = 0;
    while (i < 1000) {
        vector::push_back(&mut large_data, (i % 256) as u8);
        i = i + 1;
    };

    action_specs::add_action(&mut specs, action_type, large_data);

    assert!(action_specs::action_count(&specs) == 1, 0);
    let retrieved = action_specs::get_action(&specs, 0);
    assert!(vector::length(action_specs::action_data(retrieved)) == 1000, 1);
}

// === Accessor Tests ===

#[test]
fun test_actions_returns_correct_vector() {
    let mut specs = action_specs::new_init_specs();

    let type1 = type_name::get<CreateCouncilAction>();
    let type2 = type_name::get<UpdateConfigAction>();

    action_specs::add_action(&mut specs, type1, b"data1");
    action_specs::add_action(&mut specs, type2, b"data2");

    let actions_vec = action_specs::actions(&specs);
    assert!(vector::length(actions_vec) == 2, 0);
}

#[test]
fun test_action_count_empty() {
    let specs = action_specs::new_init_specs();
    assert!(action_specs::action_count(&specs) == 0, 0);
}

#[test]
fun test_action_count_after_additions() {
    let mut specs = action_specs::new_init_specs();
    let action_type = type_name::get<TransferAction>();

    assert!(action_specs::action_count(&specs) == 0, 0);

    action_specs::add_action(&mut specs, action_type, b"data1");
    assert!(action_specs::action_count(&specs) == 1, 1);

    action_specs::add_action(&mut specs, action_type, b"data2");
    assert!(action_specs::action_count(&specs) == 2, 2);

    action_specs::add_action(&mut specs, action_type, b"data3");
    assert!(action_specs::action_count(&specs) == 3, 3);
}

#[test]
fun test_get_action_by_index() {
    let mut specs = action_specs::new_init_specs();

    let type1 = type_name::get<CreateCouncilAction>();
    let type2 = type_name::get<UpdateConfigAction>();
    let type3 = type_name::get<TransferAction>();

    action_specs::add_action(&mut specs, type1, b"data1");
    action_specs::add_action(&mut specs, type2, b"data2");
    action_specs::add_action(&mut specs, type3, b"data3");

    // Test index 0
    let action0 = action_specs::get_action(&specs, 0);
    assert!(action_specs::action_type(action0) == type1, 0);

    // Test index 1
    let action1 = action_specs::get_action(&specs, 1);
    assert!(action_specs::action_type(action1) == type2, 1);

    // Test index 2
    let action2 = action_specs::get_action(&specs, 2);
    assert!(action_specs::action_type(action2) == type3, 2);
}

// === Edge Case Tests ===

#[test]
fun test_empty_specs_operations() {
    let specs = action_specs::new_init_specs();

    assert!(action_specs::action_count(&specs) == 0, 0);
    assert!(vector::length(action_specs::actions(&specs)) == 0, 1);
}

#[test]
#[expected_failure]
fun test_get_action_out_of_bounds() {
    let specs = action_specs::new_init_specs();
    let _ = action_specs::get_action(&specs, 0); // Should abort with out of bounds
}

#[test]
#[expected_failure]
fun test_get_action_beyond_count() {
    let mut specs = action_specs::new_init_specs();
    let action_type = type_name::get<CreateCouncilAction>();

    action_specs::add_action(&mut specs, action_type, b"data");

    let _ = action_specs::get_action(&specs, 1); // Only index 0 exists, should abort
}

// === Type Preservation Tests ===

#[test]
fun test_type_name_preservation_different_types() {
    let type_usdc = type_name::get<USDC>();
    let type_usdt = type_name::get<USDT>();

    let spec_usdc = action_specs::new_action_spec(type_usdc, b"usdc_data");
    let spec_usdt = action_specs::new_action_spec(type_usdt, b"usdt_data");

    // Verify types are preserved correctly
    assert!(action_specs::action_type(&spec_usdc) == type_usdc, 0);
    assert!(action_specs::action_type(&spec_usdt) == type_usdt, 1);

    // Verify types are different
    assert!(action_specs::action_type(&spec_usdc) != action_specs::action_type(&spec_usdt), 2);
}

#[test]
fun test_type_name_consistency_across_operations() {
    let mut specs = action_specs::new_init_specs();
    let original_type = type_name::get<CreateCouncilAction>();
    let data = b"test_data";

    // Add action
    action_specs::add_action(&mut specs, original_type, data);

    // Retrieve and verify type is unchanged
    let retrieved = action_specs::get_action(&specs, 0);
    let retrieved_type = action_specs::action_type(retrieved);

    assert!(retrieved_type == original_type, 0);
}

// === Data Integrity Tests ===

#[test]
fun test_data_integrity_after_storage() {
    let mut specs = action_specs::new_init_specs();

    // Binary data with all byte values
    let mut binary_data = vector::empty<u8>();
    let mut i = 0;
    while (i < 256) {
        vector::push_back(&mut binary_data, i as u8);
        i = i + 1;
    };

    let action_type = type_name::get<TransferAction>();
    action_specs::add_action(&mut specs, action_type, binary_data);

    let retrieved = action_specs::get_action(&specs, 0);
    let retrieved_data = action_specs::action_data(retrieved);

    // Verify all bytes match
    assert!(vector::length(retrieved_data) == 256, 0);
    let mut j = 0;
    while (j < 256) {
        assert!(*vector::borrow(retrieved_data, j) == j as u8, j + 1);
        j = j + 1;
    };
}

#[test]
fun test_action_spec_copy_ability() {
    let action_type = type_name::get<CreateCouncilAction>();
    let data = b"test_data";

    let spec1 = action_specs::new_action_spec(action_type, data);
    let spec2 = spec1; // Uses copy ability

    // Both should have same data
    assert!(action_specs::action_type(&spec1) == action_specs::action_type(&spec2), 0);
    assert!(action_specs::action_data(&spec1) == action_specs::action_data(&spec2), 1);
}

#[test]
fun test_init_specs_copy_ability() {
    let mut specs1 = action_specs::new_init_specs();

    let action_type = type_name::get<UpdateConfigAction>();
    action_specs::add_action(&mut specs1, action_type, b"data");

    let specs2 = specs1; // Uses copy ability

    // Both should have same action count
    assert!(action_specs::action_count(&specs1) == action_specs::action_count(&specs2), 0);
    assert!(action_specs::action_count(&specs1) == 1, 1);
}

// === Comprehensive Integration Test ===

#[test]
fun test_full_workflow_simulation() {
    // Simulate building init specs for a DAO
    let mut init_specs = action_specs::new_init_specs();

    // Add council creation
    let council_type = type_name::get<CreateCouncilAction>();
    let council_data = b"security_council_config";
    action_specs::add_action(&mut init_specs, council_type, council_data);

    // Add config update
    let config_type = type_name::get<UpdateConfigAction>();
    let config_data = b"trading_params";
    action_specs::add_action(&mut init_specs, config_type, config_data);

    // Add multiple transfers
    let transfer_type = type_name::get<TransferAction>();
    action_specs::add_action(&mut init_specs, transfer_type, b"transfer_to_treasury");
    action_specs::add_action(&mut init_specs, transfer_type, b"transfer_to_founder");
    action_specs::add_action(&mut init_specs, transfer_type, b"transfer_to_contributor");

    // Verify total count
    assert!(action_specs::action_count(&init_specs) == 5, 0);

    // Verify we can retrieve all actions in order
    let action0 = action_specs::get_action(&init_specs, 0);
    assert!(action_specs::action_type(action0) == council_type, 1);
    assert!(action_specs::action_data(action0) == &council_data, 2);

    let action1 = action_specs::get_action(&init_specs, 1);
    assert!(action_specs::action_type(action1) == config_type, 3);
    assert!(action_specs::action_data(action1) == &config_data, 4);

    let action2 = action_specs::get_action(&init_specs, 2);
    assert!(action_specs::action_type(action2) == transfer_type, 5);
    assert!(action_specs::action_data(action2) == &b"transfer_to_treasury", 6);

    let action3 = action_specs::get_action(&init_specs, 3);
    assert!(action_specs::action_data(action3) == &b"transfer_to_founder", 7);

    let action4 = action_specs::get_action(&init_specs, 4);
    assert!(action_specs::action_data(action4) == &b"transfer_to_contributor", 8);
}
