// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

/// Protocol admin actions for managing the futarchy protocol through its own DAO (dogfooding).
/// This module allows the protocol's owner DAO and its security council to control:
/// - Factory admin functions (FactoryOwnerCap)
/// - Fee management (FeeAdminCap) 
/// - Validator functions (ValidatorAdminCap)
module futarchy_governance_actions::protocol_admin_actions;

// === Imports ===
use std::{
    string::{String as UTF8String, String},
    type_name::{Self, TypeName},
};
use sui::{
    bcs::{Self, BCS},
    clock::Clock,
    coin::{Self, Coin},
    event,
    object::{Self, ID},
    sui::SUI,
    vec_set::VecSet,
};
use account_protocol::{
    account::{Self, Account},
    bcs_validation,
    executable::{Self, Executable},
    intents,
    version_witness::VersionWitness,
};
use futarchy_core::futarchy_config::{Self, FutarchyConfig};
use futarchy_factory::{
    factory::{Self, Factory, FactoryOwnerCap, ValidatorAdminCap},
    launchpad::{Self, Raise},
};
use futarchy_markets_core::{
    fee::{Self, FeeManager, FeeAdminCap},
};
// futarchy_dao dependency removed - use ConfigWitness instead
use futarchy_types::action_type_markers as action_types;
use futarchy_core::action_validation;

// === Errors ===
const EInvalidAdminCap: u64 = 1;
const ECapNotFound: u64 = 2;

// === Events ===
public struct VerificationRequested has copy, drop {
    dao_id: ID,
    verification_id: ID,
    requester: address,
    attestation_url: String,
    level: u8,
    timestamp: u64,
}

public struct VerificationApproved has copy, drop {
    dao_id: ID,
    verification_id: ID,
    level: u8,
    attestation_url: String,
    validator: address,
    timestamp: u64,
}

public struct VerificationRejected has copy, drop {
    dao_id: ID,
    verification_id: ID,
    reason: String,
    validator: address,
    timestamp: u64,
}

public struct LaunchpadTrustScoreSet has copy, drop {
    raise_id: ID,
    trust_score: u64,
    review_text: String,
}

const EInvalidFeeAmount: u64 = 3;

// === Action Structs ===

// Factory Admin Actions

/// Pause or unpause the factory
public struct SetFactoryPausedAction has store, drop {
    paused: bool,
}

/// Add a stable coin type to the factory whitelist
public struct AddStableTypeAction has store, drop {
    stable_type: TypeName,
}

/// Remove a stable coin type from the factory whitelist
public struct RemoveStableTypeAction has store, drop {
    stable_type: TypeName,
}

// Fee Admin Actions

/// Update the DAO creation fee
public struct UpdateDaoCreationFeeAction has store, drop {
    new_fee: u64,
}

/// Update the proposal creation fee per outcome
public struct UpdateProposalFeeAction has store, drop {
    new_fee_per_outcome: u64,
}

/// Update verification fee for a specific level
public struct UpdateVerificationFeeAction has store, drop {
    level: u8,
    new_fee: u64,
}

/// Add a new verification level with fee
public struct AddVerificationLevelAction has store, drop {
    level: u8,
    fee: u64,
}

/// Remove a verification level
public struct RemoveVerificationLevelAction has store, drop {
    level: u8,
}

/// Request verification for the DAO itself (only the DAO can request its own verification)
public struct RequestVerificationAction has store, drop {
    level: u8,
    attestation_url: String,
}

/// Approve DAO verification request
public struct ApproveVerificationAction has store, drop {
    dao_id: ID,
    verification_id: ID,
    level: u8,
    attestation_url: String,
}

/// Reject DAO verification request
public struct RejectVerificationAction has store, drop {
    dao_id: ID,
    verification_id: ID,
    reason: String,
}

/// Set DAO quality score (admin-only, uses ValidatorAdminCap)
public struct SetDaoScoreAction has store, drop {
    dao_id: ID,
    score: u64,
    reason: String,
}

/// Set launchpad raise trust score and review (admin-only, uses ValidatorAdminCap)
public struct SetLaunchpadTrustScoreAction has store, drop {
    raise_id: ID,
    trust_score: u64,
    review_text: String,
}

/// Update the recovery fee
public struct UpdateRecoveryFeeAction has store, drop {
    new_fee: u64,
}

/// Withdraw accumulated fees to treasury
public struct WithdrawFeesToTreasuryAction has store, drop {
    amount: u64,
}

// Coin-specific fee actions

/// Add a new coin type with fee configuration
public struct AddCoinFeeConfigAction has store, drop {
    coin_type: TypeName,
    decimals: u8,
    dao_creation_fee: u64,
    proposal_fee_per_outcome: u64,
    recovery_fee: u64,
    multisig_creation_fee: u64,
}

/// Update creation fee for a specific coin type (with 6-month delay)
public struct UpdateCoinCreationFeeAction has store, drop {
    coin_type: TypeName,
    new_fee: u64,
}

/// Update proposal fee for a specific coin type (with 6-month delay)
public struct UpdateCoinProposalFeeAction has store, drop {
    coin_type: TypeName,
    new_fee_per_outcome: u64,
}

/// Update recovery fee for a specific coin type (with 6-month delay)
public struct UpdateCoinRecoveryFeeAction has store, drop {
    coin_type: TypeName,
    new_fee: u64,
}

// === Public Functions ===

// Factory Actions

public fun new_set_factory_paused(paused: bool): SetFactoryPausedAction {
    SetFactoryPausedAction { paused }
}

public fun new_add_stable_type(stable_type: TypeName): AddStableTypeAction {
    AddStableTypeAction { stable_type }
}

public fun new_remove_stable_type(stable_type: TypeName): RemoveStableTypeAction {
    RemoveStableTypeAction { stable_type }
}

// Fee Actions

public fun new_update_dao_creation_fee(new_fee: u64): UpdateDaoCreationFeeAction {
    UpdateDaoCreationFeeAction { new_fee }
}

public fun new_update_proposal_fee(new_fee_per_outcome: u64): UpdateProposalFeeAction {
    UpdateProposalFeeAction { new_fee_per_outcome }
}

public fun new_update_verification_fee(level: u8, new_fee: u64): UpdateVerificationFeeAction {
    UpdateVerificationFeeAction { level, new_fee }
}

public fun new_add_verification_level(level: u8, fee: u64): AddVerificationLevelAction {
    AddVerificationLevelAction { level, fee }
}

public fun new_remove_verification_level(level: u8): RemoveVerificationLevelAction {
    RemoveVerificationLevelAction { level }
}

public fun new_request_verification(level: u8, attestation_url: String): RequestVerificationAction {
    RequestVerificationAction { level, attestation_url }
}

public fun new_approve_verification(dao_id: ID, verification_id: ID, level: u8, attestation_url: String): ApproveVerificationAction {
    ApproveVerificationAction { dao_id, verification_id, level, attestation_url }
}

public fun new_reject_verification(dao_id: ID, verification_id: ID, reason: String): RejectVerificationAction {
    RejectVerificationAction { dao_id, verification_id, reason }
}

public fun new_set_dao_score(dao_id: ID, score: u64, reason: String): SetDaoScoreAction {
    SetDaoScoreAction { dao_id, score, reason }
}

public fun new_set_launchpad_trust_score(raise_id: ID, trust_score: u64, review_text: String): SetLaunchpadTrustScoreAction {
    SetLaunchpadTrustScoreAction { raise_id, trust_score, review_text }
}

public fun new_update_recovery_fee(new_fee: u64): UpdateRecoveryFeeAction {
    UpdateRecoveryFeeAction { new_fee }
}

public fun new_withdraw_fees_to_treasury(amount: u64): WithdrawFeesToTreasuryAction {
    WithdrawFeesToTreasuryAction { amount }
}

// Coin-specific fee constructors

public fun new_add_coin_fee_config(
    coin_type: TypeName,
    decimals: u8,
    dao_creation_fee: u64,
    proposal_fee_per_outcome: u64,
    recovery_fee: u64,
    multisig_creation_fee: u64,
): AddCoinFeeConfigAction {
    AddCoinFeeConfigAction {
        coin_type,
        decimals,
        dao_creation_fee,
        proposal_fee_per_outcome,
        recovery_fee,
        multisig_creation_fee,
    }
}

public fun new_update_coin_creation_fee(
    coin_type: TypeName,
    new_fee: u64,
): UpdateCoinCreationFeeAction {
    UpdateCoinCreationFeeAction { coin_type, new_fee }
}

public fun new_update_coin_proposal_fee(
    coin_type: TypeName,
    new_fee_per_outcome: u64,
): UpdateCoinProposalFeeAction {
    UpdateCoinProposalFeeAction { coin_type, new_fee_per_outcome }
}

public fun new_update_coin_recovery_fee(
    coin_type: TypeName,
    new_fee: u64,
): UpdateCoinRecoveryFeeAction {
    UpdateCoinRecoveryFeeAction { coin_type, new_fee }
}

public fun new_apply_pending_coin_fees(
    coin_type: TypeName,
): ApplyPendingCoinFeesAction {
    ApplyPendingCoinFeesAction { coin_type }
}

// === Execution Functions ===

/// Execute factory pause/unpause action
public fun do_set_factory_paused<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    version: VersionWitness,
    witness: IW,
    factory: &mut Factory,
    ctx: &mut TxContext,
) {
    // Get spec and validate type BEFORE deserialization
    let specs = executable::intent(executable).action_specs();
    let spec = specs.borrow(executable::action_idx(executable));
    action_validation::assert_action_type<action_types::SetFactoryPaused>(spec);

    // Deserialize the action data
    let action_data = intents::action_spec_data(spec);
    let mut bcs = bcs::new(*action_data);
    let paused = bcs::peel_bool(&mut bcs);
    let action = SetFactoryPausedAction { paused };

    // Increment action index
    executable::increment_action_idx(executable);

    let _ = ctx;
    
    let cap = account::borrow_managed_asset<FutarchyConfig, String, FactoryOwnerCap>(
        account,
        b"protocol:factory_owner_cap".to_string(),
        version
    );
    
    // Toggle pause state if action says to pause and factory is unpaused, or vice versa
    if ((action.paused && !factory::is_paused(factory)) || 
        (!action.paused && factory::is_paused(factory))) {
        factory::toggle_pause(factory, cap);
    }
}

/// Execute add stable type action
public fun do_add_stable_type<Outcome: store, IW: drop, StableType>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    version: VersionWitness,
    witness: IW,
    factory: &mut Factory,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Get spec and validate type BEFORE deserialization
    let specs = executable::intent(executable).action_specs();
    let spec = specs.borrow(executable::action_idx(executable));
    action_validation::assert_action_type<action_types::AddStableType>(spec);

    // Create action with generic type
    let stable_type = type_name::get<StableType>();
    let action = AddStableTypeAction { stable_type };

    // Increment action index
    executable::increment_action_idx(executable);
    
    let cap = account::borrow_managed_asset<FutarchyConfig, String, FactoryOwnerCap>(
        account,
        b"protocol:factory_owner_cap".to_string(),
        version
    );
    
    factory::add_allowed_stable_type<StableType>(factory, cap, clock, ctx);
}

/// Execute remove stable type action
public fun do_remove_stable_type<Outcome: store, IW: drop, StableType>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    version: VersionWitness,
    witness: IW,
    factory: &mut Factory,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Get spec and validate type BEFORE deserialization
    let specs = executable::intent(executable).action_specs();
    let spec = specs.borrow(executable::action_idx(executable));
    action_validation::assert_action_type<action_types::RemoveStableType>(spec);

    // Create action with generic type
    let stable_type = type_name::get<StableType>();
    let action = RemoveStableTypeAction { stable_type };

    // Increment action index
    executable::increment_action_idx(executable);
    
    let cap = account::borrow_managed_asset<FutarchyConfig, String, FactoryOwnerCap>(
        account,
        b"protocol:factory_owner_cap".to_string(),
        version
    );
    
    factory::remove_allowed_stable_type<StableType>(factory, cap, clock, ctx);
}

/// Execute update DAO creation fee action
public fun do_update_dao_creation_fee<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    version: VersionWitness,
    witness: IW,
    fee_manager: &mut FeeManager,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Get spec and validate type BEFORE deserialization
    let specs = executable::intent(executable).action_specs();
    let spec = specs.borrow(executable::action_idx(executable));
    action_validation::assert_action_type<action_types::UpdateDaoCreationFee>(spec);

    // Deserialize the action data
    let action_data = intents::action_spec_data(spec);
    let mut bcs = bcs::new(*action_data);
    let new_fee = bcs::peel_u64(&mut bcs);
    let action = UpdateDaoCreationFeeAction { new_fee };

    // Increment action index
    executable::increment_action_idx(executable);
    
    let cap = account::borrow_managed_asset<FutarchyConfig, String, FeeAdminCap>(
        account,
        b"protocol:fee_admin_cap".to_string(),
        version
    );
    
    fee::update_dao_creation_fee(fee_manager, cap, action.new_fee, clock, ctx);
}

/// Execute update proposal fee action
public fun do_update_proposal_fee<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    version: VersionWitness,
    witness: IW,
    fee_manager: &mut FeeManager,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Get spec and validate type BEFORE deserialization
    let specs = executable::intent(executable).action_specs();
    let spec = specs.borrow(executable::action_idx(executable));
    action_validation::assert_action_type<action_types::UpdateProposalFee>(spec);

    // Deserialize the action data
    let action_data = intents::action_spec_data(spec);
    let mut bcs = bcs::new(*action_data);
    let new_fee_per_outcome = bcs::peel_u64(&mut bcs);
    let action = UpdateProposalFeeAction { new_fee_per_outcome };

    // Increment action index
    executable::increment_action_idx(executable);

    let cap = account::borrow_managed_asset<FutarchyConfig, String, FeeAdminCap>(
        account,
        b"protocol:fee_admin_cap".to_string(),
        version
    );

    fee::update_proposal_creation_fee(
        fee_manager,
        cap,
        action.new_fee_per_outcome,
        clock,
        ctx
    );
}

/// Execute update verification fee action
public fun do_update_verification_fee<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    version: VersionWitness,
    witness: IW,
    fee_manager: &mut FeeManager,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Get spec and validate type BEFORE deserialization
    let specs = executable::intent(executable).action_specs();
    let spec = specs.borrow(executable::action_idx(executable));
    action_validation::assert_action_type<action_types::UpdateVerificationFee>(spec);

    // Deserialize the action data
    let action_data = intents::action_spec_data(spec);
    let mut bcs = bcs::new(*action_data);
    let level = bcs::peel_u8(&mut bcs);
    let new_fee = bcs::peel_u64(&mut bcs);
    let action = UpdateVerificationFeeAction { level, new_fee };

    // Increment action index
    executable::increment_action_idx(executable);
    
    let cap = account::borrow_managed_asset<FutarchyConfig, String, FeeAdminCap>(
        account,
        b"protocol:fee_admin_cap".to_string(),
        version
    );
    
    fee::update_verification_fee(
        fee_manager,
        cap,
        action.level,
        action.new_fee,
        clock,
        ctx
    );
}

/// Execute add verification level action
public fun do_add_verification_level<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    version: VersionWitness,
    witness: IW,
    fee_manager: &mut FeeManager,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Get spec and validate type BEFORE deserialization
    let specs = executable::intent(executable).action_specs();
    let spec = specs.borrow(executable::action_idx(executable));
    action_validation::assert_action_type<action_types::AddVerificationLevel>(spec);

    // Deserialize the action data
    let action_data = intents::action_spec_data(spec);
    let mut bcs = bcs::new(*action_data);
    let level = bcs::peel_u8(&mut bcs);
    let fee = bcs::peel_u64(&mut bcs);
    let action = AddVerificationLevelAction { level, fee };

    // Increment action index
    executable::increment_action_idx(executable);
    
    let cap = account::borrow_managed_asset<FutarchyConfig, String, FeeAdminCap>(
        account,
        b"protocol:fee_admin_cap".to_string(),
        version
    );
    
    fee::add_verification_level(fee_manager, cap, action.level, action.fee, clock, ctx);
}

/// Execute remove verification level action
public fun do_remove_verification_level<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    version: VersionWitness,
    witness: IW,
    fee_manager: &mut FeeManager,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Get spec and validate type BEFORE deserialization
    let specs = executable::intent(executable).action_specs();
    let spec = specs.borrow(executable::action_idx(executable));
    action_validation::assert_action_type<action_types::RemoveVerificationLevel>(spec);

    // Deserialize the action data
    let action_data = intents::action_spec_data(spec);
    let mut bcs = bcs::new(*action_data);
    let level = bcs::peel_u8(&mut bcs);
    let action = RemoveVerificationLevelAction { level };

    // Increment action index
    executable::increment_action_idx(executable);
    
    let cap = account::borrow_managed_asset<FutarchyConfig, String, FeeAdminCap>(
        account,
        b"protocol:fee_admin_cap".to_string(),
        version
    );
    
    fee::remove_verification_level(fee_manager, cap, action.level, clock, ctx);
}

/// Execute request verification action
/// DAOs can request verification for themselves by paying the required fee
/// Only the DAO itself can request its own verification (executed through governance)
/// Multiple verification requests can be pending with unique IDs
public fun do_request_verification<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    version: VersionWitness,
    witness: IW,
    fee_manager: &mut FeeManager,
    payment: Coin<SUI>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Get spec and validate type BEFORE deserialization
    let specs = executable::intent(executable).action_specs();
    let spec = specs.borrow(executable::action_idx(executable));
    action_validation::assert_action_type<action_types::RequestVerification>(spec);

    // Deserialize the action data
    let action_data = intents::action_spec_data(spec);
    let mut bcs = bcs::new(*action_data);
    let level = bcs::peel_u8(&mut bcs);
    let attestation_url = bcs::peel_vec_u8(&mut bcs).to_string();
    let action = RequestVerificationAction { level, attestation_url };

    // Increment action index
    executable::increment_action_idx(executable);

    // Get the DAO's own ID - only the DAO can request verification for itself
    let dao_id = object::id(account);

    // Generate unique verification ID
    let verification_uid = object::new(ctx);
    let verification_id = object::uid_to_inner(&verification_uid);
    object::delete(verification_uid);

    // Deposit the verification payment to fee manager
    fee::deposit_verification_payment(
        fee_manager,
        payment,
        action.level,
        clock,
        ctx
    );

    // Emit event for the verification request
    event::emit(VerificationRequested {
        dao_id,  // Using the DAO's own ID
        verification_id,
        requester: dao_id.id_to_address(),  // The DAO is the requester
        attestation_url: action.attestation_url,
        level: action.level,
        timestamp: clock.timestamp_ms(),
    });

    // The actual verification will be done by approve_verification or reject_verification
}

/// Execute approve verification action
/// Validators can approve a specific verification request by its ID
public fun do_approve_verification<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    version: VersionWitness,
    witness: IW,
    target_dao: &mut Account<FutarchyConfig>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Get spec and validate type BEFORE deserialization
    let specs = executable::intent(executable).action_specs();
    let spec = specs.borrow(executable::action_idx(executable));
    action_validation::assert_action_type<action_types::ApproveVerification>(spec);

    // Deserialize the action data
    let action_data = intents::action_spec_data(spec);
    let mut bcs = bcs::new(*action_data);
    let dao_id = bcs::peel_address(&mut bcs).to_id();
    let verification_id = bcs::peel_address(&mut bcs).to_id();
    let level = bcs::peel_u8(&mut bcs);
    let attestation_url = bcs::peel_vec_u8(&mut bcs).to_string();
    let action = ApproveVerificationAction { dao_id, verification_id, level, attestation_url };

    // Increment action index
    executable::increment_action_idx(executable);

    // Verify we have the validator capability
    let cap = account::borrow_managed_asset<FutarchyConfig, String, ValidatorAdminCap>(
        account,
        b"protocol:validator_admin_cap".to_string(),
        version
    );

    // Verify the DAO ID matches
    assert!(object::id(target_dao) == action.dao_id, EInvalidAdminCap);

    // Get the DAO's config and update verification level and attestation URL
    // Get the mutable DaoState from the Account using dynamic fields
    let dao_state = futarchy_config::state_mut_from_account(target_dao);
    // Set verification status
    futarchy_config::set_verification_pending(dao_state, false);
    futarchy_config::set_attestation_url(dao_state, action.attestation_url);

    // Emit event for transparency with verification ID
    event::emit(VerificationApproved {
        dao_id: action.dao_id,
        verification_id: action.verification_id,
        level: action.level,
        attestation_url: action.attestation_url,
        validator: ctx.sender(),
        timestamp: clock.timestamp_ms(),
    });
}

/// Execute reject verification action
/// Validators can reject a specific verification request with a reason
public fun do_reject_verification<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    version: VersionWitness,
    witness: IW,
    target_dao: &mut Account<FutarchyConfig>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Get spec and validate type BEFORE deserialization
    let specs = executable::intent(executable).action_specs();
    let spec = specs.borrow(executable::action_idx(executable));
    action_validation::assert_action_type<action_types::RejectVerification>(spec);

    // Deserialize the action data
    let action_data = intents::action_spec_data(spec);
    let mut bcs = bcs::new(*action_data);
    let dao_id = bcs::peel_address(&mut bcs).to_id();
    let verification_id = bcs::peel_address(&mut bcs).to_id();
    let reason = bcs::peel_vec_u8(&mut bcs).to_string();
    let action = RejectVerificationAction { dao_id, verification_id, reason };

    // Increment action index
    executable::increment_action_idx(executable);

    // Verify we have the validator capability
    let cap = account::borrow_managed_asset<FutarchyConfig, String, ValidatorAdminCap>(
        account,
        b"protocol:validator_admin_cap".to_string(),
        version
    );

    // Verify the DAO ID matches
    assert!(object::id(target_dao) == action.dao_id, EInvalidAdminCap);

    // Get the DAO's config and ensure verification level stays at 0
    // Get the mutable DaoState from the Account using dynamic fields
    let dao_state = futarchy_config::state_mut_from_account(target_dao);
    // Reset verification to unverified state
    futarchy_config::set_verification_pending(dao_state, false);

    // Emit event for transparency with verification ID
    event::emit(VerificationRejected {
        dao_id: action.dao_id,
        verification_id: action.verification_id,
        reason: action.reason,
        validator: ctx.sender(),
        timestamp: clock.timestamp_ms(),
    });
}

/// Execute update recovery fee action
public fun do_update_recovery_fee<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    version: VersionWitness,
    witness: IW,
    fee_manager: &mut FeeManager,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Get spec and validate type BEFORE deserialization
    let specs = executable::intent(executable).action_specs();
    let spec = specs.borrow(executable::action_idx(executable));
    action_validation::assert_action_type<action_types::UpdateRecoveryFee>(spec);

    // Deserialize the action data
    let action_data = intents::action_spec_data(spec);
    let mut bcs = bcs::new(*action_data);
    let new_fee = bcs::peel_u64(&mut bcs);
    let action = UpdateRecoveryFeeAction { new_fee };

    // Increment action index
    executable::increment_action_idx(executable);
    
    let cap = account::borrow_managed_asset<FutarchyConfig, String, FeeAdminCap>(
        account,
        b"protocol:fee_admin_cap".to_string(),
        version
    );
    
    fee::update_recovery_fee(fee_manager, cap, action.new_fee, clock, ctx);
}

/// Execute withdraw fees to treasury action
public fun do_withdraw_fees_to_treasury<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    version: VersionWitness,
    witness: IW,
    fee_manager: &mut FeeManager,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Get spec and validate type BEFORE deserialization
    let specs = executable::intent(executable).action_specs();
    let spec = specs.borrow(executable::action_idx(executable));
    action_validation::assert_action_type<action_types::WithdrawFeesToTreasury>(spec);

    // Deserialize the action data
    let action_data = intents::action_spec_data(spec);
    let mut bcs = bcs::new(*action_data);
    let amount = bcs::peel_u64(&mut bcs);
    let action = WithdrawFeesToTreasuryAction { amount };

    // Increment action index
    executable::increment_action_idx(executable);
    
    let cap = account::borrow_managed_asset<FutarchyConfig, String, FeeAdminCap>(
        account,
        b"protocol:fee_admin_cap".to_string(),
        version
    );
    
    // Withdraw all fees from the fee manager
    fee::withdraw_all_fees(fee_manager, cap, clock, ctx);
    // Note: The withdraw_all_fees function transfers directly to sender
    // In a proper implementation, we would need a function that returns the coin
    // for deposit into the DAO treasury
}

// Coin-specific fee execution functions

/// Execute action to add a coin fee configuration
public fun do_add_coin_fee_config<Outcome: store, IW: drop, StableType>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    version: VersionWitness,
    witness: IW,
    fee_manager: &mut FeeManager,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Get spec and validate type BEFORE deserialization
    let specs = executable::intent(executable).action_specs();
    let spec = specs.borrow(executable::action_idx(executable));
    action_validation::assert_action_type<action_types::AddCoinFeeConfig>(spec);

    // Deserialize the action data
    let action_data = intents::action_spec_data(spec);
    let mut bcs = bcs::new(*action_data);
    let decimals = bcs::peel_u8(&mut bcs);
    let dao_creation_fee = bcs::peel_u64(&mut bcs);
    let proposal_fee_per_outcome = bcs::peel_u64(&mut bcs);
    let recovery_fee = bcs::peel_u64(&mut bcs);
    let multisig_creation_fee = bcs::peel_u64(&mut bcs);
    let action = AddCoinFeeConfigAction {
        coin_type: type_name::get<StableType>(),
        decimals,
        dao_creation_fee,
        proposal_fee_per_outcome,
        recovery_fee,
        multisig_creation_fee,
    };

    // Increment action index
    executable::increment_action_idx(executable);

    let cap = account::borrow_managed_asset<FutarchyConfig, String, FeeAdminCap>(
        account,
        b"protocol:fee_admin_cap".to_string(),
        version
    );

    fee::add_coin_fee_config(
        fee_manager,
        cap,
        action.coin_type,
        action.decimals,
        action.dao_creation_fee,
        action.proposal_fee_per_outcome,
        action.recovery_fee,
        action.multisig_creation_fee,
        clock,
        ctx
    );
}

/// Execute action to update coin creation fee
public fun do_update_coin_creation_fee<Outcome: store, IW: drop, StableType>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    version: VersionWitness,
    witness: IW,
    fee_manager: &mut FeeManager,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Get spec and validate type BEFORE deserialization
    let specs = executable::intent(executable).action_specs();
    let spec = specs.borrow(executable::action_idx(executable));
    action_validation::assert_action_type<action_types::UpdateCoinCreationFee>(spec);

    // Deserialize the action data
    let action_data = intents::action_spec_data(spec);
    let mut bcs = bcs::new(*action_data);
    let new_fee = bcs::peel_u64(&mut bcs);
    let action = UpdateCoinCreationFeeAction { coin_type: type_name::get<StableType>(), new_fee };

    // Increment action index
    executable::increment_action_idx(executable);
    
    let cap = account::borrow_managed_asset<FutarchyConfig, String, FeeAdminCap>(
        account,
        b"protocol:fee_admin_cap".to_string(),
        version
    );
    
    fee::update_coin_creation_fee(
        fee_manager,
        cap,
        action.coin_type,
        action.new_fee,
        clock,
        ctx
    );
}

/// Execute action to update coin proposal fee
public fun do_update_coin_proposal_fee<Outcome: store, IW: drop, StableType>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    version: VersionWitness,
    witness: IW,
    fee_manager: &mut FeeManager,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Get spec and validate type BEFORE deserialization
    let specs = executable::intent(executable).action_specs();
    let spec = specs.borrow(executable::action_idx(executable));
    action_validation::assert_action_type<action_types::UpdateCoinProposalFee>(spec);

    // Deserialize the action data
    let action_data = intents::action_spec_data(spec);
    let mut bcs = bcs::new(*action_data);
    let new_fee_per_outcome = bcs::peel_u64(&mut bcs);
    let action = UpdateCoinProposalFeeAction { coin_type: type_name::get<StableType>(), new_fee_per_outcome };

    // Increment action index
    executable::increment_action_idx(executable);
    
    let cap = account::borrow_managed_asset<FutarchyConfig, String, FeeAdminCap>(
        account,
        b"protocol:fee_admin_cap".to_string(),
        version
    );
    
    fee::update_coin_proposal_fee(
        fee_manager,
        cap,
        action.coin_type,
        action.new_fee_per_outcome,
        clock,
        ctx
    );
}

/// Execute action to update coin recovery fee
public fun do_update_coin_recovery_fee<Outcome: store, IW: drop, StableType>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    version: VersionWitness,
    witness: IW,
    fee_manager: &mut FeeManager,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Get spec and validate type BEFORE deserialization
    let specs = executable::intent(executable).action_specs();
    let spec = specs.borrow(executable::action_idx(executable));
    action_validation::assert_action_type<action_types::UpdateCoinRecoveryFee>(spec);

    // Deserialize the action data
    let action_data = intents::action_spec_data(spec);
    let mut bcs = bcs::new(*action_data);
    let new_fee = bcs::peel_u64(&mut bcs);
    let action = UpdateCoinRecoveryFeeAction { coin_type: type_name::get<StableType>(), new_fee };

    // Increment action index
    executable::increment_action_idx(executable);
    
    let cap = account::borrow_managed_asset<FutarchyConfig, String, FeeAdminCap>(
        account,
        b"protocol:fee_admin_cap".to_string(),
        version
    );
    
    fee::update_coin_recovery_fee(
        fee_manager,
        cap,
        action.coin_type,
        action.new_fee,
        clock,
        ctx
    );
}

/// Action to apply pending coin fee configuration after delay
public struct ApplyPendingCoinFeesAction has store, drop {
    coin_type: TypeName,
}

/// Execute action to apply pending coin fees after delay
public fun do_apply_pending_coin_fees<Outcome: store, IW: drop, StableType>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    version: VersionWitness,
    witness: IW,
    fee_manager: &mut FeeManager,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Get spec and validate type BEFORE deserialization
    let specs = executable::intent(executable).action_specs();
    let spec = specs.borrow(executable::action_idx(executable));
    action_validation::assert_action_type<action_types::ApplyPendingCoinFees>(spec);

    // Deserialize the action data
    let action_data = intents::action_spec_data(spec);
    let mut bcs = bcs::new(*action_data);
    // This action has no parameters
    let action = ApplyPendingCoinFeesAction { coin_type: type_name::get<StableType>() };

    // Increment action index
    executable::increment_action_idx(executable);
    let _ = account;
    let _ = version;
    let _ = ctx;
    
    // No admin cap needed - anyone can apply pending fees after delay
    fee::apply_pending_coin_fees(
        fee_manager,
        action.coin_type,
        clock
    );
}

/// Execute set launchpad trust score action
public fun do_set_launchpad_trust_score<Outcome: store, IW: drop, RaiseToken, StableCoin>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    version: VersionWitness,
    witness: IW,
    raise: &mut Raise<RaiseToken, StableCoin>,
) {
    // Get spec and validate type BEFORE deserialization
    let specs = executable::intent(executable).action_specs();
    let spec = specs.borrow(executable::action_idx(executable));
    action_validation::assert_action_type<action_types::SetLaunchpadTrustScore>(spec);

    // Deserialize the action data
    let action_data = intents::action_spec_data(spec);
    let mut bcs = bcs::new(*action_data);
    let raise_id = bcs::peel_address(&mut bcs).to_id();
    let trust_score = bcs::peel_u64(&mut bcs);
    let review_text = bcs::peel_vec_u8(&mut bcs).to_string();

    // Validate all bytes consumed (security: prevents trailing data attacks)
    bcs_validation::validate_all_bytes_consumed(bcs);

    let action = SetLaunchpadTrustScoreAction { raise_id, trust_score, review_text };

    // Increment action index
    executable::increment_action_idx(executable);

    // Verify we have the validator capability
    let cap = account::borrow_managed_asset<FutarchyConfig, String, ValidatorAdminCap>(
        account,
        b"protocol:validator_admin_cap".to_string(),
        version
    );

    // Verify the raise ID matches
    assert!(object::id(raise) == action.raise_id, EInvalidAdminCap);

    // Set the trust score and review
    launchpad::set_admin_trust_score(
        raise,
        cap,
        action.trust_score,
        action.review_text
    );

    // Emit event for transparency (off-chain indexers)
    event::emit(LaunchpadTrustScoreSet {
        raise_id: action.raise_id,
        trust_score: action.trust_score,
        review_text: action.review_text,
    });
}

// === Helper Functions for Security Council ===

// This function is commented out because it has incorrect assumptions about
// how account::borrow_managed_asset works. The FactoryOwnerCap would need to be
// stored in the account first, but it's actually a separate object.
// /// Allow security council to execute factory operations 
// public fun council_set_factory_paused<Outcome: store>(
//     council: &mut Account<FutarchyConfig>,
//     executable: &mut Executable<Outcome>,
//     factory: &mut Factory,
//     paused: bool,
//     version: VersionWitness,
//     ctx: &mut TxContext,
// ) {
//     // Security council must have been granted access to the cap
//     let cap = account::borrow_managed_asset<FactoryOwnerCap>(
//         council,
//         b"protocol:factory_owner_cap".to_string(),
//         version
//     );
//     
//     // Toggle pause state if needed
//     let current_paused = factory::is_paused(factory);
//     if (current_paused != paused) {
//         factory::toggle_pause(factory, cap);
//     };
// }

// This function is commented out because it has incorrect assumptions about
// how account::borrow_managed_asset works. The FeeAdminCap would need to be
// stored in the account first, but it's actually a separate object.
// /// Allow security council to execute fee operations
// public fun council_withdraw_emergency_fees<Outcome: store>(
//     council: &mut Account<FutarchyConfig>,
//     executable: &mut Executable<Outcome>,
//     fee_manager: &mut FeeManager,
//     amount: u64,
//     version: VersionWitness,
//     clock: &Clock,
//     ctx: &mut TxContext,
// ) {
//     let cap = account::borrow_managed_asset<FeeAdminCap>(
//         council,
//         b"protocol:fee_admin_cap".to_string(),
//         version
//     );
//     
//     // Withdraw all fees (there's no partial withdraw function)
//     // Note: This withdraws ALL fees, not just the specified amount
//     fee::withdraw_all_fees(fee_manager, cap, clock, ctx);
//     // The fees are sent to tx sender, not to the council account
//     // This is a limitation of the current fee module
//     let _ = amount;
//     let _ = council;
//     let _ = version;
// }

// === Garbage Collection ===

/// Delete protocol admin action from expired intent
public fun delete_protocol_admin_action(expired: &mut account_protocol::intents::Expired) {
    let action_spec = account_protocol::intents::remove_action_spec(expired);
    let _ = action_spec;
}