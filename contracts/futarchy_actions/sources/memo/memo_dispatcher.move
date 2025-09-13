/// Dispatcher for memo actions
module futarchy_actions::memo_dispatcher;

// === Imports ===
use sui::{
    clock::Clock,
    tx_context::TxContext,
};
use account_protocol::{
    account::Account,
    executable::{Self, Executable},
};
use futarchy_core::version;
use futarchy_core::futarchy_config::FutarchyConfig;
use futarchy_actions::memo_actions;

// === Public(friend) Functions ===

/// Try to execute memo actions
public fun try_execute_memo_action<IW: drop, Outcome: store + drop + copy>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    witness: IW,
    clock: &Clock,
    ctx: &mut TxContext
): bool {
    // Try to execute EmitMemoAction
    if (executable::contains_action<Outcome, memo_actions::EmitMemoAction>(executable)) {
        memo_actions::do_emit_memo<Outcome, IW>(
            executable,
            account,
            version::current(),
            witness,
            clock,
            ctx
        );
        return true
    };

    // Try to execute EmitDecisionAction
    if (executable::contains_action<Outcome, memo_actions::EmitDecisionAction>(executable)) {
        memo_actions::do_emit_decision<Outcome, IW>(
            executable,
            account,
            version::current(),
            witness,
            clock,
            ctx
        );
        return true
    };

    false
}