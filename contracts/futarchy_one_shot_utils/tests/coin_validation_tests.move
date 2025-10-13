#[test_only]
module futarchy_one_shot_utils::coin_validation_tests;

use futarchy_one_shot_utils::coin_validation;
use futarchy_one_shot_utils::test_coin_a::{Self, TEST_COIN_A};
use futarchy_one_shot_utils::test_coin_b::{Self, TEST_COIN_B};
use sui::coin::{Self, TreasuryCap, CoinMetadata};
use sui::test_scenario;

// === assert_zero_supply Tests ===

#[test]
fun test_assert_zero_supply_valid() {
    let mut scenario = test_scenario::begin(@0x1);

    // Initialize test coin (with zero supply)
    test_coin_a::init_for_testing(scenario.ctx());
    scenario.next_tx(@0x1);

    // Get treasury cap
    let treasury_cap = scenario.take_from_sender<TreasuryCap<TEST_COIN_A>>();

    // Should pass - supply is zero
    coin_validation::assert_zero_supply(&treasury_cap);

    // Cleanup
    scenario.return_to_sender(treasury_cap);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = 0)] // ESupplyNotZero
fun test_assert_zero_supply_fails_with_minted_coins() {
    let mut scenario = test_scenario::begin(@0x1);

    // Initialize test coin
    test_coin_a::init_for_testing(scenario.ctx());
    scenario.next_tx(@0x1);

    // Get treasury cap and mint some coins
    let mut treasury_cap = scenario.take_from_sender<TreasuryCap<TEST_COIN_A>>();
    let coin = coin::mint(&mut treasury_cap, 1000, scenario.ctx());

    // Should fail - supply is not zero
    coin_validation::assert_zero_supply(&treasury_cap);

    // Cleanup
    coin::burn(&mut treasury_cap, coin);
    scenario.return_to_sender(treasury_cap);
    scenario.end();
}

// === assert_caps_match Tests ===

#[test]
fun test_assert_caps_match_valid() {
    let mut scenario = test_scenario::begin(@0x1);

    // Initialize test coin
    test_coin_a::init_for_testing(scenario.ctx());
    scenario.next_tx(@0x1);

    // Get matching treasury cap and metadata
    let treasury_cap = scenario.take_from_sender<TreasuryCap<TEST_COIN_A>>();
    let metadata = scenario.take_from_sender<CoinMetadata<TEST_COIN_A>>();

    // Should pass - types match
    coin_validation::assert_caps_match(&treasury_cap, &metadata);

    // Cleanup
    scenario.return_to_sender(treasury_cap);
    scenario.return_to_sender(metadata);
    scenario.end();
}

// Note: Type mismatch is caught at compile time, not runtime
// If you try to pass TreasuryCap<TEST_COIN_A> with CoinMetadata<TEST_COIN_B>,
// the code won't compile due to generic type parameter T

// === assert_empty_name Tests ===

#[test]
fun test_assert_empty_name_valid() {
    let mut scenario = test_scenario::begin(@0x1);

    // Initialize test coin with empty name
    test_coin_a::init_for_testing(scenario.ctx());
    scenario.next_tx(@0x1);

    let metadata = scenario.take_from_sender<CoinMetadata<TEST_COIN_A>>();

    // Should pass - name is empty
    coin_validation::assert_empty_name(&metadata);

    // Cleanup
    scenario.return_to_sender(metadata);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = 3)] // ENameNotEmpty
fun test_assert_empty_name_fails_with_name() {
    let mut scenario = test_scenario::begin(@0x1);

    // Create coin with non-empty name
    test_coin_b::create_with_name(scenario.ctx());
    scenario.next_tx(@0x1);

    let metadata = scenario.take_from_sender<CoinMetadata<TEST_COIN_B>>();

    // Should fail - name is not empty
    coin_validation::assert_empty_name(&metadata);

    // Cleanup
    scenario.return_to_sender(metadata);
    scenario.end();
}

// === assert_empty_metadata Tests ===

#[test]
fun test_assert_empty_metadata_valid() {
    let mut scenario = test_scenario::begin(@0x1);

    // Initialize test coin with empty metadata
    test_coin_a::init_for_testing(scenario.ctx());
    scenario.next_tx(@0x1);

    let metadata = scenario.take_from_sender<CoinMetadata<TEST_COIN_A>>();

    // Should pass - all metadata fields are empty
    coin_validation::assert_empty_metadata(&metadata);

    // Cleanup
    scenario.return_to_sender(metadata);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = 4)] // EDescriptionNotEmpty
fun test_assert_empty_metadata_fails_with_description() {
    let mut scenario = test_scenario::begin(@0x1);

    // Create coin with non-empty description
    test_coin_b::create_with_description(scenario.ctx());
    scenario.next_tx(@0x1);

    let metadata = scenario.take_from_sender<CoinMetadata<TEST_COIN_B>>();

    // Should fail - description is not empty
    coin_validation::assert_empty_metadata(&metadata);

    // Cleanup
    scenario.return_to_sender(metadata);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = 5)] // ESymbolNotEmpty
fun test_assert_empty_metadata_fails_with_symbol() {
    let mut scenario = test_scenario::begin(@0x1);

    // Create coin with non-empty symbol
    test_coin_b::create_with_symbol(scenario.ctx());
    scenario.next_tx(@0x1);

    let metadata = scenario.take_from_sender<CoinMetadata<TEST_COIN_B>>();

    // Should fail - symbol is not empty
    coin_validation::assert_empty_metadata(&metadata);

    // Cleanup
    scenario.return_to_sender(metadata);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = 6)] // EIconUrlNotEmpty
fun test_assert_empty_metadata_fails_with_icon() {
    let mut scenario = test_scenario::begin(@0x1);

    // Create coin with icon URL
    test_coin_b::create_with_icon(scenario.ctx());
    scenario.next_tx(@0x1);

    let metadata = scenario.take_from_sender<CoinMetadata<TEST_COIN_B>>();

    // Should fail - icon URL is not empty
    coin_validation::assert_empty_metadata(&metadata);

    // Cleanup
    scenario.return_to_sender(metadata);
    scenario.end();
}

// === validate_conditional_coin Tests (Complete Validation) ===

#[test]
fun test_validate_conditional_coin_all_valid() {
    let mut scenario = test_scenario::begin(@0x1);

    // Initialize test coin with all valid properties
    test_coin_a::init_for_testing(scenario.ctx());
    scenario.next_tx(@0x1);

    let treasury_cap = scenario.take_from_sender<TreasuryCap<TEST_COIN_A>>();
    let metadata = scenario.take_from_sender<CoinMetadata<TEST_COIN_A>>();

    // Should pass - all validations succeed
    coin_validation::validate_conditional_coin(&treasury_cap, &metadata);

    // Cleanup
    scenario.return_to_sender(treasury_cap);
    scenario.return_to_sender(metadata);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = 0)] // ESupplyNotZero
fun test_validate_conditional_coin_fails_with_supply() {
    let mut scenario = test_scenario::begin(@0x1);

    // Initialize test coin
    test_coin_a::init_for_testing(scenario.ctx());
    scenario.next_tx(@0x1);

    let mut treasury_cap = scenario.take_from_sender<TreasuryCap<TEST_COIN_A>>();
    let metadata = scenario.take_from_sender<CoinMetadata<TEST_COIN_A>>();

    // Mint some coins
    let coin = coin::mint(&mut treasury_cap, 1000, scenario.ctx());

    // Should fail - supply is not zero
    coin_validation::validate_conditional_coin(&treasury_cap, &metadata);

    // Cleanup
    coin::burn(&mut treasury_cap, coin);
    scenario.return_to_sender(treasury_cap);
    scenario.return_to_sender(metadata);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = 3)] // ENameNotEmpty
fun test_validate_conditional_coin_fails_with_name() {
    let mut scenario = test_scenario::begin(@0x1);

    // Create coin with non-empty name
    test_coin_b::create_with_name(scenario.ctx());
    scenario.next_tx(@0x1);

    let treasury_cap = scenario.take_from_sender<TreasuryCap<TEST_COIN_B>>();
    let metadata = scenario.take_from_sender<CoinMetadata<TEST_COIN_B>>();

    // Should fail - name is not empty
    coin_validation::validate_conditional_coin(&treasury_cap, &metadata);

    // Cleanup
    scenario.return_to_sender(treasury_cap);
    scenario.return_to_sender(metadata);
    scenario.end();
}

// === View Function Tests (is_supply_zero, is_name_empty, is_metadata_empty) ===

#[test]
fun test_is_supply_zero_true() {
    let mut scenario = test_scenario::begin(@0x1);

    test_coin_a::init_for_testing(scenario.ctx());
    scenario.next_tx(@0x1);

    let treasury_cap = scenario.take_from_sender<TreasuryCap<TEST_COIN_A>>();

    // Should return true - supply is zero
    assert!(coin_validation::is_supply_zero(&treasury_cap) == true, 0);

    scenario.return_to_sender(treasury_cap);
    scenario.end();
}

#[test]
fun test_is_supply_zero_false() {
    let mut scenario = test_scenario::begin(@0x1);

    test_coin_a::init_for_testing(scenario.ctx());
    scenario.next_tx(@0x1);

    let mut treasury_cap = scenario.take_from_sender<TreasuryCap<TEST_COIN_A>>();

    // Mint some coins
    let coin = coin::mint(&mut treasury_cap, 1000, scenario.ctx());

    // Should return false - supply is not zero
    assert!(coin_validation::is_supply_zero(&treasury_cap) == false, 0);

    coin::burn(&mut treasury_cap, coin);
    scenario.return_to_sender(treasury_cap);
    scenario.end();
}

#[test]
fun test_is_name_empty_true() {
    let mut scenario = test_scenario::begin(@0x1);

    test_coin_a::init_for_testing(scenario.ctx());
    scenario.next_tx(@0x1);

    let metadata = scenario.take_from_sender<CoinMetadata<TEST_COIN_A>>();

    // Should return true - name is empty
    assert!(coin_validation::is_name_empty(&metadata) == true, 0);

    scenario.return_to_sender(metadata);
    scenario.end();
}

#[test]
fun test_is_name_empty_false() {
    let mut scenario = test_scenario::begin(@0x1);

    // Create coin with name
    test_coin_b::create_with_name(scenario.ctx());
    scenario.next_tx(@0x1);

    let metadata = scenario.take_from_sender<CoinMetadata<TEST_COIN_B>>();

    // Should return false - name is not empty
    assert!(coin_validation::is_name_empty(&metadata) == false, 0);

    scenario.return_to_sender(metadata);
    scenario.end();
}

#[test]
fun test_is_metadata_empty_true() {
    let mut scenario = test_scenario::begin(@0x1);

    test_coin_a::init_for_testing(scenario.ctx());
    scenario.next_tx(@0x1);

    let metadata = scenario.take_from_sender<CoinMetadata<TEST_COIN_A>>();

    // Should return true - all metadata is empty
    assert!(coin_validation::is_metadata_empty(&metadata) == true, 0);

    scenario.return_to_sender(metadata);
    scenario.end();
}

#[test]
fun test_is_metadata_empty_false_description() {
    let mut scenario = test_scenario::begin(@0x1);

    // Create coin with description
    test_coin_b::create_with_description(scenario.ctx());
    scenario.next_tx(@0x1);

    let metadata = scenario.take_from_sender<CoinMetadata<TEST_COIN_B>>();

    // Should return false - description is not empty
    assert!(coin_validation::is_metadata_empty(&metadata) == false, 0);

    scenario.return_to_sender(metadata);
    scenario.end();
}

#[test]
fun test_is_metadata_empty_false_symbol() {
    let mut scenario = test_scenario::begin(@0x1);

    // Create coin with symbol
    test_coin_b::create_with_symbol(scenario.ctx());
    scenario.next_tx(@0x1);

    let metadata = scenario.take_from_sender<CoinMetadata<TEST_COIN_B>>();

    // Should return false - symbol is not empty
    assert!(coin_validation::is_metadata_empty(&metadata) == false, 0);

    scenario.return_to_sender(metadata);
    scenario.end();
}

#[test]
fun test_is_metadata_empty_false_icon() {
    let mut scenario = test_scenario::begin(@0x1);

    // Create coin with icon
    test_coin_b::create_with_icon(scenario.ctx());
    scenario.next_tx(@0x1);

    let metadata = scenario.take_from_sender<CoinMetadata<TEST_COIN_B>>();

    // Should return false - icon URL is not empty
    assert!(coin_validation::is_metadata_empty(&metadata) == false, 0);

    scenario.return_to_sender(metadata);
    scenario.end();
}

// === Edge Case Tests ===

#[test]
fun test_supply_returns_to_zero_after_burn() {
    let mut scenario = test_scenario::begin(@0x1);

    test_coin_a::init_for_testing(scenario.ctx());
    scenario.next_tx(@0x1);

    let mut treasury_cap = scenario.take_from_sender<TreasuryCap<TEST_COIN_A>>();

    // Mint and burn coins
    let coin = coin::mint(&mut treasury_cap, 1000, scenario.ctx());
    assert!(coin_validation::is_supply_zero(&treasury_cap) == false, 0);

    coin::burn(&mut treasury_cap, coin);

    // Supply should be zero again
    assert!(coin_validation::is_supply_zero(&treasury_cap) == true, 1);
    coin_validation::assert_zero_supply(&treasury_cap);

    scenario.return_to_sender(treasury_cap);
    scenario.end();
}

#[test]
fun test_multiple_metadata_checks() {
    let mut scenario = test_scenario::begin(@0x1);

    // Test with all metadata fields populated
    test_coin_b::create_with_all_metadata(scenario.ctx());
    scenario.next_tx(@0x1);

    let metadata = scenario.take_from_sender<CoinMetadata<TEST_COIN_B>>();

    // All view functions should return false
    assert!(coin_validation::is_name_empty(&metadata) == false, 0);
    assert!(coin_validation::is_metadata_empty(&metadata) == false, 1);

    scenario.return_to_sender(metadata);
    scenario.end();
}
