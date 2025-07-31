module futarchy::init_operating_agreement_actions;

use std::string::String;
use sui::{
    table::{Self, Table},
    event,
    clock::Clock,
};
use futarchy::{
    proposal::Proposal,
    dao::{Self, DAO},
};


// === Errors ===
const EActionsAlreadyStored: u64 = 0;
const ENoActionsFound: u64 = 1;
const EAlreadyExecuted: u64 = 2;
const EProposalNotResolved: u64 = 3;
const EOperatingAgreementAlreadyExists: u64 = 4;
const EProposalDAOMismatch: u64 = 5;
const EInvalidWinningOutcome: u64 = 6;

// === Structs ===

/// Registry to store actions for initializing operating agreements.
public struct InitActionRegistry has key {
    id: UID,
    // Maps proposal_id -> The action for the "Accept" outcome.
    actions: Table<ID, InitAgreementAction>,
    // Tracks execution status: proposal_id -> executed
    executed: Table<ID, bool>,
}

/// The action to initialize an operating agreement.
public struct InitAgreementAction has store, copy, drop {
    initial_lines: vector<String>,
    initial_difficulties: vector<u64>,
}

/// Creates a new InitAgreementAction
public fun new_init_agreement_action(
    initial_lines: vector<String>,
    initial_difficulties: vector<u64>
): InitAgreementAction {
    InitAgreementAction { initial_lines, initial_difficulties }
}

// === Events ===
public struct OperatingAgreementInitialized has copy, drop {
    dao_id: ID,
    proposal_id: ID,
    agreement_id: ID,
    line_count: u64,
    timestamp: u64,
}

// === Public Functions ===

/// Create the init action registry (called once at package init).
public fun create_registry(ctx: &mut TxContext) {
    let registry = InitActionRegistry {
        id: object::new(ctx),
        actions: table::new(ctx),
        executed: table::new(ctx),
    };
    transfer::share_object(registry);
}

/// Initialize storage for a new proposal's action.
public fun init_proposal_action(
    registry: &mut InitActionRegistry,
    proposal_id: ID,
    action: InitAgreementAction,
) {
    assert!(!registry.actions.contains(proposal_id), EActionsAlreadyStored);
    registry.actions.add(proposal_id, action);
    registry.executed.add(proposal_id, false);
}

/// Check if a proposal has been executed
public fun is_executed(registry: &InitActionRegistry, proposal_id: ID): bool {
    if (!registry.executed.contains(proposal_id)) return false;
    *registry.executed.borrow(proposal_id)
}


/// Executes the initialization if the proposal passed.
public entry fun execute_init<AssetType, StableType>(
    registry: &mut InitActionRegistry,
    proposal: &Proposal<AssetType, StableType>,
    dao: &mut DAO<AssetType, StableType>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let proposal_id = proposal.get_id();

    // 1. Verify proposal is finalized and not yet executed here.
    assert!(proposal.is_finalized(), EProposalNotResolved);
    assert!(registry.actions.contains(proposal_id), ENoActionsFound);
    assert!(!*registry.executed.borrow(proposal_id), EAlreadyExecuted);
    
    // 2. Verify proposal belongs to this DAO
    assert!(proposal.get_dao_id() == object::id(dao), EProposalDAOMismatch);
    
    // 3. Ensure DAO doesn't already have an operating agreement
    assert!(!dao.has_operating_agreement(), EOperatingAgreementAlreadyExists);

    // 3. Get the winning outcome from the proposal object.
    let winning_outcome = proposal.get_winning_outcome();

    // 4. If the winning outcome is "Reject" (0), do nothing but mark as executed.
    if (winning_outcome == 0) {
        *registry.executed.borrow_mut(proposal_id) = true;
        return
    };

    // 5. If outcome is "Accept" (typically 1), initialize the operating agreement
    // Note: For multi-outcome proposals, any non-zero outcome is considered acceptance
    assert!(winning_outcome > 0, EInvalidWinningOutcome);

    // Get the stored action for this proposal.
    let action = registry.actions.borrow(proposal_id);

    // 6. Initialize the operating agreement through the DAO
    let agreement_id = dao::init_operating_agreement_internal(
        dao,
        action.initial_lines,
        action.initial_difficulties,
        ctx
    );

    // 7. Mark as executed to prevent replay.
    *registry.executed.borrow_mut(proposal_id) = true;

    event::emit(OperatingAgreementInitialized {
        dao_id: object::id(dao),
        proposal_id,
        agreement_id,
        line_count: action.initial_lines.length(),
        timestamp: clock.timestamp_ms(),
    });
}