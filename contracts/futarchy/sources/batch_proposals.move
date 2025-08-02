module futarchy::batch_proposals;

use std::string::String;
use sui::coin::Coin;
use sui::clock::Clock;
use sui::sui::SUI;
use sui::tx_context::TxContext;

use futarchy::{
    dao::{Self},
    dao_state::DAO,
    fee,
    action_registry::{Self, ActionRegistry, Action}
};

// === Errors ===
const E_OUTCOME_VECTOR_MISMATCH: u64 = 0;
const E_INVALID_OUTCOME_COUNT: u64 = 1;
const E_ACTIONS_LENGTH_MISMATCH: u64 = 2;

// === Public Entry Functions ===

/// Create a proposal with multiple actions per outcome
public fun create_proposal<AssetType, StableType>(
    dao: &mut DAO<AssetType, StableType>,
    action_registry: &mut ActionRegistry,
    fee_manager: &mut fee::FeeManager,
    payment: Coin<SUI>,
    dao_fee_payment: Coin<StableType>,
    title: String,
    metadata: String,
    outcome_messages: vector<String>,
    outcome_details: vector<String>,
    initial_asset_amounts: vector<u64>,
    initial_stable_amounts: vector<u64>,
    
    // The core of the proposal: an ordered list of actions for each outcome.
    sequences_by_outcome: vector<vector<Action>>,

    clock: &Clock,
    ctx: &mut TxContext,
) {
    let outcome_count = outcome_messages.length();
    
    // Validate inputs
    assert!(outcome_count >= 2, E_INVALID_OUTCOME_COUNT);
    assert!(sequences_by_outcome.length() == outcome_count, E_OUTCOME_VECTOR_MISMATCH);
    assert!(outcome_details.length() == outcome_count, E_OUTCOME_VECTOR_MISMATCH);
    assert!(initial_asset_amounts.length() == outcome_count, E_ACTIONS_LENGTH_MISMATCH);
    assert!(initial_stable_amounts.length() == outcome_count, E_ACTIONS_LENGTH_MISMATCH);

    // 1. Create the base futarchy proposal
    let (proposal_id, _market_state_id, _state) = dao::create_proposal_internal<AssetType, StableType>(
        dao, 
        fee_manager, 
        payment, 
        dao_fee_payment, 
        title, 
        metadata,
        outcome_messages, 
        outcome_details, 
        initial_asset_amounts,
        initial_stable_amounts,
        false, // uses_dao_liquidity
        clock, 
        ctx
    );

    // 2. Securely store the entire action plan in the unified registry.
    action_registry::init_proposal_actions(
        action_registry,
        proposal_id,
        sequences_by_outcome,
        ctx
    );
}

/// Create a simple binary proposal (Reject/Accept) with actions
public fun create_binary_proposal<AssetType, StableType>(
    dao: &mut DAO<AssetType, StableType>,
    action_registry: &mut ActionRegistry,
    fee_manager: &mut fee::FeeManager,
    payment: Coin<SUI>,
    dao_fee_payment: Coin<StableType>,
    title: String,
    metadata: String,
    initial_asset_amount_reject: u64,
    initial_stable_amount_reject: u64,
    initial_asset_amount_accept: u64,
    initial_stable_amount_accept: u64,
    
    // Actions to execute if accepted (reject outcome has no actions)
    accept_actions: vector<Action>,

    clock: &Clock,
    ctx: &mut TxContext,
) {
    let mut sequences_by_outcome = vector::empty<vector<Action>>();
    
    // Outcome 0: Reject (no actions)
    vector::push_back(&mut sequences_by_outcome, vector::empty<Action>());
    
    // Outcome 1: Accept (provided actions)
    vector::push_back(&mut sequences_by_outcome, accept_actions);

    create_proposal(
        dao,
        action_registry,
        fee_manager,
        payment,
        dao_fee_payment,
        title,
        metadata,
        vector[b"Reject".to_string(), b"Accept".to_string()],
        vector[b"No change".to_string(), b"Execute actions".to_string()],
        vector[initial_asset_amount_reject, initial_asset_amount_accept],
        vector[initial_stable_amount_reject, initial_stable_amount_accept],
        sequences_by_outcome,
        clock,
        ctx
    );
}

/// Create a multi-outcome proposal with custom messages and actions
public fun create_multi_outcome_proposal<AssetType, StableType>(
    dao: &mut DAO<AssetType, StableType>,
    action_registry: &mut ActionRegistry,
    fee_manager: &mut fee::FeeManager,
    payment: Coin<SUI>,
    dao_fee_payment: Coin<StableType>,
    title: String,
    metadata: String,
    outcome_messages: vector<String>,
    outcome_details: vector<String>,
    initial_asset_amounts: vector<u64>,
    initial_stable_amounts: vector<u64>,
    sequences_by_outcome: vector<vector<Action>>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Ensure the first outcome is always "Reject" with no actions
    assert!(&outcome_messages[0] == &b"Reject".to_string(), E_INVALID_OUTCOME_COUNT);
    assert!(vector::is_empty(&sequences_by_outcome[0]), E_ACTIONS_LENGTH_MISMATCH);

    create_proposal(
        dao,
        action_registry,
        fee_manager,
        payment,
        dao_fee_payment,
        title,
        metadata,
        outcome_messages,
        outcome_details,
        initial_asset_amounts,
        initial_stable_amounts,
        sequences_by_outcome,
        clock,
        ctx
    );
}

// === Convenience Functions for Common Proposals ===

/// Create a treasury transfer proposal
public entry fun create_transfer_proposal<AssetType, StableType, TransferCoinType>(
    dao: &mut DAO<AssetType, StableType>,
    action_registry: &mut ActionRegistry,
    fee_manager: &mut fee::FeeManager,
    payment: Coin<SUI>,
    dao_fee_payment: Coin<StableType>,
    title: String,
    metadata: String,
    initial_asset_amounts: vector<u64>,
    initial_stable_amounts: vector<u64>,
    recipient: address,
    amount: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let transfer_action = action_registry::create_transfer_action(
        std::type_name::get<TransferCoinType>(),
        recipient,
        amount
    );

    create_binary_proposal(
        dao,
        action_registry,
        fee_manager,
        payment,
        dao_fee_payment,
        title,
        metadata,
        initial_asset_amounts[0],
        initial_stable_amounts[0],
        initial_asset_amounts[1],
        initial_stable_amounts[1],
        vector[transfer_action],
        clock,
        ctx
    );
}

/// Create a configuration update proposal
public fun create_config_update_proposal<AssetType, StableType>(
    dao: &mut DAO<AssetType, StableType>,
    action_registry: &mut ActionRegistry,
    fee_manager: &mut fee::FeeManager,
    payment: Coin<SUI>,
    dao_fee_payment: Coin<StableType>,
    title: String,
    metadata: String,
    initial_asset_amounts: vector<u64>,
    initial_stable_amounts: vector<u64>,
    config_actions: vector<Action>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    create_binary_proposal(
        dao,
        action_registry,
        fee_manager,
        payment,
        dao_fee_payment,
        title,
        metadata,
        initial_asset_amounts[0],
        initial_stable_amounts[0],
        initial_asset_amounts[1],
        initial_stable_amounts[1],
        config_actions,
        clock,
        ctx
    );
}

/// Create a complex proposal with multiple treasury operations
public fun create_multi_treasury_proposal<AssetType, StableType>(
    dao: &mut DAO<AssetType, StableType>,
    action_registry: &mut ActionRegistry,
    fee_manager: &mut fee::FeeManager,
    payment: Coin<SUI>,
    dao_fee_payment: Coin<StableType>,
    title: String,
    metadata: String,
    initial_asset_amounts: vector<u64>,
    initial_stable_amounts: vector<u64>,
    treasury_actions: vector<Action>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Validate all actions are treasury-related
    let mut i = 0;
    while (i < treasury_actions.length()) {
        let action_type = action_registry::get_action_type(vector::borrow(&treasury_actions, i));
        assert!(
            action_type >= 1 && action_type <= 5, // Treasury action range
            E_ACTIONS_LENGTH_MISMATCH
        );
        i = i + 1;
    };

    create_binary_proposal(
        dao,
        action_registry,
        fee_manager,
        payment,
        dao_fee_payment,
        title,
        metadata,
        initial_asset_amounts[0],
        initial_stable_amounts[0],
        initial_asset_amounts[1],
        initial_stable_amounts[1],
        treasury_actions,
        clock,
        ctx
    );
}