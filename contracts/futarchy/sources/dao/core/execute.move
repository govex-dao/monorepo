module futarchy::execute;

use std::option;
use sui::{clock::Clock, tx_context::TxContext};
use account_protocol::{
    account::{Self, Account},
    executable::Executable,
    intents,
};

use futarchy::{
    strategy,
    gc_janitor,
    futarchy_config::{Self, FutarchyConfig, FutarchyOutcome, ExecutePermit},
    action_dispatcher,
    version,
};

const EPolicyNotSatisfied: u64 = 777;
const EInvalidPermit: u64 = 778;
const EPermitMismatch: u64 = 779;

/// Your single futarchy witness type
public struct FutarchyIntent has copy, drop {}

/// Helper function to confirm execution and handle one-shot intent cleanup
fun confirm_and_cleanup(
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

/// Generic "all actions" runner using existing dispatcher.
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

    // Delegate to existing dispatcher and get back the executable
    let executable = action_dispatcher::execute_all_actions(
        executable,
        account,
        intent_witness,
        clock,
        ctx
    );
    
    // Confirm and cleanup using helper function
    confirm_and_cleanup(executable, account);
}

/// Typed runner calling typed dispatcher.
public fun run_typed<AssetType: drop, StableType: drop, IW: copy + drop>(
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

    // Delegate to typed dispatcher and get back the executable
    let executable = action_dispatcher::execute_typed_actions<AssetType, StableType, IW, FutarchyOutcome>(
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
    // Use AND strategy with both conditions true (always passes)
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

/// Permit-based execution for cross-DAO bundles
/// The permit is minted by futarchy_config after re-checking all gates
public fun run_with_permit(
    executable: Executable<FutarchyOutcome>,
    account: &mut Account<FutarchyConfig>,
    permit: ExecutePermit,
    clock: &Clock,
    ctx: &mut TxContext
) {
    // Verify the permit is valid for this executable
    let intent_key = account_protocol::executable::intent(&executable).key();
    assert!(
        futarchy_config::verify_permit(&permit, account, &intent_key, clock),
        EInvalidPermit
    );
    
    // Execute all actions
    let executable = action_dispatcher::execute_all_actions(
        executable,
        account,
        FutarchyIntent {}, // Use standard witness
        clock,
        ctx
    );
    
    // Consume the council approval if there was one (single-use)
    let _ = futarchy_config::consume_council_approval(account, &intent_key, ctx);
    
    // Confirm and cleanup using helper function
    confirm_and_cleanup(executable, account);
}