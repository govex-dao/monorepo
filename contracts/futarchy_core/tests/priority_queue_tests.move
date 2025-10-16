#[test_only]
module futarchy_core::priority_queue_tests;

use futarchy_core::priority_queue;

// === Constants from priority_queue.move ===
const MAX_REASONABLE_FEE: u64 = 1_000_000_000_000_000; // 1 million SUI
const COMPARE_GREATER: u8 = 1;
const COMPARE_EQUAL: u8 = 0;
const COMPARE_LESS: u8 = 2;

// === create_priority_score Tests ===

#[test]
fun test_create_priority_score_basic() {
    let score = priority_queue::create_priority_score(1000, 5000);

    // Verify fee and timestamp are stored
    let value = priority_queue::priority_score_value(&score);

    // Priority = (fee << 64) | (MAX_U64 - timestamp)
    // Expected: (1000 << 64) | (18446744073709551615 - 5000)
    let max_u64 = 18446744073709551615u64;
    let timestamp_inverted = max_u64 - 5000;
    let expected = ((1000 as u128) << 64) | (timestamp_inverted as u128);

    assert!(value == expected, 0);
}

#[test]
fun test_create_priority_score_zero_fee() {
    let score = priority_queue::create_priority_score(0, 1000);

    let value = priority_queue::priority_score_value(&score);

    // With fee = 0, priority is just inverted timestamp
    let max_u64 = 18446744073709551615u64;
    let timestamp_inverted = max_u64 - 1000;
    let expected = (timestamp_inverted as u128);

    assert!(value == expected, 0);
}

#[test]
fun test_create_priority_score_max_fee() {
    let max_fee = MAX_REASONABLE_FEE;
    let score = priority_queue::create_priority_score(max_fee, 1000);

    let value = priority_queue::priority_score_value(&score);

    let max_u64 = 18446744073709551615u64;
    let timestamp_inverted = max_u64 - 1000;
    let expected = ((max_fee as u128) << 64) | (timestamp_inverted as u128);

    assert!(value == expected, 0);
}

#[test]
fun test_create_priority_score_timestamp_zero() {
    let score = priority_queue::create_priority_score(1000, 0);

    let value = priority_queue::priority_score_value(&score);

    // Timestamp inverted = MAX_U64 - 0 = MAX_U64
    let max_u64 = 18446744073709551615u64;
    let expected = ((1000 as u128) << 64) | (max_u64 as u128);

    assert!(value == expected, 0);
}

#[test]
fun test_create_priority_score_timestamp_max() {
    let max_timestamp = 18446744073709551615u64;
    let score = priority_queue::create_priority_score(1000, max_timestamp);

    let value = priority_queue::priority_score_value(&score);

    // Timestamp inverted = MAX_U64 - MAX_U64 = 0
    let expected = ((1000 as u128) << 64) | 0;

    assert!(value == expected, 0);
}

#[test]
#[expected_failure(abort_code = priority_queue::EFeeExceedsMaximum)]
fun test_create_priority_score_fee_too_high() {
    let too_high = MAX_REASONABLE_FEE + 1;
    let _score = priority_queue::create_priority_score(too_high, 1000);
}

// === Priority Ordering Tests ===

#[test]
fun test_priority_higher_fee_wins() {
    let score_high_fee = priority_queue::create_priority_score(2000, 1000);
    let score_low_fee = priority_queue::create_priority_score(1000, 1000);

    // Same timestamp, higher fee should win
    let result = priority_queue::compare_priority_scores(&score_high_fee, &score_low_fee);
    assert!(result == COMPARE_GREATER, 0);

    let result_reverse = priority_queue::compare_priority_scores(&score_low_fee, &score_high_fee);
    assert!(result_reverse == COMPARE_LESS, 1);
}

#[test]
fun test_priority_earlier_timestamp_wins_same_fee() {
    let score_earlier = priority_queue::create_priority_score(1000, 1000);
    let score_later = priority_queue::create_priority_score(1000, 2000);

    // Same fee, earlier timestamp should win
    let result = priority_queue::compare_priority_scores(&score_earlier, &score_later);
    assert!(result == COMPARE_GREATER, 0);

    let result_reverse = priority_queue::compare_priority_scores(&score_later, &score_earlier);
    assert!(result_reverse == COMPARE_LESS, 1);
}

#[test]
fun test_priority_fee_dominates_timestamp() {
    // Higher fee with much later timestamp should still win
    let score_high_fee_late = priority_queue::create_priority_score(10000, 1000000);
    let score_low_fee_early = priority_queue::create_priority_score(100, 1000);

    // High fee dominates even though timestamp is much later
    let result = priority_queue::compare_priority_scores(
        &score_high_fee_late,
        &score_low_fee_early,
    );
    assert!(result == COMPARE_GREATER, 0);
}

#[test]
fun test_priority_equal() {
    let score1 = priority_queue::create_priority_score(1000, 5000);
    let score2 = priority_queue::create_priority_score(1000, 5000);

    let result = priority_queue::compare_priority_scores(&score1, &score2);
    assert!(result == COMPARE_EQUAL, 0);
}

#[test]
fun test_priority_equal_self() {
    let score = priority_queue::create_priority_score(1000, 5000);

    let result = priority_queue::compare_priority_scores(&score, &score);
    assert!(result == COMPARE_EQUAL, 0);
}

// === Timestamp Inversion Tests ===

#[test]
fun test_timestamp_inversion_ordering() {
    // Earlier timestamps should have HIGHER priority values after inversion
    let score_t1 = priority_queue::create_priority_score(1000, 1000);
    let score_t2 = priority_queue::create_priority_score(1000, 2000);
    let score_t3 = priority_queue::create_priority_score(1000, 3000);

    let val1 = priority_queue::priority_score_value(&score_t1);
    let val2 = priority_queue::priority_score_value(&score_t2);
    let val3 = priority_queue::priority_score_value(&score_t3);

    // Earlier timestamp = higher priority value
    assert!(val1 > val2, 0);
    assert!(val2 > val3, 1);
    assert!(val1 > val3, 2);
}

#[test]
fun test_timestamp_inversion_computation() {
    let timestamp = 12345u64;
    let score = priority_queue::create_priority_score(0, timestamp);

    let value = priority_queue::priority_score_value(&score);

    let max_u64 = 18446744073709551615u64;
    let expected_inverted = max_u64 - timestamp;

    assert!(value == (expected_inverted as u128), 0);
}

// === Edge Cases ===

#[test]
fun test_priority_zero_fee_different_timestamps() {
    let score1 = priority_queue::create_priority_score(0, 1000);
    let score2 = priority_queue::create_priority_score(0, 2000);

    // With zero fee, earlier timestamp still wins
    let result = priority_queue::compare_priority_scores(&score1, &score2);
    assert!(result == COMPARE_GREATER, 0);
}

#[test]
fun test_priority_large_fee_difference() {
    let score_high = priority_queue::create_priority_score(1_000_000, 1000);
    let score_low = priority_queue::create_priority_score(1, 1000);

    let result = priority_queue::compare_priority_scores(&score_high, &score_low);
    assert!(result == COMPARE_GREATER, 0);
}

#[test]
fun test_priority_small_timestamp_difference() {
    let score1 = priority_queue::create_priority_score(1000, 5000);
    let score2 = priority_queue::create_priority_score(1000, 5001);

    // Even 1ms difference matters for tiebreaking
    let result = priority_queue::compare_priority_scores(&score1, &score2);
    assert!(result == COMPARE_GREATER, 0);
}

#[test]
fun test_priority_max_values() {
    let score1 = priority_queue::create_priority_score(MAX_REASONABLE_FEE, 18446744073709551615u64);
    let score2 = priority_queue::create_priority_score(MAX_REASONABLE_FEE - 1, 0);

    // Higher fee wins even with worst timestamp
    let result = priority_queue::compare_priority_scores(&score1, &score2);
    assert!(result == COMPARE_GREATER, 0);
}

// === Bit Shifting Verification ===

#[test]
fun test_bit_shift_fee_upper_64_bits() {
    let fee = 42u64;
    let timestamp = 1000u64;
    let score = priority_queue::create_priority_score(fee, timestamp);

    let value = priority_queue::priority_score_value(&score);

    // Extract upper 64 bits (fee component)
    let extracted_fee = (value >> 64) as u64;
    assert!(extracted_fee == fee, 0);
}

#[test]
fun test_bit_shift_timestamp_lower_64_bits() {
    let fee = 1000u64;
    let timestamp = 5000u64;
    let score = priority_queue::create_priority_score(fee, timestamp);

    let value = priority_queue::priority_score_value(&score);

    // Extract lower 64 bits (inverted timestamp component)
    let mask = 0xFFFFFFFFFFFFFFFF; // 64 bits of 1s
    let extracted_timestamp_inverted = (value & mask) as u64;

    let max_u64 = 18446744073709551615u64;
    let expected_inverted = max_u64 - timestamp;

    assert!(extracted_timestamp_inverted == expected_inverted, 0);
}

#[test]
fun test_priority_computation_no_overflow() {
    // Test that the bit shift doesn't cause unexpected behavior
    let max_fee = MAX_REASONABLE_FEE;
    let max_timestamp = 18446744073709551615u64;

    let score = priority_queue::create_priority_score(max_fee, max_timestamp);
    let value = priority_queue::priority_score_value(&score);

    // Should be: (max_fee << 64) | 0
    let expected = ((max_fee as u128) << 64);
    assert!(value == expected, 0);
}

// === Transitivity Tests ===

#[test]
fun test_compare_transitivity() {
    let score_a = priority_queue::create_priority_score(3000, 1000);
    let score_b = priority_queue::create_priority_score(2000, 1000);
    let score_c = priority_queue::create_priority_score(1000, 1000);

    // If A > B and B > C, then A > C
    assert!(priority_queue::compare_priority_scores(&score_a, &score_b) == COMPARE_GREATER, 0);
    assert!(priority_queue::compare_priority_scores(&score_b, &score_c) == COMPARE_GREATER, 1);
    assert!(priority_queue::compare_priority_scores(&score_a, &score_c) == COMPARE_GREATER, 2);
}

#[test]
fun test_compare_symmetry() {
    let score1 = priority_queue::create_priority_score(1000, 5000);
    let score2 = priority_queue::create_priority_score(2000, 3000);

    let result_12 = priority_queue::compare_priority_scores(&score1, &score2);
    let result_21 = priority_queue::compare_priority_scores(&score2, &score1);

    // If A > B, then B < A
    if (result_12 == COMPARE_GREATER) {
        assert!(result_21 == COMPARE_LESS, 0);
    } else if (result_12 == COMPARE_LESS) {
        assert!(result_21 == COMPARE_GREATER, 1);
    } else {
        assert!(result_21 == COMPARE_EQUAL, 2);
    };
}

// === Real-World Scenarios ===

#[test]
fun test_realistic_proposal_fees() {
    // Simulate realistic SUI fees (1-100 SUI with 9 decimals)
    let proposal_1_sui = priority_queue::create_priority_score(1_000_000_000, 1000000); // 1 SUI
    let proposal_10_sui = priority_queue::create_priority_score(10_000_000_000, 1000000); // 10 SUI
    let proposal_100_sui = priority_queue::create_priority_score(100_000_000_000, 1000000); // 100 SUI

    // Higher fee proposals should rank higher
    assert!(
        priority_queue::compare_priority_scores(&proposal_100_sui, &proposal_10_sui) == COMPARE_GREATER,
        0,
    );
    assert!(
        priority_queue::compare_priority_scores(&proposal_10_sui, &proposal_1_sui) == COMPARE_GREATER,
        1,
    );
}

#[test]
fun test_same_fee_timestamp_race() {
    // Two proposals with same fee, submitted 1ms apart
    let proposal_first = priority_queue::create_priority_score(5_000_000_000, 1000000);
    let proposal_second = priority_queue::create_priority_score(5_000_000_000, 1000001);

    // First proposal should win
    let result = priority_queue::compare_priority_scores(&proposal_first, &proposal_second);
    assert!(result == COMPARE_GREATER, 0);
}

#[test]
fun test_fee_escalation_scenario() {
    // Original proposal with low fee
    let original = priority_queue::create_priority_score(1_000_000_000, 1000000);

    // Someone else submits with higher fee but later timestamp
    let competitor = priority_queue::create_priority_score(5_000_000_000, 1100000);

    // Competitor should rank higher despite later submission
    let result = priority_queue::compare_priority_scores(&competitor, &original);
    assert!(result == COMPARE_GREATER, 0);
}

// === Boundary Tests ===

#[test]
fun test_timestamp_boundary_zero() {
    let score_zero = priority_queue::create_priority_score(1000, 0);
    let score_one = priority_queue::create_priority_score(1000, 1);

    // Timestamp 0 is earliest, should have highest priority
    let result = priority_queue::compare_priority_scores(&score_zero, &score_one);
    assert!(result == COMPARE_GREATER, 0);
}

#[test]
fun test_fee_boundary_one() {
    let score1 = priority_queue::create_priority_score(1, 1000);
    let score0 = priority_queue::create_priority_score(0, 1000);

    // Even 1 unit of fee matters
    let result = priority_queue::compare_priority_scores(&score1, &score0);
    assert!(result == COMPARE_GREATER, 0);
}

#[test]
fun test_multiple_proposals_ordering() {
    // Create 5 proposals with varying fees and timestamps
    let p1 = priority_queue::create_priority_score(5_000_000_000, 1000);
    let p2 = priority_queue::create_priority_score(10_000_000_000, 2000);
    let p3 = priority_queue::create_priority_score(10_000_000_000, 1000);
    let p4 = priority_queue::create_priority_score(1_000_000_000, 3000);
    let p5 = priority_queue::create_priority_score(20_000_000_000, 5000);

    // Expected order: p5 > p3 > p2 > p1 > p4
    assert!(priority_queue::compare_priority_scores(&p5, &p3) == COMPARE_GREATER, 0);
    assert!(priority_queue::compare_priority_scores(&p3, &p2) == COMPARE_GREATER, 1);
    assert!(priority_queue::compare_priority_scores(&p2, &p1) == COMPARE_GREATER, 2);
    assert!(priority_queue::compare_priority_scores(&p1, &p4) == COMPARE_GREATER, 3);
}

// === Copy Semantics Tests ===

#[test]
fun test_priority_score_copy() {
    let score1 = priority_queue::create_priority_score(1000, 5000);
    let score2 = score1; // Uses copy

    let val1 = priority_queue::priority_score_value(&score1);
    let val2 = priority_queue::priority_score_value(&score2);

    assert!(val1 == val2, 0);

    // Both should still be usable
    let result = priority_queue::compare_priority_scores(&score1, &score2);
    assert!(result == COMPARE_EQUAL, 1);
}
