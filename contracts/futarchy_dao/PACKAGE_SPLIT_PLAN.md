# Futarchy Package Split Plan

## Problem Statement
- Main futarchy package is 277KB, exceeding Sui's 128KB transaction size limit by 2.11x
- Cannot deploy to Sui mainnet/testnet/devnet without splitting
- Move 2024 removed `friend` declarations, eliminating cross-package restricted visibility
- Need to maintain security while splitting into deployable packages

## Critical Analysis: Finding the Right Split

### Key Insight: Inverted Dependency Structure

Instead of having all packages depend on core, we can create a cleaner architecture where:
1. **Markets are self-contained** (no dependencies on DAO/governance)
2. **Governance depends on markets** (uses market primitives)
3. **Core orchestrates everything** (depends on both)

### What Needs to Move to Utils

We need to systematically search for ANY module that:
- Is purely algorithmic (no DAO-specific logic)
- Could be reused in other projects
- Is isolated with minimal dependencies
- Contains generic data structures or utilities

**Search targets:**
- Binary heap implementation in priority_queue
- Any sorting/searching algorithms
- Mathematical operations beyond basic math
- Time/date utilities
- String manipulation utilities
- Generic collection types
- Common patterns (singleton, factory, etc.)

## Solution: Inverted Dependency Architecture + Hot Potato Authorization

### Architecture Overview - REVISED

```
OPTION 1: Inverted Dependencies (Cleaner)

futarchy_utils (Generic Libraries) ~10KB
├── Math, time, helpers
├── Binary heap
├── Priority queue generic
└── Other data structures

    ↑ used by all ↑

futarchy_markets (Standalone) ~40KB
├── NO dependencies on DAO/governance
├── Pure market mechanics
├── AMM logic
├── Conditional tokens
└── Oracles

    ↑ used by ↑

futarchy_governance (Depends on Markets) ~35KB
├── Proposals (use markets)
├── Voting mechanisms
├── Resolution logic
└── Fee management

    ↑ both used by ↑

futarchy_core (Orchestrator) ~30KB
├── Entry points
├── DAO struct
├── Hot potatoes
└── Depends on BOTH markets & governance
```

OR

```
OPTION 2: Hot Potato Pattern (Original)

futarchy_core (Entry Point Package) ~20KB
├── All public entry functions (83 total)
├── Hot potato authorization types
├── Payment/fee handling
├── Core DAO struct and config
├── Version management
└── Minimal orchestration logic

    ↓ creates hot potatoes for ↓

futarchy_markets ~40KB        futarchy_governance ~35KB      futarchy_actions ~30KB
├── Market mechanics          ├── Proposals                  ├── All dispatchers
├── AMM logic                 ├── Voting mechanisms          ├── Action handlers
├── Conditional tokens        ├── Resolution logic           ├── Intent processing
├── Spot pools               ├── Commitment proposals       └── Resource requests
├── Oracle interfaces        ├── Optimistic proposals
└── Market state            └── Proposal lifecycle

        futarchy_security ~15KB              futarchy_vault ~20KB
        ├── Security council                 ├── Vault management
        ├── Emergency actions                ├── Treasury operations
        └── Access control                   └── Liquidity management
```

### Dependencies to Break

**Current problematic dependencies:**
1. Markets → FutarchyConfig (need to break this)
2. Markets → Proposal (need to break this)
3. Markets → FeeManager (need to break this)
4. Markets → ProposalFeeManager (need to break this)

**How to break them:**
- Pass config values as parameters instead of reading from FutarchyConfig
- Make markets accept generic proposal IDs instead of Proposal structs
- Move fee logic to governance or core layer
- Use hot potatoes for any necessary cross-package operations

## Implementation Strategy

### 1. Hot Potato Authorization System

```move
// In futarchy_core package
module futarchy_core::auth {
    /// Hot potato that proves authorization for market operations
    public struct MarketAuth has drop {
        dao_id: ID,
        action: vector<u8>,
    }
    
    /// Hot potato for governance operations
    public struct GovernanceAuth has drop {
        dao_id: ID,
        proposal_id: Option<ID>,
    }
    
    /// Hot potato for security council operations
    public struct SecurityAuth has drop {
        dao_id: ID,
        council_member: address,
    }
    
    // Creation functions (only callable by core)
    public(package) fun authorize_market(dao: &DAO, action: vector<u8>): MarketAuth { ... }
    public(package) fun authorize_governance(dao: &DAO, proposal_id: Option<ID>): GovernanceAuth { ... }
    public(package) fun authorize_security(dao: &DAO, ctx: &TxContext): SecurityAuth { ... }
}
```

### 2. Entry Point Pattern

All user-facing functions live in `futarchy_core`:

```move
// Before (in futarchy package)
public entry fun finalize_market(
    state: &mut MarketState,
    winner: u64,
    ctx: &mut TxContext
) {
    market_state::finalize(state, winner);
}

// After (in futarchy_core)
public entry fun finalize_market(
    dao: &mut DAO,
    state: &mut MarketState, 
    winner: u64,
    ctx: &mut TxContext
) {
    let auth = auth::authorize_market(dao, b"finalize");
    futarchy_markets::finalize(auth, state, winner);
}
```

### 3. Package Dependencies

```toml
# futarchy_core/Move.toml
[dependencies]
futarchy_utils = { local = "../futarchy_utils" }

# futarchy_markets/Move.toml
[dependencies]
futarchy_core = { local = "../futarchy_core" }
futarchy_utils = { local = "../futarchy_utils" }

# futarchy_governance/Move.toml  
[dependencies]
futarchy_core = { local = "../futarchy_core" }
futarchy_markets = { local = "../futarchy_markets" }
futarchy_utils = { local = "../futarchy_utils" }

# futarchy_actions/Move.toml
[dependencies]
futarchy_core = { local = "../futarchy_core" }
futarchy_utils = { local = "../futarchy_utils" }

# futarchy_security/Move.toml
[dependencies]
futarchy_core = { local = "../futarchy_core" }
futarchy_utils = { local = "../futarchy_utils" }

# futarchy_vault/Move.toml
[dependencies]
futarchy_core = { local = "../futarchy_core" }
futarchy_utils = { local = "../futarchy_utils" }
```

## Module Distribution

### futarchy_utils (Already Deployed)
**Existing utilities:**
- `math.move` - Math operations
- `fixed_point_roll.move` - Fixed point math
- `weighted_median.move` - Median calculations
- `time_helper.move` - Time utilities
- `futarchy_helpers.move` - Helper functions

**Additional generic data structures to extract:**
- `binary_heap.move` - Generic binary heap from priority_queue
- `priority_queue_generic.move` - Generic priority queue operations
- Any other reusable data structures

### futarchy_core (Entry Package)
- `auth.move` - Hot potato types and creation
- `dao.move` - Core DAO struct and basic operations
- `config.move` - DAO configuration
- `fee.move` - Fee collection and distribution
- `entries/*.move` - All 83 entry functions organized by category
- `version.move` - Version management

### futarchy_markets
**From `/sources/markets/`:**
- `conditional/conditional_amm.move`
- `conditional/conditional_token.move`
- `conditional/coin_escrow.move`
- `conditional/liquidity_initialize.move`
- `conditional/liquidity_interact.move`
- `conditional/swap.move`
- `spot/spot_amm.move`
- `spot/spot_oracle_interface.move`
- `spot/account_spot_pool.move`
- `spot/spot_conditional_router.move`
- `spot/spot_conditional_quoter.move`
- `queue/priority_queue.move`
- `queue/priority_queue_helpers.move`
- `oracle.move`
- `ring_buffer_oracle.move`
- `market_state.move` (security critical - stays here)

### futarchy_governance
**From `/sources/dao/governance/`:**
- `proposal.move`
- `proposal_lifecycle.move`
- `proposal_fee_manager.move`
- `commitment_proposal.move`
- `commitment_actions.move`
- `commitment_dispatcher.move`
- `optimistic_proposal.move`
- `optimistic_dispatcher.move`
- `optimistic_intents.move`
- `oracle_actions.move`
- `protocol_admin_actions.move`
- `protocol_admin_intents.move`

### futarchy_actions
**All dispatcher and action modules:**
- From `/sources/dao/core/`:
  - `action_dispatcher.move`
  - `resource_requests.move`
- From `/sources/dao/` (all `*_dispatcher.move` and `*_actions.move` files):
  - `config/config_actions.move`
  - `config/config_intents.move`
  - `liquidity/liquidity_dispatcher.move`
  - `memo/memo_dispatcher.move`
  - `operating_agreement/operating_agreement_dispatcher.move`
  - `policy/policy_dispatcher.move`
  - `streams/stream_dispatcher.move`
  - `vault/vault_governance_dispatcher.move`
  - Plus all associated action/intent files

### futarchy_security
**From `/sources/dao/security/`:**
- `security_council.move`
- `security_council_actions.move`
- `security_council_intents.move`
- `security_council_dispatcher.move`

### futarchy_vault
**From `/sources/dao/vault/`:**
- `futarchy_vault.move`
- `vault_governance_dispatcher.move`
**From `/sources/dao/liquidity/`:**
- `liquidity_dispatcher.move`
- Related liquidity management files

## Migration Steps

### Phase 1: Preparation
1. Create new package directories
2. Set up Move.toml files with dependencies
3. Create hot potato types in core

### Phase 2: Code Movement
1. Move modules to their designated packages
2. Update import statements
3. Convert `public(package)` to `public` where needed
4. Add hot potato parameters to protected functions

### Phase 3: Entry Point Creation
1. Create entry function wrappers in core
2. Each wrapper creates appropriate hot potato
3. Calls the actual implementation in sub-package

### Phase 4: Testing
1. Build each package individually
2. Verify sizes are under 128KB
3. Test hot potato authorization flow
4. Run existing test suite with modifications

### Phase 5: Deployment
1. Deploy futarchy_utils (already done)
2. Deploy futarchy_core
3. Deploy futarchy_markets
4. Deploy futarchy_governance  
5. Deploy futarchy_actions
6. Deploy futarchy_security
7. Deploy futarchy_vault
8. Update addresses in Move.toml files

## Expected Outcomes

### Benefits
- **Deployable**: All packages under 128KB limit
- **Maintainable**: Clear separation of concerns
- **Auditable**: Smaller, focused packages for review
- **Testable**: Independent testing of each package
- **Secure**: Hot potato pattern ensures authorization

### Costs
- **Complexity**: ~1000 lines of hot potato boilerplate
- **Dependencies**: More complex dependency management
- **Deployment**: 7 packages to deploy and track
- **Upgrades**: Need to coordinate upgrades across packages

## Risk Mitigation

### Security Risks
- **Risk**: Hot potato could be misused if not properly consumed
- **Mitigation**: All hot potatoes have `drop` only, must be consumed immediately

### Complexity Risks
- **Risk**: Circular dependencies between packages
- **Mitigation**: Strict dependency hierarchy, core at top

### Size Risks
- **Risk**: Individual packages still too large
- **Mitigation**: Further split if needed, current estimates have buffer

## Success Metrics
- [ ] All packages build successfully
- [ ] All packages under 128KB when built
- [ ] All tests pass with new structure
- [ ] Successfully deploy to devnet
- [ ] Successfully deploy to testnet
- [ ] Security audit passes on new structure

## Timeline Estimate
- Preparation: 2 hours
- Code movement: 8 hours  
- Entry point creation: 4 hours
- Testing: 6 hours
- Deployment: 2 hours
- **Total: ~22 hours of focused work**

## Notes
- This is the minimum viable split to get under size limits
- Future V3 features will need careful planning to fit
- Consider this structure for all future Sui Move projects
- Document hot potato patterns for team understanding