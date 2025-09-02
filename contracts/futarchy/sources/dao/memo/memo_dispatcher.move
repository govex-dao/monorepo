/// Dispatcher for memo actions
module futarchy::memo_dispatcher;

// === Imports ===
use sui::{
    clock::Clock,
    tx_context::TxContext,
};
use account_protocol::{
    account::Account,
    executable::{Self, Executable},
};
use futarchy::{
    futarchy_config::FutarchyConfig,
    version,
    memo_actions,
};

// === Public(friend) Functions ===

/// Try to execute memo actions
public(package) fun try_execute_memo_action<IW: drop, Outcome: store + drop + copy>(
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
    
    // Try to execute EmitStructuredMemoAction
    if (executable::contains_action<Outcome, memo_actions::EmitStructuredMemoAction>(executable)) {
        memo_actions::do_emit_structured_memo<Outcome, IW>(
            executable,
            account,
            version::current(),
            witness,
            clock,
            ctx
        );
        return true
    };
    
    // Try to execute EmitCommitmentAction
    if (executable::contains_action<Outcome, memo_actions::EmitCommitmentAction>(executable)) {
        memo_actions::do_emit_commitment<Outcome, IW>(
            executable,
            account,
            version::current(),
            witness,
            clock,
            ctx
        );
        return true
    };
    
    // Try to execute EmitSignalAction
    if (executable::contains_action<Outcome, memo_actions::EmitSignalAction>(executable)) {
        memo_actions::do_emit_signal<Outcome, IW>(
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