module futarchy::execution_dispatcher;

use sui::object::{Self, ID};
use sui::tx_context::TxContext;
use sui::clock::{Self, Clock};

use futarchy::{
    action_registry::{Self, ActionRegistry},
    dao_state::DAO,
    dao::{Self},
    execution_context::{Self, ProposalExecutionContext},
    coin_escrow::{Self, TokenEscrow},
    market_state,
};

// === Errors ===
const E_PROPOSAL_NOT_FOUND: u64 = 0;
const E_PROPOSAL_NOT_EXECUTED: u64 = 1;
const E_ALREADY_FINALIZED: u64 = 2;

// === Public Entry Functions ===

/// Create the execution context for a proposal
/// This should be called once at the beginning of the PTB execution
public fun create_execution_context<AssetType, StableType>(
    dao: &DAO<AssetType, StableType>,
    escrow: &TokenEscrow<AssetType, StableType>,
    proposal_id: ID,
    clock: &Clock,
    ctx: &mut TxContext,
): ProposalExecutionContext {
    // Verify proposal exists and has been executed
    let proposal_info = dao::get_proposal_info(dao, proposal_id);
    assert!(dao::is_executed(proposal_info), E_PROPOSAL_NOT_EXECUTED);
    
    // Get winning outcome from market state
    let market_state = coin_escrow::get_market_state(escrow);
    let winning_outcome = market_state::get_winning_outcome(market_state);
    
    // Create execution context
    execution_context::new(
        proposal_id,
        object::id(dao),
        winning_outcome,
        clock::timestamp_ms(clock),
        ctx
    )
}

/// This function MUST be the final call in any proposal execution PTB.
/// It verifies that the proposal was not already executed and then marks it
/// as complete to prevent any replay attacks.
public fun finalize_execution<AssetType, StableType>(
    registry: &mut ActionRegistry,
    dao: &DAO<AssetType, StableType>,
    context: ProposalExecutionContext,
    _clock: &Clock,
    _ctx: &mut TxContext,
) {
    let proposal_id = execution_context::proposal_id(&context);
    
    // Verify proposal exists in DAO
    let proposal_info = dao::get_proposal_info(dao, proposal_id);
    assert!(dao::is_executed(proposal_info), E_PROPOSAL_NOT_EXECUTED);
    
    // Verify not already finalized
    assert!(!action_registry::is_executed(registry, proposal_id), E_ALREADY_FINALIZED);
    
    // Mark as executed in the registry
    action_registry::mark_as_executed(registry, proposal_id);
    
    // Destroy the execution context
    execution_context::destroy(context);
}

/// Get the action sequence for a winning outcome
/// This is a convenience view function for off-chain clients
public fun get_winning_actions<AssetType, StableType>(
    registry: &ActionRegistry,
    dao: &DAO<AssetType, StableType>,
    escrow: &TokenEscrow<AssetType, StableType>,
    proposal_id: ID,
): &vector<action_registry::Action> {
    // Verify proposal has been executed
    let proposal_info = dao::get_proposal_info(dao, proposal_id);
    assert!(dao::is_executed(proposal_info), E_PROPOSAL_NOT_EXECUTED);
    
    // Get winning outcome
    let market_state = coin_escrow::get_market_state(escrow);
    let winning_outcome = market_state::get_winning_outcome(market_state);
    
    // Get and return the action sequence
    action_registry::get_action_sequence(registry, proposal_id, winning_outcome)
}

/// Check if a proposal's actions have been finalized
public fun is_finalized(
    registry: &ActionRegistry,
    proposal_id: ID,
): bool {
    action_registry::is_executed(registry, proposal_id)
}

/// Verify that a proposal can be executed
/// Returns (can_execute, winning_outcome)
public fun can_execute_proposal<AssetType, StableType>(
    dao: &DAO<AssetType, StableType>,
    escrow: &TokenEscrow<AssetType, StableType>,
    registry: &ActionRegistry,
    proposal_id: ID,
): (bool, u64) {
    // Check if proposal exists
    let proposal_info = dao::get_proposal_info(dao, proposal_id);
    if (!dao::is_executed(proposal_info)) {
        return (false, 0)
    };
    
    // Check if already finalized
    if (action_registry::is_executed(registry, proposal_id)) {
        return (false, 0)
    };
    
    // Check if actions exist for this proposal
    if (!action_registry::has_actions(registry, proposal_id)) {
        return (false, 0)
    };
    
    // Get winning outcome
    let market_state = coin_escrow::get_market_state(escrow);
    let winning_outcome = market_state::get_winning_outcome(market_state);
    
    (true, winning_outcome)
}