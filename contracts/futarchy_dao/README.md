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

## Concatenating all .Move files for use with LLMs

Run these commands from the project root directory (`/Users/admin/monorepo/`):

**All 20 packages (Move Framework + Futarchy):**
```bash
find \
  contracts/move-framework/packages/extensions/sources \
  contracts/move-framework/packages/protocol/sources \
  contracts/move-framework/packages/actions/sources \
  contracts/futarchy_one_shot_utils/sources \
  contracts/futarchy_types/sources \
  contracts/futarchy_core/sources \
  contracts/futarchy_markets/sources \
  contracts/futarchy_vault/sources \
  contracts/futarchy_multisig/sources \
  contracts/futarchy_payments/sources \
  contracts/futarchy_streams/sources \
  contracts/futarchy_oracle/sources \
  contracts/futarchy_factory/sources \
  contracts/futarchy_lifecycle/sources \
  contracts/futarchy_legal_actions/sources \
  contracts/futarchy_governance_actions/sources \
  contracts/futarchy_actions/sources \
  contracts/futarchy_dao/sources \
  -type f -name '*.move' ! -name "*test*" ! -name "*Test*" -exec cat {} + > all_19_packages.txt
```


```
git add -N .
git diff HEAD | pbcopy
```


```
git diff | pbcopy
```


```
for pkg in */; do [ -f "$pkg/Move.toml" ] && (cd "$pkg" && output=$(sui move build --silence-warnings 2>&1 || true) && error_count=$(echo "$output" | grep -c -i "error") && echo "Errors in $pkg: $error_count"); done
```