/// Commitment Dispatcher Module
/// Routes commitment-related actions through the action dispatcher system
module futarchy_actions::commitment_dispatcher;

use std::string::{Self, String};
use std::option::{Self, Option};
use sui::clock::Clock;
use sui::coin::Coin;
use sui::transfer;
use sui::tx_context::TxContext;
use account_protocol::{
    executable::{Self, Executable},
    account::{Self, Account},
    version_witness::VersionWitness,
};
use futarchy_core::version;
use futarchy_core::futarchy_config::FutarchyConfig;
use futarchy_actions::{
    commitment_proposal::{Self, CommitmentProposal},
    commitment_actions::{Self, CreateCommitmentProposalAction, ExecuteCommitmentAction, 
                         UpdateCommitmentRecipientAction, WithdrawUnlockedTokensAction},
};
use futarchy_markets::{
    proposal::Proposal,
};
use futarchy_actions::resource_requests::{Self, ResourceRequest, ResourceReceipt};

// === Dispatcher Functions ===

/// Try to execute create commitment action
public fun try_execute_create_commitment<AssetType, StableType, Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    witness: IW,
    committed_coins: Coin<AssetType>,
    clock: &Clock,
    ctx: &mut TxContext,
): Option<CommitmentProposal<AssetType, StableType>> {
    if (executable::contains_action<Outcome, CreateCommitmentProposalAction<AssetType>>(executable)) {
        let commitment = commitment_actions::do_create_commitment_proposal<AssetType, StableType, Outcome, IW>(
            executable,
            account,
            version::current(),
            witness,
            committed_coins,
            clock,
            ctx,
        );
        option::some(commitment)
    } else {
        // If no action, return the coins to the sender
        transfer::public_transfer(committed_coins, ctx.sender());
        option::none()
    }
}

/// Try to execute commitment execution action - returns ResourceRequest
public fun try_execute_commitment<AssetType, StableType, Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    witness: IW,
    ctx: &mut TxContext,
): Option<ResourceRequest<ExecuteCommitmentAction>> {
    if (executable::contains_action<Outcome, ExecuteCommitmentAction>(executable)) {
        let request = commitment_actions::do_execute_commitment<AssetType, StableType, Outcome, IW>(
            executable,
            account,
            version::current(),
            witness,
            ctx,
        );
        option::some(request)
    } else {
        option::none()
    }
}

/// Try to execute update recipient action - returns ResourceRequest
public fun try_execute_update_recipient<AssetType, StableType, Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    witness: IW,
    ctx: &mut TxContext,
): Option<ResourceRequest<UpdateCommitmentRecipientAction>> {
    if (executable::contains_action<Outcome, UpdateCommitmentRecipientAction>(executable)) {
        let request = commitment_actions::do_update_commitment_recipient<AssetType, StableType, Outcome, IW>(
            executable,
            account,
            version::current(),
            witness,
            ctx,
        );
        option::some(request)
    } else {
        option::none()
    }
}

/// Try to execute withdraw action - returns ResourceRequest
public fun try_execute_withdraw_tokens<AssetType, StableType, Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    witness: IW,
    ctx: &mut TxContext,
): Option<ResourceRequest<WithdrawUnlockedTokensAction>> {
    if (executable::contains_action<Outcome, WithdrawUnlockedTokensAction>(executable)) {
        let request = commitment_actions::do_withdraw_unlocked_tokens<AssetType, StableType, Outcome, IW>(
            executable,
            account,
            version::current(),
            witness,
            ctx,
        );
        option::some(request)
    } else {
        option::none()
    }
}