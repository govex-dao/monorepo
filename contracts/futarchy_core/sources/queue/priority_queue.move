// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

/// Priority Queue Implementation Using Binary Heap
/// Provides O(log n) insertion and extraction for scalable gas costs
module futarchy_core::priority_queue;

use account_protocol::account::{Self, Account};
use futarchy_core::futarchy_config::{Self, FutarchyConfig, SlashDistribution};
use futarchy_core::proposal_fee_manager::{Self, ProposalFeeManager};
use futarchy_types::init_action_specs::{Self, InitActionSpecs};
use std::option::{Self, Option};
use std::string::String;
use std::u128;
use std::u64;
use std::vector;
use sui::clock::{Self, Clock};
use sui::coin::{Self, Coin};
use sui::event;
use sui::object::{Self, ID, UID};
use sui::sui::SUI;
use sui::table::{Self, Table};
use sui::transfer;
use sui::tx_context::{Self, TxContext};

// === Events ===

/// Emitted when a proposal is evicted from the queue due to a higher-priority proposal
public struct ProposalEvicted has copy, drop {
    proposal_id: ID,
    proposer: address,
    fee: u64,
    evicted_by: ID,
    timestamp: u64,
    priority_score: u128,
    new_proposal_priority_score: u128, // Priority score of the proposal that caused eviction
}

/// Emitted when a proposal's fee is updated
public struct ProposalFeeUpdated has copy, drop {
    proposal_id: ID,
    proposer: address,
    old_fee: u64,
    new_fee: u64,
    new_priority_score: u128,
    timestamp: u64,
}

/// Emitted when a proposal is added to the queue
public struct ProposalQueued has copy, drop {
    proposal_id: ID,
    proposer: address,
    fee: u64,
    priority_score: u128,
    queue_position: u64,
}

/// Emitted when an evicted proposal has an associated intent spec that needs cleanup
public struct EvictedIntentNeedsCleanup has copy, drop {
    proposal_id: ID,
    has_intent_spec: bool,
    dao_id: ID,
    timestamp: u64,
}

// === Errors ===

const EQueueFullAndFeeTooLow: u64 = 0;
const EQueueEmpty: u64 = 2;
const EInvalidProposalId: u64 = 3;
const EProposalNotFound: u64 = 4;
const EInvalidBond: u64 = 5;
const EProposalInGracePeriod: u64 = 6;
const EHeapInvariantViolated: u64 = 7;
const EFeeExceedsMaximum: u64 = 8;
const EProposalNotTimedOut: u64 = 10;
const EBondNotExtracted: u64 = 12;
const ECrankBountyNotExtracted: u64 = 13;

// === Constants ===

const MAX_QUEUE_SIZE: u64 = 100;
const EVICTION_GRACE_PERIOD_MS: u64 = 300000; // 5 minutes
const MAX_TIME_AT_TOP_OF_QUEUE_MS: u64 = 86400000; // 24 hours
const COMPARE_GREATER: u8 = 1;
const COMPARE_EQUAL: u8 = 0;
const COMPARE_LESS: u8 = 2;
const MAX_REASONABLE_FEE: u64 = 1_000_000_000_000_000; // 1 million SUI (with 9 decimals)

// === Structs ===

/// Witness for queue mutations
/// Only authorized modules can create this to mutate proposals
public struct QueueMutationAuth has drop {}

/// Priority score combining fee and timestamp
public struct PriorityScore has copy, drop, store {
    fee: u64,
    timestamp: u64,
    computed_value: u128,
}

/// Proposal data stored in the queue
public struct ProposalData has copy, drop, store {
    title: String,
    metadata: String,
    outcome_messages: vector<String>,
    outcome_details: vector<String>,
}

/// Queued proposal with priority
public struct QueuedProposal<phantom StableCoin> has store {
    bond: Option<Coin<StableCoin>>,
    proposal_id: ID,
    dao_id: ID,
    proposer: address,
    fee: u64,
    timestamp: u64,
    priority_score: PriorityScore,
    intent_spec: Option<InitActionSpecs>,
    uses_dao_liquidity: bool,
    data: ProposalData,
    queue_entry_time: u64, // Track when proposal entered queue for grace period
    // === Policy Enforcement Fields (CRITICAL SECURITY) ===
    // Inline storage of policy requirements "locked in" at proposal creation time.
    // This ensures that if the DAO changes its policies via another proposal,
    // it won't brick execution of in-flight proposals created under the old policy.
    /// Policy mode: 0=DAO_ONLY, 1=COUNCIL_ONLY, 2=DAO_OR_COUNCIL, 3=DAO_AND_COUNCIL
    policy_mode: u8,
    /// Which council is required (if any)
    required_council_id: Option<ID>,
    /// Proof of council approval (ApprovedIntentSpec ID) if mode required it
    council_approval_proof: Option<ID>,
    /// Timestamp when proposal reached top of queue (for timeout mechanism)
    /// Set to Some(timestamp) when proposal becomes #1, None otherwise
    time_reached_top_of_queue: Option<u64>,
    /// Bounty for permissionless cranking (in SUI)
    /// Anyone can claim this by successfully cranking proposal to PREMARKET state
    crank_bounty: Option<Coin<SUI>>,
    /// Track if proposal used admin quota/budget (excludes from creator rewards)
    used_quota: bool,
}

/// Priority queue using binary heap for O(log n) operations
public struct ProposalQueue<phantom StableCoin> has key, store {
    id: UID,
    /// DAO ID this queue belongs to
    dao_id: ID,
    /// Binary heap of proposals - stored as vector but maintains heap property
    heap: vector<QueuedProposal<StableCoin>>,
    /// Index table for O(1) proposal lookup by ID
    proposal_indices: Table<ID, u64>,
    /// Current size of the heap
    size: u64,
    /// Whether a proposal is currently live (trading)
    is_proposal_live: bool,
    /// Maximum proposer-funded proposals in queue
    max_proposer_funded: u64,
    /// Grace period in milliseconds before a proposal can be evicted
    eviction_grace_period_ms: u64,
    /// Reserved next on-chain Proposal ID (if locked as the next one to go live)
    reserved_next_proposal: Option<ID>,
}

/// Information about an evicted proposal
public struct EvictionInfo has copy, drop, store {
    proposal_id: ID,
    proposer: address,
    used_quota: bool,
}

// === Heap Operations (Private) ===

/// Get parent index in heap (safe from underflow)
fun parent_idx(i: u64): u64 {
    // Already protected: returns 0 for i=0, otherwise (i-1)/2
    // The check prevents underflow when i=0
    if (i == 0) 0 else (i - 1) / 2
}

/// Get left child index (safe from overflow)
fun left_child_idx(i: u64): u64 {
    // Check for potential overflow: if i > (MAX_U64 - 1) / 2
    // For practical heap sizes this will never overflow, but add safety
    let max_safe = (18446744073709551615u64 - 1) / 2;
    if (i > max_safe) {
        // Return max value to indicate invalid child (will be >= size in checks)
        18446744073709551615u64
    } else {
        2 * i + 1
    }
}

/// Get right child index (safe from overflow)
fun right_child_idx(i: u64): u64 {
    // Check for potential overflow: if i > (MAX_U64 - 2) / 2
    // For practical heap sizes this will never overflow, but add safety
    let max_safe = (18446744073709551615u64 - 2) / 2;
    if (i > max_safe) {
        // Return max value to indicate invalid child (will be >= size in checks)
        18446744073709551615u64
    } else {
        2 * i + 2
    }
}

/// Bubble up element to maintain heap property - O(log n)
fun bubble_up<StableCoin>(
    heap: &mut vector<QueuedProposal<StableCoin>>,
    indices: &mut Table<ID, u64>,
    mut idx: u64,
) {
    // Safety: ensure idx is within bounds
    let heap_size = vector::length(heap);
    if (idx >= heap_size) return;

    while (idx > 0) {
        let parent = parent_idx(idx);

        // Safety: parent_idx guarantees parent < idx when idx > 0
        let child_priority = &vector::borrow(heap, idx).priority_score;
        let parent_priority = &vector::borrow(heap, parent).priority_score;

        // If child has higher priority, swap with parent
        if (compare_priority_scores(child_priority, parent_priority) == COMPARE_GREATER) {
            // Update indices before swapping
            let child_id = vector::borrow(heap, idx).proposal_id;
            let parent_id = vector::borrow(heap, parent).proposal_id;
            *indices.borrow_mut(child_id) = parent;
            *indices.borrow_mut(parent_id) = idx;

            vector::swap(heap, idx, parent);
            idx = parent;
        } else {
            break
        };
    }
}

/// Bubble down element to maintain heap property - O(log n)
fun bubble_down<StableCoin>(
    heap: &mut vector<QueuedProposal<StableCoin>>,
    indices: &mut Table<ID, u64>,
    mut idx: u64,
    size: u64,
) {
    // Safety: ensure parameters are valid
    if (size == 0 || idx >= size) return;

    loop {
        let left = left_child_idx(idx);
        let right = right_child_idx(idx);
        let mut largest = idx;

        // Compare with left child
        if (left < size) {
            let left_priority = &vector::borrow(heap, left).priority_score;
            let largest_priority = &vector::borrow(heap, largest).priority_score;
            if (compare_priority_scores(left_priority, largest_priority) == COMPARE_GREATER) {
                largest = left;
            };
        };

        // Compare with right child
        if (right < size) {
            let right_priority = &vector::borrow(heap, right).priority_score;
            let largest_priority = &vector::borrow(heap, largest).priority_score;
            if (compare_priority_scores(right_priority, largest_priority) == COMPARE_GREATER) {
                largest = right;
            };
        };

        // If current node is largest, we're done
        if (largest == idx) break;

        // Update indices before swapping
        let current_id = vector::borrow(heap, idx).proposal_id;
        let largest_id = vector::borrow(heap, largest).proposal_id;
        *indices.borrow_mut(current_id) = largest;
        *indices.borrow_mut(largest_id) = idx;

        // Otherwise swap and continue
        vector::swap(heap, idx, largest);
        idx = largest;
    }
}

/// Find minimum priority element in heap (it's in the leaves) - O(n/2)
/// Optimized to only check proposer-funded proposals
fun find_min_index<StableCoin>(heap: &vector<QueuedProposal<StableCoin>>, size: u64): u64 {
    if (size == 0) return 0;
    if (size == 1) return 0;

    // Minimum is in the second half of the array (leaves)
    // But we only care about proposer-funded proposals
    let start = size / 2;
    let mut min_idx = size; // Initialize to invalid index
    let mut min_priority: Option<PriorityScore> = option::none();

    // Only check leaves and filter for proposer-funded proposals
    let mut i = start;
    while (i < size) {
        let proposal = vector::borrow(heap, i);
        // Only consider proposer-funded proposals for eviction
        if (!proposal.uses_dao_liquidity) {
            if (option::is_none(&min_priority)) {
                min_priority = option::some(proposal.priority_score);
                min_idx = i;
            } else {
                let current_priority = &proposal.priority_score;
                if (
                    compare_priority_scores(current_priority, option::borrow(&min_priority)) == COMPARE_LESS
                ) {
                    min_priority = option::some(proposal.priority_score);
                    min_idx = i;
                };
            };
        };
        i = i + 1;
    };

    // If no proposer-funded proposal found in leaves, check the rest
    if (min_idx == size && start > 0) {
        let mut i = 0;
        while (i < start) {
            let proposal = vector::borrow(heap, i);
            if (!proposal.uses_dao_liquidity) {
                if (option::is_none(&min_priority)) {
                    min_priority = option::some(proposal.priority_score);
                    min_idx = i;
                } else {
                    let current_priority = &proposal.priority_score;
                    if (
                        compare_priority_scores(current_priority, option::borrow(&min_priority)) == COMPARE_LESS
                    ) {
                        min_priority = option::some(proposal.priority_score);
                        min_idx = i;
                    };
                };
            };
            i = i + 1;
        };
    };

    min_idx
}

/// Remove element at index and maintain heap property - O(log n)
fun remove_at<StableCoin>(
    heap: &mut vector<QueuedProposal<StableCoin>>,
    indices: &mut Table<ID, u64>,
    idx: u64,
    size: &mut u64,
): QueuedProposal<StableCoin> {
    // Safety: ensure valid index and non-empty heap
    assert!(*size > 0, EQueueEmpty);
    assert!(idx < *size, EInvalidProposalId);

    // Swap with last element (safe: size > 0 guaranteed)
    let last_idx = *size - 1;
    if (idx != last_idx) {
        // Update indices before swapping
        let current_id = vector::borrow(heap, idx).proposal_id;
        let last_id = vector::borrow(heap, last_idx).proposal_id;
        *indices.borrow_mut(last_id) = idx;

        vector::swap(heap, idx, last_idx);
    };

    // Remove the element
    let removed = vector::pop_back(heap);
    // Remove from index table
    indices.remove(removed.proposal_id);
    *size = *size - 1;

    // Reheapify if we didn't remove the last element
    if (idx < *size && *size > 0) {
        // Check if we need to bubble up or down
        if (idx > 0) {
            let parent = parent_idx(idx);
            let current_priority = &vector::borrow(heap, idx).priority_score;
            let parent_priority = &vector::borrow(heap, parent).priority_score;

            if (compare_priority_scores(current_priority, parent_priority) == COMPARE_GREATER) {
                bubble_up(heap, indices, idx);
            } else {
                bubble_down(heap, indices, idx, *size);
            };
        } else {
            bubble_down(heap, indices, idx, *size);
        };
    };

    removed
}

// === Public Functions ===

/// Create a new proposal queue with DAO ID
public fun new<StableCoin>(
    dao_id: ID,
    max_proposer_funded: u64,
    eviction_grace_period_ms: u64,
    ctx: &mut TxContext,
): ProposalQueue<StableCoin> {
    assert!(max_proposer_funded > 0, EInvalidProposalId);

    ProposalQueue {
        id: object::new(ctx),
        dao_id,
        heap: vector::empty(),
        proposal_indices: table::new(ctx),
        size: 0,
        is_proposal_live: false,
        max_proposer_funded,
        eviction_grace_period_ms,
        reserved_next_proposal: option::none(),
    }
}

/// Create a new proposal queue (backward compatibility)
public fun new_with_config<StableCoin>(
    dao_id: ID,
    max_proposer_funded: u64,
    _max_queue_size: u64, // Ignored - we use MAX_QUEUE_SIZE constant
    eviction_grace_period_ms: u64,
    ctx: &mut TxContext,
): ProposalQueue<StableCoin> {
    new(dao_id, max_proposer_funded, eviction_grace_period_ms, ctx)
}

/// Create priority score from fee and timestamp with validation
public fun create_priority_score(fee: u64, timestamp: u64): PriorityScore {
    // Validate fee is within reasonable bounds to prevent gaming
    assert!(fee <= MAX_REASONABLE_FEE, EFeeExceedsMaximum);

    // Higher fee = higher priority
    // Earlier timestamp = higher priority (for tie-breaking)
    // Invert timestamp for priority ordering (earlier = higher priority)
    let max_u64 = 18446744073709551615u64;
    // timestamp is already u64, so it cannot exceed max_u64
    // Safe subtraction - timestamp will always be <= max_u64
    let timestamp_inverted = max_u64 - timestamp;

    // Compute priority value: fee in upper 64 bits, inverted timestamp in lower 64 bits
    // This ensures fee is the primary factor, timestamp is the tiebreaker
    let computed_value = ((fee as u128) << 64) | (timestamp_inverted as u128);

    PriorityScore {
        fee,
        timestamp,
        computed_value,
    }
}

/// Compare two priority scores
public fun compare_priority_scores(a: &PriorityScore, b: &PriorityScore): u8 {
    if (a.computed_value > b.computed_value) {
        COMPARE_GREATER
    } else if (a.computed_value < b.computed_value) {
        COMPARE_LESS
    } else {
        COMPARE_EQUAL
    }
}

/// Insert a proposal into the queue - O(log n) complexity!
public fun insert<StableCoin>(
    queue: &mut ProposalQueue<StableCoin>,
    mut proposal: QueuedProposal<StableCoin>,
    clock: &Clock,
    ctx: &mut TxContext,
): Option<EvictionInfo> {
    // Validate fee is reasonable
    assert!(proposal.fee <= MAX_REASONABLE_FEE, EFeeExceedsMaximum);

    // Generate proposal ID if needed
    if (proposal.proposal_id == @0x0.to_id()) {
        let id = object::new(ctx);
        proposal.proposal_id = id.to_inner();
        id.delete();
    };
    let mut eviction_info = option::none<EvictionInfo>();
    let current_time = clock.timestamp_ms();

    // Set queue entry time for grace period tracking
    proposal.queue_entry_time = current_time;

    // Check capacity and eviction logic
    // Simple: if queue is at capacity, must evict lowest priority proposer-funded proposal
    let proposer_funded_count = count_proposer_funded(&queue.heap, queue.size);

    if (proposer_funded_count >= queue.max_proposer_funded) {
        // Find lowest priority proposer-funded proposal
        let lowest_idx = find_min_index(&queue.heap, queue.size);
        let lowest = vector::borrow(&queue.heap, lowest_idx);

        // Check grace period BEFORE removing (use queue entry time, not creation timestamp)
        assert!(
            current_time - lowest.queue_entry_time >= queue.eviction_grace_period_ms,
            EProposalInGracePeriod,
        );

        // New proposal must have higher priority to evict
        assert!(
            compare_priority_scores(&proposal.priority_score, &lowest.priority_score) == COMPARE_GREATER,
            EQueueFullAndFeeTooLow,
        );

        // Now safe to remove - assertions have passed
        let evicted = remove_at(
            &mut queue.heap,
            &mut queue.proposal_indices,
            lowest_idx,
            &mut queue.size,
        );

        // Save eviction info before destructuring
        let evicted_proposal_id = evicted.proposal_id;
        let evicted_proposer = evicted.proposer;
        let evicted_fee = evicted.fee;
        let evicted_timestamp = evicted.timestamp;
        let evicted_priority_value = evicted.priority_score.computed_value;
        let evicted_used_quota = evicted.used_quota;

        // Handle eviction
        eviction_info =
            option::some(EvictionInfo {
                proposal_id: evicted_proposal_id,
                proposer: evicted_proposer,
                used_quota: evicted_used_quota,
            });

        // Emit eviction event with both priority scores for transparency
        event::emit(ProposalEvicted {
            proposal_id: evicted_proposal_id,
            proposer: evicted_proposer,
            fee: evicted_fee,
            evicted_by: proposal.proposal_id,
            timestamp: evicted_timestamp,
            priority_score: evicted_priority_value,
            new_proposal_priority_score: proposal.priority_score.computed_value,
        });

        // Clean up evicted proposal
        let QueuedProposal {
            mut bond,
            proposal_id,
            dao_id,
            proposer: evicted_proposer_addr,
            fee: _,
            timestamp: _,
            priority_score: _,
            mut intent_spec,
            uses_dao_liquidity: _,
            data: _,
            queue_entry_time: _,
            policy_mode: _,
            required_council_id: _,
            council_approval_proof: _,
            time_reached_top_of_queue: _,
            mut crank_bounty,
            used_quota: _,
        } = evicted;

        if (intent_spec.is_some()) {
            let _ = intent_spec.extract();
            event::emit(EvictedIntentNeedsCleanup {
                proposal_id,
                has_intent_spec: true,
                dao_id,
                timestamp: current_time,
            });
        };

        // Handle bond properly - return to evicted proposer if it exists
        if (option::is_some(&bond)) {
            // Return the bond to the proposer who got evicted
            transfer::public_transfer(option::extract(&mut bond), evicted_proposer_addr);
        };
        option::destroy_none(bond);

        // Handle crank bounty - return to evicted proposer if it exists
        if (option::is_some(&crank_bounty)) {
            transfer::public_transfer(option::extract(&mut crank_bounty), evicted_proposer_addr);
        };
        option::destroy_none(crank_bounty);
    };

    // Save values before moving proposal
    let proposal_id = proposal.proposal_id;
    let proposer = proposal.proposer;
    let fee = proposal.fee;
    let priority_value = proposal.priority_score.computed_value;

    // Add to heap - O(1)
    vector::push_back(&mut queue.heap, proposal);
    let new_idx = queue.size;
    queue.size = queue.size + 1;

    // CRITICAL: Add to indices table BEFORE bubble_up
    // bubble_up uses borrow_mut which requires the key to exist
    queue.proposal_indices.add(proposal_id, new_idx);

    // Now bubble up can safely update indices - O(log n)!
    bubble_up(&mut queue.heap, &mut queue.proposal_indices, new_idx);

    // Emit queued event
    event::emit(ProposalQueued {
        proposal_id,
        proposer,
        fee,
        priority_score: priority_value,
        queue_position: queue.size - 1,
    });

    eviction_info
}

/// Extract the highest priority proposal - O(log n) complexity!
/// Requires QueueMutationAuth witness to prevent unauthorized extraction
public fun extract_max<StableCoin>(
    _auth: QueueMutationAuth, // ← Witness required
    queue: &mut ProposalQueue<StableCoin>,
): Option<QueuedProposal<StableCoin>> {
    if (queue.size == 0) {
        return option::none()
    };

    // Remove root (max element) - O(log n)!
    let max_proposal = remove_at(&mut queue.heap, &mut queue.proposal_indices, 0, &mut queue.size);
    option::some(max_proposal)
}

/// Peek at the highest priority proposal - O(1)
/// Returns the proposal ID if queue is not empty
public fun peek_max<StableCoin>(queue: &ProposalQueue<StableCoin>): Option<ID> {
    if (queue.size == 0) {
        option::none()
    } else {
        option::some(vector::borrow(&queue.heap, 0).proposal_id)
    }
}

/// Count proposer-funded proposals
fun count_proposer_funded<StableCoin>(heap: &vector<QueuedProposal<StableCoin>>, size: u64): u64 {
    let mut count = 0;
    let mut i = 0;
    while (i < size) {
        if (!vector::borrow(heap, i).uses_dao_liquidity) {
            count = count + 1;
        };
        i = i + 1;
    };
    count
}

// === Compatibility functions for ProposalData ===

// For compatibility, we need to return owned vectors since we don't store these fields
public fun get_initial_asset_amounts(_data: &ProposalData): vector<u64> {
    vector::empty<u64>() // Not used in new version, return empty for compatibility
}

public fun get_initial_stable_amounts(_data: &ProposalData): vector<u64> {
    vector::empty<u64>() // Not used in new version, return empty for compatibility
}

/// Get proposal data from a queued proposal
public fun get_proposal_data<StableCoin>(proposal: &QueuedProposal<StableCoin>): &ProposalData {
    &proposal.data
}

/// Check if proposal uses DAO liquidity
public fun uses_dao_liquidity<StableCoin>(proposal: &QueuedProposal<StableCoin>): bool {
    proposal.uses_dao_liquidity
}

/// Get the DAO ID associated with this queue
public fun dao_id<StableCoin>(queue: &ProposalQueue<StableCoin>): ID {
    queue.dao_id
}

/// Get the length of the queue
public fun length<StableCoin>(queue: &ProposalQueue<StableCoin>): u64 {
    queue.size
}

// === Additional Public Functions (maintaining compatibility) ===

/// Create a new queued proposal
public fun new_queued_proposal<StableCoin>(
    dao_id: ID,
    fee: u64,
    uses_dao_liquidity: bool,
    proposer: address,
    data: ProposalData,
    bond: Option<Coin<StableCoin>>,
    intent_spec: Option<InitActionSpecs>,
    policy_mode: u8,
    required_council_id: Option<ID>,
    council_approval_proof: Option<ID>,
    used_quota: bool,
    clock: &Clock,
): QueuedProposal<StableCoin> {
    let timestamp = clock.timestamp_ms();
    let priority_score = create_priority_score(fee, timestamp);

    QueuedProposal {
        bond,
        proposal_id: @0x0.to_id(), // Will be set during insert
        dao_id,
        proposer,
        fee,
        timestamp,
        priority_score,
        intent_spec,
        uses_dao_liquidity,
        data,
        queue_entry_time: 0, // Will be set during insert
        policy_mode,
        required_council_id,
        council_approval_proof,
        time_reached_top_of_queue: option::none(), // Not at top yet
        crank_bounty: option::none(), // No bounty by default
        used_quota,
    }
}

/// Create a new queued proposal with a specific ID
public fun new_queued_proposal_with_id<StableCoin>(
    proposal_id: ID,
    dao_id: ID,
    fee: u64,
    uses_dao_liquidity: bool,
    proposer: address,
    data: ProposalData,
    bond: Option<Coin<StableCoin>>,
    intent_spec: Option<InitActionSpecs>,
    policy_mode: u8,
    required_council_id: Option<ID>,
    council_approval_proof: Option<ID>,
    used_quota: bool,
    clock: &Clock,
): QueuedProposal<StableCoin> {
    let timestamp = clock.timestamp_ms();
    let priority_score = create_priority_score(fee, timestamp);

    QueuedProposal {
        bond,
        proposal_id,
        dao_id,
        proposer,
        fee,
        timestamp,
        priority_score,
        intent_spec,
        uses_dao_liquidity,
        data,
        queue_entry_time: 0, // Will be set during insert
        policy_mode,
        required_council_id,
        council_approval_proof,
        time_reached_top_of_queue: option::none(), // Not at top yet
        crank_bounty: option::none(), // No bounty by default
        used_quota,
    }
}

/// Create proposal data
public fun new_proposal_data(
    title: String,
    metadata: String,
    outcome_messages: vector<String>,
    outcome_details: vector<String>,
    _initial_asset_amounts: vector<u64>, // Ignored for compatibility
    _initial_stable_amounts: vector<u64>, // Ignored for compatibility
): ProposalData {
    ProposalData {
        title,
        metadata,
        outcome_messages,
        outcome_details,
    }
}

/// Get queue size
public fun size<StableCoin>(queue: &ProposalQueue<StableCoin>): u64 {
    queue.size
}

/// Check if queue is empty
public fun is_empty<StableCoin>(queue: &ProposalQueue<StableCoin>): bool {
    queue.size == 0
}

/// Get proposals vector (for compatibility)
public fun get_proposals<StableCoin>(
    queue: &ProposalQueue<StableCoin>,
): &vector<QueuedProposal<StableCoin>> {
    &queue.heap
}

// Getter functions for QueuedProposal
public fun get_proposal_id<StableCoin>(proposal: &QueuedProposal<StableCoin>): ID {
    proposal.proposal_id
}

public fun get_proposer<StableCoin>(proposal: &QueuedProposal<StableCoin>): address {
    proposal.proposer
}

public fun get_fee<StableCoin>(proposal: &QueuedProposal<StableCoin>): u64 { proposal.fee }

public fun get_timestamp<StableCoin>(proposal: &QueuedProposal<StableCoin>): u64 {
    proposal.timestamp
}

public fun get_priority_score<StableCoin>(proposal: &QueuedProposal<StableCoin>): &PriorityScore {
    &proposal.priority_score
}

public fun get_intent_spec<StableCoin>(
    proposal: &QueuedProposal<StableCoin>,
): &Option<InitActionSpecs> { &proposal.intent_spec }

public fun get_uses_dao_liquidity<StableCoin>(proposal: &QueuedProposal<StableCoin>): bool {
    proposal.uses_dao_liquidity
}

public fun get_data<StableCoin>(proposal: &QueuedProposal<StableCoin>): &ProposalData {
    &proposal.data
}

public fun get_dao_id<StableCoin>(proposal: &QueuedProposal<StableCoin>): ID { proposal.dao_id }

public fun get_policy_mode<StableCoin>(proposal: &QueuedProposal<StableCoin>): u8 {
    proposal.policy_mode
}

public fun get_required_council_id<StableCoin>(proposal: &QueuedProposal<StableCoin>): Option<ID> {
    proposal.required_council_id
}

public fun get_council_approval_proof<StableCoin>(
    proposal: &QueuedProposal<StableCoin>,
): Option<ID> { proposal.council_approval_proof }

public fun get_used_quota<StableCoin>(proposal: &QueuedProposal<StableCoin>): bool {
    proposal.used_quota
}

// Getter functions for EvictionInfo
public fun eviction_proposal_id(info: &EvictionInfo): ID { info.proposal_id }

public fun eviction_proposer(info: &EvictionInfo): address { info.proposer }

public fun eviction_used_quota(info: &EvictionInfo): bool { info.used_quota }

// Getter functions for ProposalData
public fun get_title(data: &ProposalData): &String { &data.title }

public fun get_metadata(data: &ProposalData): &String { &data.metadata }

public fun get_outcome_messages(data: &ProposalData): &vector<String> { &data.outcome_messages }

public fun get_outcome_details(data: &ProposalData): &vector<String> { &data.outcome_details }

// Getter functions for PriorityScore
public fun priority_score_value(score: &PriorityScore): u128 { score.computed_value }

/// Tries to activate the next proposal from the queue
/// Requires QueueMutationAuth witness to prevent unauthorized activation
public fun try_activate_next<StableCoin>(
    auth: QueueMutationAuth, // ← Witness required
    queue: &mut ProposalQueue<StableCoin>,
): Option<QueuedProposal<StableCoin>> {
    extract_max(auth, queue)
}

/// Calculate minimum required fee based on queue occupancy
///
/// The fee scaling regime works as follows:
/// - Below 50% occupancy: Base fee (1 unit)
/// - 50-75% occupancy: 2x base fee
/// - 75-90% occupancy: 5x base fee
/// - 90-100% occupancy: 10x base fee
/// - Above 100%: Clamped to 10x
///
/// Note: Occupancy is calculated relative to max_proposer_funded (the queue capacity).
public fun calculate_min_fee<StableCoin>(queue: &ProposalQueue<StableCoin>): u64 {
    let queue_size = queue.size;

    // Calculate occupancy ratio, clamped to 100% maximum
    // max_proposer_funded is guaranteed to be > 0 by constructor validation
    let raw_ratio = (queue_size * 100) / queue.max_proposer_funded;
    // Clamp to 100%
    let occupancy_ratio = if (raw_ratio > 100) { 100 } else { raw_ratio };

    // Base minimum fee
    let min_fee_base = 1_000_000; // 1 unit with 6 decimals

    // Escalate fee based on clamped queue occupancy
    if (occupancy_ratio >= 90) {
        min_fee_base * 10 // 10x when queue is 90%+ full
    } else if (occupancy_ratio >= 75) {
        min_fee_base * 5 // 5x when queue is 75-90% full
    } else if (occupancy_ratio >= 50) {
        min_fee_base * 2 // 2x when queue is 50-75% full
    } else {
        min_fee_base // 1x when queue is below 50% full
    }
}

/// Get proposals by a specific proposer
public fun get_proposals_by_proposer<StableCoin>(
    queue: &ProposalQueue<StableCoin>,
    proposer: address,
): vector<ID> {
    let mut result = vector::empty<ID>();
    let mut i = 0;

    while (i < queue.size) {
        let proposal = vector::borrow(&queue.heap, i);
        if (proposal.proposer == proposer) {
            vector::push_back(&mut result, proposal.proposal_id);
        };
        i = i + 1;
    };

    result
}

/// Check if a proposal with given fee would be accepted
public fun would_accept_proposal<StableCoin>(
    queue: &ProposalQueue<StableCoin>,
    fee: u64,
    _uses_dao_liquidity: bool, // Kept for compatibility but not used
    clock: &Clock,
): bool {
    // Check basic fee requirements
    let min_fee = calculate_min_fee(queue);
    if (fee < min_fee) {
        return false
    };

    // Check if we can add without eviction
    let proposer_funded_count = count_proposer_funded(&queue.heap, queue.size);
    if (proposer_funded_count < queue.max_proposer_funded) {
        return true // Room available
    };

    // Would need to evict - check if fee is high enough
    let min_idx = find_min_index(&queue.heap, queue.size);
    if (min_idx < queue.size) {
        let lowest = vector::borrow(&queue.heap, min_idx);
        let new_priority = create_priority_score(fee, clock.timestamp_ms());
        return compare_priority_scores(&new_priority, &lowest.priority_score) == COMPARE_GREATER
    };

    false
}

/// Slash and distribute fee according to DAO configuration
public fun slash_and_distribute_fee<StableCoin>(
    _queue: &ProposalQueue<StableCoin>,
    fee_manager: &mut ProposalFeeManager,
    proposal_id: ID,
    slasher: address,
    account: &Account<FutarchyConfig>,
    ctx: &mut TxContext,
): (Coin<SUI>, Coin<SUI>) {
    let config = account::config(account);
    let slash_config = futarchy_config::slash_distribution(config);

    // Use the fee manager to slash and distribute
    let (slasher_reward, dao_coin) = proposal_fee_manager::slash_proposal_fee_with_distribution(
        fee_manager,
        proposal_id,
        slash_config,
        ctx,
    );

    // Transfer slasher reward directly to the slasher
    if (coin::value(&slasher_reward) > 0) {
        transfer::public_transfer(slasher_reward, slasher);
    } else {
        coin::destroy_zero(slasher_reward);
    };

    // Return DAO treasury coin for the caller to handle
    (coin::zero(ctx), dao_coin)
}

/// Mark a proposal as active after extraction from queue
/// Sets is_proposal_live to true
/// Requires QueueMutationAuth witness to prevent unauthorized state changes
public fun mark_proposal_activated<StableCoin>(
    _auth: QueueMutationAuth, // ← Witness required
    queue: &mut ProposalQueue<StableCoin>,
    _uses_dao_liquidity: bool, // Kept for compatibility but not used
) {
    // Set the live flag
    queue.is_proposal_live = true;
}

/// Mark a proposal as completed, freeing up space with state consistency checks
/// Now requires proposal_id to ensure we're marking the correct proposal
public fun mark_proposal_completed<StableCoin>(
    queue: &mut ProposalQueue<StableCoin>,
    proposal_id: ID,
    _uses_dao_liquidity: bool, // Kept for compatibility but not used
) {
    // Validate preconditions: must have a live proposal
    assert!(queue.is_proposal_live, EInvalidProposalId);

    // Verify the proposal_id matches a reserved/active proposal if tracked
    // This ensures we're completing the right proposal
    if (option::is_some(&queue.reserved_next_proposal)) {
        let reserved_id = *option::borrow(&queue.reserved_next_proposal);
        if (reserved_id == proposal_id) {
            // Clear the reservation as it's being completed
            queue.reserved_next_proposal = option::none();
        }
    };

    // Clear the live flag
    queue.is_proposal_live = false;
}

/// Remove a specific proposal from the queue - O(log n) with index tracking
/// Made package-visible to prevent unauthorized removal
public fun remove_from_queue<StableCoin>(
    queue: &mut ProposalQueue<StableCoin>,
    proposal_id: ID,
): QueuedProposal<StableCoin> {
    // O(1) lookup of proposal index
    if (!queue.proposal_indices.contains(proposal_id)) {
        abort EProposalNotFound
    };

    let idx = *queue.proposal_indices.borrow(proposal_id);
    // O(log n) removal
    remove_at(&mut queue.heap, &mut queue.proposal_indices, idx, &mut queue.size)
}

/// Check if a proposal is currently live
public fun is_proposal_live<StableCoin>(queue: &ProposalQueue<StableCoin>): bool {
    queue.is_proposal_live
}

/// Get top N proposal IDs from the queue
public fun get_top_n_ids<StableCoin>(queue: &ProposalQueue<StableCoin>, n: u64): vector<ID> {
    let mut result = vector::empty<ID>();
    let limit = if (n < queue.size) { n } else { queue.size };
    let mut i = 0;

    // Note: The heap is not necessarily in sorted order except for the root
    // For true top-N, we'd need to extract and re-insert, but this gives
    // a reasonable approximation for display purposes
    while (i < limit) {
        let proposal = vector::borrow(&queue.heap, i);
        vector::push_back(&mut result, proposal.proposal_id);
        i = i + 1;
    };

    result
}

/// Update the maximum number of proposer-funded proposals
public fun update_max_proposer_funded<StableCoin>(
    queue: &mut ProposalQueue<StableCoin>,
    new_max: u64,
) {
    assert!(new_max > 0, EInvalidProposalId);
    queue.max_proposer_funded = new_max;
}


/// Cancel a proposal and refund the fee - secured to prevent theft
/// Now this is an entry function that transfers funds directly to the proposer
/// Added validation to ensure proposal is still in queue (not activated)
public entry fun cancel_proposal<StableCoin>(
    queue: &mut ProposalQueue<StableCoin>,
    fee_manager: &mut ProposalFeeManager,
    proposal_id: ID,
    ctx: &mut TxContext,
) {
    let mut i = 0;
    let mut found = false;

    // First, verify the proposal exists in the queue and belongs to the sender
    while (i < queue.size) {
        let proposal = vector::borrow(&queue.heap, i);
        if (proposal.proposal_id == proposal_id) {
            // Critical fix: Require that the transaction sender is the proposer
            assert!(proposal.proposer == tx_context::sender(ctx), EProposalNotFound);
            found = true;
            break
        };
        i = i + 1;
    };

    // If not found in queue, it means proposal is either:
    // 1. Already activated (cannot cancel)
    // 2. Never existed
    // Either way, abort with error
    assert!(found, EProposalNotFound);

    // Now we know the proposal is in queue and belongs to sender, safe to remove
    let proposal = vector::borrow(&queue.heap, i);
    let proposer_addr = proposal.proposer;

    let removed = remove_at(&mut queue.heap, &mut queue.proposal_indices, i, &mut queue.size);
    let QueuedProposal {
        proposal_id,
        mut bond,
        dao_id: _,
        proposer: _,
        fee: _,
        timestamp: _,
        priority_score: _,
        intent_spec: _,
        uses_dao_liquidity: _,
        data: _,
        queue_entry_time: _,
        policy_mode: _,
        required_council_id: _,
        council_approval_proof: _,
        time_reached_top_of_queue: _,
        mut crank_bounty,
        used_quota: _,
    } = removed;

    // Get the fee refunded as a Coin
    let refunded_fee = proposal_fee_manager::refund_proposal_fee(
        fee_manager,
        proposal_id,
        ctx,
    );

    // Critical fix: Transfer the refunded fee directly to the proposer
    transfer::public_transfer(refunded_fee, proposer_addr);

    // Critical fix: Transfer the bond directly to the proposer if it exists
    if (option::is_some(&bond)) {
        transfer::public_transfer(option::extract(&mut bond), proposer_addr);
    };
    option::destroy_none(bond);

    // Refund crank bounty to proposer if it exists
    if (option::is_some(&crank_bounty)) {
        transfer::public_transfer(option::extract(&mut crank_bounty), proposer_addr);
    };
    option::destroy_none(crank_bounty);
}

/// Update a proposal's priority by adding more fee
public fun update_proposal_fee<StableCoin>(
    queue: &mut ProposalQueue<StableCoin>,
    proposal_id: ID,
    additional_fee: u64,
    clock: &Clock,
    ctx: &TxContext,
) {
    assert!(additional_fee > 0, EProposalNotFound);

    let mut i = 0;
    while (i < queue.size) {
        let proposal = vector::borrow(&queue.heap, i);
        if (proposal.proposal_id == proposal_id) {
            assert!(proposal.proposer == ctx.sender(), EProposalNotFound);

            // Remove the proposal temporarily
            let mut removed = remove_at(
                &mut queue.heap,
                &mut queue.proposal_indices,
                i,
                &mut queue.size,
            );
            let old_fee = removed.fee;

            // Update fee and recalculate priority
            removed.fee = removed.fee + additional_fee;
            removed.priority_score = create_priority_score(removed.fee, clock.timestamp_ms());

            // Emit fee update event
            event::emit(ProposalFeeUpdated {
                proposal_id,
                proposer: removed.proposer,
                old_fee,
                new_fee: removed.fee,
                new_priority_score: removed.priority_score.computed_value,
                timestamp: clock.timestamp_ms(),
            });

            // Re-insert with new priority - O(log n)!
            vector::push_back(&mut queue.heap, removed);
            queue.size = queue.size + 1;
            bubble_up(&mut queue.heap, &mut queue.proposal_indices, queue.size - 1);

            return
        };
        i = i + 1;
    };

    abort EProposalNotFound
}

/// Get queue statistics
public fun get_stats<StableCoin>(queue: &ProposalQueue<StableCoin>): (u64, bool, u64) {
    (queue.size, queue.is_proposal_live, count_proposer_funded(&queue.heap, queue.size))
}

/// True if the queue already has a reserved next proposal
public fun has_reserved<StableCoin>(queue: &ProposalQueue<StableCoin>): bool {
    option::is_some(&queue.reserved_next_proposal)
}

/// Get reserved on-chain proposal ID (if any)
public fun reserved_proposal_id<StableCoin>(queue: &ProposalQueue<StableCoin>): Option<ID> {
    queue.reserved_next_proposal
}

/// Set the reserved next proposal
/// Requires QueueMutationAuth witness to prevent unauthorized reservation
public fun set_reserved<StableCoin>(
    _auth: QueueMutationAuth, // ← Witness required
    queue: &mut ProposalQueue<StableCoin>,
    id: ID,
) {
    assert!(!has_reserved(queue), EHeapInvariantViolated);
    queue.reserved_next_proposal = option::some(id);
}

/// Clear the reserved next proposal
/// Requires QueueMutationAuth witness to prevent unauthorized clearing
public fun clear_reserved<StableCoin>(
    _auth: QueueMutationAuth, // ← Witness required
    queue: &mut ProposalQueue<StableCoin>,
) {
    queue.reserved_next_proposal = option::none();
}

/// Check if a specific proposal can be activated
public fun can_activate_proposal<StableCoin>(
    queue: &ProposalQueue<StableCoin>,
    _proposal: &QueuedProposal<StableCoin>,
): bool {
    // Simple: only one proposal at a time!
    !queue.is_proposal_live
}

/// Get all proposals in the queue (for viewing)
public fun get_all_proposals<StableCoin>(
    queue: &ProposalQueue<StableCoin>,
): &vector<QueuedProposal<StableCoin>> {
    &queue.heap
}

/// Extract bond from a queued proposal (mutable)
/// Requires QueueMutationAuth witness to prevent unauthorized bond extraction
/// CRITICAL: This prevents value theft - only authorized modules can extract bonds
public fun extract_bond<StableCoin>(
    _auth: QueueMutationAuth, // ← Witness required
    proposal: &mut QueuedProposal<StableCoin>,
): Option<Coin<StableCoin>> {
    let bond_ref = &mut proposal.bond;
    if (option::is_some(bond_ref)) {
        option::some(option::extract(bond_ref))
    } else {
        option::none()
    }
}

/// Destroy a queued proposal
/// IMPORTANT: Caller must extract bond and crank_bounty BEFORE calling this
/// This ensures no value is lost - resources must be explicitly handled
public fun destroy_proposal<StableCoin>(proposal: QueuedProposal<StableCoin>) {
    let QueuedProposal {
        bond,
        proposal_id: _,
        dao_id: _,
        proposer: _,
        fee: _,
        timestamp: _,
        priority_score: _,
        intent_spec: _,
        uses_dao_liquidity: _,
        data: _,
        queue_entry_time: _,
        policy_mode: _,
        required_council_id: _,
        council_approval_proof: _,
        time_reached_top_of_queue: _,
        crank_bounty,
        used_quota: _,
    } = proposal;

    // SAFETY: Assert no valuable resources remain
    // Prevents accidental value loss - caller must handle coins explicitly
    assert!(bond.is_none(), EBondNotExtracted);
    assert!(crank_bounty.is_none(), ECrankBountyNotExtracted);

    // Safe to destroy now - no resources lost
    bond.destroy_none();
    crank_bounty.destroy_none();
}

/// Create queue mutation authority witness
/// Only package modules can create this witness for authorized mutations
public fun create_mutation_auth(): QueueMutationAuth {
    QueueMutationAuth {}
}

/// Set crank bounty for permissionless proposal execution
/// Bounty is paid to whoever successfully cranks proposal to PREMARKET
/// Note: Caller must handle any existing bounty before calling this
/// This function will abort if a bounty already exists
/// Requires QueueMutationAuth witness for access control
public fun set_crank_bounty<StableCoin>(
    _auth: QueueMutationAuth, // ← Witness required
    proposal: &mut QueuedProposal<StableCoin>,
    bounty: Coin<SUI>,
) {
    // SAFETY: Cannot overwrite existing bounty
    // Caller must extract old bounty first to prevent value loss
    assert!(option::is_none(&proposal.crank_bounty), ECrankBountyNotExtracted);

    // Safe to set new bounty
    option::fill(&mut proposal.crank_bounty, bounty);
}

/// Extract and claim crank bounty (called by cranker after successful execution)
public(package) fun extract_crank_bounty<StableCoin>(
    proposal: &mut QueuedProposal<StableCoin>,
    ctx: &mut TxContext,
) {
    if (option::is_some(&proposal.crank_bounty)) {
        let bounty = option::extract(&mut proposal.crank_bounty);
        transfer::public_transfer(bounty, tx_context::sender(ctx));
    };
}

/// Update time_reached_top_of_queue when proposal becomes #1
/// Called automatically when proposal reaches top of queue
public(package) fun mark_reached_top_of_queue<StableCoin>(
    proposal: &mut QueuedProposal<StableCoin>,
    clock: &Clock,
) {
    if (option::is_none(&proposal.time_reached_top_of_queue)) {
        proposal.time_reached_top_of_queue = option::some(clock::timestamp_ms(clock));
    };
}

/// Check if proposal has timed out at top of queue (24 hours)
/// Returns true if proposal should be evicted due to timeout
///
/// SAFETY: Uses saturating subtraction to handle clock adjustments
/// If clock goes backwards (NTP sync, testnet reset), treats as no time elapsed
public fun has_timed_out_at_top<StableCoin>(
    proposal: &QueuedProposal<StableCoin>,
    clock: &Clock,
): bool {
    if (option::is_none(&proposal.time_reached_top_of_queue)) {
        return false // Not at top yet
    };

    let time_at_top = *option::borrow(&proposal.time_reached_top_of_queue);
    let current_time = clock::timestamp_ms(clock);

    // CRITICAL: Saturating subtraction prevents underflow
    // If clock went backwards, elapsed = 0 (no timeout)
    let elapsed = if (current_time >= time_at_top) {
        current_time - time_at_top
    } else {
        0 // Clock went backwards, treat as no time elapsed
    };

    elapsed >= MAX_TIME_AT_TOP_OF_QUEUE_MS
}

/// Evict timed-out proposal from top of queue
/// Anyone can call this to clean up stuck proposals
public entry fun evict_timed_out_proposal<StableCoin>(
    queue: &mut ProposalQueue<StableCoin>,
    proposal_id: ID,
    clock: &Clock,
) {
    assert!(queue.proposal_indices.contains(proposal_id), EProposalNotFound);

    let idx = *queue.proposal_indices.borrow(proposal_id);
    assert!(idx == 0, EInvalidProposalId); // Must be at top of queue (index 0 in max-heap)

    let proposal = vector::borrow(&queue.heap, idx);
    assert!(has_timed_out_at_top(proposal, clock), EProposalNotTimedOut);

    // Get proposer address before removing
    let proposer_addr = proposal.proposer;

    // Remove the proposal from queue
    let mut removed = remove_at(&mut queue.heap, &mut queue.proposal_indices, idx, &mut queue.size);

    // Extract and return valuable resources to proposer
    if (option::is_some(&removed.bond)) {
        let bond = option::extract(&mut removed.bond);
        transfer::public_transfer(bond, proposer_addr);
    };

    if (option::is_some(&removed.crank_bounty)) {
        let bounty = option::extract(&mut removed.crank_bounty);
        transfer::public_transfer(bounty, proposer_addr);
    };

    // Now safe to destroy (no resources left)
    destroy_proposal(removed);

    // Clear reserved slot if this was the reserved proposal
    if (option::is_some(&queue.reserved_next_proposal)) {
        if (*option::borrow(&queue.reserved_next_proposal) == proposal_id) {
            queue.reserved_next_proposal = option::none();
        };
    };
}

// === Share Functions ===

/// Share the proposal queue - can only be called by this module
/// Used during DAO initialization after setup is complete
public fun share_queue<StableCoin>(queue: ProposalQueue<StableCoin>) {
    transfer::share_object(queue);
}

// === Test Functions ===

#[test_only]
public fun test_internals<StableCoin>(queue: &ProposalQueue<StableCoin>): (u64, bool) {
    (queue.max_proposer_funded, queue.is_proposal_live)
}

#[test_only]
/// Create a test queued proposal with minimal required fields
/// Other fields are set to sensible defaults for testing
public fun new_test_queued_proposal<StableCoin>(
    dao_id: ID,
    proposer: address,
    fee: u64,
    title: String,
    clock: &Clock,
): QueuedProposal<StableCoin> {
    use std::string;

    let timestamp = clock.timestamp_ms();
    let priority_score = create_priority_score(fee, timestamp);

    QueuedProposal {
        bond: option::none(),
        proposal_id: @0x0.to_id(), // Will be set during insert
        dao_id,
        proposer,
        fee,
        timestamp,
        priority_score,
        intent_spec: option::none(),
        uses_dao_liquidity: false,
        data: ProposalData {
            title,
            metadata: string::utf8(b""),
            outcome_messages: vector::empty(),
            outcome_details: vector::empty(),
        },
        queue_entry_time: 0,
        policy_mode: 0, // MODE_DAO_ONLY
        required_council_id: option::none(),
        council_approval_proof: option::none(),
        time_reached_top_of_queue: option::none(),
        crank_bounty: option::none(),
        used_quota: false,
    }
}

#[test_only]
/// Destroy a queued proposal for testing, handling any resources
/// Unlike the production destroy_proposal, this extracts and destroys resources automatically
public fun destroy_for_testing<StableCoin>(proposal: QueuedProposal<StableCoin>) {
    let QueuedProposal {
        mut bond,
        proposal_id: _,
        dao_id: _,
        proposer: _,
        fee: _,
        timestamp: _,
        priority_score: _,
        intent_spec: _,
        uses_dao_liquidity: _,
        data: _,
        queue_entry_time: _,
        policy_mode: _,
        required_council_id: _,
        council_approval_proof: _,
        time_reached_top_of_queue: _,
        mut crank_bounty,
        used_quota: _,
    } = proposal;

    // Extract and destroy any resources
    if (option::is_some(&bond)) {
        let coin = option::extract(&mut bond);
        sui::test_utils::destroy(coin);
    };
    option::destroy_none(bond);

    if (option::is_some(&crank_bounty)) {
        let coin = option::extract(&mut crank_bounty);
        sui::test_utils::destroy(coin);
    };
    option::destroy_none(crank_bounty);
}

#[test_only]
/// Destroy a queue for testing, handling any remaining proposals
public fun destroy_queue_for_testing<StableCoin>(queue: ProposalQueue<StableCoin>) {
    let ProposalQueue {
        id,
        dao_id: _,
        mut heap,
        proposal_indices,
        size: _,
        is_proposal_live: _,
        max_proposer_funded: _,
        eviction_grace_period_ms: _,
        reserved_next_proposal: _,
    } = queue;

    // Destroy all remaining proposals
    while (!vector::is_empty(&heap)) {
        let proposal = vector::pop_back(&mut heap);
        destroy_for_testing(proposal);
    };
    vector::destroy_empty(heap);

    // Clean up table and UID
    table::drop(proposal_indices);
    object::delete(id);
}
