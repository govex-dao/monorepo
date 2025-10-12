# Futarchy AMM Refactor: Eliminating Type Explosion

## Executive Summary

**Problem:** Current AMM architecture suffers from type explosion, requiring separate functions for each outcome count (2, 3, 4, 5 outcomes). This creates:
- Abstraction leak (aggregators must know outcome count)
- Code duplication (10,000+ lines of duplicate code)
- Poor scalability (supporting 10 outcomes = 10 modules)
- Maintenance nightmare

**Solution:** Replace typed `Coin<CondNAsset>` parameters with balance-based `ConditionalMarketBalance` object that tracks all outcome balances in a single `vector<u64>`.

**Impact:**
- ✅ **ONE** swap function replaces 20+ swap functions
- ✅ **ZERO** type parameters beyond base types
- ✅ **ZERO** abstraction leak to aggregators
- ✅ Future-proof for N outcomes (2-200)

**⚠️ BACKWARD COMPATIBILITY:** Not required - clean break architecture.

---

## Table of Contents

1. [Current Architecture (The Problem)](#current-architecture-the-problem)
2. [Proposed Architecture (The Solution)](#proposed-architecture-the-solution)
3. [Detailed Design](#detailed-design)
4. [Migration Strategy](#migration-strategy)
5. [Parallel Implementation Plan](#parallel-implementation-plan)

---

## Current Architecture (The Problem)

### Type Explosion in Action

**File Evidence:**
```
contracts/futarchy_markets/sources/
├── swap_entry_2_outcomes.move       # 482 lines
├── swap_entry_3_outcomes.move       # ~600 lines (estimated)
├── swap_entry_4_outcomes.move       # ~800 lines (estimated)
├── swap_entry_5_outcomes.move       # ~1000 lines (estimated)
├── arbitrage_2_outcomes.move        # 493 lines
├── arbitrage_3_outcomes.move        # ~700 lines (estimated)
├── arbitrage_4_outcomes.move        # ~900 lines (estimated)
└── arbitrage_5_outcomes.move        # ~1100 lines (estimated)
```

**Total: ~5,500 lines of DUPLICATE CODE** 🚨

### Why Type Explosion Happens

**Move's Type System Constraints:**

```move
// ❌ Can't do this: Runtime type indexing
let coin = if (outcome_idx == 0) {
    mint<Cond0Asset>(...)  // Type 0
} else {
    mint<Cond1Asset>(...)  // Type 1 - DIFFERENT TYPE!
};

// ❌ Can't do this: Heterogeneous vectors
let mut coins = vector::empty();
vector::push_back(&mut coins, cond_0_asset);  // Coin<Cond0Asset>
vector::push_back(&mut coins, cond_1_asset);  // Coin<Cond1Asset> - TYPE ERROR!
```

**Current "Solution" - Explicit N-Outcome Modules:**

```move
// swap_entry_2_outcomes.move
public entry fun swap_spot_stable_to_asset_2<
    AssetType,
    StableType,
    Cond0Asset,    // ← 6 type parameters!
    Cond1Asset,
    Cond0Stable,
    Cond1Stable
>(...)

// swap_entry_3_outcomes.move
public entry fun swap_spot_stable_to_asset_3<
    AssetType,
    StableType,
    Cond0Asset,    // ← 12 type parameters!!!
    Cond1Asset,
    Cond2Asset,
    Cond0Stable,
    Cond1Stable,
    Cond2Stable
>(...)
```

### Abstraction Leak to Aggregators

**Current SDK Integration (BAD):**

```typescript
// Aftermath SDK must know outcome count!
const outcomeCount = await getOutcomeCount(proposalId);

if (outcomeCount === 2) {
    // Call 2-outcome function with 6 type params
    tx.moveCall({
        target: `${pkg}::swap_entry_2_outcomes::swap_spot_stable_to_asset_2`,
        typeArguments: [
            assetType,
            stableType,
            cond0Asset, cond1Asset,
            cond0Stable, cond1Stable
        ],
        ...
    });
} else if (outcomeCount === 3) {
    // Call 3-outcome function with 12 type params
    tx.moveCall({
        target: `${pkg}::swap_entry_3_outcomes::swap_spot_stable_to_asset_3`,
        typeArguments: [
            assetType,
            stableType,
            cond0Asset, cond1Asset, cond2Asset,
            cond0Stable, cond1Stable, cond2Stable
        ],
        ...
    });
}
// ... and so on for 4, 5, 6+ outcomes 🤮
```

**This is a MASSIVE abstraction leak!** Aggregators shouldn't need to know internal market structure.

---

## Proposed Architecture (The Solution)

### Core Insight: Decouple Balance Tracking from Types

**Key Realization:** We don't need typed `Coin<CondNAsset>` objects during swaps. We just need:
- **u64 balance tracking** (outcome_idx → amount)
- **Type-safe unwrapping** ONLY when users want actual coins

### The ConditionalMarketBalance Object

```move
/// Single balance object for ALL conditional market operations
struct ConditionalMarketBalance<phantom AssetType, phantom StableType> has key, store {
    id: UID,
    proposal_id: ID,
    outcome_count: u8,

    /// Dense vector: [out0_asset, out0_stable, out1_asset, out1_stable, ...]
    /// Index formula: idx = (outcome_idx * 2) + (is_asset ? 0 : 1)
    balances: vector<u64>,
}
```

**Storage Layout Example (3 outcomes):**
```
balances = [
    100,  // idx 0: Outcome 0 asset balance
    50,   // idx 1: Outcome 0 stable balance
    75,   // idx 2: Outcome 1 asset balance
    80,   // idx 3: Outcome 1 stable balance
    60,   // idx 4: Outcome 2 asset balance
    90,   // idx 5: Outcome 2 stable balance
]
```

### Type Explosion SOLVED! ✅

**Before (Type-Parameterized Hell):**
```move
// 4 different functions for 2, 3, 4, 5 outcomes
swap_entry_2_outcomes::swap_spot_stable_to_asset_2<A, S, C0A, C1A, C0S, C1S>(...)
swap_entry_3_outcomes::swap_spot_stable_to_asset_3<A, S, C0A, C1A, C2A, C0S, C1S, C2S>(...)
swap_entry_4_outcomes::swap_spot_stable_to_asset_4<A, S, ...14 more types...>(...)
swap_entry_5_outcomes::swap_spot_stable_to_asset_5<A, S, ...20 more types...>(...)
```

**After (Type-Agnostic Bliss):**
```move
// ONE function for ALL outcome counts!
public fun swap_conditional<AssetType, StableType>(
    balance: &mut ConditionalMarketBalance<AssetType, StableType>,
    outcome_idx: u8,
    is_asset: bool,    // true = swap TO asset, false = swap TO stable
    amount_in: u64,
    min_out: u64,
) {
    // Calculate indices (runtime)
    let from_idx = (outcome_idx as u64) * 2 + (if (is_asset) 1 else 0);
    let to_idx = (outcome_idx as u64) * 2 + (if (is_asset) 0 else 1);

    // Modify balances directly
    let from_bal = vector::borrow_mut(&mut balance.balances, from_idx);
    *from_bal -= amount_in;

    let to_bal = vector::borrow_mut(&mut balance.balances, to_idx);
    *to_bal += amount_out;
}
```

**Type parameters: 2 → Still 2!** No explosion! 🎉

---

## Detailed Design

### 1. Balance Management Module

**New File: `conditional_balance.move`**

```move
module futarchy_markets::conditional_balance;

/// Create new balance object for a proposal
public fun new<AssetType, StableType>(
    proposal_id: ID,
    outcome_count: u8,
    ctx: &mut TxContext,
): ConditionalMarketBalance<AssetType, StableType> {
    // Initialize with zeros for all outcomes
    let size = (outcome_count as u64) * 2;
    let balances = vector::tabulate!(size, |_| 0u64);

    ConditionalMarketBalance {
        id: object::new(ctx),
        proposal_id,
        outcome_count,
        balances,
    }
}

/// Deposit spot coins to get conditional balances (quantum split)
public fun deposit_for_conditionals<AssetType, StableType>(
    balance: &mut ConditionalMarketBalance<AssetType, StableType>,
    asset_coin: Coin<AssetType>,
    stable_coin: Coin<StableType>,
) {
    let asset_amt = asset_coin.value();
    let stable_amt = stable_coin.value();

    // Deposit to escrow (handled separately)
    // ...

    // Add to ALL outcome balances (quantum!)
    let mut i = 0u64;
    while (i < (balance.outcome_count as u64)) {
        let asset_idx = i * 2;
        let stable_idx = i * 2 + 1;

        *vector::borrow_mut(&mut balance.balances, asset_idx) += asset_amt;
        *vector::borrow_mut(&mut balance.balances, stable_idx) += stable_amt;

        i += 1;
    }
}

/// Get balance for specific outcome + type
public fun get_balance<AssetType, StableType>(
    balance: &ConditionalMarketBalance<AssetType, StableType>,
    outcome_idx: u8,
    is_asset: bool,
): u64 {
    let idx = (outcome_idx as u64) * 2 + (if (is_asset) 0 else 1);
    *vector::borrow(&balance.balances, idx)
}
```

### 2. Generic Unwrap/Wrap Functions

**For Conditional Traders Who Want Real Coins:**

```move
/// Unwrap balance to get actual Coin<ConditionalType>
/// User specifies type explicitly, function derives index from outcome_idx + is_asset
public fun unwrap_to_coin<AssetType, StableType, ConditionalCoinType>(
    balance: &mut ConditionalMarketBalance<AssetType, StableType>,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    outcome_idx: u8,
    is_asset: bool,
    ctx: &mut TxContext,
): Coin<ConditionalCoinType> {
    let idx = (outcome_idx as u64) * 2 + (if (is_asset) 0 else 1);
    let amount = vector::borrow_mut(&mut balance.balances, idx);

    // Mint actual coin from escrow's TreasuryCap
    let coin = coin_escrow::mint_conditional<AssetType, StableType, ConditionalCoinType>(
        escrow,
        outcome_idx,
        is_asset,
        *amount,
        ctx
    );

    // Clear balance
    *amount = 0;

    coin
}

/// Wrap coin back into balance
public fun wrap_coin<AssetType, StableType, ConditionalCoinType>(
    balance: &mut ConditionalMarketBalance<AssetType, StableType>,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    coin: Coin<ConditionalCoinType>,
    outcome_idx: u8,
    is_asset: bool,
) {
    let amount = coin.value();

    // Burn coin back to escrow
    coin_escrow::burn_conditional<AssetType, StableType, ConditionalCoinType>(
        escrow, outcome_idx, is_asset, coin
    );

    // Add to balance
    let idx = (outcome_idx as u64) * 2 + (if (is_asset) 0 else 1);
    let balance_ref = vector::borrow_mut(&mut balance.balances, idx);
    *balance_ref += amount;
}
```

**SDK Usage (for conditional traders):**
```typescript
// User knows they have outcome 0 asset balance
const coin = tx.moveCall({
    target: `${pkg}::conditional_balance::unwrap_to_coin`,
    typeArguments: [
        assetType,
        stableType,
        `${pkg}::Cond0Asset`,  // Type they want
    ],
    arguments: [
        balance,
        escrow,
        tx.pure(0),      // outcome_idx
        tx.pure(true),   // is_asset
    ]
});
```

### 3. Unified Swap Entry Points

**New File: `swap_entry.move` (replaces ALL swap_entry_N_outcomes.move)**

```move
module futarchy_markets::swap_entry;

/// SINGLE spot swap function for ALL outcome counts!
public entry fun swap_spot_stable_to_asset<AssetType, StableType>(
    spot_pool: &mut UnifiedSpotPool<AssetType, StableType>,
    proposal: &mut Proposal<AssetType, StableType>,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    stable_in: Coin<StableType>,
    min_asset_out: u64,
    recipient: address,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // 1. Swap in spot pool
    let asset_out = unified_spot_pool::swap_stable_for_asset(...);

    // 2. Auto-arb if proposal is live (balance-based arbitrage)
    if (proposal::state(proposal) == STATE_TRADING) {
        let registry = unified_spot_pool::validate_arb_objects_and_borrow_registry(...);
        let session = swap_core::begin_swap_session(proposal);

        // Execute arbitrage using balance operations (not typed coins!)
        let (stable_profit, mut asset_with_profit) =
            arbitrage::execute_optimal_spot_arbitrage(
                spot_pool,
                proposal,
                escrow,
                registry,
                &session,
                coin::zero<StableType>(ctx),
                asset_out,
                0,
                recipient,
                clock,
                ctx,
            );

        swap_core::finalize_swap_session(session, proposal, escrow, clock);

        // Return asset + profit
        transfer::public_transfer(asset_with_profit, recipient);
    } else {
        transfer::public_transfer(asset_out, recipient);
    }
}

/// SINGLE conditional swap function for ALL outcome counts!
public entry fun swap_conditional_stable_to_asset<AssetType, StableType>(
    spot_pool: &mut UnifiedSpotPool<AssetType, StableType>,
    proposal: &mut Proposal<AssetType, StableType>,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    balance: &mut ConditionalMarketBalance<AssetType, StableType>,
    outcome_idx: u8,
    stable_in: u64,  // Amount, not Coin!
    min_asset_out: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Swap operates on balance indices
    let session = swap_core::begin_swap_session(proposal);

    swap_core::swap_balance_stable_to_asset(
        &session,
        proposal,
        escrow,
        balance,
        outcome_idx,
        stable_in,
        min_asset_out,
        clock,
    );

    // Auto-arb using balance operations
    arbitrage::execute_conditional_arbitrage_stable_to_asset(
        spot_pool,
        proposal,
        escrow,
        registry,
        &session,
        balance,
        outcome_idx,
        0,  // min_profit
        ctx.sender(),
        clock,
        ctx,
    );

    swap_core::finalize_swap_session(session, proposal, escrow, clock);
}
```

**SDK Integration (CLEAN!):**
```typescript
// Aggregators use ONE function for ALL outcome counts!
tx.moveCall({
    target: `${pkg}::swap_entry::swap_spot_stable_to_asset`,
    typeArguments: [assetType, stableType],  // ← Only 2 types!
    arguments: [spotPool, proposal, escrow, stableCoin, minOut, recipient],
});
```

### 4. Unified Arbitrage Module

**New File: `arbitrage.move` (replaces ALL arbitrage_N_outcomes.move)**

```move
module futarchy_markets::arbitrage;

/// Execute spot arbitrage - works for ANY outcome count!
public fun execute_optimal_spot_arbitrage<AssetType, StableType>(
    spot_pool: &mut UnifiedSpotPool<AssetType, StableType>,
    proposal: &mut Proposal<AssetType, StableType>,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    registry: &mut SwapPositionRegistry<AssetType, StableType>,
    session: &SwapSession,
    stable_for_arb: Coin<StableType>,
    asset_for_arb: Coin<AssetType>,
    min_profit: u64,
    recipient: address,
    clock: &Clock,
    ctx: &mut TxContext,
): (Coin<StableType>, Coin<AssetType>) {
    // Get outcome count dynamically
    let outcome_count = proposal::outcome_count(proposal);

    // Create temporary balance object for arbitrage
    let mut arb_balance = conditional_balance::new<AssetType, StableType>(
        object::id(proposal),
        (outcome_count as u8),
        ctx,
    );

    // Deposit coins for quantum mint
    let asset_amt = asset_for_arb.value();
    let stable_amt = stable_for_arb.value();

    // Add to escrow
    coin_escrow::deposit_for_quantum_mint(escrow, asset_for_arb, stable_for_arb);

    // Update balance (quantum: same amount in ALL outcomes)
    conditional_balance::deposit_for_conditionals(&mut arb_balance, asset_amt, stable_amt);

    // Swap in each conditional market using LOOP!
    let mut i = 0u8;
    while (i < (outcome_count as u8)) {
        swap_core::swap_balance_asset_to_stable(
            session,
            proposal,
            escrow,
            &mut arb_balance,
            i,
            asset_amt,  // Quantum: each outcome has full amount
            0,          // No min (we're arbitraging)
            clock,
        );
        i += 1;
    }

    // Find minimum stable amount across all outcomes (complete set limit)
    let min_stable = conditional_balance::find_min_balance(&arb_balance, false);

    // Store excess in registry (dust)
    i = 0u8;
    while (i < (outcome_count as u8)) {
        let stable_bal = conditional_balance::get_balance(&arb_balance, i, false);
        if (stable_bal > min_stable) {
            let excess = stable_bal - min_stable;
            // Store excess dust
            conditional_balance::withdraw_to_registry(
                &mut arb_balance, registry, i, false, excess, recipient, clock, ctx
            );
        }
        i += 1;
    }

    // Burn complete set → withdraw spot stable
    let profit_stable = conditional_balance::burn_complete_set_and_withdraw(
        &mut arb_balance, escrow, min_stable, false, ctx
    );

    // Clean up balance object
    conditional_balance::destroy_empty(arb_balance);

    (profit_stable, coin::zero<AssetType>(ctx))
}
```

**Key Advantage:** ONE arbitrage function handles 2, 3, 4, 5, or 200 outcomes! 🚀

---

## Migration Strategy

### Phase 1: Core Infrastructure (Parallel Work)

**Agent 1: Balance Module**
- Create `conditional_balance.move`
- Implement `ConditionalMarketBalance` struct
- Implement deposit/withdraw/balance tracking
- Unit tests

**Agent 2: Escrow Refactor**
- Modify `coin_escrow.move` to support balance-based operations
- Add `mint_conditional_from_balance()`
- Add `burn_conditional_to_balance()`
- Keep existing `mint_conditional_asset/stable` for backward compat during transition
- Unit tests

**Agent 3: Unwrap/Wrap Functions**
- Add generic unwrap/wrap to `conditional_balance.move`
- Integration tests with escrow

### Phase 2: Core Swap Refactor (Sequential)

**Agent 1: swap_core.move**
- Add balance-based swap functions:
  - `swap_balance_asset_to_stable()`
  - `swap_balance_stable_to_asset()`
- Keep existing typed swap functions temporarily
- Unit tests

**Agent 2: swap_entry.move (NEW)**
- Create unified swap entry module
- Implement 2 spot swap functions (replaces 8+)
- Implement conditional swap with balance param
- Integration tests

### Phase 3: Arbitrage Refactor (Parallel)

**Agent 1: arbitrage.move (NEW)**
- Create unified arbitrage module
- Implement spot arbitrage with loop over outcomes
- Implement conditional arbitrage with loop
- Use balance operations throughout
- Unit tests

**Agent 2: arbitrage_math.move**
- Update math functions to work with balance vectors
- Add `compute_optimal_arbitrage_for_n_outcomes()`

### Phase 4: Cleanup (Parallel)

**Agent 1: Delete Old Files**
- Remove `swap_entry_2_outcomes.move`
- Remove `swap_entry_3_outcomes.move`
- Remove `swap_entry_4_outcomes.move`
- Remove `swap_entry_5_outcomes.move`

**Agent 2: Delete Old Arbitrage**
- Remove `arbitrage_2_outcomes.move`
- Remove `arbitrage_3_outcomes.move`
- Remove `arbitrage_4_outcomes.move`
- Remove `arbitrage_5_outcomes.move`

**Agent 3: Conditional Coin Wrapper**
- Evaluate if `conditional_coin_wrapper.move` is still needed
- If not, mark deprecated or remove

### Phase 5: Frontend/SDK Update

**Agent 1: SDK Refactor**
- Update Aftermath SDK to use new single-function API
- Remove outcome-count-based routing
- Add balance management utilities

**Agent 2: Documentation**
- Update integration guides
- Add migration guide for existing integrators

---

## Parallel Implementation Plan

### Level 1: Foundation (Can run in parallel)

**Task Group A: Balance Infrastructure**
- **Owner:** Agent A
- **Files:** `conditional_balance.move` (NEW)
- **Dependencies:** None
- **Est:** 2-3 hours
- **Deliverables:**
  - `ConditionalMarketBalance` struct
  - `new()`, `deposit_for_conditionals()`, `get_balance()`
  - `find_min_balance()`, `destroy_empty()`
  - Unit tests

**Task Group B: Escrow Balance Support**
- **Owner:** Agent B
- **Files:** `coin_escrow.move`
- **Dependencies:** None (but will integrate with Task A later)
- **Est:** 2-3 hours
- **Deliverables:**
  - `deposit_for_quantum_mint()` - deposit coins to escrow
  - `mint_conditional()` - generic mint function
  - `burn_conditional()` - generic burn function
  - Unit tests

**Task Group C: Unwrap/Wrap Functions**
- **Owner:** Agent C
- **Files:** `conditional_balance.move` (extends Task A)
- **Dependencies:** Task A (conditional_balance struct), Task B (escrow functions)
- **Est:** 2 hours
- **Deliverables:**
  - `unwrap_to_coin<ConditionalCoinType>()`
  - `wrap_coin<ConditionalCoinType>()`
  - Integration tests with escrow

### Level 2: Core Swaps (Sequential within, parallel between)

**Task Group D: Balance-Based Swap Core**
- **Owner:** Agent D
- **Files:** `swap_core.move`
- **Dependencies:** Task A (balance struct), Task B (escrow operations)
- **Est:** 3-4 hours
- **Deliverables:**
  - `swap_balance_asset_to_stable()`
  - `swap_balance_stable_to_asset()`
  - Keep existing typed swaps for now
  - Unit tests

**Task Group E: Unified Swap Entry**
- **Owner:** Agent E
- **Files:** `swap_entry.move` (NEW)
- **Dependencies:** Task D (balance swaps)
- **Est:** 3-4 hours
- **Deliverables:**
  - `swap_spot_stable_to_asset()`
  - `swap_spot_asset_to_stable()`
  - `swap_conditional_stable_to_asset()`
  - `swap_conditional_asset_to_stable()`
  - Integration tests

### Level 3: Arbitrage Refactor (Parallel)

**Task Group F: Unified Arbitrage Core**
- **Owner:** Agent F
- **Files:** `arbitrage.move` (NEW)
- **Dependencies:** Task D (balance swaps), Task A (balance ops)
- **Est:** 4-5 hours
- **Deliverables:**
  - `execute_optimal_spot_arbitrage()` with loop over outcomes
  - `execute_conditional_arbitrage_stable_to_asset()` with loop
  - `execute_conditional_arbitrage_asset_to_stable()` with loop
  - Unit tests

**Task Group G: Arbitrage Math Update**
- **Owner:** Agent G
- **Files:** `arbitrage_math.move`
- **Dependencies:** Task A (balance struct for types)
- **Est:** 2-3 hours
- **Deliverables:**
  - `compute_optimal_arbitrage_for_n_outcomes()`
  - Update existing math functions for balance vectors
  - Unit tests

### Level 4: Integration & Cleanup (Parallel)

**Task Group H: Integration Tests**
- **Owner:** Agent H
- **Files:** `tests/integration/` (NEW)
- **Dependencies:** Tasks A-G complete
- **Est:** 3-4 hours
- **Deliverables:**
  - End-to-end swap tests (2, 3, 4, 5 outcomes)
  - End-to-end arbitrage tests
  - Unwrap/wrap flow tests
  - Balance lifecycle tests

**Task Group I: Delete Old Swap Files**
- **Owner:** Agent I
- **Files:** `swap_entry_[2-5]_outcomes.move` (DELETE)
- **Dependencies:** Task E complete + Task H passing
- **Est:** 30 minutes
- **Deliverables:**
  - Remove 4 old swap entry files
  - Update Move.toml

**Task Group J: Delete Old Arbitrage Files**
- **Owner:** Agent J
- **Files:** `arbitrage_[2-5]_outcomes.move` (DELETE)
- **Dependencies:** Task F complete + Task H passing
- **Est:** 30 minutes
- **Deliverables:**
  - Remove 4 old arbitrage files
  - Update Move.toml

**Task Group K: Conditional Coin Wrapper Cleanup**
- **Owner:** Agent K
- **Files:** `conditional_coin_wrapper.move`, `conditional_balance_wrapper.move`
- **Dependencies:** Tasks I, J complete
- **Est:** 1 hour
- **Deliverables:**
  - Evaluate if wrappers still needed
  - Mark deprecated or remove
  - Update imports across codebase

### Level 5: SDK & Documentation (Parallel)

**Task Group L: SDK Refactor**
- **Owner:** Agent L (Frontend team)
- **Files:** SDK repository
- **Dependencies:** Tasks A-K complete
- **Est:** 4-6 hours
- **Deliverables:**
  - Update to use single swap API
  - Remove outcome-count routing
  - Add balance management utilities
  - Integration tests

**Task Group M: Documentation Update**
- **Owner:** Agent M
- **Files:** Docs repository
- **Dependencies:** Tasks A-K complete
- **Est:** 2-3 hours
- **Deliverables:**
  - Update integration guides
  - Add migration guide
  - Update API reference
  - Add balance unwrap/wrap examples

---

## Parallelization Summary

**Maximum Parallelism:**

```
Level 1: 3 agents in parallel (A, B, C)
         ↓
Level 2: 2 agents in parallel (D, E)
         ↓
Level 3: 2 agents in parallel (F, G)
         ↓
Level 4: 4 agents in parallel (H, I, J, K)
         ↓
Level 5: 2 agents in parallel (L, M)

Total Time (Critical Path): ~15-20 hours
Total Time (Sequential): ~35-45 hours
Speedup: ~2.2x
```

**Critical Path:** A → D → F → H → I/J

---

## Benefits Summary

### Code Reduction

| Component | Before | After | Reduction |
|-----------|--------|-------|-----------|
| Swap Entry Files | 4 files, ~2,500 lines | 1 file, ~300 lines | **88%** |
| Arbitrage Files | 4 files, ~3,000 lines | 1 file, ~500 lines | **83%** |
| **Total** | **8 files, ~5,500 lines** | **2 files, ~800 lines** | **85%** |

### Scalability

| Outcome Count | Functions Before | Functions After | Improvement |
|---------------|------------------|-----------------|-------------|
| 2 outcomes | 6 | 2 | **67%** fewer |
| 3 outcomes | 12 | 2 | **83%** fewer |
| 4 outcomes | 20 | 2 | **90%** fewer |
| 5 outcomes | 30 | 2 | **93%** fewer |
| **10 outcomes** | **90** | **2** | **98%** fewer |

### Abstraction Leak Fix

**Before:**
- Aggregators need outcome count
- SDK has complex routing logic
- Type parameters explode with N

**After:**
- Aggregators don't know/care about outcomes
- SDK uses single API
- Type parameters constant (2)

---

## Risk Assessment

### Low Risk
- ✅ Balance tracking is simpler than typed coins
- ✅ Index arithmetic is O(1) and simple
- ✅ No backward compatibility needed (clean break)
- ✅ Can implement incrementally (old code still works)

### Medium Risk
- ⚠️ Unwrap/wrap adds extra step for conditional traders
  - **Mitigation:** Only needed when user wants real coins (rare)
- ⚠️ Testing coverage for N outcomes
  - **Mitigation:** Comprehensive integration test suite

### Eliminated Risks
- ✅ Type explosion → Gone (balance-based)
- ✅ Code duplication → Gone (single modules)
- ✅ SDK complexity → Gone (single API)

---

## Success Criteria

1. **Functional:**
   - ✅ All swap operations work for 2-5 outcomes
   - ✅ Arbitrage works for 2-5 outcomes
   - ✅ Unwrap/wrap provides typed coins when needed

2. **Performance:**
   - ✅ Gas costs comparable or better (simpler code)
   - ✅ No additional object allocations

3. **Developer Experience:**
   - ✅ SDK integration is simpler
   - ✅ Code is more maintainable
   - ✅ Easy to add new outcome counts

4. **Code Quality:**
   - ✅ 85% code reduction
   - ✅ Zero type explosion
   - ✅ Zero abstraction leak

---

## Conclusion

This refactor transforms the futarchy AMM from a brittle, type-exploding architecture into an elegant, scalable system. By decoupling balance tracking from types, we achieve:

- **85% code reduction** (5,500 → 800 lines)
- **Type explosion eliminated** (constant 2 type params)
- **Abstraction leak fixed** (single API for aggregators)
- **Future-proof** (works for 2-200 outcomes without changes)

**This is a massive architectural improvement that will pay dividends forever.** 🚀
