/// Actions for commitment proposal lifecycle
/// Integrates with the futarchy action dispatcher and Intent system

module futarchy_actions::commitment_actions;

// === Imports ===
use std::string::String;
use sui::{
    bcs,
    coin::Coin,
    clock::Clock,
    object::ID,
    tx_context::TxContext,
};
use futarchy_core::{
    action_validation,
    action_types,
};
use futarchy_actions::commitment_proposal::{Self, PriceTier, CommitmentProposal};
use account_protocol::{
    bcs_validation,
    executable::{Self, Executable},
    intents,
};

// === Action Structs ===

/// Action to create a commitment proposal
public struct CreateCommitmentProposalAction<phantom AssetType> has store, drop, copy {
    committed_amount: u64,
    tier_thresholds: vector<u128>,  // TWAP thresholds
    tier_lock_amounts: vector<u64>,  // Amount to lock per tier
    tier_lock_durations: vector<u64>,  // Lock duration per tier (ms)
    cancelable_before_trading: bool,
    trading_start: u64,
    trading_end: u64,
    description: String,
}

/// Action to execute commitment (called after trading ends)
public struct ExecuteCommitmentAction has store, drop, copy {
    commitment_proposal_id: ID,
    accept_market_twap: u128,  // TWAP from ACCEPT conditional market
}

/// Action to cancel commitment before trading
public struct CancelCommitmentAction has store, drop, copy {
    commitment_proposal_id: ID,
}

/// Action to update withdrawal recipient
public struct UpdateCommitmentRecipientAction has store, drop, copy {
    commitment_proposal_id: ID,
    new_recipient: address,
}

/// Action to withdraw unlocked tokens after lock period
public struct WithdrawCommitmentAction has store, drop, copy {
    commitment_proposal_id: ID,
}

// === Execution Functions ===

/// Executes create commitment proposal action
/// NOTE: This needs to be called with the committed coins from the proposer
/// Returns the created CommitmentProposal to be shared
public fun do_create_commitment_proposal<Outcome: store, AssetType, IW: copy + drop>(
    executable: &mut Executable<Outcome>,
    deposit: Coin<AssetType>,
    witness: IW,
    clock: &Clock,
    ctx: &mut TxContext,
): CommitmentProposal<AssetType> {
    // Get spec and validate type BEFORE deserialization
    let specs = executable::intent(executable).action_specs();
    let spec = specs.borrow(executable::action_idx(executable));
    action_validation::assert_action_type<action_types::CreateCommitmentProposal>(spec);

    // Deserialize the action data
    let action_data = intents::action_spec_data(spec);
    let mut reader = bcs::new(*action_data);

    let committed_amount = bcs::peel_u64(&mut reader);
    let tier_thresholds = bcs::peel_vec_u128(&mut reader);
    let tier_lock_amounts = bcs::peel_vec_u64(&mut reader);
    let tier_lock_durations = bcs::peel_vec_u64(&mut reader);
    let cancelable_before_trading = bcs::peel_bool(&mut reader);
    let trading_start = bcs::peel_u64(&mut reader);
    let trading_end = bcs::peel_u64(&mut reader);
    let description = bcs::peel_vec_u8(&mut reader).to_string();

    bcs_validation::validate_all_bytes_consumed(reader);

    // Validate all tier vectors have same length
    let tier_count = tier_thresholds.length();
    assert!(
        tier_lock_amounts.length() == tier_count &&
        tier_lock_durations.length() == tier_count,
        9  // ETierVectorLengthMismatch from commitment_proposal
    );

    // Build tier vector
    let mut tiers = vector::empty<PriceTier>();
    let mut i = 0;

    while (i < tier_count) {
        let tier = commitment_proposal::new_price_tier(
            *tier_thresholds.borrow(i),
            *tier_lock_amounts.borrow(i),
            *tier_lock_durations.borrow(i),
        );
        tiers.push_back(tier);
        i = i + 1;
    };

    // Create the proposal
    let proposal = commitment_proposal::create_commitment_proposal(
        deposit,
        tiers,
        cancelable_before_trading,
        trading_start,
        trading_end,
        clock,
        ctx
    );

    // Increment action index
    executable::increment_action_idx(executable);

    proposal
}

/// Executes commitment based on market TWAP
/// Returns refund coin to be transferred to proposer
public fun do_execute_commitment<Outcome: store, AssetType, IW: copy + drop>(
    executable: &mut Executable<Outcome>,
    proposal: &mut CommitmentProposal<AssetType>,
    witness: IW,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<AssetType> {
    // Get spec and validate type
    let specs = executable::intent(executable).action_specs();
    let spec = specs.borrow(executable::action_idx(executable));
    action_validation::assert_action_type<action_types::ExecuteCommitment>(spec);

    // Deserialize
    let action_data = intents::action_spec_data(spec);
    let mut reader = bcs::new(*action_data);

    let commitment_proposal_id = bcs::peel_address(&mut reader).to_id();
    let accept_market_twap = bcs::peel_u128(&mut reader);

    bcs_validation::validate_all_bytes_consumed(reader);

    // Verify proposal ID matches
    assert!(object::id(proposal) == commitment_proposal_id, 0);

    // Execute commitment
    let refund = commitment_proposal::execute_commitment(
        proposal,
        accept_market_twap,
        clock,
        ctx
    );

    // Increment action index
    executable::increment_action_idx(executable);

    refund
}

/// Cancels commitment before trading
public fun do_cancel_commitment<Outcome: store, AssetType, IW: copy + drop>(
    executable: &mut Executable<Outcome>,
    proposal: &mut CommitmentProposal<AssetType>,
    witness: IW,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<AssetType> {
    // Get spec and validate type
    let specs = executable::intent(executable).action_specs();
    let spec = specs.borrow(executable::action_idx(executable));
    action_validation::assert_action_type<action_types::CancelCommitment>(spec);

    // Deserialize
    let action_data = intents::action_spec_data(spec);
    let mut reader = bcs::new(*action_data);

    let commitment_proposal_id = bcs::peel_address(&mut reader).to_id();

    bcs_validation::validate_all_bytes_consumed(reader);

    // Verify proposal ID
    assert!(object::id(proposal) == commitment_proposal_id, 0);

    // Cancel
    let refund = commitment_proposal::cancel_commitment(
        proposal,
        clock,
        ctx
    );

    executable::increment_action_idx(executable);

    refund
}

/// Updates withdrawal recipient
public fun do_update_commitment_recipient<Outcome: store, AssetType, IW: copy + drop>(
    executable: &mut Executable<Outcome>,
    proposal: &mut CommitmentProposal<AssetType>,
    witness: IW,
    _clock: &Clock,
    ctx: &mut TxContext,
) {
    // Get spec and validate type
    let specs = executable::intent(executable).action_specs();
    let spec = specs.borrow(executable::action_idx(executable));
    action_validation::assert_action_type<action_types::UpdateCommitmentRecipient>(spec);

    // Deserialize
    let action_data = intents::action_spec_data(spec);
    let mut reader = bcs::new(*action_data);

    let commitment_proposal_id = bcs::peel_address(&mut reader).to_id();
    let new_recipient = bcs::peel_address(&mut reader);

    bcs_validation::validate_all_bytes_consumed(reader);

    // Verify proposal ID
    assert!(object::id(proposal) == commitment_proposal_id, 0);

    // Update recipient
    commitment_proposal::update_withdrawal_recipient(
        proposal,
        new_recipient,
        ctx
    );

    executable::increment_action_idx(executable);
}

/// Withdraws unlocked tokens
public fun do_withdraw_commitment<Outcome: store, AssetType, IW: copy + drop>(
    executable: &mut Executable<Outcome>,
    proposal: &mut CommitmentProposal<AssetType>,
    witness: IW,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<AssetType> {
    // Get spec and validate type
    let specs = executable::intent(executable).action_specs();
    let spec = specs.borrow(executable::action_idx(executable));
    action_validation::assert_action_type<action_types::WithdrawCommitment>(spec);

    // Deserialize
    let action_data = intents::action_spec_data(spec);
    let mut reader = bcs::new(*action_data);

    let commitment_proposal_id = bcs::peel_address(&mut reader).to_id();

    bcs_validation::validate_all_bytes_consumed(reader);

    // Verify proposal ID
    assert!(object::id(proposal) == commitment_proposal_id, 0);

    // Withdraw
    let unlocked = commitment_proposal::withdraw_locked_commitment(
        proposal,
        clock,
        ctx
    );

    executable::increment_action_idx(executable);

    unlocked
}

// === Cleanup Functions ===

public fun delete_create_commitment_proposal<AssetType>(
    expired: &mut account_protocol::intents::Expired
) {
    let spec = account_protocol::intents::remove_action_spec(expired);
    let _ = spec;
}

public fun delete_execute_commitment(expired: &mut account_protocol::intents::Expired) {
    let spec = account_protocol::intents::remove_action_spec(expired);
    let _ = spec;
}

public fun delete_cancel_commitment(expired: &mut account_protocol::intents::Expired) {
    let spec = account_protocol::intents::remove_action_spec(expired);
    let _ = spec;
}

public fun delete_update_commitment_recipient(expired: &mut account_protocol::intents::Expired) {
    let spec = account_protocol::intents::remove_action_spec(expired);
    let _ = spec;
}

public fun delete_withdraw_commitment(expired: &mut account_protocol::intents::Expired) {
    let spec = account_protocol::intents::remove_action_spec(expired);
    let _ = spec;
}
