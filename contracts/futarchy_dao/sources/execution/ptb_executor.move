/// PTB-based execution pattern for Futarchy proposals
/// Replaces the monolithic dispatcher with direct PTB calls to action modules
module futarchy_dao::ptb_executor;

// === Imports ===
use std::string::{Self, String};
use account_protocol::{
    account::{Self, Account},
    executable::{Self, Executable},
};
use futarchy_core::{
    futarchy_config::{Self, FutarchyConfig, FutarchyOutcome},
    version
};
use sui::{
    clock::{Self, Clock},
    tx_context::TxContext,
};

// === Entry Functions for PTB Composition ===

/// Create an Executable from an approved proposal
/// This is the first call in a PTB execution chain
public fun create_executable_from_proposal(
    account: &mut Account<FutarchyConfig>,
    proposal_id: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Executable<FutarchyOutcome> {
    // Create the intent key from proposal ID
    let mut intent_key = b"proposal_".to_string();
    intent_key.append(proposal_id.to_string());

    // Create the outcome for this proposal
    let outcome = futarchy_config::new_futarchy_outcome(
        intent_key,
        clock.timestamp_ms()
    );

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
public fun finalize_execution(
    executable: Executable<FutarchyOutcome>,
    account: &mut Account<FutarchyConfig>,
    ctx: &mut TxContext,
) {
    // Consume the executable using account's confirm_execution
    account::confirm_execution(account, executable);

    // Update account state if needed
    // Emit events, etc.
    let _ = ctx;
}

// === Example PTB Execution Pattern ===
//
// The frontend/client would compose a PTB like this:
// ```typescript
// const tx = new TransactionBlock();
//
// // Step 1: Create executable
// const executable = tx.moveCall({
//     target: `${package}::ptb_executor::create_executable_from_proposal`,
//     arguments: [account, proposalId, clock],
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
// // Step 3: Finalize
// tx.moveCall({
//     target: `${package}::ptb_executor::finalize_execution`,
//     arguments: [executable, account],
// });
//
// await client.signAndExecuteTransactionBlock({ transactionBlock: tx });
// ```