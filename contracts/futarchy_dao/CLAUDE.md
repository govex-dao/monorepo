# Claude AI Context - Futarchy Protocol

## Common Build Issues

### Package Address Mismatches
**Issue**: "Conflicting assignments for address" errors during build
**Cause**: Package's own Move.toml has `package_name = "0x0"` while dependencies reference the deployed address
**Fix**: Ensure each package's Move.toml has its own address set to the deployed value, not "0x0"

# Claude AI Context - Futarchy Protocol

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

## References

- Robin Hanson's futarchy papers (prediction market governance)
- Conditional token: `/contracts/futarchy/sources/markets/conditional_token.move`
- AMM: `/contracts/futarchy/sources/markets/conditional_amm.move`
- Oracle (critical): `/contracts/futarchy/sources/markets/oracle.move:473-492`



Architecture Summary: Composable Governance Actions
Our system uses a dual-pattern architecture that cleanly separates the construction of actions from their execution. This design leverages the full power of Programmable Transaction Blocks (PTBs) for maximum composability and security.
1. Core Data Structures
ActionSpec (The Blueprint)
Data Structure: struct { action_type: TypeName, action_data: vector<u8> }
Role: A lightweight, immutable, serializable description of a single action. It is a plan, not a live object.
Used For: Staging actions for DAO initialization and for defining the payload of on-chain governance proposals.
IntentSpec (The Blueprint Collection)
Data Structure: struct { actions: vector<ActionSpec>, ... }
Role: A container for a list of ActionSpec blueprints. It represents the complete set of actions for an init sequence or a proposal outcome.
Intent (The Live Contract)
Data Structure: struct { actions: Bag, ... }
Role: A stateful object stored inside a live Account. It represents an approved, executable plan or a recurring task. It is not used for unapproved proposals to avoid state bloat.
Executable (The Hot Potato)
Data Structure: A hot potato struct that wraps a temporary Intent.
Role: Securely passes the right to execute a sequence of actions between functions within a single atomic transaction. It cannot be stored or transferred across transaction boundaries.
2. The Two-Phase Lifecycle
Phase A: Construction (Building the IntentSpec Blueprint)
How it's Called: Off-chain clients (SDKs, UIs) build a PTB.
Dispatcher: The PTB acts as a "Builder Dispatcher."
On-Chain Method: The PTB calls a single, centralized entry function: init_intent_builder::build_spec(action_id, params_bcs).
This on-chain builder function uses an if/else chain on action_id to deserialize the params_bcs into a strongly-typed action data struct.
It then creates and returns a validated ActionSpec.
Result: The PTB assembles a list of ActionSpecs to create a complete IntentSpec object on-chain.
Phase B: Execution (Processing the Executable Hot Potato)
How it's Called: An approved proposal or init sequence kicks off the execution flow. A top-level entry function reads an IntentSpec and converts it into an Executable hot potato, which is then passed through a chain of calls in a PTB.
Dispatcher: The PTB acts as the "Execution Dispatcher." There is no central on-chain main_dispatcher.
On-Chain Method: The PTB calls a series of modular, category-specific entry functions (e.g., config_dispatcher::execute_config_actions, liquidity_dispatcher::execute_liquidity_actions).
Each of these functions accepts the Executable hot potato, processes all actions relevant to its category in a loop, and then passes the updated hot potato on to the next call in the PTB.
Each function has a unique signature, allowing the PTB to provide the specific resources (&mut SpotAMM, Coin<T>, etc.) that it needs.
Finalization: The last call in the PTB is to a confirm_and_cleanup function that consumes the final Executable, ensuring the process is completed atomically and securely.