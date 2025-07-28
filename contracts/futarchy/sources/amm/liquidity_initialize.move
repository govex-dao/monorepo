module futarchy::liquidity_initialize;

use futarchy::amm::{Self, LiquidityPool};
use futarchy::coin_escrow::TokenEscrow;
use futarchy::conditional_token as token;
use sui::balance::Balance;
use sui::clock::Clock;
use sui::coin::TreasuryCap;

// === Introduction ===
// Method to initialize AMM liquidity

// === Errors ===
const EInitAssetReservesMismatch: u64 = 100;
const EInitStableReservesMismatch: u64 = 101;
const EInitPoolCountMismatch: u64 = 102;
const EInitPoolOutcomeMismatch: u64 = 103;

// === Public Functions ===
public(package) fun create_outcome_markets<AssetType, StableType>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    outcome_count: u64,
    asset_amounts: vector<u64>,
    stable_amounts: vector<u64>,
    twap_start_delay: u64,
    twap_initial_observation: u128,
    twap_step_max: u64,
    initial_asset: Balance<AssetType>,
    initial_stable: Balance<StableType>,
    clock: &Clock,
    ctx: &mut TxContext,
): (vector<ID>, vector<LiquidityPool>) {
    let mut supply_ids = vector[];
    let mut amm_pools = vector[];

    // 1. Create supplies and register them for each outcome
    let mut i = 0;
    while (i < outcome_count) {
        // Use same pattern as original to avoid borrow issues
        {
            let ms = escrow.get_market_state(); // Immutable borrow
            let asset_supply = token::new_supply(ms, 0, (i as u8), ctx);
            let stable_supply = token::new_supply(ms, 1, (i as u8), ctx);
            let lp_supply = token::new_supply(ms, 2, (i as u8), ctx);

            // Record their IDs
            let asset_supply_id = object::id(&asset_supply);
            let stable_supply_id = object::id(&stable_supply);
            let lp_supply_id = object::id(&lp_supply);
            supply_ids.push_back(asset_supply_id);
            supply_ids.push_back(stable_supply_id);
            supply_ids.push_back(lp_supply_id);

            // Register
            escrow.register_supplies(i, asset_supply, stable_supply, lp_supply);
        };

        i = i + 1;
    };

    // 2. Deposit liquidity and handle differential minting in one step
    escrow.deposit_initial_liquidity(
        outcome_count,
        &asset_amounts,
        &stable_amounts,
        initial_asset,
        initial_stable,
        clock,
        ctx,
    );

    // 3. Create AMM pools for each outcome - same as original
    i = 0;
    while (i < outcome_count) {
        let asset_amt = asset_amounts[i];
        let stable_amt = stable_amounts[i];

        // Use same scoped borrow pattern as original
        {
            let ms = escrow.get_market_state(); // Immutable borrow
            let pool = amm::new_pool(
                ms,
                (i as u8),
                asset_amt,
                stable_amt,
                twap_initial_observation,
                twap_start_delay,
                twap_step_max,
                ctx,
            );
            amm_pools.push_back(pool);
        };

        i = i + 1;
    };

    assert_initial_reserves_consistency<AssetType, StableType>(escrow, &amm_pools);

    (supply_ids, amm_pools)
}

fun assert_initial_reserves_consistency<AssetType, StableType>(
    escrow: &TokenEscrow<AssetType, StableType>,
    amm_pools: &vector<LiquidityPool>,
) {
    let outcome_count = escrow.get_market_state().outcome_count();

    assert!(amm_pools.length() == outcome_count, EInitPoolCountMismatch);

    let (escrow_asset, escrow_stable) = escrow.get_balances();

    let mut i = 0;
    while (i < outcome_count) {
        let pool = &amm_pools[i];

        assert!(pool.get_outcome_idx() == (i as u8), EInitPoolOutcomeMismatch);

        let (amm_asset, amm_stable) = pool.get_reserves();
        let protocol_fees = pool.get_protocol_fees();
        assert!(protocol_fees == 0, EInitStableReservesMismatch); // Fees must be 0 initially

        let (
            _fetched_escrow_asset,
            _fetched_escrow_stable,
            asset_total_supply,
            stable_total_supply,
        ) = escrow.get_escrow_balances_and_supply(i);

        // --- Perform the Core Assertions ---

        // Verify asset equation: AMM asset reserves + asset token supply = total escrow asset
        assert!(amm_asset + asset_total_supply == escrow_asset, EInitAssetReservesMismatch);

        // Verify stable equation: AMM stable reserves + protocol fees (0) + stable token supply = total escrow stable
        assert!(
            amm_stable + protocol_fees + stable_total_supply == escrow_stable, // protocol_fees is 0 here
            EInitStableReservesMismatch,
        );

        i = i + 1;
    };
}
