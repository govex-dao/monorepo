# Move Framework vs Futarchy: Package Architecture Analysis

## Package Structure Comparison

### Move Framework (3 packages, ~14K lines)

```
move-framework/packages/
├── extensions/          # Type registry & action types (ZERO dependencies)
│   ├── extensions.move          # Versioned package whitelist
│   └── framework_action_types.move  # Empty type tags for all actions
│
├── protocol/           # Core Account system (depends on: extensions)
│   ├── account.move             # Account<Config> with intents
│   ├── types/
│   │   ├── intents.move         # Intent/Executable types
│   │   ├── executable.move      # Hot potato for execution
│   │   ├── deps.move            # Dependency tracking
│   │   └── metadata.move        # Account metadata
│   └── actions/
│       ├── config.move          # Account configuration actions
│       └── owned.move           # Generic object transfer
│
└── actions/            # Standard actions (depends on: protocol)
    ├── lib/                     # Business logic
    │   ├── vault.move           # Treasury spend/deposit
    │   ├── currency.move        # Mint/burn/update
    │   ├── vesting.move         # Vesting schedules
    │   ├── access_control.move  # Capability borrowing
    │   ├── package_upgrade.move # Package upgrades
    │   └── kiosk.move           # NFT marketplace
    ├── intents/                 # Intent builders
    │   ├── vault.move           # request_spend_and_transfer()
    │   ├── currency.move        # request_mint_and_transfer()
    │   └── ...
    └── decoders/                # BCS deserialization
        ├── vault_decoder.move
        ├── currency_decoder.move
        └── ...
```

### Futarchy (17 packages, ~70K lines)

```
contracts/
├── futarchy_types/              # Shared types (like extensions)
├── futarchy_one_shot_utils/     # Utilities
├── futarchy_core/               # Core DAO system (like protocol)
│   ├── dao_config.move
│   ├── futarchy_config.move
│   ├── proposal_fee_manager.move
│   └── queue/priority_queue.move
│
├── futarchy_markets_primitives/ # Market fundamentals
├── futarchy_markets_core/       # Conditional markets
├── futarchy_markets_operations/ # AMM operations
├── futarchy_oracle/             # Price oracles
├── futarchy_vault/              # Asset management
│
├── futarchy_multisig/           # Multi-sig + policy enforcement
├── futarchy_lifecycle/          # Proposal lifecycle
├── futarchy_streams/            # Payment streams
├── futarchy_payments/           # Dividends/payments
│
├── futarchy_legal_actions/      # Legal docs (operating agreements)
├── futarchy_governance_actions/ # Meta-governance
├── futarchy_actions/            # Action orchestration
├── futarchy_factory/            # DAO creation
└── futarchy_dao/                # Top-level integration
```

## Key Design Patterns

### 1. **Extensions Pattern** (Zero-Dependency Type Registry)

**Move Framework:**
```move
// extensions/framework_action_types.move - NO IMPORTS!
module account_extensions::framework_action_types;

// Empty structs as type tags
public struct VaultSpend has drop {}
public struct CurrencyMint has drop {}
public struct PackageUpgrade has drop {}

// Minimal constructors for cross-module usage
public fun vault_spend(): VaultSpend { VaultSpend {} }
```

**Why This Works:**
- **Zero circular dependencies** - Extensions has NO imports
- **Compile-time type safety** - TypeName-based routing
- **Cross-package compatibility** - Anyone can import types
- **Versioning support** - Registry tracks package versions

**Your Futarchy Equivalent:**
```move
// futarchy_types/action_types.move
// Currently has 145 action types scattered across packages
// Could benefit from this pattern!
```

### 2. **Three-Layer Action Architecture**

**Move Framework Pattern:**

```
Layer 1: LIB (Business Logic)
  ├─ vault.move        → do_spend(), do_deposit()
  ├─ currency.move     → do_mint(), do_burn()
  └─ Pure functions, no intent/executable knowledge

Layer 2: INTENTS (Intent Builders)
  ├─ vault.move        → request_spend_and_transfer()
  ├─ currency.move     → request_mint_and_transfer()
  └─ Creates Intent, calls Layer 1, returns Intent

Layer 3: DECODERS (BCS Deserialization)
  ├─ vault_decoder.move    → decode BCS → call Layer 2
  ├─ currency_decoder.move → decode BCS → call Layer 2
  └─ Bridges storage (bytes) to execution (types)
```

**Benefits:**
- **Separation of concerns** - Logic ≠ Intent management ≠ Serialization
- **Reusability** - Layer 1 can be called directly or via intents
- **Testability** - Each layer tested independently
- **Extensibility** - Add new actions by implementing 3 modules

### 3. **Dependency Injection via Config Witness**

**Move Framework:**
```move
// Protocol defines the pattern
public fun new<Config, CW: drop>(
    config: Config,
    deps: Deps,
    version_witness: VersionWitness,
    config_witness: CW,  // ← Only config module can create
    ctx: &mut TxContext,
): Account<Config>

// Actions package provides implementations
module account_actions::currency;
use account_protocol::account::{Self, Account};

public fun request_mint<Config, ...>(
    account: &mut Account<Config>,  // ← Works with ANY config!
    amount: u64,
    ...
): Intent { ... }
```

**Your Futarchy:**
```move
// Tightly coupled to FutarchyConfig
module futarchy_actions::liquidity_actions;
use futarchy_core::futarchy_config::{FutarchyConfig};

public fun do_create_pool<Outcome, ...>(
    account: &mut Account<FutarchyConfig>,  // ← Hardcoded!
    ...
)
```

### 4. **Package Versioning & Upgrades**

**Move Framework:**
```move
// Extensions registry tracks versions
public struct PackageVersion has store {
    addr: address,
    version: u64,
}

// Account tracks dependencies
public struct Account<Config> {
    deps: Deps,  // Verified against Extensions registry
    ...
}

// Actions verify they're allowed
public fun request_spend(..., version_witness: VersionWitness) {
    account.deps().check(version_witness);  // ← Fails if wrong version
}
```

**Your Futarchy:**
- No explicit versioning system
- Package upgrades would break everything
- Need to redeploy all 17 packages atomically

## Complexity Analysis

| Metric | Move Framework | Futarchy | Ratio |
|--------|---------------|----------|-------|
| **Packages** | 3 | 17 | 5.7x |
| **Lines of Code** | 14,021 | 70,200 | 5x |
| **Action Types** | ~25 | ~145 | 5.8x |
| **Dependency Depth** | 2 levels | 5+ levels | 2.5x |

### Why Futarchy is Complex

1. **Domain complexity**
   - Conditional markets (AMMs for YES/NO outcomes)
   - TWAP oracles with 90-day windows
   - Quantum liquidity (1 spot token → N conditional tokens)
   - Policy enforcement (OBJECT > TYPE > ACTION hierarchy)
   - Multi-council governance
   - Streams, payments, grants, dividends
   - Legal document management
   - Dissolution/exit mechanics

2. **Architectural choices**
   - 17 packages vs 3 (fine-grained splitting)
   - 145 action types vs 25 (specialized actions)
   - Direct coupling vs abstraction (FutarchyConfig hardcoded)
   - No central type registry (types scattered)

## Recommended Refactoring Strategy

### Option A: **Conservative** (Low Risk, Moderate Benefit)

**Goal:** Apply extensions pattern without major restructuring

```
1. Create futarchy_extensions package (zero deps)
   └─ All 145 action types as empty structs

2. Update futarchy_core to use type-based routing
   └─ Replace string matching with TypeName

3. Add version tracking to FutarchyConfig
   └─ deps: Deps field

4. Keep existing 17-package structure
```

**Benefits:**
- ✅ Compile-time type safety
- ✅ Better IDE support
- ✅ Foundation for future versioning
- ✅ Low migration risk

**Effort:** ~1 week

---

### Option B: **Moderate** (Medium Risk, High Benefit)

**Goal:** Adopt 3-layer architecture for new actions

```
1. Do Option A (extensions pattern)

2. Create futarchy_action_lib package
   ├─ lib/          # Pure business logic
   ├─ intents/      # Intent builders
   └─ decoders/     # BCS deserializers

3. Migrate 10-15 most common actions to new pattern
   └─ config_actions, vault_actions, stream_actions

4. Leave specialized actions as-is (markets, oracle)
   └─ These are domain-specific, not general-purpose
```

**Benefits:**
- ✅ Option A benefits
- ✅ Cleaner separation of concerns
- ✅ Easier testing and maintenance
- ✅ New actions follow best practices
- ✅ Old actions still work

**Effort:** ~3 weeks

---

### Option C: **Aggressive** (High Risk, Maximum Benefit)

**Goal:** Full restructuring to match Move Framework

```
1. Consolidate to 5 packages:
   ├─ futarchy_extensions  (types only)
   ├─ futarchy_protocol    (core DAO/markets)
   ├─ futarchy_actions     (standard actions)
   ├─ futarchy_advanced    (markets/oracle/streams)
   └─ futarchy_governance  (multisig/policies)

2. Make FutarchyConfig generic: Account<FutarchyConfig<MarketType>>
   └─ Enable different market types (AMM, CLOB, etc.)

3. Full 3-layer architecture for all actions

4. Implement versioning and upgrade system
```

**Benefits:**
- ✅ All benefits from A & B
- ✅ Future-proof architecture
- ✅ Easier onboarding for new devs
- ✅ Community can build extensions
- ✅ Cleaner dependency graph

**Risks:**
- ⚠️ 6-8 weeks of work
- ⚠️ Need comprehensive testing
- ⚠️ May discover hidden dependencies
- ⚠️ Redeployment complexity

---

## My Recommendation

**Start with Option A, then incrementally move toward B**

### Phase 1: Foundation (Week 1)
```bash
1. Create futarchy_extensions package
2. Define all 145 action types
3. Update futarchy_core type routing
4. Add basic versioning to FutarchyConfig
```

### Phase 2: Proof of Concept (Week 2-3)
```bash
5. Pick 3 simple actions (e.g., UpdateName, SetProposalsEnabled, AddMemo)
6. Refactor them into lib/intents/decoders pattern
7. Validate the pattern works with existing system
```

### Phase 3: Incremental Migration (Week 4+)
```bash
8. Migrate 2-3 actions per week
9. Focus on high-frequency actions first
10. Leave specialized actions (markets, oracle) as-is
```

## Why NOT Full Restructuring (Option C)?

1. **Your complexity is REAL domain complexity**
   - Conditional markets are inherently complex
   - Policy enforcement is a unique governance primitive
   - Quantum liquidity is novel research
   - This isn't accidental complexity to refactor away

2. **17 packages is actually reasonable**
   - markets_primitives, markets_core, markets_operations
   - Each does ONE thing (SRP)
   - Clear dependency graph
   - Easy to understand boundaries

3. **Move Framework is simpler because its domain is simpler**
   - Generic account → vault → mint/burn/transfer
   - No markets, no conditional tokens, no oracles
   - No policy enforcement, no multi-council governance
   - They're an SDK, you're a protocol

## What You Should Steal from Move Framework

✅ **DO adopt:**
1. Extensions pattern (zero-dep type registry)
2. TypeName-based routing (compile-time safety)
3. Three-layer architecture for NEW actions
4. Version tracking in configs
5. `public fun share_account()` pattern for hot potato

❌ **DON'T adopt:**
1. Consolidating to 3 packages (you need 17)
2. Generic Config<T> (FutarchyConfig is specific)
3. Migrating ALL actions (too risky)
4. Their action set (yours is domain-specific)

## Conclusion

**Your futarchy codebase is complex because futarchy IS complex.**

The Move Framework is a beautiful reference architecture for:
- Extensibility patterns (zero-dep types)
- Clean separation of concerns (3-layer)
- Versioning strategy (Deps + Extensions)

But you shouldn't feel bad about having 17 packages and 70K lines. You're building:
- Novel governance primitives (policy enforcement)
- Advanced market mechanics (conditional AMMs)
- Complex lifecycle management (dissolution, streams, vesting)

**Recommendation: Steal their patterns, keep your structure.**

Start with Option A (extensions + type safety), then incrementally adopt 3-layer architecture for new actions. Leave specialized code (markets, oracle, policy) as-is - it's correctly complex.
