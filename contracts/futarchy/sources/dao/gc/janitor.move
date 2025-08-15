module futarchy::gc_janitor;

use std::string::String;
use std::vector;
use account_protocol::{
    account::{Self, Account},
    intents::{Self, Expired},
};
use sui::clock::Clock;
use futarchy::futarchy_config::{FutarchyConfig, FutarchyOutcome};

/// Drain an `Expired` bag by invoking all futarchy delete hooks, then destroy.
fun drain_all(expired: &mut Expired) {
    // Call every delete_* you registered. Add more as you introduce actions.
    
    // Operating Agreement
    futarchy::gc_registry::delete_operating_agreement_update(expired);
    futarchy::gc_registry::delete_operating_agreement_insert(expired);
    futarchy::gc_registry::delete_operating_agreement_remove(expired);
    futarchy::gc_registry::delete_operating_agreement_batch(expired);
    
    // Config
    futarchy::gc_registry::delete_config_update(expired);
    futarchy::gc_registry::delete_trading_params(expired);
    futarchy::gc_registry::delete_metadata_update(expired);
    futarchy::gc_registry::delete_governance_update(expired);
    futarchy::gc_registry::delete_slash_distribution(expired);
    
    // Security Council
    futarchy::gc_registry::delete_create_council(expired);
    futarchy::gc_registry::delete_approve_oa_change(expired);
    futarchy::gc_registry::delete_update_council_membership(expired);
    futarchy::gc_registry::delete_approve_policy_change(expired);
    
    // Note: Generic type parameters need to be handled specially
    // For now we skip them - they'll be handled in Phase 3 with proper type resolution
    // futarchy::gc_registry::delete_approve_custody<R>(expired);
    // futarchy::gc_registry::delete_add_coin_type<CoinType>(expired);
    // futarchy::gc_registry::delete_add_liquidity<AssetType, StableType>(expired);
    
    // Liquidity (non-generic)
    futarchy::gc_registry::delete_update_pool_params(expired);
    
    // Policy
    futarchy::gc_registry::delete_set_policy(expired);
    futarchy::gc_registry::delete_remove_policy(expired);
    
    // Dissolution
    futarchy::gc_registry::delete_initiate_dissolution(expired);
    futarchy::gc_registry::delete_batch_distribute(expired);
    futarchy::gc_registry::delete_finalize_dissolution(expired);
    futarchy::gc_registry::delete_cancel_dissolution(expired);
    
    // Package upgrade and owned actions (placeholders)
    futarchy::gc_registry::delete_upgrade_commit(expired);
    futarchy::gc_registry::delete_owned_withdraw(expired);
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
    drain_all(&mut expired);
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

/// Public export of drain_all for use in other modules
/// This works on any Expired object, not just time-expired ones
/// Accepts &mut Account in case any delete hooks need it
public fun drain_all_public(account: &mut Account<FutarchyConfig>, expired: &mut Expired) {
    // Some delete functions (like owned::delete_withdraw) need the account
    // For now, we just pass it through in case it's needed
    // The individual delete functions will use it if required
    let _ = account;
    drain_all(expired);
}