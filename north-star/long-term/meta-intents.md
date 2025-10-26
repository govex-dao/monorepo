# Meta-Intents: Fault-Tolerant Conditional Execution Primitive

**Status**: Architecture Design
**Timeline**: 6+ months
**Priority**: Critical - Core Protocol Innovation

---

## The Problem

**High-performance blockchains removed exception handling for speed.**

- Sui Move: No try-catch (abort only)
- Solana: Removed CPI error recovery in 2020 (too expensive)
- Result: Any failure in multi-step workflows = entire transaction reverts

**This creates a critical failure mode in futarchy proposals:**

Futarchy proposals go through multiple lifecycle stages:
1. **Market Activation** - Initialize conditional markets, start trading
2. **Trading Period** - Users trade based on outcome predictions
3. **Finalization** - Determine winning outcome from market prices
4. **Intent Execution** - Execute proposal actions if it passes

```
Market Activation Flow:
  create_markets() → execute_market_init_intents() → start_trading()
                              ↓
                         ABORT! (insufficient balance)
                              ↓
                    ENTIRE PROPOSAL BRICKS

Finalization Flow:
  settle_markets() → execute_finalization_intents() → mark_complete()
                              ↓
                         ABORT! (oracle call fails)
                              ↓
                    PROPOSAL STUCK, MARKETS CAN'T SETTLE
```

**Current workarounds are insufficient:**
- Hardcode each use case (not scalable)
- Pre-validate everything (state can change)
- Skip intent execution (defeats the purpose)

---

## The Solution: Meta-Intents

**Meta-intents = Hierarchical conditional workflows with soft failures**

Instead of catching errors (impossible), we **prevent errors through conditional execution**.

### Core Concepts:

1. **Stage-Coupled Execution**
   - Intents execute across proposal lifecycle stages
   - Each stage has independent sub-intents
   - **Proposal Lifecycle Stages:**
     - **PREMARKET**: Proposal created, outcomes can be modified
     - **MARKET_INIT**: Market activation (conditional markets initialized, trading begins)
     - **REVIEW**: Review period before trading starts
     - **TRADING**: Active trading period (markets operational)
     - **FINALIZATION**: Market finalized, winning outcome determined
     - **EXECUTION**: Intent execution (only if proposal passes)
   - Each stage can trigger sub-intents with conditional logic

2. **Nested Sub-Intents**
   - Sub-intents contain sub-sub-intents (arbitrary depth)
   - Each node can have conditional branching
   - Composition over monolithic execution

3. **Read-Validate-Execute Pattern**
   - READ: Snapshot all state (no mutations)
   - VALIDATE: Check conditions (boolean logic)
   - EXECUTE: Mutate state only if safe

4. **Shared Context (Data Flow)**
   - Stages pass data via shared context
   - Downstream stages read upstream results
   - Enables conditional logic across lifecycle

5. **Soft Failures**
   - Failed conditions → set flags, don't abort
   - Downstream actions check flags and adapt
   - Proposal lifecycle never bricks

6. **Pre-Approved Templates (Safety)**
   - Meta-intents created from governance-approved templates
   - Templates define structure, logic, and safety bounds
   - Users instantiate templates with custom parameters
   - Off-chain validation before submission (simulation + bounds checking)
   - **Single unified registry with two validation layers:**
     - Layer 1: Approved action types (existing whitelist)
     - Layer 2: Approved meta-intent templates (new)
     - Templates can only use pre-approved actions (composable security)

---

## Architecture

```
META-INTENT (spans entire proposal)
    ├─ MARKET_INIT Sub-Intent
    │    ├─ read vault_balance
    │    ├─ if balance >= threshold:
    │    │   └─ Sub-Intent: AMM Buy-Back
    │    │       ├─ read amm_liquidity
    │    │       ├─ if liquidity > min:
    │    │       │   └─ execute swap()
    │    │       └─ else:
    │    │           └─ set_flag("low_liquidity")
    │    └─ else:
    │        └─ set_flag("insufficient_funds")
    │
    ├─ FINALIZATION Sub-Intent
    │    ├─ read MARKET_INIT results
    │    ├─ if buyback_succeeded:
    │    │   └─ update_accounting()
    │    └─ else:
    │        └─ log_skipped()
    │
    └─ EXECUTION Sub-Intent (if proposal passes)
         ├─ read FINALIZATION results
         ├─ if no_errors:
         │   └─ execute_proposal_actions()
         └─ else:
             └─ rollback_plan()
```

### Data Structures:

```move
public struct MetaIntent<Outcome> {
    outcome: Outcome,
    premarket_intent: Option<SubIntent>,
    market_init_intent: Option<SubIntent>,
    finalization_intent: Option<SubIntent>,
    execution_intent: Option<SubIntent>,
    shared_context: SharedContext,
}

public struct SubIntent {
    reads: vector<ReadOperation>,
    conditionals: vector<ConditionalBranch>,
    sub_intents: vector<SubIntent>,  // Recursive nesting
    outputs: Table<String, vector<u8>>,
}

public struct ConditionalBranch {
    condition: Condition,
    on_true: SubIntent,
    on_false: SubIntent,
}

public struct SharedContext {
    reads: Table<String, vector<u8>>,
    stage_outputs: Table<u8, Table<String, vector<u8>>>,
    status: u8,
    errors: vector<ExecutionError>,
    flags: Table<String, bool>,
}
```

---

## Use Cases

### 1. AMM Auto Buy-Back
```
if vault_balance >= 1M AND amm_liquidity > 10M:
    execute swap(stable → asset)
else:
    skip and continue proposal
```

### 2. Conditional M&A
```
if due_diligence_passed AND valuation < 10M AND treasury_sufficient:
    transfer funds + acquire equity
else:
    refund escrow
```

### 3. Removing Race Conditions
```
if proposal_finalized AND my_outcome == winning_outcome:
    transfer conditional_tokens (will be redeemable)
else:
    escrow transfer until finalization
```

### 4. Conditional NFT Auctions
```
if floor_price >= 10_SOL AND collection_verified:
    create_auction(nft, reserve_price)
else:
    return_nft_to_vault
```

---

## Why This Matters

### Problem Scope:
- ❌ Move doesn't have try-catch (by design)
- ❌ Solana removed CPI error recovery (2020)
- ❌ Every high-performance chain has this issue
- ❌ No existing solution

### Our Solution:
- ✅ **Novel**: Hierarchical conditional workflows on-chain
- ✅ **General**: Works for any multi-step conditional logic
- ✅ **Fault-tolerant**: Soft failures, never bricks
- ✅ **Composable**: Nested sub-intents, reusable logic
- ✅ **Chain-agnostic**: Solves Sui + Solana + any chain without exception handling

### Positioning:
**"Fault-tolerant conditional execution primitive for high-performance blockchains"**

Not a DAO tool. Not a DeFi app.

**A base layer protocol.**

---

## Implementation Phases

### Phase 1: Template System (2 months)
- Meta-intent template registry (on-chain)
- Template approval via governance
- Core template library (AMM buy-back, conditional transfer, etc.)
- Off-chain validation framework (simulation + bounds checking)

### Phase 2: Core Execution Engine (2 months)
- Single-stage sub-intents
- Basic conditional branching
- Shared context (read/write)
- Soft failure tracking
- Template instantiation

### Phase 3: Stage Coupling (1 month)
- Multi-stage meta-intents
- Data flow between stages
- Stage-aware permissions
- Lifecycle integration

### Phase 4: Nested Sub-Intents (2 months)
- Recursive sub-intent execution
- Complex conditional logic
- Composition primitives
- Advanced template patterns

### Phase 5: Developer Tooling (1 month)
- Template builder SDK
- Visualization tools
- Testing framework
- Documentation

---

## Success Metrics

### Technical:
- Zero proposal bricking from intent failures
- Support 5+ levels of sub-intent nesting
- <100ms execution overhead per stage
- 10+ approved template library
- Off-chain simulation catches 95%+ of errors

### Adoption:
- 5+ governance-approved templates
- 3+ protocols building on meta-intents
- 50+ DAOs using the system
- Sui Foundation partnership
- Port to Solana (proof of generality)

---

## Risks & Mitigations

### Risk 1: Complexity
- **Mitigation**: Start simple (single-stage), add incrementally
- **Mitigation**: Invest in devtools and docs early

### Risk 2: Gas Costs
- **Mitigation**: Optimize execution engine
- **Mitigation**: Lazy evaluation (skip unused branches)

### Risk 3: Debugging
- **Mitigation**: Comprehensive execution context logging
- **Mitigation**: Simulation mode for testing

### Risk 4: Adoption
- **Mitigation**: Solve our own problem first (AMM buy-back)
- **Mitigation**: Early design partners (3-5 protocols)

### Risk 5: Malicious Templates
- **Mitigation**: Governance approval required for all templates
- **Mitigation**: Off-chain simulation catches unsafe patterns
- **Mitigation**: Safety bounds enforced at runtime
- **Mitigation**: Template audit process (security review)

---

## Open Questions

1. **Condition Language**: Custom DSL vs Move expressions?
2. **Gas Model**: Flat fee vs per-action metering?
3. **Recursion Limits**: Max sub-intent depth?
4. **Parallelization**: Can branches execute in parallel?
5. **Template Versioning**: How to upgrade approved templates?
6. **Validation Depth**: How much can off-chain simulation guarantee?

---

## Next Steps

1. **Spec Document** (1 week)
   - Detailed API design
   - Example workflows
   - Security analysis

2. **Proof of Concept** (2 weeks)
   - Single-stage sub-intent
   - Basic conditionals
   - AMM buy-back demo

3. **Pitch Deck** (1 week)
   - Problem/solution
   - Market sizing
   - Competitive analysis
   - Team + capital ask

4. **Fundraise** (1-2 months)
   - Seed round ($1-2M)
   - 12-18 month runway
   - Hire eng team

---

## Related Documents

- `../architecture/intent-system.md` - Current intent architecture
- `../architecture/proposal-lifecycle.md` - Proposal state machine
- `./conditional-execution-primitives.md` - Detailed primitives design (TBD)
- `./solana-port.md` - Solana compatibility strategy (TBD)

---

**This is the innovation. This is the moat. This is the protocol.**
