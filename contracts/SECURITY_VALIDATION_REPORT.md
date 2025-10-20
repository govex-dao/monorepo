# Security Validation Report - Config Migration

**Date**: 2025-10-20
**Status**: ✅ All validation checks in place

## Overview

After migrating from `Account<Config>` to `Account` with dynamic field storage, we verified that all security checks are still enforced at runtime.

## Critical Functions with Validation

All functions that mutate or access sensitive account data require both:
1. **Config witness** (`CW: drop`) - proves caller is from the config module
2. **Version witness** - proves caller is from an approved dependency

### 1. `config_mut` - Mutate Config
**Location**: `account.move:630-639`

```move
public fun config_mut<Config: store, CW: drop>(
    account: &mut Account,
    version_witness: VersionWitness,
    config_witness: CW,
): &mut Config {
    account.deps().check(version_witness);              // ✅ Version check
    assert_is_config_module<Config, CW>(account, config_witness);  // ✅ Config validation
    df::borrow_mut<ConfigKey, Config>(&mut account.id, ConfigKey {})
}
```

**Validation**:
- Line 635: Checks version witness is approved dependency
- Line 636: Validates witness matches stored config type AND witness module matches config module

**All Usage Verified**:
- ✅ `futarchy_core/futarchy_config.move:714` - passes `ConfigWitness`
- ✅ `futarchy_actions/config_actions.move` - 12 calls, all pass `ConfigActionsWitness`

---

### 2. `new_auth` - Create Authorization
**Location**: `account.move:584-593`

```move
public fun new_auth<Config: store, CW: drop>(
    account: &Account,
    version_witness: VersionWitness,
    config_witness: CW,
): Auth {
    account.deps().check(version_witness);              // ✅ Version check
    assert_is_config_module<Config, CW>(account, config_witness);  // ✅ Config validation
    Auth { account_addr: account.addr() }
}
```

**Validation**:
- Line 589: Checks version witness
- Line 590: Validates config witness matches stored config

**All Usage Verified**:
- ✅ `futarchy_core/futarchy_config.move:983` - passes `ConfigWitness`
- ✅ `futarchy_factory/factory.move` - 13 calls, all pass `futarchy_config::ConfigWitness`
- ✅ `futarchy_markets_operations/lp_token_custody.move` - 2 calls, pass generic witness `W`

---

### 3. `create_executable` - Create Execution Token
**Location**: `account.move:596-615`

```move
public fun create_executable<Config: store, Outcome: store + copy, CW: drop>(
    account: &mut Account,
    key: String,
    clock: &Clock,
    version_witness: VersionWitness,
    config_witness: CW,
    ctx: &mut TxContext,
): (Outcome, Executable<Outcome>) {
    account.deps().check(version_witness);              // ✅ Version check
    assert_is_config_module<Config, CW>(account, config_witness);  // ✅ Config validation
    // ... creates executable
}
```

**Validation**:
- Line 604: Checks version witness
- Line 605: Validates config witness

**All Usage Verified**:
- ✅ `futarchy_governance_actions/governance_intents.move:78` - passes `GovernanceWitness`

---

### 4. `intents_mut` - Mutate Intents
**Location**: `account.move:618-627`

```move
public fun intents_mut<Config: store, CW: drop>(
    account: &mut Account,
    version_witness: VersionWitness,
    config_witness: CW,
): &mut Intents {
    account.deps().check(version_witness);              // ✅ Version check
    assert_is_config_module<Config, CW>(account, config_witness);  // ✅ Config validation
    &mut account.intents
}
```

**Validation**:
- Line 623: Checks version witness
- Line 624: Validates config witness

**Usage**: Not called directly - accessed via macro system which passes witnesses correctly.

---

## Core Validation Function

### `assert_is_config_module`
**Location**: `account.move:275-286`

```move
public(package) fun assert_is_config_module<Config: store, CW: drop>(
    account: &Account,
    _config_witness: CW,
) {
    // Check 1: Stored type matches requested type
    let stored_type = df::borrow<ConfigTypeKey, TypeName>(&account.id, ConfigTypeKey {});
    let requested_type = type_name::get<Config>();
    assert!(&requested_type == stored_type, EWrongConfigType);  // ✅ Type check

    // Check 2: Witness package/module matches config
    assert_is_config_module_static<Config, CW>();  // ✅ Module check
}
```

**Two-layer validation**:
1. **Runtime**: Stored config type must match requested `Config` type parameter
2. **Static**: Witness module must match Config module (prevents cross-config attacks)

---

## Security Properties Maintained

### ✅ No Config Type Confusion
- Runtime check ensures you can't use `FutarchyConfig` witness to access `MultiSigConfig` data
- Error `EWrongConfigType` thrown if mismatch

### ✅ No Cross-Module Access
- Static check ensures witness comes from same module as Config
- Prevents malicious modules from creating fake witnesses

### ✅ Version Control
- All mutation functions require `VersionWitness`
- Account can upgrade dependencies without breaking security

### ✅ Auth Binding
- `Auth` contains account address, cannot be forged
- `account.verify(auth)` validates authority before mutations

---

## Macro System Validation

The macro system in `account_interface.move` and `intent_interface.move` correctly passes witnesses:

**create_account** (line 55-64):
```move
public macro fun create_account<$Config: store, $CW: drop>(
    $config: $Config,
    $version_witness: VersionWitness,
    $config_witness: $CW,  // ✅ Requires witness
    $ctx: &mut TxContext,
    $init_deps: || -> Deps,
): Account {
    account::new<$Config, $CW>($config, deps, $version_witness, $config_witness, $ctx)
}
```

**create_auth** (line 85-96):
```move
public macro fun create_auth<$Config: store, $CW: drop>(
    $account: &Account,
    $version_witness: VersionWitness,
    $config_witness: $CW,  // ✅ Requires witness
    $grant_permission: ||,
): Auth {
    $grant_permission();
    account.new_auth<$Config, $CW>($version_witness, $config_witness)
}
```

---

## Test Coverage

Key test validates witness enforcement:
- `test_assert_is_config_module_correct_witness()` (account.move:1169-1176)
- Tests that correct witness passes validation

---

## Conclusion

✅ **All security checks are in place and enforced**

The migration from `Account<Config>` to `Account` with dynamic fields maintains the same security guarantees as before:

1. **Config access is gated** - All mutations require config witness
2. **Runtime type safety** - Stored config type validated against requested type
3. **Module isolation** - Witness must come from config module
4. **Version control** - All operations check version witness
5. **No direct access** - Config cannot be accessed without proper witnesses

**Result**: The removal of compile-time `Config` generic is fully compensated by runtime validation. Security is equivalent or stronger.
