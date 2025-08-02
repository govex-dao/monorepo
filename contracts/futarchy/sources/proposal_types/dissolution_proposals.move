/// Dissolution proposal creation module for futarchy DAOs
module futarchy::dissolution_proposals;

// === Imports ===
use std::string::String;
use std::type_name::{Self, TypeName};
use sui::{
    coin::Coin,
    clock::Clock,
    sui::SUI,
};
use futarchy::{
    dao::{Self},
    dao_state::{Self, DAO},
    fee,
    treasury_actions::{Self, ActionRegistry}
};

// === Errors ===
const E_INVALID_PARAMS: u64 = 0;
const E_INVALID_PERCENTAGES: u64 = 1;
const E_REJECT_OUTCOME_NEEDS_NO_OP: u64 = 2;
const E_PERCENTAGE_TOO_HIGH: u64 = 3;
const E_EMPTY_COIN_TYPES: u64 = 4;
const E_LIQUIDATION_PERIOD_TOO_SHORT: u64 = 5;
const E_REDEMPTION_FEE_TOO_HIGH: u64 = 6;

// === Constants ===
const MIN_LIQUIDATION_PERIOD_MS: u64 = 604_800_000; // 7 days minimum
const MAX_REDEMPTION_FEE_BPS: u64 = 1000; // 10% max fee

// === Public Functions ===

/// Create a partial dissolution proposal - allows redeeming a portion of treasury assets
public entry fun create_partial_dissolution_proposal<AssetType, StableType>(
    dao: &mut DAO<AssetType, StableType>,
    action_registry: &mut ActionRegistry,
    fee_manager: &mut fee::FeeManager,
    payment: Coin<SUI>,
    dao_fee_payment: Coin<StableType>,
    title: String,
    metadata: String,
    // --- Partial Dissolution Parameters ---
    max_tokens_to_redeem: u64,
    redeemable_coin_type_strings: vector<String>, // Type names as strings
    redeemable_percentages: vector<u64>, // In basis points (10000 = 100%)
    redemption_fee_bps: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Validate parameters
    assert!(redeemable_coin_type_strings.length() == redeemable_percentages.length(), E_INVALID_PARAMS);
    assert!(redeemable_coin_type_strings.length() > 0, E_EMPTY_COIN_TYPES);
    assert!(max_tokens_to_redeem > 0, E_INVALID_PARAMS);
    assert!(redemption_fee_bps <= MAX_REDEMPTION_FEE_BPS, E_REDEMPTION_FEE_TOO_HIGH);
    
    // Validate percentages
    let mut i = 0;
    while (i < redeemable_percentages.length()) {
        let percentage = *vector::borrow(&redeemable_percentages, i);
        assert!(percentage <= 10000, E_PERCENTAGE_TOO_HIGH); // Max 100%
        i = i + 1;
    };
    
    // Create the futarchy proposal (binary reject/accept)
    let outcome_descriptions = vector[
        b"Reject".to_string(), 
        b"Accept".to_string()
    ];
    
    let outcome_messages = vector[
        b"Do not redeem assets".to_string(), 
        b"Enable partial treasury redemption".to_string()
    ];
    
    // Create initial liquidity amounts
    let initial_asset_amounts = vector[1000, 1000]; // Asset amounts for each outcome
    let initial_stable_amounts = vector[1000, 1000]; // Stable amounts for each outcome
    
    let (proposal_id, _, _) = dao::create_proposal_internal<AssetType, StableType>(
        dao, 
        fee_manager, 
        payment, 
        dao_fee_payment, 
        title, 
        metadata,
        outcome_descriptions,
        outcome_messages,
        initial_asset_amounts,
        initial_stable_amounts,
        false, // Not using DAO liquidity
        clock, 
        ctx
    );

    // Convert strings to TypeNames
    let mut redeemable_coin_types = vector<TypeName>[];
    let mut j = 0;
    while (j < redeemable_coin_type_strings.length()) {
        let type_string = vector::borrow(&redeemable_coin_type_strings, j);
        // Convert string to TypeName - this needs a proper implementation
        // For now, we'll pass the strings and convert in the action module
        j = j + 1;
    };
    
    // Create the dissolution action for the "Accept" outcome (outcome 1)
    // Store the action using the dissolution_actions module pattern
    treasury_actions::add_partial_dissolution_action_with_strings(
        action_registry,
        proposal_id,
        1, // Accept outcome
        max_tokens_to_redeem,
        redeemable_coin_type_strings,
        redeemable_percentages,
        redemption_fee_bps,
        ctx
    );
}

/// Create a full dissolution proposal - dissolves the entire DAO
public entry fun create_full_dissolution_proposal<AssetType, StableType>(
    dao: &mut DAO<AssetType, StableType>,
    action_registry: &mut ActionRegistry,
    fee_manager: &mut fee::FeeManager,
    payment: Coin<SUI>,
    dao_fee_payment: Coin<StableType>,
    title: String,
    metadata: String,
    liquidation_period_ms: u64,
    redemption_fee_bps: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Validate parameters
    assert!(liquidation_period_ms >= MIN_LIQUIDATION_PERIOD_MS, E_LIQUIDATION_PERIOD_TOO_SHORT);
    assert!(redemption_fee_bps <= MAX_REDEMPTION_FEE_BPS, E_REDEMPTION_FEE_TOO_HIGH);
    
    // Create the futarchy proposal (binary reject/accept)
    let outcome_descriptions = vector[
        b"Reject".to_string(), 
        b"Accept".to_string()
    ];
    
    let outcome_messages = vector[
        b"Do not dissolve DAO".to_string(), 
        b"Initiate full DAO dissolution".to_string()
    ];
    
    // Create initial liquidity amounts
    let initial_asset_amounts = vector[1000, 1000]; // Asset amounts for each outcome
    let initial_stable_amounts = vector[1000, 1000]; // Stable amounts for each outcome
    
    let (proposal_id, _, _) = dao::create_proposal_internal<AssetType, StableType>(
        dao, 
        fee_manager, 
        payment, 
        dao_fee_payment, 
        title, 
        metadata,
        outcome_descriptions,
        outcome_messages,
        initial_asset_amounts,
        initial_stable_amounts,
        false, // Not using DAO liquidity
        clock, 
        ctx
    );

    // Create the full dissolution action for the "Accept" outcome (outcome 1)
    treasury_actions::add_full_dissolution_action(
        action_registry,
        proposal_id,
        1, // Accept outcome
        liquidation_period_ms,
        redemption_fee_bps,
        ctx
    );
}