module futarchy_dao::gc_janitor;

use std::string::String;
use std::vector;
use account_protocol::{
    account::{Self, Account},
    intents::{Self, Expired},
};
use sui::clock::Clock;
use futarchy_core::futarchy_config::{FutarchyConfig, FutarchyOutcome};
use futarchy_dao::gc_registry;

/// Drain an `Expired` bag by invoking all futarchy delete hooks, then destroy.
/// Internal version without Account parameter for non-owned actions
fun drain_all(expired: &mut Expired) {
    // Call every delete_* you registered. Add more as you introduce actions.
    
    // Operating Agreement
    futarchy_dao::gc_registry::delete_operating_agreement_update(expired);
    futarchy_dao::gc_registry::delete_operating_agreement_insert(expired);
    futarchy_dao::gc_registry::delete_operating_agreement_remove(expired);
    futarchy_dao::gc_registry::delete_operating_agreement_batch(expired);
    
    // Config
    futarchy_dao::gc_registry::delete_config_update(expired);
    futarchy_dao::gc_registry::delete_trading_params(expired);
    futarchy_dao::gc_registry::delete_metadata_update(expired);
    futarchy_dao::gc_registry::delete_governance_update(expired);
    futarchy_dao::gc_registry::delete_slash_distribution(expired);
    
    // Security Council
    futarchy_dao::gc_registry::delete_create_council(expired);
    futarchy_dao::gc_registry::delete_approve_oa_change(expired);
    futarchy_dao::gc_registry::delete_update_council_membership(expired);
    futarchy_dao::gc_registry::delete_approve_policy_change(expired);
    
    // Note: Generic type parameters need to be handled specially
    // For now we skip them - they'll be handled in Phase 3 with proper type resolution
    // futarchy::gc_registry::delete_approve_custody<R>(expired);
    // futarchy::gc_registry::delete_add_coin_type<CoinType>(expired);
    // futarchy::gc_registry::delete_add_liquidity<AssetType, StableType>(expired);
    
    // Liquidity (non-generic)
    futarchy_dao::gc_registry::delete_update_pool_params(expired);
    
    // Policy
    futarchy_dao::gc_registry::delete_set_policy(expired);
    futarchy_dao::gc_registry::delete_remove_policy(expired);
    
    // Dissolution
    futarchy_dao::gc_registry::delete_initiate_dissolution(expired);
    futarchy_dao::gc_registry::delete_batch_distribute(expired);
    futarchy_dao::gc_registry::delete_finalize_dissolution(expired);
    futarchy_dao::gc_registry::delete_cancel_dissolution(expired);
    
    // Package upgrade actions
    futarchy_dao::gc_registry::delete_upgrade_commit(expired);
    
    // Note: owned::delete_withdraw is handled separately in drain_all_with_account
    // since it requires the Account parameter to unlock objects
}

/// Delete a specific expired intent by key (one-shot flow).
public fun delete_expired_by_key(
    account: &mut Account<FutarchyConfig>,
    key: String,
    clock: &Clock
) {
    let mut expired = account::delete_expired_intent<FutarchyConfig, FutarchyOutcome>(
        account, key, clock
    );
    drain_all_with_account(account, &mut expired);
    intents::destroy_empty_expired(expired);
}

// TODO: Implement sweep_some when we have a way to check intent expiration
// /// Bounded sweeper (iterate over your own key index if you maintain one).
// public fun sweep_some(
//     account: &mut Account<FutarchyConfig>,
//     keys: &vector<String>,
//     max_n: u64,
//     clock: &Clock
// ) {
//     let mut i = 0u64;
//     let len = vector::length(keys);
//     while (i < max_n && i < len) {
//         let k = *vector::borrow(keys, i);
//         // Need to check if intent is expired - not currently exposed by protocol
//         // if (account::is_expired<FutarchyConfig, FutarchyOutcome>(account, k, clock)) {
//         //     delete_expired_by_key(account, k, clock);
//         // };
//         i = i + 1;
//     }
// }

/// Drain with Account context for actions that need unlocking
fun drain_all_with_account(account: &mut Account<FutarchyConfig>, expired: &mut Expired) {
    // First drain all non-owned actions
    drain_all(expired);
    
    // Then handle owned withdrawals which need Account for unlocking
    // We need to check if there are owned withdrawals in the expired bag
    // Since we can't inspect the bag directly, we try to delete and handle any errors
    futarchy_dao::gc_registry::delete_owned_withdraw(account, expired);
    
    // Handle vault spending actions that might need Account
    futarchy_dao::gc_registry::delete_vault_spend(account, expired);
}

/// Public export of drain_all for use in other modules
/// This works on any Expired object, not just time-expired ones
/// Accepts &mut Account for actions that need unlocking
public fun drain_all_public(account: &mut Account<FutarchyConfig>, expired: &mut Expired) {
    drain_all_with_account(account, expired);
}