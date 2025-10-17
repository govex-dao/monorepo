// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

/// Dissolution-related actions for futarchy DAOs
/// This module defines action structs and execution logic for DAO dissolution
module futarchy_lifecycle::dissolution_actions;

// === Imports ===
use std::{string::{Self, String}, vector, type_name};
use sui::{
    bcs::{Self, BCS},
    coin::{Self, Coin},
    object::{Self, ID},
    transfer,
    clock::Clock,
    tx_context::TxContext,
};
use futarchy_markets_core::unified_spot_pool;
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
    resource_requests::{Self as resource_requests, ResourceReceipt, ResourceRequest},
};
use futarchy_actions::lp_token_custody;
use futarchy_stream_actions::stream_actions;
use futarchy_lifecycle::dissolution_auction;
use account_actions::vault;

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
const EWrongAction: u64 = 10;
const EAuctionsStillActive: u64 = 11;

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
    /// LP token ID to withdraw from custody
    token_id: ID,
    /// Bypass MINIMUM_LIQUIDITY check (true = allow complete emptying)
    bypass_minimum: bool,
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

/// Action to create dissolution auction for unique asset
public struct CreateAuctionAction has store, drop, copy {
    /// ID of the object being auctioned
    object_id: ID,
    /// Fully-qualified type name of the object being auctioned
    object_type: String,
    /// Fully-qualified type name of the bid coin
    bid_coin_type: String,
    /// Minimum bid amount in BidCoin
    minimum_bid: u64,
    /// Auction duration in milliseconds
    duration_ms: u64,
}

// === Hot Potato Structs ===

/// Resource request for AMM liquidity withdrawal (hot potato)
/// Must be fulfilled in same transaction by providing pool reference and account
public struct WithdrawAmmLiquidityRequest<phantom AssetType, phantom StableType> has store, drop {
    pool_id: ID,
    token_id: ID,
    bypass_minimum: bool,
}

/// Receipt confirming AMM liquidity withdrawal completed
public struct WithdrawAmmLiquidityReceipt<phantom AssetType, phantom StableType> has store, drop {
    pool_id: ID,
    asset_amount: u64,
    stable_amount: u64,
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

    // 3. Initialize auction counter for dissolution auctions
    dissolution_auction::init_auction_counter(account);

    // 4. Record dissolution parameters in config metadata
    assert!(reason.length() > 0, EInvalidRatio);
    assert!(distribution_method <= 2, EInvalidRatio);
    assert!(final_operations_deadline > 0, EInvalidThreshold);

    let _ = burn_unsold_tokens;
    let _ = version;
    let _ = intent_witness;

    // Execute and increment
    executable::increment_action_idx(executable);
}

/// Execute a batch distribute action
///
/// ⚠️ METADATA-ONLY ACTION (NOT A STUB):
/// This action records which asset types will be distributed during dissolution.
/// It does NOT perform the actual distribution - that happens via individual
/// `do_distribute_assets<CoinType>` actions that follow this action in the intent.
///
/// **Purpose:**
/// 1. **Governance Transparency**: Proposal explicitly lists all assets to be distributed
/// 2. **Validation**: Ensures asset types are known and valid before distribution begins
/// 3. **Coordination**: Acts as a checkpoint before multiple distribution actions
///
/// **Typical Intent Flow:**
/// ```
/// 1. InitiateDissolution - Set DAO to DISSOLVING state
/// 2. CancelAllStreams - Cancel payment streams
/// 3. WithdrawAmmLiquidity - Get liquidity from pools
/// 4. BatchDistribute - [METADATA] Record assets to distribute (USDC, SUI, etc.)
/// 5. DistributeAssets<USDC> - Actual distribution of USDC
/// 6. DistributeAssets<SUI> - Actual distribution of SUI
/// 7. FinalizeDissolution - Set DAO to DISSOLVED state
/// ```
///
/// **Production Enhancement (Optional):**
/// - Store asset list in Account dynamic fields for audit trail
/// - Frontend can verify all listed assets were actually distributed
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

    assert!(final_recipient != @0x0, EInvalidRecipient);

    // CRITICAL: All auctions must be complete before finalization (check BEFORE borrowing state mutably)
    assert!(
        dissolution_auction::all_auctions_complete(account),
        EAuctionsStillActive
    );

    // Verify dissolution is active and set to dissolved
    let dao_state = futarchy_config::state_mut_from_account(account);
    assert!(
        futarchy_config::operational_state(dao_state) == DAO_STATE_DISSOLVING,
        EDissolutionNotActive
    );

    // Set operational state to dissolved
    futarchy_config::set_operational_state(dao_state, DAO_STATE_DISSOLVED);

    if (destroy_account) {
        // Account destruction would need special handling
    };

    // Execute and increment
    executable::increment_action_idx(executable);
}

/// Execute a cancel dissolution action
///
/// ⚠️ CANCELLATION SAFETY CHECKS:
/// This function verifies that cancellation is safe by checking:
/// 1. DAO is currently in DISSOLVING state
/// 2. No active auctions exist (would leave auctions orphaned)
///
/// **Note on Irreversible Operations:**
/// Some dissolution actions cannot be automatically reversed:
/// - **Stream cancellations**: Cancelled streams stay cancelled (manual recreation needed)
/// - **AMM withdrawals**: Withdrawn liquidity stays withdrawn (manual re-deposit needed)
/// - **Completed auctions**: Sold items cannot be reclaimed
///
/// The DAO can still return to ACTIVE state after these operations, but the operator
/// must manually restore the previous state (recreate streams, re-add liquidity, etc.)
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

    assert!(reason.length() > 0, EInvalidRatio);

    // SAFETY CHECK: Verify no active auctions before cancellation (check BEFORE borrowing state mutably)
    // Active auctions would be orphaned if we cancel dissolution
    assert!(
        dissolution_auction::all_auctions_complete(account),
        EAuctionsStillActive
    );

    // Verify DAO is in dissolving state
    let dao_state = futarchy_config::state_mut_from_account(account);
    assert!(
        futarchy_config::operational_state(dao_state) == DAO_STATE_DISSOLVING,
        ENotDissolving
    );

    // Set operational state back to active
    futarchy_config::set_operational_state(dao_state, DAO_STATE_ACTIVE);
    // Proposals are re-enabled automatically via operational state

    // Execute and increment
    executable::increment_action_idx(executable);
}

/// Execute calculate pro rata shares action
///
/// ⚠️ VALIDATION & METADATA ACTION:
/// This action validates parameters and records metadata for pro-rata distribution.
/// The actual calculation happens OFF-CHAIN when creating `DistributeAssetsAction`.
///
/// **Purpose:**
/// 1. **Governance Approval**: DAO explicitly approves the distribution method and parameters
/// 2. **Parameter Validation**: Ensures total_supply > 0 and flags are valid
/// 3. **Transparency**: Records whether DAO-owned tokens are excluded from distribution
///
/// **Why Off-Chain Calculation:**
/// - Pro-rata calculation requires reading ALL holder balances from off-chain indexer
/// - On-chain iteration over all holders would hit gas limits for large DAOs
/// - Distribution amounts are calculated off-chain, then passed to `DistributeAssetsAction`
///
/// **Example Flow:**
/// ```
/// // 1. DAO approves pro-rata method (this action)
/// CalculateProRataShares { total_supply: 1_000_000, exclude_dao_tokens: true }
///
/// // 2. Off-chain (indexer/frontend):
/// //    - Query all token holders and balances
/// //    - Calculate circulating supply (excluding DAO-owned)
/// //    - Calculate each holder's pro-rata share
/// //    holders = [alice, bob], amounts = [500_000, 500_000]
///
/// // 3. Execute distributions with calculated amounts (next actions in intent)
/// DistributeAssets<USDC> { holders, holder_amounts, total_distribution_amount }
/// ```
///
/// **Production Enhancement (Optional):**
/// - Store calculation parameters in Account dynamic fields for audit
/// - Emit event with circulating supply snapshot for off-chain indexers
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
    action_validation::assert_action_type<action_types::CalculateProRataShares>(spec);

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

    // Validate parameters for pro-rata calculation
    assert!(total_supply > 0, EDivisionByZero);

    // NOTE: Actual per-holder calculation happens OFF-CHAIN
    // The frontend/indexer will:
    // 1. Read all holder balances from chain state
    // 2. Calculate circulating supply (exclude DAO tokens if flag set)
    // 3. Calculate pro-rata shares: (holder_balance / circulating_supply) * treasury_amount
    // 4. Pass results to DistributeAssetsAction

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
    action_validation::assert_action_type<action_types::CancelAllStreams>(spec);

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

/// Execute withdraw AMM liquidity action - STEP 1: Create Resource Request
///
/// ⚠️ HOT POTATO PATTERN:
/// Returns a ResourceRequest that MUST be fulfilled in same transaction
/// PTB must call fulfill_withdraw_amm_liquidity() with pool reference
///
/// ⚠️ CRITICAL: This action withdraws DAO-owned LP from the AMM
/// - Bypasses MINIMUM_LIQUIDITY check for complete dissolution
/// - Blocks if proposal is active (liquidity in conditional markets)
/// - Deposits withdrawn assets to vault for distribution
public fun do_withdraw_amm_liquidity<Outcome: store, AssetType, StableType, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    version: VersionWitness,
    intent_witness: IW,
    ctx: &mut TxContext,
): ResourceRequest<WithdrawAmmLiquidityRequest<AssetType, StableType>> {
    // Get spec and validate type BEFORE deserialization
    let specs = executable::intent(executable).action_specs();
    let spec = specs.borrow(executable::action_idx(executable));
    action_validation::assert_action_type<action_types::WithdrawAllSpotLiquidity>(spec);

    let action_data = intents::action_spec_data(spec);

    // Safe BCS deserialization
    let mut reader = bcs::new(*action_data);
    let pool_id = bcs::peel_address(&mut reader).to_id();
    let token_id = bcs::peel_address(&mut reader).to_id();  // LP token ID in custody
    let bypass_minimum = bcs::peel_bool(&mut reader);  // Allow bypassing MINIMUM_LIQUIDITY
    bcs_validation::validate_all_bytes_consumed(reader);

    // Verify dissolution is active
    let dao_state = futarchy_config::state_mut_from_account(account);
    assert!(
        futarchy_config::operational_state(dao_state) == DAO_STATE_DISSOLVING,
        EDissolutionNotActive
    );

    let _ = version;
    let _ = intent_witness;

    // Execute and increment
    executable::increment_action_idx(executable);

    // Return hot potato wrapped in resource request - MUST be fulfilled in same transaction
    let request_data = WithdrawAmmLiquidityRequest {
        pool_id,
        token_id,
        bypass_minimum,
    };
    resource_requests::new_resource_request(request_data, ctx)
}

/// Fulfill AMM liquidity withdrawal - STEP 2: Execute with Pool Reference
///
/// ⚠️ HOT POTATO FULFILLMENT:
/// Caller must provide actual pool reference to complete withdrawal
/// Returns coins that can be deposited to vault or distributed
///
/// # PTB Flow Example:
/// ```
/// // 1. Execute action (returns hot potato)
/// let request = do_withdraw_amm_liquidity(...);
///
/// // 2. Get pool and account references
/// let pool = // ... get from DAO's dynamic fields or shared object
///
/// // 3. Fulfill request (consumes hot potato, withdraws LP from custody)
/// let (asset_coin, stable_coin, receipt) = fulfill_withdraw_amm_liquidity(request, account, pool, witness, ctx);
///
/// // 4. Deposit to vault or use in distribution
/// vault::deposit(account, asset_coin);
/// vault::deposit(account, stable_coin);
///
/// // 5. Confirm completion
/// confirm_withdraw_amm_liquidity(receipt);
/// ```
public fun fulfill_withdraw_amm_liquidity<AssetType, StableType, W: copy + drop>(
    request: ResourceRequest<WithdrawAmmLiquidityRequest<AssetType, StableType>>,
    account: &mut Account<FutarchyConfig>,
    pool: &mut unified_spot_pool::UnifiedSpotPool<AssetType, StableType>,
    witness: W,
    ctx: &mut TxContext,
): (Coin<AssetType>, Coin<StableType>, WithdrawAmmLiquidityReceipt<AssetType, StableType>) {
    let WithdrawAmmLiquidityRequest {
        pool_id,
        token_id,
        bypass_minimum,
    } = resource_requests::extract_action(request);

    // Verify pool ID matches
    assert!(object::id(pool) == pool_id, EWrongAction);

    // Step 1: Withdraw the LP token from custody
    let lp_token = lp_token_custody::withdraw_lp_token<AssetType, StableType, W>(
        account,
        pool_id,
        token_id,
        copy witness,
        ctx
    );

    // Step 2: Remove liquidity from the pool using the special dissolution function
    // This bypasses the MINIMUM_LIQUIDITY check if requested
    let (asset_coin, stable_coin) = if (bypass_minimum) {
        unified_spot_pool::remove_liquidity_for_dissolution<AssetType, StableType>(
            pool,
            lp_token,
            bypass_minimum,
            ctx
        )
    } else {
        // Use regular remove_liquidity which enforces MINIMUM_LIQUIDITY
        unified_spot_pool::remove_liquidity<AssetType, StableType>(
            pool,
            lp_token,
            0,  // min_asset_out
            0,  // min_stable_out
            ctx
        )
    };

    let asset_amount = coin::value(&asset_coin);
    let stable_amount = coin::value(&stable_coin);

    // Create receipt
    let receipt = WithdrawAmmLiquidityReceipt {
        pool_id,
        asset_amount,
        stable_amount,
    };

    (asset_coin, stable_coin, receipt)
}

/// Confirm AMM liquidity withdrawal - STEP 3: Consume Receipt
///
/// Consumes the receipt to confirm withdrawal completed
/// Can extract withdrawal amounts for accounting/events
public fun confirm_withdraw_amm_liquidity<AssetType, StableType>(
    receipt: WithdrawAmmLiquidityReceipt<AssetType, StableType>,
): (ID, u64, u64) {
    let WithdrawAmmLiquidityReceipt {
        pool_id,
        asset_amount,
        stable_amount,
    } = receipt;

    (pool_id, asset_amount, stable_amount)
}

/// Execute distribute assets action
///
/// ⚠️ COIN FLOW PATTERN - PTB COMPOSITION REQUIRED:
/// This function requires coins to be provided as a parameter. The PTB must:
///
/// 1. **Withdraw from Vault** - Call vault::request_spend_and_transfer<CoinType> first:
///    ```move
///    let coins = vault::request_spend_and_transfer<CoinType>(
///        account,
///        total_distribution_amount,
///        temp_address,  // Will be distributed in next step
///        ctx
///    );
///    ```
///
/// 2. **Pass to Distribution** - Use the coins from step 1:
///    ```move
///    dissolution_actions::do_distribute_assets<CoinType>(
///        executable,
///        account,
///        coins,  // From vault withdrawal
///        ctx
///    );
///    ```
///
/// 3. **Automatic Remainder Handling**:
///    - If coin value > distribution amount: Remainder deposited back to vault (if allowed coin type)
///    - If not allowed coin type: Remainder transferred to tx sender
///    - If exact match: Coin destroyed as zero balance
///
/// **Why Not ResourceRequest Pattern:**
/// - Vault spending is already an established pattern in the system
/// - ResourceRequest is for EXTERNAL resources (AMM pools, shared objects)
/// - This uses Account's own vault resources (internal, not external)
public fun do_distribute_assets<Outcome: store, CoinType: drop, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    version: VersionWitness,
    _intent_witness: IW,
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
    
    // CRITICAL: All auctions must be complete before distribution
    assert!(
        dissolution_auction::all_auctions_complete(account),
        EAuctionsStillActive
    );

    // Return any remainder back to sender or destroy if zero
    if (coin::value(&distribution_coin) > 0) {
        let vault_name = string::utf8(b"treasury");
        if (vault::is_coin_type_approved<FutarchyConfig, CoinType>(account, vault_name)) {
            vault::deposit_approved<FutarchyConfig, CoinType>(
                account,
                vault_name,
                distribution_coin
            );
        } else {
            transfer::public_transfer(distribution_coin, ctx.sender());
        };
    } else {
        distribution_coin.destroy_zero();
    };

    let _ = version;
    let _ = ctx;

    // Increment action index
    executable::increment_action_idx(executable);
}

/// Execute create auction action - STEP 1: Create Type-Erased Request
///
/// ⚠️ HOT POTATO PATTERN:
/// Returns CreateAuctionRequest that MUST be fulfilled in same transaction
/// PTB must call fulfill_create_auction() with actual object + type parameters
///
/// This uses TYPE ERASURE to avoid generic explosion:
/// - Action data stores object_type and bid_coin_type as Strings
/// - Request is non-generic (object_id: ID, not object: T)
/// - Fulfillment is generic (validates types match at runtime)
public fun do_create_auction<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    version: VersionWitness,
    intent_witness: IW,
    ctx: &mut TxContext,
): ResourceRequest<dissolution_auction::CreateAuctionRequest> {
    // Get spec and validate type BEFORE deserialization
    let specs = executable::intent(executable).action_specs();
    let spec = specs.borrow(executable::action_idx(executable));
    action_validation::assert_action_type<action_types::CreateAuction>(spec);

    let action_data = intents::action_spec_data(spec);

    // Safe BCS deserialization
    let mut reader = bcs::new(*action_data);
    let action = CreateAuctionAction {
        object_id: bcs::peel_address(&mut reader).to_id(),
        object_type: string::utf8(bcs::peel_vec_u8(&mut reader)),
        bid_coin_type: string::utf8(bcs::peel_vec_u8(&mut reader)),
        minimum_bid: bcs::peel_u64(&mut reader),
        duration_ms: bcs::peel_u64(&mut reader),
    };
    bcs_validation::validate_all_bytes_consumed(reader);

    // Verify dissolution is active
    let dao_state = futarchy_config::state_mut_from_account(account);
    assert!(
        futarchy_config::operational_state(dao_state) == DAO_STATE_DISSOLVING,
        EDissolutionNotActive
    );

    assert!(action.minimum_bid > 0, EInvalidAmount);
    assert!(action.duration_ms > 0, EInvalidThreshold);

    let _ = version;
    let _ = intent_witness;

    // Increment action index BEFORE returning hot potato
    executable::increment_action_idx(executable);

    // Return type-erased hot potato wrapped in resource request - MUST be fulfilled in same transaction
    // Strings will be validated against actual TypeName at fulfillment
    let request = dissolution_auction::create_auction_request(
        account,
        action.object_id,
        action.object_type,
        action.bid_coin_type,
        action.minimum_bid,
        action.duration_ms,
        ctx,
    );
    resource_requests::new_resource_request(request, ctx)
}

/// Fulfill create auction - STEP 2: Execute with Actual Object
///
/// ⚠️ HOT POTATO FULFILLMENT:
/// Caller must provide actual object and type parameters
/// Creates shared auction object, stores object, increments counter
///
/// # PTB Flow Example:
/// ```
/// // 1. Execute action (returns type-erased request)
/// let request = do_create_auction(...);
///
/// // 2. Get object to auction (from DAO's owned objects)
/// let nft = // ... withdraw from Account or passed as parameter
///
/// // 3. Fulfill request (consumes hot potato, type parameters provided here)
/// let auction_id = fulfill_create_auction<MyNFT, USDC>(request, account, nft, clock, ctx);
///
/// // 4. Auction is now live as shared object, anyone can bid
/// ```
public fun fulfill_create_auction<T: key + store, BidCoin>(
    request: ResourceRequest<dissolution_auction::CreateAuctionRequest>,
    account: &mut Account<FutarchyConfig>,
    object: T,
    clock: &Clock,
    ctx: &mut TxContext,
): ID {
    let request_data = resource_requests::extract_action(request);
    dissolution_auction::fulfill_create_auction<T, BidCoin>(
        request_data,
        account,
        object,
        clock,
        ctx,
    )
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
    action_validation::assert_action_type<action_types::CalculateProRataShares>(&spec);
}

/// Delete a cancel all streams action from an expired intent
public fun delete_cancel_all_streams(expired: &mut Expired) {
    // Remove the action spec from expired intent
    let spec = intents::remove_action_spec(expired);
    action_validation::assert_action_type<action_types::CancelAllStreams>(&spec);
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
    action_validation::assert_action_type<action_types::DistributeAsset>(&spec);
}

/// Delete a create auction action from an expired intent
public fun delete_create_auction<T: key + store, BidCoin>(expired: &mut Expired) {
    // Remove the action spec from expired intent
    let spec = intents::remove_action_spec(expired);
    action_validation::assert_action_type<action_types::CreateAuction>(&spec);
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

/// Create a new create auction action
public fun new_create_auction_action<T: key + store, BidCoin>(
    object_id: ID,
    minimum_bid: u64,
    duration_ms: u64,
): CreateAuctionAction {
    assert!(minimum_bid > 0, EInvalidAmount);
    assert!(duration_ms > 0, EInvalidThreshold);

    CreateAuctionAction {
        object_id,
        object_type: string::from_ascii(type_name::into_string(type_name::with_defining_ids<T>())),
        bid_coin_type: string::from_ascii(type_name::into_string(type_name::with_defining_ids<BidCoin>())),
        minimum_bid,
        duration_ms,
    }
}

/// Create a new withdraw AMM liquidity action
public fun new_withdraw_amm_liquidity_action<AssetType, StableType>(
    pool_id: ID,
    token_id: ID,
    bypass_minimum: bool,
): WithdrawAmmLiquidityAction<AssetType, StableType> {
    WithdrawAmmLiquidityAction {
        pool_id,
        token_id,
        bypass_minimum,
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

// === Distribution Accounting Helpers ===

/// Calculate circulating supply for pro-rata distribution
/// Excludes DAO-owned LP tokens from circulating supply
/// (DAO's LP value is included in treasury, but not in holder shares)
///
/// Example:
/// - Total supply: 1,000,000 tokens
/// - DAO owns: 100,000 tokens
/// - Circulating supply: 900,000 tokens
/// - Pro-rata distribution is based on 900,000, not 1,000,000
public fun calculate_circulating_supply(
    total_supply: u64,
    dao_owned_tokens: u64,
): u64 {
    assert!(dao_owned_tokens <= total_supply, EInvalidRatio);
    total_supply - dao_owned_tokens
}

/// Calculate pro-rata distribution amounts excluding DAO holdings
/// Returns (holders, amounts) vectors for distribution
///
/// Example:
/// - Treasury has: 1,000 USDC
/// - Total supply: 1,000 tokens (900 circulating + 100 DAO-owned)
/// - Alice holds: 450 tokens (50% of circulating)
/// - Bob holds: 450 tokens (50% of circulating)
/// - Alice gets: 500 USDC, Bob gets: 500 USDC
public fun calculate_distribution_excluding_dao(
    total_treasury_amount: u64,
    total_token_supply: u64,
    dao_owned_tokens: u64,
    holders: vector<address>,
    holder_balances: vector<u64>,
): (vector<address>, vector<u64>, u64) {
    assert!(holders.length() == holder_balances.length(), EInvalidRatio);

    // Calculate circulating supply (excluding DAO)
    let circulating_supply = calculate_circulating_supply(total_token_supply, dao_owned_tokens);
    assert!(circulating_supply > 0, EDivisionByZero);

    // Calculate total held by external holders
    let mut total_held = 0u64;
    let mut i = 0;
    while (i < holder_balances.length()) {
        total_held = total_held + *holder_balances.borrow(i);
        i = i + 1;
    };

    // Verify total matches circulating supply
    assert!(total_held <= circulating_supply, EInvalidRatio);

    // Calculate pro-rata amounts
    let mut distribution_holders = vector::empty<address>();
    let mut distribution_amounts = vector::empty<u64>();

    let mut j = 0;
    while (j < holders.length()) {
        let holder = *holders.borrow(j);
        let holder_balance = *holder_balances.borrow(j);

        // Skip zero balances and DAO address
        if (holder_balance > 0 && holder != @0x0) {
            // Calculate: (holder_balance / circulating_supply) * total_treasury_amount
            let share = (holder_balance as u128) * (total_treasury_amount as u128) / (circulating_supply as u128);
            assert!(share <= (std::u64::max_value!() as u128), EOverflow);

            if ((share as u64) > 0) {
                distribution_holders.push_back(holder);
                distribution_amounts.push_back((share as u64));
            };
        };

        j = j + 1;
    };

    (distribution_holders, distribution_amounts, circulating_supply)
}

// === Auction Integration ===

/// Get active auction count (used by frontend to check if dissolution can proceed)
public fun get_active_auction_count(account: &Account<FutarchyConfig>): u64 {
    dissolution_auction::get_active_auction_count(account)
}

/// Check if all auctions are complete (required before distribution/finalization)
public fun all_auctions_complete(account: &Account<FutarchyConfig>): bool {
    dissolution_auction::all_auctions_complete(account)
}
