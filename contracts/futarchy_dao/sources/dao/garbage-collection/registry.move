// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

module futarchy_dao::gc_registry;

use account_actions::access_control;
use account_actions::currency;
use account_actions::kiosk;
use account_actions::package_upgrade;
use account_actions::transfer;
use account_actions::vault;
use account_actions::vesting;
use account_protocol::account::Account;
use account_protocol::intents::Expired;
use account_protocol::owned;
use futarchy_actions::config_actions;
use futarchy_actions::liquidity_actions;
use futarchy_actions::memo_actions;
use futarchy_actions::quota_actions;
use futarchy_core::futarchy_config::{FutarchyConfig, FutarchyOutcome};
use futarchy_governance_actions::protocol_admin_actions;
use futarchy_legal_actions::dao_file_actions;
use futarchy_legal_actions::walrus_renewal;
use futarchy_lifecycle::dissolution_actions;
use futarchy_multisig::policy_actions;
use futarchy_multisig::security_council_actions;
use futarchy_oracle::oracle_actions;
use futarchy_dividend_actions::dividend_actions;
use futarchy_stream_actions::stream_actions;

/// Register one delete_* per action you actually use in futarchy.
/// This module serves as a central registry for all delete functions.
/// Each function delegates to the appropriate module's delete function.

// === DAO File Actions ===
public fun delete_dao_file_create_registry(expired: &mut Expired) {
    dao_file_actions::delete_create_registry(expired);
}

public fun delete_dao_file_create_root_document(expired: &mut Expired) {
    dao_file_actions::delete_create_root_document(expired);
}

public fun delete_dao_file_delete_document(expired: &mut Expired) {
    dao_file_actions::delete_delete_document(expired);
}

public fun delete_dao_file_add_chunk(expired: &mut Expired) {
    dao_file_actions::delete_add_chunk(expired);
}

public fun delete_dao_file_update(expired: &mut Expired) {
    dao_file_actions::delete_update_chunk(expired);
}

public fun delete_dao_file_remove(expired: &mut Expired) {
    dao_file_actions::delete_remove_chunk(expired);
}

public fun delete_dao_file_set_chunk_immutable(expired: &mut Expired) {
    dao_file_actions::delete_set_chunk_immutable(expired);
}

public fun delete_dao_file_set_document_immutable(expired: &mut Expired) {
    dao_file_actions::delete_set_document_immutable(expired);
}

public fun delete_dao_file_set_registry_immutable(expired: &mut Expired) {
    dao_file_actions::delete_set_registry_immutable(expired);
}

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

public fun delete_slash_distribution(expired: &mut Expired) {
    config_actions::delete_slash_distribution_update<FutarchyConfig>(expired);
}

// === Security Council Actions ===
public fun delete_create_council(expired: &mut Expired) {
    futarchy_multisig::security_council_actions::delete_create_council(expired);
}

public fun delete_update_council_membership(expired: &mut Expired) {
    futarchy_multisig::security_council_actions::delete_update_council_membership(expired);
}

public fun delete_approve_policy_change(expired: &mut Expired) {
    futarchy_multisig::security_council_actions::delete_approve_generic(expired);
}

// === Vault/Custody Actions ===
// REMOVED: custody_actions deleted, add/remove coin type actions deleted

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

// === Policy Actions ===
public fun delete_set_policy(expired: &mut Expired) {
    futarchy_multisig::policy_actions::delete_set_type_policy(expired);
}

public fun delete_remove_policy(expired: &mut Expired) {
    futarchy_multisig::policy_actions::delete_remove_type_policy(expired);
}

// === Dissolution Actions ===
public fun delete_initiate_dissolution(expired: &mut Expired) {
    dissolution_actions::delete_initiate_dissolution(expired);
}

public fun delete_batch_distribute(expired: &mut Expired) {
    dissolution_actions::delete_batch_distribute(expired);
}

public fun delete_finalize_dissolution(expired: &mut Expired) {
    dissolution_actions::delete_finalize_dissolution(expired);
}

public fun delete_cancel_dissolution(expired: &mut Expired) {
    dissolution_actions::delete_cancel_dissolution(expired);
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
public fun delete_owned_withdraw(account: &Account<FutarchyConfig>, expired: &mut Expired) {
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

// === Kiosk Actions ===
public fun delete_kiosk_take(expired: &mut Expired) {
    kiosk::delete_take(expired);
}

public fun delete_kiosk_list(expired: &mut Expired) {
    kiosk::delete_list(expired);
}

// === Access Control Actions ===
public fun delete_borrow_cap<Cap>(expired: &mut Expired) {
    access_control::delete_borrow<Cap>(expired);
}

public fun delete_return_cap<Cap>(expired: &mut Expired) {
    access_control::delete_return<Cap>(expired);
}

// === Stream/Payment Actions ===
public fun delete_create_payment<CoinType>(expired: &mut Expired) {
    stream_actions::delete_create_payment<CoinType>(expired);
}

public fun delete_execute_payment<CoinType>(expired: &mut Expired) {
    stream_actions::delete_execute_payment<CoinType>(expired);
}

public fun delete_cancel_payment<CoinType>(expired: &mut Expired) {
    stream_actions::delete_cancel_payment<CoinType>(expired);
}

public fun delete_update_payment_recipient(expired: &mut Expired) {
    stream_actions::delete_update_payment_recipient(expired);
}

public fun delete_add_withdrawer(expired: &mut Expired) {
    stream_actions::delete_add_withdrawer(expired);
}

public fun delete_remove_withdrawers(expired: &mut Expired) {
    stream_actions::delete_remove_withdrawers(expired);
}

public fun delete_toggle_payment(expired: &mut Expired) {
    stream_actions::delete_toggle_payment(expired);
}

public fun delete_request_withdrawal<CoinType>(expired: &mut Expired) {
    stream_actions::delete_request_withdrawal<CoinType>(expired);
}

public fun delete_challenge_withdrawals(expired: &mut Expired) {
    stream_actions::delete_challenge_withdrawals(expired);
}

public fun delete_process_pending_withdrawal<CoinType>(expired: &mut Expired) {
    stream_actions::delete_process_pending_withdrawal<CoinType>(expired);
}

public fun delete_cancel_challenged_withdrawals(expired: &mut Expired) {
    stream_actions::delete_cancel_challenged_withdrawals(expired);
}

// === Governance Actions ===
// REMOVED: Second-order proposals and reservation system deleted

// === Oracle Actions ===
// NOTE: ConditionalMint and TieredMint have been replaced by PriceBasedMintGrant shared object
// ReadOraclePrice action has drop, no cleanup needed

// === Memo Actions ===
public fun delete_memo(expired: &mut Expired) {
    memo_actions::delete_memo(expired);
}

// === Dividend Actions ===
public fun delete_create_dividend<CoinType>(expired: &mut Expired) {
    dividend_actions::delete_create_dividend<CoinType>(expired);
}

// === Platform Fee Actions ===
// REMOVED: Deprecated platform fee collection system deleted

// === Walrus Renewal Actions ===
public fun delete_walrus_renewal(expired: &mut Expired) {
    walrus_renewal::delete_walrus_renewal(expired);
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

// === Additional DAO File Actions ===
public fun delete_set_document_insert_allowed(expired: &mut Expired) {
    dao_file_actions::delete_set_document_insert_allowed(expired);
}

public fun delete_set_document_remove_allowed(expired: &mut Expired) {
    dao_file_actions::delete_set_document_remove_allowed(expired);
}

// === Additional Dissolution Actions ===
public fun delete_calculate_pro_rata_shares(expired: &mut Expired) {
    dissolution_actions::delete_calculate_pro_rata_shares(expired);
}

public fun delete_cancel_all_streams(expired: &mut Expired) {
    dissolution_actions::delete_cancel_all_streams(expired);
}

public fun delete_distribute_assets<CoinType>(expired: &mut Expired) {
    dissolution_actions::delete_distribute_assets<CoinType>(expired);
}

public fun delete_withdraw_amm_liquidity<AssetType, StableType>(expired: &mut Expired) {
    dissolution_actions::delete_withdraw_amm_liquidity<AssetType, StableType>(expired);
}

// === Additional Policy Actions ===
public fun delete_register_council(expired: &mut Expired) {
    policy_actions::delete_register_council(expired);
}

public fun delete_set_object_policy(expired: &mut Expired) {
    policy_actions::delete_set_object_policy(expired);
}

public fun delete_remove_object_policy(expired: &mut Expired) {
    policy_actions::delete_remove_object_policy(expired);
}
