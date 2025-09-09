# Futarchy Contracts Deployment Guide

## Quick Start

```bash
# Deploy all packages with one command
./deploy_futarchy_packages.sh

# Or deploy with force rebuild
./deploy_futarchy_packages.sh --force
```

## Overview

The Futarchy protocol consists of 12 interdependent packages that must be deployed in a specific order. The deployment script handles all dependencies, address updates, and verification automatically.

## Package Architecture

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

### Deployment Order

1. **Kiosk** - NFT framework
2. **AccountExtensions** - Extension framework  
3. **AccountProtocol** - Core account protocol
4. **AccountActions** - Standard actions (vault, currency, etc.)
5. **futarchy_one_shot_utils** - Utility functions
6. **futarchy_core** - Core futarchy types and config
7. **futarchy_markets** - AMM and conditional markets
8. **futarchy_vault** - Vault management
9. **futarchy_multisig** - Multi-signature support
10. **futarchy_lifecycle** - Proposal lifecycle, streams, oracle
11. **futarchy_specialized_actions** - Legal, governance actions
12. **futarchy_actions** - Main action dispatcher
13. **futarchy_dao** - Top-level DAO package

## Common Issues and Solutions

### 1. Move.toml Configuration Issues

**Problem**: "address with no value" error during build
**Cause**: Package's own address not defined in its Move.toml
**Solution**: Each package must have its own address defined:

```toml
[addresses]
package_name = "0x0"  # Set to 0x0 before deployment
# ... other dependencies
```

### 2. Duplicate Entries in Move.toml

**Problem**: Duplicate address entries causing parse errors
**Cause**: Faulty sed commands or multiple update attempts
**Solution**: The deployment script automatically cleans duplicates

### 3. PublishUpgradeMissingDependency Error

**Problem**: Package deployment fails with missing dependency error
**Causes**:
- Dependencies not deployed first
- Incorrect addresses in Move.toml
- Package addresses don't exist on-chain

**Solution**: Use the deployment script which verifies all dependencies

### 4. VMVerificationOrDeserializationError

**Problem**: Package verification fails during deployment
**Cause**: Referenced packages don't exist at specified addresses
**Solution**: Deploy in correct order and verify addresses exist on-chain

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

# Ensure package address is set to 0x0 in Move.toml
sed -i '' 's/^package_name = "0x[a-f0-9]*"/package_name = "0x0"/' Move.toml

# Build to verify
sui move build --skip-fetch-latest-git-deps

# Deploy and extract package ID
PACKAGE_ID=$(sui client publish --gas-budget 5000000000 --skip-fetch-latest-git-deps --json 2>/dev/null | \
  jq -r '.effects.created[] | select(.owner == "Immutable") | .reference.objectId' | head -1)

echo "Package deployed at: $PACKAGE_ID"

# Update address in all Move.toml files
find /Users/admin/monorepo/contracts -name "Move.toml" -type f -exec \
  sed -i '' "s/package_name = \"0x[a-f0-9]*\"/package_name = \"$PACKAGE_ID\"/" {} \;
```

### 3. Verify Deployment

```bash
# Check if package exists on-chain
sui client object <PACKAGE_ADDRESS> --json 2>/dev/null | jq -r '.data.type // "NOT FOUND"'

# List all deployed packages
sui client objects --json 2>/dev/null | \
  jq -r '.[] | select(.data.type == "0x2::package::UpgradeCap") | .data.content.fields.package'
```

## Deployment Script Features

The `deploy_futarchy_packages.sh` script provides:

- **Automatic dependency resolution** - Deploys packages in correct order
- **Address management** - Updates all Move.toml files automatically
- **Duplicate cleanup** - Removes duplicate entries before deployment
- **Gas management** - Checks balance and requests from faucet if needed
- **Deployment verification** - Checks if packages already exist on-chain
- **Comprehensive logging** - Saves deployment log and JSON output
- **Error handling** - Clear error messages and recovery steps
- **Idempotent** - Can be run multiple times safely

## Troubleshooting

### Check Deployment Status

```bash
# Check all package addresses in Move.toml files
for file in $(find . -name "Move.toml"); do
    echo "=== $file ==="
    grep "= \"0x" "$file" | grep -v "^#"
done
```

### Reset All Addresses

```bash
# Reset all package addresses to 0x0 for fresh deployment
find . -name "Move.toml" -exec sed -i '' 's/= "0x[a-f0-9]*"/= "0x0"/' {} \;
```

### Clean Duplicate Entries

```bash
# Remove duplicate lines from Move.toml files
find . -name "Move.toml" | while read file; do
    awk '!seen[$0]++' "$file" > "$file.tmp" && mv "$file.tmp" "$file"
done
```

### Verify Dependencies

```bash
# Check if all dependencies exist for a package
cd /path/to/package
for addr in $(grep '= "0x' Move.toml | cut -d'"' -f2); do
    echo -n "Checking $addr: "
    sui client object $addr --json 2>/dev/null | jq -r '.data.type // "NOT FOUND"' | head -c 50
    echo ""
done
```

## Environment Variables

The deployment script uses these paths:
- Contracts root: `/Users/admin/monorepo/contracts`
- Move framework: `/Users/admin/monorepo/contracts/move-framework`
- Futarchy packages: `/Users/admin/monorepo/contracts/futarchy_*`

## Best Practices

1. **Always deploy in order** - Dependencies must exist before dependents
2. **Verify addresses** - Check packages exist on-chain before proceeding
3. **Clean Move.toml files** - Remove duplicates before deployment
4. **Use the script** - Manual deployment is error-prone
5. **Save deployment info** - Keep the JSON output for reference
6. **Check gas first** - Ensure sufficient balance before starting

## Recent Deployment Example

```
Kiosk: 0x3b6222e7d3b8ea5be933acd16767d022723faf27e8826ea6748179c4342627a7
AccountExtensions: 0x1d02c0069be1b2b6f06f16095c03997ed1d5fab5a725be923ed4b4571c513681
AccountProtocol: 0x128f93d1ad6977fa168c0877160da2f3bbe82a0aa44ee92d65a09d05a2758d50
AccountActions: 0xe70b48716e3e452f055ea38549c4381b6eeb175784364caa09b030e5b2f55714
futarchy_one_shot_utils: 0x6f37d232d20f2ff1f6d30e7eccc8ea77955fb1bd85a67f26169d96672c878839
futarchy_core: 0x516f4a3b32bc43213229e2c7327dcaba83251328fdcf116bbaa0382a496184d2
futarchy_markets: 0x18cf78cdcc08eeb8abeb4b8bf038c5f33352986fb9c4fe168e2647c1851546e9
futarchy_vault: 0xa3f436ab481645f0f27bb608d0c3ed7b7c2ced8e07aa54531290ae832d97edd7
futarchy_multisig: 0x364fe460e44b8bfcf7d9411400f2f3481a747ab5a7850a002d429d9024130a58
futarchy_lifecycle: 0x7dc13c609cfdfa40836679b32bc178d59ed35784fe5c5d706e243af4e6000901
futarchy_specialized_actions: 0x5c1efbbef09433743ffc879e1afff6704393749c5e5fc205bbdaccaf67739563
futarchy_actions: 0x1ed2edff5cbb02d8bb4d9f2c6258568233ca7d620f8bd28258965787d6be8e85
futarchy_dao: 0xf0b7fd9eb8cb4b1037f23f7e6908b1192540942c3449645ce4a1f79106e21881
```

## Support

If deployment fails:
1. Check the deployment log for specific errors
2. Verify all dependencies are correctly deployed
3. Ensure Move.toml files don't have duplicate entries
4. Confirm sufficient gas balance
5. Try resetting addresses and deploying fresh

The deployment script handles most edge cases automatically, but understanding the manual process helps with debugging.