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

## Action Execution Pattern

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
Actions needing special resources (coins, treasury caps, AMM pools) use the **hot potato pattern**:

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

### Key Benefits
- **Clean interfaces** - Standard actions don't see special resource complexity
- **Type safety** - Hot potato ensures resources are provided atomically
- **Extensible** - Same pattern works for any action needing special resources
- **No parameter threading** - Governance resources don't pollute the entire call chain

### Implementation
- `resource_requests` module provides generic `ResourceRequest<T>` with dynamic fields
- Actions return requests when they need resources, fulfill functions complete execution
- Dispatcher provides both standard (`execute_all_actions`) and resource-aware (`execute_all_actions_with_governance`) versions

## References

- Robin Hanson's futarchy papers (prediction market governance)
- Conditional token: `/contracts/futarchy/sources/markets/conditional_token.move`
- AMM: `/contracts/futarchy/sources/markets/conditional_amm.move`
- Oracle (critical): `/contracts/futarchy/sources/markets/oracle.move:473-492`