# Config Migration Implementation Plan

## Goal
Remove `Account<Config>` generic parameter and store config as dynamic field to enable runtime config migration (e.g., FutarchyV1 → FutarchyV2 → MultiSig).

## Why This Matters
- DAOs can swap governance models without changing Account ID
- Operating agreements stay valid (reference stable account ID)
- Enables true hard forks and version upgrades

## Current Status
✅ Phase 1 COMPLETE: Core account.move changes
- Account struct modified (config field removed)
- Dynamic field keys added (ConfigKey, ConfigTypeKey)
- config(), config_mut(), new() updated to use dynamic fields
- Error codes added (EWrongConfigType, ENotConfigModule)
- Protocol package builds successfully ✅

✅ Phase 2 COMPLETE: Account Actions package
- Fixed 212 compilation errors → 0 errors (100% reduction!)
- Removed Config from 50+ functions in actions package
- Updated all call sites and type parameters
- Actions package builds successfully ✅

## Implementation Checklist

### Phase 1: Core Protocol (account_protocol) - ✅ COMPLETE
- [x] Remove `config: Config` field from Account struct
- [x] Add ConfigKey and ConfigTypeKey
- [x] Add error codes (EWrongConfigType, ENotConfigModule)
- [x] Update `new()` to store config in dynamic field
- [x] Update `config()` to read from dynamic field
- [x] Update `config_mut()` to borrow_mut from dynamic field
- [x] Add `assert_is_config_module_static()` helper
- [x] Update `assert_is_config_module()` with runtime validation
- [x] Update `new_auth()` with validation
- [x] Update `create_executable()` with validation
- [x] Update `intents_mut()` with validation
- [x] Remove all `Account<Config>` generics (50 occurrences) → `Account`
- [x] Add `: store` bound to all `Config` generics
- [x] Fix account_interface.move macros
- [x] Fix type inference errors in view functions
- [x] Test account.move builds ✅

### Phase 2: Account Actions Package - ✅ COMPLETE
Files updated: 13 files in `move-framework/packages/actions/sources/`
- [x] Update all `Account<Config>` → `Account`
- [x] Add `: store` bound where needed
- [x] Remove Config from functions that don't use it (50+ functions)
- [x] Update all call sites and type parameters
- [x] Fix turbofish syntax issues in macros
- [x] Add Auth accessor function to account.move
- [x] Test builds ✅ (212 errors → 0 errors, 100% reduction!)

### Phase 3: Futarchy Core Package
Files: `futarchy_core/sources/*.move`
- [ ] Update futarchy_config.move accessor functions
- [ ] Update all `Account<FutarchyConfig>` → `Account`
- [ ] Test builds

### Phase 4: Futarchy Action Packages
Packages to update:
- [ ] futarchy_actions (config, quota, liquidity)
- [ ] futarchy_governance_actions
- [ ] futarchy_stream_actions
- [ ] futarchy_oracle_actions
- [ ] futarchy_factory
- [ ] futarchy_governance
- [ ] futarchy_markets_operations

### Phase 5: V3 Packages
**Note**: V3 packages will NOT be included in this migration.

### Phase 6: Migration API
Add to account.move:
- [ ] `migrate_config<OldConfig, NewConfig, OldWitness, NewWitness>()` function
- [ ] ConfigMigrated event
- [ ] Documentation

### Phase 7: Testing
- [ ] Create migration test helpers
- [ ] Test config storage/retrieval
- [ ] Test witness validation (wrong type, wrong witness)
- [ ] Test config migration
- [ ] Test authorization checks

## Current Errors to Fix

### Type Inference Errors
Many functions now cannot infer `Config` type because Account no longer has the generic parameter.

**Solution**: Explicitly provide type annotations where needed.

Example:
```move
// Before (Config inferred from Account<Config>)
account.addr()

// After (Config must be explicit)
account.addr<FutarchyConfig>()
```

### account_interface.move Macros
The macro system uses `Account<$Config>` which is now invalid.

**Solution**: Update macro templates to use `Account` and require explicit Config in function signatures.

### Too Many Type Arguments Errors
Locations that reference `Account<Config>` but Account now has 0 type params.

**Solution**: Remove the type argument: `Account<Config>` → `Account`

## Type Inference Resolution Strategy

Functions that need explicit Config annotation:
1. **View functions** (addr, metadata, deps, intents, config, etc.)
   - Cannot infer Config from Account alone
   - Caller must specify: `account::addr<Config>(account)`

2. **Helper functions** (ensure_object_tracker, init_object_tracker, etc.)
   - Called internally, must propagate Config generic
   - Or make them work without Config (preferred)

3. **Auth verification** (verify, assert_is_config_module)
   - Need Config for validation
   - Must be explicit in function signature

## Next Steps
1. Fix account_interface.move macros
2. Fix type inference in account.move
3. Test account_protocol builds
4. Move to Phase 2 (account_actions)
5. Iterate through all packages

## Progress Tracking
- Phase 1: 85% complete (account.move core changes done, need macro + inference fixes)
- Phase 2: Not started
- Phase 3: Not started
- Phase 4: Not started
- Phase 5: Not started
- Phase 6: Not started
- Phase 7: Not started

## Estimated Time
- Phase 1 remaining: 2-3 hours
- Phase 2: 2 hours
- Phase 3: 1 hour
- Phase 4: 4 hours
- Phase 5: 1 hour
- Phase 6: 2 hours
- Phase 7: 3 hours
**Total: ~15 hours (2 days)**
