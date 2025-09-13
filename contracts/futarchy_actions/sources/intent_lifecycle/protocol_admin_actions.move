/// Protocol admin actions for managing the futarchy protocol through its own DAO (dogfooding).
/// This module allows the protocol's owner DAO and its security council to control:
/// - Factory admin functions (FactoryOwnerCap)
/// - Fee management (FeeAdminCap) 
/// - Validator functions (ValidatorAdminCap)
module futarchy_actions::protocol_admin_actions;

// === Imports ===
use std::{
    string::{String as UTF8String, String},
    type_name::{Self, TypeName},
};
use sui::{
    clock::Clock,
    coin::{Self, Coin},
    event,
    object::{Self, ID},
    sui::SUI,
    vec_set::VecSet,
};
use account_protocol::{
    account::{Self, Account},
    executable::{Self, Executable},
    version_witness::VersionWitness,
};
use futarchy_core::futarchy_config::{Self, FutarchyConfig};
use futarchy_lifecycle::{
    factory::{Self, Factory, FactoryOwnerCap, ValidatorAdminCap},
};
use futarchy_markets::{
    fee::{Self, FeeManager, FeeAdminCap},
};
use futarchy_dao::futarchy_dao;

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
const EInvalidFeeAmount: u64 = 3;

// === Action Structs ===

// Factory Admin Actions

/// Pause or unpause the factory
public struct SetFactoryPausedAction has store {
    paused: bool,
}

/// Add a stable coin type to the factory whitelist
public struct AddStableTypeAction has store {
    stable_type: TypeName,
}

/// Remove a stable coin type from the factory whitelist
public struct RemoveStableTypeAction has store {
    stable_type: TypeName,
}

// Fee Admin Actions

/// Update the DAO creation fee
public struct UpdateDaoCreationFeeAction has store {
    new_fee: u64,
}

/// Update the proposal creation fee per outcome
public struct UpdateProposalFeeAction has store {
    new_fee_per_outcome: u64,
}

/// Update the monthly DAO fee
public struct UpdateMonthlyDaoFeeAction has store {
    new_fee: u64,
}

/// Update verification fee for a specific level
public struct UpdateVerificationFeeAction has store {
    level: u8,
    new_fee: u64,
}

/// Add a new verification level with fee
public struct AddVerificationLevelAction has store {
    level: u8,
    fee: u64,
}

/// Remove a verification level
public struct RemoveVerificationLevelAction has store {
    level: u8,
}

/// Request verification for a DAO
public struct RequestVerificationAction has store {
    dao_id: ID,
    level: u8,
    attestation_url: String,
}

/// Approve DAO verification request
public struct ApproveVerificationAction has store {
    dao_id: ID,
    verification_id: ID,
    level: u8,
    attestation_url: String,
}

/// Reject DAO verification request
public struct RejectVerificationAction has store {
    dao_id: ID,
    verification_id: ID,
    reason: String,
}

/// Update the recovery fee
public struct UpdateRecoveryFeeAction has store {
    new_fee: u64,
}

/// Withdraw accumulated fees to treasury
public struct WithdrawFeesToTreasuryAction has store {
    amount: u64,
}

/// Apply discount to a DAO's monthly fees
public struct ApplyDaoFeeDiscountAction has store {
    dao_id: ID,
    discount_amount: u64,
}

// Coin-specific fee actions

/// Add a new coin type with fee configuration
public struct AddCoinFeeConfigAction has store {
    coin_type: TypeName,
    decimals: u8,
    dao_monthly_fee: u64,
    dao_creation_fee: u64,
    proposal_fee_per_outcome: u64,
    recovery_fee: u64,
}

/// Update monthly fee for a specific coin type (with 6-month delay)
public struct UpdateCoinMonthlyFeeAction has store {
    coin_type: TypeName,
    new_fee: u64,
}

/// Update creation fee for a specific coin type (with 6-month delay)
public struct UpdateCoinCreationFeeAction has store {
    coin_type: TypeName,
    new_fee: u64,
}

/// Update proposal fee for a specific coin type (with 6-month delay)
public struct UpdateCoinProposalFeeAction has store {
    coin_type: TypeName,
    new_fee_per_outcome: u64,
}

/// Update recovery fee for a specific coin type (with 6-month delay)
public struct UpdateCoinRecoveryFeeAction has store {
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

public fun new_update_monthly_dao_fee(new_fee: u64): UpdateMonthlyDaoFeeAction {
    UpdateMonthlyDaoFeeAction { new_fee }
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

public fun new_request_verification(dao_id: ID, level: u8, attestation_url: String): RequestVerificationAction {
    RequestVerificationAction { dao_id, level, attestation_url }
}

public fun new_approve_verification(dao_id: ID, verification_id: ID, level: u8, attestation_url: String): ApproveVerificationAction {
    ApproveVerificationAction { dao_id, verification_id, level, attestation_url }
}

public fun new_reject_verification(dao_id: ID, verification_id: ID, reason: String): RejectVerificationAction {
    RejectVerificationAction { dao_id, verification_id, reason }
}

public fun new_update_recovery_fee(new_fee: u64): UpdateRecoveryFeeAction {
    UpdateRecoveryFeeAction { new_fee }
}

public fun new_apply_dao_fee_discount(dao_id: ID, discount_amount: u64): ApplyDaoFeeDiscountAction {
    ApplyDaoFeeDiscountAction { dao_id, discount_amount }
}

public fun new_withdraw_fees_to_treasury(amount: u64): WithdrawFeesToTreasuryAction {
    WithdrawFeesToTreasuryAction { amount }
}

// Coin-specific fee constructors

public fun new_add_coin_fee_config(
    coin_type: TypeName,
    decimals: u8,
    dao_monthly_fee: u64,
    dao_creation_fee: u64,
    proposal_fee_per_outcome: u64,
    recovery_fee: u64,
): AddCoinFeeConfigAction {
    AddCoinFeeConfigAction {
        coin_type,
        decimals,
        dao_monthly_fee,
        dao_creation_fee,
        proposal_fee_per_outcome,
        recovery_fee,
    }
}

public fun new_update_coin_monthly_fee(
    coin_type: TypeName,
    new_fee: u64,
): UpdateCoinMonthlyFeeAction {
    UpdateCoinMonthlyFeeAction { coin_type, new_fee }
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
    let action = executable::next_action<Outcome, SetFactoryPausedAction, IW>(executable, witness);
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
    let action = executable::next_action<Outcome, AddStableTypeAction, IW>(executable, witness);
    let _ = action; // Just consume it
    
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
    let action = executable::next_action<Outcome, RemoveStableTypeAction, IW>(executable, witness);
    let _ = action; // Just consume it
    
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
    let action = executable::next_action<Outcome, UpdateDaoCreationFeeAction, IW>(executable, witness);
    
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
    let action = executable::next_action<Outcome, UpdateProposalFeeAction, IW>(executable, witness);
    
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

/// Execute update monthly DAO fee action
public fun do_update_monthly_dao_fee<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    version: VersionWitness,
    witness: IW,
    fee_manager: &mut FeeManager,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let action = executable::next_action<Outcome, UpdateMonthlyDaoFeeAction, IW>(executable, witness);
    
    let cap = account::borrow_managed_asset<FutarchyConfig, String, FeeAdminCap>(
        account,
        b"protocol:fee_admin_cap".to_string(),
        version
    );
    
    // Update the monthly fee (it will have a built-in delay)
    fee::update_dao_monthly_fee(
        fee_manager,
        cap,
        action.new_fee,
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
    let action = executable::next_action<Outcome, UpdateVerificationFeeAction, IW>(executable, witness);
    
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
    let action = executable::next_action<Outcome, AddVerificationLevelAction, IW>(executable, witness);
    
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
    let action = executable::next_action<Outcome, RemoveVerificationLevelAction, IW>(executable, witness);
    
    let cap = account::borrow_managed_asset<FutarchyConfig, String, FeeAdminCap>(
        account,
        b"protocol:fee_admin_cap".to_string(),
        version
    );
    
    fee::remove_verification_level(fee_manager, cap, action.level, clock, ctx);
}

/// Execute request verification action
/// DAOs can request verification by paying the required fee
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
    let action = executable::next_action<Outcome, RequestVerificationAction, IW>(executable, witness);

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
        dao_id: action.dao_id,
        verification_id,
        requester: ctx.sender(),
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
    let action = executable::next_action<Outcome, ApproveVerificationAction, IW>(executable, witness);

    // Verify we have the validator capability
    let cap = account::borrow_managed_asset<FutarchyConfig, String, ValidatorAdminCap>(
        account,
        b"protocol:validator_admin_cap".to_string(),
        version
    );

    // Verify the DAO ID matches
    assert!(object::id(target_dao) == action.dao_id, EInvalidAdminCap);

    // Get the DAO's config and update verification level and attestation URL
    let dao_config = account::config_mut(target_dao, version, futarchy_dao::witness());
    futarchy_config::set_verification_level(dao_config, action.level);
    futarchy_config::set_attestation_url(dao_config, action.attestation_url);

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
    let action = executable::next_action<Outcome, RejectVerificationAction, IW>(executable, witness);

    // Verify we have the validator capability
    let cap = account::borrow_managed_asset<FutarchyConfig, String, ValidatorAdminCap>(
        account,
        b"protocol:validator_admin_cap".to_string(),
        version
    );

    // Verify the DAO ID matches
    assert!(object::id(target_dao) == action.dao_id, EInvalidAdminCap);

    // Get the DAO's config and ensure verification level stays at 0
    let dao_config = account::config_mut(target_dao, version, futarchy_dao::witness());
    futarchy_config::set_verification_level(dao_config, 0);

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
    let action = executable::next_action<Outcome, UpdateRecoveryFeeAction, IW>(executable, witness);
    
    let cap = account::borrow_managed_asset<FutarchyConfig, String, FeeAdminCap>(
        account,
        b"protocol:fee_admin_cap".to_string(),
        version
    );
    
    fee::update_recovery_fee(fee_manager, cap, action.new_fee, clock, ctx);
}

/// Execute apply DAO fee discount action
public fun do_apply_dao_fee_discount<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    version: VersionWitness,
    witness: IW,
    fee_manager: &mut FeeManager,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let action = executable::next_action<Outcome, ApplyDaoFeeDiscountAction, IW>(executable, witness);
    
    let cap = account::borrow_managed_asset<FutarchyConfig, String, FeeAdminCap>(
        account,
        b"protocol:fee_admin_cap".to_string(),
        version
    );
    
    // Note: There's no direct apply_dao_fee_discount function.
    // Discounts are applied at collection time via collect_dao_platform_fee_with_discount
    // This action would need to store the discount for later use, which isn't implemented
    let _ = fee_manager;
    let _ = cap;
    let _ = action;
    let _ = clock;
    let _ = ctx;
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
    let action = executable::next_action<Outcome, WithdrawFeesToTreasuryAction, IW>(executable, witness);
    let _ = action; // Just consume it
    
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
public fun do_add_coin_fee_config<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    version: VersionWitness,
    witness: IW,
    fee_manager: &mut FeeManager,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let action = executable::next_action<Outcome, AddCoinFeeConfigAction, IW>(executable, witness);
    
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
        action.dao_monthly_fee,
        action.dao_creation_fee,
        action.proposal_fee_per_outcome,
        action.recovery_fee,
        clock,
        ctx
    );
}

/// Execute action to update coin monthly fee
public fun do_update_coin_monthly_fee<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    version: VersionWitness,
    witness: IW,
    fee_manager: &mut FeeManager,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let action = executable::next_action<Outcome, UpdateCoinMonthlyFeeAction, IW>(executable, witness);
    
    let cap = account::borrow_managed_asset<FutarchyConfig, String, FeeAdminCap>(
        account,
        b"protocol:fee_admin_cap".to_string(),
        version
    );
    
    fee::update_coin_monthly_fee(
        fee_manager,
        cap,
        action.coin_type,
        action.new_fee,
        clock,
        ctx
    );
}

/// Execute action to update coin creation fee
public fun do_update_coin_creation_fee<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    version: VersionWitness,
    witness: IW,
    fee_manager: &mut FeeManager,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let action = executable::next_action<Outcome, UpdateCoinCreationFeeAction, IW>(executable, witness);
    
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
public fun do_update_coin_proposal_fee<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    version: VersionWitness,
    witness: IW,
    fee_manager: &mut FeeManager,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let action = executable::next_action<Outcome, UpdateCoinProposalFeeAction, IW>(executable, witness);
    
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
public fun do_update_coin_recovery_fee<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    version: VersionWitness,
    witness: IW,
    fee_manager: &mut FeeManager,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let action = executable::next_action<Outcome, UpdateCoinRecoveryFeeAction, IW>(executable, witness);
    
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
public struct ApplyPendingCoinFeesAction has store {
    coin_type: TypeName,
}

/// Execute action to apply pending coin fees after delay
public fun do_apply_pending_coin_fees<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    version: VersionWitness,
    witness: IW,
    fee_manager: &mut FeeManager,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let action = executable::next_action<Outcome, ApplyPendingCoinFeesAction, IW>(executable, witness);
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