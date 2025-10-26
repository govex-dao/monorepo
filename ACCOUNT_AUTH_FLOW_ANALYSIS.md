# Account Creation and Auth Flow Analysis

## Overview
This document traces the complete account creation, state transition, and auth mechanisms in the futarchy codebase.

## 1. Account Creation Flow (Unshared State)

### Phase 1.1: Account Object Creation
Location: `/Users/admin/monorepo/contracts/futarchy_factory/sources/factory.move:451`
```move
let mut account = futarchy_config::new_with_package_registry(registry, config, ctx);
```

**Key Point**: At this stage, the Account object is **unshared** (owned, not shared).

### Phase 1.2: Initialize Default Treasury Vault
Location: `/Users/admin/monorepo/contracts/futarchy_factory/sources/factory.move:457-463`
```move
let auth = account::new_auth<FutarchyConfig, futarchy_config::ConfigWitness>(
    &account,
    registry,
    version::current(),
    futarchy_config::authenticate(&account, ctx),
);
vault::open<FutarchyConfig>(auth, &mut account, registry, std::string::utf8(b"treasury"), ctx);
```

**Pattern**: 
1. Generate Auth using `account::new_auth()` from the config module
2. Pass Auth + &mut account to vault operations

### Phase 1.3: Pre-approve Common Coin Types
Location: `/Users/admin/monorepo/contracts/futarchy_factory/sources/factory.move:468-490`
```move
let auth = account::new_auth<FutarchyConfig, futarchy_config::ConfigWitness>(
    &account,
    registry,
    version::current(),
    futarchy_config::authenticate(&account, ctx),
);
vault::approve_coin_type<FutarchyConfig, SUI>(auth, &mut account, registry, std::string::utf8(b"treasury"));
```

**Pattern**: Same as Phase 1.2 - generate Auth for each operation

### Phase 1.4: Lock TreasuryCap with auth_cap
Location: `/Users/admin/monorepo/contracts/futarchy_factory/sources/factory.move:495-509`
```move
let auth = account::new_auth<FutarchyConfig, futarchy_config::ConfigWitness>(
    &account,
    registry,
    version::current(),
    futarchy_config::authenticate(&account, ctx),
);

currency::lock_cap(
    auth,
    &mut account,
    registry,
    treasury_cap,
    option::none(),
);
```

**Implementation in currency.move:124-149**:
```move
public fun lock_cap<CoinType>(
    auth: Auth,
    account: &mut Account,
    registry: &PackageRegistry,
    treasury_cap: TreasuryCap<CoinType>,
    max_supply: Option<u64>,
) {
    account.verify(auth);  // <-- AUTH VERIFICATION
    
    let rules = CurrencyRules<CoinType> { ... };
    account.add_managed_data(registry, CurrencyRulesKey<CoinType>(), rules, version::current());
    
    // Create new auth for add_managed_asset
    let asset_auth = account::new_auth_from_witness(account, registry, version::current(), auth.account_witness());
    account::add_managed_asset(asset_auth, account, registry, TreasuryCapKey<CoinType>(), treasury_cap, version::current());
}
```

### Phase 1.5: Store CoinMetadata with add_managed_asset
Location: `/Users/admin/monorepo/contracts/futarchy_factory/sources/factory.move:512-525`
```move
let auth = account::new_auth<FutarchyConfig, futarchy_config::ConfigWitness>(
    &account,
    registry,
    version::current(),
    futarchy_config::authenticate(&account, ctx),
);
account::add_managed_asset(
    auth,
    &mut account,
    registry,
    CoinMetadataKey<AssetType> {},
    coin_metadata,
    version::current(),
);
```

## 2. Auth Mechanism During Account Creation

### Auth Structure
Location: `/Users/admin/monorepo/contracts/move-framework/packages/protocol/sources/account.move:118-121`
```move
/// Protected type ensuring provenance, authenticate an address to an account.
public struct Auth {
    // address of the account that created the auth
    account_addr: address,
}
```

### Auth Creation - new_auth()
Location: `/Users/admin/monorepo/contracts/move-framework/packages/protocol/sources/account.move:596-607`
```move
/// Returns an Auth object that can be used to call gated functions. 
/// Can only be called from the config module.
public fun new_auth<Config: store, CW: drop>(
    account: &Account,
    registry: &PackageRegistry,
    version_witness: VersionWitness,
    config_witness: CW,
): Auth {
    account.deps().check(version_witness, registry);
    assert_is_config_module<Config, CW>(account, config_witness);
    
    Auth { account_addr: account.addr() }
}
```

### Auth Verification - verify()
Location: `/Users/admin/monorepo/contracts/move-framework/packages/protocol/sources/account.move:371-376`
```move
/// Unpacks and verifies the Auth matches the account.
public fun verify(account: &Account, auth: Auth) {
    let Auth { account_addr } = auth;
    
    assert!(account.addr() == account_addr, EWrongAccount);
}
```

## 3. Critical Pattern: add_managed_asset During Unshared Creation

### The Bug/Pattern in factory.move:940-945
```move
if (coin_metadata.is_some()) {
    account.add_managed_asset(  // <-- NO AUTH PASSED!
        registry,
        CoinMetadataKey<AssetType> {},
        coin_metadata.destroy_some(),
        version::current(),
    );
}
```

### Correct Implementation in factory.move:512-525
```move
let auth = account::new_auth<FutarchyConfig, futarchy_config::ConfigWitness>(
    &account,
    registry,
    version::current(),
    futarchy_config::authenticate(&account, ctx),
);
account::add_managed_asset(
    auth,  // <-- AUTH PASSED!
    &mut account,
    registry,
    CoinMetadataKey<AssetType> {},
    coin_metadata,
    version::current(),
);
```

### add_managed_asset Function Signature
Location: `/Users/admin/monorepo/contracts/move-framework/packages/protocol/sources/account.move:500-513`
```move
/// Adds a managed object to the account.
public fun add_managed_asset<Key: copy + drop + store, Asset: key + store>(
    auth: Auth,  // <-- REQUIRED PARAMETER
    account: &mut Account,
    registry: &package_registry::PackageRegistry,
    key: Key,
    asset: Asset,
    version_witness: VersionWitness,
) {
    account.verify(auth);  // <-- VERIFICATION HAPPENS HERE
    assert!(!has_managed_asset(account, key), EManagedAssetAlreadyExists);
    account.deps().check(version_witness, registry);
    dof::add(&mut account.id, key, asset);
}
```

## 4. Transition to Shared State

### Phase 2: Final Atomic Sharing
Location: `/Users/admin/monorepo/contracts/futarchy_factory/sources/factory.move:549-553`
```move
// --- Phase 3: Final Atomic Sharing ---
// All objects are shared at the end of the function. If any step above failed,
// the transaction would abort and no objects would be created.
transfer::public_share_object(account);
unified_spot_pool::share(spot_pool);
```

**Important**: The Account transitions from unshared (owned) to **shared** state only AFTER all initialization is complete.

## 5. Auth During Initialization vs After Sharing

### During Unshared Creation
- **Requirement**: Auth verification via `account.verify(auth)` in every operation
- **Auth Creation**: `account::new_auth()` requires config_witness from the Config module
- **Works On**: Unshared (owned) Account objects

### After Sharing
- Account becomes `shared` and can be accessed by multiple transactions
- Auth still required for access-controlled functions
- Intents + Executables pattern handles multi-step approval

## 6. Unshared Variants Pattern

### Example: currency.move Lines 151-175
```move
/// Lock treasury cap during initialization - works on unshared Accounts
/// This function is for use during account creation, before the account is shared.
/// SAFETY: This function MUST only be called on unshared Accounts.
/// Calling this on a shared Account bypasses Auth checks.
public(package) fun do_lock_cap_unshared< CoinType>(
    account: &mut Account,
    registry: &PackageRegistry,
    treasury_cap: TreasuryCap<CoinType>,
) {
    // SAFETY REQUIREMENT: Account must be unshared
    // Default rules with no max supply
    let rules = CurrencyRules<CoinType> { ... };
    account.add_managed_data(registry, CurrencyRulesKey<CoinType>(), rules, version::current());
    account.add_managed_asset(registry, TreasuryCapKey<CoinType>(), treasury_cap, version::current());
}
```

**Key Difference**: `do_lock_cap_unshared()` calls `account.add_managed_asset()` WITHOUT Auth!

### Why This Works
The functions like `account.add_managed_asset()` called directly on unshared objects bypass Auth because:
1. The Account is still owned (not shared)
2. Only the creator has access to it
3. The package can enforce safety through the `do_*_unshared` naming convention

### The create_dao_unshared() Pattern
Location: `/Users/admin/monorepo/contracts/futarchy_factory/sources/factory.move:920-946`
```move
if (treasury_cap.is_some()) {
    let auth = account::new_auth<FutarchyConfig, futarchy_config::ConfigWitness>(
        &account,
        registry,
        version::current(),
        futarchy_config::authenticate(&account, ctx),
    );
    currency::lock_cap(  // <-- Uses full lock_cap with Auth
        auth,
        &mut account,
        registry,
        treasury_cap.destroy_some(),
        option::none(),
    );
}

// INCONSISTENCY: CoinMetadata stored differently
if (coin_metadata.is_some()) {
    account.add_managed_asset(  // <-- NO AUTH, THIS IS THE BUG!
        registry,
        CoinMetadataKey<AssetType> {},
        coin_metadata.destroy_some(),
        version::current(),
    );
}
```

## 7. Summary of Auth Flow

### Account Creation Phases
1. **Phase 1: Unshared Creation**
   - Account object created as owned/unshared
   - All operations during this phase STILL require Auth verification
   - Auth is created fresh for each operation via `account::new_auth()`
   
2. **Phase 2: Initialization Operations**
   - vault::open() - requires Auth
   - vault::approve_coin_type() - requires Auth
   - currency::lock_cap() - requires Auth and internal Auth creation
   - account::add_managed_asset() - requires Auth
   
3. **Phase 3: Share & Make Public**
   - Account is shared via `transfer::public_share_object()`
   - Now accessible via intents mechanism

### Key Insight
The Auth mechanism works the same way during unshared creation as after sharing. The difference is:
- **Unshared**: Only the transaction that created it can call operations
- **Shared**: Multiple transactions can propose operations via intents, subject to approval thresholds

The "unshared" convenience functions (do_*_unshared) are PROVIDED for operations that don't need Auth validation during init-time setup, but the standard functions like `add_managed_asset` ALWAYS require Auth regardless of account state.

## 8. Answer to Your Specific Questions

### Q: Do we call add_managed_asset during account creation (unshared)?
**A**: YES. During creation in the `create_dao_internal_with_extensions()` function:
- Line 518: `account::add_managed_asset(auth, ...)` for CoinMetadata 
- Line 503: `currency::lock_cap(auth, ...)` which internally calls add_managed_asset for TreasuryCapKey

### Q: If so, how does auth work there?
**A**: Auth is created fresh for each operation:
```move
let auth = account::new_auth<FutarchyConfig, futarchy_config::ConfigWitness>(
    &account,
    registry,
    version::current(),
    futarchy_config::authenticate(&account, ctx),
);
```
Then immediately passed to the function:
```move
account::add_managed_asset(auth, &mut account, ...);
```

### Q: Is there a pattern of unshared functions that skip auth?
**A**: YES. There are `do_*_unshared` functions like:
- `do_lock_cap_unshared()` in currency.move:155
- `do_mint_unshared()` in currency.move:181
- `do_mint_to_coin_unshared()` in currency.move:209

These functions call account methods WITHOUT Auth, but they include safety documentation stating they must ONLY be called on unshared accounts.

### Q: Are there bugs in the current codebase?
**A**: YES. In `create_dao_unshared()` at lines 940-946:
```move
if (coin_metadata.is_some()) {
    account.add_managed_asset(  // Missing auth parameter!
        registry,
        CoinMetadataKey<AssetType> {},
        coin_metadata.destroy_some(),
        version::current(),
    );
}
```

This should follow the pattern from `create_dao_internal_with_extensions()` at lines 512-525 which properly includes auth.

