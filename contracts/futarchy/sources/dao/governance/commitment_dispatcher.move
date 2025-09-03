/// Commitment Dispatcher Module
/// Routes commitment-related actions through the action dispatcher system
module futarchy::commitment_dispatcher;

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
use futarchy::{
    futarchy_config::FutarchyConfig,
    version,
    commitment_proposal::{Self, CommitmentProposal},
    proposal::Proposal,
    commitment_actions::{Self, CreateCommitmentProposalAction, ExecuteCommitmentAction, 
                         UpdateCommitmentRecipientAction, WithdrawUnlockedTokensAction},
};

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

/// Try to execute commitment execution action
public fun try_execute_commitment<AssetType, StableType, Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    witness: IW,
    commitment: &mut CommitmentProposal<AssetType, StableType>,
    proposal: &Proposal<AssetType, StableType>,
    clock: &Clock,
    ctx: &mut TxContext,
): bool {
    if (executable::contains_action<Outcome, ExecuteCommitmentAction>(executable)) {
        commitment_actions::do_execute_commitment<AssetType, StableType, Outcome, IW>(
            executable,
            account,
            version::current(),
            witness,
            commitment,
            proposal,
            clock,
            ctx,
        );
        true
    } else {
        false
    }
}

/// Try to execute other commitment actions
public fun try_execute_other_commitment_actions<AssetType, StableType, Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    witness: IW,
    commitment: &mut futarchy::commitment_proposal::CommitmentProposal<AssetType, StableType>,
    clock: &Clock,
    ctx: &mut TxContext,
): bool {
    if (executable::contains_action<Outcome, UpdateCommitmentRecipientAction>(executable)) {
        commitment_actions::do_update_commitment_recipient<AssetType, StableType, Outcome, IW>(
            executable,
            account,
            version::current(),
            witness,
            commitment,
            ctx,
        );
        true
    } else if (executable::contains_action<Outcome, WithdrawUnlockedTokensAction>(executable)) {
        commitment_actions::do_withdraw_unlocked_tokens<AssetType, StableType, Outcome, IW>(
            executable,
            account,
            version::current(),
            witness,
            commitment,
            clock,
            ctx,
        );
        true
    } else {
        false
    }
}