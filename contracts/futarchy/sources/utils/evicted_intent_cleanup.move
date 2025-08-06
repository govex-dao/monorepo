/// Helper module for cleaning up evicted intents from the priority queue
/// This module provides entry functions that can be called by keepers or admins
/// to clean up intents that were evicted from the proposal queue
module futarchy::evicted_intent_cleanup;

// === Imports ===
use std::string::String;
use sui::clock::Clock;
use account_protocol::{
    account::{Self, Account},
    intents::Expired,
};
use futarchy::{
    futarchy_config::{FutarchyConfig, FutarchyOutcome},
    version,
};
use futarchy_actions::{
    config_actions,
    dissolution_actions,
    liquidity_actions,
};

// === Entry Functions for Different Intent Types ===

/// Clean up evicted config intent with set proposals enabled action
public entry fun cleanup_set_proposals_enabled_intent(
    account: &mut Account<FutarchyConfig>,
    intent_key: String,
    clock: &Clock,
) {
    let mut expired = account::delete_expired_intent<FutarchyConfig, FutarchyOutcome>(
        account,
        intent_key,
        clock
    );
    
    config_actions::delete_set_proposals_enabled(&mut expired);
    expired.destroy_empty();
}

/// Clean up evicted config intent with update name action
public entry fun cleanup_update_name_intent(
    account: &mut Account<FutarchyConfig>,
    intent_key: String,
    clock: &Clock,
) {
    let mut expired = account::delete_expired_intent<FutarchyConfig, FutarchyOutcome>(
        account,
        intent_key,
        clock
    );
    
    config_actions::delete_update_name(&mut expired);
    expired.destroy_empty();
}

/// Clean up evicted treasury intent with transfer action
public entry fun cleanup_transfer_intent<CoinType>(
    account: &mut Account<FutarchyConfig>,
    intent_key: String,
    clock: &Clock,
) {
    let mut expired = account::delete_expired_intent<FutarchyConfig, FutarchyOutcome>(
        account,
        intent_key,
        clock
    );
    
    // Transfer cleanup - no longer needed as we use Account Protocol
    expired.destroy_empty();
}

/// Clean up evicted treasury intent with transfer asset action
public entry fun cleanup_transfer_asset_intent<AssetType: key + store>(
    account: &mut Account<FutarchyConfig>,
    intent_key: String,
    clock: &Clock,
) {
    let mut expired = account::delete_expired_intent<FutarchyConfig, FutarchyOutcome>(
        account,
        intent_key,
        clock
    );
    
    // Asset transfer cleanup - no longer needed
    expired.destroy_empty();
}

/// Clean up evicted liquidity intent with add liquidity action
public entry fun cleanup_add_liquidity_intent<AssetType, StableType>(
    account: &mut Account<FutarchyConfig>,
    intent_key: String,
    clock: &Clock,
) {
    let mut expired = account::delete_expired_intent<FutarchyConfig, FutarchyOutcome>(
        account,
        intent_key,
        clock
    );
    
    liquidity_actions::delete_add_liquidity<AssetType, StableType>(&mut expired);
    expired.destroy_empty();
}

/// Clean up evicted liquidity intent with remove liquidity action
public entry fun cleanup_remove_liquidity_intent<AssetType, StableType>(
    account: &mut Account<FutarchyConfig>,
    intent_key: String,
    clock: &Clock,
) {
    let mut expired = account::delete_expired_intent<FutarchyConfig, FutarchyOutcome>(
        account,
        intent_key,
        clock
    );
    
    liquidity_actions::delete_remove_liquidity<AssetType, StableType>(&mut expired);
    expired.destroy_empty();
}

/// Clean up evicted dissolution intent
public entry fun cleanup_dissolution_intent(
    account: &mut Account<FutarchyConfig>,
    intent_key: String,
    clock: &Clock,
) {
    let mut expired = account::delete_expired_intent<FutarchyConfig, FutarchyOutcome>(
        account,
        intent_key,
        clock
    );
    
    dissolution_actions::delete_initiate_dissolution(&mut expired);
    expired.destroy_empty();
}

/// Clean up a generic evicted intent with no specific actions
/// This can be used for intents that only contain metadata or empty actions
public entry fun cleanup_generic_intent(
    account: &mut Account<FutarchyConfig>,
    intent_key: String,
    clock: &Clock,
) {
    let expired = account::delete_expired_intent<FutarchyConfig, FutarchyOutcome>(
        account,
        intent_key,
        clock
    );
    
    // Just destroy the empty expired intent
    expired.destroy_empty();
}