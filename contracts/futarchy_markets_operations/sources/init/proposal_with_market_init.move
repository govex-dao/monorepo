// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

/// Proposal creation with integrated market initialization strategies
///
/// This module enables DAOs to atomically seed prediction markets with asymmetric liquidity
/// during proposal creation. This creates initial price signals (e.g., "we think this will pass")
/// while maintaining front-run protection via single-transaction PTB execution.
///
/// ## Market Initialization Strategies
///
/// ### 1. Conditional Raise (Mint → Swap → Deposit)
/// - **Purpose:** Simulate raising capital by selling DAO tokens in a conditional market
/// - **Flow:** Mint asset tokens → Sell in YES market → Get stable coins → Deposit to treasury
/// - **Effect:** Makes YES tokens cheaper (bearish on YES = bullish on proposal passing)
/// - **Use Case:** DAO wants to signal confidence that proposal will pass and raise funds if it does
///
/// ### 2. Conditional Buyback (Withdraw → Swap → Burn/Deposit)
/// - **Purpose:** Simulate buying back DAO tokens across multiple outcome markets
/// - **Flow:** Withdraw stable → Buy asset tokens in outcome AMMs → Burn or vault the assets
/// - **Effect:** Makes asset tokens more expensive in chosen outcomes (bullish on those outcomes)
/// - **Use Case:** DAO wants to signal which outcomes it prefers with treasury funds
/// - **Flexibility:** Per-outcome amounts via `vector<u64>` (e.g., [0, 1000, 500] for 3 outcomes)
///
/// ## Atomic Execution (Front-Run Protection)
///
/// All operations happen in a single PTB transaction:
/// 1. Create proposal (PREMARKET state)
/// 2. Create escrow and AMM pools
/// 3. Execute Intent (mint/withdraw) → get coins
/// 4. Execute market init strategy → conditional swaps
/// 5. Return proceeds to vault
/// 6. Finalize proposal (→ REVIEW state)
///
/// No intermediate state is exposed, preventing sandwich attacks or front-running.
///
/// ## Constraint: Zero Review Period Only
///
/// **Market init proposals ONLY work with `review_period_ms = 0`**
///
/// ```move
/// assert!(review_period_ms == 0, EMarketInitRequiresZeroReview);
/// ```
///
/// **Why this constraint:**
/// - ✅ Atomic execution (create + init + trading in one PTB)
/// - ✅ Front-run proof (everything happens in one transaction)
/// - ✅ No queue blocking issues
/// - ✅ No commit-reveal complexity
/// - ✅ No SEAL dependencies
/// - ✅ No timing edge cases
///
/// **Trade-off:**
/// - No premarket research period
/// - Traders must analyze quickly or after market starts
/// - Worth it for simplicity and security
///
/// **Note:** DAOs can set high queue fees (e.g., $1k min_fee) to keep the queue clear,
/// making the reservation slot more often available for market init proposals with premarket.
///
/// ## PTB Example: Conditional Raise (Mint + Swap + Deposit)
///
/// ```typescript
/// const tx = new Transaction();
///
/// // 0. Get market_op_review_period_ms from DAO config (not regular review period!)
/// const marketOpReviewPeriod = dao_config.market_op_review_period_ms();
///
/// // 1. Create proposal in PREMARKET state
/// // IMPORTANT: Use market_op_review_period_ms as the review_period parameter!
/// const proposalId = tx.moveCall({
///   target: 'futarchy_markets::proposal::new_premarket',
///   arguments: [
///     /* ... other params ... */,
///     marketOpReviewPeriod,  // ← Use market op review period, not regular!
///     /* ... */
///   ],
/// });
///
/// // 2. Create escrow for market
/// const escrow = tx.moveCall({
///   target: 'futarchy_markets::proposal::create_escrow_for_market',
///   arguments: [proposalId, clock],
/// });
///
/// // 3. Register treasury caps and create AMM pools
/// // ... (existing liquidity initialization flow)
///
/// // 4. Execute mint Intent to get asset coins
/// const mintedCoins = tx.moveCall({
///   target: 'account_actions::currency::execute_mint', // or similar
///   arguments: [account, mintAmount, /* ... */],
/// });
///
/// // 5. Execute conditional raise strategy
/// const stableCoins = tx.moveCall({
///   target: 'futarchy_markets::proposal_with_market_init::execute_raise_on_proposal',
///   arguments: [proposalId, escrow, mintedCoins, raiseConfig, clock],
///   typeArguments: [AssetType, StableType, AssetConditionalCoin, StableConditionalCoin],
/// });
///
/// // 6. Deposit stable coins back to DAO vault
/// tx.moveCall({
///   target: 'account_actions::vault::do_deposit',
///   arguments: [account, stableCoins, auth],
/// });
///
/// // 7. Finalize proposal (transitions to REVIEW state)
/// tx.moveCall({
///   target: 'futarchy_markets::proposal::finalize_market_setup',
///   arguments: [proposalId, /* ... */],
/// });
/// ```
///
/// ## PTB Example: Conditional Buyback (Withdraw + Swap + Burn/Deposit)
///
/// ```typescript
/// const tx = new Transaction();
///
/// // Steps 1-3: Same as above (create proposal, escrow, pools)
///
/// // 4. Execute withdraw Intent to get stable coins
/// const withdrawnStable = tx.moveCall({
///   target: 'account_actions::vault::execute_withdraw',
///   arguments: [account, withdrawAmount, /* ... */],
/// });
///
/// // 5. Execute conditional buyback strategy
/// const assetCoins = tx.moveCall({
///   target: 'futarchy_markets::proposal_with_market_init::execute_buyback_on_proposal',
///   arguments: [proposalId, escrow, withdrawnStable, buybackConfig, clock],
///   typeArguments: [AssetType, StableType, AssetConditionalCoin, StableConditionalCoin],
/// });
///
/// // 6. Merge and burn/deposit asset coins
/// const mergedAsset = tx.moveCall({
///   target: 'futarchy_markets::proposal_with_market_init::merge_asset_coins',
///   arguments: [assetCoins],
/// });
///
/// tx.moveCall({
///   target: 'account_actions::currency::burn', // or deposit back to vault
///   arguments: [account, mergedAsset, /* ... */],
/// });
///
/// // 7. Finalize proposal
/// tx.moveCall({
///   target: 'futarchy_markets::proposal::finalize_market_setup',
///   arguments: [proposalId, /* ... */],
/// });
/// ```
module futarchy_markets_operations::proposal_with_market_init;

use futarchy_markets_core::market_init_helpers;
use futarchy_markets_core::market_init_strategies::{
    Self,
    ConditionalRaiseConfig,
    ConditionalBuybackConfig
};
use futarchy_markets_core::proposal::{Self, Proposal};
use futarchy_markets_primitives::coin_escrow::{Self, TokenEscrow};
use sui::clock::Clock;
use sui::coin::{Self, Coin};

// === Errors ===
const EInvalidRaiseConfig: u64 = 0;
const EInvalidBuybackConfig: u64 = 1;

// === Conditional Raise Integration ===

/// Execute conditional raise strategy during proposal creation
///
/// This function should be called AFTER the market AMM pools are created but BEFORE
/// the proposal transitions to REVIEW state.
///
/// Flow:
/// 1. Caller has already built and executed mint Intent → has minted coins
/// 2. This function takes those coins and executes conditional raise strategy
/// 3. Strategy returns STABLE coins which caller must deposit back to DAO vault
///
/// ## Parameters
/// - `proposal`: The proposal (must be in PREMARKET state, after AMMs created)
/// - `escrow`: Token escrow for the proposal
/// - `minted_coins`: Asset coins obtained from executing mint Intent
/// - `config`: Conditional raise configuration
/// - `clock`: For timestamp operations
/// - `ctx`: Transaction context
///
/// ## Returns
/// - Stable coins to be deposited back to DAO vault (caller's responsibility)
public fun execute_raise_on_proposal<
    AssetType,
    StableType,
    AssetConditionalCoin,
    StableConditionalCoin,
>(
    proposal: &mut Proposal<AssetType, StableType>,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    minted_coins: Coin<AssetType>,
    config: ConditionalRaiseConfig,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<StableType> {
    let outcome_count = proposal::outcome_count(proposal);

    // Validate config before execution
    assert!(
        market_init_helpers::validate_raise_config(&config, outcome_count),
        EInvalidRaiseConfig,
    );

    // Execute the strategy
    market_init_strategies::execute_conditional_raise<
        AssetType,
        StableType,
        AssetConditionalCoin,
        StableConditionalCoin,
    >(
        proposal,
        escrow,
        minted_coins,
        config,
        outcome_count,
        clock,
        ctx,
    )
}

// === Conditional Buyback Integration ===

/// Execute conditional buyback strategy during proposal creation
///
/// This function should be called AFTER the market AMM pools are created but BEFORE
/// the proposal transitions to REVIEW state.
///
/// Flow:
/// 1. Caller has already built and executed withdraw Intent → has withdrawn stable
/// 2. This function takes those coins and executes conditional buyback strategy
/// 3. Strategy returns ASSET coins which caller can burn or deposit back to vault
///
/// ## Parameters
/// - `proposal`: The proposal (must be in PREMARKET state, after AMMs created)
/// - `escrow`: Token escrow for the proposal
/// - `withdrawn_stable`: Stable coins obtained from executing withdraw Intent
/// - `config`: Conditional buyback configuration (per-outcome amounts)
/// - `clock`: For timestamp operations
/// - `ctx`: Transaction context
///
/// ## Returns
/// - Vector of asset coins (one per outcome, some may be zero-value)
/// - Caller can burn these or deposit to vault
public fun execute_buyback_on_proposal<
    AssetType,
    StableType,
    AssetConditionalCoin,
    StableConditionalCoin,
>(
    proposal: &mut Proposal<AssetType, StableType>,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    withdrawn_stable: Coin<StableType>,
    config: ConditionalBuybackConfig,
    clock: &Clock,
    ctx: &mut TxContext,
): vector<Coin<AssetType>> {
    let outcome_count = proposal::outcome_count(proposal);

    // Validate config before execution
    assert!(
        market_init_helpers::validate_buyback_config(&config, outcome_count),
        EInvalidBuybackConfig,
    );

    // Execute the strategy
    market_init_strategies::execute_conditional_buyback<
        AssetType,
        StableType,
        AssetConditionalCoin,
        StableConditionalCoin,
    >(
        proposal,
        escrow,
        withdrawn_stable,
        config,
        outcome_count,
        clock,
        ctx,
    )
}

// === Helper: Merge Asset Coins ===

/// Helper to merge multiple asset coins into a single coin
///
/// Takes the vector of asset coins returned from buyback and merges them
/// into a single coin for easier handling by caller.
///
/// Uses Sui's built-in `join_vec` method for efficient merging.
public fun merge_asset_coins<AssetType>(
    mut asset_coins: vector<Coin<AssetType>>,
    ctx: &mut TxContext,
): Coin<AssetType> {
    if (asset_coins.is_empty()) {
        asset_coins.destroy_empty();
        return coin::zero<AssetType>(ctx)
    };

    let mut base = asset_coins.pop_back();
    base.join_vec(asset_coins); // Uses Sui's join_vec
    base
}
