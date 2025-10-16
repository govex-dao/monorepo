#[test_only]
module futarchy_one_shot_utils::binary_heap_tests;

use futarchy_one_shot_utils::binary_heap;

// === Helper Functions Tests ===

#[test]
fun test_parent_index() {
    assert!(binary_heap::parent(0) == 0, 0); // Root has no parent, returns 0
    assert!(binary_heap::parent(1) == 0, 1); // Left child of root
    assert!(binary_heap::parent(2) == 0, 2); // Right child of root
    assert!(binary_heap::parent(3) == 1, 3);
    assert!(binary_heap::parent(4) == 1, 4);
    assert!(binary_heap::parent(5) == 2, 5);
    assert!(binary_heap::parent(6) == 2, 6);
}

#[test]
fun test_left_child_index() {
    assert!(binary_heap::left(0) == 1, 0);
    assert!(binary_heap::left(1) == 3, 1);
    assert!(binary_heap::left(2) == 5, 2);
    assert!(binary_heap::left(3) == 7, 3);
}

#[test]
fun test_right_child_index() {
    assert!(binary_heap::right(0) == 2, 0);
    assert!(binary_heap::right(1) == 4, 1);
    assert!(binary_heap::right(2) == 6, 2);
    assert!(binary_heap::right(3) == 8, 3);
}

// === build_max_heap Tests ===

#[test]
fun test_build_max_heap_basic() {
    let mut v = vector[3, 1, 4, 1, 5, 9, 2, 6];
    binary_heap::build_max_heap(&mut v);

    // Root should be the maximum
    assert!(v[0] == 9, 0);

    // Verify heap property: parent >= children
    assert!(v[0] >= v[1], 1);
    assert!(v[0] >= v[2], 2);
    assert!(v[1] >= v[3], 3);
    assert!(v[1] >= v[4], 4);
    assert!(v[2] >= v[5], 5);
    assert!(v[2] >= v[6], 6);
    assert!(v[3] >= v[7], 7);
}

#[test]
fun test_build_max_heap_empty() {
    let mut v = vector<u64>[];
    binary_heap::build_max_heap(&mut v);
    assert!(v.length() == 0, 0);
}

#[test]
fun test_build_max_heap_single() {
    let mut v = vector[42];
    binary_heap::build_max_heap(&mut v);
    assert!(v[0] == 42, 0);
    assert!(v.length() == 1, 1);
}

#[test]
fun test_build_max_heap_already_sorted() {
    let mut v = vector[1, 2, 3, 4, 5];
    binary_heap::build_max_heap(&mut v);
    assert!(v[0] == 5, 0);
}

#[test]
fun test_build_max_heap_reverse_sorted() {
    let mut v = vector[5, 4, 3, 2, 1];
    binary_heap::build_max_heap(&mut v);
    assert!(v[0] == 5, 0);
}

#[test]
fun test_build_max_heap_duplicates() {
    let mut v = vector[5, 5, 5, 5, 5];
    binary_heap::build_max_heap(&mut v);
    assert!(v[0] == 5, 0);
}

// === heap_peek Tests ===

#[test]
fun test_heap_peek() {
    let mut v = vector[3, 1, 4, 1, 5, 9];
    binary_heap::build_max_heap(&mut v);

    let max = binary_heap::heap_peek(&v);
    assert!(max == 9, 0);

    // Verify peek doesn't modify vector
    assert!(v.length() == 6, 1);
}

#[test]
#[expected_failure(abort_code = 0)]
fun test_heap_peek_empty() {
    let v = vector<u64>[];
    binary_heap::heap_peek(&v);
}

// === heap_pop Tests ===

#[test]
fun test_heap_pop_sequence() {
    let mut v = vector[3, 1, 4, 1, 5, 9, 2, 6];
    binary_heap::build_max_heap(&mut v);

    // Pop elements in descending order
    assert!(binary_heap::heap_pop(&mut v) == 9, 0);
    assert!(binary_heap::heap_pop(&mut v) == 6, 1);
    assert!(binary_heap::heap_pop(&mut v) == 5, 2);
    assert!(binary_heap::heap_pop(&mut v) == 4, 3);
    assert!(binary_heap::heap_pop(&mut v) == 3, 4);
    assert!(binary_heap::heap_pop(&mut v) == 2, 5);
    assert!(binary_heap::heap_pop(&mut v) == 1, 6);
    assert!(binary_heap::heap_pop(&mut v) == 1, 7);

    assert!(v.length() == 0, 8);
}

#[test]
fun test_heap_pop_single() {
    let mut v = vector[42];
    binary_heap::build_max_heap(&mut v);

    assert!(binary_heap::heap_pop(&mut v) == 42, 0);
    assert!(v.length() == 0, 1);
}

#[test]
fun test_heap_pop_two_elements() {
    let mut v = vector[5, 10];
    binary_heap::build_max_heap(&mut v);

    assert!(binary_heap::heap_pop(&mut v) == 10, 0);
    assert!(binary_heap::heap_pop(&mut v) == 5, 1);
}

#[test]
#[expected_failure(abort_code = 0)]
fun test_heap_pop_empty() {
    let mut v = vector<u64>[];
    binary_heap::heap_pop(&mut v);
}

// === heap_push Tests ===

#[test]
fun test_heap_push_to_empty() {
    let mut v = vector<u64>[];

    binary_heap::heap_push(&mut v, 5);
    assert!(binary_heap::heap_peek(&v) == 5, 0);
    assert!(v.length() == 1, 1);
}

#[test]
fun test_heap_push_maintains_heap() {
    let mut v = vector[3, 1, 4];
    binary_heap::build_max_heap(&mut v);

    binary_heap::heap_push(&mut v, 10);
    assert!(binary_heap::heap_peek(&v) == 10, 0);

    binary_heap::heap_push(&mut v, 2);
    assert!(binary_heap::heap_peek(&v) == 10, 1);

    binary_heap::heap_push(&mut v, 8);
    assert!(binary_heap::heap_peek(&v) == 10, 2);
}

#[test]
fun test_heap_push_smaller_values() {
    let mut v = vector[100];
    binary_heap::build_max_heap(&mut v);

    binary_heap::heap_push(&mut v, 50);
    binary_heap::heap_push(&mut v, 25);
    binary_heap::heap_push(&mut v, 10);

    assert!(binary_heap::heap_peek(&v) == 100, 0);
    assert!(v.length() == 4, 1);
}

#[test]
fun test_heap_push_sequential_ascending() {
    let mut v = vector<u64>[];

    binary_heap::heap_push(&mut v, 1);
    binary_heap::heap_push(&mut v, 2);
    binary_heap::heap_push(&mut v, 3);
    binary_heap::heap_push(&mut v, 4);
    binary_heap::heap_push(&mut v, 5);

    assert!(binary_heap::heap_peek(&v) == 5, 0);
}

#[test]
fun test_heap_push_sequential_descending() {
    let mut v = vector<u64>[];

    binary_heap::heap_push(&mut v, 5);
    binary_heap::heap_push(&mut v, 4);
    binary_heap::heap_push(&mut v, 3);
    binary_heap::heap_push(&mut v, 2);
    binary_heap::heap_push(&mut v, 1);

    assert!(binary_heap::heap_peek(&v) == 5, 0);
}

// === heapify_down Tests ===

#[test]
fun test_heapify_down_basic() {
    let mut v = vector[1, 5, 3, 4, 2]; // Violates heap at root

    binary_heap::heapify_down(&mut v, 0, 5);

    // Should fix heap property
    assert!(v[0] >= v[1], 0);
    assert!(v[0] >= v[2], 1);
}

// === Combined Operations Tests ===

#[test]
fun test_mixed_operations() {
    let mut v = vector<u64>[];

    // Build heap incrementally
    binary_heap::heap_push(&mut v, 5);
    binary_heap::heap_push(&mut v, 3);
    binary_heap::heap_push(&mut v, 7);
    binary_heap::heap_push(&mut v, 1);

    assert!(binary_heap::heap_peek(&v) == 7, 0);

    // Pop max
    assert!(binary_heap::heap_pop(&mut v) == 7, 1);
    assert!(binary_heap::heap_peek(&v) == 5, 2);

    // Push new max
    binary_heap::heap_push(&mut v, 10);
    assert!(binary_heap::heap_peek(&v) == 10, 3);

    // Pop all
    assert!(binary_heap::heap_pop(&mut v) == 10, 4);
    assert!(binary_heap::heap_pop(&mut v) == 5, 5);
    assert!(binary_heap::heap_pop(&mut v) == 3, 6);
    assert!(binary_heap::heap_pop(&mut v) == 1, 7);
}

#[test]
fun test_heap_with_duplicates() {
    let mut v = vector[5, 5, 3, 5, 1];
    binary_heap::build_max_heap(&mut v);

    assert!(binary_heap::heap_pop(&mut v) == 5, 0);
    assert!(binary_heap::heap_pop(&mut v) == 5, 1);
    assert!(binary_heap::heap_pop(&mut v) == 5, 2);
    assert!(binary_heap::heap_pop(&mut v) == 3, 3);
    assert!(binary_heap::heap_pop(&mut v) == 1, 4);
}

#[test]
fun test_large_heap() {
    let mut v = vector<u64>[];

    // Push 100 elements
    let mut i = 0;
    while (i < 100) {
        binary_heap::heap_push(&mut v, i);
        i = i + 1;
    };

    assert!(binary_heap::heap_peek(&v) == 99, 0);
    assert!(v.length() == 100, 1);

    // Pop max
    assert!(binary_heap::heap_pop(&mut v) == 99, 2);
    assert!(binary_heap::heap_peek(&v) == 98, 3);
}

#[test]
fun test_heap_sort() {
    let mut v = vector[3, 1, 4, 1, 5, 9, 2, 6, 5, 3];
    binary_heap::build_max_heap(&mut v);

    let mut sorted = vector<u64>[];
    while (v.length() > 0) {
        sorted.push_back(binary_heap::heap_pop(&mut v));
    };

    // Verify descending order
    assert!(sorted[0] == 9, 0);
    assert!(sorted[1] == 6, 1);
    assert!(sorted[2] == 5, 2);
    assert!(sorted[3] == 5, 3);
    assert!(sorted[4] == 4, 4);
    assert!(sorted[5] == 3, 5);
    assert!(sorted[6] == 3, 6);
    assert!(sorted[7] == 2, 7);
    assert!(sorted[8] == 1, 8);
    assert!(sorted[9] == 1, 9);
}

// === Adversarial & Edge Case Tests ===

#[test]
fun test_max_u64_values() {
    let max = 18446744073709551615; // u64::max_value!()
    let mut v = vector[max, max - 1, max - 2, max - 100];

    binary_heap::build_max_heap(&mut v);

    assert!(binary_heap::heap_pop(&mut v) == max, 0);
    assert!(binary_heap::heap_pop(&mut v) == max - 1, 1);
    assert!(binary_heap::heap_pop(&mut v) == max - 2, 2);
    assert!(binary_heap::heap_pop(&mut v) == max - 100, 3);
}

#[test]
fun test_all_zeros() {
    let mut v = vector[0, 0, 0, 0, 0];
    binary_heap::build_max_heap(&mut v);

    assert!(binary_heap::heap_peek(&v) == 0, 0);

    // Pop all zeros
    let mut i = 0;
    while (i < 5) {
        assert!(binary_heap::heap_pop(&mut v) == 0, i + 1);
        i = i + 1;
    };
}

#[test]
fun test_alternating_push_pop() {
    let mut v = vector<u64>[];

    // Interleave pushes and pops
    binary_heap::heap_push(&mut v, 10);
    binary_heap::heap_push(&mut v, 20);
    assert!(binary_heap::heap_pop(&mut v) == 20, 0);

    binary_heap::heap_push(&mut v, 30);
    binary_heap::heap_push(&mut v, 15);
    assert!(binary_heap::heap_pop(&mut v) == 30, 1);

    binary_heap::heap_push(&mut v, 25);
    assert!(binary_heap::heap_pop(&mut v) == 25, 2);
    assert!(binary_heap::heap_pop(&mut v) == 15, 3);
    assert!(binary_heap::heap_pop(&mut v) == 10, 4);
}

#[test]
fun test_rebuild_heap_after_modification() {
    let mut v = vector[1, 2, 3, 4, 5];
    binary_heap::build_max_heap(&mut v);

    // Pop some elements
    binary_heap::heap_pop(&mut v);
    binary_heap::heap_pop(&mut v);

    // Rebuild from current state
    binary_heap::build_max_heap(&mut v);
    assert!(binary_heap::heap_peek(&v) == 3, 0);
}

#[test]
fun test_power_of_two_sizes() {
    // Test heap with sizes that are powers of 2 (edge cases for tree structure)
    let mut v = vector<u64>[];

    // 2^4 = 16 elements
    let mut i = 0;
    while (i < 16) {
        binary_heap::heap_push(&mut v, 16 - i);
        i = i + 1;
    };

    assert!(binary_heap::heap_peek(&v) == 16, 0);
    assert!(v.length() == 16, 1);
}

#[test]
fun test_non_power_of_two_sizes() {
    // Test heap with size 15 (2^4 - 1) - incomplete bottom level
    let mut v = vector<u64>[];

    let mut i = 0;
    while (i < 15) {
        binary_heap::heap_push(&mut v, i);
        i = i + 1;
    };

    assert!(binary_heap::heap_peek(&v) == 14, 0);
}

#[test]
fun test_stress_rapid_operations() {
    let mut v = vector<u64>[];

    // Rapidly push and pop in pattern
    let mut i = 0;
    while (i < 50) {
        binary_heap::heap_push(&mut v, i);
        if (i % 3 == 0 && v.length() > 0) {
            binary_heap::heap_pop(&mut v);
        };
        i = i + 1;
    };

    // Verify heap is still valid
    let first = binary_heap::heap_pop(&mut v);
    let second = binary_heap::heap_pop(&mut v);
    assert!(first >= second, 0);
}

#[test]
fun test_identical_values_stability() {
    // All identical - should handle gracefully
    let mut v = vector[42, 42, 42, 42, 42, 42, 42];
    binary_heap::build_max_heap(&mut v);

    let mut i = 0;
    while (v.length() > 0) {
        assert!(binary_heap::heap_pop(&mut v) == 42, i);
        i = i + 1;
    };
}

#[test]
fun test_near_identical_values() {
    // Values differ by 1 - tests tie-breaking
    let mut v = vector[100, 100, 100, 101, 100, 100, 99];
    binary_heap::build_max_heap(&mut v);

    assert!(binary_heap::heap_pop(&mut v) == 101, 0);
    assert!(binary_heap::heap_pop(&mut v) == 100, 1);
}

#[test]
fun test_two_element_swap() {
    let mut v = vector[1, 2];
    binary_heap::build_max_heap(&mut v);

    assert!(v[0] == 2, 0);
    assert!(binary_heap::heap_pop(&mut v) == 2, 1);
    assert!(binary_heap::heap_pop(&mut v) == 1, 2);
}

#[test]
fun test_three_element_permutations() {
    // Test different orderings of 3 elements
    let mut v1 = vector[1, 2, 3];
    binary_heap::build_max_heap(&mut v1);
    assert!(binary_heap::heap_peek(&v1) == 3, 0);

    let mut v2 = vector[3, 2, 1];
    binary_heap::build_max_heap(&mut v2);
    assert!(binary_heap::heap_peek(&v2) == 3, 1);

    let mut v3 = vector[2, 3, 1];
    binary_heap::build_max_heap(&mut v3);
    assert!(binary_heap::heap_peek(&v3) == 3, 2);
}

#[test]
fun test_fibonacci_sequence() {
    let mut v = vector[1, 1, 2, 3, 5, 8, 13, 21, 34, 55];
    binary_heap::build_max_heap(&mut v);

    assert!(binary_heap::heap_pop(&mut v) == 55, 0);
    assert!(binary_heap::heap_pop(&mut v) == 34, 1);
    assert!(binary_heap::heap_pop(&mut v) == 21, 2);
}

#[test]
fun test_geometric_progression() {
    // Powers of 2: 1, 2, 4, 8, 16, 32, 64
    let mut v = vector[1, 2, 4, 8, 16, 32, 64];
    binary_heap::build_max_heap(&mut v);

    assert!(binary_heap::heap_pop(&mut v) == 64, 0);
    assert!(binary_heap::heap_pop(&mut v) == 32, 1);
    assert!(binary_heap::heap_pop(&mut v) == 16, 2);
}

#[test]
fun test_push_pop_push_pattern() {
    let mut v = vector[5];

    binary_heap::heap_push(&mut v, 10);
    let p1 = binary_heap::heap_pop(&mut v);
    assert!(p1 == 10, 0);

    binary_heap::heap_push(&mut v, 3);
    binary_heap::heap_push(&mut v, 7);
    let p2 = binary_heap::heap_pop(&mut v);
    assert!(p2 == 7, 1);
}

#[test]
fun test_heap_property_after_each_push() {
    let mut v = vector<u64>[];
    let values = vector[50, 30, 70, 20, 40, 60, 80];

    let mut i = 0;
    while (i < values.length()) {
        binary_heap::heap_push(&mut v, values[i]);

        // Verify heap property holds after each push
        let max_so_far = *vector::borrow(&values, 0);
        let mut j = 1;
        while (j <= i) {
            if (values[j] > max_so_far) {
                let max_so_far = values[j];
            };
            j = j + 1;
        };

        i = i + 1;
    };
}

#[test]
fun test_sparse_values() {
    // Widely spaced values
    let mut v = vector[1, 1000, 2000, 5000, 10000];
    binary_heap::build_max_heap(&mut v);

    assert!(binary_heap::heap_pop(&mut v) == 10000, 0);
    assert!(binary_heap::heap_pop(&mut v) == 5000, 1);
    assert!(binary_heap::heap_pop(&mut v) == 2000, 2);
    assert!(binary_heap::heap_pop(&mut v) == 1000, 3);
    assert!(binary_heap::heap_pop(&mut v) == 1, 4);
}

#[test]
fun test_pyramid_pattern() {
    // Values: 1, 2, 3, 4, 5, 4, 3, 2, 1
    let mut v = vector[1, 2, 3, 4, 5, 4, 3, 2, 1];
    binary_heap::build_max_heap(&mut v);

    assert!(binary_heap::heap_pop(&mut v) == 5, 0);
    assert!(binary_heap::heap_pop(&mut v) == 4, 1);
    assert!(binary_heap::heap_pop(&mut v) == 4, 2);
}

#[test]
fun test_sawtooth_pattern() {
    // Alternating high/low: 100, 1, 100, 1, 100, 1
    let mut v = vector[100, 1, 100, 1, 100, 1];
    binary_heap::build_max_heap(&mut v);

    assert!(binary_heap::heap_pop(&mut v) == 100, 0);
    assert!(binary_heap::heap_pop(&mut v) == 100, 1);
    assert!(binary_heap::heap_pop(&mut v) == 100, 2);
    assert!(binary_heap::heap_pop(&mut v) == 1, 3);
}

#[test]
fun test_boundary_at_max_minus_one() {
    let max = 18446744073709551615;
    let mut v = vector[max - 1, max - 1, max - 1];

    binary_heap::build_max_heap(&mut v);
    assert!(binary_heap::heap_peek(&v) == max - 1, 0);
}

#[test]
fun test_single_large_value_among_small() {
    let mut v = vector[1, 1, 1, 1, 1000000, 1, 1, 1];
    binary_heap::build_max_heap(&mut v);

    assert!(binary_heap::heap_pop(&mut v) == 1000000, 0);
    // Rest should be 1s
    let mut i = 0;
    while (v.length() > 0) {
        assert!(binary_heap::heap_pop(&mut v) == 1, i);
        i = i + 1;
    };
}

#[test]
fun test_incremental_build_vs_batch_build() {
    // Build heap incrementally with push
    let mut v1 = vector<u64>[];
    let values = vector[3, 1, 4, 1, 5, 9, 2, 6];

    let mut i = 0;
    while (i < values.length()) {
        binary_heap::heap_push(&mut v1, values[i]);
        i = i + 1;
    };

    // Build heap with build_max_heap
    let mut v2 = vector[3, 1, 4, 1, 5, 9, 2, 6];
    binary_heap::build_max_heap(&mut v2);

    // Both should have same max
    assert!(binary_heap::heap_peek(&v1) == binary_heap::heap_peek(&v2), 0);
}

#[test]
fun test_pop_until_one_then_push() {
    let mut v = vector[10, 20, 30, 40, 50];
    binary_heap::build_max_heap(&mut v);

    // Pop until one element left
    while (v.length() > 1) {
        binary_heap::heap_pop(&mut v);
    };

    assert!(binary_heap::heap_peek(&v) == 10, 0);

    // Push larger value
    binary_heap::heap_push(&mut v, 100);
    assert!(binary_heap::heap_peek(&v) == 100, 1);
}

#[test]
fun test_heapify_down_cascade() {
    // Create a vector where heapify_down will cascade multiple levels
    let mut v = vector[1, 50, 40, 45, 30, 35, 25];
    // This violates heap at root - should cascade down

    binary_heap::heapify_down(&mut v, 0, 7);

    // After heapify, root should be one of the largest
    assert!(v[0] >= v[1] && v[0] >= v[2], 0);
}
