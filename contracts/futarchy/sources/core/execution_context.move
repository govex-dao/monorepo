/// Module for execution context types to avoid circular dependencies
module futarchy::execution_context;

// === Structs ===

/// A one-shot witness object that proves a proposal's outcome
/// is authorized for execution. It's created and passed by the DAO
/// and consumed by the action execution module.
public struct ProposalExecutionContext has drop {
    proposal_id: ID,
    winning_outcome: u64,
    dao_id: ID,
}

// === Public Functions ===

/// Create a new execution context
public(package) fun new(
    proposal_id: ID,
    winning_outcome: u64,
    dao_id: ID,
): ProposalExecutionContext {
    ProposalExecutionContext {
        proposal_id,
        winning_outcome,
        dao_id,
    }
}

/// Get the proposal ID from the context
public fun proposal_id(context: &ProposalExecutionContext): ID {
    context.proposal_id
}

/// Get the winning outcome from the context
public fun winning_outcome(context: &ProposalExecutionContext): u64 {
    context.winning_outcome
}

/// Get the DAO ID from the context
public fun dao_id(context: &ProposalExecutionContext): ID {
    context.dao_id
}

// === Test Functions ===

#[test_only]
public fun create_for_testing(
    proposal_id: ID,
    winning_outcome: u64,
    dao_id: ID,
): ProposalExecutionContext {
    ProposalExecutionContext {
        proposal_id,
        winning_outcome,
        dao_id,
    }
}