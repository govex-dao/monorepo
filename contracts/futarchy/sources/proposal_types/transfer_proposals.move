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
    dao::{Self}, 
    dao_state::{Self, DAO},
    fee,
    treasury_actions::{Self, ActionRegistry},
};

// === Errors ===
const EInvalidParameters: u64 = 0;
const ETransferAmountTooLarge: u64 = 1;
const ETotalTransferTooLarge: u64 = 2;

// === Constants ===
const MAX_SINGLE_TRANSFER_AMOUNT: u64 = 100_000_000_000_000; // 100 trillion - reasonable max per transfer
const MAX_TOTAL_TRANSFER_AMOUNT: u64 = 1_000_000_000_000_000; // 1 quadrillion - reasonable max total

// === Public Functions ===

/// Create a treasury capability deposit proposal
/// This allows the DAO to vote on accepting a TreasuryCap that someone wants to deposit
public entry fun create_capability_deposit_proposal<AssetType, StableType, CoinType>(
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
    max_supply: Option<u64>,
    max_mint_per_proposal: Option<u64>,
    mint_cooldown_ms: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let outcome_count = outcome_descriptions.length();
    assert!(outcome_count >= 2, EInvalidParameters);
    assert!(initial_outcome_amounts.length() == outcome_count * 2, EInvalidParameters);
    
    
    // Split initial_outcome_amounts into asset and stable vectors
    let mut asset_amounts = vector[];
    let mut stable_amounts = vector[];
    let mut i = 0;
    while (i < outcome_count) {
        vector::push_back(&mut asset_amounts, initial_outcome_amounts[i * 2]);
        vector::push_back(&mut stable_amounts, initial_outcome_amounts[i * 2 + 1]);
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
    amount: u64,
    target_treasury: address,
    _description: String,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(amount > 0, EInvalidParameters);
    assert!(amount <= MAX_SINGLE_TRANSFER_AMOUNT, ETransferAmountTooLarge);
    
    let outcome_count = outcome_descriptions.length();
    assert!(outcome_count >= 2, EInvalidParameters);
    assert!(initial_outcome_amounts.length() == outcome_count * 2, EInvalidParameters);
    
    
    // Split initial_outcome_amounts into asset and stable vectors
    let mut asset_amounts = vector[];
    let mut stable_amounts = vector[];
    let mut i = 0;
    while (i < outcome_count) {
        vector::push_back(&mut asset_amounts, initial_outcome_amounts[i * 2]);
        vector::push_back(&mut stable_amounts, initial_outcome_amounts[i * 2 + 1]);
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
    // Transfer specs: [outcome_index, amount, recipient_index]
    transfer_specs: vector<vector<u64>>,
    recipients: vector<address>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let outcome_count = outcome_descriptions.length();
    assert!(outcome_count >= 2, EInvalidParameters);
    assert!(initial_outcome_amounts.length() == outcome_count * 2, EInvalidParameters);
    
    // Split initial_outcome_amounts into asset and stable vectors
    let mut asset_amounts = vector[];
    let mut stable_amounts = vector[];
    let mut i = 0;
    while (i < outcome_count) {
        vector::push_back(&mut asset_amounts, initial_outcome_amounts[i * 2]);
        vector::push_back(&mut stable_amounts, initial_outcome_amounts[i * 2 + 1]);
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
    
    // Add transfers based on specs
    let mut i = 0;
    let mut total_transfer_amount = 0u64;
    while (i < transfer_specs.length()) {
        let spec = &transfer_specs[i];
        // Validate spec has correct length
        assert!(spec.length() >= 3, EInvalidParameters);
        
        let outcome = spec[0];
        let amount = spec[1];
        let recipient_idx = spec[2];
        
        // Validate indices
        assert!(outcome < outcome_count, EInvalidParameters);
        assert!(recipient_idx < recipients.length(), EInvalidParameters);
        
        if (amount > 0) {
            // Validate single transfer amount
            assert!(amount <= MAX_SINGLE_TRANSFER_AMOUNT, ETransferAmountTooLarge);
            
            // Check total transfer amount doesn't exceed limit
            assert!(total_transfer_amount <= MAX_TOTAL_TRANSFER_AMOUNT - amount, ETotalTransferTooLarge);
            total_transfer_amount = total_transfer_amount + amount;
            
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
    assert!(initial_outcome_amounts.length() == outcome_count * 2, EInvalidParameters);
    
    // Verify amounts sum to mint_amount (with overflow protection)
    let mut total = 0u64;
    let mut i = 0;
    while (i < amounts.length()) {
        let amount = amounts[i];
        // Check for overflow before adding
        assert!(total <= std::u64::max_value!() - amount, EInvalidParameters);
        total = total + amount;
        i = i + 1;
    };
    assert!(total == mint_amount, EInvalidParameters);
    
    
    // Split initial_outcome_amounts into asset and stable vectors
    let mut asset_amounts = vector[];
    let mut stable_amounts = vector[];
    i = 0;
    while (i < outcome_count) {
        vector::push_back(&mut asset_amounts, initial_outcome_amounts[i * 2]);
        vector::push_back(&mut stable_amounts, initial_outcome_amounts[i * 2 + 1]);
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

