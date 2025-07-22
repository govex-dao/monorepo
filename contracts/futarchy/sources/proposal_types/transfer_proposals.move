/// Transfer and capability management proposals for futarchy DAOs
module futarchy::transfer_proposals;

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
const EInvalidParameters: u64 = 0;

// === Public Functions ===

/// Create a treasury capability deposit proposal
/// This allows the DAO to vote on accepting a TreasuryCap that someone wants to deposit
public entry fun create_capability_deposit_proposal<AssetType, StableType, CoinType>(
    dao: &mut DAO,
    fee_manager: &mut fee::FeeManager,
    registry: &mut ActionRegistry,
    payment: Coin<SUI>,
    dao_fee_payment: Coin<StableType>,
    asset_coin: Coin<AssetType>,
    stable_coin: Coin<StableType>,
    title: String,
    metadata: String,
    outcome_descriptions: vector<String>,
    outcome_messages: vector<String>,
    initial_outcome_amounts: vector<u64>,
    max_supply: Option<u64>,
    max_mint_per_proposal: Option<u64>,
    mint_cooldown_ms: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let outcome_count = outcome_descriptions.length();
    assert!(outcome_count >= 2, EInvalidParameters);
    
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
        dao_fee_payment,
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
    
    // For binary proposals, add capability deposit to outcome 1
    // For multi-outcome, caller should specify which outcomes get the action
    if (outcome_count == 2) {
        treasury_actions::add_capability_deposit_action<CoinType>(
            registry,
            proposal_id,
            1,
            max_supply,
            max_mint_per_proposal,
            mint_cooldown_ms,
            ctx
        );
    };
}

/// Create a cross-treasury transfer proposal
/// Allows transferring assets between different treasuries or DAOs
public entry fun create_cross_treasury_transfer_proposal<AssetType, StableType, CoinType>(
    dao: &mut DAO,
    fee_manager: &mut fee::FeeManager,
    registry: &mut ActionRegistry,
    payment: Coin<SUI>,
    dao_fee_payment: Coin<StableType>,
    asset_coin: Coin<AssetType>,
    stable_coin: Coin<StableType>,
    title: String,
    metadata: String,
    outcome_descriptions: vector<String>,
    outcome_messages: vector<String>,
    initial_outcome_amounts: vector<u64>,
    amount: u64,
    target_treasury: address,
    _description: String,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(amount > 0, EInvalidParameters);
    
    let outcome_count = outcome_descriptions.length();
    assert!(outcome_count >= 2, EInvalidParameters);
    
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
        dao_fee_payment,
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
    
    // For binary proposals, add transfer to outcome 1
    if (outcome_count == 2) {
        treasury_actions::add_transfer_action<CoinType>(
            registry,
            proposal_id,
            1,
            target_treasury,
            amount,
            ctx
        );
    };
}

/// Create a multi-step transfer proposal
/// Allows complex transfers with multiple recipients and amounts
public entry fun create_multi_transfer_proposal<AssetType, StableType, CoinType>(
    dao: &mut DAO,
    fee_manager: &mut fee::FeeManager,
    registry: &mut ActionRegistry,
    payment: Coin<SUI>,
    dao_fee_payment: Coin<StableType>,
    asset_coin: Coin<AssetType>,
    stable_coin: Coin<StableType>,
    title: String,
    metadata: String,
    outcome_descriptions: vector<String>,
    outcome_messages: vector<String>,
    initial_outcome_amounts: vector<u64>,
    // Transfer specs: [outcome_index, amount, recipient_index]
    transfer_specs: vector<vector<u64>>,
    recipients: vector<address>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let outcome_count = outcome_descriptions.length();
    assert!(outcome_count >= 2, EInvalidParameters);
    
    let (proposal_id, _, _) = dao::create_proposal_internal<AssetType, StableType>(
        dao,
        fee_manager,
        payment,
        dao_fee_payment,
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
    
    // Add transfers based on specs
    let mut i = 0;
    while (i < transfer_specs.length()) {
        let spec = &transfer_specs[i];
        let outcome = spec[0];
        let amount = spec[1];
        let recipient_idx = spec[2];
        
        if (amount > 0) {
            treasury_actions::add_transfer_action<CoinType>(
                registry,
                proposal_id,
                outcome,
                recipients[recipient_idx],
                amount,
                ctx
            );
        };
        i = i + 1;
    };
}

/// Create a proposal that combines minting and transfers
/// Useful for minting tokens and distributing them in one proposal
public entry fun create_mint_and_transfer_proposal<AssetType, StableType, CoinType>(
    dao: &mut DAO,
    fee_manager: &mut fee::FeeManager,
    registry: &mut ActionRegistry,
    payment: Coin<SUI>,
    dao_fee_payment: Coin<StableType>,
    asset_coin: Coin<AssetType>,
    stable_coin: Coin<StableType>,
    title: String,
    metadata: String,
    outcome_descriptions: vector<String>,
    outcome_messages: vector<String>,
    initial_outcome_amounts: vector<u64>,
    mint_amount: u64,
    // Recipients and their portions (must sum to mint_amount)
    recipients: vector<address>,
    amounts: vector<u64>,
    descriptions: vector<String>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(mint_amount > 0, EInvalidParameters);
    assert!(recipients.length() == amounts.length(), EInvalidParameters);
    assert!(recipients.length() == descriptions.length(), EInvalidParameters);
    
    let outcome_count = outcome_descriptions.length();
    assert!(outcome_count >= 2, EInvalidParameters);
    
    // Verify amounts sum to mint_amount
    let mut total = 0;
    let mut i = 0;
    while (i < amounts.length()) {
        total = total + amounts[i];
        i = i + 1;
    };
    assert!(total == mint_amount, EInvalidParameters);
    
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
        dao_fee_payment,
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
    
    // For binary proposals, add all mint actions to outcome 1
    if (outcome_count == 2) {
        i = 0;
        while (i < recipients.length()) {
            if (amounts[i] > 0) {
                treasury_actions::add_mint_action<CoinType>(
                    registry,
                    proposal_id,
                    1,
                    amounts[i],
                    recipients[i],
                    descriptions[i],
                    ctx
                );
            };
            i = i + 1;
        };
    };
}