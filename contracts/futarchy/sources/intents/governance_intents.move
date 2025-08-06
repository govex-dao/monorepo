/// Governance module for creating and executing intents from approved proposals
/// This module provides a simplified interface for governance operations
module futarchy::governance_intents;

// === Imports ===
use std::string::String;
use sui::clock::Clock;
use account_protocol::{
    account::Account,
    executable::Executable,
    intents::{Self, Intent, Params},
};
use futarchy::{
    futarchy_config::{Self, FutarchyConfig, FutarchyOutcome},
    proposal::Proposal,
    market_state::MarketState,
    version,
};

// === Witness ===
/// Single witness for governance intents
public struct GovernanceWitness has copy, drop {}

/// Get the governance witness
public fun witness(): GovernanceWitness {
    GovernanceWitness {}
}

// === Intent Creation Functions ===

/// Create a simple treasury transfer intent
/// For actual transfers, use vault_intents::request_spend_and_transfer directly
public fun create_transfer_intent<CoinType>(
    account: &Account<FutarchyConfig>,
    recipient: address,
    amount: u64,
    clock: &Clock,
    ctx: &mut TxContext
): Intent<FutarchyOutcome> {
    // Generate intent key
    let mut intent_key = b"transfer_".to_string();
    intent_key.append(recipient.to_string());
    intent_key.append(b"_".to_string());
    intent_key.append(amount.to_string());
    
    // Create outcome
    let outcome = futarchy_config::new_outcome_for_intent(
        intent_key,
        clock.timestamp_ms() + 86_400_000, // 24 hour execution window
    );
    
    // Create intent parameters
    let params = intents::new_params(
        intent_key,
        b"Treasury Transfer".to_string(),
        vector[clock.timestamp_ms() + 3_600_000], // 1 hour delay
        clock.timestamp_ms() + 86_400_000, // 24 hour expiry
        clock,
        ctx
    );
    
    // Create intent using account
    let intent = account.create_intent(
        params,
        outcome,
        b"TreasuryTransfer".to_string(),
        version::current(),
        witness(),
        ctx
    );
    
    // Note: Actions should be added by the caller using vault_intents
    intent
}

/// Create a config update intent
public fun create_config_intent(
    account: &Account<FutarchyConfig>,
    update_type: String,
    clock: &Clock,
    ctx: &mut TxContext
): Intent<FutarchyOutcome> {
    // Generate intent key
    let mut intent_key = b"config_".to_string();
    intent_key.append(update_type);
    intent_key.append(b"_".to_string());
    intent_key.append(clock.timestamp_ms().to_string());
    
    // Create outcome
    let outcome = futarchy_config::new_outcome_for_intent(
        intent_key,
        clock.timestamp_ms() + 86_400_000,
    );
    
    // Create intent parameters
    let params = intents::new_params(
        intent_key,
        b"Config Update".to_string(),
        vector[clock.timestamp_ms() + 3_600_000],
        clock.timestamp_ms() + 86_400_000,
        clock,
        ctx
    );
    
    // Create intent
    let intent = account.create_intent(
        params,
        outcome,
        b"ConfigUpdate".to_string(),
        version::current(),
        witness(),
        ctx
    );
    
    intent
}

/// Create a dissolution intent
public fun create_dissolution_intent(
    account: &Account<FutarchyConfig>,
    clock: &Clock,
    ctx: &mut TxContext
): Intent<FutarchyOutcome> {
    // Generate intent key
    let mut intent_key = b"dissolution_".to_string();
    intent_key.append(clock.timestamp_ms().to_string());
    
    // Create outcome
    let outcome = futarchy_config::new_outcome_for_intent(
        intent_key,
        clock.timestamp_ms() + 86_400_000,
    );
    
    // Create intent parameters
    let params = intents::new_params(
        intent_key,
        b"DAO Dissolution".to_string(),
        vector[clock.timestamp_ms() + 7_200_000], // 2 hour delay for dissolution
        clock.timestamp_ms() + 86_400_000,
        clock,
        ctx
    );
    
    // Create intent
    let intent = account.create_intent(
        params,
        outcome,
        b"Dissolution".to_string(),
        version::current(),
        witness(),
        ctx
    );
    
    intent
}

// === Execution Functions ===

/// Execute a governance intent from an approved proposal
/// This is called after a proposal is approved and its market is finalized
/// Note: The actual execution is delegated to futarchy_config::execute_proposal_intent
public fun execute_proposal_intent<AssetType, StableType>(
    account: &mut Account<FutarchyConfig>,
    proposal: &Proposal<AssetType, StableType>,
    market: &MarketState,
    clock: &Clock,
    ctx: &mut TxContext
): Executable<FutarchyOutcome> {
    // Delegate to futarchy_config which has the proper implementation
    futarchy_config::execute_proposal_intent(
        account,
        proposal,
        market,
        clock,
        ctx
    )
}

// === Helper Functions ===

/// Create FutarchyOutcome from proposal and market data
public fun create_outcome_from_proposal<AssetType, StableType>(
    proposal: &Proposal<AssetType, StableType>,
    market: &MarketState,
    approved: bool,
    clock: &Clock,
): FutarchyOutcome {
    futarchy_config::new_futarchy_outcome(
        b"governance_proposal".to_string(),
        option::some(object::id(proposal)),
        option::some(object::id(market)),
        approved,
        clock.timestamp_ms() + 86_400_000, // 24 hour execution window
    )
}

/// Helper to create intent params with standard settings
public fun create_standard_params(
    key: String,
    description: String,
    delay_ms: u64,
    expiry_ms: u64,
    clock: &Clock,
    ctx: &mut TxContext
): Params {
    intents::new_params(
        key,
        description,
        vector[clock.timestamp_ms() + delay_ms],
        clock.timestamp_ms() + expiry_ms,
        clock,
        ctx
    )
}

// === Notes ===
// For actual action execution, use the appropriate modules directly:
// - Transfers: account_actions::vault_intents
// - Config: futarchy_actions::config_intents
// - Liquidity: futarchy_actions::liquidity_intents
// - Dissolution: futarchy_actions::dissolution_intents
// - Streaming: futarchy_actions::stream_intents