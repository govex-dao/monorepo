/// DEPRECATED: PTB-based execution pattern for Futarchy proposals
///
/// ⚠️ THIS MODULE IS DEPRECATED AND NON-FUNCTIONAL ⚠️
///
/// This module is broken and should not be used. The execution pattern it implements
/// is incompatible with the current system architecture:
///
/// Problems:
/// 1. Expects old intent key system, but proposals now store IntentSpec directly
/// 2. Execution tracking stubs (is_executed, mark_executed, intent_key) have been removed
/// 3. account::create_executable() requires an intent key that doesn't exist in modern proposals
///
/// Modern Execution Pattern:
/// Proposals now use governance_intents::execute_proposal_intent() which:
/// - Reads IntentSpec directly from proposal
/// - Converts IntentSpec to Intent and Executable in one step
/// - Doesn't need separate intent key storage
/// - Tracks execution via off-chain indexers (not on-chain state)
///
/// See futarchy_governance_actions::governance_intents.move for the correct pattern.
///
/// This module is kept for reference only. Do not use it for new development.
module futarchy_dao::ptb_executor;

use account_protocol::account::{Self, Account};
use account_protocol::executable::Executable;
use futarchy_core::futarchy_config::{Self, FutarchyConfig, FutarchyOutcome};
use futarchy_core::version;
use futarchy_dao::proposal_lifecycle;
use futarchy_markets_core::proposal::Proposal;
use sui::clock::Clock;
use sui::tx_context::TxContext;

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
        ctx,
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
