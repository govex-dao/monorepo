# Futarchy Contract Cardinality

<img width="773" alt="image" src="https://github.com/user-attachments/assets/099f2353-a3d0-40f5-a850-c2eb3c7717e4" />


# Sequence Diagram

<img width="1048" alt="image" src="https://github.com/user-attachments/assets/707f7a38-9fce-4a98-a6af-1edd4621cd39" />


# Linting

Using this linter https://www.npmjs.com/package/@mysten/prettier-plugin-move

Run this in root
```
npm run prettier -- -w sources/amm/amm.move  
```

## Concatenating all .Move files for use with LLMs

Run these commands from the project root directory (`/Users/admin/monorepo/`):

**All 12 packages (Move Framework + Futarchy):**
```bash
find \
  contracts/move-framework/packages/extensions/sources \
  contracts/move-framework/packages/protocol/sources \
  contracts/move-framework/packages/actions/sources \
  contracts/futarchy_one_shot_utils/sources \
  contracts/futarchy_core/sources \
  contracts/futarchy_markets/sources \
  contracts/futarchy_vault/sources \
  contracts/futarchy_multisig/sources \
  contracts/futarchy_specialized_actions/sources \
  contracts/futarchy_lifecycle/sources \
  contracts/futarchy_actions/sources \
  contracts/futarchy_dao/sources \
  -type f -name '*.move' ! -name "*test*" ! -name "*Test*" -exec cat {} + > all_12_packages.txt
```

**Just 3 Move Framework packages:**
```bash
find \
  contracts/move-framework/packages/extensions/sources \
  contracts/move-framework/packages/protocol/sources \
  contracts/move-framework/packages/actions/sources \
  -type f -name '*.move' ! -name "*test*" ! -name "*Test*" -exec cat {} + > move_framework_only.txt
```

**Just 9 Futarchy packages:**
```bash
find \
  contracts/futarchy_one_shot_utils/sources \
  contracts/futarchy_core/sources \
  contracts/futarchy_markets/sources \
  contracts/futarchy_vault/sources \
  contracts/futarchy_multisig/sources \
  contracts/futarchy_specialized_actions/sources \
  contracts/futarchy_lifecycle/sources \
  contracts/futarchy_actions/sources \
  contracts/futarchy_dao/sources \
  -type f -name '*.move' ! -name "*test*" ! -name "*Test*" -exec cat {} + > futarchy_9_packages.txt
```

**Alternative: Run from contracts/futarchy_dao directory:**
```bash
# If running from contracts/futarchy_dao/
find \
  ../move-framework/packages/extensions/sources \
  ../move-framework/packages/protocol/sources \
  ../move-framework/packages/actions/sources \
  ../futarchy_one_shot_utils/sources \
  ../futarchy_core/sources \
  ../futarchy_markets/sources \
  ../futarchy_vault/sources \
  ../futarchy_multisig/sources \
  ../futarchy_specialized_actions/sources \
  ../futarchy_lifecycle/sources \
  ../futarchy_actions/sources \
  ../futarchy_dao/sources \
  -type f -name '*.move' ! -name "*test*" ! -name "*Test*" -exec cat {} + > ../../all_12_packages.txt
```

```
git add -N .
git diff HEAD | pbcopy
```


```
git diff | pbcopy
```