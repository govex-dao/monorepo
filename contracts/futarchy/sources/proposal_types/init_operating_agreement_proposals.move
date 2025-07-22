module futarchy::init_operating_agreement_proposals;

use std::string::String;
use sui::{
    coin::Coin,
    clock::Clock,
    sui::SUI,
};
use futarchy::{
    dao::{Self, DAO},
    fee,
    init_operating_agreement_actions::{Self, InitActionRegistry},
};


// === Public Functions ===

/// Creates a proposal to initialize a DAO's operating agreement.
/// This is a binary proposal (Reject/Accept). If accepted, it will create
/// and attach an operating agreement to the DAO with the specified lines and difficulties.
public entry fun create_init_operating_agreement_proposal<AssetType, StableType>(
    dao: &mut DAO,
    fee_manager: &mut fee::FeeManager,
    init_action_registry: &mut InitActionRegistry,
    // Standard proposal inputs
    payment: Coin<SUI>,
    dao_fee_payment: Coin<StableType>,
    asset_coin: Coin<AssetType>,
    stable_coin: Coin<StableType>,
    title: String,
    metadata: String,
    initial_outcome_amounts: vector<u64>,
    // Specific inputs for initializing operating agreement
    initial_lines: vector<String>,
    initial_difficulties: vector<u64>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Ensure the DAO doesn't already have an operating agreement
    assert!(!dao.has_operating_agreement(), 0); // EOperatingAgreementAlreadyExists

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
            b"No operating agreement will be added to the DAO.".to_string(),
            b"The proposed operating agreement will be initialized for the DAO.".to_string()
        ],
        metadata,
        // The outcome_messages are standard "Reject" and "Accept".
        vector[b"Reject".to_string(), b"Accept".to_string()],
        initial_outcome_amounts,
        clock,
        ctx
    );

    // 2. Register the intended action with the secure InitActionRegistry.
    let action = init_operating_agreement_actions::new_init_agreement_action(
        initial_lines,
        initial_difficulties
    );

    init_operating_agreement_actions::init_proposal_action(
        init_action_registry,
        proposal_id,
        action
    );
}