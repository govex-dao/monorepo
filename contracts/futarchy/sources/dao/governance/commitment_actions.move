/// Commitment Actions Module
/// Defines actions for creating and managing commitment proposals
module futarchy::commitment_actions;

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
use futarchy::{
    futarchy_config::FutarchyConfig,
    version,
    commitment_proposal::{Self, CommitmentProposal, PriceTier},
    spot_amm::SpotAMM,
    resource_requests::{Self, ResourceRequest, ResourceReceipt},
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

/// Action to create a commitment proposal
public struct CreateCommitmentProposalAction<phantom AssetType> has store, copy, drop {
    /// Amount of tokens to commit
    committed_amount: u64,
    /// Price tiers for locking
    tiers: vector<PriceTier>,
    /// Associated proposal ID
    proposal_id: ID,
    /// Trading start time
    trading_start: u64,
    /// Trading end time
    trading_end: u64,
    /// Description of the commitment
    description: String,
}

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
    assert!(coin::value(&committed_coins) >= action.committed_amount, EInsufficientCommittedAmount);
    
    // Create the commitment proposal directly
    commitment_proposal::create_commitment_proposal(
        tx_context::sender(ctx),
        committed_coins,
        action.tiers,
        action.proposal_id,
        action.trading_start,
        action.trading_end,
        action.description,
        clock,
        ctx,
    )
}

/// Execute a commitment proposal directly
public fun do_execute_commitment<AssetType, StableType, Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    _account: &mut Account<FutarchyConfig>,
    _version: VersionWitness,
    witness: IW,
    commitment: &mut CommitmentProposal<AssetType, StableType>,
    proposal: &Proposal<AssetType, StableType>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let action = executable::next_action<Outcome, ExecuteCommitmentAction, IW>(
        executable,
        witness,
    );
    
    // Verify commitment ID matches the action's target
    assert!(object::id(commitment) == action.commitment_id, ECommitmentIdMismatch);
    
    // Execute the commitment directly
    commitment_proposal::execute_commitment(
        commitment,
        proposal,
        clock,
        ctx,
    );
}

/// Update withdrawal recipient
public fun do_update_commitment_recipient<AssetType, StableType, Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    _account: &mut Account<FutarchyConfig>,
    _version: VersionWitness,
    witness: IW,
    commitment: &mut CommitmentProposal<AssetType, StableType>,
    ctx: &mut TxContext,
) {
    let action = executable::next_action<Outcome, UpdateCommitmentRecipientAction, IW>(
        executable,
        witness,
    );
    
    // Verify commitment ID matches the action's target
    assert!(object::id(commitment) == action.commitment_id, ECommitmentIdMismatch);
    
    // Update the recipient
    commitment_proposal::update_withdrawal_recipient(
        commitment,
        action.new_recipient,
        ctx,
    );
}

/// Withdraw unlocked tokens
public fun do_withdraw_unlocked_tokens<AssetType, StableType, Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    _account: &mut Account<FutarchyConfig>,
    _version: VersionWitness,
    witness: IW,
    commitment: &mut CommitmentProposal<AssetType, StableType>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let action = executable::next_action<Outcome, WithdrawUnlockedTokensAction, IW>(
        executable,
        witness,
    );
    
    // Verify commitment ID matches the action's target
    assert!(object::id(commitment) == action.commitment_id, ECommitmentIdMismatch);
    
    // Withdraw the tokens
    commitment_proposal::withdraw_unlocked_tokens(
        commitment,
        clock,
        ctx,
    );
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
    CreateCommitmentProposalAction {
        committed_amount,
        tiers,
        proposal_id,
        trading_start,
        trading_end,
        description,
    }
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