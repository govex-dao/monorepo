# LP Withdrawal System Implementation Plan

## Architecture Overview

### 3-Bucket System

Each AMM (spot + conditionals) tracks liquidity in buckets:

```
Spot AMM:
├─ LIVE           ← Quantum-splits for next proposal
├─ TRANSITIONING  ← Won't quantum-split, but still trades in current proposal
└─ WITHDRAW-ONLY  ← Frozen, no trading, ready to claim (SPOT ONLY)

Conditional AMM (each outcome):
├─ LIVE           ← Came from spot.LIVE via quantum split
└─ TRANSITIONING  ← Came from spot.TRANSITIONING via quantum split
```

**Key Insight:** Conditionals don't have WITHDRAW-ONLY. That bucket only exists in spot after recombination.

---

## Data Structures

### 1. UnifiedSpotPool Changes

```move
public struct UnifiedSpotPool<phantom AssetType, phantom StableType> has key {
    id: UID,

    // Asset reserves (split across buckets)
    asset_reserve: Balance<AssetType>,
    asset_live: u64,           // NEW: Amount in LIVE bucket
    asset_transitioning: u64,  // NEW: Amount in TRANSITIONING bucket
    asset_withdraw_only: u64,  // NEW: Amount in WITHDRAW-ONLY bucket

    // Stable reserves (split across buckets)
    stable_reserve: Balance<StableType>,
    stable_live: u64,           // NEW
    stable_transitioning: u64,  // NEW
    stable_withdraw_only: u64,  // NEW

    // LP supply tracking (split across buckets)
    lp_supply: u64,
    lp_live: u64,           // NEW: LP tokens in LIVE
    lp_transitioning: u64,  // NEW: LP tokens in TRANSITIONING
    lp_withdraw_only: u64,  // NEW: LP tokens in WITHDRAW-ONLY

    // Existing fields...
    locked_to_proposal: Option<ID>,
    simple_twap: SimpleTWAP,
    // ...
}
```

**Invariants:**
```move
asset_live + asset_transitioning + asset_withdraw_only == asset_reserve.value()
stable_live + stable_transitioning + stable_withdraw_only == stable_reserve.value()
lp_live + lp_transitioning + lp_withdraw_only == lp_supply
```

### 2. LPToken (NFT Receipt) Changes

```move
public struct LPToken<phantom AssetType, phantom StableType> has key, store {
    id: UID,
    amount: u64,  // Total LP tokens owned
    locked_in_proposal: Option<ID>,
    withdraw_mode: bool,  // NEW: Set to true when user wants to withdraw
}
```

**State Machine:**
```
withdraw_mode=false → User sets → withdraw_mode=true
                                       ↓
                         Crank moves LP to withdraw_only bucket
                                       ↓
                         User calls withdraw() → Destroys NFT, claims coins
```

### 3. Conditional AMM Changes

```move
public struct LiquidityPool has store {
    id: UID,
    outcome_idx: u8,

    // Virtual reserves (split across buckets)
    virtual_asset_reserve: u64,
    asset_live: u64,           // NEW
    asset_transitioning: u64,  // NEW

    virtual_stable_reserve: u64,
    stable_live: u64,           // NEW
    stable_transitioning: u64,  // NEW

    // LP supply (split across buckets)
    lp_supply: u64,
    lp_live: u64,           // NEW
    lp_transitioning: u64,  // NEW

    // Existing fields...
    oracle: SimpleTWAP,
    // ...
}
```

---

## State Transitions

### 1. User Marks for Withdrawal

**Function:** `mark_for_withdrawal(pool, lp_token)`

**Case A: Active Proposal**
```move
if (pool.has_active_proposal()) {
    // Move from LIVE → TRANSITIONING
    // Still trades, won't quantum-split next time
    let lp_amount = lp_token.amount;

    // Update spot pool buckets
    pool.lp_live -= lp_amount;
    pool.lp_transitioning += lp_amount;

    // Proportionally move reserves
    let asset_to_move = (lp_amount * pool.asset_live) / pool.lp_live;
    let stable_to_move = (lp_amount * pool.stable_live) / pool.lp_live;

    pool.asset_live -= asset_to_move;
    pool.asset_transitioning += asset_to_move;
    pool.stable_live -= stable_to_move;
    pool.stable_transitioning += stable_to_move;

    // Mark token
    lp_token.withdraw_mode = true;
}
```

**Case B: No Active Proposal**
```move
else {
    // Move from LIVE → WITHDRAW_ONLY (immediate)
    let lp_amount = lp_token.amount;

    pool.lp_live -= lp_amount;
    pool.lp_withdraw_only += lp_amount;

    // Proportionally move reserves
    let asset_to_move = (lp_amount * pool.asset_live) / pool.lp_live;
    let stable_to_move = (lp_amount * pool.stable_live) / pool.lp_live;

    pool.asset_live -= asset_to_move;
    pool.asset_withdraw_only += asset_to_move;
    pool.stable_live -= stable_to_move;
    pool.stable_withdraw_only += stable_to_move;

    // Mark token
    lp_token.withdraw_mode = true;
}
```

### 2. Quantum Split (Proposal Starts)

**Function:** `auto_quantum_split_on_proposal_start(spot_pool, escrow, ratio)`

**CRITICAL: Only split LIVE bucket**

```move
// Calculate amounts to quantum-split (LIVE ONLY)
let asset_to_split = (spot_pool.asset_live * ratio) / 100;
let stable_to_split = (spot_pool.stable_live * ratio) / 100;
let lp_to_split = (spot_pool.lp_live * ratio) / 100;

// Mint conditional coins (quantum: 1 spot → 1 per outcome)
for each outcome {
    escrow.mint_conditional_asset(outcome, asset_to_split);
    escrow.mint_conditional_stable(outcome, stable_to_split);

    // Initialize conditional pool with bucket tracking
    conditional_pool[outcome].asset_live = asset_to_split;
    conditional_pool[outcome].stable_live = stable_to_split;
    conditional_pool[outcome].lp_live = lp_to_split;

    conditional_pool[outcome].asset_transitioning = 0;  // Empty initially
    conditional_pool[outcome].stable_transitioning = 0;
    conditional_pool[outcome].lp_transitioning = 0;
}

// Reduce spot pool LIVE bucket
spot_pool.asset_live -= asset_to_split;
spot_pool.stable_live -= stable_to_split;
spot_pool.lp_live -= lp_to_split;

// TRANSITIONING and WITHDRAW_ONLY buckets are NOT touched
```

### 3. Recombination (Proposal Ends - THE CRANK)

**Function:** `crank_recombine_and_transition(proposal, escrow, spot_pool)`

**This is the critical function that moves TRANSITIONING → WITHDRAW_ONLY**

```move
let winning_outcome = proposal.winning_outcome;
let winning_pool = conditional_pools[winning_outcome];

// === LIVE bucket recombination ===
// Burn conditional coins, return to spot LIVE
let asset_live = winning_pool.asset_live;
let stable_live = winning_pool.stable_live;
let lp_live = winning_pool.lp_live;

escrow.burn_conditional_asset(winning_outcome, asset_live);
escrow.burn_conditional_stable(winning_outcome, stable_live);

spot_pool.asset_live += asset_live;
spot_pool.stable_live += stable_live;
spot_pool.lp_live += lp_live;

// === TRANSITIONING bucket recombination ===
// Burn conditional coins, return to spot WITHDRAW_ONLY (frozen!)
let asset_trans = winning_pool.asset_transitioning;
let stable_trans = winning_pool.stable_transitioning;
let lp_trans = winning_pool.lp_transitioning;

escrow.burn_conditional_asset(winning_outcome, asset_trans);
escrow.burn_conditional_stable(winning_outcome, stable_trans);

spot_pool.asset_withdraw_only += asset_trans;    // ← Goes to WITHDRAW_ONLY!
spot_pool.stable_withdraw_only += stable_trans;  // ← Frozen, no more trading
spot_pool.lp_withdraw_only += lp_trans;          // ← Ready to claim

// === Losing outcomes ===
// Conditional coins become worthless (quantum collapse)
for each losing_outcome {
    // Do nothing - conditional coins stay in escrow but can't be redeemed
}
```

### 4. User Claims Withdrawal

**Function:** `withdraw(spot_pool, lp_token)`

```move
assert!(lp_token.withdraw_mode == true, ENotMarkedForWithdrawal);
assert!(lp_token.locked_in_proposal.is_none(), EStillLocked);

let lp_amount = lp_token.amount;

// Calculate proportional share of WITHDRAW_ONLY bucket
let asset_out = (lp_amount * spot_pool.asset_withdraw_only) / spot_pool.lp_withdraw_only;
let stable_out = (lp_amount * spot_pool.stable_withdraw_only) / spot_pool.lp_withdraw_only;

// Update buckets
spot_pool.asset_withdraw_only -= asset_out;
spot_pool.stable_withdraw_only -= stable_out;
spot_pool.lp_withdraw_only -= lp_amount;

// Extract coins from balances
let asset_coin = coin::take(&mut spot_pool.asset_reserve, asset_out, ctx);
let stable_coin = coin::take(&mut spot_pool.stable_reserve, stable_out, ctx);

// Destroy LP token (NFT burned)
let LPToken { id, amount: _, locked_in_proposal: _, withdraw_mode: _ } = lp_token;
object::delete(id);

// Transfer to user
transfer::public_transfer(asset_coin, ctx.sender());
transfer::public_transfer(stable_coin, ctx.sender());
```

---

## Functions to Implement

### unified_spot_pool.move

```move
// === New Functions ===

/// Mark LP for withdrawal (user-triggered)
public fun mark_lp_for_withdrawal<AssetType, StableType>(
    pool: &mut UnifiedSpotPool<AssetType, StableType>,
    lp_token: &mut LPToken<AssetType, StableType>,
)

/// Withdraw LP (user-triggered, after crank)
public fun withdraw_lp<AssetType, StableType>(
    pool: &mut UnifiedSpotPool<AssetType, StableType>,
    lp_token: LPToken<AssetType, StableType>,
    ctx: &mut TxContext,
): (Coin<AssetType>, Coin<StableType>)

/// Internal: Move LP from LIVE → TRANSITIONING
fun move_live_to_transitioning<AssetType, StableType>(
    pool: &mut UnifiedSpotPool<AssetType, StableType>,
    lp_amount: u64,
)

/// Internal: Move LP from LIVE → WITHDRAW_ONLY (no active proposal)
fun move_live_to_withdraw_only<AssetType, StableType>(
    pool: &mut UnifiedSpotPool<AssetType, StableType>,
    lp_amount: u64,
)

/// Check if pool has active proposal
public fun has_active_proposal<AssetType, StableType>(
    pool: &UnifiedSpotPool<AssetType, StableType>
): bool {
    pool.locked_to_proposal.is_some()
}

// === Modified Functions ===

/// add_liquidity() - Always adds to LIVE bucket
/// remove_liquidity() - Can only remove from LIVE bucket
/// swap() - Uses LIVE + TRANSITIONING reserves (both trade)
```

### quantum_lp_manager.move

```move
// === Modified Functions ===

/// auto_quantum_split_on_proposal_start()
/// CHANGE: Only quantum-split the LIVE bucket
/// TRANSITIONING and WITHDRAW_ONLY stay in spot

// Before:
let asset_to_split = calculate_split_amount(spot_pool.asset_reserve, ...);

// After:
let asset_to_split = calculate_split_amount(spot_pool.asset_live, ...);
```

### conditional_amm.move (LiquidityPool)

```move
// === New Functions ===

/// Get bucket amounts for recombination
public fun get_bucket_amounts(pool: &LiquidityPool): (u64, u64, u64, u64, u64, u64) {
    (
        pool.asset_live,
        pool.asset_transitioning,
        pool.stable_live,
        pool.stable_transitioning,
        pool.lp_live,
        pool.lp_transitioning,
    )
}

// === Modified Functions ===

/// Swap functions - Use (asset_live + asset_transitioning) as total reserve
/// Both buckets are "active" for trading during proposal
```

### liquidity_interact.move

```move
// === New Functions ===

/// Crank function: Recombine winning conditional → spot
/// Moves LIVE → spot.LIVE, TRANSITIONING → spot.WITHDRAW_ONLY
public fun crank_recombine_and_transition<AssetType, StableType, AssetConditionalCoin, StableConditionalCoin>(
    proposal: &mut Proposal<AssetType, StableType>,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    spot_pool: &mut UnifiedSpotPool<AssetType, StableType>,
    ctx: &mut TxContext,
)

// === Modified Functions ===

/// empty_amm_and_return_to_provider() - Split by bucket
/// empty_amm_and_return_to_dao() - Split by bucket
```

### proposal_lifecycle.move

```move
// === Modified Functions ===

/// finalize_proposal_market_internal()
/// ADD: Call crank_recombine_and_transition() before returning liquidity

fun finalize_proposal_market_internal<AssetType, StableType>(
    // ... existing params ...
) {
    // ... existing finalization logic ...

    // NEW: Crank the bucket transitions
    if (proposal::uses_dao_liquidity(proposal)) {
        liquidity_interact::crank_recombine_and_transition(
            proposal,
            escrow,
            spot_pool,
            ctx
        );
    };

    // ... rest of finalization ...
}
```

---

## Edge Cases

### 1. User marks withdrawal during proposal trading
- ✅ Moves to TRANSITIONING
- ✅ Still trades in current proposal
- ✅ After crank → WITHDRAW_ONLY
- ✅ Next proposal doesn't quantum-split this liquidity

### 2. User marks withdrawal when no proposal active
- ✅ Moves directly to WITHDRAW_ONLY
- ✅ Can withdraw immediately (PTB: mark + withdraw)

### 3. Proposal ends, user hasn't marked yet
- ✅ Liquidity returns to LIVE bucket
- ✅ Auto quantum-splits for next proposal
- ✅ User can mark withdrawal anytime

### 4. User tries to withdraw before crank
- ❌ assert!(lp_token.locked_in_proposal.is_none())
- ❌ Must wait for proposal to finalize and crank to run

### 5. Swap during proposal with mixed buckets
- ✅ Uses (LIVE + TRANSITIONING) as total reserves
- ✅ Both buckets trade proportionally
- ✅ k = (live + trans) * (live + trans)

### 6. Multiple users mark withdrawal simultaneously
- ✅ Each gets proportional share of buckets
- ✅ No race condition (atomic per-transaction)
- ✅ All transition together at crank

---

## Testing Plan

### Unit Tests

1. **test_mark_withdrawal_active_proposal()**
   - Add liquidity → get LP token
   - Start proposal → quantum split
   - Mark for withdrawal → verify TRANSITIONING
   - Verify still trades in conditional

2. **test_mark_withdrawal_no_proposal()**
   - Add liquidity → get LP token
   - Mark for withdrawal → verify WITHDRAW_ONLY (immediate)
   - Withdraw → verify coins received

3. **test_quantum_split_respects_buckets()**
   - Add 1000 liquidity
   - Mark 400 for withdrawal → 600 LIVE, 400 TRANSITIONING
   - Quantum split 50% → only 300 LIVE splits
   - Verify 300 LIVE + 400 TRANSITIONING in spot

4. **test_crank_recombination()**
   - Proposal with mixed LIVE/TRANSITIONING liquidity
   - Finalize → verify LIVE → spot.LIVE
   - Verify TRANSITIONING → spot.WITHDRAW_ONLY

5. **test_full_lifecycle()**
   - User A: 1000 liquidity, no withdrawal
   - User B: 1000 liquidity, marks withdrawal mid-proposal
   - Proposal ends, crank runs
   - User A: liquidity quantum-splits again
   - User B: can withdraw immediately

### Integration Tests

1. **test_multiple_proposals_with_withdrawals()**
   - 3 users, 3 sequential proposals
   - Users mark withdrawal at different times
   - Verify correct bucket accounting throughout

2. **test_swap_with_mixed_buckets()**
   - Liquidity split across LIVE/TRANSITIONING
   - Perform swaps during proposal
   - Verify price impact uses combined reserves

3. **test_no_double_quantum_split()**
   - User marks withdrawal in proposal A
   - Proposal A ends → crank
   - Proposal B starts
   - Verify user's liquidity NOT quantum-split

---

## Migration Plan

### Phase 1: Add bucket tracking (backward compatible)
- Add new fields with default values
- Initialize existing pools: all liquidity → LIVE

### Phase 2: Implement mark/withdraw functions
- Add user-facing entry points
- No changes to existing flows

### Phase 3: Update quantum split logic
- Modify to only touch LIVE bucket
- Add crank to finalization

### Phase 4: Testing & deployment
- Full test coverage
- Deploy to testnet
- Monitor for issues

---

## Open Questions

1. **LP token transferability:** Can users transfer LP NFTs? If yes, new owner inherits withdraw_mode state?
   - **Recommendation:** Allow transfer, inherit state

2. **Cancel withdrawal:** Can user move TRANSITIONING → LIVE before crank?
   - **Recommendation:** Yes, add `cancel_withdrawal()` function

3. **Partial withdrawal:** Can user withdraw 50% of LP, keep 50% active?
   - **Recommendation:** No, keep it simple (all-or-nothing per token)

4. **Multiple LP tokens per user:** Can user have multiple positions?
   - **Recommendation:** Yes, NFTs allow this naturally

---

## Success Criteria

✅ Users can mark liquidity for withdrawal at any time
✅ Marked liquidity still trades in current proposal
✅ Quantum split only touches LIVE bucket
✅ Crank atomically transitions TRANSITIONING → WITHDRAW_ONLY
✅ Users can claim after crank
✅ No liquidity fragmentation (single AMM)
✅ No gaming (can't instant-withdraw mid-proposal)
✅ Gas-efficient (batch transitions at crank)
