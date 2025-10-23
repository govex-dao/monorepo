// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

module futarchy_markets_core::liquidity_initialize;

use futarchy_markets_primitives::coin_escrow::TokenEscrow;
use futarchy_markets_primitives::conditional_amm::{Self, LiquidityPool};
use sui::balance::Balance;
use sui::clock::Clock;

// === Introduction ===
// Method to initialize AMM liquidity using TreasuryCap-based conditional coins
// Assumes TreasuryCaps have been registered with escrow before calling this

// === Errors ===
const EInitAssetReservesMismatch: u64 = 100;
const EInitStableReservesMismatch: u64 = 101;
const EInitPoolCountMismatch: u64 = 102;
const EInitPoolOutcomeMismatch: u64 = 103;
const EInitZeroLiquidity: u64 = 104;
const ECapsNotRegistered: u64 = 105;

// === Public Functions ===
/// Create outcome markets using TreasuryCap-based conditional coins
/// IMPORTANT: TreasuryCaps must be registered with escrow BEFORE calling this function
/// The caller (PTB) must have called register_conditional_caps() N times before this
public fun create_outcome_markets<AssetType, StableType>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    outcome_count: u64,
    asset_amounts: vector<u64>,
    stable_amounts: vector<u64>,
    twap_start_delay: u64,
    twap_initial_observation: u128,
    twap_step_max: u64,
    amm_total_fee_bps: u64,
    initial_asset: Balance<AssetType>,
    initial_stable: Balance<StableType>,
    clock: &Clock,
    ctx: &mut TxContext,
): vector<LiquidityPool> {
    assert!(asset_amounts.length() == outcome_count, EInitAssetReservesMismatch);
    assert!(stable_amounts.length() == outcome_count, EInitStableReservesMismatch);

    // Validate that all amounts are non-zero to prevent division by zero in AMM calculations
    let mut j = 0;
    while (j < outcome_count) {
        assert!(asset_amounts[j] > 0, EInitZeroLiquidity);
        assert!(stable_amounts[j] > 0, EInitZeroLiquidity);
        j = j + 1;
    };

    let mut amm_pools = vector[];

    // 1. Deposit spot liquidity into escrow (quantum liquidity model)
    escrow.deposit_spot_liquidity(initial_asset, initial_stable);

    // 2. Create AMM pools for each outcome
    let mut i = 0;
    while (i < outcome_count) {
        let asset_amt = asset_amounts[i];
        let stable_amt = stable_amounts[i];

        let ms = escrow.get_market_state();
        let market_id = futarchy_markets_primitives::market_state::market_id(ms);
        let pool = conditional_amm::new_pool(
            market_id,
            (i as u8),
            amm_total_fee_bps,
            asset_amt,
            stable_amt,
            twap_initial_observation,
            twap_start_delay,
            twap_step_max,
            clock,
            ctx,
        );
        amm_pools.push_back(pool);

        i = i + 1;
    };

    amm_pools
}
