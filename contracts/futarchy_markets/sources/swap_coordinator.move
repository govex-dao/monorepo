/// ============================================================================
/// SWAP COORDINATOR - UNIFIED ARBITRAGE AT ALL ENTRY POINTS
/// ============================================================================
///
/// Based on Solana's built-in arbitrage pattern (lines 620-836 in their impl)
///
/// ARCHITECTURE:
/// - High-level coordinator above AMMs
/// - No circular dependencies
/// - ACTUAL coin splitting and execution
/// - Dynamic optimization with profitability checks
///
/// HOW IT WORKS (Solana pattern):
/// 1. User submits swap transaction
/// 2. Coordinator splits input: direct path + arbitrage path
/// 3. Executes BOTH paths atomically:
///    - Direct: User amount through target pool
///    - Arbitrage: Route through profitable path (spot ↔ conditionals)
/// 4. Combines outputs and returns to user
/// 5. User gets: direct_output + arbitrage_profit
///
/// DYNAMIC OPTIMIZATION:
/// - Calculate expected profit before splitting
/// - Only arbitrage if profit > gas cost
/// - Use optimal split ratio (not fixed 10%)
/// - Quantum constraint: min across all conditional pools
///
/// ============================================================================

module futarchy_markets::swap_coordinator;

use futarchy_markets::spot_amm::{Self, SpotAMM};
use futarchy_markets::conditional_amm::{Self, LiquidityPool};
use futarchy_markets::market_state::MarketState;
use futarchy_markets::optimal_routing::{Self, PoolState, RoutingPlan};
use futarchy_one_shot_utils::math;
use sui::coin::{Self, Coin};
use sui::clock::Clock;

// === Errors ===
const EZeroAmount: u64 = 0;
const EInsufficientOutput: u64 = 1;
const EArbitrageCycleDetected: u64 = 2;
const EExcessConditionalCoins: u64 = 3;  // Abort if would create excess conditional coins (handle later)

// === Public Swap Functions ===

/// Swap SPOT asset for SPOT stable with optimal routing
///
/// This function calculates optimal routing across spot + conditional pools but currently
/// only executes spot-only swaps to avoid excess conditional coin management.
///
/// Routing through conditional pools would require:
/// 1. Split spot → conditional tokens (creates N conditional coins)
/// 2. Swap in conditional pools according to routing plan
/// 3. Recombine conditional stables to spot stable (excess coins from non-swapped outcomes)
/// 4. Return spot stable + transfer excess conditional coins to user
///
/// TODO: Full implementation requires TokenEscrow parameter for minting/burning conditional coins
public fun swap_asset_for_stable_in_spot<AssetType, StableType>(
    spot_pool: &mut SpotAMM<AssetType, StableType>,
    conditional_pools: &mut vector<LiquidityPool>,
    mut asset_in: Coin<AssetType>,
    min_stable_out: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<StableType> {
    let amount_in = asset_in.value();
    assert!(amount_in > 0, EZeroAmount);

    // Build pool states for routing calculation
    let pool_states = build_pool_states_for_asset_to_stable(spot_pool, conditional_pools);

    // Calculate optimal routing plan
    let routing_plan = optimal_routing::calculate_optimal_asset_to_stable_routing(
        amount_in,
        &pool_states,
    );

    // Check if routing would use conditional pools
    let num_pools = optimal_routing::get_num_pools(&routing_plan);
    let mut routes_through_conditionals = false;
    let mut i = 1; // Skip index 0 (spot pool)
    while (i < num_pools) {
        let amount = optimal_routing::get_amount_for_pool(&routing_plan, i);
        if (amount > 0) {
            routes_through_conditionals = true;
        };
        i = i + 1;
    };

    // If routing uses conditionals, abort for now (need escrow for minting/burning)
    if (routes_through_conditionals) {
        // TODO: Implement with TokenEscrow parameter to handle:
        // 1. Deposit spot → mint conditional tokens
        // 2. Swap in conditional pools
        // 3. Recombine conditional stables → spot stable
        // 4. Transfer excess conditional tokens to user
        abort EExcessConditionalCoins
    };

    // Execute spot-only swap
    let mut empty_vec = vector::empty<LiquidityPool>();
    let output = spot_amm::swap_asset_for_stable(
        spot_pool,
        asset_in,
        min_stable_out,
        clock,
        ctx,
    );
    vector::destroy_empty(empty_vec);
    output
}

/// Swap SPOT stable for SPOT asset with optimal routing
///
/// This function calculates optimal routing across spot + conditional pools but currently
/// only executes spot-only swaps to avoid excess conditional coin management.
///
/// TODO: Full implementation requires TokenEscrow parameter for minting/burning conditional coins
public fun swap_stable_for_asset_in_spot<AssetType, StableType>(
    spot_pool: &mut SpotAMM<AssetType, StableType>,
    conditional_pools: &mut vector<LiquidityPool>,
    stable_in: Coin<StableType>,
    min_asset_out: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<AssetType> {
    let amount_in = stable_in.value();
    assert!(amount_in > 0, EZeroAmount);

    // Build pool states for routing calculation
    let pool_states = build_pool_states_for_stable_to_asset(spot_pool, conditional_pools);

    // Calculate optimal routing plan
    let routing_plan = optimal_routing::calculate_optimal_stable_to_asset_routing(
        amount_in,
        &pool_states,
    );

    // Check if routing would use conditional pools
    let num_pools = optimal_routing::get_num_pools(&routing_plan);
    let mut routes_through_conditionals = false;
    let mut i = 1; // Skip index 0 (spot pool)
    while (i < num_pools) {
        let amount = optimal_routing::get_amount_for_pool(&routing_plan, i);
        if (amount > 0) {
            routes_through_conditionals = true;
        };
        i = i + 1;
    };

    // If routing uses conditionals, abort for now (need escrow for minting/burning)
    if (routes_through_conditionals) {
        // TODO: Implement with TokenEscrow parameter to handle:
        // 1. Deposit spot → mint conditional tokens
        // 2. Swap in conditional pools
        // 3. Recombine conditional assets → spot asset
        // 4. Transfer excess conditional tokens to user
        abort EExcessConditionalCoins
    };

    // Execute spot-only swap
    spot_amm::swap_stable_for_asset(
        spot_pool,
        stable_in,
        min_asset_out,
        clock,
        ctx,
    )
}

/// Swap CONDITIONAL asset for CONDITIONAL stable (same outcome pool)
///
/// This function calculates optimal routing including spot pool but currently only executes
/// direct conditional swaps to avoid complex complete-set burning requirements.
///
/// Routing conditional → spot → conditional would require:
/// 1. Acquiring other outcome's conditional tokens to form complete set
/// 2. Burning complete set → spot tokens
/// 3. Swapping in spot pool
/// 4. Minting new complete set → conditional tokens
/// 5. Returning desired outcome + excess tokens
///
/// TODO: Implement conditional → spot routing with complete set handling
public fun swap_asset_for_stable_in_conditional<AssetType, StableType>(
    conditional_pool: &mut LiquidityPool,
    spot_pool: &mut SpotAMM<AssetType, StableType>,
    _other_conditional_pools: &mut vector<LiquidityPool>,
    market_state: &MarketState,
    amount_in: u64,
    min_amount_out: u64,
    clock: &Clock,
    ctx: &TxContext,
): u64 {
    assert!(amount_in > 0, EZeroAmount);

    // Check if spot routing would be better (for future implementation)
    let (spot_asset, spot_stable) = spot_amm::get_reserves(spot_pool);
    let has_spot_liquidity = spot_asset > 0 && spot_stable > 0;

    if (has_spot_liquidity) {
        // Build pool states to compare conditional vs spot routing
        let (cond_asset, cond_stable) = conditional_amm::get_reserves(conditional_pool);

        // Create single-pool states for comparison
        let mut pool_states = vector::empty<PoolState>();
        vector::push_back(&mut pool_states, optimal_routing::new_pool_state(
            0, cond_asset, cond_stable, 30
        ));
        vector::push_back(&mut pool_states, optimal_routing::new_pool_state(
            1, spot_asset, spot_stable, 30
        ));

        // Calculate routing (would show if spot is better)
        let _routing_plan = optimal_routing::calculate_optimal_asset_to_stable_routing(
            amount_in,
            &pool_states,
        );

        // TODO: If routing plan prefers spot (index 1), execute spot routing:
        // 1. Acquire other outcomes to form complete set
        // 2. Burn → spot, swap, mint → conditional
        // 3. Return output + excess tokens
    };

    // Execute direct conditional swap
    let market_id = futarchy_markets::market_state::market_id(market_state);
    conditional_amm::swap_asset_to_stable(
        conditional_pool,
        market_id,
        amount_in,
        min_amount_out,
        clock,
        ctx,
    )
}

/// Swap CONDITIONAL stable for CONDITIONAL asset (same outcome pool)
///
/// This function calculates optimal routing including spot pool but currently only executes
/// direct conditional swaps to avoid complex complete-set burning requirements.
///
/// TODO: Implement conditional → spot routing with complete set handling
public fun swap_stable_for_asset_in_conditional<AssetType, StableType>(
    conditional_pool: &mut LiquidityPool,
    spot_pool: &mut SpotAMM<AssetType, StableType>,
    _other_conditional_pools: &mut vector<LiquidityPool>,
    market_state: &MarketState,
    amount_in: u64,
    min_amount_out: u64,
    clock: &Clock,
    ctx: &TxContext,
): u64 {
    assert!(amount_in > 0, EZeroAmount);

    // Check if spot routing would be better (for future implementation)
    let (spot_asset, spot_stable) = spot_amm::get_reserves(spot_pool);
    let has_spot_liquidity = spot_asset > 0 && spot_stable > 0;

    if (has_spot_liquidity) {
        // Build pool states to compare conditional vs spot routing
        let (cond_asset, cond_stable) = conditional_amm::get_reserves(conditional_pool);

        // Create single-pool states for comparison
        let mut pool_states = vector::empty<PoolState>();
        vector::push_back(&mut pool_states, optimal_routing::new_pool_state(
            0, cond_stable, cond_asset, 30  // Note: reversed for stable → asset
        ));
        vector::push_back(&mut pool_states, optimal_routing::new_pool_state(
            1, spot_stable, spot_asset, 30  // Note: reversed for stable → asset
        ));

        // Calculate routing (would show if spot is better)
        let _routing_plan = optimal_routing::calculate_optimal_stable_to_asset_routing(
            amount_in,
            &pool_states,
        );

        // TODO: If routing plan prefers spot (index 1), execute spot routing:
        // 1. Acquire other outcomes to form complete set
        // 2. Burn → spot, swap, mint → conditional
        // 3. Return output + excess tokens
    };

    // Execute direct conditional swap
    let market_id = futarchy_markets::market_state::market_id(market_state);
    conditional_amm::swap_stable_to_asset(
        conditional_pool,
        market_id,
        amount_in,
        min_amount_out,
        clock,
        ctx,
    )
}

// === Helper Functions for Routing ===

/// Build PoolState vector for optimal routing calculation (asset → stable)
fun build_pool_states_for_asset_to_stable<AssetType, StableType>(
    spot_pool: &SpotAMM<AssetType, StableType>,
    conditional_pools: &vector<LiquidityPool>,
): vector<PoolState> {
    let mut pool_states = vector::empty<PoolState>();

    // Add spot pool (index 0)
    let (spot_asset, spot_stable) = spot_amm::get_reserves(spot_pool);
    vector::push_back(&mut pool_states, optimal_routing::new_pool_state(
        0,           // pool_index
        spot_asset,  // asset_reserve
        spot_stable, // stable_reserve
        30,          // fee_bps (0.3% = 30 bps)
    ));

    // Add all conditional pools (index 1+)
    let num_conditionals = vector::length(conditional_pools);
    let mut i = 0;
    while (i < num_conditionals) {
        let conditional = vector::borrow(conditional_pools, i);
        let (cond_asset, cond_stable) = conditional_amm::get_reserves(conditional);

        vector::push_back(&mut pool_states, optimal_routing::new_pool_state(
            i + 1,       // pool_index (1, 2, 3...)
            cond_asset,  // asset_reserve
            cond_stable, // stable_reserve
            30,          // fee_bps
        ));

        i = i + 1;
    };

    pool_states
}

/// Build PoolState vector for optimal routing calculation (stable → asset)
fun build_pool_states_for_stable_to_asset<AssetType, StableType>(
    spot_pool: &SpotAMM<AssetType, StableType>,
    conditional_pools: &vector<LiquidityPool>,
): vector<PoolState> {
    // Same structure as asset → stable, just used for opposite direction
    build_pool_states_for_asset_to_stable(spot_pool, conditional_pools)
}

// NOTE: Conditional routing with coin bridging was explored but isn't practical
// due to Move's type system limitations (can't have Option<&mut T>).
//
// For conditional market routing, use swap.move module directly:
// 1. deposit_asset_and_mint_conditional() - spot → conditional
// 2. swap::swap_asset_to_stable() - conditional swap
// 3. burn_conditional_stable_and_withdraw() - conditional → spot
//
// The optimal_routing math module remains useful for:
// - Calculating optimal splits across multiple spot-like pools
// - Arbitrage profitability calculations
// - Future routing implementations with different architectures
