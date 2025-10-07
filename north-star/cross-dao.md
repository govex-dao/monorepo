# Cross-DAO Coordination: Learnings and Analysis

## Executive Summary

We explored implementing cross-DAO atomic execution where multiple DAOs could coordinate to execute actions together (e.g., "all 3 DAOs merge liquidity pools or none do"). After extensive implementation attempts, we concluded this feature should not be built due to fundamental architectural incompatibilities and poor cost-benefit tradeoffs.

## The Vision

### What We Wanted
- Multiple DAOs vote on coordinated actions independently
- Actions only execute if ALL participating DAOs approve
- Atomic execution - either all succeed or all fail
- No double execution - proposals can't execute both normally and via bundle

### Use Cases Considered
1. **Liquidity Pool Mergers** - Multiple DAOs combine their AMM pools
2. **Treasury Swaps** - DAOs exchange treasury assets
3. **Joint Investments** - Multiple DAOs fund a project together
4. **Governance Upgrades** - Coordinated parameter changes across DAOs

## Implementation Attempts

### Attempt 1: Hot Potato Pattern with Stored Executables

**Approach:**
```move
// Store actual executables in bundle
public struct Bundle {
    executables: vector<Executable<Outcome>>,
    ...
}

// Return hot potato requiring execution in same PTB
public struct CrossDAOExecutionRequest<Outcome> {
    executables: vector<Executable<Outcome>>,
    ...
}
```

**Why it failed:**
- Move's type system requires `Executable<Outcome>` to have `store` ability
- But `Executable` can't have `store` for all `Outcome` types
- Dynamic fields (`df::add`) still require `store` ability
- Can't store generic executables without knowing exact types at compile time

### Attempt 2: Two-Phase Commit with Reservations

**Approach:**
```move
// Phase 1: Reserve proposal (prevent normal execution)
public struct Reservation {
    proposal_id: ID,
    bundle_id: String,
}

// Phase 2: Commit executable after reservation
public fun commit_with_reservation(
    reservation: ReservationReceipt,
    executable: Executable<Outcome>,
    ...
)
```

**Why it failed:**
- Reservation system tracks intent but can't enforce locks
- Proposal module would need modification to check reservations
- No way to prevent `proposal::execute()` from being called directly
- The lock exists in a separate module that proposal doesn't know about

### Attempt 3: Simplified Coordination Tracker

**Approach:**
```move
// Just track which DAOs have committed
public struct Bundle {
    reservations: Bag,
    reservation_count: u64,
}

// Mark bundle as "executed" when all participate
public fun mark_executed(bundle: &mut Bundle)
```

**What worked:**
- Compiles and deploys successfully
- Tracks coordination state
- Enforces minimum participants

**What didn't work:**
- Doesn't actually prevent double execution
- No atomic execution (each DAO executes separately)
- No rollback if one fails
- Just a "sign-up sheet" with no enforcement

## Fundamental Obstacles

### 1. Move Type System Constraints

Move's ability system creates a catch-22:
- To store something, it needs `store` ability
- To pass something around, it often needs `copy` or `drop`
- But `Executable<T>` can't have these abilities for all T
- Generic storage of arbitrary actions is essentially impossible

### 2. Account Protocol Design Assumptions

The Account Protocol was designed for:
- Single account execution
- Synchronous action processing
- Type-safe action handling
- No cross-account coordination

Trying to make it coordinate across accounts fights its fundamental design.

### 3. Sui Object Model

Sui's object model makes atomic cross-account operations difficult:
- Objects are owned by single accounts
- Shared objects have consensus overhead
- No built-in two-phase commit
- Transaction atomicity is per-transaction, not cross-transaction

### 4. The Lock Enforcement Problem

To prevent double execution, we need to modify core proposal execution:

**Current:**
```move
public fun execute_proposal(proposal: &mut Proposal) {
    // Executes immediately
}
```

**Would need:**
```move
public fun execute_proposal(proposal: &mut Proposal) {
    assert!(!is_locked_in_bundle(proposal.id));
    // Then execute
}
```

But this requires:
- Modifying core proposal module
- Adding bundle awareness to base governance
- Cross-module state checking
- Circular dependency risks

## Why This is Actually Fine

### 1. Rare Use Case
- How often do DAOs really need atomic cross-execution?
- Most coordination can be done socially
- Independent execution with social agreement works

### 2. Workarounds Exist

**Escrow Pattern:**
```move
// Each DAO deposits assets
// Released when all conditions met
public struct Escrow {
    deposits: Table<address, Coin<X>>,
    required_participants: vector<address>,
}
```

**Oracle Confirmation:**
```move
// External oracle confirms all executed
public fun confirm_all_executed(
    oracle: &Oracle,
    dao_addresses: vector<address>,
)
```

**Simple Social Coordination:**
- DAOs communicate off-chain
- Execute within agreed timeframe
- Trust and reputation handle enforcement

### 3. Complexity Cost Too High

Adding this feature would:
- Touch core proposal execution paths
- Add new failure modes
- Increase testing surface area
- Make single-DAO execution (99% use case) more complex
- Risk introducing bugs in critical governance paths

## Lessons Learned

### 1. Type Systems Shape Architecture
Move's ability system isn't just a constraint - it fundamentally shapes what architectures are possible. Fighting it leads to overcomplicated workarounds.

### 2. Cross-Account Atomicity is Hard
Blockchains are good at atomic operations within a transaction, not across multiple independent accounts over time.

### 3. Not All Web2 Patterns Translate
"Multiple parties approve then execute together" is trivial in Web2 with a central coordinator. In Web3, it requires complex coordination primitives.

### 4. Simple > Clever
The simple reservation system we built works and compiles. But "works and compiles" isn't the same as "solves the problem."

### 5. Know When to Stop
We spent significant effort on three different approaches. Recognizing when to stop and document learnings is valuable.

## Alternative Designs for Future

If this feature becomes critical, consider:

### 1. Protocol-Level Support
Build cross-DAO coordination as a first-class protocol feature, not bolted onto existing governance.

### 2. Specialized Coordination Contracts
Instead of general-purpose cross-DAO execution, build specific contracts for specific coordination types (e.g., `LiquidityMerger`, `TreasurySwap`).

### 3. External Coordinator Service
Use an external service or oracle to coordinate execution, with on-chain verification after the fact.

### 4. Upgrade to Proposals V2
Redesign proposal system from ground up with cross-DAO coordination as a primary requirement, not an afterthought.

## Conclusion

Cross-DAO atomic execution is a fascinating problem that reveals deep constraints in blockchain architecture. While technically possible with significant refactoring, the cost-benefit analysis strongly favors not implementing this feature.

The attempt taught us valuable lessons about:
- Move's type system boundaries
- Account Protocol's design assumptions  
- The difficulty of cross-account atomicity
- When architectural constraints should guide product decisions

Sometimes the best code is the code you don't write.

## Code Artifacts to Remove

- `/contracts/futarchy_dao/sources/dao/cross/cross_dao_bundle.move`
- `/contracts/futarchy_dao/sources/dao/cross/cross_dao_bundle_broken.move.bak`
- `/contracts/futarchy_dao/tests/cross_dao_test.move`
- `/contracts/futarchy_dao/cross_dao_usage_example.md`
- `/contracts/futarchy_dao/cross_dao_bundle_fixes.md`

---

*Document created: 2025-01-09*  
*Decision: Feature dropped due to architectural incompatibility*  
*Time invested: ~4 hours*  
*Outcome: Valuable learnings about system constraints*