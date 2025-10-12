# Type Parameter Explosion Problem in Move

## Problem Statement

We have successfully eliminated type parameter explosion from ~95% of our conditional market system using `ConditionalMarketBalance` abstraction. However, we still face a bottleneck when **converting balances back to typed coins** for end users.

### Current Architecture

**What Works (No Type Explosion) ✅**

All operations on `ConditionalMarketBalance` only require 2 type parameters:

```move
// Arbitrage - works for ANY outcome count (2, 3, 4, 5, 100...)
public fun execute_optimal_spot_arbitrage<AssetType, StableType>(
    spot_pool: &mut UnifiedSpotPool<AssetType, StableType>,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    session: &SwapSession,
    // ...
): (Coin<StableType>, Coin<AssetType>, option::Option<ConditionalMarketBalance<AssetType, StableType>>)

// Swaps - works for ANY outcome count
public fun swap_balance_asset_to_stable<AssetType, StableType>(
    session: &SwapSession,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    balance: &mut ConditionalMarketBalance<AssetType, StableType>,
    outcome_idx: u8,  // ← Runtime index, not type parameter!
    amount_in: u64,
    // ...
)

// Storage structure - works for ANY outcome count
public struct ConditionalMarketBalance<phantom AssetType, phantom StableType> has key, store {
    id: UID,
    market_id: ID,
    outcome_count: u8,
    balances: vector<u64>,  // [out0_asset, out0_stable, out1_asset, out1_stable, ...]
}
```

**What Doesn't Work (Type Explosion) ❌**

Converting balances back to typed coins requires a type parameter **for each conditional coin type**:

```move
// This function REQUIRES the ConditionalCoinType parameter
public fun unwrap_to_coin<AssetType, StableType, ConditionalCoinType>(
    balance: &mut ConditionalMarketBalance<AssetType, StableType>,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    outcome_idx: u8,
    is_asset: bool,
    ctx: &mut TxContext,
): Coin<ConditionalCoinType> {
    // Must mint typed coin - requires ConditionalCoinType
    let coin = coin_escrow::mint_conditional<AssetType, StableType, ConditionalCoinType>(
        escrow, outcome_idx, is_asset, amount, ctx
    );
    coin
}
```

### Current Workaround (Hardcoded Functions)

We currently have hardcoded functions for each outcome count:

```move
// For 2-outcome markets
public entry fun crank_position_2<AssetType, StableType, Cond0Asset, Cond1Asset, Cond0Stable, Cond1Stable>(
    registry: &mut SwapPositionRegistry<AssetType, StableType>,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    recipient: address,
    ctx: &mut TxContext,
) {
    // ... unwrap all 2*2=4 coins with their specific types
}

// For 3-outcome markets
public entry fun crank_position_3<AssetType, StableType, Cond0Asset, Cond1Asset, Cond2Asset, Cond0Stable, Cond1Stable, Cond2Stable>(...)

// For 4-outcome markets
public entry fun crank_position_4<AssetType, StableType, Cond0Asset, Cond1Asset, Cond2Asset, Cond3Asset, Cond0Stable, Cond1Stable, Cond2Stable, Cond3Stable>(...)

// ... need to hardcode up to 10+ outcomes (potentially 100!)
```

**Problem:** We need to support 2-100 outcomes, which would require 99 hardcoded functions.

## Root Cause Analysis

The bottleneck exists because:

1. **Move's Coin<T> is fundamentally typed** - `Coin<Type0>` ≠ `Coin<Type1>`
2. **Escrow minting requires type parameters**:
   ```move
   public fun mint_conditional<AssetType, StableType, ConditionalCoinType>(
       escrow: &mut TokenEscrow<AssetType, StableType>,
       outcome_index: u64,
       amount: u64,
       ctx: &mut TxContext,
   ): Coin<ConditionalCoinType> {
       let cap: &mut TreasuryCap<ConditionalCoinType> =
           dynamic_field::borrow_mut(&mut escrow.id, asset_key);
       coin::mint(cap, amount, ctx)  // ← Requires typed TreasuryCap
   }
   ```
3. **Move's type system prevents runtime type iteration** - Can't have `vector<Coin<T>>` where T varies per element

## Investigated Solutions

### Solution 1: Phantom Types

**Idea:** Use phantom type parameters that don't appear in fields.

**Analysis:** ❌ Not applicable
- Phantom types are for static type safety without runtime representation
- We need REAL typed `Coin<T>` objects (not phantom)
- Minting/burning requires actual `TreasuryCap<T>` (not phantom)

**Verdict:** Cannot solve this problem.

---

### Solution 2: Programmable Transaction Blocks (PTB)

**Idea:** Let frontend/PTB construct the calls dynamically with specific types.

#### Approach 2A: Direct PTB Dispatch (Shared Object Pattern)

**Current Issue:** Objects with `key` ability (like `ConditionalMarketBalance`) typically cannot be passed by value between PTB calls.

```typescript
// ❌ This doesn't work - can't pass object by value
const balance = tx.moveCall({ target: 'registry::get_balance', ... });
const balance2 = tx.moveCall({
    target: 'registry::unwrap_one',
    arguments: [balance, ...]  // ← balance is an object, not a value
});
```

#### Approach 2B: Hot Potato Pattern ✅

**Key Insight:** Wrap the balance in a hot potato (struct with NO abilities) to force PTB consumption.

```move
// Hot potato wrapper - NO abilities (must be consumed in same transaction)
public struct CrankProgress<phantom AssetType, phantom StableType> {
    balance: ConditionalMarketBalance<AssetType, StableType>,
    outcomes_processed: u8,
}

// Step 1: Start crank (returns hot potato)
public fun start_crank<AssetType, StableType>(
    registry: &mut SwapPositionRegistry<AssetType, StableType>,
    recipient: address,
    ctx: &mut TxContext,
): CrankProgress<AssetType, StableType> {
    let balance = table::remove(&mut registry.positions, key);
    CrankProgress { balance, outcomes_processed: 0 }
}

// Step 2: Unwrap one outcome (consumes + returns hot potato)
public fun unwrap_one<AssetType, StableType, ConditionalCoinType>(
    mut progress: CrankProgress<AssetType, StableType>,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    is_asset: bool,
    recipient: address,
    ctx: &mut TxContext,
): CrankProgress<AssetType, StableType> {
    let coin = unwrap_to_coin<AssetType, StableType, ConditionalCoinType>(
        &mut progress.balance,
        escrow,
        progress.outcomes_processed,
        is_asset,
        ctx
    );
    transfer::public_transfer(coin, recipient);
    progress.outcomes_processed = progress.outcomes_processed + 1;
    progress
}

// Step 3: Finish (consumes hot potato)
public fun finish_crank<AssetType, StableType>(
    progress: CrankProgress<AssetType, StableType>,
) {
    let CrankProgress { balance, outcomes_processed: _ } = progress;
    conditional_balance::destroy_empty(balance);
}
```

**Frontend PTB construction:**
```typescript
// Frontend knows: outcome_count = 3, types = [Cond0Asset, Cond1Asset, Cond2Asset, ...]

const progress0 = tx.moveCall({
    target: 'registry::start_crank',
    typeArguments: [AssetType, StableType],
    arguments: [registry, recipient]
});

const progress1 = tx.moveCall({
    target: 'registry::unwrap_one',
    typeArguments: [AssetType, StableType, Cond0Asset],  // ← Frontend specifies type
    arguments: [progress0, escrow, true, recipient]
});

const progress2 = tx.moveCall({
    target: 'registry::unwrap_one',
    typeArguments: [AssetType, StableType, Cond1Asset],  // ← Next type
    arguments: [progress1, escrow, true, recipient]
});

const progress3 = tx.moveCall({
    target: 'registry::unwrap_one',
    typeArguments: [AssetType, StableType, Cond2Asset],  // ← Next type
    arguments: [progress2, escrow, true, recipient]
});

// Repeat for all outcomes...

tx.moveCall({
    target: 'registry::finish_crank',
    arguments: [progressN]
});
```

**Advantages:**
- ✅ Works for ANY outcome count (2-100+)
- ✅ Frontend constructs the exact PTB needed
- ✅ Hot potato ensures atomic execution
- ✅ No hardcoded on-chain functions needed

**Disadvantages:**
- ⚠️ Frontend complexity (must construct PTB with N calls)
- ⚠️ Gas scales linearly with outcome count (but that's unavoidable)
- ⚠️ Requires frontend to know all conditional coin types

**Verdict:** ✅ **This can work!** Frontend-driven PTB construction with hot potato pattern.

---

### Solution 3: Macros / Code Generation

**Idea:** Use build-time code generation to create `crank_position_2`, `crank_position_3`, etc.

#### Approach 3A: Move Macros

**Analysis:** ❌ Move doesn't have macros like Rust (`macro_rules!`) or C (`#define`)

**Verdict:** Not available in Move.

#### Approach 3B: External Code Generation (Build Script)

**Idea:** Write a script that generates Move code before compilation.

```bash
#!/bin/bash
# generate_crank_functions.sh

for n in {2..100}; do
    # Generate type parameters: Cond0Asset, Cond1Asset, ..., CondNAsset, Cond0Stable, ...
    # Generate function body with N unwrap calls
    # Write to crank_functions.move
done
```

**Generated code:**
```move
// Auto-generated by generate_crank_functions.sh
// DO NOT EDIT MANUALLY

public entry fun crank_position_2<AssetType, StableType, Cond0Asset, Cond1Asset, Cond0Stable, Cond1Stable>(...)
public entry fun crank_position_3<AssetType, StableType, Cond0Asset, Cond1Asset, Cond2Asset, Cond0Stable, Cond1Stable, Cond2Stable>(...)
// ... up to crank_position_100
```

**Advantages:**
- ✅ Simple on-chain API (just call the right function)
- ✅ No frontend complexity
- ✅ Deterministic gas costs

**Disadvantages:**
- ❌ Generates massive amount of code (100 functions × ~50 lines each = 5000 lines)
- ❌ Longer compilation times
- ❌ Larger package size
- ❌ Still need to update script for >100 outcomes

**Verdict:** ⚠️ Works but creates technical debt and bloat.

---

## Recommended Solution

**Use Solution 2B: PTB + Hot Potato Pattern**

### Why This is Best:

1. **Scales to unlimited outcomes** - No hardcoded limit
2. **Clean on-chain code** - Just 3 functions instead of 100
3. **Frontend has the data** - Frontend already knows outcome count and types
4. **Atomic execution** - Hot potato ensures all-or-nothing
5. **No code bloat** - Minimal on-chain code

### Implementation Checklist:

- [ ] Create hot potato wrapper struct `CrankProgress<AssetType, StableType>`
- [ ] Implement `start_crank()` - returns hot potato
- [ ] Implement `unwrap_one<ConditionalCoinType>()` - consumes + returns hot potato
- [ ] Implement `finish_crank()` - final consumption
- [ ] Update frontend to construct PTB dynamically based on outcome count
- [ ] Remove hardcoded `crank_position_2`, `crank_position_3`, etc.

### Alternative: Keep Codegen for Common Cases

If PTB construction is too complex for frontend, we could use a **hybrid approach**:

```move
// On-chain: Hardcoded for common cases (2-5 outcomes)
public entry fun crank_position_2<...>(...)
public entry fun crank_position_3<...>(...)
public entry fun crank_position_4<...>(...)
public entry fun crank_position_5<...>(...)

// On-chain: PTB pattern for rare cases (6+ outcomes)
public fun start_crank<AssetType, StableType>(...)
public fun unwrap_one<AssetType, StableType, ConditionalCoinType>(...)
public fun finish_crank<AssetType, StableType>(...)
```

This gives:
- Simple API for 95% of cases (2-5 outcomes)
- Flexible PTB for edge cases (6-100 outcomes)
- Only 7 total functions instead of 100

## Open Questions for Review

1. **PTB gas limits:** Is there a maximum number of function calls in a single PTB? (Need to verify for 100+ outcome markets)

2. **Frontend complexity:** Is PTB construction too complex for frontend? Should we provide SDK helpers?

3. **Type discovery:** How does frontend discover conditional coin types? (Presumably from market state or escrow inspection)

4. **Backward compatibility:** Do we need to maintain old `crank_position_N` functions for existing users?

5. **Security:** Are there any security implications of the hot potato pattern vs hardcoded functions?

## Summary

| Solution | Pros | Cons | Verdict |
|----------|------|------|---------|
| Phantom Types | - | Not applicable to this problem | ❌ |
| PTB (Shared Object) | - | Objects can't be passed by value | ❌ |
| **PTB (Hot Potato)** | Scales infinitely, clean code | Frontend complexity | ✅ **Recommended** |
| Codegen (100 functions) | Simple API | Code bloat, maintenance burden | ⚠️ Fallback |
| Hybrid (5 + PTB) | Best of both | Two patterns to maintain | ✅ Alternative |

**Final Recommendation:** Implement PTB + Hot Potato pattern for maximum flexibility and clean architecture.
