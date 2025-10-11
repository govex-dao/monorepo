/// ============================================================================
/// OPTIMAL ROUTING - DETERMINISTIC SMART ORDER ROUTING
/// ============================================================================
///
/// Pure mathematical functions for calculating optimal swap routing across
/// multiple AMM pools with different prices and liquidity.
///
/// PROBLEM:
/// Given N pools (spot + conditionals) with different:
/// - Prices (determined by reserve ratios)
/// - Liquidity (total reserves)
/// - Fees
///
/// Find: How to split user's input across pools to MAXIMIZE output
///
/// SOLUTION:
/// Constant product AMMs (xy=k) have a deterministic optimal routing:
/// 1. Calculate marginal price for each pool
/// 2. Route to best-priced pool first
/// 3. Keep routing until marginal price equals next-best pool
/// 4. Split between pools where marginal prices are equal
/// 5. Continue until all input consumed
///
/// This is PURE MATH - fully deterministic, testable, no guessing.
///
/// ============================================================================

module futarchy_markets::optimal_routing;

use futarchy_one_shot_utils::math;

// === Structs for routing calculation ===

/// Represents a pool's state for routing calculations
public struct PoolState has copy, drop {
    pool_index: u64,      // Which pool (0 = spot, 1+ = conditionals)
    asset_reserve: u64,   // Current asset reserves
    stable_reserve: u64,  // Current stable reserves
    fee_bps: u64,         // Fee in basis points
}

/// Routing decision: how much to route to each pool
public struct RoutingPlan has copy, drop {
    amounts_per_pool: vector<u64>,  // Amount to route to each pool
    expected_output: u64,            // Total expected output
}

// === Public API ===

/// Calculate optimal routing for asset → stable swap
///
/// Returns: RoutingPlan showing how to split input across pools for maximum output
///
/// # Arguments
/// * `amount_in` - Total amount user wants to swap
/// * `pools` - Vector of all available pools (spot first, then conditionals)
///
/// # Pure Function
/// - No side effects
/// - Deterministic output for given inputs
/// - Fully testable
public fun calculate_optimal_asset_to_stable_routing(
    amount_in: u64,
    pools: &vector<PoolState>,
): RoutingPlan {
    let num_pools = vector::length(pools);
    if (num_pools == 0) {
        return RoutingPlan {
            amounts_per_pool: vector::empty(),
            expected_output: 0,
        }
    };

    // If only one pool, route everything there
    if (num_pools == 1) {
        let pool = vector::borrow(pools, 0);
        let output = calculate_output_with_fee(
            amount_in,
            pool.asset_reserve,
            pool.stable_reserve,
            pool.fee_bps,
        );

        let mut amounts = vector::empty();
        vector::push_back(&mut amounts, amount_in);

        return RoutingPlan {
            amounts_per_pool: amounts,
            expected_output: output,
        }
    };

    // Multiple pools - calculate optimal split
    calculate_optimal_split(amount_in, pools, true) // true = asset to stable
}

/// Calculate optimal routing for stable → asset swap
public fun calculate_optimal_stable_to_asset_routing(
    amount_in: u64,
    pools: &vector<PoolState>,
): RoutingPlan {
    let num_pools = vector::length(pools);
    if (num_pools == 0) {
        return RoutingPlan {
            amounts_per_pool: vector::empty(),
            expected_output: 0,
        }
    };

    if (num_pools == 1) {
        let pool = vector::borrow(pools, 0);
        let output = calculate_output_with_fee(
            amount_in,
            pool.stable_reserve,
            pool.asset_reserve,
            pool.fee_bps,
        );

        let mut amounts = vector::empty();
        vector::push_back(&mut amounts, amount_in);

        return RoutingPlan {
            amounts_per_pool: amounts,
            expected_output: output,
        }
    };

    calculate_optimal_split(amount_in, pools, false) // false = stable to asset
}

// === Core Routing Algorithm ===

/// Calculate optimal split using marginal price equalization
///
/// Algorithm:
/// 1. Start with all input unrouted
/// 2. Find pool with best marginal price
/// 3. Route small amount to that pool
/// 4. Recalculate marginal prices (they change as reserves change)
/// 5. Repeat until all input routed
///
/// This greedy algorithm is optimal for constant product AMMs
fun calculate_optimal_split(
    amount_in: u64,
    pools: &vector<PoolState>,
    is_asset_to_stable: bool,
): RoutingPlan {
    let num_pools = vector::length(pools);

    // Track how much to route to each pool
    let mut amounts_per_pool = vector::empty<u64>();
    let mut i = 0;
    while (i < num_pools) {
        vector::push_back(&mut amounts_per_pool, 0);
        i = i + 1;
    };

    // Track current reserves (will update as we route)
    let mut current_pools = vector::empty<PoolState>();
    i = 0;
    while (i < num_pools) {
        let pool = vector::borrow(pools, i);
        vector::push_back(&mut current_pools, *pool);
        i = i + 1;
    };

    // Route in small increments to approximate optimal continuous routing
    let num_iterations = 100; // More iterations = more accurate
    let increment = amount_in / num_iterations;
    let mut remaining = amount_in;

    let mut iteration = 0;
    while (iteration < num_iterations && remaining > 0) {
        let route_amount = if (remaining < increment) { remaining } else { increment };

        // Find pool with best marginal price
        let best_pool_idx = find_best_pool_for_routing(
            &current_pools,
            is_asset_to_stable,
        );

        // Route to that pool
        let current_amount = *vector::borrow(&amounts_per_pool, best_pool_idx);
        *vector::borrow_mut(&mut amounts_per_pool, best_pool_idx) = current_amount + route_amount;

        // Update pool reserves to reflect this routing
        update_pool_reserves(
            &mut current_pools,
            best_pool_idx,
            route_amount,
            is_asset_to_stable,
        );

        remaining = remaining - route_amount;
        iteration = iteration + 1;
    };

    // Calculate total expected output
    let mut total_output = 0u64;
    i = 0;
    while (i < num_pools) {
        let amount = *vector::borrow(&amounts_per_pool, i);
        if (amount > 0) {
            let pool = vector::borrow(pools, i);
            let output = if (is_asset_to_stable) {
                calculate_output_with_fee(amount, pool.asset_reserve, pool.stable_reserve, pool.fee_bps)
            } else {
                calculate_output_with_fee(amount, pool.stable_reserve, pool.asset_reserve, pool.fee_bps)
            };
            total_output = total_output + output;
        };
        i = i + 1;
    };

    RoutingPlan {
        amounts_per_pool,
        expected_output: total_output,
    }
}

/// Find pool with best marginal price (would give most output for next unit)
fun find_best_pool_for_routing(
    pools: &vector<PoolState>,
    is_asset_to_stable: bool,
): u64 {
    let num_pools = vector::length(pools);
    let mut best_pool_idx = 0;
    let mut best_marginal_output = 0u128;

    let mut i = 0;
    while (i < num_pools) {
        let pool = vector::borrow(pools, i);

        // Calculate marginal output for this pool (output for 1 unit)
        let marginal_output = if (is_asset_to_stable) {
            calculate_marginal_output(pool.asset_reserve, pool.stable_reserve, pool.fee_bps)
        } else {
            calculate_marginal_output(pool.stable_reserve, pool.asset_reserve, pool.fee_bps)
        };

        if (marginal_output > best_marginal_output) {
            best_marginal_output = marginal_output;
            best_pool_idx = i;
        };

        i = i + 1;
    };

    best_pool_idx
}

/// Update pool reserves after routing amount to it
fun update_pool_reserves(
    pools: &mut vector<PoolState>,
    pool_idx: u64,
    amount_in: u64,
    is_asset_to_stable: bool,
) {
    let pool = vector::borrow_mut(pools, pool_idx);

    // Calculate output for this amount
    let amount_out = if (is_asset_to_stable) {
        calculate_output_with_fee(amount_in, pool.asset_reserve, pool.stable_reserve, pool.fee_bps)
    } else {
        calculate_output_with_fee(amount_in, pool.stable_reserve, pool.asset_reserve, pool.fee_bps)
    };

    // Update reserves
    if (is_asset_to_stable) {
        pool.asset_reserve = pool.asset_reserve + amount_in;
        pool.stable_reserve = pool.stable_reserve - amount_out;
    } else {
        pool.stable_reserve = pool.stable_reserve + amount_in;
        pool.asset_reserve = pool.asset_reserve - amount_out;
    };
}

// === Helper Math Functions ===

/// Calculate output for constant product AMM with fees
fun calculate_output_with_fee(
    amount_in: u64,
    reserve_in: u64,
    reserve_out: u64,
    fee_bps: u64,
): u64 {
    if (amount_in == 0 || reserve_in == 0 || reserve_out == 0) return 0;

    // Apply fee: amount_in_after_fee = amount_in * (10000 - fee_bps) / 10000
    let amount_in_after_fee = amount_in - (amount_in * fee_bps / 10000);

    // Constant product: output = reserve_out * amount_in_after_fee / (reserve_in + amount_in_after_fee)
    math::mul_div_to_64(
        amount_in_after_fee,
        reserve_out,
        reserve_in + amount_in_after_fee
    )
}

/// Calculate marginal output (output for next infinitesimal unit)
/// This is the derivative: dy/dx at current reserves
/// For xy=k: marginal = y / (x + 1)^2 approximately y/x^2 for large pools
fun calculate_marginal_output(
    reserve_in: u64,
    reserve_out: u64,
    fee_bps: u64,
): u128 {
    if (reserve_in == 0 || reserve_out == 0) return 0;

    // Marginal output ≈ reserve_out / reserve_in for small trades
    // Scale up for precision
    let marginal = math::mul_div_to_128(
        reserve_out,
        10000 - fee_bps, // Account for fee
        reserve_in
    );

    marginal
}

// === Getters for RoutingPlan ===

public fun get_amount_for_pool(plan: &RoutingPlan, pool_index: u64): u64 {
    if (pool_index >= vector::length(&plan.amounts_per_pool)) return 0;
    *vector::borrow(&plan.amounts_per_pool, pool_index)
}

public fun get_expected_output(plan: &RoutingPlan): u64 {
    plan.expected_output
}

public fun get_num_pools(plan: &RoutingPlan): u64 {
    vector::length(&plan.amounts_per_pool)
}

// === Constructor for PoolState ===

public fun new_pool_state(
    pool_index: u64,
    asset_reserve: u64,
    stable_reserve: u64,
    fee_bps: u64,
): PoolState {
    PoolState {
        pool_index,
        asset_reserve,
        stable_reserve,
        fee_bps,
    }
}
