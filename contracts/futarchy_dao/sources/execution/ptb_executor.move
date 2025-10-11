/// PTB-based execution pattern for Futarchy proposals
/// Replaces the monolithic dispatcher with direct PTB calls to action modules
module futarchy_dao::ptb_executor;

// === Imports ===
use account_protocol::{
    account::{Self, Account},
    executable::Executable,
};
use futarchy_core::{
    futarchy_config::{Self, FutarchyConfig, FutarchyOutcome},
    version
};
use futarchy_dao::proposal_lifecycle;
use futarchy_markets::proposal::Proposal;
use sui::{
    clock::Clock,
    tx_context::TxContext,
};

// === Errors ===
const EProposalNotPassed: u64 = 1;
const EProposalAlreadyExecuted: u64 = 2;

// === Entry Functions for PTB Composition ===

/// Create an Executable from an approved proposal
/// This is the first call in a PTB execution chain
/// Validates proposal state and marks it as executed
public fun create_executable_from_proposal<AssetType, StableType>(
    account: &mut Account<FutarchyConfig>,
    proposal: &mut Proposal<AssetType, StableType>,
    clock: &Clock,
    ctx: &mut TxContext,
): Executable<FutarchyOutcome> {
    // Validate proposal is passed and not yet executed
    assert!(proposal_lifecycle::is_passed(proposal), EProposalNotPassed);
    assert!(!proposal_lifecycle::is_executed(proposal), EProposalAlreadyExecuted);

    // Mark proposal as executed
    proposal_lifecycle::mark_executed(proposal);

    // Get the intent key from the proposal
    let intent_key = proposal_lifecycle::intent_key(proposal);

    // Create executable from the account's stored intent
    let (_, executable) = account::create_executable(
        account,
        intent_key,
        clock,
        version::current(),
        futarchy_config::witness(),
        ctx
    );

    executable
}

/// Finalize execution and cleanup
/// This is the last call in a PTB execution chain
/// Consumes the Executable hot potato
public fun finalize_execution(
    account: &mut Account<FutarchyConfig>,
    executable: Executable<FutarchyOutcome>,
) {
    // Confirm execution - this will destroy the Executable
    account::confirm_execution(
        account,
        executable,
    );
}

// === Example PTB Execution Pattern ===
//
// The frontend/client would compose a PTB like this:
// ```typescript
// const tx = new TransactionBlock();
//
// // Step 1: Create executable (validates and marks proposal as executed)
// const executable = tx.moveCall({
//     target: `${package}::ptb_executor::create_executable_from_proposal`,
//     arguments: [account, proposal, clock],
//     typeArguments: [AssetType, StableType],
// });
//
// // Step 2: Execute each action by calling the appropriate do_* function
// // The specific calls depend on the actions in the proposal
//
// // For config update:
// tx.moveCall({
//     target: `${package}::config_actions::do_update_name`,
//     arguments: [executable, account, newName],
// });
//
// // For liquidity operation:
// tx.moveCall({
//     target: `${package}::liquidity_actions::do_add_liquidity`,
//     arguments: [executable, account, pool, amount],
// });
//
// // Step 3: Finalize (consumes executable hot potato)
// tx.moveCall({
//     target: `${package}::ptb_executor::finalize_execution`,
//     arguments: [account, executable],
// });
//
// await client.signAndExecuteTransactionBlock({ transactionBlock: tx });
// ```