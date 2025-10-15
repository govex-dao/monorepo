/// Generic binary heap operations for vectors
/// Extracted from conditional market price leader board
module futarchy_one_shot_utils::binary_heap;

use std::vector;

// === Max Heap Operations for vector<u64> ===

/// Get parent index in heap
public fun parent(i: u64): u64 { 
    if (i == 0) 0 else (i - 1) / 2 
}

/// Get left child index in heap
public fun left(i: u64): u64 { 
    2 * i + 1 
}

/// Get right child index in heap
public fun right(i: u64): u64 { 
    2 * i + 2 
}

/// Maintain max heap property by moving element down
public fun heapify_down(v: &mut vector<u64>, mut i: u64, size: u64) {
    loop {
        let l = left(i);
        let r = right(i);
        let mut largest = i;

        if (l < size && *vector::borrow(v, l) > *vector::borrow(v, largest)) {
            largest = l;
        };
        if (r < size && *vector::borrow(v, r) > *vector::borrow(v, largest)) {
            largest = r;
        };
        if (largest == i) break;
        vector::swap(v, i, largest);
        i = largest;
    }
}

/// Build a max heap from an unordered vector
public fun build_max_heap(v: &mut vector<u64>) {
    let sz = vector::length(v);
    if (sz <= 1) return;
    
    let mut i = (sz - 1) / 2;
    loop {
        heapify_down(v, i, sz);
        if (i == 0) break;
        i = i - 1;
    };
}

/// Peek at the maximum element (root) without removing
public fun heap_peek(v: &vector<u64>): u64 {
    assert!(!vector::is_empty(v), 0);
    *vector::borrow(v, 0)
}

/// Remove and return the maximum element
public fun heap_pop(v: &mut vector<u64>): u64 {
    let size = vector::length(v);
    assert!(size > 0, 0);
    
    let top = *vector::borrow(v, 0);
    let last_idx = size - 1;
    
    if (last_idx != 0) {
        vector::swap(v, 0, last_idx);
    };
    let _ = vector::pop_back(v);
    
    if (last_idx > 1) {
        heapify_down(v, 0, last_idx);
    };
    
    top
}

/// Insert element and maintain heap property
public fun heap_push(v: &mut vector<u64>, value: u64) {
    vector::push_back(v, value);
    let mut i = vector::length(v) - 1;
    
    // Bubble up
    while (i > 0) {
        let p = parent(i);
        if (*vector::borrow(v, p) >= *vector::borrow(v, i)) break;
        vector::swap(v, i, p);
        i = p;
    }
}