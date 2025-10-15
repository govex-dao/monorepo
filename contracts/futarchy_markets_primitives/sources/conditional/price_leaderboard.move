/// Price leaderboard using binary max-heap for O(log N) updates
/// Maintains sorted order of outcome prices with O(1) winner lookup
///
/// Performance guarantees:
/// - get_winner(): O(1)
/// - get_winner_and_spread(): O(1)
/// - update_price(): O(log N)
/// - init_from_prices(): O(N)
module futarchy_markets_primitives::price_leaderboard;

use std::vector;
use sui::table::{Self, Table};
use futarchy_one_shot_utils::binary_heap;

// === Errors ===
const EInsufficientOutcomes: u64 = 0;
const EOutcomeNotFound: u64 = 1;
const EAlreadyInitialized: u64 = 2;

// === Structs ===

/// Price leaderboard backed by binary max-heap
/// Stores outcome prices in sorted order for fast winner lookup
/// Must be explicitly destroyed with destroy() function
public struct PriceLeaderboard has store {
    /// Max heap: heap[0] = highest price (winner)
    /// Each node stores (outcome_index, price)
    heap: vector<PriceNode>,

    /// Fast lookup: outcome_index → position in heap
    /// Enables O(1) find + O(log N) update
    outcome_to_heap_index: Table<u64, u64>,
}

/// Heap node storing outcome and its price
public struct PriceNode has store, copy, drop {
    outcome_index: u64,
    price: u128,
}

// === Public Functions ===

/// Create empty leaderboard
public fun new(ctx: &mut TxContext): PriceLeaderboard {
    PriceLeaderboard {
        heap: vector::empty(),
        outcome_to_heap_index: table::new(ctx),
    }
}

/// Initialize leaderboard from outcome prices
/// prices[i] = price for outcome i
/// Complexity: O(N) using Floyd's heapify algorithm
public fun init_from_prices(
    prices: vector<u128>,
    ctx: &mut TxContext,
): PriceLeaderboard {
    let n = prices.length();
    let mut heap = vector::empty<PriceNode>();
    let mut index_map = table::new<u64, u64>(ctx);

    // Build initial unordered vector
    let mut i = 0u64;
    while (i < n) {
        let node = PriceNode {
            outcome_index: i,
            price: prices[i],
        };
        vector::push_back(&mut heap, node);
        table::add(&mut index_map, i, i); // Initial position = index
        i = i + 1;
    };

    // Heapify: O(N)
    build_max_heap(&mut heap, &mut index_map);

    PriceLeaderboard {
        heap,
        outcome_to_heap_index: index_map,
    }
}

/// Get winner (highest price) in O(1)
/// Returns (outcome_index, price)
public fun get_winner(leaderboard: &PriceLeaderboard): (u64, u128) {
    assert!(leaderboard.heap.length() >= 1, EInsufficientOutcomes);
    let winner = &leaderboard.heap[0];
    (winner.outcome_index, winner.price)
}

/// Get winner and spread in O(1)
/// Returns (winner_index, winner_price, spread)
/// Second-largest is guaranteed to be one of root's children (heap[1] or heap[2])
public fun get_winner_and_spread(leaderboard: &PriceLeaderboard): (u64, u128, u128) {
    assert!(leaderboard.heap.length() >= 2, EInsufficientOutcomes);

    let winner = &leaderboard.heap[0];

    // Second-largest MUST be one of the root's children
    let second_price = if (leaderboard.heap.length() == 2) {
        // Only 2 outcomes: second is heap[1]
        leaderboard.heap[1].price
    } else {
        // 3+ outcomes: compare both children, take larger
        let left = &leaderboard.heap[1];
        let right = &leaderboard.heap[2];
        if (left.price >= right.price) {
            left.price
        } else {
            right.price
        }
    };

    let spread = if (winner.price > second_price) {
        winner.price - second_price
    } else {
        0u128
    };

    (winner.outcome_index, winner.price, spread)
}

/// Update price for an outcome in O(log N)
/// Maintains heap invariant by bubbling up or down as needed
public fun update_price(
    leaderboard: &mut PriceLeaderboard,
    outcome_index: u64,
    new_price: u128,
) {
    // O(1) lookup of heap position
    assert!(
        table::contains(&leaderboard.outcome_to_heap_index, outcome_index),
        EOutcomeNotFound
    );
    let heap_idx = *table::borrow(&leaderboard.outcome_to_heap_index, outcome_index);

    // Get old price
    let old_price = leaderboard.heap[heap_idx].price;

    // Update price in node
    leaderboard.heap[heap_idx].price = new_price;

    // Restore heap property: O(log N)
    if (new_price > old_price) {
        // Price increased: bubble up towards root
        sift_up(&mut leaderboard.heap, &mut leaderboard.outcome_to_heap_index, heap_idx);
    } else if (new_price < old_price) {
        // Price decreased: bubble down away from root
        sift_down(&mut leaderboard.heap, &mut leaderboard.outcome_to_heap_index, heap_idx);
    };
    // else: price unchanged, heap already valid
}

/// Get price for a specific outcome in O(1)
public fun get_price(
    leaderboard: &PriceLeaderboard,
    outcome_index: u64,
): u128 {
    let heap_idx = *table::borrow(&leaderboard.outcome_to_heap_index, outcome_index);
    leaderboard.heap[heap_idx].price
}

/// Get number of outcomes in leaderboard
public fun size(leaderboard: &PriceLeaderboard): u64 {
    leaderboard.heap.length()
}

/// Check if leaderboard contains outcome
public fun contains(leaderboard: &PriceLeaderboard, outcome_index: u64): bool {
    table::contains(&leaderboard.outcome_to_heap_index, outcome_index)
}

/// Get all prices in outcome order (not heap order)
public fun get_all_prices(leaderboard: &PriceLeaderboard): vector<u128> {
    let n = leaderboard.heap.length();
    let mut prices = vector::empty<u128>();

    let mut i = 0u64;
    while (i < n) {
        let price = get_price(leaderboard, i);
        vector::push_back(&mut prices, price);
        i = i + 1;
    };

    prices
}

// === Internal Heap Operations ===

/// Build max heap from unordered vector - O(N)
/// Uses Floyd's algorithm: start from last non-leaf and sift down
fun build_max_heap(
    heap: &mut vector<PriceNode>,
    index_map: &mut Table<u64, u64>,
) {
    let n = heap.length();
    if (n <= 1) return;

    // Start from last non-leaf node: parent of last element
    let mut i = (n - 1) / 2;
    loop {
        sift_down(heap, index_map, i);
        if (i == 0) break;
        i = i - 1;
    };
}

/// Bubble node up towards root (when price increases)
/// Max heap property: parent.price >= child.price
fun sift_up(
    heap: &mut vector<PriceNode>,
    index_map: &mut Table<u64, u64>,
    mut idx: u64,
) {
    while (idx > 0) {
        let parent_idx = binary_heap::parent(idx);

        // Check heap property
        if (heap[parent_idx].price >= heap[idx].price) {
            break // Heap property satisfied
        };

        // Swap with parent
        swap_nodes(heap, index_map, idx, parent_idx);
        idx = parent_idx;
    };
}

/// Bubble node down away from root (when price decreases)
/// Swaps with largest child until heap property restored
fun sift_down(
    heap: &mut vector<PriceNode>,
    index_map: &mut Table<u64, u64>,
    mut idx: u64,
) {
    let n = heap.length();

    loop {
        let left_idx = binary_heap::left(idx);
        let right_idx = binary_heap::right(idx);
        let mut largest_idx = idx;

        // Find largest among node and its children
        if (left_idx < n && heap[left_idx].price > heap[largest_idx].price) {
            largest_idx = left_idx;
        };
        if (right_idx < n && heap[right_idx].price > heap[largest_idx].price) {
            largest_idx = right_idx;
        };

        if (largest_idx == idx) {
            break // Heap property satisfied
        };

        // Swap with largest child
        swap_nodes(heap, index_map, idx, largest_idx);
        idx = largest_idx;
    };
}

/// Swap two nodes and update index map
/// Maintains invariant: index_map[outcome_idx] = heap_position
fun swap_nodes(
    heap: &mut vector<PriceNode>,
    index_map: &mut Table<u64, u64>,
    i: u64,
    j: u64,
) {
    // Get nodes
    let node_i = heap[i];
    let node_j = heap[j];

    // Swap in heap vector
    vector::swap(heap, i, j);

    // Update index map: outcome_idx → new heap position
    *table::borrow_mut(index_map, node_i.outcome_index) = j;
    *table::borrow_mut(index_map, node_j.outcome_index) = i;
}

// === Public Destruction ===

/// Destroy leaderboard and clean up table
public fun destroy(leaderboard: PriceLeaderboard) {
    let PriceLeaderboard { heap: _, outcome_to_heap_index } = leaderboard;
    table::drop(outcome_to_heap_index);
}

// === Test Helpers ===

#[test_only]
/// Verify heap property: parent >= children for all nodes
public fun verify_heap_property(leaderboard: &PriceLeaderboard): bool {
    let heap = &leaderboard.heap;
    let n = heap.length();

    let mut i = 0u64;
    while (i < n) {
        let left_idx = binary_heap::left(i);
        let right_idx = binary_heap::right(i);

        if (left_idx < n) {
            assert!(heap[i].price >= heap[left_idx].price, 0);
        };
        if (right_idx < n) {
            assert!(heap[i].price >= heap[right_idx].price, 0);
        };

        i = i + 1;
    };

    true
}

#[test_only]
/// Verify index map matches actual heap positions
public fun verify_index_map(leaderboard: &PriceLeaderboard): bool {
    let heap = &leaderboard.heap;
    let n = heap.length();

    let mut i = 0u64;
    while (i < n) {
        let node = &heap[i];
        let mapped_idx = *table::borrow(&leaderboard.outcome_to_heap_index, node.outcome_index);
        assert!(mapped_idx == i, 0);
        i = i + 1;
    };

    true
}

#[test_only]
/// Get heap as vector for testing
public fun get_heap_vector(leaderboard: &PriceLeaderboard): vector<PriceNode> {
    leaderboard.heap
}
