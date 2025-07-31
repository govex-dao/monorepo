module futarchy::priority_queue;

use std::string::String;
use std::u64;
use std::u128;
use std::vector;
use sui::clock::{Self, Clock};
use sui::coin::{Coin};
use std::option::{Self, Option};
use sui::object::{Self, ID, UID};
use sui::tx_context::TxContext;

use sui::event;

// === Events ===

/// Emitted when a proposal is evicted from the queue due to a higher-priority proposal
public struct ProposalEvicted has copy, drop {
    proposal_id: ID,
    proposer: address,
    fee: u64,
    evicted_by: ID,  // New proposal that caused eviction
    timestamp: u64,
    priority_score: u128,  // Priority score of evicted proposal
}

/// Emitted when a proposal is added to the queue
public struct ProposalQueued has copy, drop {
    proposal_id: ID,
    proposer: address,
    fee: u64,
    priority_score: u128,
    queue_position: u64,
}

// === Errors ===

/// The queue for proposer-funded proposals is full, and the new proposal's fee is not high enough
const EQueueFullAndFeeTooLow: u64 = 0;
/// Attempted to add a DAO-funded proposal when the single slot is already occupied
const EDaoSlotOccupied: u64 = 1;
/// Queue is empty
const EQueueEmpty: u64 = 2;
/// Invalid proposal ID
const EInvalidProposalId: u64 = 3;
/// Proposal not found in queue
const EProposalNotFound: u64 = 4;
/// Invalid bond for DAO-funded proposal
const EInvalidBond: u64 = 5;
/// Overflow in priority score calculation
const EOverflow: u64 = 6;
/// Queue size exceeded maximum allowed
const EQueueSizeExceeded: u64 = 7;
/// Fee is below minimum required
const EFeeBelowMinimum: u64 = 8;
/// Fee exceeds maximum allowed
const EFeeExceedsMaximum: u64 = 9;
/// Cannot cancel proposal
const ECannotCancelProposal: u64 = 10;
/// Insufficient fee for update
const EInsufficientFeeForUpdate: u64 = 11;

// === Constants ===
/// Maximum total proposals allowed in queue to prevent unbounded gas costs
const MAX_QUEUE_SIZE: u64 = 50;  // Limited for O(n) operations safety
/// Default maximum queue size if not specified
const DEFAULT_MAX_QUEUE_SIZE: u64 = 30;
/// Minimum queue size to prevent DoS
const MIN_QUEUE_SIZE: u64 = 10;
/// Maximum fee to prevent overflow (basically u64::MAX)
const MAX_FEE: u64 = 18_446_744_073_709_551_615; // u64::MAX
/// Minimum fee required to prevent spam (in smallest units)
const MIN_FEE: u64 = 1_000_000; // 1 unit with 6 decimals
/// Standard comparison results
const COMPARE_LESS: u8 = 0;
const COMPARE_EQUAL: u8 = 1;
const COMPARE_GREATER: u8 = 2;

// === Structs ===

/// Priority score with proper type safety and comparison methods
public struct PriorityScore has copy, drop, store {
    /// Score value (just the fee)
    value: u128,
    /// Original fee amount for reference
    fee: u64,
    /// Timestamp when proposal was created
    timestamp: u64,
}

// === Priority Score Functions ===

/// Creates a new priority score with validation and overflow protection
public fun new_priority_score(fee: u64, timestamp: u64, _clock: &Clock): PriorityScore {
    // Validate inputs
    assert!(fee >= MIN_FEE, EFeeBelowMinimum);
    assert!(fee <= MAX_FEE, EFeeExceedsMaximum);
    
    // Priority is just the fee - highest fee wins
    let value = (fee as u128);
    
    PriorityScore { 
        value, 
        fee, 
        timestamp,
    }
}

/// Compares two priority scores using standard ordering
public fun compare_priority_scores(a: &PriorityScore, b: &PriorityScore): u8 {
    if (a.value < b.value) { COMPARE_LESS }
    else if (a.value > b.value) { COMPARE_GREATER }
    else { COMPARE_EQUAL }
}

/// Gets the value of a priority score
public fun priority_score_value(score: &PriorityScore): u128 {
    score.value
}


/// Typed data for a proposal waiting in the queue. Validated on submission.
public struct ProposalData has store, drop, copy {
    title: String,
    metadata: String,
    outcome_messages: vector<String>,
    outcome_details: vector<String>,
    initial_asset_amounts: vector<u64>,
    initial_stable_amounts: vector<u64>,
}

/// A queued proposal entry
public struct QueuedProposal<phantom StableCoin> has store {
    proposal_id: ID,
    dao_id: ID,
    fee: u64,
    uses_dao_liquidity: bool,
    proposer: address,
    timestamp: u64,
    priority_score: PriorityScore, // Proper type for priority scoring
    data: ProposalData,
    bond: Option<Coin<StableCoin>>, // Bond required for DAO-funded proposals
}

/// Capability to handle proposal fee refunds
public struct RefundCapability has store, drop {
    fee_manager_id: ID,
}

/// Priority queue for managing proposal submissions
public struct ProposalQueue<phantom StableCoin> has key, store {
    id: UID,
    dao_id: ID,
    /// Sorted list of proposals (highest priority first)
    proposals: vector<QueuedProposal<StableCoin>>,
    /// Maximum number of proposer-funded proposals
    max_proposer_funded: u64,
    /// Maximum total proposals (including DAO-funded)
    max_concurrent_proposals: u64,
    /// Whether the single DAO liquidity slot is occupied
    dao_liquidity_slot_occupied: bool,
    /// Current number of active proposals (not in queue)
    active_proposal_count: u64,
    /// Maximum queue size (configurable per DAO)
    max_queue_size: u64,
    /// Optional refund capability for automatic fee refunds
    refund_cap: Option<RefundCapability>,
}

// === Public Functions ===

/// Calculates minimum required fee based on queue occupancy (DoS protection)
public fun calculate_min_fee<StableCoin>(queue: &ProposalQueue<StableCoin>): u64 {
    let queue_size = vector::length(&queue.proposals);
    let occupancy_ratio = (queue_size * 100) / queue.max_queue_size;
    
    // Escalate fee based on queue occupancy
    if (occupancy_ratio >= 90) {
        MIN_FEE * 10  // 10x when queue is 90% full
    } else if (occupancy_ratio >= 75) {
        MIN_FEE * 5   // 5x when queue is 75% full
    } else if (occupancy_ratio >= 50) {
        MIN_FEE * 2   // 2x when queue is 50% full
    } else {
        MIN_FEE
    }
}

/// Gets all proposals in the queue (for viewing)
public fun get_all_proposals<StableCoin>(queue: &ProposalQueue<StableCoin>): &vector<QueuedProposal<StableCoin>> {
    &queue.proposals
}

/// Gets proposals by proposer
public fun get_proposals_by_proposer<StableCoin>(
    queue: &ProposalQueue<StableCoin>, 
    proposer: address
): vector<ID> {
    let mut result = vector::empty<ID>();
    let len = vector::length(&queue.proposals);
    let mut i = 0;
    
    while (i < len) {
        let proposal = vector::borrow(&queue.proposals, i);
        if (proposal.proposer == proposer) {
            vector::push_back(&mut result, proposal.proposal_id);
        };
        i = i + 1;
    };
    
    result
}

/// Checks if a proposal with given fee would be accepted
public fun would_accept_proposal<StableCoin>(
    queue: &ProposalQueue<StableCoin>,
    fee: u64,
    uses_dao_liquidity: bool,
    clock: &Clock
): bool {
    // Check basic fee requirements
    if (fee < calculate_min_fee(queue)) {
        return false
    };
    
    // Check if can create immediately
    if (can_create_immediately(queue, uses_dao_liquidity)) {
        return true
    };
    
    // Check if would evict someone
    if (!uses_dao_liquidity) {
        let proposer_funded_count = count_proposer_funded(&queue.proposals);
        if (proposer_funded_count >= queue.max_proposer_funded) {
            // Would need to evict - check if fee is high enough
            let lowest_idx = find_lowest_priority_proposer_funded(&queue.proposals);
            let lowest = vector::borrow(&queue.proposals, lowest_idx);
            let new_priority = new_priority_score(fee, clock::timestamp_ms(clock), clock);
            return compare_priority_scores(&new_priority, &lowest.priority_score) == COMPARE_GREATER
        };
    };
    
    // Check queue size
    vector::length(&queue.proposals) < queue.max_queue_size
}

/// Creates a new ProposalData
public fun new_proposal_data(
    title: String,
    metadata: String,
    outcome_messages: vector<String>,
    outcome_details: vector<String>,
    initial_asset_amounts: vector<u64>,
    initial_stable_amounts: vector<u64>,
): ProposalData {
    ProposalData {
        title,
        metadata,
        outcome_messages,
        outcome_details,
        initial_asset_amounts,
        initial_stable_amounts,
    }
}

/// Creates a new proposal queue for a DAO
public fun new<StableCoin>(
    dao_id: ID,
    max_proposer_funded: u64,
    max_concurrent_proposals: u64,
    ctx: &mut TxContext
): ProposalQueue<StableCoin> {
    new_with_config(dao_id, max_proposer_funded, max_concurrent_proposals, DEFAULT_MAX_QUEUE_SIZE, ctx)
}

/// Creates a new proposal queue with custom configuration
public fun new_with_config<StableCoin>(
    dao_id: ID,
    max_proposer_funded: u64,
    max_concurrent_proposals: u64,
    max_queue_size: u64,
    ctx: &mut TxContext
): ProposalQueue<StableCoin> {
    assert!(max_queue_size >= MIN_QUEUE_SIZE && max_queue_size <= MAX_QUEUE_SIZE, EQueueSizeExceeded);
    
    ProposalQueue {
        id: object::new(ctx),
        dao_id,
        proposals: vector::empty(),
        max_proposer_funded,
        max_concurrent_proposals,
        dao_liquidity_slot_occupied: false,
        active_proposal_count: 0,
        max_queue_size,
        refund_cap: option::none(),
    }
}

/// Creates a new queued proposal
public fun new_queued_proposal<StableCoin>(
    proposal_id: ID,
    dao_id: ID,
    fee: u64,
    uses_dao_liquidity: bool,
    proposer: address,
    data: ProposalData,
    bond: Option<Coin<StableCoin>>,
    clock: &Clock,
): QueuedProposal<StableCoin> {
    let timestamp = clock::timestamp_ms(clock);
    let priority_score = new_priority_score(fee, timestamp, clock);
    
    // Validate that DAO-funded proposals have a bond and proposer-funded don't
    assert!(uses_dao_liquidity == bond.is_some(), EInvalidBond);
    
    QueuedProposal {
        proposal_id,
        dao_id,
        fee,
        uses_dao_liquidity,
        proposer,
        timestamp,
        priority_score,
        data,
        bond,
    }
}

/// Sets the refund capability for automatic fee refunds
public fun set_refund_capability<StableCoin>(
    queue: &mut ProposalQueue<StableCoin>,
    fee_manager_id: ID,
) {
    queue.refund_cap = option::some(RefundCapability { fee_manager_id });
}

/// Removes the refund capability
public fun remove_refund_capability<StableCoin>(
    queue: &mut ProposalQueue<StableCoin>,
): RefundCapability {
    option::extract(&mut queue.refund_cap)
}

/// Checks if a proposal can be created immediately (without queuing)
public fun can_create_immediately<StableCoin>(queue: &ProposalQueue<StableCoin>, uses_dao_liquidity: bool): bool {
    // Check if we're at max concurrent proposals
    if (queue.active_proposal_count >= queue.max_concurrent_proposals) {
        return false
    };
    
    // If using DAO liquidity, check if slot is available
    if (uses_dao_liquidity && queue.dao_liquidity_slot_occupied) {
        return false
    };
    
    true
}

/// Inserts a proposal into the queue
public fun insert<StableCoin>(
    queue: &mut ProposalQueue<StableCoin>,
    proposal: QueuedProposal<StableCoin>,
    _ctx: &mut TxContext
) {
    // Check minimum fee requirement (DoS protection)
    let min_fee = calculate_min_fee(queue);
    assert!(proposal.fee >= min_fee, EFeeBelowMinimum);
    
    let proposals = &mut queue.proposals;
    
    // Check total queue size to prevent unbounded growth
    assert!(proposals.length() < queue.max_queue_size, EQueueSizeExceeded);
    
    if (proposal.uses_dao_liquidity) {
        // For DAO-funded proposals, check if we're trying to add when slot is occupied and at capacity
        if (queue.dao_liquidity_slot_occupied && 
            queue.active_proposal_count >= queue.max_concurrent_proposals) {
            abort EDaoSlotOccupied
        };
    } else {
        // Check if proposer-funded queue is at capacity
        let proposer_funded_count = count_proposer_funded(proposals);
        
        if (proposer_funded_count >= queue.max_proposer_funded) {
            // Find the lowest priority proposer-funded proposal
            let lowest_priority_idx = find_lowest_priority_proposer_funded(proposals);
            let lowest = vector::borrow(proposals, lowest_priority_idx);
            
            // New proposal must have higher priority to evict
            assert!(compare_priority_scores(&proposal.priority_score, &lowest.priority_score) == COMPARE_GREATER, EQueueFullAndFeeTooLow);
            
            // Remove the lowest priority proposal
            let evicted = vector::remove(proposals, lowest_priority_idx);
            let QueuedProposal { bond, proposal_id, proposer, fee, timestamp, priority_score, .. } = evicted;
            
            // Emit eviction event
            event::emit(ProposalEvicted { 
                proposal_id, 
                proposer, 
                fee,
                evicted_by: proposal.proposal_id,
                timestamp,
                priority_score: priority_score_value(&priority_score),
            });
            
            // Handle refund if capability is available
            if (option::is_some(&queue.refund_cap)) {
                // The refund should be handled by external system listening to events
                // We just ensure the bond is properly destroyed
            };
            
            bond.destroy_none(); // Proposer-funded proposals have no bond
        };
    };
    
    // Insert in sorted order (highest priority first)
    let insert_idx = find_insert_position(proposals, &proposal.priority_score);
    
    // Emit event for proposal being queued
    event::emit(ProposalQueued {
        proposal_id: proposal.proposal_id,
        proposer: proposal.proposer,
        fee: proposal.fee,
        priority_score: priority_score_value(&proposal.priority_score),
        queue_position: insert_idx,
    });
    
    vector::insert(proposals, proposal, insert_idx);
}

/// Tries to activate the next proposal from the queue
public fun try_activate_next<StableCoin>(queue: &mut ProposalQueue<StableCoin>): Option<QueuedProposal<StableCoin>> {
    if (vector::is_empty(&queue.proposals)) {
        return option::none()
    };
    
    // Check from highest priority down
    let mut i = 0;
    let len = vector::length(&queue.proposals);
    
    while (i < len) {
        let proposal = vector::borrow(&queue.proposals, i);
        
        // Check if this proposal can be activated
        if (can_activate_proposal(queue, proposal)) {
            // Remove and return it
            let activated = vector::remove(&mut queue.proposals, i);
            
            // Update state
            queue.active_proposal_count = queue.active_proposal_count + 1;
            if (activated.uses_dao_liquidity) {
                queue.dao_liquidity_slot_occupied = true;
            };
            
            return option::some(activated)
        };
        
        i = i + 1;
    };
    
    option::none()
}

/// Marks a proposal as completed, freeing up space
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

/// Removes a specific proposal from the queue
public fun remove_from_queue<StableCoin>(
    queue: &mut ProposalQueue<StableCoin>,
    proposal_id: ID
): QueuedProposal<StableCoin> {
    let proposals = &mut queue.proposals;
    let len = vector::length(proposals);
    let mut i = 0;
    
    while (i < len) {
        let proposal = vector::borrow(proposals, i);
        if (proposal.proposal_id == proposal_id) {
            return vector::remove(proposals, i)
        };
        i = i + 1;
    };
    
    abort EProposalNotFound
}

// === View Functions ===

/// Returns the number of proposals in the queue
public fun length<StableCoin>(queue: &ProposalQueue<StableCoin>): u64 {
    vector::length(&queue.proposals)
}

/// Returns the number of active proposals
public fun active_count<StableCoin>(queue: &ProposalQueue<StableCoin>): u64 {
    queue.active_proposal_count
}

/// Checks if the DAO liquidity slot is occupied
public fun is_dao_slot_occupied<StableCoin>(queue: &ProposalQueue<StableCoin>): bool {
    queue.dao_liquidity_slot_occupied
}

/// Returns the top N proposal IDs in the queue
public fun get_top_n_ids<StableCoin>(queue: &ProposalQueue<StableCoin>, n: u64): vector<ID> {
    let mut result = vector::empty();
    let limit = if (n < length(queue)) { n } else { length(queue) };
    let mut i = 0;
    
    while (i < limit) {
        let proposal = vector::borrow(&queue.proposals, i);
        vector::push_back(&mut result, proposal.proposal_id);
        i = i + 1;
    };
    
    result
}

/// Cancels a proposal and refunds the fee
public fun cancel_proposal<StableCoin>(
    queue: &mut ProposalQueue<StableCoin>,
    proposal_id: ID,
    proposer: address,
    _ctx: &TxContext
): (u64, Option<Coin<StableCoin>>) {
    let proposals = &mut queue.proposals;
    let len = vector::length(proposals);
    let mut i = 0;
    
    while (i < len) {
        let proposal = vector::borrow(proposals, i);
        if (proposal.proposal_id == proposal_id) {
            // Only proposer can cancel their own proposal
            assert!(proposal.proposer == proposer, ECannotCancelProposal);
            
            let removed = vector::remove(proposals, i);
            let QueuedProposal { fee, bond, uses_dao_liquidity, .. } = removed;
            
            // Update cached count if needed
            if (!uses_dao_liquidity) {
                // Proposer-funded proposal removed
            };
            
            return (fee, bond)
        };
        i = i + 1;
    };
    
    abort EProposalNotFound
}

/// Updates a proposal's priority by adding more fee
public fun update_proposal_fee<StableCoin>(
    queue: &mut ProposalQueue<StableCoin>,
    proposal_id: ID,
    additional_fee: u64,
    proposer: address,
    clock: &Clock,
): u64 {
    assert!(additional_fee >= MIN_FEE, EInsufficientFeeForUpdate);
    
    let proposals = &mut queue.proposals;
    let len = vector::length(proposals);
    let mut i = 0;
    
    while (i < len) {
        let proposal = vector::borrow(proposals, i);
        if (proposal.proposal_id == proposal_id) {
            assert!(proposal.proposer == proposer, ECannotCancelProposal);
            
            // Remove the proposal temporarily
            let mut removed = vector::remove(proposals, i);
            
            // Update fee and recalculate priority
            let new_fee = removed.fee + additional_fee;
            assert!(new_fee <= MAX_FEE, EFeeExceedsMaximum);
            
            removed.fee = new_fee;
            removed.priority_score = new_priority_score(new_fee, removed.timestamp, clock);
            
            // Re-insert in sorted order
            let new_idx = find_insert_position(proposals, &removed.priority_score);
            vector::insert(proposals, removed, new_idx);
            
            return new_fee
        };
        i = i + 1;
    };
    
    abort EProposalNotFound
}

/// Gets queue statistics
public fun get_stats<StableCoin>(queue: &ProposalQueue<StableCoin>): (u64, u64, u64, bool) {
    (
        length(queue),
        queue.active_proposal_count,
        count_proposer_funded(&queue.proposals),
        queue.dao_liquidity_slot_occupied
    )
}

// === Internal Functions ===

/// Counts proposer-funded proposals in the queue  
fun count_proposer_funded<StableCoin>(proposals: &vector<QueuedProposal<StableCoin>>): u64 {
    let mut count = 0;
    let mut i = 0;
    let len = vector::length(proposals);
    
    while (i < len) {
        let proposal = vector::borrow(proposals, i);
        if (!proposal.uses_dao_liquidity) {
            count = count + 1;
        };
        i = i + 1;
    };
    
    count
}

/// Finds the lowest priority proposer-funded proposal
fun find_lowest_priority_proposer_funded<StableCoin>(proposals: &vector<QueuedProposal<StableCoin>>): u64 {
    let len = vector::length(proposals);
    // Handle empty queue
    if (len == 0) {
        abort EProposalNotFound
    };
    
    let mut i = len - 1;
    
    // Search from end (lowest priority) to start
    loop {
        let proposal = vector::borrow(proposals, i);
        if (!proposal.uses_dao_liquidity) {
            return i
        };
        
        if (i == 0) break;
        i = i - 1;
    };
    
    // This should not happen if we have proposer-funded proposals
    abort EProposalNotFound
}

/// Finds the correct insertion position to maintain sorted order
fun find_insert_position<StableCoin>(proposals: &vector<QueuedProposal<StableCoin>>, priority_score: &PriorityScore): u64 {
    let len = vector::length(proposals);
    let mut i = 0;
    
    while (i < len) {
        let current = vector::borrow(proposals, i);
        if (compare_priority_scores(priority_score, &current.priority_score) == COMPARE_GREATER) {
            return i
        };
        i = i + 1;
    };
    
    len
}

/// Checks if a specific proposal can be activated
fun can_activate_proposal<StableCoin>(queue: &ProposalQueue<StableCoin>, proposal: &QueuedProposal<StableCoin>): bool {
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

// === Getter Functions for ProposalData ===

/// Get title
public fun get_title(data: &ProposalData): &String {
    &data.title
}

/// Get metadata
public fun get_metadata(data: &ProposalData): &String {
    &data.metadata
}

/// Get outcome messages
public fun get_outcome_messages(data: &ProposalData): &vector<String> {
    &data.outcome_messages
}

/// Get outcome details
public fun get_outcome_details(data: &ProposalData): &vector<String> {
    &data.outcome_details
}

/// Get initial asset amounts
public fun get_initial_asset_amounts(data: &ProposalData): &vector<u64> {
    &data.initial_asset_amounts
}

/// Get initial stable amounts
public fun get_initial_stable_amounts(data: &ProposalData): &vector<u64> {
    &data.initial_stable_amounts
}

// === Getter Functions for QueuedProposal ===

/// Get proposal data
public fun get_proposal_data<StableCoin>(proposal: &QueuedProposal<StableCoin>): &ProposalData {
    &proposal.data
}

/// Get proposal ID
public fun get_proposal_id<StableCoin>(proposal: &QueuedProposal<StableCoin>): ID {
    proposal.proposal_id
}

/// Get proposer address
public fun get_proposer<StableCoin>(proposal: &QueuedProposal<StableCoin>): address {
    proposal.proposer
}

/// Get fee amount
public fun get_fee<StableCoin>(proposal: &QueuedProposal<StableCoin>): u64 {
    proposal.fee
}

/// Check if proposal uses DAO liquidity
public fun uses_dao_liquidity<StableCoin>(proposal: &QueuedProposal<StableCoin>): bool {
    proposal.uses_dao_liquidity
}

/// Get timestamp
public fun get_timestamp<StableCoin>(proposal: &QueuedProposal<StableCoin>): u64 {
    proposal.timestamp
}

/// Get priority score
public fun get_priority_score<StableCoin>(proposal: &QueuedProposal<StableCoin>): &PriorityScore {
    &proposal.priority_score
}

/// Extract bond (mutable)
public fun extract_bond<StableCoin>(proposal: &mut QueuedProposal<StableCoin>): Option<Coin<StableCoin>> {
    let bond_ref = &mut proposal.bond;
    if (option::is_some(bond_ref)) {
        option::some(option::extract(bond_ref))
    } else {
        option::none()
    }
}

/// Destroy a queued proposal (must be called within priority_queue module)
public(package) fun destroy_proposal<StableCoin>(proposal: QueuedProposal<StableCoin>) {
    let QueuedProposal { 
        proposal_id: _, 
        dao_id: _, 
        fee: _, 
        uses_dao_liquidity: _, 
        proposer: _, 
        timestamp: _, 
        priority_score: _, 
        data: _, 
        bond 
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