/// No-arbitrage band enforcement for quantum liquidity futarchy markets
///
/// Prevents arbitrage loops by ensuring spot price stays within bounds implied by:
/// 1. Spot → Conditionals → Spot: buy on spot, mint complete set, sell across outcomes, redeem
/// 2. Conditionals → Spot → Conditionals: buy complete set, recombine to spot, sell
///
/// Mathematical invariant enforced:
/// floor ≤ P_spot ≤ ceiling
/// where:
/// - floor = (1 - f_s) * min_i[(1 - f_i) * p_i]
/// - ceiling = (1/(1 - f_s)) * Σ_i[p_i/(1 - f_i)]
/// - P_s = spot price (stable per asset)
/// - p_i = conditional pool i price (stable/asset ratio)
/// - f_s, f_i = fees in basis points
module futarchy_markets_operations::no_arb_guard;

use futarchy_markets_core::unified_spot_pool::{Self, UnifiedSpotPool};
use futarchy_markets_primitives::conditional_amm::{Self, LiquidityPool};
use futarchy_one_shot_utils::constants;

// === Errors ===
const ENoArbBandViolation: u64 = 0;
const ENoPoolsProvided: u64 = 1;

// === Constants ===
/// Must match spot pool price scale
const PRICE_SCALE: u128 = 1_000_000_000_000; // 1e12

/// Compute instantaneous no-arb floor/ceiling for spot price P_s (stable per asset)
/// given the set of conditional pools and their fees/liquidity.
///
/// Returns: (floor, ceiling) both on PRICE_SCALE (1e12)
///
/// ## Arguments
/// - `spot_pool`: The spot AMM
/// - `pools`: Vector of conditional AMM pools
///
/// ## Returns
/// - `floor`: Minimum spot price that prevents Spot→Cond→Spot arbitrage
/// - `ceiling`: Maximum spot price that prevents Cond→Spot→Cond arbitrage
public fun compute_noarb_band<AssetType, StableType>(
    spot_pool: &UnifiedSpotPool<AssetType, StableType>,
    pools: &vector<LiquidityPool>,
): (u128, u128) {
    let n = pools.length();
    assert!(n > 0, ENoPoolsProvided);

    // Use actual basis points scale (10,000 = 100%) for fee calculations
    let bps = constants::total_fee_bps(); // 10,000 (correct BPS scale)
    let f_s = unified_spot_pool::get_fee_bps(spot_pool); // spot fee in bps
    let one_minus_fs = bps - f_s; // (1 - f_s)*bps

    // floor = (1 - f_s) * min_i [ (1 - f_i) * p_i ]
    // ceiling = (1 / (1 - f_s)) * sum_i [ p_i / (1 - f_i) ]
    let mut min_term: u128 = std::u128::max_value!();
    let mut sum_term: u128 = 0;

    let mut i = 0;
    while (i < n) {
        let pool = &pools[i];
        let (a_i, s_i) = conditional_amm::get_reserves(pool);

        // p_i on PRICE_SCALE: (stable_reserve / asset_reserve) * PRICE_SCALE
        let p_i = if (a_i == 0) {
            0
        } else {
            ((s_i as u128) * PRICE_SCALE) / (a_i as u128)
        };

        let f_i = conditional_amm::get_fee_bps(pool);
        let one_minus_fi = bps - f_i;

        // (1 - f_i) * p_i for floor calculation
        let term_floor = (p_i * (one_minus_fi as u128)) / (bps as u128);
        if (term_floor < min_term) {
            min_term = term_floor;
        };

        // p_i / (1 - f_i) for ceiling calculation
        // Guard divide-by-zero (fee < bps ensured by AMM)
        let term_ceil = if (one_minus_fi > 0) {
            (p_i * (bps as u128)) / (one_minus_fi as u128)
        } else {
            std::u128::max_value!()
        };
        sum_term = sum_term + term_ceil;

        i = i + 1;
    };

    // floor: multiply by (1 - f_s)
    let floor = (min_term * (one_minus_fs as u128)) / (bps as u128);

    // ceiling: divide by (1 - f_s) == multiply by bps / (bps - f_s)
    let ceiling = if (one_minus_fs > 0) {
        (sum_term * (bps as u128)) / (one_minus_fs as u128)
    } else {
        std::u128::max_value!()
    };

    (floor, ceiling)
}

/// Ensures current spot price is within the no-arb band.
/// Call this after running post-swap auto-arb to verify no arbitrage loop exists.
///
/// ## Panics
/// - If spot price is below floor (enables Spot→Cond→Spot arb)
/// - If spot price is above ceiling (enables Cond→Spot→Cond arb)
public fun ensure_spot_in_band<AssetType, StableType>(
    spot_pool: &UnifiedSpotPool<AssetType, StableType>,
    pools: &vector<LiquidityPool>,
) {
    let p_spot = unified_spot_pool::get_spot_price(spot_pool); // Returns u128 on PRICE_SCALE
    let (floor, ceiling) = compute_noarb_band(spot_pool, pools);

    assert!(p_spot >= floor && p_spot <= ceiling, ENoArbBandViolation);
}

/// Check if spot price is within band without reverting
/// Returns: (is_in_band, current_price, floor, ceiling)
public fun check_spot_in_band<AssetType, StableType>(
    spot_pool: &UnifiedSpotPool<AssetType, StableType>,
    pools: &vector<LiquidityPool>,
): (bool, u128, u128, u128) {
    let p_spot = unified_spot_pool::get_spot_price(spot_pool);
    let (floor, ceiling) = compute_noarb_band(spot_pool, pools);
    let is_in_band = p_spot >= floor && p_spot <= ceiling;

    (is_in_band, p_spot, floor, ceiling)
}
