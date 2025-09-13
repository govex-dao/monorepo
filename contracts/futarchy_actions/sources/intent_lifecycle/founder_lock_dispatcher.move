/// Commitment Dispatcher Module
/// Routes incentives_and_options-related actions through the action dispatcher system
module futarchy_actions::incentives_and_options_dispatcher;

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
    incentives_and_options_proposal::{Self, IncentivesAndOptionsProposal},
    incentives_and_options_actions::{Self, ExecuteIncentivesAndOptionsAction, 
                         UpdateIncentivesAndOptionsRecipientAction, WithdrawUnlockedTokensAction},
};
use futarchy_one_shot_utils::action_data_structs::CreateIncentivesAndOptionsProposalAction;
use futarchy_markets::{
    proposal::Proposal,
};
use futarchy_actions::resource_requests::{Self, ResourceRequest, ResourceReceipt};

// === Dispatcher Functions ===

/// Try to execute create incentives_and_options action
public fun try_execute_create_incentives_and_options<AssetType, StableType, Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    witness: IW,
    committed_coins: Coin<AssetType>,
    clock: &Clock,
    ctx: &mut TxContext,
): Option<IncentivesAndOptionsProposal<AssetType, StableType>> {
    if (executable::contains_action<Outcome, CreateIncentivesAndOptionsProposalAction<AssetType>>(executable)) {
        let incentives_and_options = incentives_and_options_actions::do_create_incentives_and_options_proposal<AssetType, StableType, Outcome, IW>(
            executable,
            account,
            version::current(),
            witness,
            committed_coins,
            clock,
            ctx,
        );
        option::some(incentives_and_options)
    } else {
        // If no action, return the coins to the sender
        transfer::public_transfer(committed_coins, ctx.sender());
        option::none()
    }
}

/// Try to execute incentives_and_options execution action - returns ResourceRequest
public fun try_execute_incentives_and_options<AssetType, StableType, Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    witness: IW,
    ctx: &mut TxContext,
): Option<ResourceRequest<ExecuteIncentivesAndOptionsAction>> {
    if (executable::contains_action<Outcome, ExecuteIncentivesAndOptionsAction>(executable)) {
        let request = incentives_and_options_actions::do_execute_incentives_and_options<AssetType, StableType, Outcome, IW>(
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
): Option<ResourceRequest<UpdateIncentivesAndOptionsRecipientAction>> {
    if (executable::contains_action<Outcome, UpdateIncentivesAndOptionsRecipientAction>(executable)) {
        let request = incentives_and_options_actions::do_update_incentives_and_options_recipient<AssetType, StableType, Outcome, IW>(
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
        let request = incentives_and_options_actions::do_withdraw_unlocked_tokens<AssetType, StableType, Outcome, IW>(
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