module futarchy::gc_registry;

use account_protocol::{
    intents::Expired,
    account::Account,
    owned,
};
use account_actions::{
    package_upgrade,
    vault,
};
use futarchy::futarchy_config::FutarchyConfig;

/// Register one delete_* per action you actually use in futarchy.
/// This module serves as a central registry for all delete functions.
/// Each function delegates to the appropriate module's delete function.

// === Operating Agreement Actions ===
public fun delete_operating_agreement_update(expired: &mut Expired) {
    futarchy::operating_agreement_actions::delete_update_line(expired);
}

public fun delete_operating_agreement_insert(expired: &mut Expired) {
    futarchy::operating_agreement_actions::delete_insert_line_after(expired);
}

public fun delete_operating_agreement_remove(expired: &mut Expired) {
    futarchy::operating_agreement_actions::delete_remove_line(expired);
}

public fun delete_operating_agreement_batch(expired: &mut Expired) {
    futarchy::operating_agreement_actions::delete_batch_operating_agreement(expired);
}

// === Config Actions ===
public fun delete_config_update(expired: &mut Expired) {
    futarchy::config_actions::delete_config_action(expired);
}

public fun delete_trading_params(expired: &mut Expired) {
    futarchy::config_actions::delete_trading_params_update(expired);
}

public fun delete_metadata_update(expired: &mut Expired) {
    futarchy::config_actions::delete_metadata_update(expired);
}

public fun delete_governance_update(expired: &mut Expired) {
    futarchy::config_actions::delete_governance_update(expired);
}

public fun delete_slash_distribution(expired: &mut Expired) {
    futarchy::config_actions::delete_slash_distribution_update(expired);
}

// === Security Council Actions ===
public fun delete_create_council(expired: &mut Expired) {
    futarchy::security_council_actions::delete_create_council(expired);
}

public fun delete_approve_oa_change(expired: &mut Expired) {
    futarchy::security_council_actions::delete_approve_oa_change(expired);
}

public fun delete_update_council_membership(expired: &mut Expired) {
    futarchy::security_council_actions::delete_update_council_membership(expired);
}

public fun delete_approve_policy_change(expired: &mut Expired) {
    futarchy::security_council_actions::delete_approve_generic(expired);
}

// === Vault/Custody Actions ===
public fun delete_approve_custody<R>(expired: &mut Expired) {
    futarchy::custody_actions::delete_approve_custody<R>(expired);
}

public fun delete_accept_into_custody<R>(expired: &mut Expired) {
    futarchy::custody_actions::delete_accept_into_custody<R>(expired);
}

public fun delete_add_coin_type<CoinType>(expired: &mut Expired) {
    futarchy::futarchy_vault::delete_add_coin_type<CoinType>(expired);
}

public fun delete_remove_coin_type<CoinType>(expired: &mut Expired) {
    futarchy::futarchy_vault::delete_remove_coin_type<CoinType>(expired);
}

// === Liquidity Actions ===
public fun delete_add_liquidity<AssetType, StableType>(expired: &mut Expired) {
    futarchy::liquidity_actions::delete_add_liquidity<AssetType, StableType>(expired);
}

public fun delete_remove_liquidity<AssetType, StableType>(expired: &mut Expired) {
    futarchy::liquidity_actions::delete_remove_liquidity<AssetType, StableType>(expired);
}

public fun delete_create_pool<AssetType, StableType>(expired: &mut Expired) {
    futarchy::liquidity_actions::delete_create_pool<AssetType, StableType>(expired);
}

public fun delete_update_pool_params(expired: &mut Expired) {
    futarchy::liquidity_actions::delete_update_pool_params(expired);
}

// === Policy Actions ===
public fun delete_set_policy(expired: &mut Expired) {
    futarchy::policy_actions::delete_set_policy(expired);
}

public fun delete_remove_policy(expired: &mut Expired) {
    futarchy::policy_actions::delete_remove_policy(expired);
}

// === Dissolution Actions ===
public fun delete_initiate_dissolution(expired: &mut Expired) {
    futarchy::dissolution_actions::delete_initiate_dissolution(expired);
}

public fun delete_distribute_asset<CoinType>(expired: &mut Expired) {
    futarchy::dissolution_actions::delete_distribute_asset<CoinType>(expired);
}

public fun delete_batch_distribute(expired: &mut Expired) {
    futarchy::dissolution_actions::delete_batch_distribute(expired);
}

public fun delete_finalize_dissolution(expired: &mut Expired) {
    futarchy::dissolution_actions::delete_finalize_dissolution(expired);
}

public fun delete_cancel_dissolution(expired: &mut Expired) {
    futarchy::dissolution_actions::delete_cancel_dissolution(expired);
}

// === Package Upgrade Actions ===
public fun delete_upgrade_commit(expired: &mut Expired) {
    // Handle upgrade commit actions from account_actions
    // These don't need Account parameter
    if (expired.actions().length() > 0) {
        account_actions::package_upgrade::delete_upgrade(expired);
    }
}

// === Owned Object Actions ===
public fun delete_owned_withdraw(account: &mut Account<FutarchyConfig>, expired: &mut Expired) {
    // Handle owned withdrawals - this unlocks the object
    // We need to check if there's actually a withdraw action before calling
    // For now we'll handle this carefully to avoid errors
    if (expired.actions().length() > 0) {
        // Try to delete owned withdraw if it exists
        // The account_protocol::owned module handles the unlocking
        account_protocol::owned::delete_withdraw(expired, account);
    }
}

// === Vault Spending Actions ===
public fun delete_vault_spend(account: &mut Account<FutarchyConfig>, expired: &mut Expired) {
    // Handle vault spending which might involve locked coins
    // Check with vault module if this needs special handling
    let _ = account;
    if (expired.actions().length() > 0) {
        // account_actions::vault::delete_spend(expired);
        // For now, just drain without special handling
        let _ = expired;
    }
}