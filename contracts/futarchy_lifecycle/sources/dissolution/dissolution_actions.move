/// Dissolution-related actions for futarchy DAOs
/// This module defines action structs and execution logic for DAO dissolution
module futarchy_lifecycle::dissolution_actions;

// === Imports ===
use std::{string::{Self, String}, vector};
use sui::{
    bcs::{Self, BCS},
    coin::{Self, Coin},
    balance::{Self, Balance},
    object::{Self, ID},
    transfer,
    clock::Clock,
    tx_context::TxContext,
};
use account_protocol::{
    account::{Self, Account},
    executable::{Self, Executable},
    intents::{Self, Expired, ActionSpec},
    version_witness::VersionWitness,
    bcs_validation,
};
use futarchy_core::{
    futarchy_config::{Self, FutarchyConfig},
    action_validation,
    action_types,
};
use futarchy_vault::{
    futarchy_vault,
};
use futarchy_streams::stream_actions;

// === Constants ===

// Operational states (matching futarchy_config)
const DAO_STATE_ACTIVE: u8 = 0;
const DAO_STATE_DISSOLVING: u8 = 1;
const DAO_STATE_PAUSED: u8 = 2;
const DAO_STATE_DISSOLVED: u8 = 3;

// === Errors ===
const EInvalidRatio: u64 = 1;
const EInvalidRecipient: u64 = 2;
const EEmptyAssetList: u64 = 3;
const EInvalidThreshold: u64 = 4;
const EDissolutionNotActive: u64 = 5;
const ENotDissolving: u64 = 6;
const EInvalidAmount: u64 = 7;
const EDivisionByZero: u64 = 8;
const EOverflow: u64 = 9;

// === Action Structs ===

/// Action to initiate DAO dissolution
public struct InitiateDissolutionAction has store, drop, copy {
    reason: String,
    distribution_method: u8, // 0: pro-rata, 1: equal, 2: custom
    burn_unsold_tokens: bool,
    final_operations_deadline: u64,
}

/// Action to batch distribute multiple assets
public struct BatchDistributeAction has store, drop, copy {
    asset_types: vector<String>, // Type names of assets to distribute
}

/// Action to finalize dissolution and destroy the DAO
public struct FinalizeDissolutionAction has store, drop, copy {
    final_recipient: address, // For any remaining dust
    destroy_account: bool,
}

/// Action to cancel dissolution (if allowed)
public struct CancelDissolutionAction has store, drop, copy {
    reason: String,
}

/// Action to calculate pro rata shares for distribution
public struct CalculateProRataSharesAction has store, drop, copy {
    /// Total supply of asset tokens (excluding DAO-owned)
    total_supply: u64,
    /// Whether to exclude DAO treasury tokens
    exclude_dao_tokens: bool,
}

/// Action to cancel all active streams
public struct CancelAllStreamsAction has store, drop, copy {
    /// Whether to return stream balances to treasury
    return_to_treasury: bool,
}

/// Action to withdraw all AMM liquidity
public struct WithdrawAmmLiquidityAction<phantom AssetType, phantom StableType> has store, drop, copy {
    /// Pool ID to withdraw from
    pool_id: ID,
    /// Whether to burn LP tokens after withdrawal
    burn_lp_tokens: bool,
}

/// Action to distribute all treasury assets pro rata
public struct DistributeAssetsAction<phantom CoinType> has store, drop, copy {
    /// Holders who will receive distributions (address -> token amount held)
    holders: vector<address>,
    /// Amount of tokens each holder has
    holder_amounts: vector<u64>,
    /// Total amount to distribute
    total_distribution_amount: u64,
}

// === Execution Functions ===

/// Execute an initiate dissolution action
public fun do_initiate_dissolution<Outcome: store, IW: drop + copy>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    version: VersionWitness,
    intent_witness: IW,
    _ctx: &mut TxContext,
) {
    // Get spec and validate type BEFORE deserialization
    let specs = executable::intent(executable).action_specs();
    let spec = specs.borrow(executable::action_idx(executable));
    action_validation::assert_action_type<action_types::InitiateDissolution>(spec);

    let action_data = intents::action_spec_data(spec);

    // Safe BCS deserialization
    let mut reader = bcs::new(*action_data);
    let reason_bytes = bcs::peel_vec_u8(&mut reader);
    let reason = string::utf8(reason_bytes);
    let distribution_method = bcs::peel_u8(&mut reader);
    let burn_unsold_tokens = bcs::peel_bool(&mut reader);
    let final_operations_deadline = bcs::peel_u64(&mut reader);
    bcs_validation::validate_all_bytes_consumed(reader);

    // Get the DaoState and set dissolution state
    let dao_state = futarchy_config::state_mut_from_account(account);

    // 1. Set operational state to dissolving
    futarchy_config::set_operational_state(dao_state, DAO_STATE_DISSOLVING);

    // 2. Proposals are disabled automatically via operational state

    // 3. Record dissolution parameters in config metadata
    assert!(reason.length() > 0, EInvalidRatio);
    assert!(distribution_method <= 2, EInvalidRatio);
    assert!(final_operations_deadline > 0, EInvalidThreshold);

    let _ = burn_unsold_tokens;
    let _ = version;
    let _ = intent_witness;

    // Execute and increment
    executable::increment_action_idx(executable);
}

/// Execute a distribute asset action

/// Execute a batch distribute action
public fun do_batch_distribute<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    version: VersionWitness,
    intent_witness: IW,
    ctx: &mut TxContext,
) {
    // Get spec and validate type BEFORE deserialization
    let specs = executable::intent(executable).action_specs();
    let spec = specs.borrow(executable::action_idx(executable));
    action_validation::assert_action_type<action_types::DistributeAsset>(spec);

    let action_data = intents::action_spec_data(spec);

    // Safe BCS deserialization
    let mut reader = bcs::new(*action_data);
    let asset_types_count = bcs::peel_vec_length(&mut reader);
    let mut asset_types = vector::empty<String>();
    let mut i = 0;
    while (i < asset_types_count) {
        let asset_type_bytes = bcs::peel_vec_u8(&mut reader);
        asset_types.push_back(string::utf8(asset_type_bytes));
        i = i + 1;
    };
    bcs_validation::validate_all_bytes_consumed(reader);

    // Verify dissolution is active
    let dao_state = futarchy_config::state_mut_from_account(account);
    assert!(
        futarchy_config::operational_state(dao_state) == DAO_STATE_DISSOLVING,
        EDissolutionNotActive
    );

    // Validate that we have asset types to distribute
    assert!(asset_types.length() > 0, EEmptyAssetList);

    let _ = version;
    let _ = ctx;

    // Execute and increment
    executable::increment_action_idx(executable);
}

/// Execute a finalize dissolution action
public fun do_finalize_dissolution<Outcome: store, IW: drop + copy>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    version: VersionWitness,
    intent_witness: IW,
    _ctx: &mut TxContext,
) {
    // Get spec and validate type BEFORE deserialization
    let specs = executable::intent(executable).action_specs();
    let spec = specs.borrow(executable::action_idx(executable));
    action_validation::assert_action_type<action_types::FinalizeDissolution>(spec);

    let action_data = intents::action_spec_data(spec);

    // Safe BCS deserialization
    let mut reader = bcs::new(*action_data);
    let final_recipient = bcs::peel_address(&mut reader);
    let destroy_account = bcs::peel_bool(&mut reader);
    bcs_validation::validate_all_bytes_consumed(reader);

    // Verify dissolution is active
    let dao_state = futarchy_config::state_mut_from_account(account);
    assert!(
        futarchy_config::operational_state(dao_state) == DAO_STATE_DISSOLVING,
        EDissolutionNotActive
    );

    assert!(final_recipient != @0x0, EInvalidRecipient);

    // Set operational state to dissolved
    futarchy_config::set_operational_state(dao_state, DAO_STATE_DISSOLVED);

    if (destroy_account) {
        // Account destruction would need special handling
    };

    // Execute and increment
    executable::increment_action_idx(executable);
}

/// Execute a cancel dissolution action
public fun do_cancel_dissolution<Outcome: store, IW: drop + copy>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    version: VersionWitness,
    intent_witness: IW,
    _ctx: &mut TxContext,
) {
    // Get spec and validate type BEFORE deserialization
    let specs = executable::intent(executable).action_specs();
    let spec = specs.borrow(executable::action_idx(executable));
    action_validation::assert_action_type<action_types::CancelDissolution>(spec);

    let action_data = intents::action_spec_data(spec);

    // Safe BCS deserialization
    let mut reader = bcs::new(*action_data);
    let reason_bytes = bcs::peel_vec_u8(&mut reader);
    let reason = string::utf8(reason_bytes);
    bcs_validation::validate_all_bytes_consumed(reader);

    let dao_state = futarchy_config::state_mut_from_account(account);

    assert!(
        futarchy_config::operational_state(dao_state) == DAO_STATE_DISSOLVING,
        ENotDissolving
    );

    assert!(reason.length() > 0, EInvalidRatio);

    // Set operational state back to active
    futarchy_config::set_operational_state(dao_state, DAO_STATE_ACTIVE);
    // Proposals are re-enabled automatically via operational state

    // Execute and increment
    executable::increment_action_idx(executable);
}

/// Execute calculate pro rata shares action
public fun do_calculate_pro_rata_shares<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    version: VersionWitness,
    intent_witness: IW,
    _ctx: &mut TxContext,
) {
    // Get spec and validate type BEFORE deserialization
    let specs = executable::intent(executable).action_specs();
    let spec = specs.borrow(executable::action_idx(executable));
    // TODO: Add CalculateProRataShares to action_types module or use a different type
    // action_validation::assert_action_type<action_types::CalculateProRataShares>(spec);

    let action_data = intents::action_spec_data(spec);

    // Safe BCS deserialization
    let mut reader = bcs::new(*action_data);
    let total_supply = bcs::peel_u64(&mut reader);
    let exclude_dao_tokens = bcs::peel_bool(&mut reader);
    bcs_validation::validate_all_bytes_consumed(reader);
    
    // Verify dissolution is active
    let dao_state = futarchy_config::state_mut_from_account(account);
    assert!(
        futarchy_config::operational_state(dao_state) == DAO_STATE_DISSOLVING,
        EDissolutionNotActive
    );
    
    // Calculate pro rata distribution
    // In a real implementation, this would:
    // 1. Get total supply of asset tokens
    // 2. If exclude_dao_tokens, subtract DAO-owned tokens from total
    // 3. Calculate each holder's percentage of the adjusted total
    // 4. Store these percentages for use in distribution actions
    
    assert!(total_supply > 0, EDivisionByZero);
    
    // The actual calculation would be done when creating DistributeAssetsAction
    // This action mainly validates and prepares for distribution
    
    let _ = exclude_dao_tokens;
    let _ = version;

    // Execute and increment
    executable::increment_action_idx(executable);
}

/// Execute cancel all streams action
public fun do_cancel_all_streams<Outcome: store, CoinType: drop, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    version: VersionWitness,
    intent_witness: IW,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Get spec and validate type BEFORE deserialization
    let specs = executable::intent(executable).action_specs();
    let spec = specs.borrow(executable::action_idx(executable));
    // CancelAllStreams doesn't exist, using CancelStreamsInBag
    action_validation::assert_action_type<action_types::CancelStreamsInBag>(spec);

    let action_data = intents::action_spec_data(spec);

    // Safe BCS deserialization
    let mut reader = bcs::new(*action_data);
    let return_to_treasury = bcs::peel_bool(&mut reader);
    bcs_validation::validate_all_bytes_consumed(reader);
    
    // Verify dissolution is active
    let dao_state = futarchy_config::state_mut_from_account(account);
    assert!(
        futarchy_config::operational_state(dao_state) == DAO_STATE_DISSOLVING,
        EDissolutionNotActive
    );
    
    // Get all payment IDs that need to be cancelled
    let payment_ids = stream_actions::get_all_payment_ids(account);
    
    // Cancel all payments and return funds to treasury
    if (return_to_treasury) {
        // This function handles:
        // 1. Cancelling all cancellable streams
        // 2. Returning isolated pool funds to treasury
        // 3. Cancelling pending budget withdrawals
        stream_actions::cancel_all_payments_for_dissolution<FutarchyConfig, CoinType>(
            account,
            clock,
            ctx
        );
    };
    
    // Note: In production, you would:
    // 1. Get list of payment IDs from stream_actions
    // 2. Create individual CancelPaymentAction for each
    // 3. Process them to properly handle coin returns
    // This simplified version provides the integration point
    
    let _ = payment_ids;
    let _ = version;

    // Increment action index
    executable::increment_action_idx(executable);
}

/// Execute withdraw AMM liquidity action
public fun do_withdraw_amm_liquidity<Outcome: store, AssetType, StableType, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    version: VersionWitness,
    intent_witness: IW,
    ctx: &mut TxContext,
) {
    // Get spec and validate type BEFORE deserialization
    let specs = executable::intent(executable).action_specs();
    let spec = specs.borrow(executable::action_idx(executable));
    // WithdrawAmmLiquidity doesn't exist, using WithdrawAllSpotLiquidity
    action_validation::assert_action_type<action_types::WithdrawAllSpotLiquidity>(spec);

    let action_data = intents::action_spec_data(spec);

    // Safe BCS deserialization
    let mut reader = bcs::new(*action_data);
    let pool_id = bcs::peel_address(&mut reader).to_id();
    let burn_lp_tokens = bcs::peel_bool(&mut reader);
    bcs_validation::validate_all_bytes_consumed(reader);
    
    // Verify dissolution is active
    let dao_state = futarchy_config::state_mut_from_account(account);
    assert!(
        futarchy_config::operational_state(dao_state) == DAO_STATE_DISSOLVING,
        EDissolutionNotActive
    );
    
    // Withdraw all liquidity from AMM
    // In a real implementation, this would:
    // 1. Get reference to the AccountSpotPool using pool_id
    // 2. Remove all liquidity using remove_liquidity function
    // 3. Receive back asset and stable tokens
    // 4. Store these tokens in vault for distribution
    // 5. Optionally burn the LP tokens
    
    // Since the AccountSpotPool operations require specific access patterns,
    // the actual implementation would coordinate with the pool module
    
    let _ = pool_id;
    let _ = burn_lp_tokens;
    let _ = version;
    let _ = ctx;

    // Execute and increment
    executable::increment_action_idx(executable);
}

/// Execute distribute assets action
/// 
/// ⚠️ REQUIRES SPECIAL HANDLING:
/// This function now properly requires and uses coins for actual distribution, but needs frontend to:
///   1. Create vault SpendAction to withdraw coins
///   2. Pass coins to this action  
///   3. This is architecturally challenging in current system
/// 
/// The coins must be provided as a parameter, which means the frontend needs to structure
/// the transaction to first withdraw from vault, then call this with the resulting coins.
public fun do_distribute_assets<Outcome: store, CoinType, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    version: VersionWitness,
    intent_witness: IW,
    mut distribution_coin: Coin<CoinType>,
    ctx: &mut TxContext,
) {
    // Get spec and validate type BEFORE deserialization
    let specs = executable::intent(executable).action_specs();
    let spec = specs.borrow(executable::action_idx(executable));
    // DistributeAssets doesn't exist, using DistributeAsset (singular)
    action_validation::assert_action_type<action_types::DistributeAsset>(spec);

    let action_data = intents::action_spec_data(spec);

    // Safe BCS deserialization
    let mut reader = bcs::new(*action_data);
    let holders = bcs::peel_vec_address(&mut reader);
    let holder_amounts = bcs::peel_vec_u64(&mut reader);
    let total_distribution_amount = bcs::peel_u64(&mut reader);
    bcs_validation::validate_all_bytes_consumed(reader);
    
    // Verify dissolution is active
    let dao_state = futarchy_config::state_mut_from_account(account);
    assert!(
        futarchy_config::operational_state(dao_state) == DAO_STATE_DISSOLVING,
        EDissolutionNotActive
    );
    
    // Validate inputs
    assert!(holders.length() > 0, EEmptyAssetList);
    assert!(holders.length() == holder_amounts.length(), EInvalidRatio);
    assert!(coin::value(&distribution_coin) >= total_distribution_amount, EInvalidAmount);
    
    // Calculate total tokens held (for pro rata calculation)
    let mut total_held = 0u64;
    let mut i = 0;
    while (i < holder_amounts.length()) {
        total_held = total_held + *holder_amounts.borrow(i);
        i = i + 1;
    };
    // Prevent division by zero in pro rata calculations
    assert!(total_held > 0, EDivisionByZero);
    
    // Distribute assets pro rata to each holder
    let mut j = 0;
    let mut total_distributed = 0u64;
    while (j < holders.length()) {
        let holder = *holders.borrow(j);
        let holder_amount = *holder_amounts.borrow(j);
        
        // Calculate pro rata share with overflow protection
        let share = (holder_amount as u128) * (total_distribution_amount as u128) / (total_held as u128);
        // Check that the result fits in u64
        assert!(share <= (std::u64::max_value!() as u128), EOverflow);
        let mut share_amount = (share as u64);
        
        // Last recipient gets the remainder to handle rounding
        if (j == holders.length() - 1) {
            share_amount = total_distribution_amount - total_distributed;
        };
        
        // Validate recipient
        assert!(holder != @0x0, EInvalidRecipient);
        
        // Transfer the calculated share to the holder
        if (share_amount > 0) {
            transfer::public_transfer(coin::split(&mut distribution_coin, share_amount, ctx), holder);
            total_distributed = total_distributed + share_amount;
        };
        
        j = j + 1;
    };
    
    // Return any remainder back to sender or destroy if zero
    if (coin::value(&distribution_coin) > 0) {
        transfer::public_transfer(distribution_coin, ctx.sender());
    } else {
        distribution_coin.destroy_zero();
    };
    
    let _ = version;
    let _ = ctx;

    // Increment action index
    executable::increment_action_idx(executable);
}

// === Cleanup Functions ===

/// Delete an initiate dissolution action from an expired intent
public fun delete_initiate_dissolution(expired: &mut Expired) {
    // Remove the action spec from expired intent
    let spec = intents::remove_action_spec(expired);
    // Validate it was the expected action type
    action_validation::assert_action_type<action_types::InitiateDissolution>(&spec);
}

/// Delete a batch distribute action from an expired intent
public fun delete_batch_distribute(expired: &mut Expired) {
    // Remove the action spec from expired intent
    let spec = intents::remove_action_spec(expired);
    // Validate it was the expected action type
    action_validation::assert_action_type<action_types::DistributeAsset>(&spec);
}

/// Delete a finalize dissolution action from an expired intent
public fun delete_finalize_dissolution(expired: &mut Expired) {
    // Remove the action spec from expired intent
    let spec = intents::remove_action_spec(expired);
    // Validate it was the expected action type
    action_validation::assert_action_type<action_types::FinalizeDissolution>(&spec);
}

/// Delete a cancel dissolution action from an expired intent
public fun delete_cancel_dissolution(expired: &mut Expired) {
    // Remove the action spec from expired intent
    let spec = intents::remove_action_spec(expired);
    // Validate it was the expected action type
    action_validation::assert_action_type<action_types::CancelDissolution>(&spec);
}

/// Delete a calculate pro rata shares action from an expired intent
public fun delete_calculate_pro_rata_shares(expired: &mut Expired) {
    // Remove the action spec from expired intent
    let spec = intents::remove_action_spec(expired);
    // Action has drop, will be automatically cleaned up
    let _ = spec;
}

/// Delete a cancel all streams action from an expired intent
public fun delete_cancel_all_streams(expired: &mut Expired) {
    // Remove the action spec from expired intent
    let spec = intents::remove_action_spec(expired);
    // Action has drop, will be automatically cleaned up
    let _ = spec;
}

/// Delete a withdraw AMM liquidity action from an expired intent
public fun delete_withdraw_amm_liquidity<AssetType, StableType>(expired: &mut Expired) {
    // Remove the action spec from expired intent
    let spec = intents::remove_action_spec(expired);
    // Action has drop, will be automatically cleaned up
    let _ = spec;
}

/// Delete a distribute assets action from an expired intent
public fun delete_distribute_assets<CoinType>(expired: &mut Expired) {
    // Remove the action spec from expired intent
    let spec = intents::remove_action_spec(expired);
    // Action has drop, will be automatically cleaned up
    let _ = spec;
}

// === Helper Functions ===

/// Create a new initiate dissolution action
public fun new_initiate_dissolution_action(
    reason: String,
    distribution_method: u8,
    burn_unsold_tokens: bool,
    final_operations_deadline: u64,
): InitiateDissolutionAction {
    assert!(distribution_method <= 2, EInvalidRatio); // 0, 1, or 2
    assert!(reason.length() > 0, EInvalidRatio);

    let action = InitiateDissolutionAction {
        reason,
        distribution_method,
        burn_unsold_tokens,
        final_operations_deadline,
    };
    action
}

/// Create a new batch distribute action
public fun new_batch_distribute_action(
    asset_types: vector<String>,
): BatchDistributeAction {
    assert!(asset_types.length() > 0, EEmptyAssetList);

    let action = BatchDistributeAction {
        asset_types,
    };
    action
}

/// Create a new finalize dissolution action
public fun new_finalize_dissolution_action(
    final_recipient: address,
    destroy_account: bool,
): FinalizeDissolutionAction {
    assert!(final_recipient != @0x0, EInvalidRecipient);

    let action = FinalizeDissolutionAction {
        final_recipient,
        destroy_account,
    };
    action
}

/// Create a new cancel dissolution action
public fun new_cancel_dissolution_action(
    reason: String,
): CancelDissolutionAction {
    assert!(reason.length() > 0, EInvalidRatio);

    let action = CancelDissolutionAction {
        reason,
    };
    action
}

// === Getter Functions ===

/// Get reason from InitiateDissolutionAction
public fun get_reason(action: &InitiateDissolutionAction): &String {
    &action.reason
}

/// Get distribution method from InitiateDissolutionAction
public fun get_distribution_method(action: &InitiateDissolutionAction): u8 {
    action.distribution_method
}

/// Get burn unsold tokens flag from InitiateDissolutionAction
public fun get_burn_unsold_tokens(action: &InitiateDissolutionAction): bool {
    action.burn_unsold_tokens
}

/// Get final operations deadline from InitiateDissolutionAction
public fun get_final_operations_deadline(action: &InitiateDissolutionAction): u64 {
    action.final_operations_deadline
}

/// Get asset types from BatchDistributeAction
public fun get_asset_types(action: &BatchDistributeAction): &vector<String> {
    &action.asset_types
}

/// Get final recipient from FinalizeDissolutionAction
public fun get_final_recipient(action: &FinalizeDissolutionAction): address {
    action.final_recipient
}

/// Get destroy account flag from FinalizeDissolutionAction
public fun get_destroy_account(action: &FinalizeDissolutionAction): bool {
    action.destroy_account
}

/// Get cancel reason from CancelDissolutionAction
public fun get_cancel_reason(action: &CancelDissolutionAction): &String {
    &action.reason
}

/// Create a new calculate pro rata shares action
public fun new_calculate_pro_rata_shares_action(
    total_supply: u64,
    exclude_dao_tokens: bool,
): CalculateProRataSharesAction {
    assert!(total_supply > 0, EInvalidRatio);
    
    CalculateProRataSharesAction {
        total_supply,
        exclude_dao_tokens,
    }
}

/// Create a new cancel all streams action
public fun new_cancel_all_streams_action(
    return_to_treasury: bool,
): CancelAllStreamsAction {
    CancelAllStreamsAction {
        return_to_treasury,
    }
}

/// Create a new withdraw AMM liquidity action
public fun new_withdraw_amm_liquidity_action<AssetType, StableType>(
    pool_id: ID,
    burn_lp_tokens: bool,
): WithdrawAmmLiquidityAction<AssetType, StableType> {
    WithdrawAmmLiquidityAction {
        pool_id,
        burn_lp_tokens,
    }
}

/// Create a new distribute assets action
public fun new_distribute_assets_action<CoinType>(
    holders: vector<address>,
    holder_amounts: vector<u64>,
    total_distribution_amount: u64,
): DistributeAssetsAction<CoinType> {
    assert!(holders.length() > 0, EEmptyAssetList);
    assert!(holders.length() == holder_amounts.length(), EInvalidRatio);
    assert!(total_distribution_amount > 0, EInvalidRatio);
    
    // Verify holder amounts sum is positive
    let mut sum = 0u64;
    let mut i = 0;
    while (i < holder_amounts.length()) {
        sum = sum + *holder_amounts.borrow(i);
        i = i + 1;
    };
    assert!(sum > 0, EInvalidRatio);
    
    DistributeAssetsAction {
        holders,
        holder_amounts,
        total_distribution_amount,
    }
}