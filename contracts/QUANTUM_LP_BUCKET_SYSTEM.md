# Quantum LP Bucket System Architecture

## Overview

The quantum LP system manages liquidity that must quantum-split across conditional outcome pools when proposals are active, then recombine when proposals end. The bucket system ensures that LP operations (add/remove) can happen at any time without creating economic exploits or DoS vectors.

## Core Problem

**Challenge**: Allow LP operations during active proposals without:
1. Giving new LPs unfair access to conditional market outcomes
2. Creating DoS vectors by blocking operations
3. Violating constant-product invariants (xy=k)
4. Creating ratio mismatches between pools with different prices

**Solution**: 4-bucket system in spot pools, 2-bucket system in conditional pools, with explicit state transitions.

## Bucket Architecture

### Spot Pool: 4 Buckets

```
┌─────────────────────────────────────────────────────────────────┐
│                     UNIFIED SPOT POOL                            │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  1. asset_spot_active_quantum_lp                                │
│     ├─ Normal active LP                                         │
│     ├─ Quantum-splits when proposals start                      │
│     └─ Can be removed anytime (if no proposal active)           │
│                                                                  │
│  2. asset_spot_leave_lp_when_proposal_ends                      │
│     ├─ User marked for exit during active proposal              │
│     ├─ Gets one final quantum-split to conditionals             │
│     └─ Becomes spot_frozen_claimable when proposal ends         │
│                                                                  │
│  3. asset_spot_frozen_claimable_lp                              │
│     ├─ Fully withdrawn, ready for user to claim                 │
│     ├─ Does NOT quantum-split (stays in spot)                   │
│     └─ Final destination before burning LP token                │
│                                                                  │
│  4. asset_spot_join_quantum_lp_when_proposal_ends               │
│     ├─ New LP added during active proposal                      │
│     ├─ Does NOT quantum-split to current proposal               │
│     └─ Becomes spot_active_quantum when proposal ends           │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

### Conditional Pool: 2 Buckets

```
┌─────────────────────────────────────────────────────────────────┐
│                  CONDITIONAL OUTCOME POOL                        │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  1. asset_conditional_recombine_to_spot_active                  │
│     ├─ Came from spot_active_quantum_lp                         │
│     ├─ Trades actively in conditional market                    │
│     └─ Recombines to spot_active_quantum when proposal ends     │
│                                                                  │
│  2. asset_conditional_recombine_to_spot_frozen_claimable        │
│     ├─ Came from spot_leave_lp_when_proposal_ends               │
│     ├─ Trades actively in conditional market (one last time)    │
│     └─ Recombines to spot_frozen_claimable when proposal ends   │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

## State Transitions

### Lifecycle 1: Normal Active LP

```
┌──────────────────────────────────────────────────────────────────┐
│                    NORMAL LP LIFECYCLE                           │
└──────────────────────────────────────────────────────────────────┘

  [User adds LP, no proposal active]
              ↓
    spot_active_quantum_lp
              ↓
    [Proposal starts → quantum split]
              ↓
    ┌─────────────────────────────────┐
    │  Split to all outcome pools:    │
    │  - conditional_to_spot_active   │
    │  - conditional_to_spot_active   │
    │  - conditional_to_spot_active   │
    └─────────────────────────────────┘
              ↓
    [Proposal ends → recombine]
              ↓
    spot_active_quantum_lp
              ↓
    [Next proposal starts → quantum split again]
              ↓
           (repeat)
```

### Lifecycle 2: LP Joins During Active Proposal

```
┌──────────────────────────────────────────────────────────────────┐
│              NEW LP DURING ACTIVE PROPOSAL                       │
└──────────────────────────────────────────────────────────────────┘

  [User adds LP, proposal IS active]
              ↓
    spot_join_quantum_lp_when_proposal_ends
              │
              │ (ISOLATED - does NOT quantum-split)
              │ (Trades in spot, earns fees)
              │
              ↓
    [Proposal ends → merge_joining_to_active()]
              ↓
    spot_active_quantum_lp
              ↓
    [Next proposal starts → NOW quantum-splits]
              ↓
    ┌─────────────────────────────────┐
    │  Split to all outcome pools     │
    └─────────────────────────────────┘
```

### Lifecycle 3: LP Withdrawal

```
┌──────────────────────────────────────────────────────────────────┐
│                    LP WITHDRAWAL LIFECYCLE                       │
└──────────────────────────────────────────────────────────────────┘

  spot_active_quantum_lp
              ↓
    [User calls mark_lp_for_withdrawal()]
              ↓
    spot_leave_lp_when_proposal_ends
              ↓
    [Proposal starts → quantum split]
              ↓
    ┌─────────────────────────────────────────┐
    │  Split to all outcome pools:            │
    │  - conditional_to_spot_frozen_claimable │
    │  - conditional_to_spot_frozen_claimable │
    │  - conditional_to_spot_frozen_claimable │
    └─────────────────────────────────────────┘
              ↓
    [Proposal ends → recombine]
              ↓
    spot_frozen_claimable_lp
              ↓
    [User calls claim_withdrawal()]
              ↓
    [Burn LP token, return coins]
```

### Lifecycle 4: Edge Case - Withdrawal During No Proposal

```
┌──────────────────────────────────────────────────────────────────┐
│          WITHDRAWAL MARKED BUT NO PROPOSAL ACTIVE                │
└──────────────────────────────────────────────────────────────────┘

  spot_active_quantum_lp
              ↓
    [User calls mark_lp_for_withdrawal()]
              ↓
    spot_leave_lp_when_proposal_ends
              │
              │ (No proposal active, so no quantum-split happens)
              │
              ↓
    [Crank calls transition_leaving_to_frozen_claimable()]
              ↓
    spot_frozen_claimable_lp
              ↓
    [User calls claim_withdrawal()]
              ↓
    [Burn LP token, return coins]
```

## Key Invariants

### Bucket Isolation

1. **Active quantum LP**: ALWAYS quantum-splits on proposal start
2. **Joining LP**: NEVER quantum-splits to current proposal (isolated)
3. **Leaving LP**: Gets ONE final quantum-split, then freezes
4. **Frozen LP**: NEVER quantum-splits (stays in spot only)

### Quantum Split Rules

```
When proposal starts (quantum_split_spot_to_conditionals):
  ├─ Split: spot_active_quantum_lp → conditional_to_spot_active
  ├─ Split: spot_leave_lp_when_proposal_ends → conditional_to_spot_frozen
  ├─ Keep:  spot_frozen_claimable (stays in spot)
  └─ Keep:  spot_join_quantum_lp_when_proposal_ends (stays in spot)
```

### Recombination Rules

```
When proposal ends (recombine_conditionals_to_spot):
  ├─ Merge: conditional_to_spot_active → spot_active_quantum_lp
  ├─ Merge: conditional_to_spot_frozen → spot_frozen_claimable
  └─ Merge: spot_join_quantum_lp_when_proposal_ends → spot_active_quantum_lp
```

## Critical Design Decisions

### Why 4 Buckets in Spot? (Not 3)

**Problem**: If new LP during proposals went to `spot_active_quantum_lp`, they would unfairly benefit from conditional market outcomes.

**Example Attack**:
```
1. Proposal starts, YES pool trades to 2:1 ratio
2. Attacker adds LP during proposal
3. If LP quantum-splits to current proposal:
   - Attacker gets YES tokens at 2:1 ratio
   - If YES wins, attacker extracts value unfairly
```

**Solution**: Isolate new LP in `spot_join_quantum_lp_when_proposal_ends` until current proposal ends.

### Why NOT Merge joining + leaving Buckets?

**They have OPPOSITE behaviors**:

| Bucket | Quantum-splits? | Destination |
|--------|----------------|-------------|
| `spot_leave_lp_when_proposal_ends` | ✅ YES (one final time) | → `spot_frozen_claimable` |
| `spot_join_quantum_lp_when_proposal_ends` | ❌ NO (stays in spot) | → `spot_active_quantum` |

Merging them would require complex branching logic on every operation.

### Why NOT Block LP Operations During Proposals?

**DoS Vector**: Attacker could:
1. Create proposals continuously
2. Lock all LP add/remove operations
3. Prevent legitimate users from managing liquidity

**Solution**: Allow operations anytime, route to appropriate bucket.

## Code Footprint

The entire feature requires only **~15 lines of business logic**:

### 1. Routing Logic (13 lines)
```move
// In add_liquidity_and_return()
if (is_locked_for_proposal(pool)) {
    pool.asset_spot_join_quantum_lp_when_proposal_ends += asset_amount;
    pool.stable_spot_join_quantum_lp_when_proposal_ends += stable_amount;
    pool.lp_spot_join_quantum_lp_when_proposal_ends += lp_amount;
} else {
    pool.asset_spot_active_quantum_lp += asset_amount;
    pool.stable_spot_active_quantum_lp += stable_amount;
    pool.lp_spot_active_quantum_lp += lp_amount;
};
```

### 2. Merge Function (13 lines)
```move
public(package) fun merge_joining_to_active_quantum_lp<AssetType, StableType>(
    pool: &mut UnifiedSpotPool<AssetType, StableType>,
) {
    pool.asset_spot_active_quantum_lp += pool.asset_spot_join_quantum_lp_when_proposal_ends;
    pool.stable_spot_active_quantum_lp += pool.stable_spot_join_quantum_lp_when_proposal_ends;
    pool.lp_spot_active_quantum_lp += pool.lp_spot_join_quantum_lp_when_proposal_ends;

    pool.asset_spot_join_quantum_lp_when_proposal_ends = 0;
    pool.stable_spot_join_quantum_lp_when_proposal_ends = 0;
    pool.lp_spot_join_quantum_lp_when_proposal_ends = 0;
}
```

### 3. Merge Call (1 line)
```move
// In quantum_lp_manager::recombine_conditionals_to_spot()
unified_spot_pool::merge_joining_to_active_quantum_lp(spot_pool);
```

**Total**: 27 lines of code for a major security feature.

## Files Modified

- `/contracts/futarchy_markets_core/sources/spot/unified_spot_pool.move`: Add 4th bucket, routing logic, merge function
- `/contracts/futarchy_markets_core/sources/quantum_lp_manager.move`: Call merge on recombination
- `/contracts/futarchy_markets_primitives/sources/conditional/conditional_amm.move`: Rename buckets to hyper-explicit names
- `/contracts/futarchy_markets_operations/sources/liquidity/liquidity_interact.move`: Update function call

## Testing Checklist

### Unit Tests Needed

- [ ] Add LP during active proposal → goes to joining bucket
- [ ] Add LP when no proposal active → goes to active bucket
- [ ] Joining bucket does NOT quantum-split when proposal starts
- [ ] Joining bucket merges to active when proposal ends
- [ ] Merged joining LP DOES quantum-split on next proposal

### Integration Tests Needed

- [ ] Full lifecycle: add LP during proposal → proposal ends → next proposal starts → verify quantum-split
- [ ] Withdrawal lifecycle: mark for exit → proposal starts → quantum-split → proposal ends → claim
- [ ] Edge case: mark for exit when no proposal active → crank → claim

### Property-Based Tests

- [ ] Total LP supply = sum of all bucket LP supplies (spot + all conditionals)
- [ ] LP shares never exceed proportional contribution
- [ ] K-invariant maintained across all operations
- [ ] Recombination is lossless (ignoring fees)

### Attack Vectors to Test

- [ ] Attacker adds LP when YES pool is 2:1, NO pool is 1:1 → verify isolated from outcome
- [ ] Attacker tries to DoS by marking/unmarking withdrawal rapidly → verify no revert
- [ ] Attacker adds LP right before proposal ends → verify fair share calculation

## Future Considerations

### Potential Optimizations

1. **Batch Merging**: If many users add LP during proposal, merge can be gas-intensive
2. **Lazy Migration**: Could defer joining → active migration until user's next operation
3. **Dynamic Bucket Count**: Currently hardcoded to 4 buckets in spot, 2 in conditionals

### Potential Extensions

1. **Time-Weighted LP**: Different buckets could earn different fee shares based on participation time
2. **Conditional-Specific LP**: Allow LP directly to one outcome pool (advanced users)
3. **Auto-Compounding**: Automatically reinvest fees into active bucket

## References

- Uniswap V2 constant-product AMM: xy=k invariant
- Gnosis conditional tokens: Quantum mechanics for outcome tokens
- Hanson's LMSR: Market scoring rules for prediction markets

## Changelog

- **2025-01-18**: Initial implementation of 4-bucket system
- **2025-01-18**: Renamed all buckets to hyper-explicit names for clarity
- **2025-01-18**: Added merge_joining_to_active_quantum_lp() integration
