/// Dispatcher for vault governance actions
module futarchy::vault_governance_dispatcher;

// === Imports ===
use sui::tx_context::TxContext;
use account_protocol::{
    account::Account,
    executable::{Self, Executable},
};
use futarchy::{
    futarchy_config::FutarchyConfig,
    version,
    futarchy_vault,
};

// === Public(friend) Functions ===

/// Execute typed vault actions for managing allowed coin types
public(package) fun try_execute_typed_vault_action<CoinType, IW: drop, Outcome: store + drop + copy>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    witness: IW,
    ctx: &mut TxContext
): bool {
    // Try to execute AddCoinTypeAction
    if (executable::contains_action<Outcome, futarchy_vault::AddCoinTypeAction<CoinType>>(executable)) {
        futarchy_vault::do_add_coin_type<Outcome, CoinType, IW>(
            executable,
            account,
            version::current(),
            witness,
            ctx
        );
        return true
    };
    
    // Try to execute RemoveCoinTypeAction
    if (executable::contains_action<Outcome, futarchy_vault::RemoveCoinTypeAction<CoinType>>(executable)) {
        futarchy_vault::do_remove_coin_type<Outcome, CoinType, IW>(
            executable,
            account,
            version::current(),
            witness,
            ctx
        );
        return true
    };
    
    false
}