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
const ACTION_UPDATE: u8 = 0;
const ACTION_INSERT_AFTER: u8 = 1;
const ACTION_INSERT_AT_BEGINNING: u8 = 2;
const ACTION_REMOVE: u8 = 3;
// BASIS_POINTS is used in difficulty calculations to avoid precision loss
// Maximum difficulty is expected to be less than u64::MAX, so BASIS_POINTS + difficulty cannot overflow
const BASIS_POINTS: u256 = 100_000;

// === Structs ===

/// Registry to store actions for operating agreement proposals.
public struct ActionRegistry has key {
    id: UID,
    // Maps proposal_id -> A vector of actions for the "Accept" outcome.
    actions: Table<ID, vector<Action>>,
    // Tracks execution status: proposal_id -> executed
    executed: Table<ID, bool>,
}

/// Represents a single atomic change within a proposal.
public struct Action has store, copy, drop {
    action_type: u8, // 0 for Update, 1 for Insert After, 2 for Insert At Beginning, 3 for Remove
    // Only fields relevant to the action_type will be populated.
    line_id: Option<ID>, // Used for Update, Remove, and as the *previous* line for Insert After
    text: Option<String>, // Used for Update and Insert operations
    difficulty: Option<u64>, // Used for Insert operations
}

/// Creates a new update action
public fun new_update_action(line_id: ID, new_text: String): Action {
    Action { 
        action_type: ACTION_UPDATE,
        line_id: option::some(line_id), 
        text: option::some(new_text),
        difficulty: option::none(),
    }
}

/// Creates a new insert after action
public fun new_insert_after_action(prev_line_id: ID, text: String, difficulty: u64): Action {
    Action { 
        action_type: ACTION_INSERT_AFTER,
        line_id: option::some(prev_line_id), 
        text: option::some(text),
        difficulty: option::some(difficulty),
    }
}

/// Creates a new insert at beginning action
public fun new_insert_at_beginning_action(text: String, difficulty: u64): Action {
    Action { 
        action_type: ACTION_INSERT_AT_BEGINNING,
        line_id: option::none(), 
        text: option::some(text),
        difficulty: option::some(difficulty),
    }
}

/// Creates a new remove action
public fun new_remove_action(line_id: ID): Action {
    Action { 
        action_type: ACTION_REMOVE,
        line_id: option::some(line_id), 
        text: option::none(),
        difficulty: option::none(),
    }
}

// === Events ===
public struct OperatingAgreementActionsExecuted has copy, drop {
    dao_id: ID,
    proposal_id: ID,
    action_count: u64,
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

/// Initialize storage for a new proposal's actions.
public fun init_proposal_actions(
    registry: &mut ActionRegistry,
    proposal_id: ID,
    actions_batch: vector<Action>,
) {
    assert!(!registry.actions.contains(proposal_id), EActionsAlreadyStored);
    registry.actions.add(proposal_id, actions_batch);
    registry.executed.add(proposal_id, false);
}


/// Executes the actions if the proposal passed and meets the specific difficulty threshold.
public entry fun execute_actions<AssetType, StableType>(
    registry: &mut ActionRegistry,
    proposal: &Proposal<AssetType, StableType>,
    agreement: &mut OperatingAgreement,
    clock: &Clock,
    ctx: &mut TxContext,
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

    // 4. If outcome is "Accept" (1), perform the special difficulty check for the entire batch.
    // The entire proposal must clear the bar set by the single most difficult action in the batch.
    assert!(winning_outcome == 1, ERejectOutcomeNoAction);

    // === PHASE 1: FIND THE HIGHEST DIFFICULTY IN THE BATCH ===
    let actions_batch = registry.actions.borrow(proposal_id);
    let mut max_difficulty_in_batch = 0;
    let mut i = 0;
    while (i < actions_batch.length()) {
        let action = actions_batch.borrow(i);
        let current_difficulty = if (action.action_type == ACTION_UPDATE || action.action_type == ACTION_REMOVE) {
            operating_agreement::get_difficulty(agreement, *action.line_id.borrow())
        } else if (action.action_type == ACTION_INSERT_AFTER) {
            // For insert after, we use the difficulty of the new line
            *action.difficulty.borrow()
        } else { // ACTION_INSERT_AT_BEGINNING
            *action.difficulty.borrow()
        };

        if (current_difficulty > max_difficulty_in_batch) {
            max_difficulty_in_batch = current_difficulty;
        };
        i = i + 1;
    };

    // === PHASE 2: PERFORM THE ATOMIC CHECK AGAINST THE HIGHEST DIFFICULTY ===
    // Get the final TWAP prices from the resolved proposal.
    let twaps = proposal.get_twap_prices();
    let twap_reject = *twaps.borrow(0);
    let twap_accept = *twaps.borrow(1);

    // Calculate with overflow protection
    let accept_val = (twap_accept as u256) * BASIS_POINTS;
    let difficulty_256 = (max_difficulty_in_batch as u256);
    // Ensure difficulty doesn't cause overflow (should be much less than u256::MAX - BASIS_POINTS)
    assert!(difficulty_256 < (std::u256::max_value!() - BASIS_POINTS), EThresholdNotMet);
    let required_reject_val = (twap_reject as u256) * (BASIS_POINTS + difficulty_256);
    assert!(accept_val > required_reject_val, EThresholdNotMet);

    // === PHASE 3: EXECUTE ALL ACTIONS IN THE BATCH ===
    // This only runs if the atomic check above passes.
    i = 0;
    while (i < actions_batch.length()) {
        let action = actions_batch.borrow(i);
        if (action.action_type == ACTION_UPDATE) {
            operating_agreement::update_line(
                agreement,
                *action.line_id.borrow(),
                *action.text.borrow()
            );
        } else if (action.action_type == ACTION_INSERT_AFTER) {
            let _new_id = operating_agreement::insert_line_after(
                agreement,
                *action.line_id.borrow(), // This ID is the 'previous line' to insert after
                *action.text.borrow(),
                *action.difficulty.borrow(),
                ctx
            );
        } else if (action.action_type == ACTION_INSERT_AT_BEGINNING) {
            let _new_id = operating_agreement::insert_line_at_beginning(
                agreement,
                *action.text.borrow(),
                *action.difficulty.borrow(),
                ctx
            );
        } else { // ACTION_REMOVE
            operating_agreement::remove_line(agreement, *action.line_id.borrow());
        };
        i = i + 1;
    };

    // Mark as executed to prevent replay.
    *registry.executed.borrow_mut(proposal_id) = true;

    event::emit(OperatingAgreementActionsExecuted {
        dao_id: operating_agreement::get_dao_id(agreement),
        proposal_id,
        action_count: actions_batch.length(),
        timestamp: clock.timestamp_ms(),
    });

    // Atomically emit the new, full state of the agreement for indexers.
    operating_agreement::emit_current_state_event(agreement, clock);
}