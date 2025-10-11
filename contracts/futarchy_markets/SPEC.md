# Futarchy Markets AMM Spec

## Core Architecture: Hanson-Style Quantum Liquidity

- **Quantum Liquidity Model**: 1 spot token → 1 conditional token in EACH outcome simultaneously (not proportional split)
- **Winner-Takes-All**: Only highest-priced conditional market wins; its tokens redeem 1:1 to spot
- **TreasuryCap-Based**: Native Sui `Coin<T>` types with mint/burn instead of custom token structs
- **Invariant**: `spot_balance == each_outcome_supply` (for ALL outcomes, until finalization)

## Components

### 1. Conditional AMM (`conditional_amm.move`)
- **Type**: Uniswap V2-style constant product (XY=K) AMM per outcome
- **Reserves**: Virtual reserves (no actual liquidity locked - quantum model)
- **Fee Structure**: 0.3% default; 80% to LPs, 20% protocol
- **Oracles**: Dual TWAP (futarchy oracle for winner, SimpleTWAP for external)
- **Live-Flow**: LPs can add/remove liquidity during active proposals
- **No Lock-In**: Liquidity flows freely between spot and conditional pools

### 2. Spot AMM (`spot_amm.move`)
- **Purpose**: Base fair value price oracle (not for external protocols)
- **TWAP Continuity**: Maintains continuous price history across spot ↔ conditional transitions
- **Locking**: Freezes when liquidity moves to proposals; resumes after finalization
- **Backfilling**: Winning conditional's TWAP fills spot's gap during proposal period
- **Window**: 3-day rolling TWAP for founder token minting/protocol decisions

### 3. Coin Escrow (`coin_escrow.move`)
- **TreasuryCap Storage**: Dynamic field storage indexed by `(outcome_index, is_asset)`
- **Quantum Operations**:
  - Split: 100 spot → 100 in outcome 0 + 100 in outcome 1 + ... (simultaneous existence)
  - Recombine: 100 from ALL outcomes → 100 spot (complete set required)
- **Mint/Burn**: Borrow TreasuryCap from storage, operate, return (vector-like access)
- **Escrow Balances**: Central spot asset/stable balances backing all conditional tokens

### 4. Market State (`market_state.move`)
- **Lifecycle**: `PREMARKET → REVIEW → TRADING → FINALIZED`
- **PREMARKET**: Outcomes can be added/mutated; no market yet
- **REVIEW**: Market initialized; review period before trading starts
- **TRADING**: Live price discovery; oracle start times set
- **FINALIZED**: Winner determined; redemption enabled
- **Pool Ownership**: AMM pools live in MarketState (not Proposal)

### 5. Proposal (`proposal.move`)
- **Ownership**: Owns market infrastructure via IDs (escrow_id, market_state_id)
- **Conditional Coins**: Bags store TreasuryCaps + metadata per outcome
- **IntentSpecs**: Action specifications per outcome (executed if outcome wins)
- **Policy Enforcement**: Inline policy data (mode, council_id, approval_proof) locked at creation
- **Early Resolve**: Optional metrics for flip detection (current_winner, last_flip_time)
- **Fee Tracking**: Per-outcome creator fees for refunds

### 6. Swap System (`swap.move`)
- **Hot Potato**: `SwapSession` ensures metrics updated exactly once per PTB
- **Burn-Calculate-Mint**: Burn input conditional → AMM calculation → mint output conditional
- **Batch Operations**: Multiple swaps in single session (gas-efficient for M-of-N trading)
- **Early Resolve**: Metrics recalculated after all swaps complete (flip detection)

### 7. Liquidity Management (`liquidity_interact.move`)
- **Add Liquidity**: Burn conditional coins → update AMM reserves → mint LP tokens
- **Remove Liquidity**: Burn LP tokens → reduce AMM reserves → mint conditional coins
- **Finalization**:
  - User-funded: Return spot liquidity to provider
  - DAO-funded: Return spot liquidity to DAO vault
- **Protocol Fees**: Collect from winning pool after finalization

## Key Innovations

### Quantum Liquidity vs Traditional
- **Traditional**: 100 spot → 50 in outcome A + 50 in outcome B (proportional split)
- **Quantum**: 100 spot → 100 in A + 100 in B + 100 in C + ... (full existence in all)
- **Security**: Manipulation requires attacking ALL conditional markets simultaneously
- **Price Discovery**: Markets compete; highest price wins

### TWAP Continuity
- **Problem**: Spot pool empty during proposals; how to maintain continuous TWAP?
- **Solution**: Freeze spot TWAP at proposal start; use winning conditional's TWAP during proposal; backfill gap after finalization
- **Formula**: `combined_twap = (spot_cumulative_before + conditional_cumulative_during) / total_window`

### Live-Flow Liquidity Model
- **No Locking**: LPs can add/remove during active proposals
- **Proportional Distribution**: Liquidity changes split evenly across all outcome AMMs
- **DAO Control**: DAO can add liquidity mid-proposal if needed
- **Flexibility**: Supports both user-funded and DAO-funded proposals

### TreasuryCap Architecture
- **Why**: Enables native Sui Coin<T> integration (wallets, DEXs, etc.)
- **Storage**: Dynamic fields with vector-like indexing (`outcome_index`)
- **Operations**: Borrow cap → mint/burn → return cap (atomic)
- **Supply Tracking**: `coin::total_supply(cap)` instead of custom Supply objects

## Security Properties

1. **Quantum Invariant**: `spot_balance == outcome_supply` for ALL outcomes (enforced in mint/burn)
2. **Complete Set Requirement**: Recombining requires tokens from ALL outcomes (prevents partial redemption)
3. **Winner-Only Redemption**: Only winning outcome's conditional tokens redeem post-finalization
4. **TWAP Manipulation Resistance**: Requires attacking all conditional markets + frozen spot cumulative
5. **Hot Potato Enforcement**: SwapSession ensures metrics updated (no skip attacks)
6. **Policy Lock-In**: Policy data stored inline at creation (immune to later policy changes)

## Integration Points

### Frontend/SDK Must Provide
- Conditional coin types at compile time (generics required)
- Complete set operations for all outcome counts (2, 3, 4+)
- PTB composition for multi-outcome operations

### Oracle Consumers
- **Internal**: Futarchy oracle for winner determination
- **External**: SimpleTWAP for lending/derivatives (3-day rolling window)
- **Spot TWAP**: Base fair value for founder tokens/protocol decisions

### DAO Integration
- Proposal execution via winning outcome's IntentSpec
- Policy enforcement at proposal creation (OBJECT > TYPE > ACTION hierarchy)
- Fee collection to protocol treasury

## Gas Efficiency

- **Batch Swaps**: ~3× cheaper than separate transactions (metrics updated once)
- **Inline Storage**: 74 bytes vs 446 bytes with shared PolicyRequirement objects
- **No Historical Arrays**: Spot oracle uses rolling window (constant storage)
- **Dynamic Fields**: Vector-like TreasuryCap access without bag overhead

## Limitations

- **Spot TWAP**: Not suitable for external lending (specialized for futarchy)
- **Outcome Count**: Entry functions required per N (2, 3, 4+ outcomes)
- **Type Parameters**: Generic types must be known at compile time
- **Complete Sets**: All outcomes required for spot recombination (no partial)

## Arbitrage via PTBs

### Architecture Decision

**No inline arbitrage** - Arbitrage happens **externally via PTBs (Programmable Transaction Blocks)**

**Why:**
- ✅ PTBs already enable multi-step operations
- ✅ No type parameter complexity (frontend knows conditional types)
- ✅ Off-chain optimization (simulate 100 routes for free)
- ✅ On-chain execution once (gas efficient)

### Tools for Arbitrageurs

**1. Frontend computes optimal amount** (deterministic math)
```typescript
// Step 1: Read current prices
const spotPrice = await getSpotPrice(spotPool);
const conditionalPrices = await Promise.all(
  conditionalPools.map(p => getConditionalPrice(p))
);

// Step 2: Find bottleneck (minimum conditional price)
const targetPrice = Math.min(...conditionalPrices);
const bottleneckIdx = conditionalPrices.indexOf(targetPrice);

// Step 3: Solve for amount that equalizes prices
// For constant product: (stable + x) / (asset - out(x)) = targetPrice
const optimalAmount = solveEquilibrium(spotPool, targetPrice);

// Step 4: Verify profit on-chain
const profit = await calculateProfit(spotPool, conditionalPools, optimalAmount);

if (profit > minProfit) {
  // Execute arbitrage PTB
}
```

**2. `arbitrage_math.move`** - Profit calculation functions
```move
// On-chain: Verify profit for computed amount
let profit = arbitrage_math::calculate_spot_arbitrage_profit(
    spot_pool,
    conditional_pools,
    optimal_amount,  // ← Frontend computed this deterministically
    is_asset_to_stable
);
```

**Key insight**: This is **NOT a search problem!**
- Frontend solves: `spot_price(x) = min(conditional_prices(x))`
- Contract verifies profitability
- No on-chain search needed

**2. `spot_amm.move`** - Simulation functions
```move
// Simulate swaps without executing
let stable_out = spot_amm::simulate_swap_asset_to_stable(pool, amount_in);
let asset_out = conditional_amm::simulate_swap_asset_to_stable(pool, amount_in);
```

### Example PTB: Arbitrage Spot ↔ Conditionals

```typescript
// Off-chain: Optimize amount
const optimal = await simulateArbitrage(spotPool, conditionalPools);

// On-chain: Execute in single PTB
const tx = new Transaction();

// 1. Buy from spot (cheap)
const spotAsset = tx.moveCall({
  target: 'spot_amm::swap_stable_for_asset',
  arguments: [pool, stableIn, minOut, clock]
});

// 2. Split spot → conditionals (quantum!)
const [cond0, cond1] = tx.moveCall({
  target: 'coin_escrow::split_asset_into_complete_set_2',
  arguments: [escrow, spotAsset],
  typeArguments: ['SUI', 'USDC', 'Cond0', 'Cond1']
});

// 3. Sell to conditionals (expensive)
const stable0 = tx.moveCall({
  target: 'swap::swap_asset_to_stable',
  arguments: [proposal, escrow, 0, cond0, minOut, clock]
});
const stable1 = tx.moveCall({
  target: 'swap::swap_asset_to_stable',
  arguments: [proposal, escrow, 1, cond1, minOut, clock]
});

// 4. Recombine (min() constraint enforced here!)
const spotStable = tx.moveCall({
  target: 'coin_escrow::recombine_stable_complete_set_2',
  arguments: [escrow, stable0, stable1],
  typeArguments: ['SUI', 'USDC', 'Cond0Stable', 'Cond1Stable']
});

// 5. Keep profit
tx.transferObjects([spotStable], sender);
```

### Security Properties

**Complete Set Barrier**: Profitable arbitrage requires `min(conditional_outputs) > spot_input`
- Recombination enforces EQUAL amounts from ALL outcomes
- Limited by worst-case conditional pool
- See `ARBITRAGE_ANALYSIS.md` for detailed proofs

### When to Arbitrage

**Profitable when:**
- ALL conditional pools trade at premium to spot
- `min(cond_price_0, cond_price_1, ...) > spot_price`

**Example (profitable):**
```
Spot: SUI at $2.00
Cond 0: c0_SUI at $2.10  ✓
Cond 1: c1_SUI at $2.05  ✓

min(2.10, 2.05) = 2.05 > 2.00 ✓ Profit!
```

**Example (not profitable):**
```
Spot: SUI at $2.00
Cond 0: c0_SUI at $2.10
Cond 1: c1_SUI at $1.90  ✗

min(2.10, 1.90) = 1.90 < 2.00 ✗ Loss!
```
