/// PTB-composable execution entry points for proposal execution
/// This provides the main hot potato flow pattern
module futarchy_dao::execute_ptb;

use sui::clock::Clock;
use account_protocol::account::{Self, Account};
use account_protocol::executable::{Self, Executable};
use futarchy_core::futarchy_config::{Self, FutarchyConfig};
use futarchy_core::futarchy_config::FutarchyOutcome as ProposalOutcome;
use futarchy_dao::proposal_lifecycle::{Self};
use futarchy_markets::proposal::Proposal;
use futarchy_core::version;

// === Errors ===
const EProposalNotPassed: u64 = 1;
const EProposalAlreadyExecuted: u64 = 2;
const ENotAllActionsExecuted: u64 = 3;

// === Entry Functions ===

/// Start proposal execution - creates Executable hot potato
/// Must be consumed by execute_proposal_end after all actions
public fun execute_proposal_start<AssetType, StableType>(
    account: &mut Account<FutarchyConfig>,
    proposal: &mut Proposal<AssetType, StableType>,
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

    // Create executable from the account's stored intent
    let (outcome, executable) = account::create_executable(
        account,
        intent_key,
        clock,
        version::current(),
        futarchy_config::witness(),
        ctx
    );

    // No need to validate outcome.passed since we control it

    executable // Return the single, clean hot potato
}

/// Finalize proposal execution - consumes the Executable hot potato
/// CRITICAL: This function MUST verify that all actions in the proposal were executed
public fun execute_proposal_end(
    account: &mut Account<FutarchyConfig>,
    executable: Executable<ProposalOutcome>,
) {
    // Confirm execution - this will destroy the Executable
    // The account::confirm_execution function only takes 2 arguments
    account::confirm_execution(
        account,
        executable,
    );
}