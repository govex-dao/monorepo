/// Unified proposal creation module for futarchy DAOs (single vault version)
module futarchy::proposals;

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
const EInvalidRecipients: u64 = 0;
const EInvalidAmount: u64 = 4;

// === Public Functions ===

// ============= Unified Multi-Outcome Proposals =============

/// Create a multi-outcome transfer proposal with arbitrary number of outcomes
/// 
/// IMPORTANT CONVENTION:
/// - Outcome 0 MUST always be the "Reject" option with no treasury action (amount = 0 or no entry)
/// - For binary proposals (2 outcomes): Outcome 1 MUST be "Accept"
/// - For multi-outcome proposals (3+ outcomes): Outcomes 1+ can be any meaningful options
///
/// The system enforces that binary proposals will have outcome_messages set to ["Reject", "Accept"]
/// automatically. Transfer actions should specify [outcome_index, amount] pairs, where outcome 0
/// typically has no action or amount = 0.
public entry fun create_multi_outcome_transfer_proposal<AssetType, StableType, CoinType>(
    dao: &mut DAO,
    fee_manager: &mut fee::FeeManager,
    registry: &mut ActionRegistry,
    payment: Coin<SUI>,
    asset_coin: Coin<AssetType>,
    stable_coin: Coin<StableType>,
    title: String,
    metadata: String,
    outcome_descriptions: vector<String>,
    mut outcome_messages: vector<String>,
    initial_outcome_amounts: vector<u64>,
    // Transfer actions: vector of (outcome_index, recipient, amount, description)
    transfer_actions: vector<vector<u64>>, // [outcome, amount] 
    transfer_recipients: vector<address>,
    transfer_descriptions: vector<String>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let outcome_count = outcome_descriptions.length();
    assert!(outcome_count >= 2, EInvalidRecipients);
    assert!(outcome_messages.length() == outcome_count, EInvalidRecipients);
    assert!(initial_outcome_amounts.length() == outcome_count * 2, EInvalidAmount);
    assert!(transfer_actions.length() == transfer_recipients.length(), EInvalidRecipients);
    assert!(transfer_actions.length() == transfer_descriptions.length(), EInvalidRecipients);
    
    // Special handling for binary proposals
    if (outcome_count == 2) {
        // Override messages for binary proposals
        *vector::borrow_mut(&mut outcome_messages, 0) = b"Reject".to_string();
        *vector::borrow_mut(&mut outcome_messages, 1) = b"Accept".to_string();
    };
    
    // Create the proposal
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
    
    // Initialize actions for this proposal
    treasury_actions::init_proposal_actions(
        registry,
        proposal_id,
        outcome_count,
        ctx
    );
    
    // Add transfer actions for specified outcomes
    let mut i = 0;
    while (i < transfer_actions.length()) {
        let action_spec = &transfer_actions[i];
        let outcome = action_spec[0];
        let amount = action_spec[1];
        
        if (amount > 0) {
            treasury_actions::add_transfer_action<CoinType>(
                registry,
                proposal_id,
                outcome,
                transfer_recipients[i],
                amount,
                ctx,
            );
        };
        i = i + 1;
    };
}

// ============= Binary Proposal Helper Functions =============
// These are convenience functions for common binary (reject/accept) proposals

/// Create a binary transfer proposal
public entry fun create_and_store_transfer_proposal<AssetType, StableType, CoinType>(
    dao: &mut DAO,
    fee_manager: &mut fee::FeeManager,
    registry: &mut ActionRegistry,
    payment: Coin<SUI>,
    asset_coin: Coin<AssetType>,
    stable_coin: Coin<StableType>,
    title: String,
    metadata: String,
    initial_outcome_amounts: vector<u64>,
    recipient: address,
    amount: u64,
    transfer_description: String,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Set up for binary proposal
    let outcome_descriptions = vector[
        b"Reject transfer proposal".to_string(),
        b"Approve transfer".to_string()
    ];
    let outcome_messages = vector[b"".to_string(), b"".to_string()]; // Will be auto-filled
    
    // Create transfer actions for outcome 1 (Accept)
    let transfer_actions = vector[vector[1, amount]]; // outcome 1, amount
    let transfer_recipients = vector[recipient];
    let transfer_descriptions = vector[transfer_description];
    
    // Call the unified function
    create_multi_outcome_transfer_proposal<AssetType, StableType, CoinType>(
        dao,
        fee_manager,
        registry,
        payment,
        asset_coin,
        stable_coin,
        title,
        metadata,
        outcome_descriptions,
        outcome_messages,
        initial_outcome_amounts,
        transfer_actions,
        transfer_recipients,
        transfer_descriptions,
        clock,
        ctx
    );
}

/// Create a binary recurring payment proposal
public entry fun create_recurring_payment_proposal<AssetType, StableType, CoinType>(
    dao: &mut DAO,
    fee_manager: &mut fee::FeeManager,
    registry: &mut ActionRegistry,
    payment: Coin<SUI>,
    asset_coin: Coin<AssetType>,
    stable_coin: Coin<StableType>,
    title: String,
    metadata: String,
    initial_outcome_amounts: vector<u64>,
    recipient: address,
    amount_per_payment: u64,
    payment_interval_ms: u64,
    total_payments: u64,
    start_timestamp: u64,
    description: String,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Create a standard binary proposal
    let outcome_descriptions = vector[
        b"Reject recurring payment proposal".to_string(),
        b"Approve recurring payment".to_string()
    ];
    let outcome_messages = vector[b"".to_string(), b"".to_string()]; // Will be auto-filled as Reject/Accept
    
    // Create the proposal
    let (proposal_id, _, _) = dao::create_proposal_internal<AssetType, StableType>(
        dao,
        fee_manager,
        payment,
        2,
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
    
    // Initialize actions for this proposal
    treasury_actions::init_proposal_actions(
        registry,
        proposal_id,
        2,
        ctx
    );
    
    // Add no-op for reject (outcome 0)
    treasury_actions::add_no_op_action(
        registry,
        proposal_id,
        0,
        ctx
    );
    
    // Add recurring payment action for accept (outcome 1)
    treasury_actions::add_recurring_payment_action<CoinType>(
        registry,
        proposal_id,
        1,
        recipient,
        amount_per_payment,
        payment_interval_ms,
        total_payments,
        start_timestamp,
        description,
        ctx
    );
}

// ============= Helper Functions =============

/// Check if anyone can create proposals (permissionless system)
public fun can_create_proposal(_dao: &DAO): bool {
    true // Anyone can create proposals with fee payment
}

