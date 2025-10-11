/// Core swap primitives (building blocks)
///
/// Internal library providing low-level swap functions used by other modules.
/// Users don't call this directly - use swap_entry.move instead.
module futarchy_markets::swap_core;

use futarchy_markets::coin_escrow::{Self, TokenEscrow};
use futarchy_markets::proposal::{Self, Proposal};
use futarchy_markets::early_resolve;
use futarchy_one_shot_utils::math;
use sui::clock::Clock;
use sui::coin::{Self, Coin};
use sui::object::ID;

// === Introduction ===
// Core swap functions for TreasuryCap-based conditional coins
// Swaps work by: burn input → update AMM reserves → mint output
//
// Hot potato pattern ensures early resolve metrics are updated once per PTB:
// 1. begin_swap_session() - creates SwapSession hot potato
// 2. swap_*() - validates session, performs swaps
// 3. finalize_swap_session() - consumes hot potato, updates metrics ONCE

// === Errors ===
const EInvalidOutcome: u64 = 0;
const EInvalidState: u64 = 3;
const EInsufficientOutput: u64 = 5;
const ESessionMismatch: u64 = 6;

// === Constants ===
const STATE_TRADING: u8 = 2; // Must match proposal.move STATE_TRADING

// === Structs ===

/// Hot potato that enforces early resolve metrics update at end of swap session
/// No abilities = must be consumed by finalize_swap_session()
public struct SwapSession {
    proposal_id: ID,  // Track which proposal this session is for
}

// === Session Management ===

/// Begin a swap session (creates hot potato)
/// Must be called before any swaps in a PTB
///
/// Creates a hot potato that must be consumed by finalize_swap_session().
/// This ensures metrics are updated exactly once after all swaps complete.
public fun begin_swap_session<AssetType, StableType>(
    proposal: &Proposal<AssetType, StableType>,
): SwapSession {
    SwapSession {
        proposal_id: object::id(proposal),
    }
}

/// Finalize swap session (consumes hot potato and updates metrics)
/// Must be called at end of PTB to consume the SwapSession
/// This is where early resolve metrics are updated ONCE for efficiency
///
/// **Idempotency Guarantee:** update_early_resolve_metrics is idempotent when called
/// multiple times at the same timestamp with unchanged state. If winner hasn't flipped,
/// the second call is a no-op (just gas cost, no state changes). This ensures correctness
/// even if accidentally called multiple times in same PTB.
///
/// **Flip Recalculation:** This function recalculates the winning outcome from current
/// AMM prices AFTER all swaps complete, ensuring flip detection happens exactly once
/// per transaction with up-to-date market state.
public fun finalize_swap_session<AssetType, StableType>(
    session: SwapSession,
    proposal: &mut Proposal<AssetType, StableType>,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    clock: &Clock,
) {
    let SwapSession { proposal_id } = session;
    assert!(proposal_id == object::id(proposal), ESessionMismatch);

    // Update early resolve metrics once per session (efficient!)
    // Recalculates winner from current prices after all swaps complete
    // Get market_state from escrow to pass to early_resolve
    let market_state = coin_escrow::get_market_state_mut(escrow);
    early_resolve::update_metrics(proposal, market_state, clock);
}

// === Core Swap Functions ===

/// Swap conditional asset coins to conditional stable coins
/// Uses TreasuryCap system: burn input → AMM calculation → mint output
/// Requires valid SwapSession to ensure metrics are updated at end of PTB
public fun swap_asset_to_stable<AssetType, StableType, AssetConditionalCoin, StableConditionalCoin>(
    session: &SwapSession,
    proposal: &mut Proposal<AssetType, StableType>,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    outcome_idx: u64,
    asset_in: Coin<AssetConditionalCoin>,
    min_amount_out: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<StableConditionalCoin> {
    // Validate session matches proposal
    assert!(session.proposal_id == object::id(proposal), ESessionMismatch);

    assert!(proposal::state(proposal) == STATE_TRADING, EInvalidState);
    assert!(outcome_idx < proposal::outcome_count(proposal), EInvalidOutcome);

    let amount_in = asset_in.value();

    // Burn input conditional asset coins
    coin_escrow::burn_conditional_asset<AssetType, StableType, AssetConditionalCoin>(
        escrow,
        outcome_idx,
        asset_in,
    );

    // Calculate swap through AMM (access pools from market_state)
    let market_state = coin_escrow::get_market_state_mut(escrow);
    let market_id = futarchy_markets::market_state::market_id(market_state);
    let pool = futarchy_markets::market_state::get_pool_mut_by_outcome(market_state, (outcome_idx as u8));
    let amount_out = pool.swap_asset_to_stable(
        market_id,
        amount_in,
        min_amount_out,
        clock,
        ctx
    );

    assert!(amount_out >= min_amount_out, EInsufficientOutput);

    // Mint output conditional stable coins
    coin_escrow::mint_conditional_stable<AssetType, StableType, StableConditionalCoin>(
        escrow,
        outcome_idx,
        amount_out,
        ctx,
    )
}

// DELETED: swap_asset_to_stable_entry
// Old entry function - replaced by swap_clean.move functions

/// Swap conditional stable coins to conditional asset coins
/// Requires valid SwapSession to ensure metrics are updated at end of PTB
public fun swap_stable_to_asset<AssetType, StableType, AssetConditionalCoin, StableConditionalCoin>(
    session: &SwapSession,
    proposal: &mut Proposal<AssetType, StableType>,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    outcome_idx: u64,
    stable_in: Coin<StableConditionalCoin>,
    min_amount_out: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<AssetConditionalCoin> {
    // Validate session matches proposal
    assert!(session.proposal_id == object::id(proposal), ESessionMismatch);

    assert!(proposal::state(proposal) == STATE_TRADING, EInvalidState);
    assert!(outcome_idx < proposal::outcome_count(proposal), EInvalidOutcome);

    let amount_in = stable_in.value();

    // Burn input conditional stable coins
    coin_escrow::burn_conditional_stable<AssetType, StableType, StableConditionalCoin>(
        escrow,
        outcome_idx,
        stable_in,
    );

    // Calculate swap through AMM (access pools from market_state)
    let market_state = coin_escrow::get_market_state_mut(escrow);
    let market_id = futarchy_markets::market_state::market_id(market_state);
    let pool = futarchy_markets::market_state::get_pool_mut_by_outcome(market_state, (outcome_idx as u8));
    let amount_out = pool.swap_stable_to_asset(
        market_id,
        amount_in,
        min_amount_out,
        clock,
        ctx
    );

    assert!(amount_out >= min_amount_out, EInsufficientOutput);

    // Mint output conditional asset coins
    coin_escrow::mint_conditional_asset<AssetType, StableType, AssetConditionalCoin>(
        escrow,
        outcome_idx,
        amount_out,
        ctx,
    )
}

// DELETED: swap_stable_to_asset_entry
// DELETED: swap_multiple_asset_to_stable_entry
// DELETED: swap_multiple_stable_to_asset_entry
// DELETED: swap_stable_to_asset_with_registry_2
// All old entry functions removed - use swap_clean.move instead
//
// Users should use the 4 clean entry functions in swap_clean.move:
// - swap_spot_stable_to_asset (with auto-arb)
// - swap_spot_asset_to_stable (with auto-arb)
// - swap_conditional_stable_to_asset (with auto-arb)
// - swap_conditional_asset_to_stable (with auto-arb)

// === CONDITIONAL TRADER CONSTRAINTS ===
//
// Conditional traders CANNOT perform cross-market arbitrage without complete sets.
// The quantum liquidity model prevents burning tokens from one outcome and withdrawing
// spot tokens, as this would break the invariant: spot_balance == Cond0_supply == Cond1_supply
//
// Available operations for conditional traders:
// 1. Swap within same outcome: Cond0_Stable ↔ Cond0_Asset (using swap_stable_to_asset/swap_asset_to_stable)
// 2. Acquire complete sets: Get tokens from ALL outcomes → burn complete set → withdraw spot
//
// Cross-market routing requires spot tokens, which conditional traders cannot obtain
// without first acquiring a complete set (tokens from ALL outcomes).
//
// See arbitrage_executor.move for spot trader arbitrage pattern with complete sets.
