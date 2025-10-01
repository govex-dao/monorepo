/// Simple execute module for handling proposal execution
module futarchy_dao::execute;

use account_protocol::{
    account::Account,
    executable::Executable,
};
use futarchy_core::{
    futarchy_config::{FutarchyConfig, FutarchyOutcome},
    version,
};

// === Entry Functions ===

/// Run all actions in the executable with governance
public fun run_with_governance<IW: copy + drop>(
    executable: Executable<FutarchyOutcome>,
    account: &mut Account<FutarchyConfig>,
    witness: IW,
    clock: &sui::clock::Clock,
    ctx: &mut sui::tx_context::TxContext,
) {
    // Simply confirm execution - the actual action execution happens via PTB
    account_protocol::account::confirm_execution(
        account,
        executable,
    );

    // Suppress unused warnings
    let _ = witness;
    let _ = clock;
    let _ = ctx;
}

/// Run all actions in the executable
public fun run_all<IW: copy + drop>(
    executable: Executable<FutarchyOutcome>,
    account: &mut Account<FutarchyConfig>,
    witness: IW,
    clock: &sui::clock::Clock,
    ctx: &mut sui::tx_context::TxContext,
) {
    // Simply confirm execution - the actual action execution happens via PTB
    account_protocol::account::confirm_execution(
        account,
        executable,
    );

    // Suppress unused warnings
    let _ = witness;
    let _ = clock;
    let _ = ctx;
}