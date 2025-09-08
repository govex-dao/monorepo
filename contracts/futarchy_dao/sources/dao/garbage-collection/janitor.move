module futarchy_dao::gc_janitor;

use std::string::String;
use std::vector;
use account_protocol::{
    account::{Self, Account},
    intents::{Self, Expired},
};
use sui::{clock::Clock, sui::SUI};
use futarchy_core::futarchy_config::{FutarchyConfig, FutarchyOutcome};
use futarchy_dao::gc_registry;

/// Drain an `Expired` bag by invoking all futarchy delete hooks.
/// This handles all non-generic and common generic actions.
fun drain_all(expired: &mut Expired) {
    // Operating Agreement
    gc_registry::delete_operating_agreement_update(expired);
    gc_registry::delete_operating_agreement_insert(expired);
    gc_registry::delete_operating_agreement_remove(expired);
    gc_registry::delete_operating_agreement_batch(expired);
    
    // Config Actions
    gc_registry::delete_config_update(expired);
    gc_registry::delete_trading_params(expired);
    gc_registry::delete_metadata_update(expired);
    gc_registry::delete_governance_update(expired);
    gc_registry::delete_slash_distribution(expired);
    
    // Security Council
    gc_registry::delete_create_council(expired);
    gc_registry::delete_approve_oa_change(expired);
    gc_registry::delete_update_council_membership(expired);
    gc_registry::delete_approve_policy_change(expired);
    
    // Policy Actions
    gc_registry::delete_set_policy(expired);
    gc_registry::delete_remove_policy(expired);
    
    // Dissolution Actions
    gc_registry::delete_initiate_dissolution(expired);
    gc_registry::delete_batch_distribute(expired);
    gc_registry::delete_finalize_dissolution(expired);
    gc_registry::delete_cancel_dissolution(expired);
    
    // Package Upgrade
    gc_registry::delete_upgrade_commit(expired);
    gc_registry::delete_restrict_policy(expired);
    
    // Liquidity (non-generic)
    gc_registry::delete_update_pool_params(expired);
    
    // Stream/Payment Actions (non-generic)
    gc_registry::delete_update_payment_recipient(expired);
    gc_registry::delete_add_withdrawer(expired);
    gc_registry::delete_remove_withdrawers(expired);
    gc_registry::delete_toggle_payment(expired);
    gc_registry::delete_challenge_withdrawals(expired);
    gc_registry::delete_cancel_challenged_withdrawals(expired);
    
    // Governance Actions
    gc_registry::delete_create_proposal(expired);
    gc_registry::delete_proposal_reservation(expired);
    
    // Note: Oracle price reading actions have drop ability, don't need cleanup
    // Only mint actions (which are generic) need cleanup
    
    // Memo Actions
    gc_registry::delete_memo(expired);
}

/// Drain common generic actions for known coin types
/// This handles the most common coin types used in the protocol
/// For production, you would add your specific coin types here
fun drain_common_generics(expired: &mut Expired) {
    // Vault Actions for SUI
    drain_vault_actions_for_coin<SUI>(expired);
    
    // Currency Actions for SUI
    drain_currency_actions_for_coin<SUI>(expired);
    
    // Stream Actions for SUI
    drain_stream_actions_for_coin<SUI>(expired);
    
    // Note: For production, add your specific coin types here:
    // - DAO governance tokens
    // - Stablecoins used in your protocol
    // - LP tokens, etc.
}

/// Helper to drain vault actions for a specific coin type
fun drain_vault_actions_for_coin<CoinType>(expired: &mut Expired) {
    // Try each vault action - if it doesn't exist, it will be a no-op
    gc_registry::delete_vault_spend<CoinType>(expired);
    gc_registry::delete_vault_deposit<CoinType>(expired);
    gc_registry::delete_add_coin_type<CoinType>(expired);
    gc_registry::delete_remove_coin_type<CoinType>(expired);
}

/// Helper to drain currency actions for a specific coin type
fun drain_currency_actions_for_coin<CoinType>(expired: &mut Expired) {
    gc_registry::delete_currency_mint<CoinType>(expired);
    gc_registry::delete_currency_burn<CoinType>(expired);
    gc_registry::delete_currency_update_metadata<CoinType>(expired);
}

/// Helper to drain stream actions for a specific coin type
fun drain_stream_actions_for_coin<CoinType>(expired: &mut Expired) {
    gc_registry::delete_create_payment<CoinType>(expired);
    gc_registry::delete_create_budget_stream<CoinType>(expired);
    gc_registry::delete_execute_payment<CoinType>(expired);
    gc_registry::delete_cancel_payment<CoinType>(expired);
    gc_registry::delete_request_withdrawal<CoinType>(expired);
    gc_registry::delete_process_pending_withdrawal<CoinType>(expired);
}

/// Helper to drain oracle mint actions for a specific coin type
fun drain_oracle_mint_for_coin<CoinType>(expired: &mut Expired) {
    gc_registry::delete_conditional_mint<CoinType>(expired);
    gc_registry::delete_tiered_mint<CoinType>(expired);
}

/// Helper to drain liquidity actions for a specific pair
fun drain_liquidity_actions_for_pair<AssetType, StableType>(expired: &mut Expired) {
    gc_registry::delete_add_liquidity<AssetType, StableType>(expired);
    gc_registry::delete_remove_liquidity<AssetType, StableType>(expired);
    gc_registry::delete_create_pool<AssetType, StableType>(expired);
}

/// Delete a specific expired intent by key
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

/// Sweep multiple expired intents in a bounded manner
/// Processes up to max_n intents from the provided keys
public fun sweep_expired_intents(
    account: &mut Account<FutarchyConfig>,
    keys: vector<String>,
    max_n: u64,
    clock: &Clock
) {
    let mut i = 0u64;
    let len = vector::length(&keys);
    let limit = if (max_n < len) { max_n } else { len };
    
    while (i < limit) {
        let key = *vector::borrow(&keys, i);
        
        // Try to delete the intent if it's expired
        // The delete_expired_intent will fail if not expired, so we catch that
        if (is_intent_expired(account, &key, clock)) {
            delete_expired_by_key(account, key, clock);
        };
        
        i = i + 1;
    }
}

/// Check if an intent is expired (helper function)
fun is_intent_expired(
    account: &Account<FutarchyConfig>,
    key: &String,
    clock: &Clock
): bool {
    // Check if intent exists
    if (!account::intents(account).contains(*key)) {
        return false
    };
    
    // Get the intent and check if it has any non-expired execution times
    let intent = account::intents(account).get<FutarchyOutcome>(*key);
    let exec_times = intent.execution_times();
    
    // If no execution times, it's effectively expired
    if (exec_times.is_empty()) {
        return true
    };
    
    // Check if all execution times are in the past
    let current_time = clock.timestamp_ms();
    let mut all_expired = true;
    let mut i = 0;
    
    while (i < exec_times.length()) {
        if (*exec_times.borrow(i) > current_time) {
            all_expired = false;
            break
        };
        i = i + 1;
    };
    
    all_expired
}

/// Drain with Account context to handle all action types including owned withdrawals
fun drain_all_with_account(account: &Account<FutarchyConfig>, expired: &mut Expired) {
    // First drain all non-generic actions
    drain_all(expired);
    
    // Then drain common generic actions
    drain_common_generics(expired);
    
    // Handle owned withdrawals
    gc_registry::delete_owned_withdraw(account, expired);
    
    // Handle NFT/Kiosk actions for common NFT types
    // Note: These would need specific NFT type parameters
    // For production, you'd enumerate known NFT types here
}

/// Public export of drain_all for use in other modules
/// Properly handles all action types including generics
public fun drain_all_public(account: &Account<FutarchyConfig>, expired: &mut Expired) {
    drain_all_with_account(account, expired);
}

/// Entry function to clean up a specific expired intent
public entry fun cleanup_expired_intent(
    account: &mut Account<FutarchyConfig>,
    key: String,
    clock: &Clock
) {
    delete_expired_by_key(account, key, clock);
}

/// Entry function to sweep multiple expired intents
public entry fun cleanup_expired_intents(
    account: &mut Account<FutarchyConfig>,
    keys: vector<String>,
    clock: &Clock
) {
    // Process up to 10 intents per transaction to avoid gas limits
    sweep_expired_intents(account, keys, 10, clock);
}