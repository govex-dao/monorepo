/// Dispatcher for optimistic intent actions
module futarchy_actions::optimistic_dispatcher;

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

// === Public(friend) Functions ===

/// Try to execute optimistic intent actions
public fun try_execute_optimistic_action<IW: drop, Outcome: store + drop + copy>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    witness: IW,
    clock: &Clock,
    ctx: &mut TxContext,
): bool {
    // Optimistic intent actions not yet implemented
    // Return false to indicate no action was executed
    let _ = executable;
    let _ = account;
    let _ = witness;
    let _ = clock;
    let _ = ctx;
    false
}