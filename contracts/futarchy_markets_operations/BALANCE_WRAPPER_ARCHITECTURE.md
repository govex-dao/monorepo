# Balance Wrapper Architecture

## Problem Statement

Futarchy markets need to:
1. **Expose standard AMM interface to aggregators** - Standard spot pool for DEX routing
2. **Support N conditional markets** - 2, 3, 5, or 200 outcomes per proposal
3. **Maintain conditional coin composability** - Standard `Coin<T>` types for external DeFi
4. **Avoid type explosion** - Can't have `Pool<Cond0, Cond1, Cond2, ...>` with unbounded type params

## Solution: Balance Wrapper + PTB Unwrapping

### Unified Spot Pool (Aggregator Interface)

**`UnifiedSpotPool<AssetType, StableType>`** exposes standard AMM interface:
- Only 2 type parameters (asset + stable)
- Standard swap/liquidity functions
- Composable with any DEX aggregator (Aftermath, Cetus, etc.)
- Optional aggregator features (TWAP, escrow tracking)

```move
// futarchy_markets_core/sources/spot/unified_spot_pool.move
public struct UnifiedSpotPool<phantom AssetType, phantom StableType> {
    asset_reserve: Balance<AssetType>,
    stable_reserve: Balance<StableType>,
    lp_supply: u64,
    // ... standard AMM fields
    aggregator_config: Option<AggregatorConfig>, // Optional features
}
```

### Conditional Markets (Balance Wrapper)

**Internal**: Use balance wrapper to avoid type explosion
```move
// futarchy_markets_primitives/sources/conditional/conditional_balance.move
public struct ConditionalMarketBalance<phantom AssetType, phantom StableType> {
    balances: vector<u64>, // Dense vector: [out0_asset, out0_stable, out1_asset, ...]
}
```

**Key insight**: Only 2 phantom types, stores balances as u64 values indexed by outcome.

### PTB Unwrapping (External Composability)

**When users need typed coins** for external DeFi:
```move
// Unwrap balance → typed coin (for external use)
public fun unwrap_to_coin<AssetType, StableType, ConditionalCoinType>(
    balance: &mut ConditionalMarketBalance<AssetType, StableType>,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    outcome_idx: u8,
    is_asset: bool,
    ctx: &mut TxContext,
): Coin<ConditionalCoinType>

// Wrap typed coin → balance (return from external use)
public fun wrap_coin<AssetType, StableType, ConditionalCoinType>(
    balance: &mut ConditionalMarketBalance<AssetType, StableType>,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    coin: Coin<ConditionalCoinType>,
    outcome_idx: u8,
    is_asset: bool,
)
```

**User specifies `ConditionalCoinType` in PTB** - type is determined at transaction time, not storage time.

## Arbitrage Flow (Balance Wrapper Usage)

```move
// futarchy_markets_core/sources/arbitrage.move:105
public fun execute_optimal_spot_arbitrage<AssetType, StableType>(
    spot_pool: &mut UnifiedSpotPool<AssetType, StableType>,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    // ...
) {
    // 1. Swap in spot pool (standard AMM interface)
    let asset = unified_spot_pool::swap_stable_for_asset(spot_pool, stable, ...);

    // 2. Create balance wrapper (NO type params for conditionals!)
    let mut arb_balance = conditional_balance::new(market_id, outcome_count, ctx);

    // 3. Deposit to escrow (quantum mint)
    coin_escrow::deposit_spot_coins(escrow, asset, ...);

    // 4. Add to balance for ALL outcomes (loop over outcomes!)
    while (i < outcome_count) {
        conditional_balance::add_to_balance(&mut arb_balance, i, true, amount);
        i = i + 1;
    };

    // 5. Swap in EACH conditional market (loop-based!)
    while (i < outcome_count) {
        swap_core::swap_balance_asset_to_stable(session, escrow, &mut arb_balance, i, ...);
        i = i + 1;
    };

    // 6. Burn complete set → profit
    let profit = burn_complete_set_and_withdraw_stable(&mut arb_balance, escrow, ...);

    // 7. Return dust balance (incomplete set) as NFT to user
    (profit_stable, profit_asset, arb_balance)
}
```

**Key**: One arbitrage function for N outcomes - loops over balance indices instead of type parameters.

## Benefits

### For Aggregators
- ✅ Standard `UnifiedSpotPool<AssetType, StableType>` interface
- ✅ No conditional market complexity exposed
- ✅ Standard swap/liquidity functions
- ✅ Composable with existing DEX routing

### For Conditional Markets
- ✅ Standard `Coin<ConditionalType>` for external DeFi
- ✅ Economically safe (1:1 backing via TreasuryCap)
- ✅ Composable with lending, perps, etc.
- ✅ PTB unwrapping on-demand

### For Internal Operations
- ✅ No type explosion (loop over outcomes)
- ✅ Dynamic outcome counts (2 to 200)
- ✅ Efficient storage (vector of u64)
- ✅ Auto-merge for DCA bots (one NFT per user, not 100)

## Architecture Diagram

```
┌─────────────────────────────────────────────────────────┐
│                    DEX Aggregators                      │
│              (Aftermath, Cetus, etc.)                   │
└────────────────────┬────────────────────────────────────┘
                     │
                     │ Standard AMM Interface
                     ▼
┌─────────────────────────────────────────────────────────┐
│  UnifiedSpotPool<AssetType, StableType>                 │
│  - swap_asset_for_stable()                              │
│  - swap_stable_for_asset()                              │
│  - add_liquidity()                                      │
└────────────────────┬────────────────────────────────────┘
                     │
                     │ Quantum Liquidity Split
                     ▼
┌─────────────────────────────────────────────────────────┐
│  Conditional Markets (N outcomes)                       │
│  - ConditionalMarketBalance<AssetType, StableType>      │
│  - balances: vector<u64>                                │
│  - Loop-based operations (no type params!)              │
└────────────────────┬────────────────────────────────────┘
                     │
                     │ PTB Unwrapping (on-demand)
                     ▼
┌─────────────────────────────────────────────────────────┐
│  External DeFi                                          │
│  - Coin<Cond0Asset>, Coin<Cond1Asset>, ...             │
│  - Standard composable coin types                       │
│  - Lending, perps, spot DEXes                           │
└─────────────────────────────────────────────────────────┘
```

## Implementation Files

1. **Spot Interface**: `futarchy_markets_core/sources/spot/unified_spot_pool.move`
2. **Balance Wrapper**: `futarchy_markets_primitives/sources/conditional/conditional_balance.move`
3. **Arbitrage Logic**: `futarchy_markets_core/sources/arbitrage.move`
4. **Quantum LP Manager**: `futarchy_markets_core/sources/quantum_lp_manager.move`
5. **Token Escrow**: `futarchy_markets_primitives/sources/conditional/coin_escrow.move`

## Key Insight

**Type parameters at transaction time, not storage time.**

- Storage uses balance wrappers (no types)
- Users specify `ConditionalCoinType` in PTB when needed
- Internal operations loop over outcomes (no type explosion)
- External DeFi sees standard `Coin<T>` types

This architecture allows **standard AMM interface for aggregators** while maintaining **full conditional market composability** without type explosion.
