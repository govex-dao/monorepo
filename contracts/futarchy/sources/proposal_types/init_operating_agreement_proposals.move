module futarchy::init_operating_agreement_proposals;

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
    init_operating_agreement_actions::{Self, InitActionRegistry},
};


// === Public Functions ===

/// Creates a proposal to initialize a DAO's operating agreement.
/// Supports multiple outcomes - for 2 outcomes, must be ["Reject", "Accept"]
public entry fun create_init_operating_agreement_proposal<AssetType, StableType>(
    dao: &mut DAO<AssetType, StableType>,
    fee_manager: &mut fee::FeeManager,
    init_action_registry: &mut InitActionRegistry,
    // Standard proposal inputs
    payment: Coin<SUI>,
    dao_fee_payment: Coin<StableType>,
    title: String,
    metadata: String,
    outcome_messages: vector<String>,
    outcome_details: vector<String>,
    initial_outcome_amounts: vector<u64>,
    // Specific inputs for initializing operating agreement
    initial_lines: vector<String>,
    initial_difficulties: vector<u64>,
    action_outcome_index: u64, // Which outcome should trigger the action (0-based, typically 1 for binary)
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Ensure the DAO doesn't already have an operating agreement
    assert!(dao_state::operating_agreement_id(dao).is_none(), 0); // EOperatingAgreementAlreadyExists

    // Validate inputs
    let outcome_count = outcome_messages.length();
    assert!(outcome_count >= 2, 1); // Need at least 2 outcomes
    assert!(outcome_details.length() == outcome_count, 2); // Matching details
    assert!(initial_outcome_amounts.length() == outcome_count * 2, 3); // asset + stable for each outcome
    assert!(action_outcome_index < outcome_count, 4); // Valid outcome index
    
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
        outcome_details,
        asset_amounts,
        stable_amounts,
        false, // uses_dao_liquidity
        clock,
        ctx
    );

    // Register the intended action with the secure InitActionRegistry
    // Only if action_outcome_index is not 0 (reject outcome)
    if (action_outcome_index > 0) {
        let action = init_operating_agreement_actions::new_init_agreement_action(
            initial_lines,
            initial_difficulties
        );

        init_operating_agreement_actions::init_proposal_action(
            init_action_registry,
            proposal_id,
            action
        );
    };
}