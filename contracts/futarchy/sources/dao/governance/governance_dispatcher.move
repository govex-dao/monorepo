/// Dispatcher for governance actions
module futarchy::governance_dispatcher;

// === Imports ===
use sui::{
    clock::Clock,
    tx_context::TxContext,
};
use account_protocol::{
    account::Account,
    executable::Executable,
};
use futarchy::{
    futarchy_config::FutarchyConfig,
};

// === Public(friend) Functions ===

/// Try to execute governance actions
/// These actions require special resources (queue, fee_manager, etc.)
/// and should be handled via specialized entry functions
public(package) fun try_execute_governance_actions<IW: drop, Outcome: store + drop + copy>(
    _executable: &mut Executable<Outcome>,
    _account: &mut Account<FutarchyConfig>,
    _witness: IW,
    _clock: &Clock,
    _ctx: &mut TxContext,
): bool {
    // Governance actions require special resources (queue, fee_manager, etc.)
    // These should be handled via specialized entry functions
    // For now, return false to indicate not handled
    false
}