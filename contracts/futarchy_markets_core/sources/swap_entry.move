/// User-facing swap API with auto-arbitrage
///
/// This is where users enter the system. Provides entry functions that:
/// - Execute user swaps
/// - Automatically run arbitrage with the output
/// - Return combined results to maximize value
///
/// Based on Solana futarchy pattern: user swap → auto arb with output → return combined result
///
/// **4 entry functions:**
///
/// **Spot swaps (for aggregators/DCA):**
/// 1. swap_spot_stable_to_asset - Aggregator wrapper with `recipient` parameter
/// 2. swap_spot_asset_to_stable - Aggregator wrapper with `recipient` parameter
///    - Dust deposited to registry owned by recipient
///    - Output transferred to recipient (not caller)
///    - Supports DCA bots calling on behalf of users
///
/// **Conditional swaps (for direct traders):**
/// 3. swap_conditional_stable_to_asset - Returns everything to caller directly
/// 4. swap_conditional_asset_to_stable - Returns everything to caller directly
///    - No recipient parameter needed (trader is the caller)

module futarchy_markets_core::swap_entry;

use sui::coin::{Self, Coin};
use sui::clock::Clock;
use sui::object;
use sui::transfer;
use futarchy_markets_core::unified_spot_pool::{Self, UnifiedSpotPool};
use futarchy_markets_core::swap_core;
use futarchy_markets_core::proposal::{Self, Proposal};
use futarchy_markets_core::coin_escrow::{Self, TokenEscrow};
use futarchy_markets_core::conditional_balance::{Self, ConditionalMarketBalance};
use futarchy_markets_core::market_state;
use futarchy_markets_core::arbitrage;
use futarchy_markets_core::no_arb_guard;
use std::option;

// === Errors ===
const EZeroAmount: u64 = 0;
const EProposalNotLive: u64 = 1;

// === Constants ===
const STATE_TRADING: u8 = 2;  // Must match proposal.move

// === Spot Swaps with Auto-Arb ===

/// Swap stable → asset in spot market with automatic arbitrage
///
/// DEX AGGREGATOR WRAPPER: Deposits dust to registry for composability
///
/// Flow:
/// 1. Swap stable → asset in spot (user pays fees)
/// 2. If proposal is live: execute arbitrage (returns profit + dust)
/// 3. Deposit any dust conditional coins to registry (owned by recipient)
/// 4. Return: output + profit to recipient
///
/// For DEX aggregators and DCA bots - dust is stored in registry,
/// claimable after proposal resolves via permissionless crank.
///
/// The recipient parameter allows callers (e.g., DCA bots) to specify
/// the actual end user who should receive output coins and own the dust.
public entry fun swap_spot_stable_to_asset<AssetType, StableType>(
    spot_pool: &mut UnifiedSpotPool<AssetType, StableType>,
    proposal: &mut Proposal<AssetType, StableType>,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    stable_in: Coin<StableType>,
    min_asset_out: u64,
    recipient: address,  // Who receives output and owns dust (for aggregator compatibility)
    clock: &Clock,
    ctx: &mut TxContext,
) {
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

        // Execute optimal arb bidirectionally (dust deposited to registry)
        // Pass asset_out (what we have) and zero stable (what we don't have)
        // Note: Arbitrage handles registry access internally from spot_pool
        let (stable_profit, mut asset_with_profit, dust_opt) = arbitrage::execute_optimal_spot_arbitrage<
            AssetType,
            StableType,
        >(
            spot_pool,
            escrow,
            &session,
            coin::zero<StableType>(ctx),  // Don't have stable
            asset_out,                     // Have asset from swap
            0,  // min_profit_threshold (any profit is good)
            recipient,                     // Who owns dust and receives complete sets
            false,                         // Don't return dust balance (goes to registry)
            clock,
            ctx,
        );
        // Dust goes to registry, so option should be None
        option::destroy_none(dust_opt);

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
                0,  // Accept any amount (already profitable from arb)
                clock,
                ctx,
            );
            coin::join(&mut asset_with_profit, extra_asset);
        } else {
            coin::destroy_zero(stable_profit);
        };

        // Transfer asset + profit to recipient (all in asset)
        transfer::public_transfer(asset_with_profit, recipient);
    } else {
        // No arb, just return swap output to recipient
        transfer::public_transfer(asset_out, recipient);
    };
}

/// Swap asset → stable in spot market with automatic arbitrage
///
/// DEX AGGREGATOR WRAPPER: Deposits dust to registry for composability
///
/// Flow:
/// 1. Swap asset → stable in spot (user pays fees)
/// 2. If proposal is live: check arb opportunity using swap OUTPUT
/// 3. If profitable: execute arb (feeless) using optimal amount from output
/// 4. Return: remaining output + arb profit to recipient
///
/// The recipient parameter allows callers (e.g., DCA bots) to specify
/// the actual end user who should receive output coins and own the dust.
public entry fun swap_spot_asset_to_stable<AssetType, StableType>(
    spot_pool: &mut UnifiedSpotPool<AssetType, StableType>,
    proposal: &mut Proposal<AssetType, StableType>,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    asset_in: Coin<AssetType>,
    min_stable_out: u64,
    recipient: address,  // Who receives output and owns dust (for aggregator compatibility)
    clock: &Clock,
    ctx: &mut TxContext,
) {
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

        // Execute optimal arb bidirectionally (dust deposited to registry)
        // Pass stable_out (what we have) and zero asset (what we don't have)
        // Note: Arbitrage handles registry access internally from spot_pool
        let (mut stable_with_profit, asset_profit, dust_opt) = arbitrage::execute_optimal_spot_arbitrage<
            AssetType,
            StableType,
        >(
            spot_pool,
            escrow,
            &session,
            stable_out,                     // Have stable from swap
            coin::zero<AssetType>(ctx),    // Don't have asset
            0,  // min_profit_threshold
            recipient,                      // Who owns dust and receives complete sets
            false,                          // Don't return dust balance (goes to registry)
            clock,
            ctx,
        );
        // Dust goes to registry, so option should be None
        option::destroy_none(dust_opt);

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
                0,  // Accept any amount (already profitable from arb)
                clock,
                ctx,
            );
            coin::join(&mut stable_with_profit, extra_stable);
        } else {
            coin::destroy_zero(asset_profit);
        };

        // Transfer stable + profit to recipient (all in stable)
        transfer::public_transfer(stable_with_profit, recipient);
    } else {
        // No arb, just return swap output to recipient
        transfer::public_transfer(stable_out, recipient);
    };
}

// === Spot Swaps with Auto-Arb + Dust Return ===

/// Swap stable → asset with auto-arbitrage, returning dust as ConditionalMarketBalance
///
/// Same as swap_spot_stable_to_asset but returns dust as a ConditionalMarketBalance
/// object instead of putting it in the registry. Useful for advanced traders who want
/// to manage their own dust positions.
///
/// Flow:
/// 1. Swap stable → asset in spot (user pays fees)
/// 2. If proposal is live: execute arbitrage
/// 3. Return dust as ConditionalMarketBalance object to recipient
/// 4. Return: output + profit to recipient
public entry fun swap_spot_stable_to_asset_return_dust<AssetType, StableType>(
    spot_pool: &mut UnifiedSpotPool<AssetType, StableType>,
    proposal: &mut Proposal<AssetType, StableType>,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    stable_in: Coin<StableType>,
    min_asset_out: u64,
    recipient: address,
    clock: &Clock,
    ctx: &mut TxContext,
) {
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

    // Step 2: Auto-arb if proposal is live
    let proposal_state = proposal::state(proposal);

    if (proposal_state == STATE_TRADING) {
        let session = swap_core::begin_swap_session(escrow);

        // Execute arbitrage and return dust balance
        let (stable_profit, mut asset_with_profit, mut dust_opt) = arbitrage::execute_optimal_spot_arbitrage<
            AssetType,
            StableType,
        >(
            spot_pool,
            escrow,
            &session,
            coin::zero<StableType>(ctx),
            asset_out,
            0,
            recipient,
            true,  // Return dust as ConditionalMarketBalance
            clock,
            ctx,
        );

        swap_core::finalize_swap_session(session, proposal, escrow, clock);

        let market_state = coin_escrow::get_market_state(escrow);
        let pools = market_state::borrow_amm_pools(market_state);
        no_arb_guard::ensure_spot_in_band(spot_pool, pools);

        // Convert stable profit to asset
        if (stable_profit.value() > 0) {
            let extra_asset = unified_spot_pool::swap_stable_for_asset(
                spot_pool,
                stable_profit,
                0,
                clock,
                ctx,
            );
            coin::join(&mut asset_with_profit, extra_asset);
        } else {
            coin::destroy_zero(stable_profit);
        };

        // Transfer output coins
        transfer::public_transfer(asset_with_profit, recipient);

        // Transfer dust balance if it exists
        if (option::is_some(&dust_opt)) {
            let dust = option::extract(&mut dust_opt);
            transfer::public_transfer(dust, recipient);
        };
        option::destroy_none(dust_opt);
    } else {
        // No arb, just return swap output
        transfer::public_transfer(asset_out, recipient);
    };
}

/// Swap asset → stable with auto-arbitrage, returning dust as ConditionalMarketBalance
///
/// Same as swap_spot_asset_to_stable but returns dust as a ConditionalMarketBalance
/// object instead of putting it in the registry.
public entry fun swap_spot_asset_to_stable_return_dust<AssetType, StableType>(
    spot_pool: &mut UnifiedSpotPool<AssetType, StableType>,
    proposal: &mut Proposal<AssetType, StableType>,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    asset_in: Coin<AssetType>,
    min_stable_out: u64,
    recipient: address,
    clock: &Clock,
    ctx: &mut TxContext,
) {
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

        // Execute arbitrage and return dust balance
        let (mut stable_with_profit, asset_profit, mut dust_opt) = arbitrage::execute_optimal_spot_arbitrage<
            AssetType,
            StableType,
        >(
            spot_pool,
            escrow,
            &session,
            stable_out,
            coin::zero<AssetType>(ctx),
            0,
            recipient,
            true,  // Return dust as ConditionalMarketBalance
            clock,
            ctx,
        );

        swap_core::finalize_swap_session(session, proposal, escrow, clock);

        let market_state = coin_escrow::get_market_state(escrow);
        let pools = market_state::borrow_amm_pools(market_state);
        no_arb_guard::ensure_spot_in_band(spot_pool, pools);

        // Convert asset profit to stable
        if (asset_profit.value() > 0) {
            let extra_stable = unified_spot_pool::swap_asset_for_stable(
                spot_pool,
                asset_profit,
                0,
                clock,
                ctx,
            );
            coin::join(&mut stable_with_profit, extra_stable);
        } else {
            coin::destroy_zero(asset_profit);
        };

        // Transfer output coins
        transfer::public_transfer(stable_with_profit, recipient);

        // Transfer dust balance if it exists
        if (option::is_some(&dust_opt)) {
            let dust = option::extract(&mut dust_opt);
            transfer::public_transfer(dust, recipient);
        };
        option::destroy_none(dust_opt);
    } else {
        // No arb, just return swap output
        transfer::public_transfer(stable_out, recipient);
    };
}

// === OLD CONDITIONAL SWAP FUNCTIONS REMOVED ===
//
// The old swap_conditional_stable_to_asset and swap_conditional_asset_to_stable
// entry functions have been removed. They were inefficient (each swap had its own
// session overhead) and didn't enforce complete set closure.
//
// Use the PTB batching pattern instead (see below):
// - begin_conditional_swaps() → swap_in_batch() × N → finalize_conditional_swaps()
//
// Benefits:
// - Hot potato forces complete set closure (can't forget to finalize)
// - Gas efficient (one session for N swaps)
// - Enables cross-outcome strategies
//
// ============================================================================
// === PTB-BASED CONDITIONAL SWAP BATCHING ===
// ============================================================================
//
// These functions enable chaining multiple conditional swaps in a PTB,
// then triggering auto-arb at the END of the PTB (not after each swap).
//
// KEY FEATURE: Hot potato pattern FORCES users to call finalize at end of PTB.
// Users CANNOT do conditional swaps without closing the batch.
//
// Use Cases:
// - Cross-outcome strategies (long outcome 0, short outcome 1)
// - Spread trading (exploit price differences between outcomes)
// - Gas-optimized multi-outcome swaps (one session for N swaps)
//
// Flow:
// 1. begin_conditional_swaps() → creates ConditionalSwapBatch hot potato
// 2. swap_in_batch() × N → accumulates swaps in balance (chainable)
// 3. finalize_conditional_swaps() → closes complete sets, returns profit
//
// IMPORTANT: Spot swaps (lines 47-411) remain UNCHANGED - auto-arb still
// triggers immediately after each spot swap. This pattern is ONLY for
// conditional swap batching.
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
        ctx
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
        !is_asset_to_stable,  // is_asset = opposite of swap direction
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
        is_asset_to_stable,  // is_asset = swap direction
        ctx,
    );

    // Return modified hot potato and output coin
    (batch, coin_out)
}

/// Step 3: Finalize conditional swaps (consumes hot potato)
///
/// Closes complete sets from accumulated balance, withdraws spot coins as profit,
/// and transfers to recipient. This MUST be called at end of PTB to consume hot potato.
///
/// # Arguments
/// * `batch` - Hot potato from swap_in_batch (final state)
/// * `spot_pool` - Spot pool (for no-arb guard, NOT for swapping)
/// * `proposal` - Proposal object
/// * `escrow` - Token escrow
/// * `session` - SwapSession hot potato (consumed here)
/// * `recipient` - Who receives profit
/// * `clock` - Clock object
///
/// # Flow
/// 1. Find minimum balance across outcomes (complete set limit)
/// 2. Burn complete sets → withdraw spot coins
/// 3. Transfer profit to recipient
/// 4. Finalize session (updates early resolve metrics ONCE)
/// 5. Destroy empty balance (cleanup)
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
            &mut balance, escrow, min_asset, ctx
        )
    } else {
        coin::zero<AssetType>(ctx)
    };

    let spot_stable = if (min_stable > 0) {
        arbitrage::burn_complete_set_and_withdraw_stable<AssetType, StableType>(
            &mut balance, escrow, min_stable, ctx
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

    // Cleanup dust (zero out remaining balances)
    // TODO: Store dust in registry instead of destroying (future enhancement)
    let outcome_count = conditional_balance::outcome_count(&balance);
    let mut i = 0u8;
    while ((i as u64) < (outcome_count as u64)) {
        conditional_balance::set_balance(&mut balance, i, true, 0);
        conditional_balance::set_balance(&mut balance, i, false, 0);
        i = i + 1;
    };
    conditional_balance::destroy_empty(balance);
}
