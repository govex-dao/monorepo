/// Mint and burn proposal creation module for futarchy DAOs
module futarchy::mint_burn_proposals;

// === Imports ===
use std::string::String;
use sui::{
    coin::Coin,
    clock::Clock,
    sui::SUI,
};
use futarchy::{
    dao::{Self, DAO},
    fee,
    treasury_actions::{Self, ActionRegistry},
};

// === Errors ===
const EInvalidAmount: u64 = 0;

// === Public Functions ===

/// Create a mint proposal
public entry fun create_mint_proposal<AssetType, StableType, CoinType>(
    dao: &mut DAO,
    fee_manager: &mut fee::FeeManager,
    registry: &mut ActionRegistry,
    payment: Coin<SUI>,
    asset_coin: Coin<AssetType>,
    stable_coin: Coin<StableType>,
    title: String,
    metadata: String,
    outcome_descriptions: vector<String>,
    outcome_messages: vector<String>,
    initial_outcome_amounts: vector<u64>,
    mint_amount: u64,
    recipient: address,
    description: String,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(mint_amount > 0, EInvalidAmount);
    
    let outcome_count = outcome_descriptions.length();
    assert!(outcome_count >= 2, EInvalidAmount);
    
    // For binary proposals, enforce standard reject/accept pattern
    let mut final_outcome_messages = outcome_messages;
    if (outcome_count == 2) {
        *vector::borrow_mut(&mut final_outcome_messages, 0) = b"Reject".to_string();
        *vector::borrow_mut(&mut final_outcome_messages, 1) = b"Accept".to_string();
    };
    
    let (proposal_id, _, _) = dao::create_proposal_internal<AssetType, StableType>(
        dao,
        fee_manager,
        payment,
        outcome_count,
        asset_coin,
        stable_coin,
        title,
        outcome_descriptions,
        metadata,
        final_outcome_messages,
        initial_outcome_amounts,
        clock,
        ctx
    );
    
    // Initialize actions
    treasury_actions::init_proposal_actions(
        registry,
        proposal_id,
        outcome_count,
        ctx
    );
    
    // Add no-op for reject (outcome 0)
    treasury_actions::add_no_op_action(
        registry,
        proposal_id,
        0,
        ctx
    );
    
    // For binary proposals, add mint action to outcome 1
    if (outcome_count == 2) {
        treasury_actions::add_mint_action<CoinType>(
            registry,
            proposal_id,
            1,
            mint_amount,
            recipient,
            description,
            ctx
        );
    };
}

/// Create a burn proposal
public entry fun create_burn_proposal<AssetType, StableType, CoinType>(
    dao: &mut DAO,
    fee_manager: &mut fee::FeeManager,
    registry: &mut ActionRegistry,
    payment: Coin<SUI>,
    asset_coin: Coin<AssetType>,
    stable_coin: Coin<StableType>,
    title: String,
    metadata: String,
    outcome_descriptions: vector<String>,
    outcome_messages: vector<String>,
    initial_outcome_amounts: vector<u64>,
    burn_amount: u64,
    description: String,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(burn_amount > 0, EInvalidAmount);
    
    let outcome_count = outcome_descriptions.length();
    assert!(outcome_count >= 2, EInvalidAmount);
    
    // For binary proposals, enforce standard reject/accept pattern
    let mut final_outcome_messages = outcome_messages;
    if (outcome_count == 2) {
        *vector::borrow_mut(&mut final_outcome_messages, 0) = b"Reject".to_string();
        *vector::borrow_mut(&mut final_outcome_messages, 1) = b"Accept".to_string();
    };
    
    let (proposal_id, _, _) = dao::create_proposal_internal<AssetType, StableType>(
        dao,
        fee_manager,
        payment,
        outcome_count,
        asset_coin,
        stable_coin,
        title,
        outcome_descriptions,
        metadata,
        final_outcome_messages,
        initial_outcome_amounts,
        clock,
        ctx
    );
    
    // Initialize actions
    treasury_actions::init_proposal_actions(
        registry,
        proposal_id,
        outcome_count,
        ctx
    );
    
    // Add no-op for reject (outcome 0)
    treasury_actions::add_no_op_action(
        registry,
        proposal_id,
        0,
        ctx
    );
    
    // For binary proposals, add burn action to outcome 1
    if (outcome_count == 2) {
        treasury_actions::add_burn_action<CoinType>(
            registry,
            proposal_id,
            1,
            burn_amount,
            true, // from_treasury
            description,
            ctx
        );
    };
}

/// Create a multi-outcome mint proposal with different amounts
public entry fun create_multi_outcome_mint_proposal<AssetType, StableType, CoinType>(
    dao: &mut DAO,
    fee_manager: &mut fee::FeeManager,
    registry: &mut ActionRegistry,
    payment: Coin<SUI>,
    asset_coin: Coin<AssetType>,
    stable_coin: Coin<StableType>,
    title: String,
    metadata: String,
    outcome_descriptions: vector<String>,
    outcome_messages: vector<String>,
    initial_outcome_amounts: vector<u64>,
    // Mint actions: vector of [outcome_index, amount, recipient_index]
    mint_actions: vector<vector<u64>>,
    recipients: vector<address>,
    descriptions: vector<String>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let outcome_count = outcome_descriptions.length();
    assert!(outcome_count >= 2, EInvalidAmount);
    assert!(mint_actions.length() == descriptions.length(), EInvalidAmount);
    
    let (proposal_id, _, _) = dao::create_proposal_internal<AssetType, StableType>(
        dao,
        fee_manager,
        payment,
        outcome_count,
        asset_coin,
        stable_coin,
        title,
        outcome_descriptions,
        metadata,
        outcome_messages,
        initial_outcome_amounts,
        clock,
        ctx
    );
    
    // Initialize actions
    treasury_actions::init_proposal_actions(
        registry,
        proposal_id,
        outcome_count,
        ctx
    );
    
    // Add actions based on specifications
    let mut i = 0;
    while (i < mint_actions.length()) {
        let action_spec = &mint_actions[i];
        let outcome = action_spec[0];
        let amount = action_spec[1];
        let recipient_idx = action_spec[2];
        
        if (amount > 0) {
            treasury_actions::add_mint_action<CoinType>(
                registry,
                proposal_id,
                outcome,
                amount,
                recipients[recipient_idx],
                descriptions[i],
                ctx
            );
        };
        i = i + 1;
    };
}

/// Create a combined mint and burn proposal
public entry fun create_mint_and_burn_proposal<AssetType, StableType, CoinType>(
    dao: &mut DAO,
    fee_manager: &mut fee::FeeManager,
    registry: &mut ActionRegistry,
    payment: Coin<SUI>,
    asset_coin: Coin<AssetType>,
    stable_coin: Coin<StableType>,
    title: String,
    metadata: String,
    outcome_descriptions: vector<String>,
    outcome_messages: vector<String>,
    initial_outcome_amounts: vector<u64>,
    mint_amount: u64,
    mint_recipient: address,
    burn_amount: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(mint_amount > 0 || burn_amount > 0, EInvalidAmount);
    
    let outcome_count = outcome_descriptions.length();
    assert!(outcome_count >= 2, EInvalidAmount);
    
    // For binary proposals, enforce standard reject/accept pattern
    let mut final_outcome_messages = outcome_messages;
    if (outcome_count == 2) {
        *vector::borrow_mut(&mut final_outcome_messages, 0) = b"Reject".to_string();
        *vector::borrow_mut(&mut final_outcome_messages, 1) = b"Accept".to_string();
    };
    
    let (proposal_id, _, _) = dao::create_proposal_internal<AssetType, StableType>(
        dao,
        fee_manager,
        payment,
        outcome_count,
        asset_coin,
        stable_coin,
        title,
        outcome_descriptions,
        metadata,
        final_outcome_messages,
        initial_outcome_amounts,
        clock,
        ctx
    );
    
    // Initialize actions
    treasury_actions::init_proposal_actions(
        registry,
        proposal_id,
        outcome_count,
        ctx
    );
    
    // Add no-op for reject (outcome 0)
    treasury_actions::add_no_op_action(
        registry,
        proposal_id,
        0,
        ctx
    );
    
    // For binary proposals, add mint and burn actions to outcome 1
    if (outcome_count == 2) {
        // Add mint action if amount > 0
        if (mint_amount > 0) {
            treasury_actions::add_mint_action<CoinType>(
                registry,
                proposal_id,
                1,
                mint_amount,
                mint_recipient,
                b"Mint new tokens".to_string(),
                ctx
            );
        };
        
        // Add burn action if amount > 0
        if (burn_amount > 0) {
            treasury_actions::add_burn_action<CoinType>(
                registry,
                proposal_id,
                1,
                burn_amount,
                true, // from_treasury
                b"Burn treasury tokens".to_string(),
                ctx
            );
        };
    };
}