/// PTB-composable execution entry points with ExecutionContext support
/// This provides the main hot potato flow for proposal execution
module futarchy_dao::execute_ptb;

use sui::clock::Clock;
use account_protocol::account::{Self, Account};
use account_protocol::executable::{Self, Executable};
use futarchy_core::futarchy_config::{Self, FutarchyConfig};
use futarchy_core::futarchy_config::FutarchyOutcome as ProposalOutcome;
use futarchy_dao::proposal_lifecycle::{Self, Proposal};
use futarchy_utils::version;

// === Errors ===
const EProposalNotPassed: u64 = 1;
const EProposalAlreadyExecuted: u64 = 2;

// === Entry Functions ===

/// Start proposal execution - creates Executable with embedded ExecutionContext
/// Returns hot potato that must be consumed by execute_proposal_end
public fun execute_proposal_start(
    account: &mut Account<FutarchyConfig>,
    proposal: &mut Proposal,
    clock: &Clock,
    ctx: &mut TxContext,
): Executable<ProposalOutcome> {
    // Validate proposal is passed and not yet executed
    assert!(proposal_lifecycle::is_passed(proposal), EProposalNotPassed);
    assert!(!proposal_lifecycle::is_executed(proposal), EProposalAlreadyExecuted);

    // Mark proposal as executed
    proposal_lifecycle::mark_executed(proposal);

    // Get the intent key from the proposal
    let intent_key = proposal_lifecycle::intent_key(proposal);

    // Create executable with embedded context (ctx is now passed through)
    let (outcome, executable) = account::create_executable(
        account,
        intent_key,
        clock,
        version::current(),
        futarchy_config::witness(),
        ctx, // Pass ctx to create ExecutionContext inside Executable
    );

    // Validate the outcome matches what we expect
    assert!(outcome.passed, EProposalNotPassed);

    executable // Return the single, clean hot potato
}

/// Finalize proposal execution - consumes the Executable hot potato
/// The ExecutionContext is automatically cleaned up when Executable is destroyed
public fun execute_proposal_end(
    account: &mut Account<FutarchyConfig>,
    executable: Executable<ProposalOutcome>,
) {
    // Confirm execution - this will destroy the Executable and its embedded context
    account::confirm_execution(
        account,
        executable,
        version::current(),
        futarchy_config::witness(),
    );
}