/// Vault governance intents for futarchy DAOs
/// Provides governance-controlled coin type management with permissionless deposits for allowed types
module futarchy::vault_governance_intents;

// === Imports ===
use std::string::String;
use sui::coin::Coin;
use account_protocol::{
    account::{Account, Auth},
    intents::Params,
    intent_interface,
};
use account_actions::vault;
use futarchy::{
    futarchy_config::{Self, FutarchyConfig, FutarchyOutcome},
    futarchy_vault,
    version,
};

// === Aliases ===
use fun intent_interface::build_intent as Account.build_intent;

// === Structs ===

/// Intent witness for adding a new coin type to the vault
public struct AddCoinTypeIntent() has copy, drop;

/// Intent witness for removing a coin type from the vault
public struct RemoveCoinTypeIntent() has copy, drop;

// === Public Functions ===

/// Request to add a new coin type to the vault (requires governance)
/// This creates an intent that must be approved through a proposal
public fun request_add_coin_type<CoinType>(
    auth: Auth,
    account: &mut Account<FutarchyConfig>,
    params: Params,
    outcome: FutarchyOutcome,
    vault_name: String,
    ctx: &mut TxContext,
) {
    account.verify(auth);
    params.assert_single_execution();
    
    // Check that coin type is not already allowed
    assert!(
        !futarchy_vault::is_coin_type_allowed<FutarchyConfig, CoinType>(account),
        0 // ECoinTypeAlreadyAllowed
    );
    
    account.build_intent!(
        params,
        outcome,
        vault_name,
        version::current(),
        AddCoinTypeIntent(),
        ctx,
        |intent, iw| new_add_coin_type<_, CoinType, _>(
            intent, 
            vault_name, 
            iw
        )
    );
}

/// Request to remove a coin type from the vault (requires governance)
public fun request_remove_coin_type<CoinType>(
    auth: Auth,
    account: &mut Account<FutarchyConfig>,
    params: Params,
    outcome: FutarchyOutcome,
    vault_name: String,
    ctx: &mut TxContext,
) {
    account.verify(auth);
    params.assert_single_execution();
    
    // Check that coin type is currently allowed
    assert!(
        futarchy_vault::is_coin_type_allowed<FutarchyConfig, CoinType>(account),
        1 // ECoinTypeNotAllowed
    );
    
    account.build_intent!(
        params,
        outcome,
        vault_name,
        version::current(),
        RemoveCoinTypeIntent(),
        ctx,
        |intent, iw| new_remove_coin_type<_, CoinType, _>(
            intent,
            vault_name,
            iw
        )
    );
}

/// Helper function to create add coin type action in an intent
public fun new_add_coin_type<Outcome, CoinType, IW: drop>(
    intent: &mut account_protocol::intents::Intent<Outcome>,
    vault_name: String,
    intent_witness: IW,
) {
    let action = futarchy_vault::new_add_coin_type_action<CoinType>(vault_name);
    intent.add_action(action, intent_witness);
}

/// Helper function to create remove coin type action in an intent
public fun new_remove_coin_type<Outcome, CoinType, IW: drop>(
    intent: &mut account_protocol::intents::Intent<Outcome>,
    vault_name: String,
    intent_witness: IW,
) {
    let action = futarchy_vault::new_remove_coin_type_action<CoinType>(vault_name);
    intent.add_action(action, intent_witness);
}