/// Governance module for creating and executing intents from approved proposals
/// This module provides a simplified interface for governance operations
module futarchy_specialized_actions::governance_intents;

// === Imports ===
use std::string::{Self, String};
use std::option;
use std::vector;
use sui::{
    clock::Clock,
    tx_context::TxContext,
    object,
};
use account_protocol::{
    account::{Self, Account},
    executable::{Self, Executable},
    intents::{Self, Intent, Params},
    intent_interface,
};
use futarchy_core::version;
use futarchy_core::{
    futarchy_config::{Self, FutarchyConfig},
};
use futarchy_markets::{
    proposal::{Self, Proposal},
    market_state::MarketState,
};

// === Aliases ===
use fun intent_interface::build_intent as Account.build_intent;

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
public fun create_transfer_intent<CoinType, Outcome: store + drop + copy>(
    account: &Account<FutarchyConfig>,
    recipient: address,
    amount: u64,
    outcome: Outcome,
    clock: &Clock,
    ctx: &mut TxContext
): Intent<Outcome> {
    // Generate intent key
    let mut intent_key = b"transfer_".to_string();
    intent_key.append(recipient.to_string());
    intent_key.append(b"_".to_string());
    intent_key.append(amount.to_string());
    
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
public fun create_config_intent<Outcome: store + drop + copy>(
    account: &Account<FutarchyConfig>,
    update_type: String,
    outcome: Outcome,
    clock: &Clock,
    ctx: &mut TxContext
): Intent<Outcome> {
    // Generate intent key
    let mut intent_key = b"config_".to_string();
    intent_key.append(update_type);
    intent_key.append(b"_".to_string());
    intent_key.append(clock.timestamp_ms().to_string());
    
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
public fun create_dissolution_intent<Outcome: store + drop + copy>(
    account: &Account<FutarchyConfig>,
    outcome: Outcome,
    clock: &Clock,
    ctx: &mut TxContext
): Intent<Outcome> {
    // Generate intent key
    let mut intent_key = b"dissolution_".to_string();
    intent_key.append(clock.timestamp_ms().to_string());
    
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
/// This retrieves the stored intent and converts it to an executable for execution
/// The intent should have been created when the proposal was submitted to the queue
public fun execute_proposal_intent<AssetType, StableType, Outcome: store + drop + copy>(
    account: &mut Account<FutarchyConfig>,
    proposal: &Proposal<AssetType, StableType>,
    _market: &MarketState,
    outcome_index: u64,
    clock: &Clock,
    _ctx: &mut TxContext
): Executable<Outcome> {
    // Get the intent key from the proposal for the specified outcome
    let intent_key_opt = proposal::get_intent_key_for_outcome(proposal, outcome_index);
    
    // Extract the intent key - if no key exists, this indicates no action was defined for this outcome
    assert!(option::is_some(intent_key_opt), 4); // EIntentNotFound
    let intent_key = *option::borrow(intent_key_opt);
    
    // Execute the intent - pull it from the account and create an executable
    // The intent was previously stored when the proposal was created
    let (_outcome, executable) = account::create_executable<FutarchyConfig, Outcome, GovernanceWitness>(
        account,
        intent_key,
        clock,
        version::current(),
        GovernanceWitness{},
    );
    
    executable
}

// === Helper Functions ===

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
// - Config: futarchy::config_intents
// - Liquidity: futarchy::liquidity_intents
// - Dissolution: futarchy::dissolution_intents
// - Streaming: futarchy::stream_intents