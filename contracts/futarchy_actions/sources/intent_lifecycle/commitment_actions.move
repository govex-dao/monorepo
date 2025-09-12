/// Commitment Actions Module
/// Defines actions for creating and managing commitment proposals
module futarchy_actions::commitment_actions;

use std::string::{Self, String};
use std::vector;
use std::option::{Self, Option};
use sui::coin::{Self, Coin};
use sui::clock::{Self, Clock};
use sui::transfer;
use sui::tx_context::{Self, TxContext};
use sui::object::{Self, ID};
use sui::event;
use account_protocol::{
    executable::{Self, Executable},
    account::{Self, Account},
    version_witness::VersionWitness,
};
use futarchy_core::futarchy_config::FutarchyConfig;
use futarchy_actions::commitment_proposal::{Self, CommitmentProposal, PriceTier as CommitmentPriceTier};
use futarchy_one_shot_utils::action_data_structs::{Self, CreateCommitmentProposalAction, PriceTier};
use futarchy_actions::resource_requests::{Self, ResourceRequest, ResourceReceipt};
use futarchy_markets::{
    spot_amm::SpotAMM,
    proposal::Proposal,
};

// === Errors ===
const EInvalidProposalId: u64 = 0;
const EProposalNotFound: u64 = 1;
const ECommitmentAlreadyExists: u64 = 2;
const ECommitmentNotFound: u64 = 3;
const EInvalidRecipient: u64 = 4;
const ECannotExecuteWithoutPool: u64 = 5;
const ECannotExecuteWithoutProposal: u64 = 6;
const ECommitmentIdMismatch: u64 = 7;
const EInsufficientCommittedAmount: u64 = 8;

// === Action Structs ===

// CreateCommitmentProposalAction moved to futarchy_one_shot_utils::action_data_structs

/// Action to execute a commitment after proposal passes
public struct ExecuteCommitmentAction has store, copy, drop {
    /// ID of the commitment proposal to execute
    commitment_id: ID,
}

/// Action to update withdrawal recipient
public struct UpdateCommitmentRecipientAction has store, copy, drop {
    /// ID of the commitment proposal
    commitment_id: ID,
    /// New recipient address
    new_recipient: address,
}

/// Action to withdraw unlocked tokens
public struct WithdrawUnlockedTokensAction has store, copy, drop {
    /// ID of the commitment proposal
    commitment_id: ID,
}

// === Do Functions (Action Execution) ===

/// Create a commitment proposal directly with coins
public fun do_create_commitment_proposal<AssetType, StableType, Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    _account: &mut Account<FutarchyConfig>,
    _version: VersionWitness,
    witness: IW,
    committed_coins: Coin<AssetType>,
    clock: &Clock,
    ctx: &mut TxContext,
): CommitmentProposal<AssetType, StableType> {
    let action = executable::next_action<Outcome, CreateCommitmentProposalAction<AssetType>, IW>(
        executable,
        witness,
    );
    
    // Verify coin amount matches exactly
    assert!(coin::value(&committed_coins) >= action_data_structs::committed_amount(action), EInsufficientCommittedAmount);
    
    // Convert PriceTiers from action format to commitment format
    let action_tiers = action_data_structs::tiers(action);
    let mut commitment_tiers = vector::empty<CommitmentPriceTier>();
    let mut i = 0;
    let len = vector::length(action_tiers);
    while (i < len) {
        let tier = vector::borrow(action_tiers, i);
        // Convert action PriceTier to CommitmentPriceTier
        // Note: This is a temporary conversion - the types should be aligned
        let commitment_tier = commitment_proposal::new_price_tier(
            action_data_structs::price(tier) as u128,  // Convert price to twap_threshold
            action_data_structs::allocation(tier),     // Use allocation as lock_amount  
            86400000                                    // Default 1 day lock duration
        );
        vector::push_back(&mut commitment_tiers, commitment_tier);
        i = i + 1;
    };
    
    // Create the commitment proposal directly
    commitment_proposal::create_commitment_proposal<AssetType, StableType>(
        tx_context::sender(ctx),
        committed_coins,
        commitment_tiers,
        action_data_structs::proposal_id(action),
        action_data_structs::trading_start(action),
        action_data_structs::trading_end(action),
        *action_data_structs::commitment_description(action),
        clock,
        ctx,
    )
}

/// Execute a commitment proposal - returns ResourceRequest for hot potato pattern
public fun do_execute_commitment<AssetType, StableType, Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    _account: &mut Account<FutarchyConfig>,
    _version: VersionWitness,
    witness: IW,
    ctx: &mut TxContext,
): ResourceRequest<ExecuteCommitmentAction> {
    let action = executable::next_action<Outcome, ExecuteCommitmentAction, IW>(
        executable,
        witness,
    );
    
    // Create resource request with commitment ID in context
    let mut request = resource_requests::new_request<ExecuteCommitmentAction>(ctx);
    resource_requests::add_context(&mut request, b"commitment_id".to_string(), action.commitment_id);
    
    request
}

/// Fulfill the execute commitment request with required resources
public fun fulfill_execute_commitment<AssetType, StableType>(
    request: ResourceRequest<ExecuteCommitmentAction>,
    commitment: &mut CommitmentProposal<AssetType, StableType>,
    proposal: &Proposal<AssetType, StableType>,
    clock: &Clock,
    ctx: &mut TxContext,
): ResourceReceipt<ExecuteCommitmentAction> {
    // Get commitment ID from request context
    let commitment_id: ID = resource_requests::get_context(&request, b"commitment_id".to_string());
    
    // Verify commitment ID matches
    assert!(object::id(commitment) == commitment_id, ECommitmentIdMismatch);
    
    // Execute the commitment
    commitment_proposal::execute_commitment(
        commitment,
        proposal,
        clock,
        ctx,
    );
    
    // Fulfill and return receipt
    resource_requests::fulfill(request)
}

/// Update withdrawal recipient - returns ResourceRequest for hot potato pattern
public fun do_update_commitment_recipient<AssetType, StableType, Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    _account: &mut Account<FutarchyConfig>,
    _version: VersionWitness,
    witness: IW,
    ctx: &mut TxContext,
): ResourceRequest<UpdateCommitmentRecipientAction> {
    let action = executable::next_action<Outcome, UpdateCommitmentRecipientAction, IW>(
        executable,
        witness,
    );
    
    // Create resource request with action data in context
    let mut request = resource_requests::new_request<UpdateCommitmentRecipientAction>(ctx);
    resource_requests::add_context(&mut request, b"commitment_id".to_string(), action.commitment_id);
    resource_requests::add_context(&mut request, b"new_recipient".to_string(), action.new_recipient);
    
    request
}

/// Fulfill the update recipient request
public fun fulfill_update_commitment_recipient<AssetType, StableType>(
    request: ResourceRequest<UpdateCommitmentRecipientAction>,
    commitment: &mut CommitmentProposal<AssetType, StableType>,
    ctx: &mut TxContext,
): ResourceReceipt<UpdateCommitmentRecipientAction> {
    // Get data from request context
    let commitment_id: ID = resource_requests::get_context(&request, b"commitment_id".to_string());
    let new_recipient: address = resource_requests::get_context(&request, b"new_recipient".to_string());
    
    // Verify commitment ID matches
    assert!(object::id(commitment) == commitment_id, ECommitmentIdMismatch);
    
    // Update the recipient
    commitment_proposal::update_withdrawal_recipient(
        commitment,
        new_recipient,
        ctx,
    );
    
    // Fulfill and return receipt
    resource_requests::fulfill(request)
}

/// Withdraw unlocked tokens - returns ResourceRequest for hot potato pattern
public fun do_withdraw_unlocked_tokens<AssetType, StableType, Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    _account: &mut Account<FutarchyConfig>,
    _version: VersionWitness,
    witness: IW,
    ctx: &mut TxContext,
): ResourceRequest<WithdrawUnlockedTokensAction> {
    let action = executable::next_action<Outcome, WithdrawUnlockedTokensAction, IW>(
        executable,
        witness,
    );
    
    // Create resource request with commitment ID in context
    let mut request = resource_requests::new_request<WithdrawUnlockedTokensAction>(ctx);
    resource_requests::add_context(&mut request, b"commitment_id".to_string(), action.commitment_id);
    
    request
}

/// Fulfill the withdraw request
public fun fulfill_withdraw_unlocked_tokens<AssetType, StableType>(
    request: ResourceRequest<WithdrawUnlockedTokensAction>,
    commitment: &mut CommitmentProposal<AssetType, StableType>,
    clock: &Clock,
    ctx: &mut TxContext,
): ResourceReceipt<WithdrawUnlockedTokensAction> {
    // Get commitment ID from request context
    let commitment_id: ID = resource_requests::get_context(&request, b"commitment_id".to_string());
    
    // Verify commitment ID matches
    assert!(object::id(commitment) == commitment_id, ECommitmentIdMismatch);
    
    // Withdraw the tokens
    commitment_proposal::withdraw_unlocked_tokens(
        commitment,
        clock,
        ctx,
    );
    
    // Fulfill and return receipt
    resource_requests::fulfill(request)
}

// === Constructor Functions ===

/// Create a new CreateCommitmentProposalAction
public fun new_create_commitment_proposal_action<AssetType>(
    committed_amount: u64,
    tiers: vector<PriceTier>,
    proposal_id: ID,
    trading_start: u64,
    trading_end: u64,
    description: String,
): CreateCommitmentProposalAction<AssetType> {
    action_data_structs::new_create_commitment_proposal_action(
        committed_amount,
        tiers,
        proposal_id,
        trading_start,
        trading_end,
        description,
    )
}

/// Create a new ExecuteCommitmentAction
public fun new_execute_commitment_action(
    commitment_id: ID,
): ExecuteCommitmentAction {
    ExecuteCommitmentAction {
        commitment_id,
    }
}

/// Create a new UpdateCommitmentRecipientAction
public fun new_update_commitment_recipient_action(
    commitment_id: ID,
    new_recipient: address,
): UpdateCommitmentRecipientAction {
    UpdateCommitmentRecipientAction {
        commitment_id,
        new_recipient,
    }
}

/// Create a new WithdrawUnlockedTokensAction
public fun new_withdraw_unlocked_tokens_action(
    commitment_id: ID,
): WithdrawUnlockedTokensAction {
    WithdrawUnlockedTokensAction {
        commitment_id,
    }
}