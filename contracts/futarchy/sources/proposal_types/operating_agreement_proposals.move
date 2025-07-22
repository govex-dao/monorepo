module futarchy::operating_agreement_proposals;

use std::string::String;
use sui::{
    coin::Coin,
    clock::Clock,
    sui::SUI,
};
use futarchy::{
    dao::{Self, DAO},
    fee,
    operating_agreement_actions::{
        Self, ActionRegistry, Action,
        new_update_action, new_insert_after_action, 
        new_insert_at_beginning_action, new_remove_action
    },
};


// === Public Functions ===

/// Creates a proposal to atomically update the DAO's operating agreement.
/// This is a binary proposal (Reject/Accept). The "Accept" outcome is only executable
/// if its final price exceeds the "Reject" price by the margin required by the
/// single most difficult action in the batch.
public entry fun create_agreement_proposal<AssetType, StableType>(
    dao: &mut DAO,
    fee_manager: &mut fee::FeeManager,
    action_registry: &mut ActionRegistry,
    // Standard proposal inputs
    payment: Coin<SUI>,
    dao_fee_payment: Coin<StableType>,
    asset_coin: Coin<AssetType>,
    stable_coin: Coin<StableType>,
    title: String,
    proposal_description: String, // A high-level description of the change batch
    metadata: String,
    initial_outcome_amounts: vector<u64>,
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
    assert!(update_line_ids.length() == update_texts.length(), 0);
    assert!(insert_after_line_ids.length() == insert_after_texts.length(), 1);
    assert!(insert_after_texts.length() == insert_after_difficulties.length(), 2);
    assert!(insert_at_beginning_texts.length() == insert_at_beginning_difficulties.length(), 3);
    
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
    i = 0;
    while (i < insert_after_line_ids.length()) {
        actions_batch.push_back(new_insert_after_action(
            *insert_after_line_ids.borrow(i),
            *insert_after_texts.borrow(i),
            *insert_after_difficulties.borrow(i)
        ));
        i = i + 1;
    };
    
    // Add insert at beginning actions
    i = 0;
    while (i < insert_at_beginning_texts.length()) {
        actions_batch.push_back(new_insert_at_beginning_action(
            *insert_at_beginning_texts.borrow(i),
            *insert_at_beginning_difficulties.borrow(i)
        ));
        i = i + 1;
    };
    
    // Add remove actions
    i = 0;
    while (i < remove_line_ids.length()) {
        actions_batch.push_back(new_remove_action(*remove_line_ids.borrow(i)));
        i = i + 1;
    };

    // 1. Create the underlying futarchy proposal (always 2-outcome for this type).
    let (proposal_id, _, _) = dao::create_proposal_internal<AssetType, StableType>(
        dao,
        fee_manager,
        payment,
        dao_fee_payment,
        2, // Always 2 outcomes for operating agreement proposals
        asset_coin,
        stable_coin,
        title,
        // The `details` vector describes each outcome for the UI.
        vector[
            b"The operating agreement will not be changed.".to_string(),
            proposal_description // The high-level description for the 'accept' outcome.
        ],
        metadata,
        vector[b"Reject".to_string(), b"Accept".to_string()],
        initial_outcome_amounts,
        clock,
        ctx
    );

    // 2. Register the entire batch of intended actions with the secure ActionRegistry.
    operating_agreement_actions::init_proposal_actions(action_registry, proposal_id, actions_batch);
}