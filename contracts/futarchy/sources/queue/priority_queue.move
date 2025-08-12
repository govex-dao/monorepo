/// Priority Queue Implementation Using Binary Heap
/// Provides O(log n) insertion and extraction for scalable gas costs
module futarchy::priority_queue;

use std::string::String;
use std::u64;
use std::u128;
use std::vector;
use std::option::{Self, Option};
use sui::clock::{Self, Clock};
use sui::coin::{Self, Coin};
use sui::sui::SUI;
use sui::object::{Self, ID, UID};
use sui::tx_context::{Self, TxContext};
use sui::event;
use sui::transfer;

use futarchy::futarchy_config::{Self, FutarchyConfig, SlashDistribution};
use futarchy::proposal_fee_manager::{Self, ProposalFeeManager};
use account_protocol::account::{Self, Account};

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

/// Emitted when an evicted proposal has an associated intent that needs cleanup
public struct EvictedIntentNeedsCleanup has copy, drop {
    proposal_id: ID,
    intent_key: String,
    dao_id: ID,
    timestamp: u64,
}

// === Errors ===

const EQueueFullAndFeeTooLow: u64 = 0;
const EDaoSlotOccupied: u64 = 1;
const EQueueEmpty: u64 = 2;
const EInvalidProposalId: u64 = 3;
const EProposalNotFound: u64 = 4;
const EInvalidBond: u64 = 5;
const EProposalInGracePeriod: u64 = 6;
const EHeapInvariantViolated: u64 = 7;

// === Constants ===

const MAX_QUEUE_SIZE: u64 = 100;
const EVICTION_GRACE_PERIOD_MS: u64 = 300000; // 5 minutes
const COMPARE_GREATER: u8 = 1;
const COMPARE_EQUAL: u8 = 0;
const COMPARE_LESS: u8 = 2;

// === Structs ===

/// Priority score combining fee and timestamp
public struct PriorityScore has store, copy, drop {
    fee: u64,
    timestamp: u64,
    computed_value: u128,
}

/// Proposal data stored in the queue
public struct ProposalData has store, copy, drop {
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
    intent_key: Option<String>,
    uses_dao_liquidity: bool,
    data: ProposalData,
}

/// Priority queue using binary heap for O(log n) operations
public struct ProposalQueue<phantom StableCoin> has key, store {
    id: UID,
    /// DAO ID this queue belongs to
    dao_id: ID,
    /// Binary heap of proposals - stored as vector but maintains heap property
    heap: vector<QueuedProposal<StableCoin>>,
    /// Current size of the heap
    size: u64,
    /// Maximum concurrent proposals allowed
    max_concurrent_proposals: u64,
    /// Current number of active proposals
    active_proposal_count: u64,
    /// Maximum proposer-funded proposals
    max_proposer_funded: u64,
    /// Whether the DAO liquidity slot is occupied
    dao_liquidity_slot_occupied: bool,
    /// Grace period in milliseconds before a proposal can be evicted
    eviction_grace_period_ms: u64,
    /// Reserved next on-chain Proposal ID (if locked as the next one to go live)
    reserved_next_proposal: Option<ID>,
}

/// Information about an evicted proposal
public struct EvictionInfo has copy, drop, store {
    proposal_id: ID,
    proposer: address,
}

// === Heap Operations (Private) ===

/// Get parent index in heap
fun parent_idx(i: u64): u64 {
    if (i == 0) 0 else (i - 1) / 2
}

/// Get left child index
fun left_child_idx(i: u64): u64 {
    2 * i + 1
}

/// Get right child index
fun right_child_idx(i: u64): u64 {
    2 * i + 2
}

/// Bubble up element to maintain heap property - O(log n)
fun bubble_up<StableCoin>(heap: &mut vector<QueuedProposal<StableCoin>>, mut idx: u64) {
    while (idx > 0) {
        let parent = parent_idx(idx);
        
        let child_priority = &vector::borrow(heap, idx).priority_score;
        let parent_priority = &vector::borrow(heap, parent).priority_score;
        
        // If child has higher priority, swap with parent
        if (compare_priority_scores(child_priority, parent_priority) == COMPARE_GREATER) {
            vector::swap(heap, idx, parent);
            idx = parent;
        } else {
            break
        };
    }
}

/// Bubble down element to maintain heap property - O(log n)
fun bubble_down<StableCoin>(heap: &mut vector<QueuedProposal<StableCoin>>, mut idx: u64, size: u64) {
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
        
        // Otherwise swap and continue
        vector::swap(heap, idx, largest);
        idx = largest;
    }
}

/// Find minimum priority element in heap (it's in the leaves) - O(n/2)
fun find_min_index<StableCoin>(heap: &vector<QueuedProposal<StableCoin>>, size: u64): u64 {
    if (size == 0) return 0;
    if (size == 1) return 0;
    
    // Minimum is in the second half of the array (leaves)
    let start = size / 2;
    let mut min_idx = start;
    let mut min_priority = &vector::borrow(heap, start).priority_score;
    
    let mut i = start + 1;
    while (i < size) {
        let current_priority = &vector::borrow(heap, i).priority_score;
        if (compare_priority_scores(current_priority, min_priority) == COMPARE_LESS) {
            min_priority = current_priority;
            min_idx = i;
        };
        i = i + 1;
    };
    
    min_idx
}

/// Remove element at index and maintain heap property - O(log n)
fun remove_at<StableCoin>(heap: &mut vector<QueuedProposal<StableCoin>>, idx: u64, size: &mut u64): QueuedProposal<StableCoin> {
    assert!(idx < *size, EInvalidProposalId);
    
    // Swap with last element
    let last_idx = *size - 1;
    if (idx != last_idx) {
        vector::swap(heap, idx, last_idx);
    };
    
    // Remove the element
    let removed = vector::pop_back(heap);
    *size = *size - 1;
    
    // Reheapify if we didn't remove the last element
    if (idx < *size && *size > 0) {
        // Check if we need to bubble up or down
        if (idx > 0) {
            let parent = parent_idx(idx);
            let current_priority = &vector::borrow(heap, idx).priority_score;
            let parent_priority = &vector::borrow(heap, parent).priority_score;
            
            if (compare_priority_scores(current_priority, parent_priority) == COMPARE_GREATER) {
                bubble_up(heap, idx);
            } else {
                bubble_down(heap, idx, *size);
            };
        } else {
            bubble_down(heap, idx, *size);
        };
    };
    
    removed
}

// === Public Functions ===

/// Create a new proposal queue with DAO ID
public fun new<StableCoin>(
    dao_id: ID,
    max_concurrent_proposals: u64,
    max_proposer_funded: u64,
    eviction_grace_period_ms: u64,
    ctx: &mut TxContext,
): ProposalQueue<StableCoin> {
    ProposalQueue {
        id: object::new(ctx),
        dao_id,
        heap: vector::empty(),
        size: 0,
        max_concurrent_proposals,
        active_proposal_count: 0,
        max_proposer_funded,
        dao_liquidity_slot_occupied: false,
        eviction_grace_period_ms,
        reserved_next_proposal: option::none(),
    }
}

/// Create a new proposal queue (backward compatibility)
public fun new_with_config<StableCoin>(
    dao_id: ID,
    max_proposer_funded: u64,
    max_concurrent_proposals: u64,
    _max_queue_size: u64,  // Ignored - we use MAX_QUEUE_SIZE constant
    eviction_grace_period_ms: u64,
    ctx: &mut TxContext,
): ProposalQueue<StableCoin> {
    new(dao_id, max_concurrent_proposals, max_proposer_funded, eviction_grace_period_ms, ctx)
}

/// Create priority score from fee and timestamp
public fun create_priority_score(fee: u64, timestamp: u64): PriorityScore {
    // Higher fee = higher priority
    // Earlier timestamp = higher priority (for tie-breaking)
    let computed_value = ((fee as u128) << 64) | ((18446744073709551615u64 - timestamp) as u128);
    
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
    // Generate proposal ID if needed
    if (proposal.proposal_id == @0x0.to_id()) {
        let id = object::new(ctx);
        proposal.proposal_id = id.to_inner();
        id.delete();
    };
    let mut eviction_info = option::none<EvictionInfo>();
    let current_time = clock::timestamp_ms(clock);
    
    // Check capacity and eviction logic
    if (proposal.uses_dao_liquidity) {
        if (queue.dao_liquidity_slot_occupied && 
            queue.active_proposal_count >= queue.max_concurrent_proposals) {
            abort EDaoSlotOccupied
        };
    } else {
        // Count proposer-funded proposals
        let proposer_funded_count = count_proposer_funded(&queue.heap, queue.size);
        
        if (proposer_funded_count >= queue.max_proposer_funded) {
            // Find lowest priority proposer-funded proposal
            let lowest_idx = find_min_index(&queue.heap, queue.size);
            let lowest = vector::borrow(&queue.heap, lowest_idx);
            
            // Check grace period BEFORE removing
            assert!(
                current_time - lowest.timestamp >= queue.eviction_grace_period_ms,
                EProposalInGracePeriod
            );
            
            // New proposal must have higher priority to evict
            assert!(
                compare_priority_scores(&proposal.priority_score, &lowest.priority_score) == COMPARE_GREATER,
                EQueueFullAndFeeTooLow
            );
            
            // Now safe to remove - assertions have passed
            let evicted = remove_at(&mut queue.heap, lowest_idx, &mut queue.size);
            
            // Save eviction info before destructuring
            let evicted_proposal_id = evicted.proposal_id;
            let evicted_proposer = evicted.proposer;
            let evicted_fee = evicted.fee;
            let evicted_timestamp = evicted.timestamp;
            let evicted_priority_value = evicted.priority_score.computed_value;
            
            // Handle eviction
            eviction_info = option::some(EvictionInfo {
                proposal_id: evicted_proposal_id,
                proposer: evicted_proposer,
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
            let QueuedProposal { mut bond, proposal_id, dao_id, proposer: evicted_proposer_addr, fee: _, timestamp: _, priority_score: _, mut intent_key, uses_dao_liquidity: _, data: _ } = evicted;
            
            if (intent_key.is_some()) {
                let key = intent_key.extract();
                event::emit(EvictedIntentNeedsCleanup {
                    proposal_id,
                    intent_key: key,
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
        };
    };
    
    // Save values before moving proposal
    let proposal_id = proposal.proposal_id;
    let proposer = proposal.proposer;
    let fee = proposal.fee;
    let priority_value = proposal.priority_score.computed_value;
    
    // Add to heap and bubble up - O(log n)!
    vector::push_back(&mut queue.heap, proposal);
    queue.size = queue.size + 1;
    bubble_up(&mut queue.heap, queue.size - 1);
    
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
/// Made package-visible to prevent unauthorized extraction
public(package) fun extract_max<StableCoin>(queue: &mut ProposalQueue<StableCoin>): Option<QueuedProposal<StableCoin>> {
    if (queue.size == 0) {
        return option::none()
    };
    
    // Remove root (max element) - O(log n)!
    let max_proposal = remove_at(&mut queue.heap, 0, &mut queue.size);
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
    vector::empty<u64>()  // Not used in new version, return empty for compatibility
}

public fun get_initial_stable_amounts(_data: &ProposalData): vector<u64> {
    vector::empty<u64>()  // Not used in new version, return empty for compatibility
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
    intent_key: Option<String>,
    clock: &Clock,
): QueuedProposal<StableCoin> {
    let timestamp = clock::timestamp_ms(clock);
    let priority_score = create_priority_score(fee, timestamp);
    
    QueuedProposal {
        bond,
        proposal_id: @0x0.to_id(),  // Will be set during insert
        dao_id,
        proposer,
        fee,
        timestamp,
        priority_score,
        intent_key,
        uses_dao_liquidity,
        data,
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
    intent_key: Option<String>,
    clock: &Clock,
): QueuedProposal<StableCoin> {
    let timestamp = clock::timestamp_ms(clock);
    let priority_score = create_priority_score(fee, timestamp);
    
    QueuedProposal {
        bond,
        proposal_id,
        dao_id,
        proposer,
        fee,
        timestamp,
        priority_score,
        intent_key,
        uses_dao_liquidity,
        data,
    }
}

/// Create proposal data
public fun new_proposal_data(
    title: String,
    metadata: String,
    outcome_messages: vector<String>,
    outcome_details: vector<String>,
    _initial_asset_amounts: vector<u64>,  // Ignored for compatibility
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
public fun get_proposals<StableCoin>(queue: &ProposalQueue<StableCoin>): &vector<QueuedProposal<StableCoin>> {
    &queue.heap
}

// Getter functions for QueuedProposal
public fun get_proposal_id<StableCoin>(proposal: &QueuedProposal<StableCoin>): ID { proposal.proposal_id }
public fun get_proposer<StableCoin>(proposal: &QueuedProposal<StableCoin>): address { proposal.proposer }
public fun get_fee<StableCoin>(proposal: &QueuedProposal<StableCoin>): u64 { proposal.fee }
public fun get_timestamp<StableCoin>(proposal: &QueuedProposal<StableCoin>): u64 { proposal.timestamp }
public fun get_priority_score<StableCoin>(proposal: &QueuedProposal<StableCoin>): &PriorityScore { &proposal.priority_score }
public fun get_intent_key<StableCoin>(proposal: &QueuedProposal<StableCoin>): &Option<String> { &proposal.intent_key }
public fun get_uses_dao_liquidity<StableCoin>(proposal: &QueuedProposal<StableCoin>): bool { proposal.uses_dao_liquidity }
public fun get_data<StableCoin>(proposal: &QueuedProposal<StableCoin>): &ProposalData { &proposal.data }
public fun get_dao_id<StableCoin>(proposal: &QueuedProposal<StableCoin>): ID { proposal.dao_id }

// Getter functions for EvictionInfo
public fun eviction_proposal_id(info: &EvictionInfo): ID { info.proposal_id }
public fun eviction_proposer(info: &EvictionInfo): address { info.proposer }

// Getter functions for ProposalData
public fun get_title(data: &ProposalData): &String { &data.title }
public fun get_metadata(data: &ProposalData): &String { &data.metadata }
public fun get_outcome_messages(data: &ProposalData): &vector<String> { &data.outcome_messages }
public fun get_outcome_details(data: &ProposalData): &vector<String> { &data.outcome_details }

// Getter functions for PriorityScore
public fun priority_score_value(score: &PriorityScore): u128 { score.computed_value }

/// Tries to activate the next proposal from the queue
/// Made package-visible to prevent unauthorized activation
public(package) fun try_activate_next<StableCoin>(queue: &mut ProposalQueue<StableCoin>): Option<QueuedProposal<StableCoin>> {
    extract_max(queue)
}

/// Calculate minimum required fee based on queue occupancy
/// 
/// The fee scaling regime works as follows:
/// - Below 50% occupancy: Base fee (1 unit)
/// - 50-75% occupancy: 2x base fee
/// - 75-90% occupancy: 5x base fee
/// - 90-100% occupancy: 10x base fee
/// - Above 100%: Clamped to 10x (queue can exceed max_concurrent_proposals in pending state)
/// 
/// Note: The queue can have more proposals than max_concurrent_proposals since that limit
/// only applies to ACTIVE proposals. The queue size can grow larger with pending proposals.
public fun calculate_min_fee<StableCoin>(queue: &ProposalQueue<StableCoin>): u64 {
    let queue_size = queue.size;
    
    // Calculate occupancy ratio, clamped to 100% maximum
    // This ensures we don't overflow and provides predictable fee scaling
    let occupancy_ratio = if (queue.max_concurrent_proposals == 0) {
        100 // If max is 0 (edge case), treat as full
    } else {
        let raw_ratio = (queue_size * 100) / queue.max_concurrent_proposals;
        // Clamp to 100% - queue can exceed max_concurrent but fee stops scaling at 100%
        if (raw_ratio > 100) { 100 } else { raw_ratio }
    };
    
    // Base minimum fee
    let min_fee_base = 1_000_000; // 1 unit with 6 decimals
    
    // Escalate fee based on clamped queue occupancy
    if (occupancy_ratio >= 90) {
        min_fee_base * 10  // 10x when queue is 90%+ full
    } else if (occupancy_ratio >= 75) {
        min_fee_base * 5   // 5x when queue is 75-90% full
    } else if (occupancy_ratio >= 50) {
        min_fee_base * 2   // 2x when queue is 50-75% full
    } else {
        min_fee_base       // 1x when queue is below 50% full
    }
}

/// Get proposals by a specific proposer
public fun get_proposals_by_proposer<StableCoin>(
    queue: &ProposalQueue<StableCoin>,
    proposer: address
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
    uses_dao_liquidity: bool,
    clock: &Clock
): bool {
    // Check basic fee requirements
    let min_fee = calculate_min_fee(queue);
    if (fee < min_fee) {
        return false
    };
    
    // Check capacity
    if (uses_dao_liquidity) {
        if (queue.dao_liquidity_slot_occupied && 
            queue.active_proposal_count >= queue.max_concurrent_proposals) {
            return false
        };
    } else {
        let proposer_funded_count = count_proposer_funded(&queue.heap, queue.size);
        if (proposer_funded_count >= queue.max_proposer_funded) {
            // Would need to evict - check if fee is high enough
            let min_idx = find_min_index(&queue.heap, queue.size);
            if (min_idx < queue.size) {
                let lowest = vector::borrow(&queue.heap, min_idx);
                let new_priority = create_priority_score(fee, clock::timestamp_ms(clock));
                return compare_priority_scores(&new_priority, &lowest.priority_score) == COMPARE_GREATER
            };
        };
    };
    
    true
}

/// Slash and distribute fee according to DAO configuration
public fun slash_and_distribute_fee<StableCoin>(
    _queue: &ProposalQueue<StableCoin>,
    fee_manager: &mut ProposalFeeManager,
    proposal_id: ID,
    slasher: address,
    account: &Account<FutarchyConfig>,
    ctx: &mut TxContext
): (Coin<SUI>, Coin<SUI>) {
    let config = account::config(account);
    let slash_config = futarchy_config::slash_distribution(config);
    
    // Use the fee manager to slash and distribute
    let (slasher_reward, dao_coin) = proposal_fee_manager::slash_proposal_fee_with_distribution(
        fee_manager,
        proposal_id,
        slash_config,
        ctx
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

/// Mark a proposal as completed, freeing up space
public fun mark_proposal_completed<StableCoin>(
    queue: &mut ProposalQueue<StableCoin>,
    uses_dao_liquidity: bool
) {
    assert!(queue.active_proposal_count > 0, EInvalidProposalId);
    
    queue.active_proposal_count = queue.active_proposal_count - 1;
    
    if (uses_dao_liquidity) {
        assert!(queue.dao_liquidity_slot_occupied, EInvalidProposalId);
        queue.dao_liquidity_slot_occupied = false;
    };
}

/// Remove a specific proposal from the queue
/// Made package-visible to prevent unauthorized removal
public(package) fun remove_from_queue<StableCoin>(
    queue: &mut ProposalQueue<StableCoin>,
    proposal_id: ID
): QueuedProposal<StableCoin> {
    let mut i = 0;
    
    while (i < queue.size) {
        let proposal = vector::borrow(&queue.heap, i);
        if (proposal.proposal_id == proposal_id) {
            // Found it - remove using our heap function
            return remove_at(&mut queue.heap, i, &mut queue.size)
        };
        i = i + 1;
    };
    
    abort EProposalNotFound
}

/// Get the number of active proposals
public fun active_count<StableCoin>(queue: &ProposalQueue<StableCoin>): u64 {
    queue.active_proposal_count
}

/// Check if the DAO liquidity slot is occupied
public fun is_dao_slot_occupied<StableCoin>(queue: &ProposalQueue<StableCoin>): bool {
    queue.dao_liquidity_slot_occupied
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
public(package) fun update_max_proposer_funded<StableCoin>(
    queue: &mut ProposalQueue<StableCoin>,
    new_max: u64
) {
    assert!(new_max > 0, EInvalidProposalId);
    queue.max_proposer_funded = new_max;
}

/// Update the maximum concurrent proposals allowed
public(package) fun update_max_concurrent_proposals<StableCoin>(
    queue: &mut ProposalQueue<StableCoin>,
    new_max: u64
) {
    assert!(new_max > 0, EInvalidProposalId);
    queue.max_concurrent_proposals = new_max;
}

/// Cancel a proposal and refund the fee - secured to prevent theft
/// Now this is an entry function that transfers funds directly to the proposer
public entry fun cancel_proposal<StableCoin>(
    queue: &mut ProposalQueue<StableCoin>,
    fee_manager: &mut ProposalFeeManager,
    proposal_id: ID,
    ctx: &mut TxContext
) {
    let mut i = 0;
    
    while (i < queue.size) {
        let proposal = vector::borrow(&queue.heap, i);
        if (proposal.proposal_id == proposal_id) {
            // Critical fix: Require that the transaction sender is the proposer
            assert!(proposal.proposer == tx_context::sender(ctx), EProposalNotFound);
            
            // Store proposer address before removing
            let proposer_addr = proposal.proposer;
            
            let removed = remove_at(&mut queue.heap, i, &mut queue.size);
            let QueuedProposal { proposal_id, mut bond, .. } = removed;
            
            // Get the fee refunded as a Coin
            let refunded_fee = proposal_fee_manager::refund_proposal_fee(
                fee_manager,
                proposal_id,
                ctx
            );
            
            // Critical fix: Transfer the refunded fee directly to the proposer
            transfer::public_transfer(refunded_fee, proposer_addr);
            
            // Critical fix: Transfer the bond directly to the proposer if it exists
            if (option::is_some(&bond)) {
                transfer::public_transfer(option::extract(&mut bond), proposer_addr);
            };
            option::destroy_none(bond);
            
            return
        };
        i = i + 1;
    };
    
    abort EProposalNotFound
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
            let mut removed = remove_at(&mut queue.heap, i, &mut queue.size);
            let old_fee = removed.fee;
            
            // Update fee and recalculate priority
            removed.fee = removed.fee + additional_fee;
            removed.priority_score = create_priority_score(removed.fee, clock::timestamp_ms(clock));
            
            // Emit fee update event
            event::emit(ProposalFeeUpdated {
                proposal_id,
                proposer: removed.proposer,
                old_fee,
                new_fee: removed.fee,
                new_priority_score: removed.priority_score.computed_value,
                timestamp: clock::timestamp_ms(clock),
            });
            
            // Re-insert with new priority - O(log n)!
            vector::push_back(&mut queue.heap, removed);
            queue.size = queue.size + 1;
            bubble_up(&mut queue.heap, queue.size - 1);
            
            return
        };
        i = i + 1;
    };
    
    abort EProposalNotFound
}

/// Get queue statistics
public fun get_stats<StableCoin>(queue: &ProposalQueue<StableCoin>): (u64, u64, u64, bool) {
    (
        queue.size,
        queue.active_proposal_count,
        count_proposer_funded(&queue.heap, queue.size),
        queue.dao_liquidity_slot_occupied
    )
}

/// True if the queue already has a reserved next proposal
public fun has_reserved<StableCoin>(queue: &ProposalQueue<StableCoin>): bool {
    option::is_some(&queue.reserved_next_proposal)
}

/// Get reserved on-chain proposal ID (if any)
public fun reserved_proposal_id<StableCoin>(queue: &ProposalQueue<StableCoin>): Option<ID> {
    queue.reserved_next_proposal
}

/// Set the reserved next proposal (package)
public(package) fun set_reserved<StableCoin>(queue: &mut ProposalQueue<StableCoin>, id: ID) {
    assert!(!has_reserved(queue), EHeapInvariantViolated);
    queue.reserved_next_proposal = option::some(id);
}

/// Clear the reserved next proposal (package)
public(package) fun clear_reserved<StableCoin>(queue: &mut ProposalQueue<StableCoin>) {
    queue.reserved_next_proposal = option::none();
}

/// Check if a specific proposal can be activated
public fun can_activate_proposal<StableCoin>(
    queue: &ProposalQueue<StableCoin>,
    proposal: &QueuedProposal<StableCoin>
): bool {
    // Check global limit
    if (queue.active_proposal_count >= queue.max_concurrent_proposals) {
        return false
    };
    
    // Check DAO liquidity constraint
    if (proposal.uses_dao_liquidity && queue.dao_liquidity_slot_occupied) {
        return false
    };
    
    true
}

/// Get all proposals in the queue (for viewing)
public fun get_all_proposals<StableCoin>(queue: &ProposalQueue<StableCoin>): &vector<QueuedProposal<StableCoin>> {
    &queue.heap
}

/// Extract bond from a queued proposal (mutable)
/// Made package-visible to prevent unauthorized bond extraction
public(package) fun extract_bond<StableCoin>(proposal: &mut QueuedProposal<StableCoin>): Option<Coin<StableCoin>> {
    let bond_ref = &mut proposal.bond;
    if (option::is_some(bond_ref)) {
        option::some(option::extract(bond_ref))
    } else {
        option::none()
    }
}

/// Destroy a queued proposal
public(package) fun destroy_proposal<StableCoin>(proposal: QueuedProposal<StableCoin>) {
    let QueuedProposal {
        bond,
        proposal_id: _,
        dao_id: _,
        proposer: _,
        fee: _,
        timestamp: _,
        priority_score: _,
        intent_key: _,
        uses_dao_liquidity: _,
        data: _,
    } = proposal;
    bond.destroy_none();
}

// === Test Functions ===

#[test_only]
public fun test_internals<StableCoin>(queue: &ProposalQueue<StableCoin>): (u64, u64, bool) {
    (
        queue.max_proposer_funded,
        queue.max_concurrent_proposals,
        queue.dao_liquidity_slot_occupied
    )
}