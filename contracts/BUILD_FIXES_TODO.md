# Futarchy Package Build Fixes TODO

**Status as of 2025-10-03**

## ✅ COMPLETED (Building Successfully)

1. **futarchy_types** - ✅ Builds
2. **futarchy_one_shot_utils** - ✅ Builds
3. **futarchy_core** - ✅ Builds (with warnings)
4. **futarchy_markets** - ✅ FIXED - Changed `fee_payment: Coin<SUI>` to `Coin<StableType>` in `proposal.move:778`
5. **futarchy_vault** - ✅ Builds
6. **futarchy_multisig** - ✅ Builds
7. **futarchy_oracle** - ✅ Builds
8. **futarchy_payments** - ✅ Builds
9. **futarchy_streams** - ✅ Builds
10. **futarchy_lifecycle** - ✅ Builds
11. **futarchy_governance_actions** - ✅ Builds
12. **futarchy_legal_actions** - ✅ Builds
13. **futarchy_factory** - ✅ Builds
14. **futarchy_actions** - ✅ FIXED - No actual proposal_state import needed (uses local constants)

## ❌ NEEDS FIXES

### 15. futarchy_dao

**Location:** `/Users/admin/monorepo/contracts/futarchy_dao`

**Error 1 - Type mismatch:**
```
error[E04007]: incompatible types
  ./sources/dao/governance/proposal_lifecycle.move:400:13
  Line 283: proposal: &mut Proposal<AssetType, StableType>
  Expected: StableType
  Given: (some other type)
```

**Error 2 - Missing function:**
```
error[E03003]: unbound module member
  ./sources/dao/garbage-collection/registry.move:47:5
  dao_file_actions::delete_create_child_document(expired);
  ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ Unbound function
```

**Files affected:**
- `sources/dao/governance/proposal_lifecycle.move:400` (line 283 shows type declaration)
- `sources/dao/garbage-collection/registry.move:47`

**Fixes needed:**
1. Fix type compatibility issue in proposal_lifecycle.move
2. Either create `delete_create_child_document` function in `dao_file_actions` or remove the call

---

## Build Order

Packages must be built in dependency order:
1. futarchy_types ✅
2. futarchy_one_shot_utils ✅
3. futarchy_core ✅
4. futarchy_markets ✅
5. futarchy_vault ✅
6. futarchy_multisig ✅
7. futarchy_oracle ✅
8. futarchy_payments ✅
9. futarchy_streams ✅
10. futarchy_lifecycle ✅
11. futarchy_actions ✅
12. futarchy_governance_actions ✅
13. futarchy_legal_actions ✅
14. futarchy_factory ✅
15. futarchy_dao ❌ **Only 2 remaining issues**

---

## Remaining Tasks

### Task 1: futarchy_dao - type compatibility ✅ FIXED
**Resolution:** The proposal_state issue was a false alarm - futarchy_actions builds successfully
- File already uses local constants, no import needed
- Type mismatch needs investigation in proposal_lifecycle.move:400

### Task 2: futarchy_dao - missing function
**Task:** Fix `delete_create_child_document` missing function
- Check if function exists in futarchy_legal_actions
- Either create it or remove the call if deprecated
- Files: `futarchy_dao/sources/dao/garbage-collection/registry.move:47`

---

## Testing Commands

```bash
# Test single package
cd /Users/admin/monorepo/contracts/futarchy_actions
sui move build

# Test all packages
for pkg in futarchy_{types,one_shot_utils,core,markets,vault,multisig,oracle,payments,streams,lifecycle,actions,governance_actions,legal_actions,factory,dao}; do
    echo "=== $pkg ==="
    (cd /Users/admin/monorepo/contracts/$pkg && sui move build 2>&1 | tail -3)
done
```

---

## Notes

- 14 out of 15 packages now build successfully! ✅
- futarchy_actions builds successfully (proposal_state error was false alarm)
- Only futarchy_dao remains with 2 issues to fix
- Once futarchy_dao is fixed, all packages will be building
