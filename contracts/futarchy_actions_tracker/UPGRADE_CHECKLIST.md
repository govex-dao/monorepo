# Complete Upgrade-Friendly Architecture Checklist

## What You Already Identified ✅

1. **Dynamic fields for state and configs** ✅
2. **Move framework style Extensions (DAO approves actions)** ✅

Great! But there's more...

---

## The Complete Checklist

### 1. Dynamic Fields for State & Config ✅ (You Got This)

**What:**
- Store optional features as dynamic fields
- DAO ID stays stable, features can be added/removed

**Why:**
- No backwards compatibility hell
- Pay only for features you use
- Clean evolutionary path

**Status:** You understand this!

---

### 2. Extensions Registry for Package Validation ✅ (You Got This)

**What:**
- Global registry of approved packages
- Per-DAO deps list (which packages this DAO allows)
- Validate actions against both

**Why:**
- DAOs opt-in to new action packages
- Security (prevents malicious packages)
- Gradual rollout of new features

**Status:** You understand this!

---

### 3. Version Witnesses (CRITICAL - Check If You Have This)

**What:**
```move
// Every package exports its version
module futarchy_core::version {
    public struct FUTARCHY_CORE has drop {}

    public fun current(): VersionWitness {
        version_witness::new_for_package<FUTARCHY_CORE>()
    }
}

// Actions validate caller package
public fun do_action(
    account: &mut Account<Config>,
    version_witness: VersionWitness,  // ← Who's calling?
    ...
) {
    // Validate package is approved
    deps::check(account.deps(), version_witness);
    // ...
}
```

**Why:**
- Prevents unauthorized packages from calling actions
- Enables per-DAO package allowlists
- Foundation for Extensions pattern

**Check Your Code:**
```bash
grep -r "VersionWitness" contracts/futarchy_*/sources --include="*.move"
grep -r "version::current()" contracts/futarchy_*/sources --include="*.move"
```

**Status:** ❓ Need to verify you're using this everywhere

---

### 4. Generic Actions (CRITICAL - You Need This)

**What:**
```move
// BAD: Hardcoded to one config version
public fun do_action(
    account: &mut Account<FutarchyConfig>,  // ← Locked to V1
    ...
) { }

// GOOD: Generic over config
public fun do_action<Config: store>(
    account: &mut Account<Config>,  // ← Works with V1, V2, V3...
    ...
) { }
```

**Why:**
- Actions work with multiple config versions
- Can deploy FutarchyConfigV2 without rewriting all actions
- Smooth migration (old DAOs use V1, new DAOs use V2)

**Check Your Code:**
```bash
# Are your actions generic?
grep "Account<FutarchyConfig>" contracts/futarchy_*/sources --include="*.move" | wc -l
# vs
grep "Account<Config>" contracts/futarchy_*/sources --include="*.move" | wc -l
```

**Status:** ❓ Need to check

---

### 5. Capability-Based Authorization (You Probably Have This)

**What:**
```move
// Don't check tx_context::sender()
// DO use witness/capability patterns

public struct AdminCap has key, store { id: UID }

public fun admin_action(
    account: &mut Account<Config>,
    _admin_cap: &AdminCap,  // ← Proves authorization
    ...
) { }
```

**Why:**
- Capabilities can be stored in DAOs (multi-sig control)
- Capabilities can be transferred/delegated
- More flexible than address checks

**Status:** ✅ Account Protocol uses this

---

### 6. Witness Pattern for Type Safety (IMPORTANT)

**What:**
```move
// One-time witness for module initialization
public struct FUTARCHY_CORE has drop {}

fun init(witness: FUTARCHY_CORE, ctx: &mut TxContext) {
    // Can only be called once per package publish
    // witness proves this is the init call
}

// Generic witness for type markers
public struct CreateDaoFileRegistry has drop {}

public fun create_dao_file_registry(): TypeName {
    type_name::with_defining_ids<CreateDaoFileRegistry>()
}
```

**Why:**
- Type-safe action routing
- Prevents action type confusion
- No string matching, pure type system

**Status:** ✅ You have this (action_type_markers.move)

---

### 7. Hot Potato Pattern for Multi-Step Operations (ADVANCED)

**What:**
```move
// ResourceRequest that MUST be fulfilled
public struct ResourceRequest<T> {
    data: T,
    // No `drop` ability! Must be consumed!
}

// Step 1: Action creates request
public fun do_add_chunk(...): ResourceRequest<AddChunkRequest> {
    // ... validation
    resource_requests::new_resource_request(AddChunkRequest { ... }, ctx)
    // ← Caller MUST call fulfill_add_chunk or transaction aborts!
}

// Step 2: Caller provides resource (Walrus blob)
public fun fulfill_add_chunk(
    request: ResourceRequest<AddChunkRequest>,
    walrus_blob: Blob,
    ...
) {
    // Consume the request (satisfy hot potato)
    let request_data = resource_requests::fulfill(request);
    // Actually add the chunk
    dao_file_registry::add_chunk(..., walrus_blob, ...);
}
```

**Why:**
- Enforce multi-step workflows
- Type-safe state machines
- Cannot skip steps (compiler prevents it)

**Check Your Code:**
```bash
grep -r "ResourceRequest" contracts/futarchy_*/sources --include="*.move"
```

**Status:** ✅ You probably have this (saw it in dao_file_actions)

---

### 8. Versioned BCS Serialization (CRITICAL FOR ACTIONS)

**What:**
```move
// Serialized action data includes version
public struct ActionSpec has store {
    action_type: TypeName,
    version: u64,  // ← Version of serialization format
    data: vector<u8>,  // ← BCS-encoded action params
}

// When deserializing, check version
public fun execute_action(executable: &mut Executable) {
    let spec = get_action_spec(executable);
    let version = action_spec_version(spec);

    assert!(version == 1, EUnsupportedActionVersion);

    // Deserialize based on version
    if (version == 1) {
        deserialize_v1(spec.data)
    } else if (version == 2) {
        deserialize_v2(spec.data)
    }
}
```

**Why:**
- Actions can evolve their parameter format
- Old intents still execute (even with new action code)
- Can add optional parameters without breaking old intents

**Check Your Code:**
```bash
grep -r "EUnsupportedActionVersion" contracts/futarchy_*/sources --include="*.move"
grep -r "action_spec_version" contracts/futarchy_*/sources --include="*.move"
```

**Status:** ✅ You probably have this (saw EUnsupportedActionVersion)

---

### 9. Migration Actions (IMPORTANT)

**What:**
```move
// Action to migrate old DAO to new version
public fun migrate_to_v2<Config>(
    account: &mut Account<Config>,
    new_feature_config: NewFeatureConfig,
    ...
) {
    // Add new dynamic fields
    df::add<NewFeatureKey, NewFeatureConfig>(&mut account.id, key, new_feature_config);

    // Remove deprecated fields
    if (df::exists_<OldFeatureKey>(&account.id, old_key)) {
        df::remove<OldFeatureKey, OldFeature>(&mut account.id, old_key);
    }

    // Update version tracker
    df::add<VersionKey, u64>(&mut account.id, VersionKey {}, 2);
}
```

**Why:**
- DAOs can opt-in to upgrades
- Backward compatible (old DAOs keep working)
- Gradual migration (not all-at-once)

**Status:** ❓ Should add these

---

### 10. Shared State Version Tracking (IMPORTANT)

**What:**
```move
// Track version of DAO's structure
public struct Account has key {
    id: UID,
    schema_version: u64,  // ← Track structure version
    // or store in dynamic field:
}

df::add<SchemaVersionKey, u64>(&mut account.id, key, 1);

// Check version before operations
public fun do_action(account: &Account) {
    let version = get_schema_version(account);
    assert!(version >= 2, ERequiresV2Schema);
    // ...
}
```

**Why:**
- Know which features a DAO supports
- Prevent incompatible operations
- Enable feature detection at runtime

**Status:** ❓ Should add

---

### 11. Feature Flags / Capabilities (CRITICAL)

**What:**
```move
// Instead of boolean flags in config:
// use_nft_governance: bool  ← BAD

// Use dynamic field presence:
public struct NftGovernanceCapability has store {
    config: NftGovernanceConfig,
}

// Check capability
if (df::exists_<NftGovernanceCapability>(&account.id, key)) {
    let capability = df::borrow<NftGovernanceCapability>(...);
    // DAO has NFT governance enabled
}

// Enable feature
df::add<NftGovernanceCapability>(&mut account.id, key, capability);

// Disable feature
df::remove<NftGovernanceCapability>(&mut account.id, key);
```

**Why:**
- Presence = enabled, absence = disabled (no bool needed)
- Can store config with the capability
- Can transfer/delegate capabilities
- Zero storage when disabled

**Status:** ❓ Should migrate bools to this pattern

---

### 12. Explicit Type Exports (MAINTENANCE)

**What:**
```move
// In futarchy_types/sources/exports.move (new file)
module futarchy_types::exports {
    // Re-export all types from one place
    public use fun futarchy_config::FutarchyConfig;
    public use fun action_type_markers::CreateDaoFileRegistry;
    public use fun signed::SignedU128;
    // ...
}

// Users import from exports
use futarchy_types::exports::{FutarchyConfig, CreateDaoFileRegistry};
```

**Why:**
- One place to manage public API
- Easy to see what's exported
- Can deprecate old types (don't re-export)
- Clean module organization

**Status:** ❓ Optional but helpful

---

### 13. Deprecation Markers (MAINTENANCE)

**What:**
```move
/// DEPRECATED: Use enable_sponsorship_v2 instead
/// This will be removed in v3.0.0
public fun enable_sponsorship(
    account: &mut Account<Config>,
    ...
) {
    // Old implementation
}

/// New sponsorship with better params
public fun enable_sponsorship_v2(
    account: &mut Account<Config>,
    ...
) {
    // New implementation
}
```

**Why:**
- Clear communication to developers
- Gradual deprecation (not breaking)
- Documentation of migration path

**Status:** ✅ Good practice to adopt

---

### 14. Test Utilities for Migrations (CRITICAL)

**What:**
```move
#[test_only]
module futarchy_test_utils::migration_helpers {
    // Create old-version DAO for testing
    public fun create_v1_dao(ctx: &mut TxContext): Account<FutarchyConfigV1> { ... }

    // Verify migration succeeded
    public fun assert_v2_features(account: &Account) {
        assert!(df::exists_<NewFeatureKey>(&account.id, key), ...);
        assert!(!df::exists_<OldFeatureKey>(&account.id, key), ...);
    }
}

#[test]
fun test_migrate_v1_to_v2() {
    let mut scenario = ts::begin(@admin);

    // Create old DAO
    let mut dao = create_v1_dao(scenario.ctx());

    // Migrate
    migrate_to_v2(&mut dao, new_config);

    // Verify
    assert_v2_features(&dao);

    scenario.end();
}
```

**Why:**
- Catch migration bugs before mainnet
- Confidence in upgrade path
- Document expected behavior

**Status:** ❓ Should add migration tests

---

### 15. Backward Compatibility Layers (OPTIONAL)

**What:**
```move
// Old API (deprecated but still works)
public fun get_trading_period(config: &FutarchyConfig): u64 {
    // Redirect to new location
    dao_config::trading_period_ms(dao_config::trading_params(&config.config))
}

// New API (preferred)
public fun trading_period_ms(config: &FutarchyConfig): u64 {
    dao_config::trading_period_ms(dao_config::trading_params(&config.config))
}
```

**Why:**
- Don't break external integrations
- Gradual migration for frontends
- Deprecate slowly, not abruptly

**Status:** ✅ You already do this (see futarchy_config.move:621-665)

---

### 16. Config Validation Functions (IMPORTANT)

**What:**
```move
// Centralized validation
public fun validate_trading_params(params: &TradingParams) {
    assert!(params.review_period_ms > 0, EInvalidPeriod);
    assert!(params.trading_period_ms > params.review_period_ms, EInvalidPeriod);
    assert!(params.conditional_amm_fee_bps <= 10000, EInvalidFee);
    // ...
}

// Use in constructors AND setters
public fun new_trading_params(...): TradingParams {
    let params = TradingParams { ... };
    validate_trading_params(&params);
    params
}

public fun set_trading_period(params: &mut TradingParams, period: u64) {
    params.trading_period_ms = period;
    validate_trading_params(params);  // ← Re-validate after mutation!
}
```

**Why:**
- Prevent invalid state
- Centralized invariant checking
- Catch bugs early

**Status:** ✅ You have this (see dao_config.move constants)

---

### 17. Event Emission for State Changes (IMPORTANT)

**What:**
```move
public struct FeatureEnabled has copy, drop {
    dao_id: ID,
    feature_name: String,
    timestamp_ms: u64,
}

public fun enable_feature(account: &mut Account, clock: &Clock) {
    df::add<FeatureKey, Feature>(&mut account.id, key, feature);

    // Emit event for indexers
    event::emit(FeatureEnabled {
        dao_id: object::id(account),
        feature_name: b"nft_governance".to_string(),
        timestamp_ms: clock::timestamp_ms(clock),
    });
}
```

**Why:**
- Indexers can track DAO evolution
- Frontend can detect migrations
- Audit trail of changes

**Status:** ✅ You probably have this (saw events in dao_file_registry)

---

### 18. Immutable Core, Mutable Extensions (ARCHITECTURE)

**What:**
```move
// Immutable core (never changes)
public struct Account has key {
    id: UID,  // ← Fixed
    created_at: u64,  // ← Fixed
    // Everything else is mutable/dynamic
}

// Mutable config (can be replaced)
df::add<ConfigKey, Config>(&mut account.id, key, config);

// Mutable features (can be added/removed)
df::add<FeatureAKey, FeatureA>(&mut account.id, key, feature_a);
df::add<FeatureBKey, FeatureB>(&mut account.id, key, feature_b);
```

**Why:**
- Minimal immutable surface = fewer upgrade constraints
- Maximum flexibility for evolution
- Clear separation: identity vs state

**Status:** ⚠️ You have too much in struct (should move to dynamic fields)

---

### 19. Registry Pattern for Global State (ADVANCED)

**What:**
```move
// Shared registry of all DAOs
public struct DaoRegistry has key {
    id: UID,
    daos: Table<ID, DaoMetadata>,  // ← All DAOs register here
}

public struct DaoMetadata has store {
    dao_id: ID,
    created_at: u64,
    schema_version: u64,
    dao_type: u8,  // 0=futarchy, 1=multisig, etc.
}

// DAOs register on creation
public fun create_dao(...): Account {
    let account = Account { ... };

    // Register in global registry
    register_dao(&mut registry, object::id(&account), metadata);

    account
}
```

**Why:**
- Discover all DAOs
- Track ecosystem growth
- Enable cross-DAO queries
- Centralized migration tracking

**Status:** ❓ Optional (for ecosystem scale)

---

### 20. Staged Rollout Pattern (DEPLOYMENT)

**What:**
```move
// Feature flags for gradual rollout
public struct FeatureFlags has store {
    nft_governance_enabled: bool,  // ← Global killswitch
    max_dao_version: u64,  // ← Progressive rollout
}

public fun enable_nft_governance(account: &mut Account, flags: &FeatureFlags) {
    // Check global killswitch
    assert!(flags.nft_governance_enabled, EFeatureDisabled);

    // Check DAO is on supported version
    let version = get_schema_version(account);
    assert!(version <= flags.max_dao_version, EVersionTooNew);

    // Enable feature
    df::add<NftGovernanceKey, NftGovernance>(&mut account.id, key, config);
}
```

**Why:**
- Deploy new features gradually (not all-at-once)
- Can disable feature if bugs found
- Progressive rollout reduces risk

**Status:** ❓ Advanced, add later

---

## Priority Checklist

### Must Have (Do These Now) 🔴

1. **Generic Actions** - Make actions work with `Account<Config>` not `Account<FutarchyConfig>`
2. **Version Witnesses Everywhere** - Validate package on every action
3. **Migration Actions** - Create actions to upgrade DAOs
4. **Schema Version Tracking** - Track which version each DAO is on
5. **Feature Flags as Dynamic Fields** - Replace bools with presence checks

### Should Have (Do These Soon) 🟡

6. **Migration Tests** - Test upgrade paths before mainnet
7. **Deprecation Markers** - Document old APIs
8. **Config Validation** - Centralize invariant checking
9. **Event Emission** - Emit events for all state changes
10. **Immutable Core** - Move more to dynamic fields

### Nice to Have (Do Eventually) 🟢

11. **Type Exports Module** - Clean public API
12. **Registry Pattern** - Global DAO discovery
13. **Staged Rollout** - Feature flag infrastructure
14. **Backward Compat Layers** - Support old APIs temporarily

---

## Quick Audit: Check Your Code

Run these commands to see what you already have:

```bash
# 1. Version Witnesses
grep -r "VersionWitness" contracts/futarchy_*/sources --include="*.move" | wc -l
grep -r "_version_witness" contracts/futarchy_*/sources --include="*.move" | wc -l

# 2. Generic Actions
grep -r "Account<Config>" contracts/futarchy_*/sources --include="*.move" | wc -l
grep -r "Account<FutarchyConfig>" contracts/futarchy_*/sources --include="*.move" | wc -l

# 3. Action Version Checking
grep -r "EUnsupportedActionVersion" contracts/futarchy_*/sources --include="*.move"

# 4. Dynamic Fields Usage
grep -r "df::add\|df::remove\|df::exists" contracts/futarchy_*/sources --include="*.move" | wc -l

# 5. Events
grep -r "event::emit" contracts/futarchy_*/sources --include="*.move" | wc -l

# 6. Feature Flags
grep -r "_enabled: bool" contracts/futarchy_core/sources --include="*.move"
```

---

## Concrete Next Steps

### Step 1: Audit Your Actions (30 min)

```bash
# Find all non-generic actions
grep "pub.*fun do_" contracts/futarchy_*/sources/**/*.move | grep "FutarchyConfig"
```

**For each one:**
- Change `Account<FutarchyConfig>` → `Account<Config>`
- Add generic constraint: `<Config: store>`
- Test still compiles

### Step 2: Add Schema Version (1 hour)

```move
// In futarchy_core/sources/schema_version.move (new file)
module futarchy_core::schema_version {
    public struct SchemaVersionKey has copy, drop, store {}

    const CURRENT_SCHEMA_VERSION: u64 = 1;

    public fun get_version(account: &Account<Config>): u64 {
        if (df::exists_<SchemaVersionKey>(&account.id, key)) {
            *df::borrow<SchemaVersionKey, u64>(&account.id, key)
        } else {
            1  // Default for DAOs created before versioning
        }
    }

    public fun set_version(account: &mut Account<Config>, version: u64) {
        if (df::exists_<SchemaVersionKey>(&account.id, key)) {
            *df::borrow_mut<SchemaVersionKey, u64>(&mut account.id, key) = version;
        } else {
            df::add(&mut account.id, SchemaVersionKey {}, version);
        }
    }
}
```

### Step 3: Create Migration Action Template (30 min)

```move
// In futarchy_actions/sources/migration_actions.move (new file)
module futarchy_actions::migration_actions {
    public fun migrate_to_v2<Config: store>(
        account: &mut Account<Config>,
        auth: Auth,
        // New feature configs...
    ) {
        account.verify(auth);

        let current_version = schema_version::get_version(account);
        assert!(current_version == 1, EAlreadyMigrated);

        // Add new features
        // ...

        // Update version
        schema_version::set_version(account, 2);

        event::emit(DaoMigrated {
            dao_id: object::id(account),
            from_version: 1,
            to_version: 2,
        });
    }
}
```

### Step 4: Migrate One Feature Flag (1 hour)

**Pick one bool field to migrate:**
```move
// Before (in FutarchyConfig):
optimistic_intent_challenge_enabled: bool,

// After (dynamic field):
public struct OptimisticChallengeEnabled has store {
    config: OptimisticChallengeConfig,
}

// Check
if (df::exists_<OptimisticChallengeEnabled>(&account.id, key)) {
    // Enabled
} else {
    // Disabled
}
```

### Step 5: Write Migration Tests (2 hours)

```move
#[test]
fun test_migrate_v1_to_v2() {
    // Create v1 DAO
    // Migrate
    // Assert v2 features exist
    // Assert v1-only features removed
}

#[test]
fun test_v1_dao_still_works() {
    // Create v1 DAO
    // Don't migrate
    // Assert old actions still work
}

#[test]
fun test_cannot_double_migrate() {
    // Create v1 DAO
    // Migrate to v2
    // Try to migrate again
    // Assert fails
}
```

---

## Summary: The Complete Stack

```
┌─────────────────────────────────────────┐
│  20. Staged Rollout (feature flags)     │  🟢 Nice to have
│  19. Registry Pattern (global state)    │  🟢 Nice to have
│  18. Immutable Core + Dynamic Features  │  🟡 Should have
├─────────────────────────────────────────┤
│  17. Event Emission (indexing)          │  🟡 Should have
│  16. Config Validation (invariants)     │  🟡 Should have
│  15. Backward Compat (old APIs work)    │  🟡 Should have
│  14. Test Utilities (migration tests)   │  🔴 Must have
│  13. Deprecation Markers (docs)         │  🟡 Should have
│  12. Type Exports (public API)          │  🟢 Nice to have
├─────────────────────────────────────────┤
│  11. Feature Flags as Capabilities      │  🔴 Must have
│  10. Schema Version Tracking            │  🔴 Must have
│  9. Migration Actions                   │  🔴 Must have
│  8. Versioned BCS (action params)       │  ✅ You have this
│  7. Hot Potato (multi-step ops)         │  ✅ You have this
├─────────────────────────────────────────┤
│  6. Witness Pattern (type markers)      │  ✅ You have this
│  5. Capability-Based Auth               │  ✅ You have this
│  4. Generic Actions                     │  🔴 Must have
│  3. Version Witnesses                   │  🔴 Must have
├─────────────────────────────────────────┤
│  2. Extensions Registry                 │  ✅ You have this
│  1. Dynamic Fields for State            │  ✅ You have this
└─────────────────────────────────────────┘
```

**Focus on the 🔴 Must Haves first!**

You already have solid foundations (1, 2, 5-8). Now add 3, 4, 9-11 and you'll be bulletproof for upgrades!
