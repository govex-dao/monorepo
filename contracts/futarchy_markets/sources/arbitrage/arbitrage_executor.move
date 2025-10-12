/// ============================================================================
/// ARBITRAGE EXECUTOR - AUTOMATIC EQUILIBRIUM MAINTENANCE
/// ============================================================================
///
/// Provides composable arbitrage execution functions that run after swaps
/// to maintain price equilibrium and eliminate mint/redeem cycles.
///
/// ARCHITECTURE:
/// 1. User swaps in spot → creates arbitrage opportunity
/// 2. Call execute_spot_arbitrage() in same PTB
/// 3. System mints conditional → swaps → redeems → profits returned to user
///
/// USAGE IN PTB:
/// ```
/// // Spot swap with auto-arbitrage
/// let stable_out = spot_amm::swap_asset_to_stable(...);
/// let arb_profit = arbitrage_executor::execute_spot_arbitrage_asset_to_stable(...);
/// coin::join(&mut stable_out, arb_profit);
/// ```
///
/// ============================================================================

module futarchy_markets::arbitrage_executor;

use futarchy_markets::unified_spot_pool::{Self, UnifiedSpotPool};
use futarchy_markets::coin_escrow::{Self, TokenEscrow};
use futarchy_markets::proposal::{Self, Proposal};
use futarchy_markets::swap_core::{Self, SwapSession};
use futarchy_markets::arbitrage_math;
use futarchy_markets::market_state;
use futarchy_markets::swap_position_registry::SwapPositionRegistry;
use sui::balance;
use sui::coin::{Self, Coin};
use sui::clock::Clock;
use sui::tx_context::TxContext;

// === Errors ===
const ENoArbitrageProfit: u64 = 0;
const EInsufficientProfit: u64 = 1;
const EInsufficientOutput: u64 = 2;
const EInvalidOutcomeCount: u64 = 3;

// === Spot → Conditional Arbitrage ===

/// Execute arbitrage after a spot asset→stable swap
///
/// Strategy:
/// 1. Validate profitability and slippage bounds
/// 2. Mint conditional tokens from spot (split complete set)
/// 3. Swap in ALL conditional pools with slippage protection
/// 4. Recombine conditional tokens back to spot (min output = profit)
/// 5. Return profit to caller
///
/// SECURITY: This function validates expected profit before execution
/// to prevent MEV attacks and ensure profitable arbitrage.
///
/// Returns: Coin<StableType> containing arbitrage profit
public fun execute_spot_arbitrage_asset_to_stable<
    AssetType,
    StableType,
    AssetConditionalCoin,
    StableConditionalCoin,
>(
    spot_pool: &mut UnifiedSpotPool<AssetType, StableType>,
    proposal: &mut Proposal<AssetType, StableType>,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    registry: &mut SwapPositionRegistry<AssetType, StableType>,
    swap_session: &SwapSession,
    stable_for_arb: Coin<StableType>,  // Spot stable to use for arbitrage
    min_profit_out: u64,  // Minimum acceptable profit (slippage protection)
    recipient: address,  // Who receives dust and complete set redemptions
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<StableType> {
    let arb_amount = stable_for_arb.value();
    assert!(arb_amount > 0, ENoArbitrageProfit);

    // Validate outcome count (Issue #6: division by zero protection)
    // Audit fix: Require >= 2 for "ALL outcomes" logic (complete sets need multiple outcomes)
    let outcome_count = proposal::outcome_count(proposal);
    assert!(outcome_count >= 2, EInvalidOutcomeCount);

    // SECURITY ISSUE #1 FIX: Validate profit BEFORE execution
    // Get conditional pools for profit calculation
    let market_state = coin_escrow::get_market_state(escrow);
    let conditional_pools = market_state::borrow_amm_pools(market_state);

    // Calculate expected profit with current pool state
    let expected_profit = arbitrage_math::calculate_spot_arbitrage_profit(
        spot_pool,
        conditional_pools,
        arb_amount,
        false,  // stable→asset direction
    );

    // Ensure arbitrage is profitable with minimum threshold
    assert!(expected_profit >= (min_profit_out as u128), EInsufficientProfit);

    // Step 1: Swap in spot (stable → asset)
    // User sold asset to spot, so we buy asset back
    //
    // DESIGN NOTE: No intermediate slippage check needed
    // - Sui transactions are atomic (no MEV possible during execution)
    // - Front-validation (line 86-94) catches MEV before execution starts
    // - Final profit validation is implicit (must return min_profit_out worth)
    // - Setting min_amount_out=0 saves gas and simplifies API
    let mut asset_from_spot = unified_spot_pool::swap_stable_for_asset(
        spot_pool,
        stable_for_arb,
        0,  // No intermediate minimum (atomic execution guarantees)
        clock,
        ctx,
    );

    let asset_amount = asset_from_spot.value();

    // Step 2: QUANTUM MINT - Deposit asset ONCE to escrow, mint FULL amount to EACH outcome
    // In quantum liquidity: 100 spot → 100 conditional in EACH outcome (not split)
    // This is the correct Hanson-style futarchy behavior
    let asset_balance = coin::into_balance(asset_from_spot);
    coin_escrow::deposit_spot_liquidity(escrow, asset_balance, balance::zero<StableType>());

    // Mint the FULL amount to each outcome (quantum replication)
    let mut conditional_assets = vector::empty<Coin<AssetConditionalCoin>>();
    let mut i = 0;
    while (i < outcome_count) {
        let conditional_asset = coin_escrow::mint_conditional_asset<
            AssetType,
            StableType,
            AssetConditionalCoin
        >(
            escrow,
            i,
            asset_amount,  // Full amount for each outcome
            ctx,
        );

        vector::push_back(&mut conditional_assets, conditional_asset);
        i = i + 1;
    };

    // Step 3: Swap conditional assets → conditional stables in ALL pools
    let mut conditional_stables = vector::empty<Coin<StableConditionalCoin>>();

    i = 0;
    while (i < outcome_count) {
        // CRITICAL FIX: Use swap_remove(0) instead of pop_back() to match forward index
        // pop_back() gets N-1, N-2, N-3... (reverse order)
        // But we swap in pools 0, 1, 2... (forward order)
        // This caused outcome mismatches where conditional tokens were swapped in wrong pools!
        let conditional_asset = vector::swap_remove(&mut conditional_assets, 0);

        // Swap in this outcome's pool
        let conditional_stable = swap_core::swap_asset_to_stable<
            AssetType,
            StableType,
            AssetConditionalCoin,
            StableConditionalCoin,
        >(
            swap_session,
            proposal,
            escrow,
            i,
            conditional_asset,
            0,  // min_amount_out (we checked profitability)
            clock,
            ctx,
        );

        vector::push_back(&mut conditional_stables, conditional_stable);
        i = i + 1;
    };

    vector::destroy_empty(conditional_assets);

    // Step 4: Find minimum conditional stable (quantum constraint)
    // We can only redeem the minimum amount across all outcomes
    let mut min_amount = std::u64::max_value!();
    i = 0;
    while (i < outcome_count) {
        let amount = vector::borrow(&conditional_stables, i).value();
        if (amount < min_amount) {
            min_amount = amount;
        };
        i = i + 1;
    };

    // Step 5: Burn equal amounts from ALL conditional stables (complete set redemption)
    // MEDIUM SEVERITY FIX: Collect excess tokens to form complete sets instead of creating dust

    // 5a. Collect excess tokens from all outcomes
    let mut excess_stables = vector::empty<Coin<StableConditionalCoin>>();
    i = 0;
    while (i < outcome_count) {
        let mut conditional_stable = vector::swap_remove(&mut conditional_stables, 0);
        let stable_value = conditional_stable.value();

        // Split excess if it exists
        if (stable_value > min_amount) {
            let excess = coin::split(&mut conditional_stable, stable_value - min_amount, ctx);
            vector::push_back(&mut excess_stables, excess);
        } else {
            // No excess - push empty coin to maintain vector alignment
            vector::push_back(&mut excess_stables, coin::zero<StableConditionalCoin>(ctx));
        };

        // Burn the minimum amount (complete set)
        coin_escrow::burn_conditional_stable<
            AssetType,
            StableType,
            StableConditionalCoin,
        >(
            escrow,
            i,
            conditional_stable,  // Now equal to min_amount
        );

        i = i + 1;
    };

    vector::destroy_empty(conditional_stables);

    // 5b. Form complete sets from excess and redeem (instead of creating dust!)
    // Find minimum excess across all outcomes
    let mut min_excess = std::u64::max_value!();
    i = 0;
    while (i < outcome_count) {
        let excess_value = vector::borrow(&excess_stables, i).value();
        if (excess_value < min_excess) {
            min_excess = excess_value;
        };
        i = i + 1;
    };

    // If we have excess complete sets, burn them and withdraw as base tokens
    if (min_excess > 0) {
        i = 0;
        while (i < outcome_count) {
            let mut excess_stable = vector::swap_remove(&mut excess_stables, 0);
            let excess_value = excess_stable.value();

            // Burn min_excess from each outcome (forms complete set)
            if (excess_value > min_excess) {
                let to_burn_excess = coin::split(&mut excess_stable, min_excess, ctx);

                coin_escrow::burn_conditional_stable<
                    AssetType,
                    StableType,
                    StableConditionalCoin,
                >(
                    escrow,
                    i,
                    to_burn_excess,
                );

                // Deposit remaining dust to registry (< 1 complete set, but user may collect more)
                if (excess_stable.value() > 0) {
                    let proposal_id = object::id(proposal);
                    futarchy_markets::swap_position_registry::store_conditional_stable(
                        registry,
                        recipient,
                        proposal_id,
                        i,
                        excess_stable,
                        clock,
                        ctx,
                    );
                } else {
                    coin::destroy_zero(excess_stable);
                };
            } else {
                // Burn all of it (no remaining dust)
                coin_escrow::burn_conditional_stable<
                    AssetType,
                    StableType,
                    StableConditionalCoin,
                >(
                    escrow,
                    i,
                    excess_stable,
                );
            };

            i = i + 1;
        };

        // Withdraw redeemed stable from burning excess complete sets
        let excess_redeemed = coin_escrow::withdraw_stable_balance(
            escrow,
            min_excess,
            ctx,
        );

        // Return redeemed base tokens to recipient (complete set, full value)
        transfer::public_transfer(excess_redeemed, recipient);
    } else {
        // No excess complete sets - deposit any dust to registry
        while (!vector::is_empty(&excess_stables)) {
            let excess_dust = vector::pop_back(&mut excess_stables);
            if (excess_dust.value() > 0) {
                let proposal_id = object::id(proposal);
                let outcome_idx = vector::length(&excess_stables);  // Reverse index
                futarchy_markets::swap_position_registry::store_conditional_stable(
                    registry,
                    recipient,
                    proposal_id,
                    outcome_idx,
                    excess_dust,
                    clock,
                    ctx,
                );
            } else {
                coin::destroy_zero(excess_dust);
            };
        };
    };

    vector::destroy_empty(excess_stables);

    // Step 6: Withdraw spot stable from escrow (complete set fully burned)
    // After burning min_amount from ALL outcomes, we can withdraw min_amount once
    let stable_profit = coin_escrow::withdraw_stable_balance(
        escrow,
        min_amount,
        ctx,
    );

    stable_profit
}

/// Execute arbitrage after a spot stable→asset swap
///
/// Similar to asset→stable but in reverse direction
///
/// SECURITY: This function validates expected profit before execution
/// to prevent MEV attacks and ensure profitable arbitrage.
public fun execute_spot_arbitrage_stable_to_asset<
    AssetType,
    StableType,
    AssetConditionalCoin,
    StableConditionalCoin,
>(
    spot_pool: &mut UnifiedSpotPool<AssetType, StableType>,
    proposal: &mut Proposal<AssetType, StableType>,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    registry: &mut SwapPositionRegistry<AssetType, StableType>,
    swap_session: &SwapSession,
    asset_for_arb: Coin<AssetType>,  // Spot asset to use for arbitrage
    min_profit_out: u64,  // Minimum acceptable profit (slippage protection)
    recipient: address,  // Who receives dust and complete set redemptions
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<AssetType> {
    let arb_amount = asset_for_arb.value();
    assert!(arb_amount > 0, ENoArbitrageProfit);

    // Validate outcome count (Issue #6: division by zero protection)
    // Audit fix: Require >= 2 for "ALL outcomes" logic (complete sets need multiple outcomes)
    let outcome_count = proposal::outcome_count(proposal);
    assert!(outcome_count >= 2, EInvalidOutcomeCount);

    // SECURITY ISSUE #1 FIX: Validate profit BEFORE execution
    let market_state = coin_escrow::get_market_state(escrow);
    let conditional_pools = market_state::borrow_amm_pools(market_state);

    // Calculate expected profit with current pool state
    let expected_profit = arbitrage_math::calculate_spot_arbitrage_profit(
        spot_pool,
        conditional_pools,
        arb_amount,
        true,  // asset→stable direction
    );

    // Ensure arbitrage is profitable with minimum threshold
    assert!(expected_profit >= (min_profit_out as u128), EInsufficientProfit);

    // Step 1: Swap in spot (asset → stable)
    //
    // DESIGN NOTE: No intermediate slippage check needed
    // - Sui transactions are atomic (no MEV possible during execution)
    // - Front-validation (line 350-358) catches MEV before execution starts
    // - Final profit validation is implicit (must return min_profit_out worth)
    // - Setting min_amount_out=0 saves gas and simplifies API
    let mut stable_from_spot = unified_spot_pool::swap_asset_for_stable(
        spot_pool,
        asset_for_arb,
        0,  // No intermediate minimum (atomic execution guarantees)
        clock,
        ctx,
    );

    let stable_amount = stable_from_spot.value();

    // Step 2: QUANTUM MINT - Deposit stable ONCE to escrow, mint FULL amount to EACH outcome
    // In quantum liquidity: 100 spot → 100 conditional in EACH outcome (not split)
    let stable_balance = coin::into_balance(stable_from_spot);
    coin_escrow::deposit_spot_liquidity(escrow, balance::zero<AssetType>(), stable_balance);

    // Mint the FULL amount to each outcome (quantum replication)
    let mut conditional_stables = vector::empty<Coin<StableConditionalCoin>>();
    let mut i = 0;
    while (i < outcome_count) {
        let conditional_stable = coin_escrow::mint_conditional_stable<
            AssetType,
            StableType,
            StableConditionalCoin,
        >(
            escrow,
            i,
            stable_amount,  // Full amount for each outcome
            ctx,
        );

        vector::push_back(&mut conditional_stables, conditional_stable);
        i = i + 1;
    };

    // Step 3: Swap conditional stables → conditional assets
    let mut conditional_assets = vector::empty<Coin<AssetConditionalCoin>>();

    i = 0;
    while (i < outcome_count) {
        // CRITICAL FIX: Use swap_remove(0) to match forward index
        let conditional_stable = vector::swap_remove(&mut conditional_stables, 0);

        let conditional_asset = swap_core::swap_stable_to_asset<
            AssetType,
            StableType,
            AssetConditionalCoin,
            StableConditionalCoin,
        >(
            swap_session,
            proposal,
            escrow,
            i,
            conditional_stable,
            0,
            clock,
            ctx,
        );

        vector::push_back(&mut conditional_assets, conditional_asset);
        i = i + 1;
    };

    vector::destroy_empty(conditional_stables);

    // Step 4: Find minimum and redeem
    let mut min_amount = std::u64::max_value!();
    i = 0;
    while (i < outcome_count) {
        let amount = vector::borrow(&conditional_assets, i).value();
        if (amount < min_amount) {
            min_amount = amount;
        };
        i = i + 1;
    };

    // Step 5: Burn equal amounts from ALL conditional assets (complete set redemption)
    // MEDIUM SEVERITY FIX: Collect excess tokens to form complete sets instead of creating dust

    // 5a. Collect excess tokens from all outcomes
    let mut excess_assets = vector::empty<Coin<AssetConditionalCoin>>();
    i = 0;
    while (i < outcome_count) {
        let mut conditional_asset = vector::swap_remove(&mut conditional_assets, 0);
        let asset_value = conditional_asset.value();

        // Split excess if it exists
        if (asset_value > min_amount) {
            let excess = coin::split(&mut conditional_asset, asset_value - min_amount, ctx);
            vector::push_back(&mut excess_assets, excess);
        } else {
            // No excess - push empty coin to maintain vector alignment
            vector::push_back(&mut excess_assets, coin::zero<AssetConditionalCoin>(ctx));
        };

        // Burn the minimum amount (complete set)
        coin_escrow::burn_conditional_asset<
            AssetType,
            StableType,
            AssetConditionalCoin,
        >(
            escrow,
            i,
            conditional_asset,  // Now equal to min_amount
        );

        i = i + 1;
    };

    vector::destroy_empty(conditional_assets);

    // 5b. Form complete sets from excess and redeem (instead of creating dust!)
    // Find minimum excess across all outcomes
    let mut min_excess = std::u64::max_value!();
    i = 0;
    while (i < outcome_count) {
        let excess_value = vector::borrow(&excess_assets, i).value();
        if (excess_value < min_excess) {
            min_excess = excess_value;
        };
        i = i + 1;
    };

    // If we have excess complete sets, burn them and withdraw as base tokens
    if (min_excess > 0) {
        i = 0;
        while (i < outcome_count) {
            let mut excess_asset = vector::swap_remove(&mut excess_assets, 0);
            let excess_value = excess_asset.value();

            // Burn min_excess from each outcome (forms complete set)
            if (excess_value > min_excess) {
                let to_burn_excess = coin::split(&mut excess_asset, min_excess, ctx);

                coin_escrow::burn_conditional_asset<
                    AssetType,
                    StableType,
                    AssetConditionalCoin,
                >(
                    escrow,
                    i,
                    to_burn_excess,
                );

                // Deposit remaining dust to registry (< 1 complete set, but user may collect more)
                if (excess_asset.value() > 0) {
                    let proposal_id = object::id(proposal);
                    futarchy_markets::swap_position_registry::store_conditional_asset(
                        registry,
                        recipient,
                        proposal_id,
                        i,
                        excess_asset,
                        clock,
                        ctx,
                    );
                } else {
                    coin::destroy_zero(excess_asset);
                };
            } else {
                // Burn all of it (no remaining dust)
                coin_escrow::burn_conditional_asset<
                    AssetType,
                    StableType,
                    AssetConditionalCoin,
                >(
                    escrow,
                    i,
                    excess_asset,
                );
            };

            i = i + 1;
        };

        // Withdraw redeemed asset from burning excess complete sets
        let excess_redeemed = coin_escrow::withdraw_asset_balance(
            escrow,
            min_excess,
            ctx,
        );

        // Return redeemed base tokens to recipient (complete set, full value)
        transfer::public_transfer(excess_redeemed, recipient);
    } else {
        // No excess complete sets - deposit any dust to registry
        while (!vector::is_empty(&excess_assets)) {
            let excess_dust = vector::pop_back(&mut excess_assets);
            if (excess_dust.value() > 0) {
                let proposal_id = object::id(proposal);
                let outcome_idx = vector::length(&excess_assets);  // Reverse index
                futarchy_markets::swap_position_registry::store_conditional_asset(
                    registry,
                    recipient,
                    proposal_id,
                    outcome_idx,
                    excess_dust,
                    clock,
                    ctx,
                );
            } else {
                coin::destroy_zero(excess_dust);
            };
        };
    };

    vector::destroy_empty(excess_assets);

    // Step 6: Withdraw spot asset from escrow (complete set fully burned)
    // After burning min_amount from ALL outcomes, we can withdraw min_amount once
    let asset_profit = coin_escrow::withdraw_asset_balance(
        escrow,
        min_amount,
        ctx,
    );

    asset_profit
}

// === Optimal Arbitrage (With Bidirectional Solver Integration) ===

/// Execute optimal arbitrage automatically using bidirectional solver
///
/// **NEW AUTONOMOUS ARBITRAGE:**
/// 1. Uses bidirectional solver to find optimal amount and direction
/// 2. Automatically splits coin to exact optimal amount
/// 3. Executes arbitrage with optimal parameters
/// 4. Returns (profit, unused_coin) for capital efficiency
///
/// **Advantages over manual execution:**
/// - No off-chain calculation needed
/// - Automatically finds best direction (Spot→Cond or Cond→Spot)
/// - Optimal capital utilization
/// - Single atomic transaction
///
/// Returns: (arbitrage_profit, unused_coin)
public fun execute_optimal_spot_arbitrage<
    AssetType,
    StableType,
    AssetConditionalCoin,
    StableConditionalCoin,
>(
    spot_pool: &mut UnifiedSpotPool<AssetType, StableType>,
    proposal: &mut Proposal<AssetType, StableType>,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    registry: &mut SwapPositionRegistry<AssetType, StableType>,
    swap_session: &SwapSession,
    mut max_stable_coin: Coin<StableType>,  // Maximum stable willing to use
    mut max_asset_coin: Coin<AssetType>,    // Maximum asset willing to use
    min_profit_threshold: u64,              // Minimum profit to execute
    recipient: address,                     // Who receives dust and complete set redemptions
    clock: &Clock,
    ctx: &mut TxContext,
): (Coin<StableType>, Coin<AssetType>) {
    // Validate outcome count
    let outcome_count = proposal::outcome_count(proposal);
    assert!(outcome_count >= 2, EInvalidOutcomeCount);

    // Get conditional pools for solver
    let market_state = coin_escrow::get_market_state(escrow);
    let conditional_pools = market_state::borrow_amm_pools(market_state);

    // STEP 1: Use bidirectional solver to find optimal arbitrage
    let (optimal_amount, expected_profit, is_spot_to_cond) =
        arbitrage_math::compute_optimal_arbitrage_bidirectional(
            spot_pool,
            conditional_pools,
            min_profit_threshold,
        );

    // If no profitable arbitrage, return coins unchanged
    if (optimal_amount == 0 || expected_profit < (min_profit_threshold as u128)) {
        return (max_stable_coin, max_asset_coin)
    };

    // STEP 2: Execute in the profitable direction
    if (is_spot_to_cond) {
        // Spot → Conditional direction (stable → asset → conditionals → stable)
        let max_stable = max_stable_coin.value();

        // Clamp optimal amount to available stable
        let arb_amount = if (optimal_amount > max_stable) {
            max_stable
        } else {
            optimal_amount
        };

        // Split exact amount needed for arbitrage
        let stable_for_arb = coin::split(&mut max_stable_coin, arb_amount, ctx);

        // Execute arbitrage
        let mut profit = execute_spot_arbitrage_asset_to_stable<
            AssetType,
            StableType,
            AssetConditionalCoin,
            StableConditionalCoin,
        >(
            spot_pool,
            proposal,
            escrow,
            registry,
            swap_session,
            stable_for_arb,
            min_profit_threshold,
            recipient,
            clock,
            ctx,
        );

        // Join profit with any unused stable remainder
        coin::join(&mut profit, max_stable_coin);

        // Return (total_stable, unused_asset)
        (profit, max_asset_coin)
    } else {
        // Conditional → Spot direction (asset → stable → conditionals → asset)
        let max_asset = max_asset_coin.value();

        // Clamp optimal amount to available asset
        let arb_amount = if (optimal_amount > max_asset) {
            max_asset
        } else {
            optimal_amount
        };

        // Split exact amount needed for arbitrage
        let asset_for_arb = coin::split(&mut max_asset_coin, arb_amount, ctx);

        // Execute arbitrage (returns asset profit)
        let mut asset_profit = execute_spot_arbitrage_stable_to_asset<
            AssetType,
            StableType,
            AssetConditionalCoin,
            StableConditionalCoin,
        >(
            spot_pool,
            proposal,
            escrow,
            registry,
            swap_session,
            asset_for_arb,
            min_profit_threshold,
            recipient,
            clock,
            ctx,
        );

        // Join profit with any unused asset remainder
        coin::join(&mut asset_profit, max_asset_coin);

        // Return (unused_stable, total_asset)
        (max_stable_coin, asset_profit)
    }
}


// ============================================================================
// FUTURE UPGRADES - VERSION FIELD CONSIDERATION
// ============================================================================
//
// CURRENT STATE (Version 1.0):
// - No version field in AMM structs (SpotAMM, LiquidityPool)
// - All functions work with all existing pools
// - Additive changes only (new functions, no state migrations)
//
// RECOMMENDATION FOR FUTURE:
// If we need state migrations (e.g., changing fee structures, adding new
// oracle types, modifying reserve calculations), add version field:
//
// ```move
// public struct SpotAMM<phantom AssetType, phantom StableType> has key, store {
//     id: UID,
//     asset_reserve: Balance<AssetType>,
//     stable_reserve: Balance<StableType>,
//     // ... existing fields ...
//
//     // VERSION FIELD (add in next upgrade that changes state)
//     version: u8,  // Current: 1, Future upgrades: 2, 3, etc.
// }
// ```
//
// WHEN TO ADD VERSION FIELD:
// ✅ State migration needed (changing struct fields)
// ✅ Breaking changes to calculation logic
// ✅ Need conditional logic based on pool version
//
// ❌ NOT needed for this upgrade (additive change only)
// ❌ NOT needed for adding new public functions
// ❌ NOT needed for gas optimizations
//
// MIGRATION PATTERN (for future reference):
// ```move
// public fun some_future_function<AssetType, StableType>(
//     pool: &mut SpotAMM<AssetType, StableType>,
//     ...
// ) {
//     if (pool.version == 1) {
//         // V1 logic (backwards compatibility)
//     } else if (pool.version == 2) {
//         // V2 logic (new behavior)
//     }
// }
// ```
//
// ============================================================================


// === Conditional Arbitrage (Cross-Market) ===
//
// These functions enable arbitrage AFTER a conditional swap by:
// 1. Using conditional swap output as arbitrage budget
// 2. Temporarily violating quantum invariant during atomic operations
// 3. Validating invariant restoration at end
//
// Pattern: Burn partial conditionals → spot swap → split → conditional swaps → validate
//
// This is SAFE because:
// - Operations are atomic (no intermediate state exposed)
// - Quantum invariant validated at transaction end
// - Complete sets ensure no value extraction

/// Execute arbitrage after a conditional stable→asset swap
///
/// Strategy (uses swap output as budget):
/// 1. Take conditional asset from swap output
/// 2. Try to extract from ALL conditional markets to form complete set
/// 3. If possible: Burn → spot swap → split → return to conditionals
/// 4. Validate quantum invariant at end
///
/// Returns: (remaining_output, arb_profit)
public fun execute_conditional_arbitrage_stable_to_asset<
    AssetType,
    StableType,
    AssetConditionalCoin,
    StableConditionalCoin,
>(
    spot_pool: &mut UnifiedSpotPool<AssetType, StableType>,
    proposal: &mut Proposal<AssetType, StableType>,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    swap_session: &SwapSession,
    outcome_idx: u64,                      // Which outcome we just swapped in
    mut conditional_asset_output: Coin<AssetConditionalCoin>,  // Output from conditional swap
    min_profit_threshold: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): (Coin<AssetConditionalCoin>, Coin<AssetConditionalCoin>) {
    let outcome_count = proposal::outcome_count(proposal);
    assert!(outcome_count >= 2, EInvalidOutcomeCount);

    let output_amount = conditional_asset_output.value();

    // Use optimal solver to determine best arbitrage amount
    let market_state = coin_escrow::get_market_state(escrow);
    let conditional_pools = market_state::borrow_amm_pools(market_state);

    // Calculate optimal amount using b-parameterization (ternary search)
    let (optimal_arb_amount, expected_profit) = arbitrage_math::compute_optimal_conditional_to_spot<
        AssetType,
        StableType,
    >(
        spot_pool,
        conditional_pools,
        min_profit_threshold,
    );

    // Clamp to available output
    let arb_amount = if (optimal_arb_amount > output_amount) {
        output_amount
    } else {
        optimal_arb_amount
    };

    if (arb_amount == 0 || expected_profit < (min_profit_threshold as u128)) {
        // Not profitable, return unchanged
        return (conditional_asset_output, coin::zero<AssetConditionalCoin>(ctx))
    };

    // Split amount for arbitrage
    let asset_for_arb = coin::split(&mut conditional_asset_output, arb_amount, ctx);

    // Step 1: Burn conditional asset from this outcome and withdraw spot
    // This temporarily breaks quantum invariant (will restore at end)
    coin_escrow::burn_conditional_asset<AssetType, StableType, AssetConditionalCoin>(
        escrow,
        outcome_idx,
        asset_for_arb,
    );
    let spot_asset = coin_escrow::withdraw_asset_balance(escrow, arb_amount, ctx);

    // Step 2: Swap in spot (asset → stable)
    let spot_stable = unified_spot_pool::swap_asset_for_stable(
        spot_pool,
        spot_asset,
        0,
        clock,
        ctx,
    );

    let stable_amount = spot_stable.value();

    // Step 3: Split to conditional stables for ALL outcomes
    let amount_per_outcome = stable_amount / outcome_count;
    let mut conditional_stables = vector::empty<Coin<StableConditionalCoin>>();

    let mut i = 0;
    let mut remaining_stable = spot_stable;
    while (i < outcome_count - 1) {
        let stable_for_outcome = coin::split(&mut remaining_stable, amount_per_outcome, ctx);
        let cond_stable = coin_escrow::deposit_stable_and_mint_conditional<
            AssetType,
            StableType,
            StableConditionalCoin,
        >(escrow, i, stable_for_outcome, ctx);
        vector::push_back(&mut conditional_stables, cond_stable);
        i = i + 1;
    };

    // Last outcome gets remainder
    let last_cond_stable = coin_escrow::deposit_stable_and_mint_conditional<
        AssetType,
        StableType,
        StableConditionalCoin,
    >(escrow, outcome_count - 1, remaining_stable, ctx);
    vector::push_back(&mut conditional_stables, last_cond_stable);

    // Step 4: Swap conditional stables → conditional assets in ALL markets
    let mut conditional_assets = vector::empty<Coin<AssetConditionalCoin>>();

    i = 0;
    while (i < outcome_count) {
        let cond_stable = vector::swap_remove(&mut conditional_stables, 0);
        let cond_asset = swap_core::swap_stable_to_asset<
            AssetType,
            StableType,
            AssetConditionalCoin,
            StableConditionalCoin,
        >(
            swap_session,
            proposal,
            escrow,
            i,
            cond_stable,
            0,
            clock,
            ctx,
        );
        vector::push_back(&mut conditional_assets, cond_asset);
        i = i + 1;
    };
    vector::destroy_empty(conditional_stables);

    // Step 5: Restore position for the swapped outcome
    // The arb should have generated extra tokens
    let outcome_asset = vector::swap_remove(&mut conditional_assets, outcome_idx);

    // Join with original output
    coin::join(&mut conditional_asset_output, outcome_asset);

    // Step 6: Handle other outcomes - keep as profit or recombine
    // For simplicity, burn them back (maintain invariant)
    i = 0;
    while (i < outcome_count) {
        if (i == outcome_idx) {
            // Skip - already handled
            i = i + 1;
            continue
        };

        let other_outcome_asset = if (vector::length(&conditional_assets) > 0) {
            vector::pop_back(&mut conditional_assets)
        } else {
            break
        };

        // Burn it back
        coin_escrow::burn_conditional_asset<AssetType, StableType, AssetConditionalCoin>(
            escrow,
            if (i > outcome_idx) { i - 1 } else { i },
            other_outcome_asset,
        );

        i = i + 1;
    };
    vector::destroy_empty(conditional_assets);

    // Step 7: Validate quantum invariant restored
    coin_escrow::validate_quantum_invariant_2<
        AssetType,
        StableType,
        AssetConditionalCoin,
        AssetConditionalCoin,  // Same type for both outcomes
        StableConditionalCoin,
        StableConditionalCoin,
    >(escrow);

    // Calculate profit (output increased)
    let final_amount = conditional_asset_output.value();
    let profit_amount = if (final_amount > output_amount) {
        final_amount - output_amount
    } else {
        0
    };

    let profit = if (profit_amount > 0) {
        coin::split(&mut conditional_asset_output, profit_amount, ctx)
    } else {
        coin::zero<AssetConditionalCoin>(ctx)
    };

    (conditional_asset_output, profit)
}

/// Execute arbitrage after a conditional asset→stable swap
///
/// Similar to stable_to_asset but in reverse direction
public fun execute_conditional_arbitrage_asset_to_stable<
    AssetType,
    StableType,
    AssetConditionalCoin,
    StableConditionalCoin,
>(
    spot_pool: &mut UnifiedSpotPool<AssetType, StableType>,
    proposal: &mut Proposal<AssetType, StableType>,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    swap_session: &SwapSession,
    outcome_idx: u64,
    mut conditional_stable_output: Coin<StableConditionalCoin>,
    min_profit_threshold: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): (Coin<StableConditionalCoin>, Coin<StableConditionalCoin>) {
    let outcome_count = proposal::outcome_count(proposal);
    assert!(outcome_count >= 2, EInvalidOutcomeCount);

    let output_amount = conditional_stable_output.value();

    // Use optimal solver to determine best arbitrage amount
    let market_state = coin_escrow::get_market_state(escrow);
    let conditional_pools = market_state::borrow_amm_pools(market_state);

    // Calculate optimal amount using b-parameterization
    let (optimal_arb_amount, expected_profit) = arbitrage_math::compute_optimal_conditional_to_spot<
        AssetType,
        StableType,
    >(
        spot_pool,
        conditional_pools,
        min_profit_threshold,
    );

    // Clamp to available output
    let arb_amount = if (optimal_arb_amount > output_amount) {
        output_amount
    } else {
        optimal_arb_amount
    };

    if (arb_amount == 0 || expected_profit < (min_profit_threshold as u128)) {
        return (conditional_stable_output, coin::zero<StableConditionalCoin>(ctx))
    };

    let stable_for_arb = coin::split(&mut conditional_stable_output, arb_amount, ctx);

    // Step 1: Burn conditional stable and withdraw spot
    coin_escrow::burn_conditional_stable<AssetType, StableType, StableConditionalCoin>(
        escrow,
        outcome_idx,
        stable_for_arb,
    );
    let spot_stable = coin_escrow::withdraw_stable_balance(escrow, arb_amount, ctx);

    // Step 2: Swap in spot (stable → asset)
    let spot_asset = unified_spot_pool::swap_stable_for_asset(
        spot_pool,
        spot_stable,
        0,
        clock,
        ctx,
    );

    let asset_amount = spot_asset.value();

    // Step 3: Split to conditional assets
    let amount_per_outcome = asset_amount / outcome_count;
    let mut conditional_assets = vector::empty<Coin<AssetConditionalCoin>>();

    let mut i = 0;
    let mut remaining_asset = spot_asset;
    while (i < outcome_count - 1) {
        let asset_for_outcome = coin::split(&mut remaining_asset, amount_per_outcome, ctx);
        let cond_asset = coin_escrow::deposit_asset_and_mint_conditional<
            AssetType,
            StableType,
            AssetConditionalCoin,
        >(escrow, i, asset_for_outcome, ctx);
        vector::push_back(&mut conditional_assets, cond_asset);
        i = i + 1;
    };

    let last_cond_asset = coin_escrow::deposit_asset_and_mint_conditional<
        AssetType,
        StableType,
        AssetConditionalCoin,
    >(escrow, outcome_count - 1, remaining_asset, ctx);
    vector::push_back(&mut conditional_assets, last_cond_asset);

    // Step 4: Swap conditional assets → stables in ALL markets
    let mut conditional_stables = vector::empty<Coin<StableConditionalCoin>>();

    i = 0;
    while (i < outcome_count) {
        let cond_asset = vector::swap_remove(&mut conditional_assets, 0);
        let cond_stable = swap_core::swap_asset_to_stable<
            AssetType,
            StableType,
            AssetConditionalCoin,
            StableConditionalCoin,
        >(
            swap_session,
            proposal,
            escrow,
            i,
            cond_asset,
            0,
            clock,
            ctx,
        );
        vector::push_back(&mut conditional_stables, cond_stable);
        i = i + 1;
    };
    vector::destroy_empty(conditional_assets);

    // Step 5: Restore and profit
    let outcome_stable = vector::swap_remove(&mut conditional_stables, outcome_idx);
    coin::join(&mut conditional_stable_output, outcome_stable);

    // Burn other outcomes
    i = 0;
    while (i < outcome_count) {
        if (i == outcome_idx) {
            i = i + 1;
            continue
        };

        let other_outcome_stable = if (vector::length(&conditional_stables) > 0) {
            vector::pop_back(&mut conditional_stables)
        } else {
            break
        };

        coin_escrow::burn_conditional_stable<AssetType, StableType, StableConditionalCoin>(
            escrow,
            if (i > outcome_idx) { i - 1 } else { i },
            other_outcome_stable,
        );

        i = i + 1;
    };
    vector::destroy_empty(conditional_stables);

    // Validate invariant
    coin_escrow::validate_quantum_invariant_2<
        AssetType,
        StableType,
        AssetConditionalCoin,
        AssetConditionalCoin,
        StableConditionalCoin,
        StableConditionalCoin,
    >(escrow);

    let final_amount = conditional_stable_output.value();
    let profit_amount = if (final_amount > output_amount) {
        final_amount - output_amount
    } else {
        0
    };

    let profit = if (profit_amount > 0) {
        coin::split(&mut conditional_stable_output, profit_amount, ctx)
    } else {
        coin::zero<StableConditionalCoin>(ctx)
    };

    (conditional_stable_output, profit)
}

