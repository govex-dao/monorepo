# Auto-Arbitrage Flow Analysis

## Current Implementation

### 1. Spot Swaps (with Auto-Arb)

**Location:** `swap_entry.move:64-143` and `157-234`

**Flow:**
```
User calls swap_spot_stable_to_asset()
  ↓
1. Execute spot swap (stable → asset in UnifiedSpotPool)
  ↓
2. If proposal state == TRADING:
     - begin_swap_session() (hot potato)
     - execute_optimal_spot_arbitrage() (uses swap output)
     - finalize_swap_session() (updates early resolve metrics ONCE)
     - ensure_spot_in_band() (no-arb guard)
  ↓
3. Transfer result + profit to recipient
```

**Auto-Arb Timing:** **IMMEDIATELY after each spot swap entry function**

**Key:** Arbitrage is triggered PER ENTRY FUNCTION CALL, not batched.

---

### 2. Conditional Swaps (NO Auto-Arb Currently)

**Location:** `swap_entry.move:438-505` and `530-597`

**Flow:**
```
User calls swap_conditional_stable_to_asset()
  ↓
1. begin_swap_session() (hot potato)
  ↓
2. Create temporary balance object
  ↓
3. Wrap coin → balance
  ↓
4. swap_balance_stable_to_asset() (SINGLE outcome market)
  ↓
5. Unwrap balance → coin
  ↓
6. finalize_swap_session() (updates metrics)
  ↓
7. Destroy empty balance
  ↓
8. Transfer coin to caller
```

**Auto-Arb Timing:** **NONE** - Pure single-market swaps, no cross-market arbitrage

---

## Problem: Can't Chain Conditional Swaps Before Arb

### Current Limitation

If a user wants to do:
1. Swap in outcome 0: stable → asset
2. Swap in outcome 1: asset → stable
3. Swap in outcome 2: stable → asset
4. **THEN** trigger auto-arb to close the loop

They **cannot** do this efficiently because:
- Each conditional swap creates/destroys its own balance object
- No way to accumulate balance across multiple conditional swaps
- Auto-arb happens in spot swap entry functions (not exposed for conditional swaps)

### Why This Matters

**Use Case: Cross-Outcome Strategy**
```
Trader believes:
- Outcome 0 is underpriced (buy asset with stable)
- Outcome 1 is overpriced (sell asset for stable)
- Outcome 2 neutral

Strategy:
1. Swap stable → asset in outcome 0 (bet on outcome 0)
2. Swap asset → stable in outcome 1 (bet against outcome 1)
3. (Optional) Swap in outcome 2
4. Trigger arb to close complete set → withdraw profit

Current system: Can't do this efficiently!
```

---

## Proposed Solution: PTB-Friendly Balance-Based Swaps

### Architecture Change

**Add new entry functions that work with persistent balance objects:**

```move
/// NEW: Create balance object for chained swaps
public entry fun create_swap_balance<AssetType, StableType>(
    escrow: &TokenEscrow<AssetType, StableType>,
    ctx: &mut TxContext,
): ConditionalMarketBalance<AssetType, StableType> {
    let market_state = coin_escrow::get_market_state(escrow);
    let market_id = market_state::market_id(market_state);
    let outcome_count = market_state::outcome_count(market_state);

    conditional_balance::new<AssetType, StableType>(
        market_id,
        (outcome_count as u8),
        ctx
    )
}

/// NEW: Swap with existing balance (chainable in PTB)
public fun swap_conditional_with_balance<AssetType, StableType, InputCoin, OutputCoin>(
    balance: &mut ConditionalMarketBalance<AssetType, StableType>,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    session: &SwapSession,
    outcome_idx: u8,
    coin_in: Coin<InputCoin>,
    is_asset_to_stable: bool,  // true = asset→stable, false = stable→asset
    min_amount_out: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<OutputCoin> {
    // Wrap coin → balance
    conditional_balance::wrap_coin(balance, escrow, coin_in, outcome_idx, !is_asset_to_stable);

    // Swap in balance
    let amount_in = if (is_asset_to_stable) {
        conditional_balance::get_balance(balance, outcome_idx, true)
    } else {
        conditional_balance::get_balance(balance, outcome_idx, false)
    };

    if (is_asset_to_stable) {
        swap_core::swap_balance_asset_to_stable(
            session, escrow, balance, outcome_idx, amount_in, min_amount_out, clock, ctx
        )
    } else {
        swap_core::swap_balance_stable_to_asset(
            session, escrow, balance, outcome_idx, amount_in, min_amount_out, clock, ctx
        )
    };

    // Unwrap balance → coin
    conditional_balance::unwrap_to_coin(balance, escrow, outcome_idx, is_asset_to_stable, ctx)
}

/// NEW: Trigger arb on accumulated balance
public entry fun execute_arb_on_balance<AssetType, StableType>(
    balance: ConditionalMarketBalance<AssetType, StableType>,
    spot_pool: &mut UnifiedSpotPool<AssetType, StableType>,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    proposal: &mut Proposal<AssetType, StableType>,
    session: &SwapSession,
    recipient: address,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Find complete set minimum
    let min_asset = conditional_balance::find_min_balance(&balance, true);
    let min_stable = conditional_balance::find_min_balance(&balance, false);

    // Burn complete sets → withdraw spot
    let spot_asset = if (min_asset > 0) {
        arbitrage::burn_complete_set_and_withdraw_asset(&mut balance, escrow, min_asset, ctx)
    } else {
        coin::zero<AssetType>(ctx)
    };

    let spot_stable = if (min_stable > 0) {
        arbitrage::burn_complete_set_and_withdraw_stable(&mut balance, escrow, min_stable, ctx)
    } else {
        coin::zero<StableType>(ctx)
    };

    // Transfer to recipient
    transfer::public_transfer(spot_asset, recipient);
    transfer::public_transfer(spot_stable, recipient);

    // Finalize session
    swap_core::finalize_swap_session(session, proposal, escrow, clock);

    // Cleanup dust (TODO: store in registry instead of destroying)
    // For now, zero out remaining balances
    let outcome_count = conditional_balance::outcome_count(&balance);
    let mut i = 0u8;
    while ((i as u64) < (outcome_count as u64)) {
        conditional_balance::set_balance(&mut balance, i, true, 0);
        conditional_balance::set_balance(&mut balance, i, false, 0);
        i = i + 1;
    };
    conditional_balance::destroy_empty(balance);
}
```

### Frontend PTB Example

```typescript
// Advanced trader strategy: Chain multiple conditional swaps, then arb
const tx = new Transaction();

// Step 1: Begin session (hot potato)
const session = tx.moveCall({
    target: `${PKG}::swap_core::begin_swap_session`,
    typeArguments: [AssetType, StableType],
    arguments: [escrow],
});

// Step 2: Create balance object
const balance = tx.moveCall({
    target: `${PKG}::swap_entry::create_swap_balance`,
    typeArguments: [AssetType, StableType],
    arguments: [escrow],
});

// Step 3: Chain multiple conditional swaps
// Swap in outcome 0: stable → asset
tx.moveCall({
    target: `${PKG}::swap_entry::swap_conditional_with_balance`,
    typeArguments: [AssetType, StableType, Cond0Stable, Cond0Asset],
    arguments: [balance, escrow, session, 0, stableCoin0, false, minOut],
});

// Swap in outcome 1: asset → stable
tx.moveCall({
    target: `${PKG}::swap_entry::swap_conditional_with_balance`,
    typeArguments: [AssetType, StableType, Cond1Asset, Cond1Stable],
    arguments: [balance, escrow, session, 1, assetCoin1, true, minOut],
});

// Swap in outcome 2: stable → asset
tx.moveCall({
    target: `${PKG}::swap_entry::swap_conditional_with_balance`,
    typeArguments: [AssetType, StableType, Cond2Stable, Cond2Asset],
    arguments: [balance, escrow, session, 2, stableCoin2, false, minOut],
});

// Step 4: Trigger arb on accumulated balance (close complete sets)
tx.moveCall({
    target: `${PKG}::swap_entry::execute_arb_on_balance`,
    typeArguments: [AssetType, StableType],
    arguments: [balance, spot_pool, escrow, proposal, session, recipient, clock],
});

// Execute entire PTB atomically
await signAndExecuteTransaction(tx);
```

---

## Benefits of This Approach

### 1. Gas Efficiency ✅
- **Before:** N separate transactions, each with session overhead
- **After:** One PTB with single session, single metrics update

**Gas savings example (3 swaps):**
```
Current:
  - 3 separate calls × session overhead = 3 × 100K = 300K gas wasted

Proposed:
  - 1 PTB with shared session = 100K gas
  - Savings: 200K gas (~67% reduction in overhead)
```

### 2. Advanced Strategies ✅
Enables sophisticated cross-outcome trading:
- **Pairs trading**: Long outcome 0, short outcome 1
- **Spread trading**: Exploit price differences between outcomes
- **Arbitrage loops**: Close complete sets for profit

### 3. Composability ✅
Balance object can be passed between PTB calls:
```
swap_conditional_with_balance() → returns modified balance
  ↓
swap_conditional_with_balance() → returns modified balance
  ↓
execute_arb_on_balance() → closes sets, returns profit
```

### 4. Backward Compatible ✅
- Old entry functions still work (swap and transfer immediately)
- New functions are opt-in for advanced traders
- No breaking changes

---

## Comparison: Current vs Proposed

| Feature | Current | Proposed |
|---------|---------|----------|
| **Spot swap auto-arb** | After each call | After each call (unchanged) |
| **Conditional swap auto-arb** | None | Optional, at end of PTB |
| **Chain multiple conditional swaps** | ❌ Can't accumulate balance | ✅ Balance object persists |
| **Gas efficiency** | N × session overhead | 1 × session overhead |
| **Advanced strategies** | ❌ Limited | ✅ Fully enabled |
| **Complexity** | Simple (immediate transfer) | Medium (manage balance object) |

---

## Recommendation

### ✅ IMPLEMENT THIS

**Reasoning:**

1. **Spot swaps work great as-is** - Auto-arb after each swap makes sense for aggregators
2. **Conditional swaps need flexibility** - Advanced traders want to chain operations
3. **Architecture already supports it** - `ConditionalMarketBalance` and `SwapSession` hot potato patterns are designed for this
4. **Low implementation cost** - Just expose existing patterns via new entry functions
5. **High user value** - Enables sophisticated trading strategies

### Implementation Priority

**Phase 1: Core Functions (1 week)**
- [ ] `create_swap_balance()` - Create balance object
- [ ] `swap_conditional_with_balance()` - Chainable swap
- [ ] `execute_arb_on_balance()` - Close complete sets
- [ ] Unit tests for balance management

**Phase 2: Integration (1 week)**
- [ ] Frontend PTB construction helpers
- [ ] Documentation and examples
- [ ] Testnet validation

**Phase 3: Advanced Features (optional)**
- [ ] Dust handling (store in registry instead of destroying)
- [ ] Batch operations (swap in multiple outcomes atomically)
- [ ] Analytics for complex strategies

---

## Alternative: Keep Current Behavior

If you decide NOT to implement this:

**Pros:**
- ✅ Simpler system (fewer entry functions)
- ✅ Less frontend complexity
- ✅ Lower maintenance burden

**Cons:**
- ❌ Advanced traders can't optimize gas
- ❌ Cross-outcome strategies require multiple transactions
- ❌ Less competitive with other futarchy implementations

**Verdict:** Not recommended. The gas savings and strategic flexibility are worth the moderate implementation cost.

---

## Questions for Design Review

1. **Should `execute_arb_on_balance` be entry or not?**
   - Entry: User can call directly (simpler)
   - Non-entry: Must be in PTB with session (safer)
   - **Recommendation:** Non-entry with session validation

2. **How to handle dust after arb?**
   - Option A: Store in registry (best for users)
   - Option B: Destroy (simpler, loses value)
   - Option C: Return as balance object (complex)
   - **Recommendation:** Store in registry (implement in Phase 3)

3. **Should balance object have `store` ability?**
   - Yes: Can be stored in other objects (more flexible)
   - No: Must be consumed in same transaction (safer)
   - **Recommendation:** No `store` - must be consumed

4. **Session management - one per PTB or one per swap?**
   - Current: One session per PTB (efficient)
   - Alternative: One session per swap (flexible)
   - **Recommendation:** Keep one per PTB (more efficient)

---

## Summary

**Current State:**
- Spot swaps: Auto-arb after each call ✅
- Conditional swaps: No auto-arb, immediate transfer ⚠️

**Proposed Change:**
- Spot swaps: Unchanged ✅
- Conditional swaps: Add optional balance-based pattern with deferred arb ✅

**Why?**
- Gas efficiency: 67% reduction in session overhead for chained swaps
- Advanced strategies: Enable cross-outcome trading
- Architecture fit: Leverages existing `ConditionalMarketBalance` pattern

**Implementation Effort:** Medium (2-3 weeks total)

**User Impact:** High (unlocks sophisticated trading strategies)

**Recommendation:** ✅ **Implement this** - The benefits far outweigh the costs.
