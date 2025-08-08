/// Cross-DAO Atomic Coordination System
/// 
/// This module implements true atomic cross-DAO coordination through the Intent/Executable framework.
/// Key design principles:
/// 1. No central registry - CrossDaoProposal is a standalone shared object
/// 2. Native integration with futarchy markets - each DAO runs its normal governance
/// 3. Two-phase commit - lock then atomically execute
/// 4. True atomicity - all actions execute in one transaction or all revert
module futarchy::cross_dao_atomic;

// === Imports ===
use std::string::{Self, String};
use std::vector;
use std::option::{Self, Option};
use sui::{
    clock::{Self, Clock},
    object::{Self, ID, UID},
    table::{Self, Table},
    transfer,
    tx_context::{Self, TxContext},
    event,
};
use account_protocol::{
    account::{Self, Account},
    executable::Executable,
};
use futarchy::futarchy_config::FutarchyConfig;

// === Errors ===
const ENotParticipant: u64 = 1;
const EAlreadyLocked: u64 = 2;
const ENotReady: u64 = 3;
const EDeadlineExpired: u64 = 4;
const EInvalidState: u64 = 5;
const EActionHashMismatch: u64 = 6;
const EProposalAlreadyCommitted: u64 = 7;
const ELockExpired: u64 = 8;
const EParticipantAlreadyLocked: u64 = 9;

// === Constants ===
const STATE_PENDING: u8 = 0;
const STATE_PARTIALLY_LOCKED: u8 = 1;
const STATE_READY: u8 = 2;
const STATE_COMMITTED: u8 = 3;

// === Core Structs ===

/// Action that signals this Executable should lock for cross-DAO coordination
public struct LockForCrossDaoCommit has store {
    cross_dao_proposal_id: ID,
    action_hash: vector<u8>,
    lock_expiry: u64,
}

/// Standalone shared object for coordinating cross-DAO actions
/// Supports M-of-N threshold: e.g., 3 of 5 DAOs must approve
public struct CrossDaoProposal has key, store {
    id: UID,
    state: u8,
    participants: vector<DaoParticipant>,
    locked_weight: u64,  // Total weight of locked participants
    threshold: u64,  // M in M-of-N (minimum weight required to proceed)
    commit_deadline: u64,
    title: String,
    description: String,
}

/// Information about a participating DAO
public struct DaoParticipant has store, copy, drop {
    dao_id: ID,
    expected_action_hash: vector<u8>,
    weight: u64,  // Voting weight (1 for equal weight, higher for more influence)
    locked: bool,  // Track lock status to prevent double-counting
}

// === Events ===

public struct ProposalCreated has copy, drop {
    proposal_id: ID,
    participant_count: u64,
    title: String,
}

public struct DaoLocked has copy, drop {
    proposal_id: ID,
    dao_id: ID,
    weight_locked: u64,
}

public struct ProposalCommitted has copy, drop {
    proposal_id: ID,
    timestamp: u64,
}

// === Public Helper Functions ===

/// Create a simple M-of-N proposal where all DAOs have equal weight
public fun create_equal_weight_proposal(
    dao_ids: vector<ID>,
    action_hashes: vector<vector<u8>>,
    threshold: u64,  // How many DAOs must approve
    title: String,
    description: String,
    commit_deadline: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let mut participants = vector::empty<DaoParticipant>();
    let mut i = 0;
    while (i < vector::length(&dao_ids)) {
        vector::push_back(&mut participants, DaoParticipant {
            dao_id: *vector::borrow(&dao_ids, i),
            expected_action_hash: *vector::borrow(&action_hashes, i),
            weight: 1,  // Equal weight for all
            locked: false,
        });
        i = i + 1;
    };
    
    create_proposal(
        participants,
        threshold,
        title,
        description,
        commit_deadline,
        clock,
        ctx
    );
}


// === Public Functions ===

/// Create a new cross-DAO proposal with M-of-N threshold
/// threshold: minimum weight needed to proceed (e.g., 3 for 3-of-5)
/// participants: list of DAOs with their voting weights
public fun create_proposal(
    participants: vector<DaoParticipant>,
    threshold: u64,  // Minimum weight needed to proceed
    title: String,
    description: String,
    commit_deadline: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Calculate total possible weight
    let mut total_weight = 0u64;
    let mut i = 0;
    while (i < vector::length(&participants)) {
        total_weight = total_weight + vector::borrow(&participants, i).weight;
        i = i + 1;
    };
    
    // Ensure threshold is achievable
    assert!(threshold <= total_weight, EInvalidState);
    assert!(threshold > 0, EInvalidState);
    
    let proposal = CrossDaoProposal {
        id: object::new(ctx),
        state: STATE_PENDING,
        participants,
        locked_weight: 0,
        threshold,
        commit_deadline,
        title,
        description,
    };
    
    event::emit(ProposalCreated {
        proposal_id: object::id(&proposal),
        participant_count: vector::length(&proposal.participants),
        title: proposal.title,
    });
    
    transfer::share_object(proposal);
}

/// Lock a DAO's commitment to the proposal
/// This function must be called by participating DAOs before the deadline
/// Once threshold weight is reached, proposal becomes ready
public fun lock_dao(
    proposal: &mut CrossDaoProposal,
    dao_id: ID,
    clock: &Clock,
) {
    // Strong state assertion - must be in lockable state
    assert!(proposal.state == STATE_PENDING || proposal.state == STATE_PARTIALLY_LOCKED, EInvalidState);
    
    // Strong deadline assertion - no extensions allowed
    let current_time = clock::timestamp_ms(clock);
    assert!(current_time < proposal.commit_deadline, EDeadlineExpired);
    
    // Find participant, get weight, and check lock status
    let mut dao_weight = 0u64;
    let mut participant_idx = 0;
    let mut found = false;
    let mut i = 0;
    while (i < vector::length(&proposal.participants)) {
        let p = vector::borrow(&proposal.participants, i);
        if (p.dao_id == dao_id) {
            assert!(!p.locked, EParticipantAlreadyLocked); // Prevent double-locking
            dao_weight = p.weight;
            participant_idx = i;
            found = true;
            break
        };
        i = i + 1;
    };
    assert!(found, ENotParticipant);
    
    // Mark participant as locked
    let p_mut = vector::borrow_mut(&mut proposal.participants, participant_idx);
    p_mut.locked = true;
    
    // Add this DAO's weight to locked count
    proposal.locked_weight = proposal.locked_weight + dao_weight;
    
    // Check if threshold is met
    if (proposal.locked_weight >= proposal.threshold) {
        proposal.state = STATE_READY;
    } else if (proposal.state == STATE_PENDING) {
        proposal.state = STATE_PARTIALLY_LOCKED;
    };
    
    event::emit(DaoLocked {
        proposal_id: object::id(proposal),
        dao_id,
        weight_locked: dao_weight,
    });
}

/// Mark proposal as committed (called after atomic execution)
public fun mark_committed(
    proposal: &mut CrossDaoProposal,
    clock: &Clock,
) {
    assert!(proposal.state == STATE_READY, ENotReady);
    assert!(proposal.state != STATE_COMMITTED, EProposalAlreadyCommitted);
    proposal.state = STATE_COMMITTED;
    
    event::emit(ProposalCommitted {
        proposal_id: object::id(proposal),
        timestamp: clock::timestamp_ms(clock),
    });
}

/// Execute the lock action from an Account's Executable
/// This is called when a DAO's proposal passes and needs to lock for cross-DAO coordination
public fun execute_lock_action<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    proposal: &mut CrossDaoProposal,
    witness: IW,
    clock: &Clock,
) {
    // Extract the lock action from the executable
    let lock_action = executable.next_action<Outcome, LockForCrossDaoCommit, IW>(witness);
    
    // Verify the action is for this proposal
    assert!(lock_action.cross_dao_proposal_id == object::id(proposal), EActionHashMismatch);
    
    // Verify lock hasn't expired
    assert!(clock::timestamp_ms(clock) < lock_action.lock_expiry, ELockExpired);
    
    // Get the DAO ID from the account
    let dao_id = object::id(account);
    
    // Verify action hash matches expected
    let mut participant_found = false;
    let mut i = 0;
    while (i < vector::length(&proposal.participants)) {
        let participant = vector::borrow(&proposal.participants, i);
        if (participant.dao_id == dao_id) {
            participant_found = true;
            assert!(
                participant.expected_action_hash == lock_action.action_hash,
                EActionHashMismatch
            );
            break
        };
        i = i + 1;
    };
    
    assert!(participant_found, ENotParticipant);
    
    // Lock this DAO's commitment
    lock_dao(proposal, dao_id, clock);
}

/// Execute actions for all locked DAOs atomically when proposal is ready.
/// This is a generic function that handles any number of locked participants.
/// Accounts and executables must be provided in matching order corresponding to locked participants.
public fun execute_atomic_actions<Outcome: drop + store>(
    proposal: &mut CrossDaoProposal,
    mut accounts: vector<Account<FutarchyConfig>>,
    mut executables: vector<Executable<Outcome>>,
    clock: &Clock,
) {
    // --- Pre-execution checks ---
    // Verify proposal is ready
    assert!(proposal.state == STATE_READY, ENotReady);
    // Verify deadline hasn't passed
    assert!(clock::timestamp_ms(clock) < proposal.commit_deadline, EDeadlineExpired);
    
    // Count locked participants
    let mut locked_count = 0u64;
    let mut i = 0;
    while (i < vector::length(&proposal.participants)) {
        if (vector::borrow(&proposal.participants, i).locked) {
            locked_count = locked_count + 1;
        };
        i = i + 1;
    };
    
    // Verify we have matching number of accounts and executables for locked participants
    assert!(vector::length(&accounts) == locked_count, EInvalidState);
    assert!(vector::length(&executables) == locked_count, EInvalidState);
    
    // --- Atomic Execution Loop ---
    // Process locked participants in order
    let mut account_idx = 0;
    let mut j = 0;
    while (j < vector::length(&proposal.participants)) {
        let participant = vector::borrow(&proposal.participants, j);
        if (participant.locked) {
            // Get the account and executable for this locked participant
            let account = vector::borrow_mut(&mut accounts, account_idx);
            let executable = vector::pop_back(&mut executables);
            
            // Ensure the account ID matches the participant's DAO ID
            assert!(object::id(account) == participant.dao_id, ENotParticipant);
            
            // Execute the actions for this DAO
            account::confirm_execution(account, executable);
            account_idx = account_idx + 1;
        };
        j = j + 1;
    };
    
    // Clean up empty vectors
    vector::destroy_empty(executables);
    // Accounts vector is consumed and will be dropped by caller
    vector::destroy_empty(accounts);
    
    // Mark proposal as committed
    mark_committed(proposal, clock);
}

/// Helper function to confirm execution for a single executable-account pair
/// Use this when you need to process executables one by one
public fun confirm_single_execution<Outcome: drop + store>(
    account: &mut Account<FutarchyConfig>,
    executable: Executable<Outcome>,
) {
    account::confirm_execution(account, executable);
}

// === Helper Functions ===

/// Create a lock action
public fun create_lock_action(
    proposal_id: ID,
    action_hash: vector<u8>,
    lock_expiry: u64,
): LockForCrossDaoCommit {
    LockForCrossDaoCommit {
        cross_dao_proposal_id: proposal_id,
        action_hash,
        lock_expiry,
    }
}

/// Create a participant
public fun create_participant(
    dao_id: ID,
    action_hash: vector<u8>,
    weight: u64,
): DaoParticipant {
    DaoParticipant {
        dao_id,
        expected_action_hash: action_hash,
        weight,
        locked: false,
    }
}

// === Timeout and Cleanup Functions ===

/// Handle expired proposal - allows cleanup after deadline
public fun handle_expired_proposal(
    proposal: &mut CrossDaoProposal,
    clock: &Clock,
) {
    let current_time = clock::timestamp_ms(clock);
    assert!(current_time >= proposal.commit_deadline, EInvalidState);
    
    // If not yet committed, mark as expired
    if (proposal.state != STATE_COMMITTED) {
        // Could emit an expiry event here
        // Allow participants to unlock their resources
    }
}

/// Verify a DAO can participate in the proposal
public fun verify_participant(
    proposal: &CrossDaoProposal,
    dao_id: ID,
    action_hash: vector<u8>,
): bool {
    let mut i = 0;
    while (i < vector::length(&proposal.participants)) {
        let participant = vector::borrow(&proposal.participants, i);
        if (participant.dao_id == dao_id) {
            return participant.expected_action_hash == action_hash
        };
        i = i + 1;
    };
    false
}

// === Getter Functions ===

public fun get_state(proposal: &CrossDaoProposal): u8 {
    proposal.state
}

public fun is_ready(proposal: &CrossDaoProposal): bool {
    proposal.state == STATE_READY
}

public fun is_committed(proposal: &CrossDaoProposal): bool {
    proposal.state == STATE_COMMITTED
}

public fun get_deadline(proposal: &CrossDaoProposal): u64 {
    proposal.commit_deadline
}

public fun get_locked_weight(proposal: &CrossDaoProposal): u64 {
    proposal.locked_weight
}

public fun get_threshold(proposal: &CrossDaoProposal): u64 {
    proposal.threshold
}

public fun get_proposal_id(action: &LockForCrossDaoCommit): ID {
    action.cross_dao_proposal_id
}

public fun get_action_hash(action: &LockForCrossDaoCommit): &vector<u8> {
    &action.action_hash
}

public fun get_lock_expiry(action: &LockForCrossDaoCommit): u64 {
    action.lock_expiry
}

// === Test Only Functions ===

#[test_only]
public struct CrossDaoProposalRegistry has key {
    id: UID,
    proposals: Table<ID, CrossDaoProposal>,
}

#[test_only]
public struct ProposalAdminCap has key, store {
    id: UID,
    proposal_id: ID,
}

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    let registry = CrossDaoProposalRegistry {
        id: object::new(ctx),
        proposals: table::new(ctx),
    };
    transfer::share_object(registry);
}

#[test_only]
public fun create_test_action(
    action_type: String,
    dao_id: ID,
    proposal_id: ID,
): DaoParticipant {
    DaoParticipant {
        dao_id,
        expected_action_hash: std::hash::sha3_256(*string::bytes(&action_type)),
        weight: 1, // Default to weight 1 for tests
        locked: false,
    }
}

#[test_only]
public fun create_cross_dao_proposal(
    registry: &mut CrossDaoProposalRegistry,
    dao_ids: vector<ID>,
    actions: vector<DaoParticipant>,
    title: String,
    description: String,
    deadline: u64,
    _exploding_offer: Option<u64>,
    _execution_delay: u64,
    admins: vector<address>,
    clock: &Clock,
    ctx: &mut TxContext,
): ID {
    let proposal = CrossDaoProposal {
        id: object::new(ctx),
        state: STATE_PENDING,
        participants: actions,
        locked_weight: 0,
        threshold: vector::length(&actions), // Default to all must approve for tests
        commit_deadline: deadline,
        title,
        description,
    };
    
    let proposal_id = object::uid_to_inner(&proposal.id);
    
    // Create admin caps for each admin
    let mut i = 0;
    while (i < vector::length(&admins)) {
        let admin_cap = ProposalAdminCap {
            id: object::new(ctx),
            proposal_id,
        };
        transfer::transfer(admin_cap, *vector::borrow(&admins, i));
        i = i + 1;
    };
    
    table::add(&mut registry.proposals, proposal_id, proposal);
    proposal_id
}

#[test_only]
public fun get_proposal(registry: &CrossDaoProposalRegistry, proposal_id: ID): &CrossDaoProposal {
    table::borrow(&registry.proposals, proposal_id)
}

#[test_only]
public fun get_proposal_state(proposal: &CrossDaoProposal): u8 {
    proposal.state
}

#[test_only]
public fun approve_proposal(
    registry: &mut CrossDaoProposalRegistry,
    proposal_id: ID,
    dao_id: ID,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let proposal = table::borrow_mut(&mut registry.proposals, proposal_id);
    
    // Find and mark the participant as locked
    let mut i = 0;
    let mut found = false;
    let mut participant_weight = 0u64;
    let mut participant_idx = 0;
    while (i < vector::length(&proposal.participants)) {
        let participant = vector::borrow(&proposal.participants, i);
        if (participant.dao_id == dao_id) {
            participant_weight = participant.weight;
            participant_idx = i;
            found = true;
            break
        };
        i = i + 1;
    };
    assert!(found, ENotParticipant);
    
    // Now update the participant after the immutable borrow is done
    let p_mut = vector::borrow_mut(&mut proposal.participants, participant_idx);
    p_mut.locked = true;
    proposal.locked_weight = proposal.locked_weight + participant_weight;
    
    // Update state based on locked weight
    if (proposal.locked_weight >= proposal.threshold) {
        proposal.state = STATE_READY;
    } else if (proposal.locked_weight > 0) {
        proposal.state = STATE_PARTIALLY_LOCKED;
    };
}

#[test_only]
public fun is_expired(proposal: &CrossDaoProposal, clock: &Clock): bool {
    clock::timestamp_ms(clock) > proposal.commit_deadline
}

#[test_only]
public fun can_execute(proposal: &CrossDaoProposal, _clock: &Clock): bool {
    proposal.state == STATE_READY
}

#[test_only]
public fun mark_ready_for_execution(
    registry: &mut CrossDaoProposalRegistry,
    proposal_id: ID,
    _clock: &Clock,
    _ctx: &mut TxContext,
) {
    let proposal = table::borrow_mut(&mut registry.proposals, proposal_id);
    assert!(proposal.state == STATE_READY, EInvalidState);
    proposal.state = STATE_COMMITTED;
}

#[test_only]
public fun create_admin_cap(
    proposal_id: ID,
    ctx: &mut TxContext,
): ProposalAdminCap {
    ProposalAdminCap {
        id: object::new(ctx),
        proposal_id,
    }
}

#[test_only]
public fun admin_veto(
    registry: &mut CrossDaoProposalRegistry,
    proposal_id: ID,
    admin_cap: &ProposalAdminCap,
    ctx: &mut TxContext,
) {
    let proposal = table::remove(&mut registry.proposals, proposal_id);
    let CrossDaoProposal { id, state: _, participants: _, locked_weight: _, threshold: _, commit_deadline: _, title: _, description: _ } = proposal;
    object::delete(id);
}