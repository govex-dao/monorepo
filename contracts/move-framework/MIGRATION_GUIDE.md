# Package Registry Migration Guide

## Overview

We've unified the separate `Extensions` (package whitelist) and `ActionDecoderRegistry` (UI decoders) into a single `PackageRegistry` to eliminate synchronization issues and provide better developer experience.

## Architecture Change

### Before (Problematic):
```
Extensions (packages) ✗ NO CONNECTION ✗ ActionDecoderRegistry (decoders)
    ↓                                           ↓
Two separate AdminCaps                    Manual sync required
Risk of desync: packages without decoders
```

### After (Unified):
```
PackageRegistry (packages + decoders + metadata)
    ↓
Single PackageAdminCap
Atomic operations: can't add package without declaring action types
```

## Breaking Changes

### 1. New Admin Capability

**Old:**
- `account_extensions::extensions::AdminCap` - for packages
- `account_actions::decoder_registry_init::DecoderAdminCap` - for decoders

**New:**
- `account_protocol::package_registry::PackageAdminCap` - for both

### 2. Add Package Operation

**Old:**
```move
// Just add package, forget about decoders
extensions::add(extensions, cap, name, addr, version);

// Later (maybe never): register decoders
decoder_registry_init::update_decoders(registry, decoder_cap, ctx);
```

**New:**
```move
// Atomic: package + action types together
package_registry::add_package(
    registry,
    cap,
    name,
    addr,
    version,
    vector[
        type_name::get<MyAction1>(),
        type_name::get<MyAction2>(),
    ],
    b"category".to_string(),    // e.g., "core", "governance"
    b"description".to_string(),
);
```

### 3. Validation Function

**Old:**
```move
extensions::is_extension(extensions, name, addr, version)
```

**New:**
```move
package_registry::is_valid_package(registry, name, addr, version)
```

## Migration Steps

### For Protocol Admin (One-Time)

1. **Deploy PackageRegistry**
   ```bash
   sui move publish --path contracts/move-framework/packages/protocol
   ```

2. **Migrate AdminCaps to Protocol DAO**
   ```move
   // Old caps
   extensions_admin_intents::migrate_extensions_admin_cap_to_dao(dao, old_extensions_cap);
   decoder_admin_intents::migrate_decoder_admin_cap_to_dao(dao, old_decoder_cap);

   // New unified cap
   package_registry_intents::migrate_package_admin_cap_to_dao(dao, new_package_cap);
   ```

3. **Migrate Existing Packages**
   - For each package in Extensions, add to PackageRegistry with action types
   - Script provided in `scripts/migrate-to-package-registry.ts`

### For Package Developers

**When adding a new action package:**

**Old way:**
```move
// 1. Deploy package
// 2. Request Extensions addition (governance)
extensions_admin_intents::add_extension_to_intent(...)
// 3. Manually register decoders (separate governance action)
// 4. Hope you didn't forget step 3
```

**New way:**
```move
// 1. Deploy package
// 2. Request PackageRegistry addition (governance) - ONE action
package_registry_intents::add_package_to_intent(
    intent,
    name,
    addr,
    version,
    action_types,  // ← Declare your action types here
    category,
    description,
    intent_witness,
);
// Decoders registered via dynamic fields on same registry
```

### For Frontend Developers

**Old way:**
```typescript
// Check if package is whitelisted
const isWhitelisted = await extensions.isExtension(name, addr, version);

// Check if decoder exists (separate object)
const hasDecoder = await decoderRegistry.hasDecoder(actionType);
```

**New way:**
```typescript
// Check package validity
const isValid = await packageRegistry.isValidPackage(name, addr, version);

// Get which package provides an action
const packageName = await packageRegistry.getPackageForAction(actionType);

// Get package metadata (category, description, action types)
const metadata = await packageRegistry.getPackageMetadata(name);
```

## Benefits

1. **Atomicity**: Can't have packages without action type metadata
2. **Single Governance**: One AdminCap, one set of governance actions
3. **Better Discovery**: Query which packages provide which actions
4. **Metadata**: Package categories, descriptions, versioning
5. **No Desync**: Packages and action types always consistent

## Backward Compatibility

### Extensions API (Deprecated but Functional)

For gradual migration, we keep `Extensions` as a compatibility wrapper:

```move
// Still works, but delegates to PackageRegistry
extensions::is_extension(extensions, name, addr, version)
```

**Deprecation Timeline:**
- **Phase 1** (Current): Both Extensions and PackageRegistry work
- **Phase 2** (3 months): Extensions marked deprecated, warnings added
- **Phase 3** (6 months): Extensions removed, PackageRegistry only

## Governance Actions

### Old (Separate):
- `extensions_admin_actions::do_add_extension`
- `extensions_admin_actions::do_remove_extension`
- `decoder_admin_actions::do_update_decoders`

### New (Unified):
- `package_registry_actions::do_add_package`
- `package_registry_actions::do_remove_package`
- `package_registry_actions::do_update_package_version`
- `package_registry_actions::do_update_package_metadata`

## Example: Adding a New Package

```move
// In your governance proposal:
public fun propose_add_my_package<Outcome: store>(
    account: &mut Account,
    params: Params,
    outcome: Outcome,
    ctx: &mut TxContext,
) {
    let mut intent = intent_interface::new_intent(...);

    // Add the package with all metadata atomically
    package_registry_intents::add_package_to_intent(
        &mut intent,
        b"MyAwesomePackage".to_string(),
        @my_package_addr,
        1,  // version
        vector[
            type_name::get<my_package::TransferAction>(),
            type_name::get<my_package::MintAction>(),
        ],
        b"defi".to_string(),  // category
        b"DeFi operations for asset management".to_string(),
        intent_witness,
    );

    // Intent execution will validate and register everything atomically
}
```

## Questions?

See the full API documentation in `contracts/move-framework/packages/protocol/sources/package_registry.move`
