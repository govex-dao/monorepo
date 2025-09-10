# Futarchy Contracts Deployment Guide

## Sui Security Model

**Important Note**: Sui's execution model is atomic and does not have reentrancy risks like Ethereum. Race conditions are also unlikely due to Sui's object-centric model and transaction ordering guarantees. When you see defensive programming patterns in this codebase (like atomic check-and-delete patterns), they are primarily for code clarity and best practices rather than addressing actual race condition risks that would exist in other blockchain environments.

## Action Descriptor & Approval System

### Why Descriptors in Move Framework?

The system uses `ActionDescriptor` in the base Move Framework (not Futarchy packages) because:

1. **Permissionless enforcement** - Anyone can create intents directly with Move Framework actions. If descriptors were only at the Futarchy layer, malicious actors could bypass approval requirements by calling base actions directly.

2. **Clean layering without circular dependencies**:
   - **Protocol layer** (Move Framework): Stores descriptors as `vector<u8>` - pure structure, no semantics
   - **Application layer** (Futarchy): Interprets bytes, defines policies - semantics without modifying structure

3. **Extensible** - Other projects can use different descriptor categories without modifying base protocol

### Architecture

```move
// In Move Framework - generic bytes, no futarchy concepts
struct ActionDescriptor {
    category: vector<u8>,    // e.g., b"treasury", b"governance"
    action_type: vector<u8>, // e.g., b"spend", b"update_config"
    target_object: Option<ID>,
}

// In Futarchy - interprets bytes, defines approval rules
struct PolicyRegistry {
    pattern_policies: Table<vector<u8>, PolicyRule>,  // b"treasury/spend" -> Treasury Council
    object_policies: Table<ID, PolicyRule>,           // Specific UpgradeCap -> Technical Council
}
```

### Approval Modes

- `MODE_DAO_ONLY (0)`: Only DAO approval needed
- `MODE_COUNCIL_ONLY (1)`: Only specified council approval needed  
- `MODE_DAO_OR_COUNCIL (2)`: Either DAO or council can approve
- `MODE_DAO_AND_COUNCIL (3)`: Both DAO and council must approve

### Key Design Decisions

1. **Every action has descriptors** - All Move Framework and Futarchy actions include descriptors for governance
2. **Parallel vectors in Intent** - `actions: vector<vector<u8>>` and `action_descriptors: vector<ActionDescriptor>` stay in sync
3. **vector<u8> not enums** - Avoids circular dependencies; futarchy defines meaning of bytes
4. **Multi-council support** - DAOs can have Treasury, Technical, Legal, Emergency councils with different responsibilities

## Quick Start

### When to Deploy

Run the deployment script when:
- **First time setup** - No packages have been deployed yet
- **After code changes** - You've modified any Move code
- **Network switch** - Moving from devnet to testnet/mainnet
- **Fresh deployment needed** - Starting over with clean addresses

### How to Deploy

```bash
# Deploy all 13 packages with one command
./deploy_verified.sh

# This will:
# 1. Request gas from faucet automatically
# 2. Deploy all 13 packages in correct dependency order
# 3. Update all Move.toml files with new addresses
# 4. Save deployment results to deployment-logs/ folder
```

### Pre-deployment Checklist

1. **Check network**: `sui client active-env`
2. **Switch if needed**: `sui client switch --env testnet`
3. **Reset addresses** (for fresh deploy): 
   ```bash
   find . -name "Move.toml" -exec sed -i '' 's/= "0x[a-f0-9]*"/= "0x0"/' {} \;
   ```
4. **Run deployment**: `./deploy_verified.sh`

## Overview

The Futarchy protocol consists of 13 interdependent packages that must be deployed in a specific order. The deployment script (`deploy_verified.sh`) handles all dependencies, address updates, and verification automatically.

**Important**: Always use the deployment script rather than deploying manually. The script ensures correct order and updates all cross-package references.

## Package Architecture

### Complete Package List (13 Total)

#### Move Framework Packages (4)
1. **Kiosk** - NFT framework (from move-framework/deps/kiosk)
2. **AccountExtensions** - Extension framework
3. **AccountProtocol** - Core account protocol  
4. **AccountActions** - Standard actions (vault, currency, etc.)

#### Futarchy Packages (9)
5. **futarchy_one_shot_utils** - Utility functions
6. **futarchy_core** - Core futarchy types and config
7. **futarchy_markets** - AMM and conditional markets
8. **futarchy_vault** - Vault management
9. **futarchy_multisig** - Multi-signature support
10. **futarchy_lifecycle** - Proposal lifecycle, streams, oracle
11. **futarchy_specialized_actions** - Legal, governance actions
12. **futarchy_actions** - Main action dispatcher
13. **futarchy_dao** - Top-level DAO package

### Dependency Hierarchy

```
Kiosk (no deps)
├── AccountExtensions (no deps)
│   └── AccountProtocol (depends on AccountExtensions)
│       └── AccountActions (depends on Protocol, Extensions, Kiosk)
│
futarchy_one_shot_utils (no deps)
├── futarchy_core (Protocol, Extensions, one_shot_utils)
│   ├── futarchy_markets (core, one_shot_utils)
│   │   └── futarchy_vault (Protocol, Actions, Extensions, core, markets)
│   │       └── futarchy_multisig (core, vault)
│   │           └── futarchy_lifecycle (core, markets, vault, multisig)
│   │               └── futarchy_specialized_actions (core, markets, vault, multisig, lifecycle)
│   │                   └── futarchy_actions (all above)
│   │                       └── futarchy_dao (all packages)
```

## Deployment Script Details

### Main Script: `deploy_verified.sh`

This script handles the complete deployment process:

```bash
#!/bin/bash
# Key features:
# - Requests gas from faucet automatically
# - Deploys packages in correct dependency order
# - Updates all Move.toml files with new addresses
# - Saves deployment results to JSON
# - Shows clear success/failure status for each package
```

### Important Flags

#### For `sui move build`:
```bash
sui move build --skip-fetch-latest-git-deps
```
- `--skip-fetch-latest-git-deps`: Skip fetching latest git dependencies
- Note: `--skip-dependency-verification` is NOT a valid flag for build

#### For `sui client publish`:
```bash
sui client publish --gas-budget 5000000000 --skip-dependency-verification
```
- `--gas-budget 5000000000`: Set gas budget to 5 SUI
- `--skip-dependency-verification`: Skip verifying dependency source matches on-chain bytecode
- Note: As of recent Sui versions, dependency verification is disabled by default

## Common Issues and Solutions

### 1. Move.toml Configuration Issues

**Problem**: "address with no value" error during build
**Solution**: Each package must have its own address defined:

```toml
[addresses]
package_name = "0x0"  # Set to 0x0 before deployment
# ... other dependencies with their deployed addresses
```

### 2. Incorrect Flag Usage

**Problem**: `error: unexpected argument '--skip-dependency-verification' found` during build
**Cause**: This flag only works with `sui client publish`, not `sui move build`
**Solution**: Use `--skip-fetch-latest-git-deps` for build commands

### 3. Package ID Extraction

**Problem**: Script reports success but packages aren't deployed
**Cause**: Package ID not extracted correctly from output
**Solution**: The script now correctly extracts from this pattern:
```
│  │ PackageID: 0x...                                          │
```

### 4. Gas Issues

**Problem**: Insufficient gas for deployment
**Solution**: Script automatically requests from faucet, but you can manually request:
```bash
sui client faucet
```

## Manual Deployment Steps

If you need to deploy packages manually:

### 1. Check Prerequisites

```bash
# Check gas balance (need at least 10 SUI)
sui client gas

# Request gas if needed
sui client faucet

# Check active network
sui client active-env
```

### 2. Deploy a Single Package

```bash
# Navigate to package directory
cd /path/to/package

# Set package address to 0x0 in Move.toml
sed -i '' "s/^package_name = \"0x[a-f0-9]*\"/package_name = \"0x0\"/" Move.toml

# Build to verify
sui move build --skip-fetch-latest-git-deps

# Deploy and extract package ID
sui client publish --gas-budget 5000000000 --skip-dependency-verification 2>&1 | \
  grep "PackageID:" | sed 's/.*PackageID: //' | awk '{print $1}'

# Update address in all Move.toml files
find /Users/admin/monorepo/contracts -name "Move.toml" -type f -exec \
  sed -i '' "s/package_name = \"0x[a-f0-9]*\"/package_name = \"PACKAGE_ID\"/" {} \;
```

### 3. Verify Deployment

```bash
# Check if package exists (may show as inaccessible for packages)
sui client object <PACKAGE_ADDRESS>

# List your deployed packages
sui client objects --json 2>/dev/null | \
  jq -r '.[] | select(.data.type == "0x2::package::UpgradeCap") | .data.content.fields.package'
```

## Latest Successful Deployment (2025-09-10)

```
Kiosk: 0xe1d663970a1119ce8d90e6c4f8b31b9c7966d5f4fbfacf19a92772775a2b9240
AccountExtensions: 0x8b4728b9820c0ed58e6e23fa0febea36d02da19fc18e35ab5c4ef2c5061c719d
AccountProtocol: 0x94c1beeba30df7e072b6319139337e48db443575010480e61d5d01dc0791b235
AccountActions: 0xbea0b34e19aebe2ddb3601fab55717198493cf55cc1795cb85ff4862aaebab16
futarchy_one_shot_utils: 0xda8a9d91b15a2b0f43c59628f79901ccdb36873c5b2e244e094dd0ee501be794
futarchy_core: 0x6083b01755cd31277f13a35d79dbc97f973e92ae972acdb04ed17c420db2f22b
futarchy_markets: 0x2cc16b854ce326c333dc203e1bf822b6874d4e04e5560d7c77f5a9f2a0137038
futarchy_vault: 0x0794b6f940b07248a139c9641ee3ddf7ab76441951445858f00a83a9a6235124
futarchy_multisig: 0x14adfec6a2a65a20ebcf5af393d7592b5f621aa0f25df2f08a077cd0abf84382
futarchy_lifecycle: 0x0c5a71e8ff53112a355fd3f92aafb18f9c4506d36830f8b9b02756612fb2cb83
futarchy_specialized_actions: 0x783f550c2ff568e5272cf1ce5e43b8ebe24649418dd5b2ddcb9e4d3c6d3bafea
futarchy_actions: 0x06b8ce017ae88cd6a6cdb8d85ad69d3216b8b9fde53e41737b209d11df94411c
futarchy_dao: 0x1af6fed64d756d89c94a9f9663231efd29c725a7c21e93eebacebe78a87ff8bb
```

## Deployment Script Features

The `deploy_verified.sh` script provides:

- **Automatic gas management** - Requests from faucet if needed
- **Correct flag usage** - Uses proper flags for build vs publish
- **Package ID extraction** - Correctly parses deployment output
- **Address updates** - Updates all Move.toml files automatically  
- **Progress tracking** - Shows clear status for each package
- **Error handling** - Stops on failure with clear error messages
- **Results saving** - Saves deployment addresses to JSON file
- **Deployment log** - Complete log of deployment process

## Troubleshooting

### If deployment fails:

1. **Check gas balance**: Ensure you have sufficient SUI
2. **Verify network**: Confirm you're on the correct network
3. **Check dependencies**: Ensure all dependency packages exist
4. **Review logs**: Check the deployment log for specific errors
5. **Reset addresses**: Set package addresses to 0x0 and retry

### Reset all addresses for fresh deployment:

```bash
# Reset all package addresses to 0x0
find . -name "Move.toml" -exec sed -i '' \
  's/= "0x[a-f0-9]*"/= "0x0"/' {} \;
```

### Clean duplicate entries in Move.toml:

```bash
# Remove duplicate lines from Move.toml files
find . -name "Move.toml" | while read file; do
    awk '!seen[$0]++' "$file" > "$file.tmp" && mv "$file.tmp" "$file"
done
```

## Environment Paths

The deployment scripts use these paths:
- **Contracts root**: `/Users/admin/monorepo/contracts`
- **Move framework**: `/Users/admin/monorepo/contracts/move-framework`
- **Kiosk**: `/Users/admin/monorepo/contracts/move-framework/deps/kiosk`
- **Futarchy packages**: `/Users/admin/monorepo/contracts/futarchy_*`

## Best Practices

1. **Always deploy in order** - Dependencies must exist before dependents
2. **Use the script** - Manual deployment is error-prone
3. **Save deployment info** - Keep the JSON output for reference
4. **Check gas first** - Ensure sufficient balance before starting
5. **Verify deployment** - Check that packages exist after deployment
6. **Use correct flags** - Different flags for build vs publish commands

## Support

If deployment fails:
1. Check the deployment log for specific errors
2. Verify all dependencies are correctly deployed
3. Ensure Move.toml files don't have duplicate entries
4. Confirm sufficient gas balance
5. Try resetting addresses and deploying fresh

The `deploy_verified.sh` script handles most edge cases automatically and provides clear error messages to help debug any issues.