module futarchy::execute;

use sui::{clock::Clock, tx_context::TxContext};
use account_protocol::{
    account::{Self, Account},
    executable::Executable,
    intent_interface,
};
use fun intent_interface::process_intent as Account.process_intent;

use futarchy::{
    version,
    strategy,
    futarchy_config::{Self, FutarchyConfig, FutarchyOutcome},
    action_dispatcher,
};

const EPolicyNotSatisfied: u64 = 777;

/// Your single futarchy witness type
public struct FutarchyIntent has copy, drop {}

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
    
    // Confirm execution (single place for confirmation)
    account::confirm_execution(account, executable);
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
    
    // Confirm execution (single place for confirmation)
    account::confirm_execution(account, executable);
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