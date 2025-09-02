/// Dispatcher for oracle mint actions
module futarchy::oracle_mint_dispatcher;

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
    oracle_mint_actions,
};

// === Constants ===
const ECannotExecuteInHotPath: u64 = 15;

// === Public(friend) Functions ===

/// Check for oracle mint actions - these require special resources
/// This function aborts if oracle mint actions are present as they need treasury cap and AMM pool
public(package) fun try_execute_oracle_mint_actions<AssetType: drop + store, StableType: drop + store, IW: copy + drop, Outcome: store + drop + copy>(
    executable: &mut Executable<Outcome>,
    _account: &mut Account<FutarchyConfig>,
    _witness: IW,
    _clock: &Clock,
    _ctx: &mut TxContext,
): bool {
    // Abort if oracle mint actions are present - they need treasury cap and AMM pool
    if (executable::contains_action<Outcome, oracle_mint_actions::ConditionalMintAction<AssetType>>(executable)) {
        abort ECannotExecuteInHotPath
    };
    
    if (executable::contains_action<Outcome, oracle_mint_actions::RatioBasedMintAction<AssetType, StableType>>(executable)) {
        abort ECannotExecuteInHotPath
    };
    
    false
}