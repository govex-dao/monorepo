module futarchy::gc_registry;

use account_protocol::intents::Expired;

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
    futarchy::security_council_actions::delete_approve_policy_change(expired);
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
// Note: Some actions from account_protocol may need special handling
// These are placeholders that will be filled in Phase 3
public fun delete_upgrade_commit(expired: &mut Expired) {
    // Will be wired to account_protocol upgrade actions
    let _ = expired;
}

public fun delete_owned_withdraw(expired: &mut Expired) {
    // Will be wired to account_protocol owned actions
    // Requires Account context, so will need special handling
    let _ = expired;
}