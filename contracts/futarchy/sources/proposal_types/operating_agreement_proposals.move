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
    operating_agreement_actions::{Self, ActionRegistry},
};


// === Public Functions ===

/// Creates a proposal to update a line in the DAO's operating agreement.
/// This is a binary proposal (Reject/Accept). The "Accept" outcome is only
/// executable if its final price exceeds the "Reject" price by a specific
/// `difficulty` margin defined on the agreement line itself.
public entry fun create_update_line_proposal<AssetType, StableType>(
    dao: &mut DAO,
    fee_manager: &mut fee::FeeManager,
    action_registry: &mut ActionRegistry,
    // Standard proposal inputs
    payment: Coin<SUI>,
    dao_fee_payment: Coin<StableType>,
    asset_coin: Coin<AssetType>,
    stable_coin: Coin<StableType>,
    title: String,
    metadata: String,
    initial_outcome_amounts: vector<u64>,
    // Specific inputs for this proposal type
    line_id_to_update: ID,
    new_text: String,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // 1. Create the underlying futarchy proposal.
    // This will be a 2-outcome proposal.
    let (proposal_id, _, _) = dao::create_proposal_internal<AssetType, StableType>(
        dao,
        fee_manager,
        payment,
        dao_fee_payment,
        2, // outcome_count is always 2 for this proposal type
        asset_coin,
        stable_coin,
        title,
        // The details vector describes each outcome.
        vector[
            b"The operating agreement will not be changed.".to_string(),
            new_text // The new text is the description for the 'accept' outcome.
        ],
        metadata,
        // The outcome_messages are standard "Reject" and "Accept".
        vector[b"Reject".to_string(), b"Accept".to_string()],
        initial_outcome_amounts,
        clock,
        ctx
    );

    // 2. Register the intended action with the secure ActionRegistry.
    // This ensures that if the proposal passes, only this specific action can be executed.
    let action = operating_agreement_actions::new_update_line_action(
        line_id_to_update,
        new_text
    );

    operating_agreement_actions::init_proposal_action(
        action_registry,
        proposal_id,
        action
    );
}