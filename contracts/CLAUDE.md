# Deployment Guide for Futarchy Contracts

## Overview
This document explains how to properly deploy the futarchy contracts and their dependencies on Sui. The deployment must be done in a specific order due to package dependencies.

## Common Issues and Solutions

### PublishUpgradeMissingDependency Error
This error occurs when:
1. Dependencies are not deployed on the network
2. Move.toml files have incorrect package addresses
3. Package IDs are extracted incorrectly from deployment output

**Solution:** Deploy all dependencies first and ensure correct package ID extraction.

### VMVerificationOrDeserializationError
This error indicates that referenced packages don't exist on-chain with the addresses specified in Move.toml files.

## Deployment Order

The packages must be deployed in this exact order due to dependencies:

1. **Kiosk** (no dependencies)
2. **AccountExtensions** (no dependencies)
3. **AccountProtocol** (depends on AccountExtensions)
4. **AccountActions** (depends on AccountProtocol, AccountExtensions, Kiosk)
5. **futarchy_one_shot_utils** (no dependencies)
6. **futarchy_core** (depends on AccountProtocol, AccountExtensions, futarchy_one_shot_utils)
7. **futarchy_markets** (depends on futarchy_core, futarchy_one_shot_utils)
8. **futarchy_vault** (depends on AccountProtocol, AccountActions, AccountExtensions, futarchy_core, futarchy_markets, futarchy_one_shot_utils)
9. **futarchy_multisig** (depends on futarchy_core, futarchy_one_shot_utils)
10. **futarchy_lifecycle** (depends on futarchy_core, futarchy_markets)
11. **futarchy_actions** (depends on futarchy_core, futarchy_markets, futarchy_vault, futarchy_lifecycle)
12. **futarchy_specialized_actions** (depends on futarchy_core, futarchy_actions, futarchy_vault)
13. **futarchy_dao** (depends on all of the above)

## Deployment Scripts

### Manual Deployment (Recommended for Debugging)

```bash
# Deploy a single package and get the correct package ID
cd /path/to/package
sui client publish --gas-budget 5000000000 --json 2>/dev/null | \
  jq -r '.effects.created[] | select(.owner == "Immutable") | .reference.objectId' | head -1
```

### Automated Deployment Scripts

We have several deployment scripts available:

#### 1. `deploy_all_automated.sh` (RECOMMENDED)
- **Primary deployment script** - deploys all 9 futarchy packages automatically
- Deploys packages in dependency order (futarchy_one_shot_utils → futarchy_core → ... → futarchy_dao)
- Includes automatic gas checking and faucet requests
- Handles Account Protocol packages (checks if already deployed)
- Saves deployment results to timestamped JSON file
- Updates all Move.toml files with deployed addresses automatically
- Usage: 
  - `./deploy_all_automated.sh` - Normal deployment (skips already deployed packages)
  - `./deploy_all_automated.sh --force` - Force redeploy all packages (useful after code changes)
- The script will:
  1. Check gas balance and request from faucet if needed
  2. Check if Account Protocol packages are deployed
  3. Deploy all 9 futarchy packages in order
  4. Update Move.toml files with new addresses after each deployment
  5. Save results to `deployment_results_YYYYMMDD_HHMMSS.json`
  6. Show deployment summary with all package addresses

#### 2. `fresh_deploy.sh`
- Resets all addresses to 0x0 before deployment
- Deploys all packages in dependency order
- Shows final deployment addresses

#### 3. `deploy_account_packages.sh`
- Specifically for deploying Account Protocol packages
- Deploys: AccountExtensions, AccountProtocol, AccountActions

#### 4. `complete_deployment.sh`
- Comprehensive deployment with status checking
- Shows current deployment status before starting
- Updates all Move.toml files automatically

## Step-by-Step Deployment Process

### 1. Check Prerequisites
```bash
# Check gas balance (need at least 5 SUI)
sui client gas

# Request gas if needed
sui client faucet

# Check active network
sui client active-env
```

### 2. Reset All Addresses
```bash
# Reset all package addresses to 0x0
find . -name "Move.toml" -exec sed -i '' 's/= "0x[a-f0-9]*"/= "0x0"/' {} \;
```

### 3. Deploy Dependencies First
```bash
# Deploy Kiosk
cd move-framework/deps/kiosk
KIOSK_ID=$(sui client publish --gas-budget 5000000000 --json 2>/dev/null | \
  jq -r '.effects.created[] | select(.owner == "Immutable") | .reference.objectId' | head -1)
echo "Kiosk deployed: $KIOSK_ID"

# Update Kiosk address everywhere
find /Users/admin/monorepo/contracts -name "Move.toml" -exec \
  sed -i '' "s/kiosk = \"0x0\"/kiosk = \"$KIOSK_ID\"/" {} \;
```

### 4. Deploy Account Protocol Packages
```bash
# Run the account packages deployment script
./deploy_account_packages.sh
```

### 5. Deploy Futarchy Packages
```bash
# Deploy in order: futarchy_one_shot_utils, futarchy_core, futarchy_markets, etc.
# Use the automated script or deploy manually
./fresh_deploy.sh
```

## Verifying Deployment

### Check if a Package Exists On-Chain
```bash
# Check if a package address exists
sui client object <PACKAGE_ADDRESS> --json 2>/dev/null | jq -r '.data.type // "NOT FOUND"'
```

### List All Deployed Packages
```bash
# List all packages owned by current address
sui client objects --json 2>/dev/null | \
  jq -r '.[] | select(.data.type == "0x2::package::UpgradeCap") | .data.content.fields.package'
```

### Verify All Dependencies
```bash
# Check all dependencies in a Move.toml file
for addr in $(grep '= "0x' Move.toml | cut -d'"' -f2); do
    echo -n "Checking $addr: "
    sui client object $addr --json 2>/dev/null | jq -r '.data.type // "NOT FOUND"' | head -c 20
    echo ""
done
```

## Important Notes

1. **Always deploy in dependency order** - Packages depend on each other and must be deployed sequentially
2. **Extract package IDs correctly** - Use the JSON output and look for immutable objects, not transaction digests
3. **Update all Move.toml files** - After deploying each package, update its address in ALL Move.toml files
4. **Check gas before starting** - Deployments require significant gas (3-5 SUI per package)
5. **Use --skip-fetch-latest-git-deps** - This prevents unnecessary network fetches during builds
6. **Build directories are git-ignored** - The .gitignore file excludes all build/ directories and deployment logs

## Troubleshooting

### If deployment fails:
1. Check the error message carefully
2. Verify all dependencies are deployed with correct addresses
3. Ensure Move.toml files don't have corrupted addresses (like "│" or empty strings)
4. Try building the package first: `sui move build --skip-fetch-latest-git-deps`
5. Check gas balance and request more if needed

### Common Errors:
- **PublishUpgradeMissingDependency**: A dependency isn't deployed or has wrong address
- **VMVerificationOrDeserializationError**: Package verification failed, usually due to missing dependencies
- **Error parsing '[addresses]' section**: Move.toml file is corrupted, check for malformed addresses

## Example Successful Deployment

After successful deployment, you should have addresses like:
```
Kiosk: 0x44c5d7428a5924600d6d9d719f267f302cf42decbe2f9b70edbb075f73be5dff
AccountExtensions: 0x18d76db190917de8d07775e5d196c296419f8de05b6e57924fc8e5e755f590f6
AccountProtocol: 0x30448780c44b209898af12419ca4264f2f016c44b66da47d15739fa8a39aa772
AccountActions: 0xe2624dde1c0ea2c2d68472902d69f0569c9317a140c346971af93a975f58024d
futarchy_one_shot_utils: 0x3dda2b29c33b794ca04f89dfeba1db2a3642bc68370a1fd9b8110126e1b74645
futarchy_core: 0xb56da75c850e9e7db23156d975060638b322d117863a143d717bc7df03b1d927
futarchy_markets: 0x4ef303a9f28a6c1e1a583837f0244a7000e550fbc2ccb16f7d46db6f8eb70140
futarchy_vault: 0x43770925f64b0265bf2da5a039c003b2b183537c872f9313936fb9c70e7348eb
```

These addresses will be different for each deployment but should all be 64-character hexadecimal strings starting with 0x.