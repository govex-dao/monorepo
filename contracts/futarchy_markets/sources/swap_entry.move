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

module futarchy_markets::swap_entry;

use sui::coin::{Self, Coin};
use sui::clock::Clock;
use sui::object;
use sui::transfer;
use futarchy_markets::unified_spot_pool::{Self, UnifiedSpotPool};
use futarchy_markets::swap_core;
use futarchy_markets::proposal::{Self, Proposal};
use futarchy_markets::coin_escrow::{Self, TokenEscrow};
use futarchy_markets::conditional_balance::{Self, ConditionalMarketBalance};
use futarchy_markets::market_state;
use futarchy_markets::arbitrage;
use futarchy_markets::no_arb_guard;
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

// === Conditional Swap Functions (FULLY IMPLEMENTED) ===

/// Swap conditional stable → conditional asset
///
/// Uses balance-based swaps from Task D to work for ANY outcome count.
/// Only needs 2 type parameters + 1 conditional type parameter.
///
/// # Arguments
/// * `proposal` - The proposal (validates state)
/// * `escrow` - Token escrow (for wrap/unwrap)
/// * `outcome_index` - Which outcome to swap in (0, 1, 2, ...)
/// * `stable_in` - Conditional stable coin to swap
/// * `min_asset_out` - Minimum asset to receive (slippage protection)
///
/// # Returns
/// Conditional asset coin from swap
///
/// # Example PTB
/// ```typescript
/// const assetOut = tx.moveCall({
///   target: '${PKG}::swap_entry::swap_conditional_stable_to_asset',
///   typeArguments: ['${ASSET}', '${STABLE}', '${COND_STABLE}', '${COND_ASSET}'],
///   arguments: [proposal, escrow, outcomeIndex, stableIn, minAssetOut, clock]
/// });
/// ```
public entry fun swap_conditional_stable_to_asset<AssetType, StableType, StableConditionalCoin, AssetConditionalCoin>(
    proposal: &mut Proposal<AssetType, StableType>,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    outcome_index: u64,
    stable_in: Coin<StableConditionalCoin>,
    min_asset_out: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let amount_in = coin::value(&stable_in);
    assert!(amount_in > 0, EZeroAmount);

    // Require trading is active (check market_state, not proposal)
    let market_state = coin_escrow::get_market_state(escrow);
    market_state::assert_trading_active(market_state);

    // Begin swap session (hot potato)
    let session = swap_core::begin_swap_session(escrow);

    // Create temporary balance for coin ↔ balance conversion
    // Get market info from escrow
    let market_id = market_state::market_id(market_state);
    let outcome_count = market_state::outcome_count(market_state);
    let mut balance = conditional_balance::new<AssetType, StableType>(
        market_id,
        (outcome_count as u8),
        ctx
    );

    // Wrap stable_in → balance
    conditional_balance::wrap_coin<AssetType, StableType, StableConditionalCoin>(
        &mut balance,
        escrow,
        stable_in,
        (outcome_index as u8),
        false,  // is_asset = false (stable)
    );

    // Perform balance-based swap (works for ANY outcome count!)
    let amount_out = swap_core::swap_balance_stable_to_asset<AssetType, StableType>(
        &session,
        escrow,
        &mut balance,
        (outcome_index as u8),
        amount_in,
        min_asset_out,
        clock,
        ctx,
    );

    // Unwrap balance → asset_out coin
    let asset_out = conditional_balance::unwrap_to_coin<AssetType, StableType, AssetConditionalCoin>(
        &mut balance,
        escrow,
        (outcome_index as u8),
        true,  // is_asset = true
        ctx,
    );

    // Finalize session (consume hot potato)
    swap_core::finalize_swap_session(session, proposal, escrow, clock);

    // Cleanup (balance should be empty after unwrap)
    conditional_balance::destroy_empty(balance);

    // Transfer to caller
    transfer::public_transfer(asset_out, ctx.sender());
}

/// Swap conditional asset → conditional stable
///
/// Uses balance-based swaps from Task D to work for ANY outcome count.
/// Only needs 2 type parameters + 1 conditional type parameter.
///
/// # Arguments
/// * `proposal` - The proposal (validates state)
/// * `escrow` - Token escrow (for wrap/unwrap)
/// * `outcome_index` - Which outcome to swap in (0, 1, 2, ...)
/// * `asset_in` - Conditional asset coin to swap
/// * `min_stable_out` - Minimum stable to receive (slippage protection)
///
/// # Returns
/// Conditional stable coin from swap
///
/// # Example PTB
/// ```typescript
/// const stableOut = tx.moveCall({
///   target: '${PKG}::swap_entry::swap_conditional_asset_to_stable',
///   typeArguments: ['${ASSET}', '${STABLE}', '${COND_ASSET}', '${COND_STABLE}'],
///   arguments: [proposal, escrow, outcomeIndex, assetIn, minStableOut, clock]
/// });
/// ```
public entry fun swap_conditional_asset_to_stable<AssetType, StableType, AssetConditionalCoin, StableConditionalCoin>(
    proposal: &mut Proposal<AssetType, StableType>,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    outcome_index: u64,
    asset_in: Coin<AssetConditionalCoin>,
    min_stable_out: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let amount_in = coin::value(&asset_in);
    assert!(amount_in > 0, EZeroAmount);

    // Require trading is active (check market_state, not proposal)
    let market_state = coin_escrow::get_market_state(escrow);
    market_state::assert_trading_active(market_state);

    // Begin swap session (hot potato)
    let session = swap_core::begin_swap_session(escrow);

    // Create temporary balance for coin ↔ balance conversion
    // Get market info from escrow
    let market_id = market_state::market_id(market_state);
    let outcome_count = market_state::outcome_count(market_state);
    let mut balance = conditional_balance::new<AssetType, StableType>(
        market_id,
        (outcome_count as u8),
        ctx
    );

    // Wrap asset_in → balance
    conditional_balance::wrap_coin<AssetType, StableType, AssetConditionalCoin>(
        &mut balance,
        escrow,
        asset_in,
        (outcome_index as u8),
        true,  // is_asset = true
    );

    // Perform balance-based swap (works for ANY outcome count!)
    let amount_out = swap_core::swap_balance_asset_to_stable<AssetType, StableType>(
        &session,
        escrow,
        &mut balance,
        (outcome_index as u8),
        amount_in,
        min_stable_out,
        clock,
        ctx,
    );

    // Unwrap balance → stable_out coin
    let stable_out = conditional_balance::unwrap_to_coin<AssetType, StableType, StableConditionalCoin>(
        &mut balance,
        escrow,
        (outcome_index as u8),
        false,  // is_asset = false (stable)
        ctx,
    );

    // Finalize session (consume hot potato)
    swap_core::finalize_swap_session(session, proposal, escrow, clock);

    // Cleanup (balance should be empty after unwrap)
    conditional_balance::destroy_empty(balance);

    // Transfer to caller
    transfer::public_transfer(stable_out, ctx.sender());
}
