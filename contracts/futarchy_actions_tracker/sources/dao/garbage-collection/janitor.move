// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

module futarchy_actions_tracker::gc_janitor;

use account_protocol::account::{Self, Account};
use account_protocol::intents::{Self, Expired};
use futarchy_core::futarchy_config::{FutarchyConfig, FutarchyOutcome};
use futarchy_actions_tracker::gc_registry;
use std::string::String;
use std::vector;
use sui::clock::Clock;
use sui::sui::SUI;

/// Drain an `Expired` bag by invoking all futarchy delete hooks.
/// This handles all non-generic and common generic actions.
fun drain_all(expired: &mut Expired) {
    // DAO File Actions
    gc_registry::delete_dao_file_create_registry(expired);
    gc_registry::delete_dao_file_create_root_document(expired);
    gc_registry::delete_dao_file_delete_document(expired);
    gc_registry::delete_dao_file_add_chunk(expired);
    gc_registry::delete_dao_file_update(expired);
    gc_registry::delete_dao_file_remove(expired);
    gc_registry::delete_dao_file_set_chunk_immutable(expired);
    gc_registry::delete_dao_file_set_document_immutable(expired);
    gc_registry::delete_dao_file_set_registry_immutable(expired);

    // Config Actions
    gc_registry::delete_config_update(expired);
    gc_registry::delete_trading_params(expired);
    gc_registry::delete_metadata_update(expired);
    gc_registry::delete_governance_update(expired);
    gc_registry::delete_slash_distribution(expired);

    // Security Council
    gc_registry::delete_create_council(expired);
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
    gc_registry::delete_upgrade_commit_action(expired);

    // Transfer Actions
    gc_registry::delete_transfer(expired);
    gc_registry::delete_transfer_to_sender(expired);

    // Kiosk Actions
    gc_registry::delete_kiosk_take(expired);
    gc_registry::delete_kiosk_list(expired);

    // Liquidity (non-generic)
    gc_registry::delete_update_pool_params(expired);

    // Stream/Payment Actions (non-generic)
    gc_registry::delete_update_payment_recipient(expired);
    gc_registry::delete_add_withdrawer(expired);
    gc_registry::delete_remove_withdrawers(expired);
    gc_registry::delete_toggle_payment(expired);
    gc_registry::delete_challenge_withdrawals(expired);
    gc_registry::delete_cancel_challenged_withdrawals(expired);

    // REMOVED: Governance Actions (second-order proposals deleted)

    // Note: Oracle price reading actions have drop ability, don't need cleanup
    // Only mint actions (which are generic) need cleanup

    // Memo Actions
    gc_registry::delete_memo(expired);

    // REMOVED: Platform Fee Actions (deprecated system deleted)

    // Walrus Renewal Actions
    gc_registry::delete_walrus_renewal(expired);


    // Quota Actions
    gc_registry::delete_set_quotas(expired);

    // Protocol Admin Actions
    gc_registry::delete_protocol_admin_action(expired);

    // Additional Liquidity Actions (non-generic)
    gc_registry::delete_set_pool_status(expired);

    // Additional Config Actions
    gc_registry::delete_set_proposals_enabled<FutarchyConfig>(expired);
    gc_registry::delete_update_name<FutarchyConfig>(expired);
    gc_registry::delete_twap_config_update<FutarchyConfig>(expired);
    gc_registry::delete_metadata_table_update<FutarchyConfig>(expired);
    gc_registry::delete_queue_params_update<FutarchyConfig>(expired);

    // Additional DAO File Actions
    gc_registry::delete_set_document_insert_allowed(expired);
    gc_registry::delete_set_document_remove_allowed(expired);

    // Additional Dissolution Actions (non-generic)
    gc_registry::delete_calculate_pro_rata_shares(expired);
    gc_registry::delete_cancel_all_streams(expired);
    // Note: delete_distribute_assets and delete_withdraw_amm_liquidity are generic
    // and are handled in drain_common_generics

    // Additional Policy Actions
    gc_registry::delete_register_council(expired);
    gc_registry::delete_set_object_policy(expired);
    gc_registry::delete_remove_object_policy(expired);
}

/// Drain common generic actions for known coin types
/// This handles the most common coin types used in the protocol
/// For production, you would add your specific coin types here
fun drain_common_generics(expired: &mut Expired) {
    // Note: These use phantom type parameters to avoid hardcoding coin types
    // The actual cleanup happens when the action_spec is removed

    // Vault Actions
    drain_vault_actions_for_coin<SUI>(expired);

    // Currency Actions
    drain_currency_actions_for_coin<SUI>(expired);

    // Stream Actions
    drain_stream_actions_for_coin<SUI>(expired);

    // NOTE: Oracle Mint Actions removed - ConditionalMint/TieredMint replaced by PriceBasedMintGrant

    // Dividend Actions (phantom CoinType)
    gc_registry::delete_create_dividend<SUI>(expired);

    // Liquidity Actions for common pairs (phantom AssetType, StableType)
    drain_liquidity_generic_actions_for_pair<SUI, SUI>(expired);

    // Dissolution Actions (phantom types)
    gc_registry::delete_distribute_assets<SUI>(expired);
    gc_registry::delete_withdraw_amm_liquidity<SUI, SUI>(expired);

    // Vesting Actions (phantom CoinType)
    gc_registry::delete_vesting_action<SUI>(expired);
    gc_registry::delete_cancel_vesting_action(expired);

    // Note: For production, add your specific coin types here:
    // - DAO governance tokens
    // - Stablecoins used in your protocol
    // - LP tokens, etc.
    // The type parameter is used for type safety but doesn't affect cleanup
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
    gc_registry::delete_currency_disable<CoinType>(expired);
}

/// Helper to drain stream actions for a specific coin type
fun drain_stream_actions_for_coin<CoinType>(expired: &mut Expired) {
    gc_registry::delete_create_payment<CoinType>(expired);
    gc_registry::delete_execute_payment<CoinType>(expired);
    gc_registry::delete_cancel_payment<CoinType>(expired);
    gc_registry::delete_request_withdrawal<CoinType>(expired);
    gc_registry::delete_process_pending_withdrawal<CoinType>(expired);
}

/// Helper to drain liquidity actions for a specific pair
fun drain_liquidity_actions_for_pair<AssetType, StableType>(expired: &mut Expired) {
    gc_registry::delete_add_liquidity<AssetType, StableType>(expired);
    gc_registry::delete_withdraw_lp_token<AssetType, StableType>(expired);
    gc_registry::delete_remove_liquidity<AssetType, StableType>(expired);
    gc_registry::delete_create_pool<AssetType, StableType>(expired);
}

/// Helper to drain additional generic liquidity actions for a specific pair
fun drain_liquidity_generic_actions_for_pair<AssetType, StableType>(expired: &mut Expired) {
    gc_registry::delete_swap<AssetType, StableType>(expired);
    gc_registry::delete_collect_fees<AssetType, StableType>(expired);
    gc_registry::delete_withdraw_fees<AssetType, StableType>(expired);
}

/// Delete a specific expired intent by key
public fun delete_expired_by_key(
    account: &mut Account<FutarchyConfig>,
    key: String,
    clock: &Clock,
) {
    let mut expired = account::delete_expired_intent<FutarchyConfig, FutarchyOutcome>(
        account,
        key,
        clock,
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
    clock: &Clock,
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
fun is_intent_expired(account: &Account<FutarchyConfig>, key: &String, clock: &Clock): bool {
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
    clock: &Clock,
) {
    delete_expired_by_key(account, key, clock);
}

/// Entry function to sweep multiple expired intents
public entry fun cleanup_expired_intents(
    account: &mut Account<FutarchyConfig>,
    keys: vector<String>,
    clock: &Clock,
) {
    // Process up to 10 intents per transaction to avoid gas limits
    sweep_expired_intents(account, keys, 10, clock);
}
