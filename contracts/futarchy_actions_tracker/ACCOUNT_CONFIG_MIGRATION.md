# Account Config Migration: Making Governance Upgradeable

## TL;DR

**Goal**: Enable DAOs to change governance models (Futarchy → MultiSig → Voting → FutarchyV2) while keeping the same account object ID.

**Current Problem**: `Account<FutarchyConfig>` type is locked forever. Cannot change to `Account<MultiSigConfig>`.

**Solution**: Remove `<Config>` generic, store config as dynamic field instead.

**Effort**: 1-2 days of mechanical refactoring.

**Benefit**: Operating agreement references stable account ID, governance model can evolve.

---

## Why This Matters

### Current Limitation

```move
// Year 1: Create DAO with futarchy governance
let dao = Account<FutarchyConfig> {
    id: 0x123,  // ← Operating agreement references this
    config: FutarchyConfig { ... },
}

// Year 2: Want to switch to multisig
// ❌ IMPOSSIBLE - cannot change type parameter
Account<FutarchyConfig> → Account<MultiSigConfig>  // Compiler error

// Only option: Create NEW account
let new_dao = Account<MultiSigConfig> {
    id: 0xABC,  // ← Different ID!
    config: MultiSigConfig { ... },
}
// Must update operating agreement, transfer all assets, migrate state
```

### With Config Migration

```move
// Year 1: Create DAO with futarchy governance
let dao = Account {
    id: 0x123,  // ← Operating agreement references this
    // config stored as dynamic field
}
df::add(&dao.id, ConfigKey {}, FutarchyConfig { ... });

// Year 2: Migrate to multisig
migrate_config<FutarchyConfig, MultiSigConfig>(
    &mut dao,  // ← SAME ID: 0x123
    FutarchyWitness {},
    MultiSigWitness {},
    |old| transform_to_multisig(old),
);
// Operating agreement unchanged, account ID unchanged, just swapped governance logic
```

---

## Technical Design

### Current Architecture

```move
// account_protocol::account
public struct Account<Config> has key, store {
    id: UID,
    metadata: Metadata,
    deps: Deps,
    intents: Intents,
    config: Config,  // ← Struct field (type is fixed at creation)
}

public fun config_mut<Config, CW: drop>(
    account: &mut Account<Config>,
    version_witness: VersionWitness,
    config_witness: CW,
): &mut Config {
    assert_is_config_module(account, config_witness);
    &mut account.config  // ← Direct field access
}
```

**Limitation**: `Config` type parameter is immutable once the object is created.

### Proposed Architecture

```move
// account_protocol::account
public struct Account has key, store {  // ← No <Config> generic
    id: UID,
    metadata: Metadata,
    deps: Deps,
    intents: Intents,
    // config: Config,  ← REMOVED
}

// Dynamic field keys
public struct ConfigKey has copy, drop, store {}
public struct ConfigTypeKey has copy, drop, store {}

public fun config_mut<Config: store, CW: drop>(
    account: &mut Account,
    version_witness: VersionWitness,
    config_witness: CW,
): &mut Config {
    // Security: Validate witness matches config type
    let stored_type: TypeName = df::borrow(&account.id, ConfigTypeKey {});
    let requested_type = type_name::get<Config>();
    let witness_type = type_name::get<CW>();

    assert!(requested_type == *stored_type, EWrongConfigType);
    assert!(
        requested_type.get_address() == witness_type.get_address() &&
        requested_type.get_module() == witness_type.get_module(),
        ENotConfigModule
    );

    df::borrow_mut<ConfigKey, Config>(&mut account.id, ConfigKey {})
}
```

**Benefit**: Config type can be swapped at runtime (with proper authorization).

---

## Security Model

### Type Safety Trade-off

**Current (Compile-time):**
```move
let account: Account<FutarchyConfig> = ...;
config_mut(account, MultisigWitness {});  // ❌ Compiler error
```

**Proposed (Runtime):**
```move
let account: Account = ...;
config_mut<FutarchyConfig>(account, MultisigWitness {});  // ✅ Compiles, ❌ Runtime error
```

We lose compile-time type safety but gain runtime flexibility.

### Witness Validation (Critical Security)

The security relies on THREE checks:

1. **Config type matches stored type**
   ```move
   assert!(requested_type<Config> == stored_type_from_df, EWrongConfigType);
   ```
   Prevents: Accessing `FutarchyConfig` when `MultiSigConfig` is stored

2. **Witness package matches config package**
   ```move
   assert!(config_type.address() == witness_type.address(), ENotConfigModule);
   ```
   Prevents: Random packages creating witnesses

3. **Witness module matches config module**
   ```move
   assert!(config_type.module() == witness_type.module(), ENotConfigModule);
   ```
   Prevents: Same-package modules accessing each other's configs

### Attack Scenarios & Mitigations

**Attack 1: Type Confusion**
```move
// Attacker tries to access wrong config type
let account: Account = ...;  // Has FutarchyConfig stored
config_mut<MultiSigConfig>(account, FutarchyWitness {});

// Defense: Check 1 fails
assert!(type_name::get<MultiSigConfig>() == stored_futarchy_type);  // ❌ Fails
```

**Attack 2: Wrong Witness**
```move
// Attacker tries to use wrong witness
config_mut<FutarchyConfig>(account, MultiSigWitness {});

// Defense: Check 2-3 fail
assert!(futarchy_type.module() == multisig_type.module());  // ❌ Fails
```

**Attack 3: Same-Package Witness**
```move
// Malicious module in futarchy_core package
module futarchy_core::exploit {
    public struct ExploitWitness has drop {}
}

config_mut<FutarchyConfig>(account, ExploitWitness {});

// Defense: Check 3 fails
assert!(futarchy_config.module() == exploit.module());  // ❌ Fails
// "futarchy_config" != "exploit"
```

---

## Implementation Plan

### Phase 1: Core Protocol (account_protocol)

**File**: `contracts/move-framework/packages/protocol/sources/account.move`

**Changes**:

1. **Modify Account struct** (Line ~74)
   ```move
   // Before
   public struct Account<Config> has key, store {
       id: UID,
       metadata: Metadata,
       deps: Deps,
       intents: Intents,
       config: Config,
   }

   // After
   public struct Account has key, store {
       id: UID,
       metadata: Metadata,
       deps: Deps,
       intents: Intents,
   }
   ```

2. **Add dynamic field keys**
   ```move
   public struct ConfigKey has copy, drop, store {}
   public struct ConfigTypeKey has copy, drop, store {}
   ```

3. **Update `new()` function** (Line ~520)
   ```move
   public fun new<Config: store, CW: drop>(
       config: Config,
       deps: Deps,
       version_witness: VersionWitness,
       config_witness: CW,
       ctx: &mut TxContext,
   ): Account {
       assert_is_config_module_static<Config, CW>();

       let mut account = Account {
           id: object::new(ctx),
           metadata: metadata::empty(),
           deps,
           intents: intents::empty(ctx),
       };

       // Store config as dynamic fields
       df::add(&mut account.id, ConfigKey {}, config);
       df::add(&mut account.id, ConfigTypeKey {}, type_name::get<Config>());

       account
   }
   ```

4. **Update `config()` function** (Line ~617)
   ```move
   public fun config<Config: store>(account: &Account): &Config {
       df::borrow<ConfigKey, Config>(&account.id, ConfigKey {})
   }
   ```

5. **Update `config_mut()` function** (Line ~581)
   ```move
   public fun config_mut<Config: store, CW: drop>(
       account: &mut Account,
       version_witness: VersionWitness,
       config_witness: CW,
   ): &mut Config {
       account.deps().check(version_witness);

       // Enhanced validation
       let stored_type = df::borrow<ConfigTypeKey, TypeName>(&account.id, ConfigTypeKey {});
       let requested_type = type_name::get<Config>();
       let witness_type = type_name::get<CW>();

       assert!(&requested_type == stored_type, EWrongConfigType);
       assert!(
           requested_type.get_address() == witness_type.get_address() &&
           requested_type.get_module() == witness_type.get_module(),
           ENotConfigModule
       );

       df::borrow_mut<ConfigKey, Config>(&mut account.id, ConfigKey {})
   }
   ```

6. **Update `new_auth()` function** (Line ~534)
   ```move
   public fun new_auth<Config: store, CW: drop>(
       account: &Account,
       version_witness: VersionWitness,
       config_witness: CW,
   ): Auth {
       account.deps().check(version_witness);

       // Validate config type matches witness
       let stored_type = df::borrow<ConfigTypeKey, TypeName>(&account.id, ConfigTypeKey {});
       let requested_type = type_name::get<Config>();
       assert!(&requested_type == stored_type, EWrongConfigType);
       assert_is_config_module_static<Config, CW>();

       Auth { account_addr: account.addr() }
   }
   ```

7. **Update all other functions**
   - Find-replace `Account<Config>` → `Account`
   - Most functions don't use config, so minimal changes
   - Total: ~43 function signatures

8. **Add helper function**
   ```move
   fun assert_is_config_module_static<Config, CW: drop>() {
       let config_type = type_name::get<Config>();
       let witness_type = type_name::get<CW>();
       assert!(
           config_type.get_address() == witness_type.get_address() &&
           config_type.get_module() == witness_type.get_module(),
           ENotCalledFromConfigModule
       );
   }
   ```

**Estimated time**: 4-6 hours

---

### Phase 2: Account Actions (account_actions)

**Files**: All files in `contracts/move-framework/packages/actions/sources/`

**Changes**:
- Find-replace: `Account<Config>` → `Account`
- No logic changes needed

**Example**:
```move
// Before
public fun request_spend_and_transfer<Config, Outcome: store, CoinType: drop>(
    auth: Auth,
    account: &mut Account<Config>,
    ...
)

// After
public fun request_spend_and_transfer<Config: store, Outcome: store, CoinType: drop>(
    auth: Auth,
    account: &mut Account,
    ...
)
```

**Note**: Add `: store` bound to `Config` generic where it appears.

**Files to update**:
- `sources/lib/*.move` (~7 files)
- `sources/intents/*.move` (~6 files)
- Total: ~121 occurrences

**Estimated time**: 2-3 hours

---

### Phase 3: Futarchy Packages

**Files**: All futarchy packages

**Changes**:
- Find-replace: `Account<FutarchyConfig>` → `Account`
- Find-replace: `Account<Config>` → `Account`
- Add `: store` bound to config generics

**Example in futarchy_core**:
```move
// Before
public fun internal_config_mut(
    account: &mut Account<FutarchyConfig>,
    version: VersionWitness,
): &mut FutarchyConfig

// After
public fun internal_config_mut(
    account: &mut Account,
    version: VersionWitness,
): &mut FutarchyConfig
```

**Packages to update**:
- futarchy_core (~12 occurrences)
- futarchy_governance_actions
- futarchy_factory
- Other futarchy_* packages

Note: futarchy_legal_actions has been moved to v3_futarchy_legal

**Estimated time**: 2-3 hours

---

### Phase 4: Migration API

**File**: `contracts/move-framework/packages/protocol/sources/account.move`

**Add migration function**:

```move
/// Migrate account from one config type to another
/// Requires authorization from BOTH old and new config modules
public fun migrate_config<OldConfig: store, NewConfig: store, OldWitness: drop, NewWitness: drop>(
    account: &mut Account,
    old_witness: OldWitness,
    new_witness: NewWitness,
    transform: |OldConfig| -> NewConfig,
) {
    // Verify old witness is authorized
    let stored_type = df::borrow<ConfigTypeKey, TypeName>(&account.id, ConfigTypeKey {});
    let old_type = type_name::get<OldConfig>();
    assert!(&old_type == stored_type, EWrongConfigType);
    assert_is_config_module_static<OldConfig, OldWitness>();

    // Verify new witness is authorized
    assert_is_config_module_static<NewConfig, NewWitness>();

    // Remove old config
    let old_config: OldConfig = df::remove(&mut account.id, ConfigKey {});

    // Transform to new config
    let new_config = transform(old_config);

    // Store new config
    df::add(&mut account.id, ConfigKey {}, new_config);

    // Update type tracking
    let _: TypeName = df::remove(&mut account.id, ConfigTypeKey {});
    df::add(&mut account.id, ConfigTypeKey {}, type_name::get<NewConfig>());

    // Emit migration event
    event::emit(ConfigMigrated {
        account_id: object::id(account),
        old_type,
        new_type: type_name::get<NewConfig>(),
    });
}

public struct ConfigMigrated has copy, drop {
    account_id: ID,
    old_type: TypeName,
    new_type: TypeName,
}
```

**Usage example**:
```move
// In futarchy_config.move
public fun migrate_to_multisig(
    account: &mut Account,
    multisig_threshold: u64,
) {
    account::migrate_config<FutarchyConfig, MultiSigConfig, ConfigWitness, multisig::ConfigWitness>(
        account,
        ConfigWitness {},
        multisig::witness(),
        |old_futarchy_config| {
            // Transform old config to new config
            multisig::new_config(
                multisig_threshold,
                old_futarchy_config.dao_name(),
                // ... map other fields
            )
        },
    );
}
```

**Estimated time**: 4-6 hours (including tests)

---

## Testing Strategy

### Unit Tests

1. **Config storage/retrieval**
   ```move
   #[test]
   fun test_config_stored_as_dynamic_field() {
       let account = account::new(TestConfig { val: 42 }, ...);
       assert!(account::config<TestConfig>(&account).val == 42);
   }
   ```

2. **Witness validation**
   ```move
   #[test]
   #[expected_failure(abort_code = EWrongConfigType)]
   fun test_wrong_config_type() {
       let account = account::new(FutarchyConfig { ... }, ...);
       // Try to access with wrong type
       account::config_mut<MultiSigConfig>(&mut account, ...);
   }

   #[test]
   #[expected_failure(abort_code = ENotConfigModule)]
   fun test_wrong_witness() {
       let account = account::new(FutarchyConfig { ... }, ...);
       // Try to use wrong witness
       account::config_mut<FutarchyConfig>(&mut account, MultiSigWitness {});
   }
   ```

3. **Config migration**
   ```move
   #[test]
   fun test_config_migration() {
       let mut account = account::new(ConfigV1 { val: 1 }, ...);

       account::migrate_config(
           &mut account,
           V1Witness {},
           V2Witness {},
           |v1| ConfigV2 { val: v1.val * 2 },
       );

       let v2 = account::config<ConfigV2>(&account);
       assert!(v2.val == 2);
   }
   ```

4. **Migration authorization**
   ```move
   #[test]
   #[expected_failure]
   fun test_migration_requires_both_witnesses() {
       let mut account = account::new(ConfigV1 { ... }, ...);

       // Try to migrate with wrong old witness
       account::migrate_config(
           &mut account,
           WrongWitness {},  // ← Should fail
           V2Witness {},
           |v1| ConfigV2 { ... },
       );
   }
   ```

### Integration Tests

1. Create DAO with FutarchyConfig
2. Execute some proposals
3. Migrate to FutarchyConfigV2
4. Verify old proposals still work
5. Create new proposals with V2 features
6. Migrate to MultiSigConfig
7. Verify assets preserved, account ID unchanged

---

## Migration Guide for Existing Code

### For Config Module Authors (futarchy_config.move)

**Before**:
```move
public fun internal_config_mut(
    account: &mut Account<FutarchyConfig>,
    version: VersionWitness,
): &mut FutarchyConfig {
    account::config_mut<FutarchyConfig, ConfigWitness>(
        account,
        version,
        ConfigWitness {}
    )
}
```

**After**:
```move
public fun internal_config_mut(
    account: &mut Account,  // ← Remove <FutarchyConfig>
    version: VersionWitness,
): &mut FutarchyConfig {
    account::config_mut<FutarchyConfig, ConfigWitness>(
        account,
        version,
        ConfigWitness {}
    )
}
```

### For Action Authors (futarchy_governance_actions)

**Before**:
```move
public fun do_action(
    account: &mut Account<FutarchyConfig>,
    auth: Auth,
) {
    account.verify(auth);
    let config = futarchy_config::config(account);
    // ...
}
```

**After**:
```move
public fun do_action(
    account: &mut Account,  // ← Remove <FutarchyConfig>
    auth: Auth,
) {
    account.verify(auth);
    let config = futarchy_config::config(account);
    // ...
}
```

**That's it!** Just remove the type parameter.

---

## Rollout Strategy

### Option 1: Breaking Upgrade (Clean Cut)

1. Make all changes
2. Publish new package versions
3. All existing DAOs continue working (old package versions)
4. New DAOs use new package versions
5. Existing DAOs can upgrade via package upgrade mechanism

**Pros**: Clean, simple
**Cons**: Breaking change

### Option 2: Compatibility Layer (Gradual)

Keep both systems:
```move
// Old (deprecated)
public fun config_mut_legacy<Config, CW: drop>(
    account: &mut Account<Config>,
    ...
): &mut Config

// New
public fun config_mut<Config: store, CW: drop>(
    account: &mut Account,
    ...
): &mut Config
```

Gradually migrate call sites.

**Pros**: No breaking changes
**Cons**: More complex, two code paths

### Recommendation: Option 1

Since you control the fork and this is pre-mainnet, do a clean breaking upgrade.

---

## FAQ

### Q: Will this break existing DAOs?

**A**: No. Existing DAOs on old package versions keep working. Only new DAOs created with new package use the new system.

### Q: Can we migrate existing DAOs to use config migration?

**A**: Not easily. You'd need to create new Account objects and transfer state. But future DAOs get the benefit.

### Q: What about performance?

**A**: Dynamic field access is slightly slower than direct field access (one extra hash lookup). Negligible for DAO operations.

### Q: What if witness validation has a bug?

**A**: That's the main risk. Thorough testing + security review recommended. The validation logic is only ~20 lines, so surface area is small.

### Q: Can we migrate between ANY config types?

**A**: Yes, as long as:
1. You provide both witnesses (authorization from both modules)
2. You provide a transformation function
3. The transformation succeeds (doesn't abort)

### Q: What happens to dynamic fields during migration?

**A**: They're preserved! Only the config DF is swapped. All other DFs (ProposalQueue, Treasury, etc.) remain untouched.

---

## Success Criteria

After implementation, you should be able to:

1. **Create DAO with FutarchyConfig**
   ```move
   let dao = account::new(FutarchyConfig { ... }, ...);
   ```

2. **Migrate to FutarchyConfigV2**
   ```move
   migrate_config<FutarchyConfig, FutarchyConfigV2>(
       &mut dao,
       FutarchyWitness {},
       FutarchyV2Witness {},
       |v1| transform_v1_to_v2(v1),
   );
   ```

3. **Account ID unchanged**
   ```move
   assert!(object::id(&dao) == original_id);  // ✅ Same ID
   ```

4. **Operating agreement still valid**
   - No need to update legal docs
   - Same on-chain address

5. **All assets preserved**
   - Treasury intact
   - Proposals intact
   - Dynamic fields intact

---

## Next Steps

1. Review this spec with team
2. Decide on rollout strategy
3. Create implementation branch
4. Phase 1: Core protocol changes
5. Phase 2: Actions package
6. Phase 3: Futarchy packages
7. Phase 4: Migration API
8. Testing
9. Security review
10. Deploy

**Estimated total time: 1-2 days implementation + 1 day testing = 2-3 days**

---

## References

- Original discussion: [futarchy_actions_tracker/ACCOUNT_AUTHORITY_ANALYSIS.md](./ACCOUNT_AUTHORITY_ANALYSIS.md)
- Sui dynamic fields: https://docs.sui.io/concepts/dynamic-fields
- Move type reflection: https://github.com/MystenLabs/sui/tree/main/crates/sui-framework/packages/sui-framework/sources/types
