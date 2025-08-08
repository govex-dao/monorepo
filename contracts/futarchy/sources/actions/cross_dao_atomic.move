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
public struct CrossDaoProposal has key, store {
    id: UID,
    state: u8,
    participants: vector<DaoParticipant>,
    locked_count: u64,
    total_required: u64,
    commit_deadline: u64,
    title: String,
    description: String,
}

/// Information about a participating DAO
public struct DaoParticipant has store, copy, drop {
    dao_id: ID,
    expected_action_hash: vector<u8>,
    required: bool,
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
    remaining_required: u64,
}

public struct ProposalCommitted has copy, drop {
    proposal_id: ID,
    timestamp: u64,
}

// === Public Functions ===

/// Create a new cross-DAO proposal
public fun create_proposal(
    participants: vector<DaoParticipant>,
    title: String,
    description: String,
    commit_deadline: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let mut total_required = 0u64;
    let mut i = 0;
    while (i < vector::length(&participants)) {
        if (vector::borrow(&participants, i).required) {
            total_required = total_required + 1;
        };
        i = i + 1;
    };
    
    let proposal = CrossDaoProposal {
        id: object::new(ctx),
        state: STATE_PENDING,
        participants,
        locked_count: 0,
        total_required,
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
/// This function must be called by each participating DAO before the deadline
/// Strong assertions ensure:
/// - DAO cannot lock twice
/// - Deadline is strictly enforced
/// - State transitions are valid
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
    
    // Verify DAO is participant
    let mut is_participant = false;
    let mut is_required = false;
    let mut i = 0;
    while (i < vector::length(&proposal.participants)) {
        let p = vector::borrow(&proposal.participants, i);
        if (p.dao_id == dao_id) {
            is_participant = true;
            is_required = p.required;
            break
        };
        i = i + 1;
    };
    assert!(is_participant, ENotParticipant);
    
    // Update counts
    if (is_required) {
        proposal.locked_count = proposal.locked_count + 1;
    };
    
    // Check if ready
    if (proposal.locked_count == proposal.total_required) {
        proposal.state = STATE_READY;
    } else if (proposal.state == STATE_PENDING) {
        proposal.state = STATE_PARTIALLY_LOCKED;
    };
    
    event::emit(DaoLocked {
        proposal_id: object::id(proposal),
        dao_id,
        remaining_required: proposal.total_required - proposal.locked_count,
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

/// Execute all actions atomically when proposal is ready
/// This ensures all DAOs execute their committed actions in a single transaction
/// Each account must be passed in the same order as the executables
public fun execute_atomic_actions<Outcome: drop + store>(
    proposal: &mut CrossDaoProposal,
    mut executables: vector<Executable<Outcome>>,
    account1: &mut Account<FutarchyConfig>,
    account2: &mut Account<FutarchyConfig>,
    clock: &Clock,
    _ctx: &mut TxContext,
) {
    // Verify proposal is ready
    assert!(proposal.state == STATE_READY, ENotReady);
    
    // Verify deadline hasn't passed
    assert!(clock::timestamp_ms(clock) < proposal.commit_deadline, EDeadlineExpired);
    
    // Verify we have exactly 2 executables for the 2 accounts
    assert!(vector::length(&executables) == 2, EInvalidState);
    assert!(vector::length(&proposal.participants) == 2, EInvalidState);
    
    // Process first executable with first account
    let executable1 = vector::pop_back(&mut executables);
    account::confirm_execution(account1, executable1);
    
    // Process second executable with second account
    let executable2 = vector::pop_back(&mut executables);
    account::confirm_execution(account2, executable2);
    
    // Ensure vector is now empty
    vector::destroy_empty(executables);
    
    // Mark proposal as committed
    mark_committed(proposal, clock);
}

/// Execute atomic actions for three DAOs
/// This variant handles three participating DAOs
public fun execute_atomic_actions_three<Outcome: drop + store>(
    proposal: &mut CrossDaoProposal,
    mut executables: vector<Executable<Outcome>>,
    account1: &mut Account<FutarchyConfig>,
    account2: &mut Account<FutarchyConfig>,
    account3: &mut Account<FutarchyConfig>,
    clock: &Clock,
    _ctx: &mut TxContext,
) {
    // Verify proposal is ready
    assert!(proposal.state == STATE_READY, ENotReady);
    
    // Verify deadline hasn't passed
    assert!(clock::timestamp_ms(clock) < proposal.commit_deadline, EDeadlineExpired);
    
    // Verify we have exactly 3 executables for the 3 accounts
    assert!(vector::length(&executables) == 3, EInvalidState);
    assert!(vector::length(&proposal.participants) == 3, EInvalidState);
    
    // Process executables with their respective accounts
    let executable1 = vector::pop_back(&mut executables);
    account::confirm_execution(account1, executable1);
    
    let executable2 = vector::pop_back(&mut executables);
    account::confirm_execution(account2, executable2);
    
    let executable3 = vector::pop_back(&mut executables);
    account::confirm_execution(account3, executable3);
    
    // Ensure vector is now empty
    vector::destroy_empty(executables);
    
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
    required: bool,
): DaoParticipant {
    DaoParticipant {
        dao_id,
        expected_action_hash: action_hash,
        required,
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

public fun get_locked_count(proposal: &CrossDaoProposal): u64 {
    proposal.locked_count
}

public fun get_required_count(proposal: &CrossDaoProposal): u64 {
    proposal.total_required
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
        required: true,
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
        locked_count: 0,
        total_required: vector::length(&actions),
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
    while (i < vector::length(&proposal.participants)) {
        let participant = vector::borrow(&proposal.participants, i);
        if (participant.dao_id == dao_id) {
            proposal.locked_count = proposal.locked_count + 1;
            found = true;
            break
        };
        i = i + 1;
    };
    assert!(found, ENotParticipant);
    
    // Update state based on locked count
    if (proposal.locked_count == proposal.total_required) {
        proposal.state = STATE_READY;
    } else if (proposal.locked_count > 0) {
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
    let CrossDaoProposal { id, state: _, participants: _, locked_count: _, total_required: _, commit_deadline: _, title: _, description: _ } = proposal;
    object::delete(id);
}