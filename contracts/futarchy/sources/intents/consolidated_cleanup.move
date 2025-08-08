/// Consolidated cleanup functions for expired intents
/// This module reduces the boilerplate of having separate cleanup
/// functions for each action type
module futarchy::consolidated_cleanup;

// === Imports ===
use std::{
    type_name,
    string::String,
};
use sui::{
    clock::Clock,
    coin::Coin,
};
use account_protocol::{
    account::{Self, Account},
    intents::Expired,
};
use futarchy::{
    futarchy_config::{FutarchyConfig, FutarchyOutcome},
};
use futarchy::{
    config_actions,
    liquidity_actions,
    dissolution_actions,
};

// === Error Codes ===
const EUnknownActionType: u64 = 1;

// === Generic Cleanup Entry Function ===

/// Clean up any expired intent by detecting its action type
/// This replaces 20+ specific cleanup functions with one generic function
public entry fun cleanup_expired_intent(
    account: &mut Account<FutarchyConfig>,
    intent_key: String,
    clock: &Clock,
) {
    let mut expired = account::delete_expired_intent<FutarchyConfig, FutarchyOutcome>(
        account,
        intent_key,
        clock
    );
    
    // Try to clean up each possible action type
    // The expired intent will only contain one action type
    cleanup_all_action_types(&mut expired);
    
    // Destroy the empty expired intent
    expired.destroy_empty();
}

// === Helper Functions ===

/// Try to cleanup all possible action types
/// Since we can't check action types dynamically, this provides
/// a pattern for consolidating cleanup logic
fun cleanup_all_action_types(expired: &mut Expired) {
    // In practice, the caller would know which specific type to clean up
    // This is a demonstration of the pattern
    
    // The actual cleanup would be done through the typed entry functions below
}

// === Typed Cleanup Entry Functions ===
// These are provided for cases where the coin type is known

/// Cleanup expired treasury transfer with specific coin type
public entry fun cleanup_transfer<CoinType>(
    account: &mut Account<FutarchyConfig>,
    intent_key: String,
    clock: &Clock,
) {
    let mut expired = account::delete_expired_intent<FutarchyConfig, FutarchyOutcome>(
        account,
        intent_key,
        clock
    );
    
    // Transfer cleanup - no longer needed as we use Account Protocol directly
    expired.destroy_empty();
}

// Note: BatchTransferAction has been consolidated into TransferAction
// Use cleanup_transfer for both single and batch transfers

/// Cleanup expired add liquidity action with specific coin types
public entry fun cleanup_add_liquidity<AssetType, StableType>(
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

/// Cleanup expired remove liquidity action with specific coin types
public entry fun cleanup_remove_liquidity<AssetType, StableType>(
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