/// Core swap primitives (building blocks)
///
/// Internal library providing low-level swap functions used by other modules.
/// Users don't call this directly - use swap_entry.move instead.
module futarchy_markets_core::swap_core;

use futarchy_markets_primitives::coin_escrow::{Self, TokenEscrow};
use futarchy_markets_primitives::conditional_balance::{Self};
use futarchy_markets_core::early_resolve;
use futarchy_markets_core::proposal::{Self, Proposal};
use futarchy_one_shot_utils::math;
use sui::clock::Clock;
use sui::coin::{Self, Coin};
use sui::object::{Self, ID};

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
const EProposalMismatch: u64 = 7;

// === Constants ===
const STATE_TRADING: u8 = 2; // Must match proposal.move STATE_TRADING

// === Structs ===

/// Hot potato that enforces early resolve metrics update at end of swap session
/// No abilities = must be consumed by finalize_swap_session()
public struct SwapSession {
    market_id: ID,  // Track which market this session is for
}

// === Session Management ===

/// Begin a swap session (creates hot potato)
/// Must be called before any swaps in a PTB
///
/// Creates a hot potato that must be consumed by finalize_swap_session().
/// This ensures metrics are updated exactly once after all swaps complete.
public fun begin_swap_session<AssetType, StableType>(
    escrow: &TokenEscrow<AssetType, StableType>,
): SwapSession {
    let market_state = coin_escrow::get_market_state(escrow);
    let market_id = futarchy_markets_core::market_state::market_id(market_state);
    SwapSession {
        market_id,
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
    let SwapSession { market_id } = session;

    // Validate session matches this market
    let market_state = coin_escrow::get_market_state_mut(escrow);
    let escrow_market_id = futarchy_markets_core::market_state::market_id(market_state);
    assert!(market_id == escrow_market_id, ESessionMismatch);

    // Update early resolve metrics once per session (efficient!)
    // Recalculates winner from current prices after all swaps complete
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
    assert!(proposal::state(proposal) == STATE_TRADING, EInvalidState);
    assert!(outcome_idx < proposal::outcome_count(proposal), EInvalidOutcome);

    let amount_in = asset_in.value();

    // Step 1: Validate session and market
    {
        let market_state = coin_escrow::get_market_state(escrow);  // Immutable borrow
        let market_id = futarchy_markets_core::market_state::market_id(market_state);
        assert!(session.market_id == market_id, ESessionMismatch);
    }; // market_state dropped here

    // Step 2: Burn input conditional asset coins
    coin_escrow::burn_conditional_asset<AssetType, StableType, AssetConditionalCoin>(
        escrow,
        outcome_idx,
        asset_in,
    );

    // Step 3: Calculate swap through AMM and update price leaderboard
    let amount_out = {
        let market_state = coin_escrow::get_market_state_mut(escrow);
        let market_id = futarchy_markets_core::market_state::market_id(market_state);

        // Lazy init price leaderboard on first swap (after init actions complete)
        if (!futarchy_markets_core::market_state::has_price_leaderboard(market_state)) {
            futarchy_markets_core::market_state::init_price_leaderboard(market_state, ctx);
        };

        // Execute swap
        let pool = futarchy_markets_core::market_state::get_pool_mut_by_outcome(market_state, (outcome_idx as u8));
        let amount_out = pool.swap_asset_to_stable(
            market_id,
            amount_in,
            min_amount_out,
            clock,
            ctx
        );

        // Update price in leaderboard (O(log N))
        let new_price = pool.get_current_price();
        futarchy_markets_core::market_state::update_price_in_leaderboard(
            market_state,
            outcome_idx,
            new_price
        );

        amount_out
    }; // market_state dropped here

    assert!(amount_out >= min_amount_out, EInsufficientOutput);

    // Step 4: Mint output conditional stable coins
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
    assert!(proposal::state(proposal) == STATE_TRADING, EInvalidState);
    assert!(outcome_idx < proposal::outcome_count(proposal), EInvalidOutcome);

    let amount_in = stable_in.value();

    // Step 1: Validate session and market
    {
        let market_state = coin_escrow::get_market_state(escrow);  // Immutable borrow
        let market_id = futarchy_markets_core::market_state::market_id(market_state);
        assert!(session.market_id == market_id, ESessionMismatch);
    }; // market_state dropped here

    // Step 2: Burn input conditional stable coins
    coin_escrow::burn_conditional_stable<AssetType, StableType, StableConditionalCoin>(
        escrow,
        outcome_idx,
        stable_in,
    );

    // Step 3: Calculate swap through AMM and update price leaderboard
    let amount_out = {
        let market_state = coin_escrow::get_market_state_mut(escrow);
        let market_id = futarchy_markets_core::market_state::market_id(market_state);

        // Lazy init price leaderboard on first swap (after init actions complete)
        if (!futarchy_markets_core::market_state::has_price_leaderboard(market_state)) {
            futarchy_markets_core::market_state::init_price_leaderboard(market_state, ctx);
        };

        // Execute swap
        let pool = futarchy_markets_core::market_state::get_pool_mut_by_outcome(market_state, (outcome_idx as u8));
        let amount_out = pool.swap_stable_to_asset(
            market_id,
            amount_in,
            min_amount_out,
            clock,
            ctx
        );

        // Update price in leaderboard (O(log N))
        let new_price = pool.get_current_price();
        futarchy_markets_core::market_state::update_price_in_leaderboard(
            market_state,
            outcome_idx,
            new_price
        );

        amount_out
    }; // market_state dropped here

    assert!(amount_out >= min_amount_out, EInsufficientOutput);

    // Step 4: Mint output conditional asset coins
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

// === BALANCE-BASED SWAP FUNCTIONS ===
//
// These functions work with ConditionalMarketBalance instead of typed coins.
// This ELIMINATES type explosion - works for ANY outcome count without N type parameters.
//
// Key benefits:
// 1. No type parameters for conditional coins (just AssetType, StableType)
// 2. Works for 2, 3, 4, 5, 200 outcomes without separate modules
// 3. Same swap logic, different input/output handling
//
// Used by: arbitrage with balance tracking, unified swap entry functions

/// Swap from balance: conditional asset → conditional stable
///
/// Works for ANY outcome count by operating on balance indices.
/// No conditional coin type parameters needed!
///
/// # Arguments
/// * `balance` - Balance object to update (decreases asset, increases stable)
/// * `outcome_idx` - Which outcome to swap in (0, 1, 2, ...)
/// * `amount_in` - Asset amount to swap
/// * `min_amount_out` - Minimum stable amount to receive (slippage protection)
///
/// # Example
/// ```move
/// // Swap 1000 asset → stable in outcome 0 (works for 2, 3, 4, ... outcomes!)
/// swap_balance_asset_to_stable(
///     &session, &mut escrow, &mut balance,
///     0, 1000, 950, &clock, ctx
/// );
/// // Balance updated: outcome 0 asset -1000, outcome 0 stable +~950
/// ```
public fun swap_balance_asset_to_stable<AssetType, StableType>(
    session: &SwapSession,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    balance: &mut conditional_balance::ConditionalMarketBalance<AssetType, StableType>,
    outcome_idx: u8,
    amount_in: u64,
    min_amount_out: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): u64 {
    // Get market state and validate everything from it
    let market_state = coin_escrow::get_market_state_mut(escrow);
    let market_id = futarchy_markets_core::market_state::market_id(market_state);

    // Validate market is active
    futarchy_markets_core::market_state::assert_trading_active(market_state);

    // Validate session matches market
    assert!(session.market_id == market_id, ESessionMismatch);

    // CRITICAL SECURITY: Validate balance belongs to this market
    // Prevents exploiting price differences between markets
    assert!(
        conditional_balance::market_id(balance) == market_id,
        EProposalMismatch
    );

    // Validate outcome exists in market
    let market_outcome_count = futarchy_markets_core::market_state::outcome_count(market_state);
    assert!((outcome_idx as u64) < market_outcome_count, EInvalidOutcome);

    // Lazy init price leaderboard on first swap (after init actions complete)
    if (!futarchy_markets_core::market_state::has_price_leaderboard(market_state)) {
        futarchy_markets_core::market_state::init_price_leaderboard(market_state, ctx);
    };

    // Subtract from asset balance (input)
    // Note: sub_from_balance validates balance sufficiency internally
    conditional_balance::sub_from_balance(balance, outcome_idx, true, amount_in);

    // Calculate swap through AMM (reuse market_state and market_id)
    let pool = futarchy_markets_core::market_state::get_pool_mut_by_outcome(market_state, outcome_idx);
    let amount_out = pool.swap_asset_to_stable(
        market_id,
        amount_in,
        min_amount_out,
        clock,
        ctx
    );

    assert!(amount_out >= min_amount_out, EInsufficientOutput);

    // Update price in leaderboard (O(log N))
    let new_price = pool.get_current_price();
    futarchy_markets_core::market_state::update_price_in_leaderboard(
        market_state,
        (outcome_idx as u64),
        new_price
    );

    // Add to stable balance (output)
    conditional_balance::add_to_balance(balance, outcome_idx, false, amount_out);

    amount_out
}

/// Swap from balance: conditional stable → conditional asset
///
/// Works for ANY outcome count by operating on balance indices.
/// No conditional coin type parameters needed!
///
/// # Arguments
/// * `balance` - Balance object to update (decreases stable, increases asset)
/// * `outcome_idx` - Which outcome to swap in (0, 1, 2, ...)
/// * `amount_in` - Stable amount to swap
/// * `min_amount_out` - Minimum asset amount to receive (slippage protection)
///
/// # Example
/// ```move
/// // Swap 1000 stable → asset in outcome 1 (works for 2, 3, 4, ... outcomes!)
/// swap_balance_stable_to_asset(
///     &session, &mut escrow, &mut balance,
///     1, 1000, 950, &clock, ctx
/// );
/// // Balance updated: outcome 1 stable -1000, outcome 1 asset +~950
/// ```
public fun swap_balance_stable_to_asset<AssetType, StableType>(
    session: &SwapSession,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    balance: &mut conditional_balance::ConditionalMarketBalance<AssetType, StableType>,
    outcome_idx: u8,
    amount_in: u64,
    min_amount_out: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): u64 {
    // Get market state and validate everything from it
    let market_state = coin_escrow::get_market_state_mut(escrow);
    let market_id = futarchy_markets_core::market_state::market_id(market_state);

    // Validate market is active
    futarchy_markets_core::market_state::assert_trading_active(market_state);

    // Validate session matches market
    assert!(session.market_id == market_id, ESessionMismatch);

    // CRITICAL SECURITY: Validate balance belongs to this market
    // Prevents exploiting price differences between markets
    assert!(
        conditional_balance::market_id(balance) == market_id,
        EProposalMismatch
    );

    // Validate outcome exists in market
    let market_outcome_count = futarchy_markets_core::market_state::outcome_count(market_state);
    assert!((outcome_idx as u64) < market_outcome_count, EInvalidOutcome);

    // Lazy init price leaderboard on first swap (after init actions complete)
    if (!futarchy_markets_core::market_state::has_price_leaderboard(market_state)) {
        futarchy_markets_core::market_state::init_price_leaderboard(market_state, ctx);
    };

    // Subtract from stable balance (input)
    // Note: sub_from_balance validates balance sufficiency internally
    conditional_balance::sub_from_balance(balance, outcome_idx, false, amount_in);

    // Calculate swap through AMM (reuse market_state and market_id)
    let pool = futarchy_markets_core::market_state::get_pool_mut_by_outcome(market_state, outcome_idx);
    let amount_out = pool.swap_stable_to_asset(
        market_id,
        amount_in,
        min_amount_out,
        clock,
        ctx
    );

    assert!(amount_out >= min_amount_out, EInsufficientOutput);

    // Update price in leaderboard (O(log N))
    let new_price = pool.get_current_price();
    futarchy_markets_core::market_state::update_price_in_leaderboard(
        market_state,
        (outcome_idx as u64),
        new_price
    );

    // Add to asset balance (output)
    conditional_balance::add_to_balance(balance, outcome_idx, true, amount_out);

    amount_out
}

// === Test Helpers ===

#[test_only]
/// Create a test swap session for testing
public fun create_test_swap_session(market_id: ID): SwapSession {
    SwapSession { market_id }
}

#[test_only]
/// Destroy a swap session for testing
public fun destroy_test_swap_session(session: SwapSession) {
    let SwapSession { market_id: _ } = session;
}
