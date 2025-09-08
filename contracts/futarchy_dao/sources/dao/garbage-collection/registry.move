module futarchy_dao::gc_registry;

use account_protocol::{
    intents::Expired,
    account::Account,
    owned,
};
use account_actions::{
    package_upgrade,
    vault,
    currency,
    kiosk,
    access_control,
};
use futarchy_core::futarchy_config::FutarchyConfig;
use futarchy_actions::{
    config_actions,
    memo_actions,
    liquidity_actions,
    governance_actions,
};
use futarchy_lifecycle::dissolution_actions;
use futarchy_specialized_actions::{
    operating_agreement_actions,
    stream_actions,
    oracle_actions,
};
use futarchy_multisig::{
    security_council_actions,
    policy_actions,
};

/// Register one delete_* per action you actually use in futarchy.
/// This module serves as a central registry for all delete functions.
/// Each function delegates to the appropriate module's delete function.

// === Operating Agreement Actions ===
public fun delete_operating_agreement_update(expired: &mut Expired) {
    operating_agreement_actions::delete_update_line(expired);
}

public fun delete_operating_agreement_insert(expired: &mut Expired) {
    operating_agreement_actions::delete_insert_line_after(expired);
}

public fun delete_operating_agreement_remove(expired: &mut Expired) {
    operating_agreement_actions::delete_remove_line(expired);
}

public fun delete_operating_agreement_batch(expired: &mut Expired) {
    operating_agreement_actions::delete_batch_operating_agreement(expired);
}

// === Config Actions ===
public fun delete_config_update(expired: &mut Expired) {
    config_actions::delete_config_action(expired);
}

public fun delete_trading_params(expired: &mut Expired) {
    config_actions::delete_trading_params_update(expired);
}

public fun delete_metadata_update(expired: &mut Expired) {
    config_actions::delete_metadata_update(expired);
}

public fun delete_governance_update(expired: &mut Expired) {
    config_actions::delete_governance_update(expired);
}

public fun delete_slash_distribution(expired: &mut Expired) {
    config_actions::delete_slash_distribution_update(expired);
}

// === Security Council Actions ===
public fun delete_create_council(expired: &mut Expired) {
    futarchy_multisig::security_council_actions::delete_create_council(expired);
}

public fun delete_approve_oa_change(expired: &mut Expired) {
    futarchy_multisig::security_council_actions::delete_approve_oa_change(expired);
}

public fun delete_update_council_membership(expired: &mut Expired) {
    futarchy_multisig::security_council_actions::delete_update_council_membership(expired);
}

public fun delete_approve_policy_change(expired: &mut Expired) {
    futarchy_multisig::security_council_actions::delete_approve_generic(expired);
}

// === Vault/Custody Actions ===
public fun delete_approve_custody<R>(expired: &mut Expired) {
    futarchy_vault::custody_actions::delete_approve_custody<R>(expired);
}

public fun delete_accept_into_custody<R>(expired: &mut Expired) {
    futarchy_vault::custody_actions::delete_accept_into_custody<R>(expired);
}

public fun delete_add_coin_type<CoinType>(expired: &mut Expired) {
    futarchy_vault::futarchy_vault::delete_add_coin_type<CoinType>(expired);
}

public fun delete_remove_coin_type<CoinType>(expired: &mut Expired) {
    futarchy_vault::futarchy_vault::delete_remove_coin_type<CoinType>(expired);
}

// === Liquidity Actions ===
public fun delete_add_liquidity<AssetType, StableType>(expired: &mut Expired) {
    liquidity_actions::delete_add_liquidity<AssetType, StableType>(expired);
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
    futarchy_multisig::policy_actions::delete_set_policy(expired);
}

public fun delete_remove_policy(expired: &mut Expired) {
    futarchy_multisig::policy_actions::delete_remove_policy(expired);
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

// === Owned Object Actions ===
public fun delete_owned_withdraw(account: &Account<FutarchyConfig>, expired: &mut Expired) {
    account_protocol::owned::delete_withdraw(expired, account);
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

// === Stream/Payment Actions ===
public fun delete_create_payment<CoinType>(expired: &mut Expired) {
    stream_actions::delete_create_payment<CoinType>(expired);
}

public fun delete_create_budget_stream<CoinType>(expired: &mut Expired) {
    stream_actions::delete_create_budget_stream<CoinType>(expired);
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
public fun delete_create_proposal(expired: &mut Expired) {
    governance_actions::delete_create_proposal(expired);
}

public fun delete_proposal_reservation(expired: &mut Expired) {
    governance_actions::delete_proposal_reservation(expired);
}

// === Oracle Actions ===
// Note: ReadOraclePriceAction has drop ability, not stored in expired intents
// Only mint actions need cleanup

public fun delete_conditional_mint<CoinType>(expired: &mut Expired) {
    oracle_actions::delete_conditional_mint<CoinType>(expired);
}

public fun delete_tiered_mint<CoinType>(expired: &mut Expired) {
    oracle_actions::delete_tiered_mint<CoinType>(expired);
}

// === Memo Actions ===
public fun delete_memo(expired: &mut Expired) {
    memo_actions::delete_memo(expired);
}