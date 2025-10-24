# Coin Registry Migration - CoinMetadata → Currency + MetadataCap

## Summary

Migrated from Sui's old `CoinMetadata<T>` pattern to the new `CoinRegistry` system using `Currency<T>` + `MetadataCap<T>`. This is a **breaking change** with no backward compatibility.

## Why This Change?

### Old System (Deprecated)
- `CoinMetadata<T>`: Owned object containing coin metadata
- Updates via `TreasuryCap` directly
- Each coin creator maintains their own metadata object
- No global registry

### New System (Required)
- `Currency<T>`: Shared object in global `CoinRegistry`
- Updates via `MetadataCap<T>` capability
- All coins registered in Sui's global `CoinRegistry`
- Metadata updates require `MetadataCap`

## Why No Backward Compatibility?

1. **Pre-Production**: We haven't launched to mainnet yet
2. **Cleaner Architecture**: Avoiding technical debt from supporting two systems
3. **Launchpad Focus**: As a launchpad, we only support newly created DAOs
4. **Sui Framework Evolution**: New Sui framework makes old pattern obsolete

## Requires Sui Framework Upgrade

This migration uses new Sui `CoinRegistry` APIs that require a newer Sui version:
- `coin_registry::set_symbol(currency, metadata_cap, symbol)`
- `coin_registry::set_name(currency, metadata_cap, name)`
- `coin_registry::set_description(currency, metadata_cap, description)`
- `coin_registry::set_icon_url(currency, metadata_cap, url)`

**Current Status**: Code won't compile until Sui dependency is upgraded to version with these APIs.

## Key Changes

### 1. Factory/Launchpad (futarchy_factory)
- `create_raise` now **requires** `MetadataCap<RaiseToken>` parameter
- Validates both `RaiseToken` and `StableCoin` exist in Sui's `CoinRegistry`
- Stores `MetadataCap` in Account for DAO governance control

### 2. Currency Actions (move-framework/actions)
- `lock_cap` accepts `Option<MetadataCap<CoinType>>`
- MetadataCap stored in Account via `MetadataCapKey`
- Update intents require MetadataCap existence
- Currency updates use `coin_registry::set_*` functions

### 3. Proposal System (futarchy_markets_core)
- `add_conditional_coin` requires `Currency<T>` + `MetadataCap<T>`
- Validates conditional coins exist in `CoinRegistry`
- Stores `MetadataCap` (not `CoinMetadata`) in proposal
- Reads base coin metadata from `Currency` objects via `coin_registry::name()`, `coin_registry::symbol()`, etc.

### 4. Custom Coin Registry (futarchy_one_shot_utils)
- `CoinSet<T>` stores `MetadataCap<T>` (not `CoinMetadata<T>`)
- `deposit_coin_set` validates coin exists in Sui's `CoinRegistry`
- Enforces all conditional coin types are properly registered

### 5. Module Consolidation
- Deleted: `futarchy_one_shot_utils::coin_validation` (redundant)
- Consolidated: `futarchy_markets_core::conditional_coin_utils`
  - All validation functions (`assert_zero_supply`, `is_supply_zero`)
  - All metadata utilities (`update_conditional_currency`, etc.)

## Migration Checklist

- [x] Update factory to require MetadataCap
- [x] Update currency actions to use Currency + MetadataCap
- [x] Update proposal system for new metadata pattern
- [x] Update custom coin registry validation
- [x] Consolidate validation modules
- [x] Remove old CoinMetadata code paths
- [ ] **Upgrade Sui dependency** (blocks compilation)
- [ ] **Update all tests** to use Currency + MetadataCap
- [ ] Rebuild and verify all packages

## Affected Packages

1. `futarchy_factory` - launchpad changes
2. `move-framework/actions` - currency action changes
3. `futarchy_markets_core` - proposal + conditional coin utils
4. `futarchy_one_shot_utils` - coin registry validation
5. All test files using old CoinMetadata pattern

## Testing Strategy

All existing tests using `CoinMetadata` need updates:
1. Replace `CoinMetadata<T>` with `Currency<T>`
2. Add `MetadataCap<T>` parameters where needed
3. Use `coin_registry::claim_metadata_cap(currency, &treasury_cap)` to get MetadataCap
4. Update metadata via `coin_registry::set_*` functions with MetadataCap

## Breaking Changes

- **API**: All functions accepting `CoinMetadata<T>` now require `Currency<T>` + `MetadataCap<T>`
- **Validation**: Coins must be registered in Sui's global `CoinRegistry`
- **Storage**: DAOs store `MetadataCap<T>` (not `CoinMetadata<T>`) in Account
- **Tests**: All test code using old pattern must be rewritten

## Benefits

1. **Global Registry**: All coins discoverable in Sui's `CoinRegistry`
2. **Shared Metadata**: No duplication, automatic updates across all readers
3. **Permission Model**: Clear separation - `MetadataCap` controls metadata updates
4. **DAO Governance**: DAOs can control coin metadata by storing MetadataCap
5. **Future-Proof**: Aligned with Sui framework evolution
