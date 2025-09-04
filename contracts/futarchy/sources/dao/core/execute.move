module futarchy::execute;

use std::option::{Self, Option};
use sui::{
    clock::Clock, 
    tx_context::TxContext,
    coin::Coin,
    sui::SUI,
    object::ID,
};
use account_protocol::{
    account::{Self, Account},
    executable::Executable,
    intents,
};

use futarchy::{
    gc_janitor,
    futarchy_config::{Self, FutarchyConfig, FutarchyOutcome, ExecutePermit},
    action_dispatcher,
    version,
    priority_queue,
    proposal_fee_manager::ProposalFeeManager,
    governance_actions::ProposalReservationRegistry,
};
use futarchy_utils::strategy;

const EPolicyNotSatisfied: u64 = 777;
const EInvalidPermit: u64 = 778;
const EPermitMismatch: u64 = 779;

/// Your single futarchy witness type
public struct FutarchyIntent has copy, drop {}

/// Helper function to confirm execution and handle one-shot intent cleanup
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
            // One-shot intent - destroy it and clean up
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

/// Generic "all actions" runner WITH governance resources
/// For proposals that may create second-order proposals
/// 
/// NOTE: Creating second-order proposals requires specialized execution
/// The frontend should use specific entry points in action_dispatcher
/// This function is kept for backwards compatibility but delegates to standard execution
public fun run_all_with_governance<IW: copy + drop>(
    executable: Executable<FutarchyOutcome>,
    account: &mut Account<FutarchyConfig>,
    gate: strategy::Strategy,
    ok_a: bool,
    ok_b: bool,
    intent_witness: IW,
    _queue: &mut priority_queue::ProposalQueue<FutarchyConfig>,
    _fee_manager: &mut ProposalFeeManager,
    _registry: &mut ProposalReservationRegistry,
    _parent_proposal_id: ID,
    mut fee_coin_opt: Option<Coin<SUI>>,
    clock: &Clock,
    ctx: &mut TxContext
) {
    assert!(strategy::can_execute(ok_a, ok_b, gate), EPolicyNotSatisfied);

    // Return fee coin if provided (governance actions not supported in this path)
    if (fee_coin_opt.is_some()) {
        let fee_coin = fee_coin_opt.extract();
        transfer::public_transfer(fee_coin, ctx.sender());
    };
    fee_coin_opt.destroy_none();
    
    // Execute standard actions only
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

/// Typed runner for proposals with typed actions
/// 
/// NOTE: Typed actions (liquidity, oracle mint) require specific resources
/// The frontend should use specialized entry points in action_dispatcher:
/// - execute_oracle_mint for oracle minting
/// - execute_vault_spend for vault operations
/// This function is kept for backwards compatibility but delegates to standard execution
public fun run_typed<AssetType: drop + store, StableType: drop + store, IW: copy + drop>(
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

    // Execute standard actions only
    // Typed actions should be executed via specialized entry points
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

/// Simple execution without strategy gates (for backwards compatibility)
public fun run_simple<IW: copy + drop>(
    executable: Executable<FutarchyOutcome>,
    account: &mut Account<FutarchyConfig>,
    intent_witness: IW,
    clock: &Clock,
    ctx: &mut TxContext
) {
    run_all(
        executable,
        account,
        strategy::and(),
        true,
        true,
        intent_witness,
        clock,
        ctx
    )
}

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