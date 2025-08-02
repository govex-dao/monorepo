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
    dao::{Self},
    dao_state::{Self, DAO},
    fee,
    treasury_actions::{Self, ActionRegistry},
};

// === Errors ===
const EInvalidAmount: u64 = 0;
const EInvalidArrayLength: u64 = 1;
const EArrayIndexOutOfBounds: u64 = 2;
const EInvalidActionSpec: u64 = 3;
const EInvalidRecipientIndex: u64 = 4;
const ETotalMintAmountTooLarge: u64 = 5;

// === Constants ===
const MAX_TOTAL_MINT_AMOUNT: u64 = 1_000_000_000_000_000; // 1 quadrillion - reasonable max for any token

// === Public Functions ===

/// Create a mint proposal
public entry fun create_mint_proposal<AssetType, StableType, CoinType>(
    dao: &mut DAO<AssetType, StableType>,
    fee_manager: &mut fee::FeeManager,
    registry: &mut ActionRegistry,
    payment: Coin<SUI>,
    dao_fee_payment: Coin<StableType>,
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
    assert!(initial_outcome_amounts.length() == outcome_count * 2, EInvalidAmount);
    
    // For binary proposals, enforce standard reject/accept pattern
    let mut final_outcome_messages = outcome_messages;
    if (outcome_count == 2) {
        *vector::borrow_mut(&mut final_outcome_messages, 0) = b"Reject".to_string();
        *vector::borrow_mut(&mut final_outcome_messages, 1) = b"Accept".to_string();
    };
    
    // Split initial_outcome_amounts into asset and stable vectors
    let mut asset_amounts = vector[];
    let mut stable_amounts = vector[];
    let mut i = 0;
    while (i < outcome_count) {
        let asset_idx = i * 2;
        let stable_idx = i * 2 + 1;
        // Ensure indices are within bounds
        assert!(stable_idx < initial_outcome_amounts.length(), EArrayIndexOutOfBounds);
        vector::push_back(&mut asset_amounts, initial_outcome_amounts[asset_idx]);
        vector::push_back(&mut stable_amounts, initial_outcome_amounts[stable_idx]);
        i = i + 1;
    };
    
    let (proposal_id, _, _) = dao::create_proposal_internal<AssetType, StableType>(
        dao,
        fee_manager,
        payment,
        dao_fee_payment,
        title,
        metadata,
        final_outcome_messages,
        outcome_descriptions,
        asset_amounts,
        stable_amounts,
        false, // uses_dao_liquidity
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
    dao: &mut DAO<AssetType, StableType>,
    fee_manager: &mut fee::FeeManager,
    registry: &mut ActionRegistry,
    payment: Coin<SUI>,
    dao_fee_payment: Coin<StableType>,
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
    assert!(initial_outcome_amounts.length() == outcome_count * 2, EInvalidAmount);
    
    // For binary proposals, enforce standard reject/accept pattern
    let mut final_outcome_messages = outcome_messages;
    if (outcome_count == 2) {
        *vector::borrow_mut(&mut final_outcome_messages, 0) = b"Reject".to_string();
        *vector::borrow_mut(&mut final_outcome_messages, 1) = b"Accept".to_string();
    };
    
    // Split initial_outcome_amounts into asset and stable vectors
    let mut asset_amounts = vector[];
    let mut stable_amounts = vector[];
    let mut i = 0;
    while (i < outcome_count) {
        let asset_idx = i * 2;
        let stable_idx = i * 2 + 1;
        // Ensure indices are within bounds
        assert!(stable_idx < initial_outcome_amounts.length(), EArrayIndexOutOfBounds);
        vector::push_back(&mut asset_amounts, initial_outcome_amounts[asset_idx]);
        vector::push_back(&mut stable_amounts, initial_outcome_amounts[stable_idx]);
        i = i + 1;
    };
    
    let (proposal_id, _, _) = dao::create_proposal_internal<AssetType, StableType>(
        dao,
        fee_manager,
        payment,
        dao_fee_payment,
        title,
        metadata,
        final_outcome_messages,
        outcome_descriptions,
        asset_amounts,
        stable_amounts,
        false, // uses_dao_liquidity
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
    dao: &mut DAO<AssetType, StableType>,
    fee_manager: &mut fee::FeeManager,
    registry: &mut ActionRegistry,
    payment: Coin<SUI>,
    dao_fee_payment: Coin<StableType>,
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
    assert!(initial_outcome_amounts.length() == outcome_count * 2, EInvalidAmount);
    
    // Split initial_outcome_amounts into asset and stable vectors
    let mut asset_amounts = vector[];
    let mut stable_amounts = vector[];
    let mut i = 0;
    while (i < outcome_count) {
        let asset_idx = i * 2;
        let stable_idx = i * 2 + 1;
        // Ensure indices are within bounds
        assert!(stable_idx < initial_outcome_amounts.length(), EArrayIndexOutOfBounds);
        vector::push_back(&mut asset_amounts, initial_outcome_amounts[asset_idx]);
        vector::push_back(&mut stable_amounts, initial_outcome_amounts[stable_idx]);
        i = i + 1;
    };
    
    let (proposal_id, _, _) = dao::create_proposal_internal<AssetType, StableType>(
        dao,
        fee_manager,
        payment,
        dao_fee_payment,
        title,
        metadata,
        outcome_messages,
        outcome_descriptions,
        asset_amounts,
        stable_amounts,
        false, // uses_dao_liquidity
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
    let mut total_mint_amount = 0u64;
    while (i < mint_actions.length()) {
        let action_spec = &mint_actions[i];
        // Validate action spec has correct length
        assert!(action_spec.length() >= 3, EInvalidActionSpec);
        
        let outcome = action_spec[0];
        let amount = action_spec[1];
        let recipient_idx = action_spec[2];
        
        // Validate recipient index
        assert!(recipient_idx < recipients.length(), EInvalidRecipientIndex);
        // Validate outcome index
        assert!(outcome < outcome_count, EArrayIndexOutOfBounds);
        
        if (amount > 0) {
            // Check total mint amount doesn't exceed limit
            assert!(total_mint_amount <= MAX_TOTAL_MINT_AMOUNT - amount, ETotalMintAmountTooLarge);
            total_mint_amount = total_mint_amount + amount;
            
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
    dao: &mut DAO<AssetType, StableType>,
    fee_manager: &mut fee::FeeManager,
    registry: &mut ActionRegistry,
    payment: Coin<SUI>,
    dao_fee_payment: Coin<StableType>,
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
    assert!(initial_outcome_amounts.length() == outcome_count * 2, EInvalidAmount);
    
    // For binary proposals, enforce standard reject/accept pattern
    let mut final_outcome_messages = outcome_messages;
    if (outcome_count == 2) {
        *vector::borrow_mut(&mut final_outcome_messages, 0) = b"Reject".to_string();
        *vector::borrow_mut(&mut final_outcome_messages, 1) = b"Accept".to_string();
    };
    
    // Split initial_outcome_amounts into asset and stable vectors
    let mut asset_amounts = vector[];
    let mut stable_amounts = vector[];
    let mut i = 0;
    while (i < outcome_count) {
        let asset_idx = i * 2;
        let stable_idx = i * 2 + 1;
        // Ensure indices are within bounds
        assert!(stable_idx < initial_outcome_amounts.length(), EArrayIndexOutOfBounds);
        vector::push_back(&mut asset_amounts, initial_outcome_amounts[asset_idx]);
        vector::push_back(&mut stable_amounts, initial_outcome_amounts[stable_idx]);
        i = i + 1;
    };
    
    let (proposal_id, _, _) = dao::create_proposal_internal<AssetType, StableType>(
        dao,
        fee_manager,
        payment,
        dao_fee_payment,
        title,
        metadata,
        final_outcome_messages,
        outcome_descriptions,
        asset_amounts,
        stable_amounts,
        false, // uses_dao_liquidity
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