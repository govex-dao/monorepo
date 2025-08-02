/// Stream management proposals for canceling payment streams
module futarchy::stream_management_proposals;

// === Imports ===
use std::string::String;
use sui::{
    object::ID,
    coin::Coin,
    clock::Clock,
    sui::SUI,
};
use futarchy::{
    dao::{Self},
    dao_state::{Self, DAO},
    fee,
    treasury_actions::{Self, ActionRegistry}
};

// === Errors ===
const E_INVALID_STREAM_ID: u64 = 0;

// === Public Functions ===

/// Creates a binary proposal to cancel an existing, active payment stream.
/// If the proposal passes, the stream is terminated and no further payments
/// can be claimed from it.
public entry fun create_cancel_stream_proposal<AssetType, StableType>(
    dao: &mut DAO<AssetType, StableType>,
    action_registry: &mut ActionRegistry,
    fee_manager: &mut fee::FeeManager,
    payment: Coin<SUI>,
    dao_fee_payment: Coin<StableType>,
    title: String,
    metadata: String,
    
    // The specific stream to be canceled
    stream_id_to_cancel: ID,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Validate stream ID is not zero
    assert!(stream_id_to_cancel != object::id_from_address(@0x0), E_INVALID_STREAM_ID);
    
    // 1. Create a standard binary futarchy proposal
    let outcome_descriptions = vector[
        b"Reject".to_string(), 
        b"Accept".to_string()
    ];
    
    let outcome_messages = vector[
        b"Continue payment stream".to_string(), 
        b"Cancel payment stream".to_string()
    ];
    
    // Create initial liquidity amounts
    let initial_asset_amounts = vector[1000, 1000]; // Asset amounts for each outcome
    let initial_stable_amounts = vector[1000, 1000]; // Stable amounts for each outcome
    
    let (proposal_id, _, _) = dao::create_proposal_internal<AssetType, StableType>(
        dao,
        fee_manager,
        payment,
        dao_fee_payment,
        title,
        metadata,
        outcome_descriptions,
        outcome_messages,
        initial_asset_amounts,
        initial_stable_amounts,
        false, // Not using DAO liquidity
        clock,
        ctx
    );

    // 2. Initialize actions for the proposal
    treasury_actions::init_proposal_actions(
        action_registry,
        proposal_id,
        2, // Two outcomes: Reject and Accept
        ctx
    );

    // 3. Add a NO-OP action for the "Reject" outcome (index 0)
    treasury_actions::add_no_op_action(action_registry, proposal_id, 0, ctx);

    // 4. Add the new "Cancel Stream" action for the "Accept" outcome (index 1)
    treasury_actions::add_cancel_stream_action(
        action_registry,
        proposal_id,
        1, // The "Accept" outcome
        stream_id_to_cancel,
        ctx
    );
}

/// Creates a proposal to cancel multiple payment streams at once.
/// Useful for bulk cleanup operations.
public entry fun create_cancel_multiple_streams_proposal<AssetType, StableType>(
    dao: &mut DAO<AssetType, StableType>,
    action_registry: &mut ActionRegistry,
    fee_manager: &mut fee::FeeManager,
    payment: Coin<SUI>,
    dao_fee_payment: Coin<StableType>,
    title: String,
    metadata: String,
    
    // The streams to be canceled
    stream_ids_to_cancel: vector<ID>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Validate stream IDs
    assert!(stream_ids_to_cancel.length() > 0, E_INVALID_STREAM_ID);
    let mut i = 0;
    while (i < stream_ids_to_cancel.length()) {
        let stream_id = *vector::borrow(&stream_ids_to_cancel, i);
        assert!(stream_id != object::id_from_address(@0x0), E_INVALID_STREAM_ID);
        i = i + 1;
    };
    
    // 1. Create a standard binary futarchy proposal
    let outcome_descriptions = vector[
        b"Reject".to_string(), 
        b"Accept".to_string()
    ];
    
    let outcome_messages = vector[
        b"Continue payment streams".to_string(), 
        b"Cancel all specified payment streams".to_string()
    ];
    
    // Create initial liquidity amounts
    let initial_asset_amounts = vector[1000, 1000]; // Asset amounts for each outcome
    let initial_stable_amounts = vector[1000, 1000]; // Stable amounts for each outcome
    
    let (proposal_id, _, _) = dao::create_proposal_internal<AssetType, StableType>(
        dao,
        fee_manager,
        payment,
        dao_fee_payment,
        title,
        metadata,
        outcome_descriptions,
        outcome_messages,
        initial_asset_amounts,
        initial_stable_amounts,
        false, // Not using DAO liquidity
        clock,
        ctx
    );

    // 2. Initialize actions for the proposal
    treasury_actions::init_proposal_actions(
        action_registry,
        proposal_id,
        2, // Two outcomes: Reject and Accept
        ctx
    );

    // 3. Add a NO-OP action for the "Reject" outcome (index 0)
    treasury_actions::add_no_op_action(action_registry, proposal_id, 0, ctx);

    // 4. Add cancel stream actions for each stream ID
    let mut j = 0;
    while (j < stream_ids_to_cancel.length()) {
        let stream_id = *vector::borrow(&stream_ids_to_cancel, j);
        treasury_actions::add_cancel_stream_action(
            action_registry,
            proposal_id,
            1, // The "Accept" outcome
            stream_id,
            ctx
        );
        j = j + 1;
    };
}