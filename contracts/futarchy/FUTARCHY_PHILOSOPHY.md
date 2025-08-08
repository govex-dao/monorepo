# Futarchy Design Philosophy

## Core Principle: Markets Decide Everything

Futarchy DAOs are designed to be **ephemeral by default**. Unlike traditional DAOs that assume perpetual existence, futarchy DAOs can and should dissolve when markets determine they're no longer creating value.

## Key Design Decisions

### 1. Native Dissolution Support

**Why it matters**: When token price < NAV (Net Asset Value), the market is signaling the DAO should return capital to holders.

**Implementation**:
- `InitiateDissolutionAction` - Start winddown when markets decide
- `CancelAllStreamsAction` - Stop all ongoing payments
- `DistributeAssetAction` - Return assets proportionally
- `FinalizeDissolutionAction` - Clean shutdown

This isn't just a feature - it's **fundamental to futarchy**. The ability to cleanly dissolve creates a price floor at NAV and ensures capital efficiency.

### 2. Streaming Payments (Not Just "Nice to Have")

**Why it matters**: Futarchy DAOs need continuous operations without large discrete treasury votes.

**Implementation**:
- `CreatePaymentAction` - Set up recurring/streaming payments
- `ExecutePaymentAction` - Claim accrued payments
- `CancelPaymentAction` - Stop payments (crucial for dissolution)

Streams allow:
- Continuous contributor payments
- No large treasury withdrawals that could affect price
- Instant cancellation during dissolution
- Clear operational expenses visible on-chain

### 3. Cross-DAO Atomic Coordination (M-of-N)

**Why it matters**: Futarchy DAOs often need to coordinate - mergers, joint ventures, or dissolution into a parent DAO.

**New Design** (just updated):
- **M-of-N thresholds**: 3-of-5 DAOs must approve
- **Weighted voting**: Larger DAOs can have more influence
- **Atomic execution**: All-or-nothing coordination

Examples:
- 5 futarchy DAOs vote on shared infrastructure (3-of-5 to proceed)
- Parent DAO has 51% weight, subsidiaries share 49%
- Merger requires 2-of-2, but acquisition might be 1-of-many

### 4. Opinionated but Composable

The actions are **opinionated** - they assume:
- DAOs might dissolve (and that's OK!)
- Continuous payments are better than discrete
- Cross-DAO coordination is common
- NAV is a meaningful metric

But they're also **composable**:
- Combine with vault actions for treasury management
- Mix with governance actions for complex proposals
- Use with third-party actions for DeFi integration

## The Futarchy Lifecycle

```
1. CREATION
   - Proposal passes in parent DAO
   - Initial capital allocated
   - Markets open for price discovery

2. OPERATION  
   - Streams pay contributors
   - Markets trade on performance
   - Cross-DAO proposals coordinate resources

3. EVALUATION
   - If Price > NAV: Continue operating
   - If Price < NAV: Market signals dissolution

4. DISSOLUTION (if needed)
   - Cancel all streams
   - Distribute assets to token holders
   - Clean shutdown with no loose ends
```

## Why This Design?

Traditional DAOs suffer from:
- **Zombie DAOs**: Continue existing despite creating no value
- **Capital lock**: Funds trapped in unproductive organizations
- **Unclear shutdown**: No clean way to return capital

Futarchy DAOs solve this by:
- **Market-driven lifecycle**: Markets decide continuation
- **Clean dissolution**: First-class support for shutdown
- **Capital efficiency**: Money flows to productive uses
- **Atomic coordination**: DAOs can merge/split/coordinate

## Not Bugs, Features

These "opinionated" choices aren't limitations - they're the core value proposition:

1. **Dissolution is easy** → Capital is never trapped
2. **Streams are native** → Operations are continuous
3. **Cross-DAO is M-of-N** → Flexible coordination
4. **NAV matters** → Price floor exists

This design makes futarchy DAOs:
- More **liquid** (can always exit at ~NAV)
- More **efficient** (capital flows to value creation)
- More **coordinated** (atomic cross-DAO actions)
- More **predictable** (standard patterns)

## Conclusion

The "opinionated" nature of these actions isn't a constraint - it's the implementation of futarchy theory. By making creation, operation, and dissolution first-class concerns, we enable truly market-driven organizations that can fluidly allocate capital to its most productive uses.