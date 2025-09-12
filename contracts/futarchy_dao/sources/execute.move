/// Execution entry points for approved proposals
/// This module provides the PTB-composable entry functions for executing proposals
module futarchy_dao::execute;

use std::{string::String, option};
use sui::{transfer, tx_context};
use account_protocol::{
    account::{Self, Account},
    executable::{Self, Executable},
    intent_spec::{Self, IntentSpec},
};
use futarchy_core::futarchy_config::FutarchyConfig;
use futarchy_markets::proposal::{Self, Proposal, ProposalIntentSpec};
use futarchy_actions::intent_factory;

// === Errors ===

const EProposalNotApproved: u64 = 0;
const ENoIntentSpecForOutcome: u64 = 1;
const EProposalDaoMismatch: u64 = 2;
const EInvalidExecutable: u64 = 3;

// === Constants ===

const OUTCOME_YES: u64 = 0;
const OUTCOME_NO: u64 = 1;

// === Public Entry Functions ===

/// Start the execution of an approved proposal
/// This function converts the IntentSpec from the winning outcome into an Executable hot potato
/// The Executable is transferred to the sender to be processed by category dispatchers
public entry fun execute_proposal<AssetType, StableType>(
    account: &mut Account<FutarchyConfig>,
    proposal: &Proposal<AssetType, StableType>,
    ctx: &mut TxContext,
) {
    // Validate proposal belongs to this DAO
    assert!(proposal::dao_id(proposal) == account::id(account), EProposalDaoMismatch);
    
    // Check that the proposal was approved (YES outcome won)
    let winning_outcome = proposal::winning_outcome(proposal);
    assert!(winning_outcome == OUTCOME_YES, EProposalNotApproved);
    
    // Get the ProposalIntentSpec for the winning outcome
    let proposal_spec_opt = proposal::get_intent_spec_for_outcome(proposal, winning_outcome);
    assert!(option::is_some(proposal_spec_opt), ENoIntentSpecForOutcome);
    
    // Convert ProposalIntentSpec to full IntentSpec (creates new UID)
    let proposal_spec_ref = option::borrow(proposal_spec_opt);
    let intent_spec = proposal::proposal_spec_to_intent_spec(proposal_spec_ref, ctx);
    
    // Convert the IntentSpec into an Executable hot potato
    let executable = intent_factory::create_executable_from_spec(
        account,
        &intent_spec,
        ctx,
    );
    
    // Clean up the IntentSpec since we're done with it
    intent_spec::destroy_intent_spec(intent_spec);
    
    // Transfer the Executable to the sender
    // The sender will then pass it through the appropriate category dispatchers
    transfer::public_transfer(executable, tx_context::sender(ctx));
}

/// Finalize the execution after all dispatchers have processed the Executable
/// This function confirms the execution
public entry fun execute_finalize<Outcome: store>(
    executable: Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    ctx: &mut TxContext,
) {
    // Validate the executable is for this account
    // Note: executable doesn't have a direct account_id field, but confirm_execution will validate
    
    // Confirm the execution
    account::confirm_execution(account, executable);
    
    // Note: Garbage collection of expired intents should be handled separately
    // One-shot intents are automatically consumed during execution
    // Recurring intents remain until explicitly destroyed or expired
}

/// Alternative entry point for optimistic proposals
/// Converts an OptimisticProposal's IntentSpec into an Executable
public entry fun execute_optimistic_proposal(
    account: &mut Account<FutarchyConfig>,
    optimistic_spec: &IntentSpec,
    ctx: &mut TxContext,
) {
    // Convert the IntentSpec into an Executable hot potato
    let executable = intent_factory::create_executable_from_spec(
        account,
        optimistic_spec,
        ctx,
    );
    
    // Transfer the Executable to the sender
    transfer::public_transfer(executable, tx_context::sender(ctx));
}