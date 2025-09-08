module futarchy_dao::execute;

use std::option::{Self, Option};
use sui::{
    clock::Clock, 
    tx_context::TxContext,
    coin::Coin,
    sui::SUI,
    object::ID,
    transfer,
};
use account_protocol::{
    account::{Self, Account},
    executable::Executable,
    intents,
};

use futarchy_core::{
    futarchy_config::{Self, FutarchyConfig, FutarchyOutcome, ExecutePermit},
    priority_queue,
    proposal_fee_manager::ProposalFeeManager,
};
use futarchy_actions::{
    action_dispatcher,
    governance_actions::ProposalReservationRegistry,
};
use futarchy_one_shot_utils::strategy;
use futarchy_dao::gc_janitor;

const EPolicyNotSatisfied: u64 = 777;
const EInvalidPermit: u64 = 778;
const EPermitMismatch: u64 = 779;

/// Your single futarchy witness type
public struct FutarchyIntent has copy, drop {}

/// Helper function to confirm execution and handle one-shot intent cleanup
/// Properly implements garbage collection for expired intents
public fun confirm_and_cleanup(
    executable: Executable<FutarchyOutcome>,
    account: &mut Account<FutarchyConfig>,
) {
    // Get the key before consuming the executable
    let key = executable.intent().key();
    
    // Confirm execution - re-adds the intent
    account::confirm_execution(account, executable);
    
    // Check if this was a one-shot intent (empty execution_times after popping one)
    if (account::intents(account).contains(key)) {
        let intent = account::intents(account).get<FutarchyOutcome>(key);
        if (intent.execution_times().is_empty()) {
            // One-shot intent - destroy it and clean up with proper garbage collection
            let mut expired = account::destroy_empty_intent<FutarchyConfig, FutarchyOutcome>(account, key);
            gc_janitor::drain_all_public(account, &mut expired);
            intents::destroy_empty_expired(expired);
        }
        // else: recurring intent, leave it in storage
    }
}

/// Generic "all actions" runner WITHOUT governance resources
/// For proposals that don't create second-order proposals
public fun run_all<IW: copy + drop>(
    executable: Executable<FutarchyOutcome>,
    account: &mut Account<FutarchyConfig>,
    gate: strategy::Strategy,
    ok_a: bool,
    ok_b: bool,
    intent_witness: IW,
    clock: &Clock,
    ctx: &mut TxContext
) {
    assert!(strategy::can_execute(ok_a, ok_b, gate), EPolicyNotSatisfied);

    let executable = action_dispatcher::execute_standard_actions(
        executable,
        account,
        intent_witness,
        clock,
        ctx
    );
    
    // Confirm and cleanup using helper function
    confirm_and_cleanup(executable, account);
}

/// Execute proposals that create second-order governance proposals
/// Requires governance resources (queue, fee manager, registry) to be provided
public fun run_with_governance<IW: copy + drop>(
    executable: Executable<FutarchyOutcome>,
    account: &mut Account<FutarchyConfig>,
    gate: strategy::Strategy,
    ok_a: bool,
    ok_b: bool,
    intent_witness: IW,
    queue: &mut priority_queue::ProposalQueue<FutarchyConfig>,
    fee_manager: &mut ProposalFeeManager,
    registry: &mut ProposalReservationRegistry,
    parent_proposal_id: ID,
    fee_coin: Coin<SUI>,
    clock: &Clock,
    ctx: &mut TxContext
) {
    assert!(strategy::can_execute(ok_a, ok_b, gate), EPolicyNotSatisfied);

    // Execute governance operations directly with all required resources
    let executable = action_dispatcher::execute_governance_operations(
        executable,
        account,
        intent_witness,
        queue,
        fee_manager,
        registry,
        parent_proposal_id,
        fee_coin,
        clock,
        ctx
    );
    
    // Confirm and cleanup
    confirm_and_cleanup(executable, account);
}

// Note: For typed operations (liquidity, oracle mint), use the specialized
// entry points in action_dispatcher module directly, as they require
// specific resources (AMM pools, TreasuryCaps) that must be provided by the caller

/// Permit-based execution for cross-DAO bundles WITHOUT governance resources
/// The permit is minted by futarchy_config after re-checking all gates
public fun run_with_permit(
    executable: Executable<FutarchyOutcome>,
    account: &mut Account<FutarchyConfig>,
    permit: ExecutePermit,
    clock: &Clock,
    ctx: &mut TxContext
) {
    let intent_key = account_protocol::executable::intent(&executable).key();
    assert!(
        futarchy_config::verify_permit(&permit, account, &intent_key, clock),
        EInvalidPermit
    );
    
    let executable = action_dispatcher::execute_standard_actions(
        executable,
        account,
        FutarchyIntent {},
        clock,
        ctx
    );
    
    // Consume the council approval if there was one (single-use)
    let _ = futarchy_config::consume_council_approval(account, &intent_key, ctx);
    
    // Confirm and cleanup using helper function
    confirm_and_cleanup(executable, account);
}