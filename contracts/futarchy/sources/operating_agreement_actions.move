module futarchy::operating_agreement_actions;

use std::string::String;
use sui::{
    table::{Self, Table},
    event,
    clock::Clock,
};
use futarchy::{
    proposal::Proposal,
    operating_agreement::{Self, OperatingAgreement},
};


// === Errors ===
const EActionsAlreadyStored: u64 = 0;
const ENoActionsFound: u64 = 1;
const EAlreadyExecuted: u64 = 2;
const EInvalidOutcome: u64 = 3;
const EThresholdNotMet: u64 = 4;
const EProposalNotResolved: u64 = 5;
const ERejectOutcomeNoAction: u64 = 7;

// === Constants ===
const BASIS_POINTS: u256 = 100_000;

// === Structs ===

/// Registry to store actions for operating agreement proposals.
public struct ActionRegistry has key {
    id: UID,
    // Maps proposal_id -> The action for the "Accept" outcome.
    actions: Table<ID, UpdateLineAction>,
    // Tracks execution status: proposal_id -> executed
    executed: Table<ID, bool>,
}

/// The action to update a line in the operating agreement.
public struct UpdateLineAction has store, copy, drop {
    line_id: ID,
    new_text: String,
}

/// Creates a new UpdateLineAction
public fun new_update_line_action(line_id: ID, new_text: String): UpdateLineAction {
    UpdateLineAction { line_id, new_text }
}

// === Events ===
public struct OperatingAgreementUpdateExecuted has copy, drop {
    dao_id: ID,
    proposal_id: ID,
    line_id: ID,
    timestamp: u64,
}

// === Public Functions ===

/// Create the action registry (called once at package init).
public fun create_registry(ctx: &mut TxContext) {
    let registry = ActionRegistry {
        id: object::new(ctx),
        actions: table::new(ctx),
        executed: table::new(ctx),
    };
    transfer::share_object(registry);
}

/// Initialize storage for a new proposal's action.
public fun init_proposal_action(
    registry: &mut ActionRegistry,
    proposal_id: ID,
    action: UpdateLineAction,
) {
    assert!(!registry.actions.contains(proposal_id), EActionsAlreadyStored);
    registry.actions.add(proposal_id, action);
    registry.executed.add(proposal_id, false);
}


/// Executes the update if the proposal passed and meets the specific difficulty threshold.
public entry fun execute_update<AssetType, StableType>(
    registry: &mut ActionRegistry,
    proposal: &Proposal<AssetType, StableType>,
    agreement: &mut OperatingAgreement,
    clock: &Clock,
) {
    let proposal_id = proposal.get_id();

    // 1. Verify proposal is finalized and not yet executed here.
    assert!(proposal.is_finalized(), EProposalNotResolved);
    assert!(registry.actions.contains(proposal_id), ENoActionsFound);
    assert!(!*registry.executed.borrow(proposal_id), EAlreadyExecuted);

    // 2. Get the winning outcome from the proposal object.
    let winning_outcome = proposal.get_winning_outcome();

    // 3. If the winning outcome is "Reject" (0), do nothing but mark as executed.
    if (winning_outcome == 0) {
        *registry.executed.borrow_mut(proposal_id) = true;
        return
    };

    // 4. If outcome is "Accept" (1), perform the special difficulty check.
    assert!(winning_outcome == 1, ERejectOutcomeNoAction);

    // Get the stored action for this proposal.
    let action = registry.actions.borrow(proposal_id);
    let line_id = action.line_id;

    // Get the required difficulty from the agreement itself.
    let difficulty = operating_agreement::get_difficulty(agreement, line_id);

    // Get the final TWAP prices from the resolved proposal.
    let twaps = proposal.get_twap_prices();
    let twap_reject = *twaps.borrow(0);
    let twap_accept = *twaps.borrow(1);

    // 5. THE SPECIAL CHECK: Verify the accept price beat the reject price by the required difficulty margin.
    // The formula is: accept_price > reject_price * (1 + difficulty_in_basis_points / 100000)
    // To avoid floating point, we use: accept_price * 100000 > reject_price * (100000 + difficulty)
    let accept_val = (twap_accept as u256) * BASIS_POINTS;
    let required_reject_val = (twap_reject as u256) * (BASIS_POINTS + (difficulty as u256));

    assert!(accept_val > required_reject_val, EThresholdNotMet);

    // 6. If the check passes, execute the update.
    operating_agreement::update_line(agreement, line_id, action.new_text);

    // 7. Mark as executed to prevent replay.
    *registry.executed.borrow_mut(proposal_id) = true;

    event::emit(OperatingAgreementUpdateExecuted {
        dao_id: operating_agreement::get_dao_id(agreement),
        proposal_id,
        line_id,
        timestamp: clock.timestamp_ms(),
    });
}