/// Factory module for creating intents from proposal data
/// This module helps create the appropriate intents based on proposal types
module futarchy::proposal_intent_factory;

// === Imports ===
use std::string::String;
use sui::{
    clock::Clock,
    coin::Coin,
    object::{Self, ID},
    tx_context::TxContext,
};
use account_protocol::{
    account::{Self, Account},
    intents::{Self, Intent},
};
use futarchy::{
    futarchy_config::{Self, FutarchyConfig},
    governance_intents,
    intent_witnesses,
    version,
};
use futarchy::{
    config_intents,
    liquidity_intents,
    dissolution_intents,
    advanced_config_actions,
    stream_intents,
};
use account_actions::{
    currency_intents,
    vault_intents,
};

// === Constants ===
const PROPOSAL_TYPE_TRANSFER: vector<u8> = b"transfer";
const PROPOSAL_TYPE_CONFIG: vector<u8> = b"config";
const PROPOSAL_TYPE_LIQUIDITY: vector<u8> = b"liquidity";
const PROPOSAL_TYPE_DISSOLUTION: vector<u8> = b"dissolution";

// === Errors ===
const EInvalidProposalType: u64 = 1;
const EInvalidProposalData: u64 = 2;

// === Public Functions ===

/// Generate a unique intent key without requiring proposal ID
/// Uses intent type, timestamp, and action-specific data
fun generate_intent_key(
    intent_type: String,
    recipient: address,
    amount: u64,
    clock: &Clock,
): String {
    let mut key = intent_type;
    key.append(b"_".to_string());
    key.append(recipient.to_string());
    key.append(b"_".to_string());
    key.append(amount.to_string());
    key.append(b"_".to_string());
    key.append(clock.timestamp_ms().to_string());
    
    key
}

/// Generate intent key for config updates
fun generate_config_intent_key(
    min_asset_amount: u64,
    min_stable_amount: u64,
    clock: &Clock,
): String {
    let mut key = b"config_update".to_string();
    key.append(b"_".to_string());
    key.append(min_asset_amount.to_string());
    key.append(b"_".to_string());
    key.append(min_stable_amount.to_string());
    key.append(b"_".to_string());
    key.append(clock.timestamp_ms().to_string());
    
    key
}

/// Generate intent key for liquidity operations
fun generate_liquidity_intent_key(
    pool_id: ID,
    asset_amount: u64,
    stable_amount: u64,
    clock: &Clock,
): String {
    let mut key = b"liquidity_add".to_string();
    key.append(b"_".to_string());
    key.append(object::id_to_address(&pool_id).to_string());
    key.append(b"_".to_string());
    key.append(asset_amount.to_string());
    key.append(b"_".to_string());
    key.append(stable_amount.to_string());
    key.append(b"_".to_string());
    key.append(clock.timestamp_ms().to_string());
    
    key
}

/// Create a treasury transfer intent
public fun create_treasury_transfer_intent<AssetType, Outcome: store + drop + copy>(
    account: &mut Account<FutarchyConfig>,
    recipient: address,
    amount: u64,
    outcome: Outcome,
    clock: &Clock,
    ctx: &mut TxContext,
): (String, Intent<Outcome>) {
    let config = account.config();
    
    // Generate a unique intent key
    let intent_key = generate_intent_key(
        b"treasury_transfer".to_string(),
        recipient,
        amount,
        clock
    );
    
    // Use the provided outcome
    
    // Create intent parameters
    let params = intents::new_params(
        intent_key,
        b"Treasury transfer proposal".to_string(),
        vector[clock.timestamp_ms() + 3_600_000], // 1 hour delay
        clock.timestamp_ms() + 86_400_000, // 24 hour expiry // 24 hour expiry
        clock,
        ctx
    );
    
    // Create intent using account
    let mut intent = account::create_intent(
        account,
        params,
        outcome,
        b"TreasuryTransfer".to_string(),
        version::current(),
        intent_witnesses::governance(),
        ctx
    );
    
    // Add transfer action using vault_intents::request_spend_and_transfer
    // Note: Actual transfer action should be added by the caller
    
    (intent_key, intent)
}

/// Create a config update intent
public fun create_config_update_intent<Outcome: store + drop + copy>(
    account: &mut Account<FutarchyConfig>,
    min_asset_amount: u64,
    min_stable_amount: u64,
    review_period_ms: u64,
    trading_period_ms: u64,
    outcome: Outcome,
    clock: &Clock,
    ctx: &mut TxContext,
): (String, Intent<Outcome>) {
    let config = account.config();
    
    // Generate intent key
    let intent_key = generate_config_intent_key(
        min_asset_amount,
        min_stable_amount,
        clock
    );
    
    // Use the provided outcome
    
    // Create intent parameters
    let params = intents::new_params(
        intent_key,
        b"Config update proposal".to_string(),
        vector[clock.timestamp_ms() + 3_600_000], // 1 hour delay
        clock.timestamp_ms() + 86_400_000, // 24 hour expiry
        clock,
        ctx
    );
    
    // Create intent using account
    let mut intent = account::create_intent(
        account,
        params,
        outcome,
        b"ConfigUpdate".to_string(),
        version::current(),
        intent_witnesses::governance(),
        ctx
    );
    
    // Config actions should be added based on specific proposal requirements
    
    (intent_key, intent)
}

/// Create a liquidity addition intent
public fun create_liquidity_intent<AssetType, StableType, Outcome: store + drop + copy>(
    account: &mut Account<FutarchyConfig>,
    pool_id: ID,
    asset_amount: u64,
    stable_amount: u64,
    outcome: Outcome,
    clock: &Clock,
    ctx: &mut TxContext,
): (String, Intent<Outcome>) {
    let config = account.config();
    
    // Generate intent key
    let intent_key = generate_liquidity_intent_key(
        pool_id,
        asset_amount,
        stable_amount,
        clock
    );
    
    // Use the provided outcome
    
    // Create intent parameters
    let params = intents::new_params(
        intent_key,
        b"Liquidity addition proposal".to_string(),
        vector[clock.timestamp_ms() + 3_600_000], // 1 hour delay
        clock.timestamp_ms() + 86_400_000, // 24 hour expiry
        clock,
        ctx
    );
    
    // Create intent using account
    let mut intent = account::create_intent(
        account,
        params,
        outcome,
        b"LiquidityAddition".to_string(),
        version::current(),
        intent_witnesses::governance(),
        ctx
    );
    
    // Add liquidity action
    liquidity_intents::add_liquidity_to_intent<Outcome, AssetType, StableType, intent_witnesses::GovernanceWitness>(
        &mut intent,
        pool_id,
        asset_amount,
        stable_amount,
        0, // min_lp_amount - accept any amount of LP tokens
        intent_witnesses::governance()
    );
    
    (intent_key, intent)
}

/// Create a dissolution intent
public fun create_dissolution_intent<CoinType, Outcome: store + drop + copy>(
    account: &mut Account<FutarchyConfig>,
    outcome: Outcome,
    clock: &Clock,
    ctx: &mut TxContext,
): (String, Intent<Outcome>) {
    let config = account.config();
    
    // Generate intent key - dissolution is unique per timestamp
    let mut intent_key = b"dissolution_".to_string();
    intent_key.append(clock.timestamp_ms().to_string());
    
    // Use the provided outcome
    
    // Create intent parameters
    let params = intents::new_params(
        intent_key,
        b"DAO dissolution proposal".to_string(),
        vector[clock.timestamp_ms() + 3_600_000], // 1 hour delay
        clock.timestamp_ms() + 86_400_000, // 24 hour expiry
        clock,
        ctx
    );
    
    // Create intent using account
    let mut intent = account::create_intent(
        account,
        params,
        outcome,
        b"Dissolution".to_string(),
        version::current(),
        intent_witnesses::governance(),
        ctx
    );
    
    // Add dissolution action
    dissolution_intents::initiate_dissolution_in_intent<Outcome, intent_witnesses::GovernanceWitness>(
        &mut intent,
        b"DAO dissolution proposal approved".to_string(),
        0, // distribution_method: 0 = pro rata
        false, // burn_unsold_tokens
        clock.timestamp_ms() + 30 * 86_400_000, // 30 days deadline
        intent_witnesses::governance()
    );
    
    (intent_key, intent)
}

/// Create a batch transfer intent
public fun create_batch_transfer_intent<AssetType, Outcome: store + drop + copy>(
    account: &mut Account<FutarchyConfig>,
    recipients: vector<address>,
    amounts: vector<u64>,
    outcome: Outcome,
    clock: &Clock,
    ctx: &mut TxContext,
): (String, Intent<Outcome>) {
    let config = account.config();
    
    // Generate intent key using recipient count and total amount
    let mut total_amount = 0u64;
    let mut i = 0;
    while (i < amounts.length()) {
        total_amount = total_amount + amounts[i];
        i = i + 1;
    };
    
    let mut intent_key = b"batch_transfer_".to_string();
    intent_key.append(recipients.length().to_string());
    intent_key.append(b"_".to_string());
    intent_key.append(total_amount.to_string());
    intent_key.append(b"_".to_string());
    intent_key.append(clock.timestamp_ms().to_string());
    
    // Use the provided outcome
    
    // Create intent parameters
    let params = intents::new_params(
        intent_key,
        b"Batch treasury transfer proposal".to_string(),
        vector[clock.timestamp_ms() + 3_600_000], // 1 hour delay
        clock.timestamp_ms() + 86_400_000, // 24 hour expiry
        clock,
        ctx
    );
    
    // Create intent using account
    let mut intent = account::create_intent(
        account,
        params,
        outcome,
        b"BatchTransfer".to_string(),
        version::current(),
        intent_witnesses::governance(),
        ctx
    );
    
    // Batch transfer actions should be added by the caller
    
    (intent_key, intent)
}