// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

module futarchy_actions_tracker::gc_registry;

use account_actions::access_control;
use account_actions::currency;
use account_actions::memo;
use account_actions::package_upgrade;
use account_actions::transfer;
use account_actions::vault;
use account_actions::vesting;
use account_protocol::account::Account;
use account_protocol::intents::Expired;
use account_protocol::owned;
use futarchy_actions::config_actions;
use futarchy_actions::liquidity_actions;
use futarchy_actions::quota_actions;
use futarchy_core::futarchy_config::{FutarchyConfig, FutarchyOutcome};
use futarchy_governance_actions::protocol_admin_actions;
use futarchy_oracle::oracle_actions;

/// Register one delete_* per action you actually use in futarchy.
/// This module serves as a central registry for all delete functions.
/// Each function delegates to the appropriate module's delete function.



// === Config Actions ===
public fun delete_config_update(expired: &mut Expired) {
    config_actions::delete_config_action<FutarchyConfig>(expired);
}

public fun delete_trading_params(expired: &mut Expired) {
    config_actions::delete_trading_params_update<FutarchyConfig>(expired);
}

public fun delete_metadata_update(expired: &mut Expired) {
    config_actions::delete_metadata_update<FutarchyConfig>(expired);
}

public fun delete_governance_update(expired: &mut Expired) {
    config_actions::delete_governance_update<FutarchyConfig>(expired);
}




// === Liquidity Actions ===
public fun delete_add_liquidity<AssetType, StableType>(expired: &mut Expired) {
    liquidity_actions::delete_add_liquidity<AssetType, StableType>(expired);
}

public fun delete_withdraw_lp_token<AssetType, StableType>(expired: &mut Expired) {
    liquidity_actions::delete_withdraw_lp_token<AssetType, StableType>(expired);
}

public fun delete_remove_liquidity<AssetType, StableType>(expired: &mut Expired) {
    liquidity_actions::delete_remove_liquidity<AssetType, StableType>(expired);
}

public fun delete_create_pool<AssetType, StableType>(expired: &mut Expired) {
    liquidity_actions::delete_create_pool<AssetType, StableType>(expired);
}

public fun delete_update_pool_params(expired: &mut Expired) {
    liquidity_actions::delete_update_pool_params(expired);
}


// === Package Upgrade Actions ===
public fun delete_upgrade_commit(expired: &mut Expired) {
    package_upgrade::delete_upgrade(expired);
}

public fun delete_restrict_policy(expired: &mut Expired) {
    package_upgrade::delete_restrict(expired);
}

public fun delete_upgrade_commit_action(expired: &mut Expired) {
    package_upgrade::delete_commit(expired);
}

// === Owned Object Actions ===
public fun delete_owned_withdraw(account: &Account, expired: &mut Expired) {
    account_protocol::owned::delete_withdraw_object(expired, account);
}

// === Vault Actions ===
public fun delete_vault_spend<CoinType>(expired: &mut Expired) {
    vault::delete_spend<CoinType>(expired);
}

public fun delete_vault_deposit<CoinType>(expired: &mut Expired) {
    vault::delete_deposit<CoinType>(expired);
}

// === Currency Actions ===
public fun delete_currency_mint<CoinType>(expired: &mut Expired) {
    currency::delete_mint<CoinType>(expired);
}

public fun delete_currency_burn<CoinType>(expired: &mut Expired) {
    currency::delete_burn<CoinType>(expired);
}

public fun delete_currency_update_metadata<CoinType>(expired: &mut Expired) {
    currency::delete_update<CoinType>(expired);
}

public fun delete_currency_disable<CoinType>(expired: &mut Expired) {
    currency::delete_disable<CoinType>(expired);
}

// === Vesting Actions ===
public fun delete_vesting_action<CoinType>(expired: &mut Expired) {
    vesting::delete_vesting_action<CoinType>(expired);
}

public fun delete_cancel_vesting_action(expired: &mut Expired) {
    vesting::delete_cancel_vesting_action(expired);
}

// === Transfer Actions ===
public fun delete_transfer(expired: &mut Expired) {
    transfer::delete_transfer(expired);
}

public fun delete_transfer_to_sender(expired: &mut Expired) {
    transfer::delete_transfer_to_sender(expired);
}

// === Access Control Actions ===
public fun delete_borrow_cap<Cap>(expired: &mut Expired) {
    access_control::delete_borrow<Cap>(expired);
}

public fun delete_return_cap<Cap>(expired: &mut Expired) {
    access_control::delete_return<Cap>(expired);
}

// === Memo Actions ===
public fun delete_memo(expired: &mut Expired) {
    memo::delete_memo(expired);
}


// === Quota Actions ===
public fun delete_set_quotas(expired: &mut Expired) {
    quota_actions::delete_set_quotas(expired);
}

// === Protocol Admin Actions ===
public fun delete_protocol_admin_action(expired: &mut Expired) {
    protocol_admin_actions::delete_protocol_admin_action(expired);
}

// === Additional Liquidity Actions ===
public fun delete_set_pool_status(expired: &mut Expired) {
    liquidity_actions::delete_set_pool_status(expired);
}

public fun delete_swap<AssetType, StableType>(expired: &mut Expired) {
    liquidity_actions::delete_swap<AssetType, StableType>(expired);
}

public fun delete_collect_fees<AssetType, StableType>(expired: &mut Expired) {
    liquidity_actions::delete_collect_fees<AssetType, StableType>(expired);
}

public fun delete_withdraw_fees<AssetType, StableType>(expired: &mut Expired) {
    liquidity_actions::delete_withdraw_fees<AssetType, StableType>(expired);
}

// === Additional Config Actions ===
public fun delete_set_proposals_enabled<Config>(expired: &mut Expired) {
    config_actions::delete_set_proposals_enabled<Config>(expired);
}

public fun delete_update_name<Config>(expired: &mut Expired) {
    config_actions::delete_update_name<Config>(expired);
}

public fun delete_twap_config_update<Config>(expired: &mut Expired) {
    config_actions::delete_twap_config_update<Config>(expired);
}

public fun delete_metadata_table_update<Config>(expired: &mut Expired) {
    config_actions::delete_metadata_table_update<Config>(expired);
}

public fun delete_queue_params_update<Config>(expired: &mut Expired) {
    config_actions::delete_queue_params_update<Config>(expired);
}