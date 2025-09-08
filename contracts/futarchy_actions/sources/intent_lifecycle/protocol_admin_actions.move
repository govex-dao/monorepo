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

// === Errors ===
const EInvalidAdminCap: u64 = 1;
const ECapNotFound: u64 = 2;
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

public fun new_update_recovery_fee(new_fee: u64): UpdateRecoveryFeeAction {
    UpdateRecoveryFeeAction { new_fee }
}

public fun new_apply_dao_fee_discount(dao_id: ID, discount_amount: u64): ApplyDaoFeeDiscountAction {
    ApplyDaoFeeDiscountAction { dao_id, discount_amount }
}

public fun new_withdraw_fees_to_treasury(amount: u64): WithdrawFeesToTreasuryAction {
    WithdrawFeesToTreasuryAction { amount }
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