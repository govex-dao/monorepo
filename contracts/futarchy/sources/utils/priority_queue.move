module futarchy::priority_queue;

use std::vector;
use std::option::{Self, Option};
use std::string::String;
use sui::object::{Self, UID, ID};
use sui::tx_context::TxContext;
use sui::clock::Clock;
use sui::coin::{Self, Coin};

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

// === Structs ===

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
    priority_score: u64, // Combination of fee and timestamp for ordering
    data: ProposalData,
    bond: Option<Coin<StableCoin>>, // Bond required for DAO-funded proposals
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
}

// === Public Functions ===

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
    ProposalQueue {
        id: object::new(ctx),
        dao_id,
        proposals: vector::empty(),
        max_proposer_funded,
        max_concurrent_proposals,
        dao_liquidity_slot_occupied: false,
        active_proposal_count: 0,
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
    let timestamp = clock.timestamp_ms();
    // Priority score: higher fee = higher priority, older = higher priority
    // We use (fee * 1e12) + (1e15 - timestamp) to ensure fee dominates but timestamp breaks ties
    let priority_score = (fee as u64) * 1_000_000_000_000 + (1_000_000_000_000_000 - timestamp);
    
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
    proposal: QueuedProposal<StableCoin>
) {
    let proposals = &mut queue.proposals;
    
    if (proposal.uses_dao_liquidity) {
        // For DAO-funded proposals, we don't check capacity as they go into queue
        // The actual slot check happens when trying to activate from queue
    } else {
        // Check if proposer-funded queue is at capacity
        let proposer_funded_count = count_proposer_funded(proposals);
        
        if (proposer_funded_count >= queue.max_proposer_funded) {
            // Find the lowest priority proposer-funded proposal
            let lowest_priority_idx = find_lowest_priority_proposer_funded(proposals);
            let lowest = vector::borrow(proposals, lowest_priority_idx);
            
            // New proposal must have higher priority to evict
            assert!(proposal.priority_score > lowest.priority_score, EQueueFullAndFeeTooLow);
            
            // Remove the lowest priority proposal
            let evicted = vector::remove(proposals, lowest_priority_idx);
            // The fee for the evicted proposal is lost and bond is destroyed
            let QueuedProposal { bond, .. } = evicted;
            bond.destroy_none(); // Proposer-funded proposals have no bond
        };
    };
    
    // Insert in sorted order (highest priority first)
    let insert_idx = find_insert_position(proposals, proposal.priority_score);
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
fun find_insert_position<StableCoin>(proposals: &vector<QueuedProposal<StableCoin>>, priority_score: u64): u64 {
    let len = vector::length(proposals);
    let mut i = 0;
    
    while (i < len) {
        let current = vector::borrow(proposals, i);
        if (priority_score > current.priority_score) {
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