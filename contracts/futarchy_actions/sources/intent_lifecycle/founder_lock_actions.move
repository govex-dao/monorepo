/// Founder Lock Actions Module
/// Defines actions for creating and managing founder lock proposals
module futarchy_actions::founder_lock_actions;

use std::string::{Self, String};
use std::vector;
use std::option::{Self, Option};
use sui::bcs::{Self, BCS};
use sui::coin::{Self, Coin};
use sui::clock::{Self, Clock};
use sui::transfer;
use sui::tx_context::{Self, TxContext};
use sui::object::{Self, ID};
use sui::event;
use account_protocol::{
    executable::{Self, Executable},
    intents,
    account::{Self, Account},
    version_witness::VersionWitness,
};
use futarchy_core::futarchy_config::FutarchyConfig;
use futarchy_actions::founder_lock_proposal::{Self, FounderLockProposal, PriceTier};
use futarchy_core::resource_requests::{Self, ResourceRequest, ResourceReceipt};
use futarchy_markets_core::{
    unified_spot_pool::UnifiedSpotPool,
    proposal::Proposal,
};
use futarchy_core::{action_types, action_validation};

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

/// Action to create a founder lock proposal
public struct CreateFounderLockProposalAction<phantom AssetType> has store, copy, drop {
    /// Amount of tokens to commit to the lock
    committed_amount: u64,
    /// Price tiers for vesting
    tiers: vector<PriceTier>,
    /// ID of the proposal this lock is for
    proposal_id: ID,
    /// Trading start timestamp
    trading_start: u64,
    /// Trading end timestamp
    trading_end: u64,
    /// Description of the lock
    description: String,
}

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
    CreateFounderLockProposalAction {
        committed_amount,
        tiers,
        proposal_id,
        trading_start,
        trading_end,
        description,
    }
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
    // Get spec and validate type BEFORE deserialization
    let specs = executable::intent(executable).action_specs();
    let spec = specs.borrow(executable::action_idx(executable));
    action_validation::assert_action_type<action_types::CreateFounderLockProposal>(spec);

    // Deserialize the action data
    let action_data = intents::action_spec_data(spec);
    let mut bcs = bcs::new(*action_data);
    let action = bcs::peel_u64(&mut bcs); // committed_amount
    let committed_amount = action;

    // Peel tiers vector
    let tiers_count = bcs::peel_vec_length(&mut bcs);
    let mut tiers = vector::empty<PriceTier>();
    let mut i = 0;
    while (i < tiers_count) {
        let twap_threshold = bcs::peel_u128(&mut bcs);
        let lock_amount = bcs::peel_u64(&mut bcs);
        let lock_duration_ms = bcs::peel_u64(&mut bcs);
        vector::push_back(&mut tiers, founder_lock_proposal::new_price_tier(twap_threshold, lock_amount, lock_duration_ms));
        i = i + 1;
    };

    let proposal_id = object::id_from_address(bcs::peel_address(&mut bcs));
    let trading_start = bcs::peel_u64(&mut bcs);
    let trading_end = bcs::peel_u64(&mut bcs);
    let description = bcs::peel_vec_u8(&mut bcs).to_string();

    let action = CreateFounderLockProposalAction<AssetType> {
        committed_amount,
        tiers,
        proposal_id,
        trading_start,
        trading_end,
        description,
    };

    // Increment action index
    executable::increment_action_idx(executable);

    // Return a resource request for the committed coins
    resource_requests::new_resource_request(action, ctx)
}

/// Fulfill the resource request by providing committed coins
public fun fulfill_create_founder_lock_proposal<AssetType, StableType>(
    request: ResourceRequest<CreateFounderLockProposalAction<AssetType>>,
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

    // The tiers are already in the correct format since we use the same PriceTier type
    let founder_lock_tiers = action.tiers;

    // Create the founder lock proposal
    let proposer = tx_context::sender(ctx);
    let founder_lock = founder_lock_proposal::create_founder_lock_proposal(
        proposer,
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
    // Get spec and validate type BEFORE deserialization
    let specs = executable::intent(executable).action_specs();
    let spec = specs.borrow(executable::action_idx(executable));
    action_validation::assert_action_type<action_types::ExecuteFounderLock>(spec);

    // Deserialize the action data
    let action_data = intents::action_spec_data(spec);
    let mut bcs = bcs::new(*action_data);
    let founder_lock_id = object::id_from_address(bcs::peel_address(&mut bcs));
    let action = ExecuteFounderLockAction { founder_lock_id };

    // Increment action index
    executable::increment_action_idx(executable);

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
    // Get spec and validate type BEFORE deserialization
    let specs = executable::intent(executable).action_specs();
    let spec = specs.borrow(executable::action_idx(executable));
    action_validation::assert_action_type<action_types::UpdateFounderLockRecipient>(spec);

    // Deserialize the action data
    let action_data = intents::action_spec_data(spec);
    let mut bcs = bcs::new(*action_data);
    let founder_lock_id = object::id_from_address(bcs::peel_address(&mut bcs));
    let new_recipient = bcs::peel_address(&mut bcs);
    let action = UpdateFounderLockRecipientAction {
        founder_lock_id,
        new_recipient,
    };

    // Increment action index
    executable::increment_action_idx(executable);

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
    // Get spec and validate type BEFORE deserialization
    let specs = executable::intent(executable).action_specs();
    let spec = specs.borrow(executable::action_idx(executable));
    action_validation::assert_action_type<action_types::WithdrawUnlockedTokens>(spec);

    // Deserialize the action data
    let action_data = intents::action_spec_data(spec);
    let mut bcs = bcs::new(*action_data);
    let founder_lock_id = object::id_from_address(bcs::peel_address(&mut bcs));
    let action = WithdrawUnlockedTokensAction { founder_lock_id };

    // Increment action index
    executable::increment_action_idx(executable);

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

// === Garbage Collection ===

/// Delete a create founder lock proposal action from an expired intent
public fun delete_create_founder_lock_proposal<AssetType>(expired: &mut intents::Expired) {
    let action_spec = intents::remove_action_spec(expired);
    let _ = action_spec;
}

/// Delete an execute founder lock action from an expired intent
public fun delete_execute_founder_lock(expired: &mut intents::Expired) {
    let action_spec = intents::remove_action_spec(expired);
    let _ = action_spec;
}

/// Delete an update founder lock recipient action from an expired intent
public fun delete_update_founder_lock_recipient(expired: &mut intents::Expired) {
    let action_spec = intents::remove_action_spec(expired);
    let _ = action_spec;
}

/// Delete a withdraw unlocked tokens action from an expired intent
public fun delete_withdraw_unlocked_tokens(expired: &mut intents::Expired) {
    let action_spec = intents::remove_action_spec(expired);
    let _ = action_spec;
}