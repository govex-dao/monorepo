/// Founder Lock Actions Module
/// Defines actions for creating and managing founder lock proposals
module futarchy_actions::founder_lock_actions;

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
use futarchy_actions::founder_lock_proposal::{Self, FounderLockProposal, PriceTier as FounderLockPriceTier};
use futarchy_one_shot_utils::action_data_structs::{Self, CreateFounderLockProposalAction, PriceTier,
    get_create_founder_lock_proposal_committed_amount,
    get_create_founder_lock_proposal_tiers,
    get_create_founder_lock_proposal_proposal_id,
    get_create_founder_lock_proposal_trading_start,
    get_create_founder_lock_proposal_trading_end,
    get_create_founder_lock_proposal_description,
};
use futarchy_actions::resource_requests::{Self, ResourceRequest, ResourceReceipt};
use futarchy_markets::{
    spot_amm::SpotAMM,
    proposal::Proposal,
};

// === Errors ===
const EInvalidProposalId: u64 = 0;
const EProposalNotFound: u64 = 1;
const EFounderLockAlreadyExists: u64 = 2;
const EFounderLockNotFound: u64 = 3;
const EInvalidRecipient: u64 = 4;
const ECannotExecuteWithoutPool: u64 = 5;
const ECannotExecuteWithoutProposal: u64 = 6;
const EFounderLockIdMismatch: u64 = 7;
const EInsufficientCommittedAmount: u64 = 8;

// === Action Structs ===

// CreateFounderLockProposalAction moved to futarchy_one_shot_utils::action_data_structs

/// Action to execute a founder lock after proposal passes
public struct ExecuteFounderLockAction has store, copy, drop {
    /// ID of the founder lock proposal to execute
    founder_lock_id: ID,
}

/// Action to update withdrawal recipient
public struct UpdateFounderLockRecipientAction has store, copy, drop {
    /// ID of the founder lock proposal
    founder_lock_id: ID,
    /// New recipient address
    new_recipient: address,
}

/// Action to withdraw unlocked tokens
public struct WithdrawUnlockedTokensAction has store, copy, drop {
    /// ID of the founder lock proposal
    founder_lock_id: ID,
}

// === Constructor Functions ===

/// Create a new founder lock creation action
public fun new_create_founder_lock_proposal_action<AssetType>(
    committed_amount: u64,
    tiers: vector<PriceTier>,
    proposal_id: ID,
    trading_start: u64,
    trading_end: u64,
    description: String,
): CreateFounderLockProposalAction<AssetType> {
    action_data_structs::new_create_founder_lock_proposal_action<AssetType>(
        committed_amount,
        tiers,
        proposal_id,
        trading_start,
        trading_end,
        description,
    )
}

/// Create an execute founder lock action
public fun new_execute_founder_lock_action(
    founder_lock_id: ID,
): ExecuteFounderLockAction {
    ExecuteFounderLockAction { founder_lock_id }
}

/// Create an update recipient action
public fun new_update_founder_lock_recipient_action(
    founder_lock_id: ID,
    new_recipient: address,
): UpdateFounderLockRecipientAction {
    UpdateFounderLockRecipientAction {
        founder_lock_id,
        new_recipient,
    }
}

/// Create a withdraw action
public fun new_withdraw_unlocked_tokens_action(
    founder_lock_id: ID,
): WithdrawUnlockedTokensAction {
    WithdrawUnlockedTokensAction { founder_lock_id }
}

// === Execution Functions ===

/// Execute the creation of a founder lock proposal
/// Returns a ResourceRequest that needs the founder lock coins
public fun do_create_founder_lock_proposal<AssetType, StableType, Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    _account: &mut Account<FutarchyConfig>,
    _version: VersionWitness,
    witness: IW,
    _clock: &Clock,
    ctx: &mut TxContext,
): ResourceRequest<CreateFounderLockProposalAction<AssetType>> {
    let action = executable::next_action<Outcome, CreateFounderLockProposalAction<AssetType>, IW>(
        executable,
        witness
    );

    // Return a resource request for the committed coins
    resource_requests::new_resource_request(action, ctx)
}

/// Fulfill the resource request by providing committed coins
public fun fulfill_create_founder_lock_proposal<AssetType, StableType>(
    request: ResourceRequest<CreateFounderLockProposalAction>,
    committed_coins: Coin<AssetType>,
    clock: &Clock,
    ctx: &mut TxContext,
): (FounderLockProposal<AssetType, StableType>, ResourceReceipt<CreateFounderLockProposalAction<AssetType>>) {
    let action = resource_requests::extract_action(request);

    // Validate committed amount
    assert!(
        coin::value(&committed_coins) >= action.committed_amount,
        EInsufficientCommittedAmount
    );

    // Convert action tiers to founder lock tiers
    let mut founder_lock_tiers = vector::empty<FounderLockPriceTier>();
    let len = vector::length(&action.tiers);
    let mut i = 0;

    while (i < len) {
        let tier = vector::borrow(&action.tiers, i);
        vector::push_back(
            &mut founder_lock_tiers,
            founder_lock_proposal::new_price_tier(
                tier.twap_threshold,
                tier.lock_amount,
                tier.lock_duration_ms,
            )
        );
        i = i + 1;
    };

    // Create the founder lock proposal
    let founder_lock = founder_lock_proposal::create_founder_lock_proposal(
        action.proposer,
        committed_coins,
        founder_lock_tiers,
        action.proposal_id,
        action.trading_start,
        action.trading_end,
        action.description,
        clock,
        ctx,
    );

    let receipt = resource_requests::create_receipt(action);
    (founder_lock, receipt)
}

/// Execute a founder lock after proposal passes
public fun do_execute_founder_lock<AssetType, StableType, Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    _account: &mut Account<FutarchyConfig>,
    _version: VersionWitness,
    witness: IW,
    founder_lock: &mut FounderLockProposal<AssetType, StableType>,
    proposal: &Proposal<AssetType, StableType>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let action = executable::next_action<Outcome, ExecuteFounderLockAction, IW>(
        executable,
        witness
    );

    // Validate IDs match
    assert!(
        object::id(founder_lock) == action.founder_lock_id,
        EFounderLockIdMismatch
    );

    // Execute the founder lock
    founder_lock_proposal::execute_founder_lock(
        founder_lock,
        proposal,
        clock,
        ctx,
    );
}

/// Update the withdrawal recipient
public fun do_update_founder_lock_recipient<AssetType, StableType, Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    _account: &mut Account<FutarchyConfig>,
    _version: VersionWitness,
    witness: IW,
    founder_lock: &mut FounderLockProposal<AssetType, StableType>,
    ctx: &mut TxContext,
) {
    let action = executable::next_action<Outcome, UpdateFounderLockRecipientAction, IW>(
        executable,
        witness
    );

    // Validate IDs match
    assert!(
        object::id(founder_lock) == action.founder_lock_id,
        EFounderLockIdMismatch
    );

    // Update recipient
    founder_lock_proposal::update_withdrawal_recipient(
        founder_lock,
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
    founder_lock: &mut FounderLockProposal<AssetType, StableType>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let action = executable::next_action<Outcome, WithdrawUnlockedTokensAction, IW>(
        executable,
        witness
    );

    // Validate IDs match
    assert!(
        object::id(founder_lock) == action.founder_lock_id,
        EFounderLockIdMismatch
    );

    // Withdraw tokens
    founder_lock_proposal::withdraw_unlocked_tokens(
        founder_lock,
        clock,
        ctx,
    );
}