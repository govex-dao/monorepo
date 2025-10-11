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

use futarchy_markets::spot_amm::{Self, SpotAMM};
use futarchy_markets::coin_escrow::{Self, TokenEscrow};
use futarchy_markets::proposal::{Self, Proposal};
use futarchy_markets::swap_core::{Self, SwapSession};
use futarchy_markets::arbitrage_executor;
use futarchy_markets::market_state;
use futarchy_markets::no_arb_guard;
use futarchy_markets::swap_position_registry::{Self, SwapPositionRegistry};
use sui::coin::{Self, Coin};
use sui::clock::Clock;

// === Errors ===
const EProposalNotLive: u64 = 0;
const EZeroAmount: u64 = 1;

// === Constants ===
const STATE_TRADING: u8 = 2; // Must match proposal.move

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
public entry fun swap_spot_stable_to_asset<AssetType, StableType, AssetConditionalCoin, StableConditionalCoin>(
    spot_pool: &mut SpotAMM<AssetType, StableType>,
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
    let asset_out = spot_amm::swap_stable_for_asset(
        spot_pool,
        stable_in,
        min_asset_out,
        clock,
        ctx,
    );

    // Step 2: Auto-arb if proposal is live (uses swap output as budget)
    let proposal_state = proposal::state(proposal);

    if (proposal_state == STATE_TRADING) {
        // Validate objects and borrow registry from spot_pool
        let registry = spot_amm::validate_arb_objects_and_borrow_registry(
            spot_pool,
            proposal,
            escrow,
        );

        // Begin swap session for conditional swaps
        let session = swap_core::begin_swap_session(proposal);

        // Execute optimal arb bidirectionally (dust deposited to registry)
        // Pass asset_out (what we have) and zero stable (what we don't have)
        let (stable_profit, mut asset_with_profit) = arbitrage_executor::execute_optimal_spot_arbitrage<
            AssetType,
            StableType,
            AssetConditionalCoin,
            StableConditionalCoin,
        >(
            spot_pool,
            proposal,
            escrow,
            registry,
            &session,
            coin::zero<StableType>(ctx),  // Don't have stable
            asset_out,                     // Have asset from swap
            0,  // min_profit_threshold (any profit is good)
            recipient,                     // Who owns dust and receives complete sets
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
            let extra_asset = spot_amm::swap_stable_for_asset(
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
public entry fun swap_spot_asset_to_stable<AssetType, StableType, AssetConditionalCoin, StableConditionalCoin>(
    spot_pool: &mut SpotAMM<AssetType, StableType>,
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
    let stable_out = spot_amm::swap_asset_for_stable(
        spot_pool,
        asset_in,
        min_stable_out,
        clock,
        ctx,
    );

    // Step 2: Auto-arb if proposal is live
    let proposal_state = proposal::state(proposal);

    if (proposal_state == STATE_TRADING) {
        // Validate objects and borrow registry from spot_pool
        let registry = spot_amm::validate_arb_objects_and_borrow_registry(
            spot_pool,
            proposal,
            escrow,
        );

        let session = swap_core::begin_swap_session(proposal);

        // Execute optimal arb bidirectionally (dust deposited to registry)
        // Pass stable_out (what we have) and zero asset (what we don't have)
        let (mut stable_with_profit, asset_profit) = arbitrage_executor::execute_optimal_spot_arbitrage<
            AssetType,
            StableType,
            AssetConditionalCoin,
            StableConditionalCoin,
        >(
            spot_pool,
            proposal,
            escrow,
            registry,                       // For dust deposits
            &session,
            stable_out,                     // Have stable from swap
            coin::zero<AssetType>(ctx),    // Don't have asset
            0,  // min_profit_threshold
            recipient,                      // Who owns dust and receives complete sets
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
            let extra_stable = spot_amm::swap_asset_for_stable(
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

// === Conditional Swaps with Auto-Arb ===

/// Swap conditional stable → conditional asset (same outcome market) with auto-arbitrage
///
/// Flow:
/// 1. Swap stable → asset in conditional market (user pays fees)
/// 2. Execute conditional arbitrage with swap output as budget
/// 3. Return: remaining output + arb profit
///
/// Auto-arb strategy:
/// - Burn partial output → spot swap → split to all outcomes → conditional swaps → restore
/// - Temporarily violates quantum invariant (validated at end)
/// - Atomic operation ensures safety
public entry fun swap_conditional_stable_to_asset<AssetType, StableType, AssetConditionalCoin, StableConditionalCoin>(
    spot_pool: &mut SpotAMM<AssetType, StableType>,
    proposal: &mut Proposal<AssetType, StableType>,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    outcome_idx: u64,
    stable_in: Coin<StableConditionalCoin>,
    min_asset_out: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let amount_in = stable_in.value();
    assert!(amount_in > 0, EZeroAmount);

    // Require proposal is live
    let proposal_state = proposal::state(proposal);
    assert!(proposal_state == STATE_TRADING, EProposalNotLive);

    // Step 1: Swap within conditional market
    let session = swap_core::begin_swap_session(proposal);

    let asset_out = swap_core::swap_stable_to_asset<
        AssetType,
        StableType,
        AssetConditionalCoin,
        StableConditionalCoin,
    >(
        &session,
        proposal,
        escrow,
        outcome_idx,
        stable_in,
        min_asset_out,
        clock,
        ctx,
    );

    // Step 2: Execute conditional arbitrage with swap output
    let (remaining_output, arb_profit) = arbitrage_executor::execute_conditional_arbitrage_stable_to_asset<
        AssetType,
        StableType,
        AssetConditionalCoin,
        StableConditionalCoin,
    >(
        spot_pool,
        proposal,
        escrow,
        &session,
        outcome_idx,
        asset_out,
        0,  // min_profit_threshold
        clock,
        ctx,
    );

    swap_core::finalize_swap_session(session, proposal, escrow, clock);

    // Ensure no-arb band is respected after auto-arb
    let market_state = coin_escrow::get_market_state(escrow);
    let pools = market_state::borrow_amm_pools(market_state);
    no_arb_guard::ensure_spot_in_band(spot_pool, pools);

    // Transfer output + profit to user
    transfer::public_transfer(remaining_output, ctx.sender());
    transfer::public_transfer(arb_profit, ctx.sender());
}

/// Swap conditional asset → conditional stable (same outcome market) with auto-arbitrage
///
/// Flow:
/// 1. Swap asset → stable in conditional market (user pays fees)
/// 2. Execute conditional arbitrage with swap output as budget
/// 3. Return: remaining output + arb profit
///
/// Auto-arb strategy:
/// - Burn partial output → spot swap → split to all outcomes → conditional swaps → restore
/// - Temporarily violates quantum invariant (validated at end)
/// - Atomic operation ensures safety
public entry fun swap_conditional_asset_to_stable<AssetType, StableType, AssetConditionalCoin, StableConditionalCoin>(
    spot_pool: &mut SpotAMM<AssetType, StableType>,
    proposal: &mut Proposal<AssetType, StableType>,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    outcome_idx: u64,
    asset_in: Coin<AssetConditionalCoin>,
    min_stable_out: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let amount_in = asset_in.value();
    assert!(amount_in > 0, EZeroAmount);

    // Require proposal is live
    let proposal_state = proposal::state(proposal);
    assert!(proposal_state == STATE_TRADING, EProposalNotLive);

    // Step 1: Swap within conditional market
    let session = swap_core::begin_swap_session(proposal);

    let stable_out = swap_core::swap_asset_to_stable<
        AssetType,
        StableType,
        AssetConditionalCoin,
        StableConditionalCoin,
    >(
        &session,
        proposal,
        escrow,
        outcome_idx,
        asset_in,
        min_stable_out,
        clock,
        ctx,
    );

    // Step 2: Execute conditional arbitrage with swap output
    let (remaining_output, arb_profit) = arbitrage_executor::execute_conditional_arbitrage_asset_to_stable<
        AssetType,
        StableType,
        AssetConditionalCoin,
        StableConditionalCoin,
    >(
        spot_pool,
        proposal,
        escrow,
        &session,
        outcome_idx,
        stable_out,
        0,  // min_profit_threshold
        clock,
        ctx,
    );

    swap_core::finalize_swap_session(session, proposal, escrow, clock);

    // Ensure no-arb band is respected after auto-arb
    let market_state = coin_escrow::get_market_state(escrow);
    let pools = market_state::borrow_amm_pools(market_state);
    no_arb_guard::ensure_spot_in_band(spot_pool, pools);

    // Transfer output + profit to user
    transfer::public_transfer(remaining_output, ctx.sender());
    transfer::public_transfer(arb_profit, ctx.sender());
}
