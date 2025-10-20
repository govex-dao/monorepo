# Security Attack Analysis - Config Cross-Contamination

**Date**: 2025-10-20
**Status**: ✅ All attack vectors BLOCKED

## Attack Scenarios Analyzed

### Attack 1: Use Config from Account B to Modify Account A

**Goal**: Attacker wants to use Account B's config to modify Account A

**Attack Flow**:
1. Create executable for Account A
2. When calling `do_update_name(executable, account, ...)`, pass Account B instead of Account A
3. Hope to read config from Account B but write to Account A

**BLOCKED BY**:

**Defense Layer 1**: Intent validation in `process_intent` macro
**Location**: `intent_interface.move:118`
```move
executable.intent().assert_is_account(account.addr());
```
- The executable stores Account A's address in the intent
- When you pass Account B, `account.addr()` returns Account B's address
- **MISMATCH** → Transaction aborts with `EWrongAccount`

**Defense Layer 2**: Config is read from the account parameter
**Location**: `account.move:638`
```move
df::borrow_mut<ConfigKey, Config>(&mut account.id, ConfigKey {})
```
- Even if Layer 1 failed (it doesn't), the config is read from `account.id`
- If you pass Account B, config comes from Account B
- But Layer 1 prevents you from ever reaching this point with wrong account

**Result**: ❌ **ATTACK BLOCKED** - Cannot use Account B with Account A's executable

---

### Attack 2: Use Old/Stale Config Reference

**Goal**: Cache a config reference, change the account's config, then use old reference

**Attack Flow**:
1. Get config reference: `let old_config = account::config_mut(account, ...)`
2. Someone updates account's config through a separate transaction
3. Try to use `old_config` reference to bypass new restrictions

**BLOCKED BY**:

**Defense**: Move's borrow checker + references cannot be stored
**Mechanism**:
```move
public fun config_mut<Config: store, CW: drop>(
    account: &mut Account,
    version_witness: VersionWitness,
    config_witness: CW,
): &mut Config {  // ← Returns REFERENCE, not owned value
```

- The return type is `&mut Config` - a mutable reference
- Move's borrow checker ensures references have LIMITED LIFETIME
- References CANNOT be stored in structs
- References CANNOT outlive the transaction
- Each action execution must call `config_mut()` fresh - you CANNOT reuse old references

**Additional Protection**: Transaction atomicity
- If config changes, it's in a DIFFERENT transaction
- Your old reference is already dead by then
- Next transaction must call `config_mut()` again, getting fresh config

**Result**: ❌ **ATTACK BLOCKED** - Cannot store or reuse config references across transactions

---

### Attack 3: Swap Config Type at Runtime

**Goal**: Create account with `FutarchyConfig`, then somehow access it as `MultiSigConfig`

**Attack Flow**:
1. Account created with `FutarchyConfig`
2. Call `config_mut<MultiSigConfig, MultiSigWitness>(...)`
3. Hope to read/write MultiSig data to Futarchy account

**BLOCKED BY**:

**Defense**: Runtime type validation in `assert_is_config_module`
**Location**: `account.move:275-286`
```move
public(package) fun assert_is_config_module<Config: store, CW: drop>(
    account: &Account,
    _config_witness: CW,
) {
    // Runtime check: Stored type must match requested type
    let stored_type = df::borrow<ConfigTypeKey, TypeName>(&account.id, ConfigTypeKey {});
    let requested_type = type_name::get<Config>();
    assert!(&requested_type == stored_type, EWrongConfigType);  // ← ABORTS HERE

    // Static check: Witness module must match config module
    assert_is_config_module_static<Config, CW>();
}
```

**What happens**:
- Account stores `ConfigTypeKey → TypeName("FutarchyConfig")` as dynamic field
- Attacker calls `config_mut<MultiSigConfig, ...>`
- Line 282: `stored_type = "FutarchyConfig"`, `requested_type = "MultiSigConfig"`
- **MISMATCH** → Transaction aborts with `EWrongConfigType`

**Result**: ❌ **ATTACK BLOCKED** - Cannot access config with wrong type parameter

---

### Attack 4: Forge Witness from Different Module

**Goal**: Create a fake witness that passes validation but comes from attacker's module

**Attack Flow**:
1. Attacker creates `malicious_module::ConfigWitness() has drop`
2. Try to call `config_mut<FutarchyConfig, malicious_module::ConfigWitness>(...)`
3. Hope the witness passes validation

**BLOCKED BY**:

**Defense**: Module matching in `assert_is_config_module_static`
**Location**: `account.move:264-272`
```move
fun assert_is_config_module_static<Config, CW: drop>() {
    let config_type = type_name::with_defining_ids<Config>();
    let witness_type = type_name::with_defining_ids<CW>();
    assert!(
        config_type.address_string() == witness_type.address_string() &&
        config_type.module_string() == witness_type.module_string(),
        ENotConfigModule,  // ← ABORTS HERE
    );
}
```

**What happens**:
- `Config = futarchy_core::FutarchyConfig`
  - address: `@futarchy_core`
  - module: `"futarchy_config"`
- `CW = malicious_module::ConfigWitness`
  - address: `@attacker`
  - module: `"malicious_module"`
- **MISMATCH** → Transaction aborts with `ENotConfigModule`

**Additional Protection**: `CW: drop` constraint
- Witness type must have `drop` ability
- Cannot be created by users at runtime
- Must be defined at compile time in the module

**Result**: ❌ **ATTACK BLOCKED** - Witness must come from same module as Config

---

### Attack 5: Time-of-Check Time-of-Use (TOCTOU)

**Goal**: Pass validation, then swap account reference before config access

**Attack Flow**:
1. Call `config_mut(accountA, version, witness)` - passes validation
2. Between validation and `df::borrow_mut`, somehow swap to accountB
3. Validation checked accountA, but borrow happens on accountB

**BLOCKED BY**:

**Defense**: Move's ownership system
**Mechanism**:
```move
public fun config_mut<Config: store, CW: drop>(
    account: &mut Account,  // ← BORROWED, not owned
    version_witness: VersionWitness,
    config_witness: CW,
): &mut Config {
    account.deps().check(version_witness);
    assert_is_config_module<Config, CW>(account, config_witness);

    df::borrow_mut<ConfigKey, Config>(&mut account.id, ConfigKey {})
    // ↑ Same 'account' reference, immutable binding
}
```

- `account` is a reference parameter (immutable binding)
- The SAME reference is used throughout the function
- Move doesn't allow reassigning reference parameters
- No way to "swap" the account between validation and access

**Result**: ❌ **ATTACK BLOCKED** - Cannot swap account reference mid-function

---

### Attack 6: Reentrancy to Modify Config During Access

**Goal**: While holding a config reference, trigger callback that modifies config

**Attack Flow**:
1. Call function A which gets `config_mut()`
2. Function A calls external contract
3. External contract calls back into function B which gets `config_mut()`
4. Function B modifies config while function A still holds reference

**BLOCKED BY**:

**Defense**: Move's borrow checker - no aliasing of mutable references
**Mechanism**:
```move
let config1 = config_mut(account, ...);  // Takes &mut account
// ... still using config1 ...
let config2 = config_mut(account, ...);  // ← COMPILE ERROR: account already mutably borrowed
```

- Move enforces: Only ONE mutable reference to an object at a time
- If function A has `&mut config`, NO other code can get `&mut account` or `&mut config`
- Reentrancy is impossible because second borrow would fail at compile time

**Additional Protection**: Transaction boundaries
- Even if reentrancy was possible in theory, Sui transactions are atomic
- All state changes happen together or not at all
- External calls in PTBs don't allow reentrancy

**Result**: ❌ **ATTACK BLOCKED** - Move prevents mutable reference aliasing

---

## Summary Table

| Attack Scenario | Defense Mechanism | Status |
|----------------|-------------------|---------|
| Cross-account config usage | `intent.assert_is_account()` validates account matches executable | ✅ BLOCKED |
| Stale config reference | Move borrow checker prevents storing references | ✅ BLOCKED |
| Config type confusion | Runtime type check in `assert_is_config_module` | ✅ BLOCKED |
| Forged witness | Static module matching check | ✅ BLOCKED |
| TOCTOU on account | Immutable reference binding in Move | ✅ BLOCKED |
| Reentrancy | Move's borrow checker prevents aliasing | ✅ BLOCKED |

## Defense Layers Summary

1. **Intent/Account Binding** (`intent_interface.move:118`)
   - Executable stores account address
   - Validated before any action execution

2. **Runtime Type Validation** (`account.move:282`)
   - Stored config type must match requested type
   - Prevents config type confusion

3. **Static Module Validation** (`account.move:264-272`)
   - Witness module must match config module
   - Prevents cross-module attacks

4. **Move's Type System**
   - Borrow checker prevents reference aliasing
   - References cannot be stored
   - Immutable bindings prevent swapping

5. **Config Always Read from Parameter** (`account.move:638`)
   - `df::borrow_mut(&mut account.id, ...)` reads from passed account
   - No global state or cached config

## Conclusion

✅ **ALL ATTACK VECTORS BLOCKED**

The migration from `Account<Config>` to `Account` with dynamic fields is SECURE because:

1. **Account identity is bound to executable** - Cannot mix accounts
2. **Config type is validated at runtime** - Cannot access wrong config type
3. **Witness must match config module** - Cannot forge authorization
4. **Move's ownership prevents common attacks** - No TOCTOU, no reentrancy, no stale references
5. **Config is always fresh** - Read directly from account parameter on every access

The removal of compile-time `Config` generic is fully compensated by runtime validation. Security is EQUIVALENT OR STRONGER than before.
