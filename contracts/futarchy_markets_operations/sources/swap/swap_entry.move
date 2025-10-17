// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

/// User-facing swap API with auto-arbitrage
///
/// This is where users enter the system. Provides entry functions that:
/// - Execute user swaps
/// - Automatically run arbitrage with the output
/// - Return combined results to maximize value
///
/// Based on Solana futarchy pattern: user swap → auto arb with output → return combined result
///
/// **Incomplete Set Handling:**
/// All spot swaps transfer incomplete sets (ConditionalMarketBalance) directly to recipient.
/// Balance object has Display metadata so shows as basic NFT in wallets.
/// User owns the balance immediately and can redeem after proposal resolves.
/// No wrapper, no shared registry, no crankers - users control their own positions.
///
/// **Entry Functions:**
///
/// **Spot swaps (aggregators/DCA compatible):**
/// 1. swap_spot_stable_to_asset - Returns profit coins + balance object to recipient
/// 2. swap_spot_asset_to_stable - Returns profit coins + balance object to recipient
///
/// Output coins and balance objects transferred directly to recipient (shows as NFT in wallet).
/// Supports DCA bots calling on behalf of users.

module futarchy_markets_operations::swap_entry;

use futarchy_markets_core::arbitrage;
use futarchy_markets_core::proposal::{Self, Proposal};
use futarchy_markets_core::swap_core;
use futarchy_markets_core::unified_spot_pool::{Self, UnifiedSpotPool};
use futarchy_markets_operations::no_arb_guard;
use futarchy_markets_primitives::coin_escrow::{Self, TokenEscrow};
use futarchy_markets_primitives::conditional_balance::{Self, ConditionalMarketBalance};
use futarchy_markets_primitives::market_state;
use std::option;
use sui::clock::Clock;
use sui::coin::{Self, Coin};
use sui::object;
use sui::transfer;

// === Errors ===
const EZeroAmount: u64 = 0;
const EProposalNotLive: u64 = 1;

// === Constants ===
const STATE_TRADING: u8 = 2; // Must match proposal.move

// === Spot Swaps with Auto-Arb ===

/// Swap stable → asset in spot market with automatic arbitrage
///
/// **DCA BOT & AGGREGATOR COMPATIBLE** - Supports auto-merge and flexible return modes
///
/// # Arguments
/// * `existing_balance_opt` - Optional balance to merge into (DCA bots: pass previous balance)
/// * `return_balance` - If true: return balance to caller. If false: transfer to recipient
///
/// # Returns
/// * `Coin<AssetType>` - Profit in asset
/// * `option::Option<ConditionalMarketBalance>` - Dust balance (Some if return_balance=true, None otherwise)
///
/// # Use Cases
///
/// **Regular User (one swap):**
/// ```typescript
/// tx.moveCall({
///   arguments: [..., recipient, null, false, ...] // Transfer balance to recipient
/// });
/// ```
///
/// **DCA Bot (100 swaps → 1 NFT):**
/// ```typescript
/// let balance = null;
/// for (let i = 0; i < 100; i++) {
///   const [assetOut, balanceOpt] = tx.moveCall({
///     arguments: [..., botAddress, balance, true, ...] // Return balance to accumulate
///   });
///   balance = balanceOpt;
/// }
/// tx.transferObjects([balance], user); // Final: 1 NFT with all dust!
/// ```
public fun swap_spot_stable_to_asset<AssetType, StableType>(
    spot_pool: &mut UnifiedSpotPool<AssetType, StableType>,
    proposal: &mut Proposal<AssetType, StableType>,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    stable_in: Coin<StableType>,
    min_asset_out: u64,
    recipient: address,
    mut existing_balance_opt: option::Option<ConditionalMarketBalance<AssetType, StableType>>,
    return_balance: bool,
    clock: &Clock,
    ctx: &mut TxContext,
): (Coin<AssetType>, option::Option<ConditionalMarketBalance<AssetType, StableType>>) {
    let amount_in = stable_in.value();
    assert!(amount_in > 0, EZeroAmount);

    // Step 1: Normal swap in spot (user pays fees)
    let asset_out = unified_spot_pool::swap_stable_for_asset(
        spot_pool,
        stable_in,
        min_asset_out,
        clock,
        ctx,
    );

    // Step 2: Auto-arb if proposal is live (uses swap output as budget)
    let proposal_state = proposal::state(proposal);

    if (proposal_state == STATE_TRADING) {
        // Begin swap session for conditional swaps
        let session = swap_core::begin_swap_session(escrow);

        // Execute optimal arb bidirectionally with auto-merge support
        let (
            stable_profit,
            mut asset_with_profit,
            final_balance,
        ) = arbitrage::execute_optimal_spot_arbitrage<AssetType, StableType>(
            spot_pool,
            escrow,
            &session,
            coin::zero<StableType>(ctx), // Don't have stable
            asset_out, // Have asset from swap
            0, // min_profit_threshold (any profit is good)
            recipient, // Who owns dust and receives complete sets
            existing_balance_opt, // Pass existing balance for auto-merge
            clock,
            ctx,
        );

        // Finalize swap session
        swap_core::finalize_swap_session(session, proposal, escrow, clock);

        // Ensure no-arb band is respected after auto-arb
        let market_state = coin_escrow::get_market_state(escrow);
        let pools = market_state::borrow_amm_pools(market_state);
        no_arb_guard::ensure_spot_in_band(spot_pool, pools);

        // If we got stable profit (arb was more profitable in opposite direction),
        // swap it to asset to give user maximum value in their desired token
        if (stable_profit.value() > 0) {
            let extra_asset = unified_spot_pool::swap_stable_for_asset(
                spot_pool,
                stable_profit,
                0, // Accept any amount (already profitable from arb)
                clock,
                ctx,
            );
            coin::join(&mut asset_with_profit, extra_asset);
        } else {
            coin::destroy_zero(stable_profit);
        };

        // Handle balance based on return_balance flag
        if (return_balance) {
            // DCA bot mode: Return balance to caller for accumulation
            (asset_with_profit, option::some(final_balance))
        } else {
            // Regular user mode: Transfer balance to recipient
            transfer::public_transfer(final_balance, recipient);
            transfer::public_transfer(asset_with_profit, recipient);
            (coin::zero<AssetType>(ctx), option::none())
        }
    } else {
        // No arb (proposal not trading) - just handle swap output and existing balance
        if (return_balance) {
            // Return coins and existing balance (if any) to caller
            (asset_out, existing_balance_opt)
        } else {
            // Transfer everything to recipient
            transfer::public_transfer(asset_out, recipient);
            if (option::is_some(&existing_balance_opt)) {
                transfer::public_transfer(option::extract(&mut existing_balance_opt), recipient);
            };
            option::destroy_none(existing_balance_opt);
            (coin::zero<AssetType>(ctx), option::none())
        }
    }
}

/// Swap asset → stable in spot market with automatic arbitrage
///
/// **DCA BOT & AGGREGATOR COMPATIBLE** - Supports auto-merge and flexible return modes
///
/// # Arguments
/// * `existing_balance_opt` - Optional balance to merge into (DCA bots: pass previous balance)
/// * `return_balance` - If true: return balance to caller. If false: transfer to recipient
///
/// # Returns
/// * `Coin<StableType>` - Profit in stable
/// * `option::Option<ConditionalMarketBalance>` - Dust balance (Some if return_balance=true, None otherwise)
///
/// # Use Cases
///
/// **Regular User (one swap):**
/// ```typescript
/// tx.moveCall({
///   arguments: [..., recipient, null, false, ...] // Transfer balance to recipient
/// });
/// ```
///
/// **DCA Bot (100 swaps → 1 NFT):**
/// ```typescript
/// let balance = null;
/// for (let i = 0; i < 100; i++) {
///   const [stableOut, balanceOpt] = tx.moveCall({
///     arguments: [..., botAddress, balance, true, ...] // Return balance to accumulate
///   });
///   balance = balanceOpt;
/// }
/// tx.transferObjects([balance], user); // Final: 1 NFT with all dust!
/// ```
public fun swap_spot_asset_to_stable<AssetType, StableType>(
    spot_pool: &mut UnifiedSpotPool<AssetType, StableType>,
    proposal: &mut Proposal<AssetType, StableType>,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    asset_in: Coin<AssetType>,
    min_stable_out: u64,
    recipient: address,
    mut existing_balance_opt: option::Option<ConditionalMarketBalance<AssetType, StableType>>,
    return_balance: bool,
    clock: &Clock,
    ctx: &mut TxContext,
): (Coin<StableType>, option::Option<ConditionalMarketBalance<AssetType, StableType>>) {
    let amount_in = asset_in.value();
    assert!(amount_in > 0, EZeroAmount);

    // Step 1: Normal swap in spot (user pays fees)
    let stable_out = unified_spot_pool::swap_asset_for_stable(
        spot_pool,
        asset_in,
        min_stable_out,
        clock,
        ctx,
    );

    // Step 2: Auto-arb if proposal is live
    let proposal_state = proposal::state(proposal);

    if (proposal_state == STATE_TRADING) {
        let session = swap_core::begin_swap_session(escrow);

        // Execute optimal arb bidirectionally with auto-merge support
        let (
            mut stable_with_profit,
            asset_profit,
            final_balance,
        ) = arbitrage::execute_optimal_spot_arbitrage<AssetType, StableType>(
            spot_pool,
            escrow,
            &session,
            stable_out, // Have stable from swap
            coin::zero<AssetType>(ctx), // Don't have asset
            0, // min_profit_threshold
            recipient, // Who owns dust
            existing_balance_opt, // Pass existing balance for auto-merge
            clock,
            ctx,
        );

        swap_core::finalize_swap_session(session, proposal, escrow, clock);

        // Ensure no-arb band is respected after auto-arb
        let market_state = coin_escrow::get_market_state(escrow);
        let pools = market_state::borrow_amm_pools(market_state);
        no_arb_guard::ensure_spot_in_band(spot_pool, pools);

        // If we got asset profit (arb was more profitable in opposite direction),
        // swap it to stable to give user maximum value in their desired token
        if (asset_profit.value() > 0) {
            let extra_stable = unified_spot_pool::swap_asset_for_stable(
                spot_pool,
                asset_profit,
                0, // Accept any amount (already profitable from arb)
                clock,
                ctx,
            );
            coin::join(&mut stable_with_profit, extra_stable);
        } else {
            coin::destroy_zero(asset_profit);
        };

        // Handle balance based on return_balance flag
        if (return_balance) {
            // DCA bot mode: Return balance to caller for accumulation
            (stable_with_profit, option::some(final_balance))
        } else {
            // Regular user mode: Transfer balance to recipient
            transfer::public_transfer(final_balance, recipient);
            transfer::public_transfer(stable_with_profit, recipient);
            (coin::zero<StableType>(ctx), option::none())
        }
    } else {
        // No arb (proposal not trading) - just handle swap output and existing balance
        if (return_balance) {
            // Return coins and existing balance (if any) to caller
            (stable_out, existing_balance_opt)
        } else {
            // Transfer everything to recipient
            transfer::public_transfer(stable_out, recipient);
            if (option::is_some(&existing_balance_opt)) {
                transfer::public_transfer(option::extract(&mut existing_balance_opt), recipient);
            };
            option::destroy_none(existing_balance_opt);
            (coin::zero<StableType>(ctx), option::none())
        }
    }
}

// === CONDITIONAL SWAP BATCHING ===
//
// PTB-based conditional swap batching for advanced traders.
// Allows chaining multiple conditional swaps, then settling at the end.
//
// Hot potato pattern ensures complete set closure.
//
// Flow:
// 1. begin_conditional_swaps() → creates ConditionalSwapBatch hot potato
// 2. swap_in_batch() × N → accumulates swaps in balance (chainable)
// 3. finalize_conditional_swaps() → closes complete sets, returns profit + incomplete set balance
//
// ============================================================================

/// Hot potato for batching conditional swaps in PTB
/// NO abilities = MUST be consumed in same transaction
///
/// This forces users to call finalize_conditional_swaps() at end of PTB,
/// which closes complete sets and returns profit. Cannot store between transactions.
public struct ConditionalSwapBatch<phantom AssetType, phantom StableType> {
    balance: ConditionalMarketBalance<AssetType, StableType>,
    market_id: ID,
}

/// Step 1: Begin a conditional swap batch (returns hot potato)
///
/// Creates hot potato with empty balance. Must be consumed by finalize_conditional_swaps().
///
/// # Example PTB Flow
/// ```typescript
/// const batch = tx.moveCall({
///   target: '${PKG}::swap_entry::begin_conditional_swaps',
///   typeArguments: [AssetType, StableType],
///   arguments: [escrow]
/// });
///
/// // Chain swaps...
/// const batch2 = tx.moveCall({
///   target: '${PKG}::swap_entry::swap_in_batch',
///   arguments: [batch, session, escrow, ...] // Returns modified hot potato
/// });
///
/// // Must finalize at end
/// tx.moveCall({
///   target: '${PKG}::swap_entry::finalize_conditional_swaps',
///   arguments: [batch2, ...]
/// });
/// ```
public fun begin_conditional_swaps<AssetType, StableType>(
    escrow: &TokenEscrow<AssetType, StableType>,
    ctx: &mut TxContext,
): ConditionalSwapBatch<AssetType, StableType> {
    // Get market info
    let market_state = coin_escrow::get_market_state(escrow);
    market_state::assert_trading_active(market_state);

    let market_id = market_state::market_id(market_state);
    let outcome_count = market_state::outcome_count(market_state);

    // Create empty balance
    let balance = conditional_balance::new<AssetType, StableType>(
        market_id,
        (outcome_count as u8),
        ctx,
    );

    // Return hot potato (NO abilities = must consume)
    ConditionalSwapBatch {
        balance,
        market_id,
    }
}

/// Step 2: Swap in batch (consumes and returns hot potato)
///
/// Wraps coin → swaps in balance → unwraps to coin → returns modified hot potato
///
/// Can be called N times in a PTB to chain swaps across multiple outcomes.
/// Each call mutates the balance in the hot potato and returns it for next call.
///
/// # Arguments
/// * `batch` - Hot potato from begin_conditional_swaps or previous swap_in_batch
/// * `session` - SwapSession hot potato (from swap_core::begin_swap_session)
/// * `outcome_index` - Which outcome to swap in (0, 1, 2, ...)
/// * `coin_in` - Input coin (conditional asset or stable)
/// * `is_asset_to_stable` - true = swap asset→stable, false = swap stable→asset
/// * `min_amount_out` - Minimum output amount (slippage protection)
///
/// # Returns
/// Modified hot potato (pass to next swap_in_batch or finalize_conditional_swaps)
///
/// # Type Parameters
/// * `InputCoin` - Type of input conditional coin
/// * `OutputCoin` - Type of output conditional coin
///
/// # Example
/// ```typescript
/// // Swap in outcome 0: stable → asset
/// let batch = tx.moveCall({
///   target: '${PKG}::swap_entry::swap_in_batch',
///   typeArguments: [AssetType, StableType, Cond0Stable, Cond0Asset],
///   arguments: [batch, session, escrow, 0, stableCoin, false, minOut, clock]
/// });
///
/// // Swap in outcome 1: asset → stable
/// batch = tx.moveCall({
///   target: '${PKG}::swap_entry::swap_in_batch',
///   typeArguments: [AssetType, StableType, Cond1Asset, Cond1Stable],
///   arguments: [batch, session, escrow, 1, assetCoin, true, minOut, clock]
/// });
/// ```
public fun swap_in_batch<AssetType, StableType, InputCoin, OutputCoin>(
    mut batch: ConditionalSwapBatch<AssetType, StableType>,
    session: &swap_core::SwapSession,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    outcome_index: u8,
    coin_in: Coin<InputCoin>,
    is_asset_to_stable: bool,
    min_amount_out: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): (ConditionalSwapBatch<AssetType, StableType>, Coin<OutputCoin>) {
    let amount_in = coin_in.value();
    assert!(amount_in > 0, EZeroAmount);

    // Validate market still active
    let market_state = coin_escrow::get_market_state(escrow);
    market_state::assert_trading_active(market_state);

    // Wrap coin → balance
    conditional_balance::wrap_coin<AssetType, StableType, InputCoin>(
        &mut batch.balance,
        escrow,
        coin_in,
        outcome_index,
        !is_asset_to_stable, // is_asset = opposite of swap direction
    );

    // Swap in balance (balance-based swap works for ANY outcome count!)
    let amount_out = if (is_asset_to_stable) {
        swap_core::swap_balance_asset_to_stable<AssetType, StableType>(
            session,
            escrow,
            &mut batch.balance,
            outcome_index,
            amount_in,
            min_amount_out,
            clock,
            ctx,
        )
    } else {
        swap_core::swap_balance_stable_to_asset<AssetType, StableType>(
            session,
            escrow,
            &mut batch.balance,
            outcome_index,
            amount_in,
            min_amount_out,
            clock,
            ctx,
        )
    };

    // Unwrap balance → coin
    let coin_out = conditional_balance::unwrap_to_coin<AssetType, StableType, OutputCoin>(
        &mut batch.balance,
        escrow,
        outcome_index,
        is_asset_to_stable, // is_asset = swap direction
        ctx,
    );

    // Return modified hot potato and output coin
    (batch, coin_out)
}

/// Step 3: Finalize conditional swaps (consumes hot potato)
///
/// Closes complete sets from accumulated balance, withdraws spot coins as profit,
/// and transfers to recipient. Returns remaining incomplete set as ConditionalMarketBalance
/// for professional traders to manage their own positions.
///
/// This MUST be called at end of PTB to consume hot potato.
///
/// # Arguments
/// * `batch` - Hot potato from swap_in_batch (final state)
/// * `spot_pool` - Spot pool (for no-arb guard, NOT for swapping)
/// * `proposal` - Proposal object
/// * `escrow` - Token escrow
/// * `session` - SwapSession hot potato (consumed here)
/// * `recipient` - Who receives profit and incomplete set
/// * `clock` - Clock object
///
/// # Flow
/// 1. Find minimum balance across outcomes (complete set limit)
/// 2. Burn complete sets → withdraw spot coins
/// 3. Transfer profit to recipient
/// 4. Transfer incomplete set balance to recipient (for pro traders to manage)
/// 5. Finalize session (updates early resolve metrics ONCE)
///
/// # Example PTB
/// ```typescript
/// tx.moveCall({
///   target: '${PKG}::swap_entry::finalize_conditional_swaps',
///   typeArguments: [AssetType, StableType],
///   arguments: [batch, spot_pool, proposal, escrow, session, recipient, clock]
/// });
/// ```
public fun finalize_conditional_swaps<AssetType, StableType>(
    batch: ConditionalSwapBatch<AssetType, StableType>,
    spot_pool: &mut UnifiedSpotPool<AssetType, StableType>,
    proposal: &mut Proposal<AssetType, StableType>,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    session: swap_core::SwapSession,
    recipient: address,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Destructure hot potato
    let ConditionalSwapBatch { mut balance, market_id: _ } = batch;

    // Find minimum balances (complete set limits)
    let min_asset = conditional_balance::find_min_balance(&balance, true);
    let min_stable = conditional_balance::find_min_balance(&balance, false);

    // Burn complete sets and withdraw spot coins
    let spot_asset = if (min_asset > 0) {
        arbitrage::burn_complete_set_and_withdraw_asset<AssetType, StableType>(
            &mut balance,
            escrow,
            min_asset,
            ctx,
        )
    } else {
        coin::zero<AssetType>(ctx)
    };

    let spot_stable = if (min_stable > 0) {
        arbitrage::burn_complete_set_and_withdraw_stable<AssetType, StableType>(
            &mut balance,
            escrow,
            min_stable,
            ctx,
        )
    } else {
        coin::zero<StableType>(ctx)
    };

    // Finalize session (updates early resolve metrics ONCE for entire batch)
    swap_core::finalize_swap_session(session, proposal, escrow, clock);

    // Ensure no-arb band is respected after batch swaps
    let market_state = coin_escrow::get_market_state(escrow);
    let pools = market_state::borrow_amm_pools(market_state);
    no_arb_guard::ensure_spot_in_band(spot_pool, pools);

    // Transfer spot profit to recipient
    if (spot_asset.value() > 0) {
        transfer::public_transfer(spot_asset, recipient);
    } else {
        coin::destroy_zero(spot_asset);
    };

    if (spot_stable.value() > 0) {
        transfer::public_transfer(spot_stable, recipient);
    } else {
        coin::destroy_zero(spot_stable);
    };

    // Transfer incomplete set balance to recipient (for pro traders to manage)
    // They can choose to:
    // - Hold and wait for proposal resolution
    // - Rebalance positions across outcomes
    // - Sell to market makers
    // - Store in registry themselves if desired
    transfer::public_transfer(balance, recipient);
}
