#[test_only]
module futarchy_types::coin_types_tests;

use futarchy_types::coin_types::{USDC, USDT};
use std::type_name;
use std::ascii;

// === Type Name Tests ===
// Note: Witness structs can't be instantiated outside their defining module
// We test TypeName functionality which is the intended use case

#[test]
fun test_usdc_type_name() {
    let type_usdc = type_name::get<USDC>();

    // Type name should be retrievable
    let addr = type_name::get_address(&type_usdc);
    assert!(ascii::length(&addr) > 0, 0);
}

#[test]
fun test_usdt_type_name() {
    let type_usdt = type_name::get<USDT>();

    // Type name should be retrievable
    let addr = type_name::get_address(&type_usdt);
    assert!(ascii::length(&addr) > 0, 0);
}

#[test]
fun test_usdc_usdt_different_types() {
    let type_usdc = type_name::get<USDC>();
    let type_usdt = type_name::get<USDT>();

    // USDC and USDT should be different types
    assert!(type_usdc != type_usdt, 0);
}

// === Type Name Comparison Tests ===

#[test]
fun test_usdc_type_consistency() {
    let type1 = type_name::get<USDC>();
    let type2 = type_name::get<USDC>();

    // Same type should produce same TypeName
    assert!(type1 == type2, 0);
}

#[test]
fun test_usdt_type_consistency() {
    let type1 = type_name::get<USDT>();
    let type2 = type_name::get<USDT>();

    // Same type should produce same TypeName
    assert!(type1 == type2, 0);
}

// === Type Safety Tests ===

#[test]
fun test_usdc_type_as_generic_param() {
    // Verify USDC can be used as a generic type parameter
    let _type = type_name::get<USDC>();
    // This compilation alone proves type safety
}

#[test]
fun test_usdt_type_as_generic_param() {
    // Verify USDT can be used as a generic type parameter
    let _type = type_name::get<USDT>();
    // This compilation alone proves type safety
}

// === Practical Usage Simulation Tests ===

#[test]
fun test_type_matching_usdc() {
    // Simulate checking if a type matches USDC
    let expected_type = type_name::get<USDC>();
    let actual_type = type_name::get<USDC>();

    assert!(expected_type == actual_type, 0);
}

#[test]
fun test_type_matching_usdt() {
    // Simulate checking if a type matches USDT
    let expected_type = type_name::get<USDT>();
    let actual_type = type_name::get<USDT>();

    assert!(expected_type == actual_type, 0);
}

#[test]
fun test_type_discrimination() {
    // Simulate discriminating between coin types
    let usdc_type = type_name::get<USDC>();
    let usdt_type = type_name::get<USDT>();

    // Should be able to tell them apart
    let is_usdc = (usdc_type == type_name::get<USDC>());
    let is_not_usdt = (usdc_type != type_name::get<USDT>());

    assert!(is_usdc, 0);
    assert!(is_not_usdt, 1);
}

// === Vector Storage Tests ===

#[test]
fun test_store_witness_types_in_vector() {
    // Witnesses can't be stored in vectors (no store ability)
    // But TypeNames can be
    let mut types = vector::empty();

    vector::push_back(&mut types, type_name::get<USDC>());
    vector::push_back(&mut types, type_name::get<USDT>());
    vector::push_back(&mut types, type_name::get<USDC>());

    assert!(vector::length(&types) == 3, 0);

    // Verify first is USDC
    assert!(*vector::borrow(&types, 0) == type_name::get<USDC>(), 1);

    // Verify second is USDT
    assert!(*vector::borrow(&types, 1) == type_name::get<USDT>(), 2);

    // Verify third is USDC
    assert!(*vector::borrow(&types, 2) == type_name::get<USDC>(), 3);
}

// === Type Module Tests ===

#[test]
fun test_type_module_name_usdc() {
    let type_usdc = type_name::get<USDC>();
    let module_name = type_name::get_module(&type_usdc);

    // Should be from coin_types module
    assert!(module_name == ascii::string(b"coin_types"), 0);
}

#[test]
fun test_type_module_name_usdt() {
    let type_usdt = type_name::get<USDT>();
    let module_name = type_name::get_module(&type_usdt);

    // Should be from coin_types module
    assert!(module_name == ascii::string(b"coin_types"), 0);
}
