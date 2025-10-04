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
