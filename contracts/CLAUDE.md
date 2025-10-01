# Futarchy Contracts Deployment Guide

## Sui Security Model

**Important Note**: Sui's execution model is atomic and does not have reentrancy risks like Ethereum. Race conditions are also unlikely due to Sui's object-centric model and transaction ordering guarantees. When you see defensive programming patterns in this codebase (like atomic check-and-delete patterns), they are primarily for code clarity and best practices rather than addressing actual race condition risks that would exist in other blockchain environments.

## Common Build Issues

### Package Address Mismatches
**Issue**: "Conflicting assignments for address" errors during build
**Cause**: Package's own Move.toml has `package_name = "0x0"` while dependencies reference the deployed address
**Fix**: Ensure each package's Move.toml has its own address set to the deployed value, not "0x0"

## Frontend Control
**IMPORTANT**: The frontend and database are fully controlled by us. This means:
- We can track all proposal types and required resources in our database
- Frontend can determine exact type parameters needed for each proposal
- We can pass all required resources as parameters without needing dynamic dispatch
- Type parameters can be specified at the frontend/transaction building layer

This eliminates the need for complex type-erased patterns or string-based dispatch in Move contracts.

## Move Framework Location
The Account Protocol and Move framework this project builds on is located at:
`/Users/admin/monorepo/contracts/move-framework/`

Key directories:
- `/contracts/move-framework/packages/protocol/` - Core Account Protocol
- `/contracts/move-framework/packages/actions/` - Account actions (vault, currency, etc.)
- `/contracts/move-framework/packages/extensions/` - Protocol extensions

## CRITICAL: Hanson-Style Futarchy with Quantum Liquidity

This is a **Hanson-style futarchy implementation** where liquidity exists quantum-mechanically across multiple conditional markets simultaneously.

### Core Mechanism

**Quantum Liquidity Splitting:**
- 1 spot token → 1 conditional token for EACH outcome (not proportional division)
- Example: $100 spot becomes $100 in YES market AND $100 in NO market simultaneously
- Only the highest-priced conditional market wins; its tokens become redeemable 1:1

**During Active Proposals:**
- Spot AMM is COMPLETELY EMPTY (all liquidity in conditionals)
- Price discovery happens across parallel conditional AMMs
- TWAP must aggregate from ALL conditional markets, using highest price

### Why This Architecture Matters

1. **Write-Through Oracle Pattern Required**
   - `get_twap()` MUST call `write_observation()` before reading in same transaction
   - Prevents stale price attacks in quantum liquidity model
   - See: `/contracts/futarchy/sources/markets/oracle.move:473-492`

2. **Security Implications**
   - Price manipulation requires attacking ALL conditional markets simultaneously
   - Standard oracle patterns will fail - liquidity is quantum, not classical
   - Empty spot pools during proposals is intentional, not a bug

### Common Misconceptions

| Wrong Assumption | Reality |
|-----------------|---------|
| Liquidity splits proportionally | Exists fully in ALL outcomes simultaneously |
| Standard oracles work | Must handle quantum liquidity + empty spot |
| Spot price exists during proposals | Only conditional prices exist |

## Design Philosophy: Ephemeral DAOs

Futarchy DAOs are **designed to dissolve** when markets signal they're no longer creating value (price < NAV).

### Key Features

**1. Native Dissolution**
- Market-driven shutdown when price < NAV
- Clean capital return to holders
- Creates natural price floor at NAV

**2. Streaming Payments**
- Continuous operations without discrete treasury votes
- Instant cancellation during dissolution
- No large withdrawals affecting price

**3. Cross-DAO Coordination (M-of-N)**
- Example: 3-of-5 DAOs approve shared infrastructure
- Weighted voting (parent DAO 51%, subsidiaries 49%)
- Atomic all-or-nothing execution

### Lifecycle

```
CREATION → OPERATION → EVALUATION → [DISSOLUTION if price < NAV]
         ↑                        ↓
         └── Continue if price > NAV
```

## DAO Creation & Init Actions

### How DAO Bootstrapping Works

DAOs are created and initialized using PTB composition with hot potato pattern for atomicity:

```typescript
// PTB composes init actions directly - no central dispatcher
const [account, queue, pool] = tx.moveCall({
  target: 'factory::create_dao_unshared',  // Returns unshared hot potatoes
  ...
});

// Each module exposes its own init functions
tx.moveCall({
  target: 'operating_agreement::init_create_operating_agreement',
  arguments: [account, lines, difficulties, ...]
});

tx.moveCall({
  target: 'stream_actions::init_create_stream',
  arguments: [account, recipient, amount, ...]
});

tx.moveCall({
  target: 'account_spot_pool::init_add_liquidity',
  arguments: [assetCoin, stableCoin, pool]
});

// Must finalize to share objects (hot potato consumed)
tx.moveCall({
  target: 'factory::finalize_and_share_dao',
  arguments: [account, queue, pool]
});
```

**Key Points:**
- **No Serialization**: PTBs call entry functions directly (no ActionSpec needed for init)
- **Module Ownership**: Each module (operating_agreement, stream_actions, etc.) owns its init functions
- **Atomic Guarantee**: Hot potatoes ensure all-or-nothing execution
- **Extensible**: Any module can add `init_*` entry functions without modifying core

**Share Functions Added:**
- `account::share_account()`
- `priority_queue::share_queue()`
- `account_spot_pool::share_pool()`

These are required because Sui only allows `share_object` in the module that defines the type.

## PTB-Driven Intent Architecture

### Core Components & Their Roles

#### 1. IntentSpec (The Blueprint)
- **What**: Lightweight, immutable specification of actions to be executed
- **Where**: Stored in Proposals and used during DAO initialization
- **Structure**:
  - `ProposalIntentSpec` (no UID) for storage in proposals
  - `account_protocol::IntentSpec` (with UID) for execution
- **Purpose**: Defines WHAT actions will be executed before they're approved
- **Key Point**: Never executed directly - must be converted to Intent/Executable first

#### 2. Intent (The Live Contract)
- **What**: Stateful object representing approved, executable actions
- **Where**: Stored in Account's intents bag after approval
- **Purpose**: Represents recurring or scheduled actions that persist
- **Lifecycle**: Created from IntentSpec → Lives in Account → Executed via Executable

#### 3. PTB as Dispatcher (The Orchestrator)
- **What**: Programmable Transaction Blocks act as the primary dispatcher
- **How**: Chain multiple entry functions in a single atomic transaction
- **Pattern**:
  ```
  1. execute_proposal() → creates Executable hot potato
  2. execute_config_actions() → processes config actions
  3. execute_liquidity_actions() → processes liquidity actions
  4. execute_finalize() → confirms execution
  ```
- **Benefit**: Composable, flexible, no monolithic on-chain dispatcher needed

#### 4. Init Actions (DAO Creation)
- **What**: Special pattern for atomic DAO initialization
- **How**: Uses hot potato pattern with unshared objects
- **Pattern**:
  ```
  1. create_dao_unshared() → returns Account, Queue, AMM as hot potatoes
  2. execute_init_config() → applies config actions
  3. execute_init_liquidity() → sets up liquidity
  4. finalize_and_share_dao() → shares objects publicly
  ```

### Type-Based Action Routing

**Old System** (String-based):
- Used `action_descriptor` with string categories like `b"treasury"`
- Runtime string comparison for routing
- Prone to typos and runtime errors

**New System** (TypeName-based):
- Uses `type_name::get<action_types::UpdateName>()` for compile-time safety
- O(1) type comparison at runtime
- Action types defined in `futarchy_utils::action_types`
- Zero-cost abstraction with maximum safety

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

## Architecture Overview

Built as a **governance layer** on Account Protocol framework:
- **Futarchy**: Handles governance and market-based decisions
- **Account Protocol**: Manages assets, vaults, and permissions
- **Action Dispatcher**: Routes approved proposals to handlers

### Core Components

**FutarchyConfig** (`dao/core/futarchy_config.move`)
- Creates typed `Account<FutarchyConfig>` for DAOs
- Stores trading params, governance settings, metadata

**Action Dispatcher** (`dao/core/action_dispatcher.move`)
- Hot potato pattern - `Executable` must be consumed
- Routes to action handlers, executes sequentially

**Proposal States** (`dao/governance/proposal.move`)
- `PENDING` → `TRADING` → `PASSED/FAILED` → `EXECUTED`

### Action System

**Futarchy-Specific Actions:**
- Config: `SetProposalsEnabled`, `UpdateName`, trading params
- Dissolution: `InitiateDissolution`, `DistributeAsset`, `FinalizeDissolution`
- Liquidity: Pool creation/management for AMMs
- Streams: Recurring payments with instant cancellation
- Operating Agreement: On-chain legal document management

**Delegated to Account Protocol:**
```move
// Transfers
vault_intents::request_spend_and_transfer<Config, Outcome, CoinType>(...)

// Minting
currency_intents::request_mint_and_transfer<Config, Outcome, CoinType>(...)

// Burning
currency_intents::request_withdraw_and_burn<Config, Outcome, CoinType>(...)
```

### Security Model

Access control hierarchy:
1. `ConfigWitness` - Only `futarchy_config` module can create
2. `Auth` - Via `futarchy_config::authenticate()`
3. `IntentWitness` - Validates action sequence
4. Hot potato ensures atomic execution (no partial proposals)

## Module Structure

```
contracts/futarchy/sources/
├── dao/
│   ├── core/
│   │   ├── futarchy_config.move   # DAO configuration
│   │   ├── action_dispatcher.move # Routes actions
│   │   └── dao_config.move        # Config management
│   ├── governance/
│   │   ├── proposal.move          # Proposal management
│   │   ├── dissolution_actions.move # Shutdown logic
│   │   └── governance_actions.move # Config updates
│   ├── liquidity/
│   │   └── liquidity_actions.move # AMM operations
│   ├── streams/
│   │   └── stream_actions.move    # Recurring payments
│   └── config/
│       └── config_actions.move    # DAO settings
└── markets/
    ├── conditional_token.move     # Quantum token splitting
    ├── conditional_amm.move       # Conditional markets
    └── oracle.move                # Write-through TWAP (lines 473-492)
```

## Action System & Dispatcher

### Complete Action System Overview

The Futarchy DAO inherits a comprehensive set of actions from the Account Protocol Move framework and adds futarchy-specific governance on top. This provides a complete, production-ready action system.

### Inherited Actions from Account Protocol

**Currency Module** (`currency.move`):
- `request_withdraw_and_burn` - Token burning from treasury
- `request_mint_and_transfer` - Token minting with transfer
- `request_mint_and_vest` - Token minting with vesting schedules
- `request_update_metadata` - Update coin metadata
- `request_disable_rules` - Disable currency permission rules

**Vault Module** (`vault.move`):
- `request_spend_and_transfer` - Direct treasury spending
- `request_spend_and_vest` - Treasury spending with vesting

**Owned Module** (`owned.move`):
- `request_withdraw_and_transfer` - Generic object transfers
- `request_withdraw_and_vest` - Create vesting from owned objects
- `request_withdraw_and_transfer_to_vault` - Move objects to vault

**Package Upgrade** (`package_upgrade.move`):
- `request_upgrade_package` - Contract upgrades
- `request_restrict_policy` - Upgrade policy management

**Access Control** (`access_control.move`):
- `request_borrow_cap` - Capability borrowing for privileged operations

**Kiosk** (`kiosk.move`):
- `request_take_nfts` - NFT transfers from kiosk
- `request_list_nfts` - NFT marketplace listing

### Futarchy-Specific Actions

**Config Actions** - DAO parameter management:
- Proposals enable/disable, trading params, metadata, TWAP config
- Governance settings, queue params, slash distribution

**Oracle Actions** - Price-based automation:
- `ReadOraclePriceAction` - Oracle price reading
- `ConditionalMintAction` - Price-triggered minting
- `TieredMintAction` - Multi-tier vesting (founder rewards)

**Dissolution Actions** - Clean shutdown:
- Initiate/cancel dissolution, asset distribution
- Stream cancellation, AMM withdrawal

**Stream Actions** - Payment systems:
- Budget streams with accountability
- Cliff periods and cancellable payments
- Multi-withdrawer project funding

**Operating Agreement** - On-chain legal framework:
- Line management, immutability controls
- Batch modifications

**Liquidity Actions** - AMM management:
- Pool creation, parameter updates
- Liquidity add/remove operations

**Governance Actions** - Meta-governance:
- Second-order proposal creation
- Proposal reservation for evicted proposals

### Action Dispatcher Architecture

The `action_dispatcher` module provides central routing with specialized execution functions:

```move
execute_standard_actions     // Config, memos, operating agreement
execute_vault_spend          // Treasury operations (inherited)
execute_vault_management     // Coin type management (inherited)
execute_oracle_mint         // Oracle-based minting (hot potato)
execute_liquidity_operations // AMM management
execute_stream_operations   // Payment streams
execute_dissolution_operations // Shutdown coordination
execute_governance_operations // Second-order proposals
```

### Hot Potato Pattern Usage

**Direct Execution** (no hot potato):
- **Config actions** - Modify DAO settings already in Account
- **Memo actions** - Just emit events
- **Operating Agreement** - Text management
- **Dissolution actions** - Use resources already in Account
- **Stream actions** - Use resources already in Account
- **Inherited vault intents** - Account Protocol handles resources

**Hot Potato Pattern** (return ResourceRequest):
- **Oracle/Mint actions** - Need external `TreasuryCap` for minting
- **Governance actions** - Need shared objects (`ProposalQueue`, `FeeManager`)
- **Liquidity actions** - Need external AMM pools

The distinction exists because Move's ownership model prevents storing certain resources (TreasuryCaps, Coins, shared objects) in the Account permanently. Actions that need these resources use the hot potato pattern to get them just-in-time from the caller.

### Standard Action Pattern
All actions follow a consistent pattern with `do_` functions that take only standard parameters:

```move
public fun do_action_name<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    version: VersionWitness,
    witness: IW,
    clock: &Clock,  // if needed
    ctx: &mut TxContext,
)
```

### Hot Potato Pattern for Special Resources
Actions needing special resources use the **hot potato pattern**:

1. **Action creates ResourceRequest** (no abilities - must consume):
   ```move
   public fun do_create_proposal<Outcome: store, IW: drop>(
       ...standard params...
   ): ResourceRequest<CreateProposalAction>
   ```

2. **Caller must fulfill in same transaction**:
   ```move
   public fun fulfill_create_proposal(
       request: ResourceRequest<CreateProposalAction>,
       queue: &mut ProposalQueue,
       fee_manager: &mut ProposalFeeManager,
       registry: &mut ProposalReservationRegistry,
       fee_coin: Coin<SUI>,
       clock: &Clock,
       ctx: &mut TxContext,
   ): ResourceReceipt<CreateProposalAction>
   ```

### Production Readiness

The action system is **100% production-ready** with:
- ✅ Complete token operations (mint, burn, vest)
- ✅ Full treasury management (spend, multi-asset)
- ✅ Package upgrades and migrations
- ✅ Emergency controls and risk management
- ✅ Advanced features (streams, cross-DAO, oracle automation)

The architecture correctly:
- Inherits standard operations from Account Protocol
- Adds futarchy-specific logic on top
- Delegates to proven framework code
- Maintains clean separation of concerns

## Architecture Summary: Composable Governance Actions

Our system uses a dual-pattern architecture that cleanly separates the construction of actions from their execution. This design leverages the full power of Programmable Transaction Blocks (PTBs) for maximum composability and security.

### 1. Core Data Structures

**ActionSpec (The Blueprint)**
- Data Structure: `struct { action_type: TypeName, action_data: vector<u8> }`
- Role: A lightweight, immutable, serializable description of a single action. It is a plan, not a live object.
- Used For: Staging actions for DAO initialization and for defining the payload of on-chain governance proposals.

**IntentSpec (The Blueprint Collection)**
- Data Structure: `struct { actions: vector<ActionSpec>, ... }`
- Role: A container for a list of ActionSpec blueprints. It represents the complete set of actions for an init sequence or a proposal outcome.

**Intent (The Live Contract)**
- Data Structure: `struct { actions: Bag, ... }`
- Role: A stateful object stored inside a live Account. It represents an approved, executable plan or a recurring task. It is not used for unapproved proposals to avoid state bloat.

**Executable (The Hot Potato)**
- Data Structure: A hot potato struct that wraps a temporary Intent.
- Role: Securely passes the right to execute a sequence of actions between functions within a single atomic transaction. It cannot be stored or transferred across transaction boundaries.

### 2. The Two-Phase Lifecycle

**Phase A: Construction (Building the IntentSpec Blueprint)**
- How it's Called: Off-chain clients (SDKs, UIs) build a PTB.
- Dispatcher: The PTB acts as a "Builder Dispatcher."
- On-Chain Method: The PTB calls a single, centralized entry function: `init_intent_builder::build_spec(action_id, params_bcs)`.
  - This on-chain builder function uses an if/else chain on action_id to deserialize the params_bcs into a strongly-typed action data struct.
  - It then creates and returns a validated ActionSpec.
- Result: The PTB assembles a list of ActionSpecs to create a complete IntentSpec object on-chain.

**Phase B: Execution (Processing the Executable Hot Potato)**
- How it's Called: An approved proposal or init sequence kicks off the execution flow. A top-level entry function reads an IntentSpec and converts it into an Executable hot potato, which is then passed through a chain of calls in a PTB.
- Dispatcher: The PTB acts as the "Execution Dispatcher." There is no central on-chain main_dispatcher.
- On-Chain Method: The PTB calls a series of modular, category-specific entry functions (e.g., `config_dispatcher::execute_config_actions`, `liquidity_dispatcher::execute_liquidity_actions`).
  - Each of these functions accepts the Executable hot potato, processes all actions relevant to its category in a loop, and then passes the updated hot potato on to the next call in the PTB.
  - Each function has a unique signature, allowing the PTB to provide the specific resources (`&mut SpotAMM`, `Coin<T>`, etc.) that it needs.
- Finalization: The last call in the PTB is to a `confirm_and_cleanup` function that consumes the final Executable, ensuring the process is completed atomically and securely.

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

## Testing

```bash
sui move test --silence-warnings
sui move build --silence-warnings
```

## Key Implementation Notes

- Write-through oracle is MANDATORY due to quantum liquidity
- TWAP aggregates from multiple simultaneous conditional markets
- Historical price stitching required when liquidity returns to spot
- Actions need `ConfigWitness` for proper access control
- 70% less code by delegating to Account Protocol

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

## References

- Robin Hanson's futarchy papers (prediction market governance)
- Conditional token: `/contracts/futarchy/sources/markets/conditional_token.move`
- AMM: `/contracts/futarchy/sources/markets/conditional_amm.move`
- Oracle (critical): `/contracts/futarchy/sources/markets/oracle.move:473-492`
## ExecutionContext Removal & PTB Architecture

### Key Changes Made (2025-09-18)
- **Removed ExecutionContext** entirely - PTBs handle object flow naturally
- **Removed placeholder system** - Use direct IDs instead of indices
- **Kept ResourceRequest pattern** - Valid for external resources (hot potato)

### Architecture Decisions

#### What Was Removed
1. **ExecutionContext** - Unnecessary complexity, PTBs handle object flow
2. **Placeholder system** - `placeholder_in/placeholder_out` fields removed
3. **ActionResults** - No longer needed without ExecutionContext
4. **resolve_placeholder()** calls - Function never existed

#### What Was Kept
1. **ResourceRequest pattern** - For actions needing external resources (AMMs, shared objects)
2. **IntentSpec** - Blueprint for proposals and DAO initialization
3. **Direct ID passing** - All actions use explicit IDs

### Pattern Guidelines

**Good Pattern - Direct Execution:**
```move
public fun do_action(
    executable: &mut Executable<Outcome>,
    account: &mut Account<Config>,
    pool_id: ID,  // Direct ID, no placeholders
)
```

**Good Pattern - ResourceRequest for External Resources:**
```move
// When action needs resources not in Account
public fun do_create_pool(...): ResourceRequest<CreatePoolAction> {
    // Returns hot potato for external resources
}

// Caller fulfills with actual resources
public fun fulfill_create_pool(
    request: ResourceRequest<CreatePoolAction>,
    asset_coin: Coin<AssetType>,   // External resource
    stable_coin: Coin<StableType>,  // External resource
): ResourceReceipt<CreatePoolAction>
```

### When to Use ResourceRequest

**Use ResourceRequest when action needs:**
1. **Shared objects** that can't be stored in Account (AMM pools, ProposalQueues)
2. **External coins** from users (not from DAO vault)
3. **Special capabilities** like TreasuryCap for minting

**Don't use ResourceRequest for:**
- Config updates (modify Account directly)
- Vault operations (coins already in Account)
- Stream management (streams stored in Account)
- Dissolution actions (use Account's resources)

### Files Updated in Remove-ExecutionContext Commit
- Removed `action_results.move` - No longer needed
- Removed `security_council_*_with_placeholders.move` - Deprecated pattern
- Updated `executable.move` - Removed ExecutionContext
- Updated `vault.move`, `currency.move` - Removed context usage
- Updated all action files - Removed placeholder fields
- Simplified liquidity actions - Direct ID passing
