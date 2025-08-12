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
use futarchy::{futarchy_config::FutarchyConfig, weighted_multisig::{WeightedMultisig, Approvals}, coexec_common};

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

/// Typed manifest entry describing a participant's action plan.
public struct ManifestEntry has store, copy, drop {
    dao_id: ID,
    package_addr: address,
    module_name: String,
    action_type: String,
    note: String,
}

/// Typed manifest that all participants must match exactly.
public struct CrossDaoManifest has store, copy, drop {
    title: String,
    description: String,
    entries: vector<ManifestEntry>,
}

/// Participants must attach the exact manifest in their lock intent (first action).
public struct AttachManifestAction has store {
    manifest: CrossDaoManifest,
}

/// Then lock to the proposal (second action).
public struct LockForCrossDaoCommit has store {
    cross_dao_proposal_id: ID,
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
    /// Canonical typed manifest that must match exactly for all participants.
    manifest: CrossDaoManifest,
}

/// Information about a participating DAO
public struct DaoParticipant has store, copy, drop {
    dao_id: ID,
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
    threshold: u64,  // How many DAOs must approve
    title: String,
    description: String,
    commit_deadline: u64,
    manifest: CrossDaoManifest,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let mut participants = vector::empty<DaoParticipant>();
    let mut i = 0;
    while (i < vector::length(&dao_ids)) {
        vector::push_back(&mut participants, DaoParticipant {
            dao_id: *vector::borrow(&dao_ids, i),
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
        manifest,
        clock,
        ctx
    );
}


// === Public Functions ===

/// Create a new cross-DAO proposal with M-of-N threshold
/// threshold: minimum weight needed to proceed (e.g., 3 for 3-of-5)
/// participants: list of DAOs with their voting weights
/// 
/// IMPORTANT: The order of participants MUST match the order of manifest.entries exactly.
/// This canonical ordering is enforced and must not change throughout the proposal lifecycle.
public fun create_proposal(
    participants: vector<DaoParticipant>,
    threshold: u64,  // Minimum weight needed to proceed
    title: String,
    description: String,
    commit_deadline: u64,
    manifest: CrossDaoManifest,
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
    
    // Exact participant/manifest alignment
    assert!(vector::length(&participants) == vector::length(&manifest.entries), EInvalidState);
    {
        let mut i = 0;
        while (i < vector::length(&participants)) {
            let p = vector::borrow(&participants, i);
            let e = vector::borrow(&manifest.entries, i);
            assert!(p.dao_id == e.dao_id, EInvalidState);
            i = i + 1;
        };
    };
    
    let proposal = CrossDaoProposal {
        id: object::new(ctx),
        state: STATE_PENDING,
        participants,
        locked_weight: 0,
        threshold,
        commit_deadline,
        title,
        description,
        manifest,
    };
    
    event::emit(ProposalCreated {
        proposal_id: object::id(&proposal),
        participant_count: vector::length(&proposal.participants),
        title: proposal.title,
    });
    
    transfer::share_object(proposal);
}

/// Manifest equality helpers (exact matching).
fun eq_entry(a: &ManifestEntry, b: &ManifestEntry): bool {
    a.dao_id == b.dao_id &&
    a.package_addr == b.package_addr &&
    a.module_name == b.module_name &&
    a.action_type == b.action_type &&
    a.note == b.note
}

fun eq_manifest(a: &CrossDaoManifest, b: &CrossDaoManifest): bool {
    if (!(a.title == b.title && a.description == b.description)) return false;
    if (vector::length(&a.entries) != vector::length(&b.entries)) return false;
    let mut i = 0;
    while (i < vector::length(&a.entries)) {
        if (!eq_entry(vector::borrow(&a.entries, i), vector::borrow(&b.entries, i))) return false;
        i = i + 1;
    };
    true
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

/// Lock intent must contain two actions in order:
/// 1) AttachManifestAction { manifest }
/// 2) LockForCrossDaoCommit { cross_dao_proposal_id, lock_expiry }
/// This function marks the DAO as locked and confirms the executable.
public fun execute_lock_action<Outcome: drop + store, IW: drop + copy>(
    mut executable: Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    proposal: &mut CrossDaoProposal,
    witness: IW,
    clock: &Clock,
) {
    // 1) Manifest must match canonical proposal manifest.
    let attach: &AttachManifestAction = executable.next_action(witness);
    assert!(eq_manifest(&attach.manifest, &proposal.manifest), EActionHashMismatch);
    
    // 2) Lock action and expiry
    let lock_action: &LockForCrossDaoCommit = executable.next_action(witness);
    
    // Verify the action is for this proposal
    assert!(lock_action.cross_dao_proposal_id == object::id(proposal), EActionHashMismatch);
    
    // Verify lock hasn't expired
    assert!(clock::timestamp_ms(clock) < lock_action.lock_expiry, ELockExpired);
    
    // Get the DAO ID from the account
    let dao_id = object::id(account);
    
    // Verify participant exists
    let mut participant_found = false;
    let mut i = 0;
    while (i < vector::length(&proposal.participants)) {
        let participant = vector::borrow(&proposal.participants, i);
        if (participant.dao_id == dao_id) {
            participant_found = true;
            break
        };
        i = i + 1;
    };
    
    assert!(participant_found, ENotParticipant);
    
    // Lock this DAO's commitment
    lock_dao(proposal, dao_id, clock);
    
    // Confirm the locking executable (must happen in same PTB since Executable can't be stored)
    account::confirm_execution(account, executable);
}

/// Confirm execution for a DAO+Council pair atomically
/// This ensures both the DAO and its security council approve together
public fun confirm_dao_council_pair<OutcomeD: drop + store>(
    dao: &mut Account<FutarchyConfig>,
    dao_exec: Executable<OutcomeD>,
    council: &mut Account<WeightedMultisig>,
    council_exec: Executable<Approvals>,
) {
    coexec_common::confirm_both_executables(dao, council, dao_exec, council_exec);
}

/// Execute actions for all locked DAOs atomically when proposal is ready.
/// This is a generic function that handles any number of locked participants.
/// Accounts and executables must be provided in matching order corresponding to locked participants.
/// 
/// IMPORTANT: Before calling this function in the same PTB, you should:
/// 1. Execute each DAO's actual actions (e.g., via futarchy::action_dispatcher)
/// 2. Then call this function to confirm all executables atomically (all-or-nothing)
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
    // Requirements: participants' action flows should already have been executed
    // (via your normal dispatchers) in the same PTB(s) before confirm_execution,
    // or be empty by design. Here we only confirm in lockstep for atomicity.
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

/// Create a lock action (no hashes).
public fun create_lock_action(
    proposal_id: ID,
    lock_expiry: u64,
): LockForCrossDaoCommit {
    LockForCrossDaoCommit {
        cross_dao_proposal_id: proposal_id,
        lock_expiry,
    }
}

/// Create a participant
public fun create_participant(
    dao_id: ID,
    weight: u64,
): DaoParticipant {
    DaoParticipant {
        dao_id,
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
): bool {
    let mut i = 0;
    while (i < vector::length(&proposal.participants)) {
        let participant = vector::borrow(&proposal.participants, i);
        if (participant.dao_id == dao_id) {
            return true
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


public fun get_lock_expiry(action: &LockForCrossDaoCommit): u64 {
    action.lock_expiry
}

/// View helper to get the canonical manifest from a proposal
public fun get_manifest(proposal: &CrossDaoProposal): &CrossDaoManifest {
    &proposal.manifest
}

/// Helpers to build manifests (optional)
public fun new_manifest_entry(
    dao_id: ID,
    package_addr: address,
    module_name: String,
    action_type: String,
    note: String,
): ManifestEntry {
    ManifestEntry { dao_id, package_addr, module_name, action_type, note }
}

public fun new_manifest(
    title: String,
    description: String,
    entries: vector<ManifestEntry>,
): CrossDaoManifest {
    CrossDaoManifest { title, description, entries }
}

/// Create an attach manifest action
public fun create_attach_manifest_action(
    manifest: CrossDaoManifest,
): AttachManifestAction {
    AttachManifestAction { manifest }
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
    dao_id: ID,
): DaoParticipant {
    DaoParticipant {
        dao_id,
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
    // Create a simple test manifest
    let mut manifest_entries = vector::empty<ManifestEntry>();
    let mut i = 0;
    while (i < vector::length(&actions)) {
        let participant = vector::borrow(&actions, i);
        vector::push_back(&mut manifest_entries, ManifestEntry {
            dao_id: participant.dao_id,
            package_addr: @0x0,
            module_name: string::utf8(b"test_module"),
            action_type: string::utf8(b"test_action"),
            note: string::utf8(b"test"),
        });
        i = i + 1;
    };
    
    let manifest = CrossDaoManifest {
        title,
        description,
        entries: manifest_entries,
    };
    
    let proposal = CrossDaoProposal {
        id: object::new(ctx),
        state: STATE_PENDING,
        participants: actions,
        locked_weight: 0,
        threshold: vector::length(&actions), // Default to all must approve for tests
        commit_deadline: deadline,
        title,
        description,
        manifest,
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
    let CrossDaoProposal { id, state: _, participants: _, locked_weight: _, threshold: _, commit_deadline: _, title: _, description: _, manifest: _ } = proposal;
    object::delete(id);
}