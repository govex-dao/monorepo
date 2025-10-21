#[test_only]
module futarchy_one_shot_utils::strategy_tests;

use futarchy_one_shot_utils::strategy;

#[test]
fun test_all_strategies() {
    // AND strategy - both must be true
    let and_strat = strategy::and();
    assert!(strategy::can_execute(true, true, and_strat) == true, 0);
    assert!(strategy::can_execute(true, false, and_strat) == false, 1);
    assert!(strategy::can_execute(false, true, and_strat) == false, 2);
    assert!(strategy::can_execute(false, false, and_strat) == false, 3);

    // OR strategy - at least one must be true
    let or_strat = strategy::or();
    assert!(strategy::can_execute(true, true, or_strat) == true, 4);
    assert!(strategy::can_execute(true, false, or_strat) == true, 5);
    assert!(strategy::can_execute(false, true, or_strat) == true, 6);
    assert!(strategy::can_execute(false, false, or_strat) == false, 7);

    // EITHER strategy (XOR) - exactly one must be true
    let either_strat = strategy::either();
    assert!(strategy::can_execute(true, true, either_strat) == false, 8);
    assert!(strategy::can_execute(true, false, either_strat) == true, 9);
    assert!(strategy::can_execute(false, true, either_strat) == true, 10);
    assert!(strategy::can_execute(false, false, either_strat) == false, 11);

    // THRESHOLD strategy - m-of-n
    let threshold_2_of_2 = strategy::threshold(2, 2);
    assert!(strategy::can_execute(true, true, threshold_2_of_2) == true, 12);
    assert!(strategy::can_execute(true, false, threshold_2_of_2) == false, 13);

    let threshold_1_of_2 = strategy::threshold(1, 2);
    assert!(strategy::can_execute(true, false, threshold_1_of_2) == true, 14);
    assert!(strategy::can_execute(false, true, threshold_1_of_2) == true, 15);
    assert!(strategy::can_execute(false, false, threshold_1_of_2) == false, 16);
}

#[test]
fun test_threshold_strategy_all_cases() {
    // Test 1-of-2 threshold
    let threshold_1_2 = strategy::threshold(1, 2);
    assert!(strategy::can_execute(true, true, threshold_1_2) == true, 0);
    assert!(strategy::can_execute(true, false, threshold_1_2) == true, 1);
    assert!(strategy::can_execute(false, true, threshold_1_2) == true, 2);
    assert!(strategy::can_execute(false, false, threshold_1_2) == false, 3);

    // Test 2-of-2 threshold
    let threshold_2_2 = strategy::threshold(2, 2);
    assert!(strategy::can_execute(true, true, threshold_2_2) == true, 4);
    assert!(strategy::can_execute(true, false, threshold_2_2) == false, 5);
    assert!(strategy::can_execute(false, true, threshold_2_2) == false, 6);
    assert!(strategy::can_execute(false, false, threshold_2_2) == false, 7);
}

// Note: Cannot test unknown strategy type from outside the module
// as Strategy struct is not public for instantiation

// === Coverage Tests for Uncovered Lines ===

#[test]
fun test_threshold_invalid_parameters() {
    // Test threshold where n < m (invalid config, should always return false)
    // This ensures we cover the full condition: satisfied_count >= s.m && s.n >= s.m
    // Lines 47-50
    let invalid_threshold = strategy::threshold(3, 2); // Want 3 approvals but only have 2 conditions
    
    // Even if both are true (satisfied_count = 2), n < m means this should fail
    assert!(strategy::can_execute(true, true, invalid_threshold) == false, 0);
    assert!(strategy::can_execute(true, false, invalid_threshold) == false, 1);
    assert!(strategy::can_execute(false, true, invalid_threshold) == false, 2);
    assert!(strategy::can_execute(false, false, invalid_threshold) == false, 3);
}
