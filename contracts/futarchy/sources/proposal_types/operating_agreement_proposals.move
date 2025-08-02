module futarchy::operating_agreement_proposals;

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
    operating_agreement_actions::{
        Self, ActionRegistry, Action,
        new_update_action, new_insert_after_action, 
        new_insert_at_beginning_action, new_remove_action
    },
};

// === Errors ===
const EUpdateVectorLengthMismatch: u64 = 0;
const EInsertAfterVectorLengthMismatch: u64 = 1;
const EInsertAfterDifficultyLengthMismatch: u64 = 2;
const EInsertBeginningVectorLengthMismatch: u64 = 3;
const EInsufficientOutcomes: u64 = 4;
const EOutcomeDetailsLengthMismatch: u64 = 5;
const EInvalidAmountsLength: u64 = 6;
const EInvalidActionOutcomeIndex: u64 = 7;
const EArrayIndexOutOfBounds: u64 = 8;
const ETooManyActions: u64 = 9;

// === Constants ===
const MAX_ACTIONS_PER_PROPOSAL: u64 = 100; // Maximum total actions to prevent excessive gas usage

// === Public Functions ===

/// Creates a proposal to atomically update the DAO's operating agreement.
/// Supports multiple outcomes - for 2 outcomes, must be ["Reject", "Accept"]
public entry fun create_agreement_proposal<AssetType, StableType>(
    dao: &mut DAO<AssetType, StableType>,
    fee_manager: &mut fee::FeeManager,
    action_registry: &mut ActionRegistry,
    // Standard proposal inputs
    payment: Coin<SUI>,
    dao_fee_payment: Coin<StableType>,
    title: String,
    metadata: String,
    outcome_messages: vector<String>,
    outcome_details: vector<String>,
    initial_outcome_amounts: vector<u64>,
    action_outcome_index: u64, // Which outcome should trigger the actions (0-based, typically 1 for binary)
    // Batch of actions - each vector must be the same length within its action type
    update_line_ids: vector<ID>,
    update_texts: vector<String>,
    insert_after_line_ids: vector<ID>,
    insert_after_texts: vector<String>,
    insert_after_difficulties: vector<u64>,
    insert_at_beginning_texts: vector<String>,
    insert_at_beginning_difficulties: vector<u64>,
    remove_line_ids: vector<ID>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Validate input vector lengths
    assert!(update_line_ids.length() == update_texts.length(), EUpdateVectorLengthMismatch);
    assert!(insert_after_line_ids.length() == insert_after_texts.length(), EInsertAfterVectorLengthMismatch);
    assert!(insert_after_texts.length() == insert_after_difficulties.length(), EInsertAfterDifficultyLengthMismatch);
    assert!(insert_at_beginning_texts.length() == insert_at_beginning_difficulties.length(), EInsertBeginningVectorLengthMismatch);
    
    // Validate total actions count
    let total_actions = update_line_ids.length() + 
                       insert_after_line_ids.length() + 
                       insert_at_beginning_texts.length() + 
                       remove_line_ids.length();
    assert!(total_actions <= MAX_ACTIONS_PER_PROPOSAL, ETooManyActions);
    
    // Build the batch of actions from the input vectors.
    let mut actions_batch = vector::empty<Action>();
    
    // Add update actions
    let mut i = 0;
    while (i < update_line_ids.length()) {
        actions_batch.push_back(new_update_action(
            *update_line_ids.borrow(i),
            *update_texts.borrow(i)
        ));
        i = i + 1;
    };
    
    // Add insert after actions
    let mut j = 0;
    while (j < insert_after_line_ids.length()) {
        actions_batch.push_back(new_insert_after_action(
            *insert_after_line_ids.borrow(j),
            *insert_after_texts.borrow(j),
            *insert_after_difficulties.borrow(j)
        ));
        j = j + 1;
    };
    
    // Add insert at beginning actions
    let mut k = 0;
    while (k < insert_at_beginning_texts.length()) {
        actions_batch.push_back(new_insert_at_beginning_action(
            *insert_at_beginning_texts.borrow(k),
            *insert_at_beginning_difficulties.borrow(k)
        ));
        k = k + 1;
    };
    
    // Add remove actions
    let mut l = 0;
    while (l < remove_line_ids.length()) {
        actions_batch.push_back(new_remove_action(*remove_line_ids.borrow(l)));
        l = l + 1;
    };

    // Validate inputs
    let outcome_count = outcome_messages.length();
    assert!(outcome_count >= 2, EInsufficientOutcomes); // Need at least 2 outcomes
    assert!(outcome_details.length() == outcome_count, EOutcomeDetailsLengthMismatch); // Matching details
    assert!(initial_outcome_amounts.length() == outcome_count * 2, EInvalidAmountsLength); // asset + stable for each outcome
    assert!(action_outcome_index < outcome_count, EInvalidActionOutcomeIndex); // Valid outcome index
    
    // Split initial_outcome_amounts into asset and stable vectors
    let mut asset_amounts = vector[];
    let mut stable_amounts = vector[];
    let mut m = 0;
    while (m < outcome_count) {
        let asset_idx = m * 2;
        let stable_idx = m * 2 + 1;
        // Ensure indices are within bounds
        assert!(stable_idx < initial_outcome_amounts.length(), EArrayIndexOutOfBounds);
        vector::push_back(&mut asset_amounts, initial_outcome_amounts[asset_idx]);
        vector::push_back(&mut stable_amounts, initial_outcome_amounts[stable_idx]);
        m = m + 1;
    };
    
    let (proposal_id, _, _) = dao::create_proposal_internal<AssetType, StableType>(
        dao,
        fee_manager,
        payment,
        dao_fee_payment,
        title,
        metadata,
        outcome_messages,
        outcome_details,
        asset_amounts,
        stable_amounts,
        false, // uses_dao_liquidity
        clock,
        ctx
    );

    // Register the entire batch of intended actions with the secure ActionRegistry
    // Only if action_outcome_index is not 0 (reject outcome)
    if (action_outcome_index > 0 && actions_batch.length() > 0) {
        operating_agreement_actions::init_proposal_actions(action_registry, proposal_id, actions_batch);
    };
}