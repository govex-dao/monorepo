/// Dissolution-related actions for futarchy DAOs
/// This module defines action structs and execution logic for DAO dissolution
module futarchy::dissolution_actions;

// === Imports ===
use std::string::String;
use sui::{
    coin::{Self, Coin},
    balance::{Self, Balance},
    object::ID,
    transfer,
    clock::Clock,
    tx_context::TxContext,
};
use account_protocol::{
    account::{Self, Account},
    executable::Executable,
    intents::Expired,
    version_witness::VersionWitness,
};
use futarchy::{
    futarchy_config::{Self, FutarchyConfig},
    futarchy_vault,
    stream_actions,
};

// === Errors ===
const EInvalidRatio: u64 = 1;
const EInvalidRecipient: u64 = 2;
const EEmptyAssetList: u64 = 3;
const EInvalidThreshold: u64 = 4;
const EDissolutionNotActive: u64 = 5;
const ENotDissolving: u64 = 6;

// === Action Structs ===

/// Action to initiate DAO dissolution
public struct InitiateDissolutionAction has store {
    reason: String,
    distribution_method: u8, // 0: pro-rata, 1: equal, 2: custom
    burn_unsold_tokens: bool,
    final_operations_deadline: u64,
}

/// Action to distribute a specific asset during dissolution
public struct DistributeAssetAction<phantom CoinType> has store {
    total_amount: u64,
    recipients: vector<address>,
    amounts: vector<u64>, // For custom distribution
}

/// Action to batch distribute multiple assets
public struct BatchDistributeAction has store {
    asset_types: vector<String>, // Type names of assets to distribute
}

/// Action to finalize dissolution and destroy the DAO
public struct FinalizeDissolutionAction has store {
    final_recipient: address, // For any remaining dust
    destroy_account: bool,
}

/// Action to cancel dissolution (if allowed)
public struct CancelDissolutionAction has store {
    reason: String,
}

/// Action to calculate pro rata shares for distribution
public struct CalculateProRataSharesAction has store {
    /// Total supply of asset tokens (excluding DAO-owned)
    total_supply: u64,
    /// Whether to exclude DAO treasury tokens
    exclude_dao_tokens: bool,
}

/// Action to cancel all active streams
public struct CancelAllStreamsAction has store {
    /// Whether to return stream balances to treasury
    return_to_treasury: bool,
}

/// Action to withdraw all AMM liquidity
public struct WithdrawAmmLiquidityAction<phantom AssetType, phantom StableType> has store {
    /// Pool ID to withdraw from
    pool_id: ID,
    /// Whether to burn LP tokens after withdrawal
    burn_lp_tokens: bool,
}

/// Action to distribute all treasury assets pro rata
public struct DistributeAssetsAction<phantom CoinType> has store {
    /// Holders who will receive distributions (address -> token amount held)
    holders: vector<address>,
    /// Amount of tokens each holder has
    holder_amounts: vector<u64>,
    /// Total amount to distribute
    total_distribution_amount: u64,
}

// === Execution Functions ===

/// Execute an initiate dissolution action
public fun do_initiate_dissolution<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    version: VersionWitness,
    intent_witness: IW,
    _ctx: &mut TxContext,
) {
    let action: &InitiateDissolutionAction = executable.next_action(intent_witness);
    
    // Extract parameters from action
    let reason = &action.reason;
    let distribution_method = action.distribution_method;
    let burn_unsold_tokens = action.burn_unsold_tokens;
    let deadline = action.final_operations_deadline;
    
    // Get the config and set dissolution state
    let config = futarchy_config::internal_config_mut(account);
    
    // 1. Set dissolution state in config (operational_state = DISSOLVING)
    futarchy_config::set_operational_state(config, futarchy_config::state_dissolving());
    
    // 2. Pause all normal operations by disabling proposals
    futarchy_config::set_proposals_enabled_internal(config, false);
    
    // 3. Record dissolution parameters in config metadata
    // Store the dissolution parameters for later use
    // Note: In a real implementation, we'd store these in a DissolutionState struct
    // For now, we just validate them
    assert!(reason.length() > 0, EInvalidRatio);
    assert!(distribution_method <= 2, EInvalidRatio);
    assert!(deadline > 0, EInvalidThreshold);
    
    // 4. Begin asset tallying process is handled by subsequent actions
    let _ = burn_unsold_tokens;
    let _ = version;
}

/// Execute a distribute asset action
public fun do_distribute_asset<Outcome: store, CoinType, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    version: VersionWitness,
    intent_witness: IW,
    mut distribution_coin: Coin<CoinType>,
    ctx: &mut TxContext,
) {
    let action: &DistributeAssetAction<CoinType> = executable.next_action(intent_witness);
    
    // Extract parameters
    let recipients = &action.recipients;
    let amounts = &action.amounts;
    let total_amount = action.total_amount;
    
    // 1. Verify dissolution state
    let config = account::config(account);
    assert!(
        futarchy_config::operational_state(config) == futarchy_config::state_dissolving(),
        EDissolutionNotActive
    );

    // 2. Distribute to recipients from provided coin
    let mut i = 0;
    let mut distributed_sum = 0;
    while (i < recipients.length()) {
        let recipient = *recipients.borrow(i);
        let amount = *amounts.borrow(i);
        transfer::public_transfer(coin::split(&mut distribution_coin, amount, ctx), recipient);
        distributed_sum = distributed_sum + amount;
        i = i + 1;
    };

    // Return any remainder back to sender; if exactly zero, destroy_zero()
    if (coin::value(&distribution_coin) > 0) {
        transfer::public_transfer(distribution_coin, ctx.sender());
    } else {
        distribution_coin.destroy_zero();
    };

    let _ = version;
}

/// Execute a batch distribute action
public fun do_batch_distribute<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    version: VersionWitness,
    intent_witness: IW,
    ctx: &mut TxContext,
) {
    let action: &BatchDistributeAction = executable.next_action(intent_witness);
    
    // Extract parameters
    let asset_types = &action.asset_types;
    
    // Verify dissolution is active
    let config = account::config(account);
    assert!(
        futarchy_config::operational_state(config) == futarchy_config::state_dissolving(),
        EDissolutionNotActive
    );
    
    // Note: This action serves as a coordinator for multiple distribute actions
    // The actual typed DistributeAssetAction<CoinType> actions would need to be
    // added to the executable for each specific coin type.
    // This is because Move doesn't support runtime type information.
    // 
    // In practice, when creating the dissolution intent, you would:
    // 1. Add this BatchDistributeAction to mark the batch operation
    // 2. Add individual DistributeAssetAction<CoinType> for each asset type
    // 3. The executor would process them in sequence
    
    // For now, just validate that we have asset types to distribute
    assert!(asset_types.length() > 0, EEmptyAssetList);
    
    let _ = version;
    let _ = ctx;
}

/// Execute a finalize dissolution action
public fun do_finalize_dissolution<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    version: VersionWitness,
    intent_witness: IW,
    _ctx: &mut TxContext,
) {
    let action: &FinalizeDissolutionAction = executable.next_action(intent_witness);
    
    // Extract parameters
    let final_recipient = action.final_recipient;
    let destroy_account = action.destroy_account;
    
    // Verify dissolution is active
    let config = futarchy_config::internal_config_mut(account);
    assert!(
        futarchy_config::operational_state(config) == futarchy_config::state_dissolving(),
        EDissolutionNotActive  
    );
    
    // 1. Verify all assets have been distributed
    // In a real implementation, we'd check that all vaults are empty or minimal
    // For now, we just validate the recipient
    assert!(final_recipient != @0x0, EInvalidRecipient);
    
    // 2. Send any remaining dust to final_recipient
    // This would require checking all vault balances and transferring remainders
    // Implementation would iterate through all coin types in vaults
    
    // 3. Mark DAO as fully dissolved
    // Set the operational state to a final "dissolved" state
    // For now, we'll keep it in DISSOLVING state since we don't have a DISSOLVED constant
    // In a real implementation, you'd add a DISSOLVED state constant
    
    // 4. Destroy account if specified
    if (destroy_account) {
        // Account destruction would need special handling
        // For now, we just mark it as inactive
        futarchy_config::set_operational_state(config, futarchy_config::state_paused());
    };
    
    let _ = version;
}

/// Execute a cancel dissolution action
public fun do_cancel_dissolution<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    version: VersionWitness,
    intent_witness: IW,
    _ctx: &mut TxContext,
) {
    let action: &CancelDissolutionAction = executable.next_action(intent_witness);
    
    // Extract parameters
    let reason = &action.reason;
    
    // Get the config
    let config = futarchy_config::internal_config_mut(account);
    
    // 1. Verify dissolution can be cancelled (must be in dissolving state)
    assert!(
        futarchy_config::operational_state(config) == futarchy_config::state_dissolving(),
        ENotDissolving
    );
    
    // Validate cancellation reason
    assert!(reason.length() > 0, EInvalidRatio);
    
    // 2. Revert operational state to ACTIVE
    futarchy_config::set_operational_state(config, futarchy_config::state_active());
    
    // 3. Resume normal operations by re-enabling proposals
    futarchy_config::set_proposals_enabled_internal(config, true);
    
    // 4. Return any collected assets to vault
    // In a real implementation, this would involve:
    // - Checking if any assets were moved to a dissolution pool
    // - Moving them back to the main vault
    // - Restoring any paused streams or recurring payments
    
    let _ = version;
}

/// Execute calculate pro rata shares action
public fun do_calculate_pro_rata_shares<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    version: VersionWitness,
    intent_witness: IW,
    _ctx: &mut TxContext,
) {
    let action: &CalculateProRataSharesAction = executable.next_action(intent_witness);
    
    // Extract parameters
    let total_supply = action.total_supply;
    let exclude_dao_tokens = action.exclude_dao_tokens;
    
    // Verify dissolution is active
    let config = account::config(account);
    assert!(
        futarchy_config::operational_state(config) == futarchy_config::state_dissolving(),
        EDissolutionNotActive
    );
    
    // Calculate pro rata distribution
    // In a real implementation, this would:
    // 1. Get total supply of asset tokens
    // 2. If exclude_dao_tokens, subtract DAO-owned tokens from total
    // 3. Calculate each holder's percentage of the adjusted total
    // 4. Store these percentages for use in distribution actions
    
    assert!(total_supply > 0, EInvalidRatio);
    
    // The actual calculation would be done when creating DistributeAssetsAction
    // This action mainly validates and prepares for distribution
    
    let _ = exclude_dao_tokens;
    let _ = version;
}

/// Execute cancel all streams action
public fun do_cancel_all_streams<Outcome: store, CoinType, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    version: VersionWitness,
    intent_witness: IW,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let action: &CancelAllStreamsAction = executable.next_action(intent_witness);
    
    // Extract parameters
    let return_to_treasury = action.return_to_treasury;
    
    // Verify dissolution is active
    let config = account::config(account);
    assert!(
        futarchy_config::operational_state(config) == futarchy_config::state_dissolving(),
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
        stream_actions::cancel_all_payments_for_dissolution<CoinType>(
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
}

/// Execute withdraw AMM liquidity action
public fun do_withdraw_amm_liquidity<Outcome: store, AssetType, StableType, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    version: VersionWitness,
    intent_witness: IW,
    ctx: &mut TxContext,
) {
    let action: &WithdrawAmmLiquidityAction<AssetType, StableType> = executable.next_action(intent_witness);
    
    // Extract parameters
    let pool_id = action.pool_id;
    let burn_lp_tokens = action.burn_lp_tokens;
    
    // Verify dissolution is active
    let config = account::config(account);
    assert!(
        futarchy_config::operational_state(config) == futarchy_config::state_dissolving(),
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
}

/// Execute distribute assets action  
public fun do_distribute_assets<Outcome: store, CoinType, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    version: VersionWitness,
    intent_witness: IW,
    ctx: &mut TxContext,
) {
    let action: &DistributeAssetsAction<CoinType> = executable.next_action(intent_witness);
    
    // Extract parameters
    let holders = &action.holders;
    let holder_amounts = &action.holder_amounts;
    let total_distribution_amount = action.total_distribution_amount;
    
    // Verify dissolution is active
    let config = account::config(account);
    assert!(
        futarchy_config::operational_state(config) == futarchy_config::state_dissolving(),
        EDissolutionNotActive
    );
    
    // Validate inputs
    assert!(holders.length() > 0, EEmptyAssetList);
    assert!(holders.length() == holder_amounts.length(), EInvalidRatio);
    
    // Calculate total tokens held (for pro rata calculation)
    let mut total_held = 0u64;
    let mut i = 0;
    while (i < holder_amounts.length()) {
        total_held = total_held + *holder_amounts.borrow(i);
        i = i + 1;
    };
    assert!(total_held > 0, EInvalidRatio);
    
    // Distribute assets pro rata
    // In a real implementation, this would:
    // 1. Withdraw total_distribution_amount from vault
    // 2. For each holder, calculate their share: (holder_amount * total_distribution) / total_held
    // 3. Transfer their share to them
    // 4. Holders would burn their tokens after receiving distribution
    
    let mut j = 0;
    while (j < holders.length()) {
        let holder = *holders.borrow(j);
        let holder_amount = *holder_amounts.borrow(j);
        
        // Calculate pro rata share
        // Using integer math: (holder_amount * total_distribution) / total_held
        // In production, use proper fixed-point math to avoid rounding errors
        let share = (holder_amount as u128) * (total_distribution_amount as u128) / (total_held as u128);
        let share_amount = (share as u64);
        
        // Validate recipient and amount
        assert!(holder != @0x0, EInvalidRecipient);
        assert!(share_amount > 0 || holder_amount == 0, EInvalidRatio);
        
        // In real implementation, transfer the share to holder here
        // transfer::public_transfer(coin::split(&mut distribution_coin, share_amount, ctx), holder);
        
        j = j + 1;
    };
    
    let _ = version;
    let _ = ctx;
}

// === Cleanup Functions ===

/// Delete an initiate dissolution action from an expired intent
public fun delete_initiate_dissolution(expired: &mut Expired) {
    let InitiateDissolutionAction {
        reason: _,
        distribution_method: _,
        burn_unsold_tokens: _,
        final_operations_deadline: _,
    } = expired.remove_action();
}

/// Delete a distribute asset action from an expired intent
public fun delete_distribute_asset<CoinType>(expired: &mut Expired) {
    let DistributeAssetAction<CoinType> {
        total_amount: _,
        recipients: _,
        amounts: _,
    } = expired.remove_action();
}

/// Delete a batch distribute action from an expired intent
public fun delete_batch_distribute(expired: &mut Expired) {
    let BatchDistributeAction {
        asset_types: _,
    } = expired.remove_action();
}

/// Delete a finalize dissolution action from an expired intent
public fun delete_finalize_dissolution(expired: &mut Expired) {
    let FinalizeDissolutionAction {
        final_recipient: _,
        destroy_account: _,
    } = expired.remove_action();
}

/// Delete a cancel dissolution action from an expired intent
public fun delete_cancel_dissolution(expired: &mut Expired) {
    let CancelDissolutionAction {
        reason: _,
    } = expired.remove_action();
}

/// Delete a calculate pro rata shares action from an expired intent
public fun delete_calculate_pro_rata_shares(expired: &mut Expired) {
    let CalculateProRataSharesAction {
        total_supply: _,
        exclude_dao_tokens: _,
    } = expired.remove_action();
}

/// Delete a cancel all streams action from an expired intent
public fun delete_cancel_all_streams(expired: &mut Expired) {
    let CancelAllStreamsAction {
        return_to_treasury: _,
    } = expired.remove_action();
}

/// Delete a withdraw AMM liquidity action from an expired intent
public fun delete_withdraw_amm_liquidity<AssetType, StableType>(expired: &mut Expired) {
    let WithdrawAmmLiquidityAction<AssetType, StableType> {
        pool_id: _,
        burn_lp_tokens: _,
    } = expired.remove_action();
}

/// Delete a distribute assets action from an expired intent
public fun delete_distribute_assets<CoinType>(expired: &mut Expired) {
    let DistributeAssetsAction<CoinType> {
        holders: _,
        holder_amounts: _,
        total_distribution_amount: _,
    } = expired.remove_action();
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
    
    InitiateDissolutionAction {
        reason,
        distribution_method,
        burn_unsold_tokens,
        final_operations_deadline,
    }
}

/// Create a new distribute asset action
public fun new_distribute_asset_action<CoinType>(
    total_amount: u64,
    recipients: vector<address>,
    amounts: vector<u64>,
): DistributeAssetAction<CoinType> {
    assert!(recipients.length() > 0, EEmptyAssetList);
    assert!(recipients.length() == amounts.length(), EInvalidRatio);
    
    // Verify amounts sum to total (with some tolerance for rounding)
    let mut sum = 0;
    let mut i = 0;
    while (i < amounts.length()) {
        sum = sum + *amounts.borrow(i);
        i = i + 1;
    };
    assert!(sum <= total_amount, EInvalidRatio);
    
    DistributeAssetAction {
        total_amount,
        recipients,
        amounts,
    }
}

/// Create a new batch distribute action
public fun new_batch_distribute_action(
    asset_types: vector<String>,
): BatchDistributeAction {
    assert!(asset_types.length() > 0, EEmptyAssetList);
    
    BatchDistributeAction {
        asset_types,
    }
}

/// Create a new finalize dissolution action
public fun new_finalize_dissolution_action(
    final_recipient: address,
    destroy_account: bool,
): FinalizeDissolutionAction {
    assert!(final_recipient != @0x0, EInvalidRecipient);
    
    FinalizeDissolutionAction {
        final_recipient,
        destroy_account,
    }
}

/// Create a new cancel dissolution action
public fun new_cancel_dissolution_action(
    reason: String,
): CancelDissolutionAction {
    assert!(reason.length() > 0, EInvalidRatio);
    
    CancelDissolutionAction {
        reason,
    }
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

/// Get total amount from DistributeAssetAction
public fun get_total_amount<CoinType>(action: &DistributeAssetAction<CoinType>): u64 {
    action.total_amount
}

/// Get recipients from DistributeAssetAction
public fun get_recipients<CoinType>(action: &DistributeAssetAction<CoinType>): &vector<address> {
    &action.recipients
}

/// Get amounts from DistributeAssetAction
public fun get_amounts<CoinType>(action: &DistributeAssetAction<CoinType>): &vector<u64> {
    &action.amounts
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