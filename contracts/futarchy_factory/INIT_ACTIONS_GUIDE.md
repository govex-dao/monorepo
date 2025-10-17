# Init Actions & Intent Patterns Guide

## Overview

This guide explains ALL intent patterns in the futarchy system and when to use each.

---

## 1. Init Actions (Launchpad DAO Creation)

**Purpose**: Execute actions during DAO creation after fundraise completes

**Location**: `futarchy_factory/sources/factory/init_actions.move`

### Pattern Flow

```
Before Raise:
  User → stage_init_intent() → Stores InitActionSpecs as Intent
                              ↓
                     (Immutable, tamper-proof)

After Raise:
  Frontend → Read InitActionSpecs from chain
           → Construct deterministic PTB
           → Execute PTB with typed init helpers
           → DAO activated with initial state
```

### Functions

**Storage**:
```move
stage_init_intent(
    account: &mut Account<FutarchyConfig>,
    owner_id: &ID,             // Launchpad ID
    staged_index: u64,         // Index in batch (0, 1, 2...)
    spec: &InitActionSpecs,    // Actions to execute
    clock: &Clock,
    ctx: &mut TxContext,
)
```

**Cleanup**:
```move
cancel_init_intent(account, owner_id, index, ctx)
cleanup_init_intents(account, owner_id, specs, ctx)
```

### Execution (PTB)

```typescript
// Read specs from chain
const specs = await client.getObject(daoId);

// Construct PTB
const tx = new Transaction();

// Call init helpers based on specs
if (spec.type === 'VaultDeposit') {
  tx.moveCall({
    target: `${pkg}::init_actions::init_vault_deposit`,
    arguments: [account, coin, vaultName],
    typeArguments: ['0x2::sui::SUI'],
  });
}

if (spec.type === 'VestingCreate') {
  tx.moveCall({
    target: `${pkg}::init_actions::init_create_vesting`,
    arguments: [account, coin, recipient, start, duration, cliff, clock],
    typeArguments: [daoTokenType],
  });
}

// Execute atomically
await tx.execute();
```

### Available Init Helpers

**Location**: `move-framework/packages/actions/sources/init/init_actions.move`

```move
// Vault
init_vault_deposit<Config, CoinType>(account, coin, vault_name, ctx)
init_vault_deposit_default<Config, CoinType>(account, coin, ctx)

// Currency
init_lock_treasury_cap<Config, CoinType>(account, cap)
init_mint<Config, CoinType>(account, amount, recipient, ctx)
init_mint_and_deposit<Config, CoinType>(account, amount, vault_name, ctx)

// Vesting
init_create_vesting<Config, CoinType>(account, coin, recipient, start, duration, cliff, clock, ctx)
init_create_founder_vesting<Config, CoinType>(account, coin, founder, cliff, clock, ctx)
init_create_team_vesting<Config, CoinType>(account, coin, member, duration, cliff, clock, ctx)

// Package Upgrade
init_lock_upgrade_cap<Config>(account, cap, package_name, delay_ms)

// Access Control
init_lock_capability<Config, Cap: key + store>(account, cap)

// Owned Objects
init_store_object<Config, Key, T: key + store>(account, key, object, ctx)

// Transfer
init_transfer_object<T: key + store>(object, recipient)
init_transfer_objects<T: key + store>(objects, recipients)

// Streams
init_create_vault_stream<Config, CoinType>(account, vault, beneficiary, amount, start, end, cliff, ...)
init_create_salary_stream<Config, CoinType>(account, employee, monthly_amount, num_months, clock, ctx)
```

### Why PTB Instead of Generic Executor?

| Aspect | Generic Executor | PTB |
|--------|-----------------|-----|
| Type safety | ❌ Runtime checks | ✅ Compile-time |
| Code complexity | ❌ 450-line dispatcher | ✅ Simple calls |
| Attack surface | ❌ Large dispatcher | ✅ Minimal |
| Object passing | ❌ Need workarounds | ✅ Natural |
| Gas efficiency | ❌ Type dispatch overhead | ✅ Direct calls |
| Atomic execution | ✅ Yes | ✅ Yes |

**PTB is SAFER and SIMPLER.**

---

## 2. Runtime Governance Intents (Proposals)

**Purpose**: Execute approved proposals via prediction market governance

**Location**: `futarchy_governance_actions/sources/governance/governance_intents.move`

### Pattern Flow

```
Create Proposal:
  User → Proposal with IntentSpec for each outcome
       → Prediction market vote
       → Market resolves to winning outcome

Execute Proposal:
  Anyone → execute_proposal_intent()
         → Reads IntentSpec from proposal
         → Creates Intent JIT (just-in-time)
         → Converts to Executable
         → PTB calls do_* functions for each action
         → Cleans up Intent
```

### Functions

**Execution**:
```move
execute_proposal_intent<AssetType, StableType, Outcome>(
    account: &mut Account<FutarchyConfig>,
    proposal: &mut Proposal<AssetType, StableType>,
    market: &MarketState,
    outcome_index: u64,      // Winning outcome index
    outcome: Outcome,
    clock: &Clock,
    ctx: &mut TxContext,
): (Executable<Outcome>, String)  // ✅ Returns both executable and intent key
```

### Intent Creation (for proposals)

**Config Actions**:
```move
// Location: futarchy_actions/sources/config/config_intents.move
create_set_proposals_enabled_intent(account, registry, params, outcome, enabled, ctx)
create_update_name_intent(account, registry, params, outcome, new_name, ctx)
create_update_metadata_intent(account, params, outcome, name, icon, description, ctx)
create_update_trading_params_intent(account, params, outcome, review_ms, trading_ms, ...)
create_update_governance_intent(account, params, outcome, enabled, max_outcomes, ...)
// ... many more
```

**Vault Actions**:
```move
// Location: account_actions/sources/lib/vault.move
new_deposit<Config, Outcome, CoinType, IW>(intent, account, vault_name, amount, witness)
new_spend<Config, Outcome, CoinType, IW>(intent, account, vault_name, amount, recipient, witness)
new_spend_and_transfer<Config, Outcome, CoinType, IW>(...)
```

**Vesting Actions**:
```move
// Location: account_actions/sources/lib/vesting.move
new_vesting<Config, Outcome, CoinType, IW>(intent, account, recipients, amounts, start, end, ...)
new_cancel_vesting<Outcome, IW>(intent, vesting_id, witness)
new_toggle_vesting_pause<Outcome, IW>(intent, vesting_id, pause_duration_ms, witness)
```

### Execution (PTB)

```typescript
// Get executable and intent key from proposal
const tx = new Transaction();

// ✅ Capture both return values
const [executable, intentKey] = tx.moveCall({
  target: `${pkg}::governance_intents::execute_proposal_intent`,
  arguments: [account, proposal, market, outcomeIndex, outcome, clock],
  typeArguments: [assetType, stableType],
});

// Execute each action
tx.moveCall({
  target: `${pkg}::config_actions::do_set_proposals_enabled`,
  arguments: [executable, account, version, witness, clock],
});

tx.moveCall({
  target: `${pkg}::vault::do_spend_and_transfer`,
  arguments: [executable, account, version, witness, clock],
  typeArguments: ['0x2::sui::SUI'],
});

// Confirm execution
tx.moveCall({
  target: `${pkg}::account::confirm_execution`,
  arguments: [account, executable],
});

// ✅ Cleanup using the returned intent key (no event parsing needed!)
tx.moveCall({
  target: `${pkg}::account::destroy_empty_intent`,
  arguments: [account, intentKey],
});

await tx.execute();
```

---

## 2.1. Deep Dive: Proposal Intent Lifecycle

### Architecture Components

The proposal intent system uses **Just-In-Time (JIT) Intent Creation** to minimize storage and maximize security:

1. **IntentSpec Storage** (at proposal creation time)
2. **Winning Outcome Selection** (market finalization)
3. **JIT Intent Creation** (execution time)
4. **PTB Execution** (user-driven)

---

### Step 1: Intent Spec Creation

**Location**: `futarchy_actions/sources/config/config_intents.move`

When users create proposals, they build `InitActionSpecs` blueprints using the `build_intent!` macro:

```move
// Example: Set Proposals Enabled action
account.build_intent!(
    params,
    outcome,
    b"config_set_proposals_enabled".to_string(),
    version::current(),
    ConfigIntent {},
    ctx,
    |intent, iw| {
        let action = config_actions::new_set_proposals_enabled_action(enabled);
        let action_bytes = bcs::to_bytes(&action);
        intent.add_typed_action(
            action_type_markers::set_proposals_enabled(),
            action_bytes,
            iw,
        );
    },
);
```

**What gets stored**:
```move
public struct ActionSpec has store, copy, drop {
    version: u8,                // Version byte (forward compatibility)
    action_type: TypeName,      // Type of the action struct
    action_data: vector<u8>,    // BCS-serialized action data
}
```

**Key Features**:
- **Type-safe**: `TypeName` ensures correct action routing
- **Bounded**: Max 4KB per action (`max_action_data_size()`)
- **Versioned**: Forward compatibility for upgrades
- **BCS-encoded**: Standard serialization format

---

### Step 2: Storage in Proposal

**Location**: `futarchy_markets_core/sources/proposal.move`

Intent specs are stored **per outcome** in the `Proposal` struct:

```move
public struct OutcomeData has store {
    outcome_count: u64,
    outcome_messages: vector<String>,
    outcome_creators: vector<address>,
    outcome_creator_fees: vector<u64>,
    intent_specs: vector<Option<InitActionSpecs>>,  // ✅ One per outcome
    actions_per_outcome: vector<u64>,
    winning_outcome: Option<u64>,
}

public struct Proposal<phantom AssetType, phantom StableType> has key, store {
    id: UID,
    // ... other fields ...
    outcome_data: OutcomeData,
    // ... more fields ...
}
```

**Management Functions**:
```move
// Store spec for an outcome
set_intent_spec_for_outcome(proposal, outcome_index, intent_spec, max_actions)

// Read spec for an outcome
get_intent_spec_for_outcome(proposal, outcome_index): &Option<InitActionSpecs>

// Extract spec (clears the slot)
take_intent_spec_for_outcome(proposal, outcome_index): Option<InitActionSpecs>

// Remove spec
clear_intent_spec_for_outcome(proposal, outcome_index)
```

**Example**: A 2-outcome proposal (YES/NO) stores:
- `intent_specs[0]`: Actions to execute if YES wins
- `intent_specs[1]`: Actions to execute if NO wins (typically empty)

---

### Step 3: Finalization & Cleanup

**Location**: `futarchy_governance/sources/proposal/proposal_lifecycle.move`

When a proposal market finalizes, **losing outcome intents are automatically cleaned up**:

```move
public fun finalize_proposal_market<AssetType, StableType>(
    account: &mut Account<FutarchyConfig>,
    proposal: &mut Proposal<AssetType, StableType>,
    escrow: &mut coin_escrow::TokenEscrow<AssetType, StableType>,
    market_state: &mut MarketState,
    spot_pool: &mut UnifiedSpotPool<AssetType, StableType>,
    fee_manager: &mut ProposalFeeManager,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // 1. Calculate winning outcome from TWAP
    let (winning_outcome, twap_prices) = calculate_winning_outcome_with_twaps(
        proposal, escrow, clock
    );

    // 2. Store final TWAPs
    proposal::set_twap_prices(proposal, twap_prices);
    proposal::set_winning_outcome(proposal, winning_outcome);

    // 3. Finalize market state
    market_state::finalize(market_state, winning_outcome, clock);

    // 4. **CRITICAL**: Cancel losing outcome intents
    let num_outcomes = proposal::get_num_outcomes(proposal);
    let mut i = 0u64;
    while (i < num_outcomes) {
        if (i != winning_outcome) {
            // Create scoped cancel witness (prevents cross-proposal attacks)
            let mut cw_opt = proposal::make_cancel_witness(proposal, i);
            if (option::is_some(&cw_opt)) {
                let _cw = option::extract(&mut cw_opt);
                // make_cancel_witness() removes the spec and resets action count
            };
            option::destroy_none(cw_opt);
        };
        i = i + 1;
    };

    // ... handle liquidity, fees, etc ...
}
```

**Security Feature**: `make_cancel_witness()` creates a **scoped witness** that:
- Proves ownership of a specific `(proposal, outcome)` pair
- Prevents canceling intents from other proposals
- Can only be created once per outcome

**Result**: Only the winning outcome's intent spec survives finalization.

---

### Step 4: JIT Intent Creation & Execution

**Location**: `futarchy_governance_actions/sources/governance/governance_intents.move`

When executing an approved proposal, the system uses the **Just-In-Time (JIT) pattern**:

```move
public fun execute_proposal_intent<AssetType, StableType, Outcome>(
    account: &mut Account<FutarchyConfig>,
    proposal: &mut Proposal<AssetType, StableType>,
    _market: &MarketState,
    outcome_index: u64,      // Winning outcome
    outcome: Outcome,
    clock: &Clock,
    ctx: &mut TxContext
): (Executable<Outcome>, String) {  // ✅ Returns both executable and intent key
    // 1. Extract intent spec from proposal (clears the slot)
    let mut intent_spec_opt = proposal::take_intent_spec_for_outcome(
        proposal,
        outcome_index
    );

    assert!(option::is_some(&intent_spec_opt), 4); // EIntentNotFound
    let intent_spec = option::extract(&mut intent_spec_opt);
    option::destroy_none(intent_spec_opt);

    // 2. Create and store Intent JIT
    let intent_key = create_and_store_intent_from_spec(
        account,
        intent_spec,
        outcome,
        clock,
        ctx
    );

    // 3. Immediately convert to Executable
    let (_outcome, executable) = account::create_executable(
        account,
        intent_key,
        clock,
        version::current(),
        GovernanceWitness{},
        ctx,
    );

    (executable, intent_key)  // ✅ Return both for PTB execution
}
```

**Helper: JIT Intent Creation**:
```move
public fun create_and_store_intent_from_spec<Outcome>(
    account: &mut Account<FutarchyConfig>,
    spec: InitActionSpecs,
    outcome: Outcome,
    clock: &Clock,
    ctx: &mut TxContext
): String {
    // 1. Generate guaranteed-unique key using Sui's native ID generation
    // This ensures uniqueness even when multiple proposals execute in the same block
    let intent_key = ctx.fresh_object_address().to_string();

    // 2. Create intent params with immediate execution
    let params = intents::new_params(
        intent_key,
        b"Just-in-time Proposal Execution".to_string(),
        vector[clock.timestamp_ms()],  // Execute NOW
        clock.timestamp_ms() + 3_600_000,  // 1 hour expiry
        clock,
        ctx
    );

    // 3. Create intent
    let mut intent = account::create_intent(
        account,
        params,
        outcome,
        b"ProposalExecution".to_string(),
        version::current(),
        witness(),
        ctx
    );

    // 4. Add all actions from spec
    let actions = init_action_specs::actions(&spec);
    let mut i = 0;
    let len = vector::length(actions);
    while (i < len) {
        let action = vector::borrow(actions, i);
        intents::add_action_spec(
            &mut intent,
            witness(),
            *init_action_specs::action_data(action),
            witness()
        );
        i = i + 1;
    };

    // 5. Store intent in account
    account::insert_intent(account, intent, version::current(), witness());

    intent_key
}
```

**Why JIT?**
- **Storage Efficiency**: Only create runtime Intent when needed
- **Security**: No stale intents sitting in storage
- **Simplicity**: Single execution path per proposal

**Why `fresh_object_address()` for Uniqueness?**
- **Guaranteed Unique**: Uses Sui's internal transaction counter, ensuring uniqueness even when multiple proposals execute in the same block
- **No Collisions**: Unlike `timestamp + account_address`, which can collide when the same account executes multiple proposals within a single block
- **Best Practice**: Follows Sui's official pattern for generating unique identifiers

---

### Step 5: PTB Execution Flow

```typescript
// Frontend builds PTB
const tx = new Transaction();

// Step 1: Get executable and intent key from proposal
const [executable, intentKey] = tx.moveCall({
  target: `${pkg}::governance_intents::execute_proposal_intent`,
  arguments: [account, proposal, market, winningOutcomeIndex, outcome, clock],
  typeArguments: [assetType, stableType],
});

// Step 2: Execute each action from the intent
// (Frontend reads action specs to know which do_* functions to call)

// Example: Config update
tx.moveCall({
  target: `${pkg}::config_actions::do_set_proposals_enabled`,
  arguments: [executable, account, version, witness, clock],
});

// Example: Vault transfer
tx.moveCall({
  target: `${pkg}::vault::do_spend_and_transfer`,
  arguments: [executable, account, version, witness, clock],
  typeArguments: ['0x2::sui::SUI'],
});

// Step 3: Confirm execution (destroys executable hot potato)
tx.moveCall({
  target: `${pkg}::account::confirm_execution`,
  arguments: [account, executable],
});

// Step 4: Cleanup JIT intent using the returned key
tx.moveCall({
  target: `${pkg}::account::destroy_empty_intent`,
  arguments: [account, intentKey],  // ✅ Use the returned key directly
});

await tx.execute();
```

**Execution Guarantees**:
- ✅ **Atomic**: All actions succeed or transaction reverts
- ✅ **Type-safe**: Compile-time action type checking
- ✅ **Hot Potato**: `Executable` must be consumed via `confirm_execution()`
- ✅ **Ordered**: Actions execute in the order they appear in the spec
- ✅ **No Event Dependency**: Intent key returned directly, no event parsing required

**Why Return the Intent Key?**

The function returns both `(Executable<Outcome>, String)` for maximum simplicity:

1. **No Event Parsing**: Frontend gets the key directly in the PTB, eliminating dependency on event indexing
2. **Composability**: PTB can use the key for cleanup without extracting it from the hot potato
3. **Debuggability**: Key is visible in transaction explorer and logs
4. **Simplicity**: 2-line change vs. adding wrapper functions
5. **Safety Net**: Janitor still handles forgotten cleanups automatically

Alternative approaches considered:
- ❌ **Event-only tracking**: Requires indexer, adds complexity
- ❌ **Helper wrapper** (`confirm_and_cleanup`): Couples concerns, breaks composability
- ❌ **Accessor functions**: Breaks `Executable` encapsulation

**Defense in Depth: Auto-Cleanup Safety Net**

Even though the key is returned for manual cleanup, the system has **automatic cleanup** as a safety net:

```move
// In ptb_executor.move::finalize_execution()
public entry fun finalize_execution<AssetType, StableType>(
    account: &mut Account<FutarchyConfig>,
    proposal: &mut Proposal<AssetType, StableType>,
    executable: Executable<FutarchyOutcome>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let intent_key = intents::key(account_protocol::executable::intent(&executable));
    account::confirm_execution(account, executable);

    // ✅ Auto-cleanup ALL expired intents (safety net)
    intent_janitor::cleanup_all_expired_intents(account, clock, ctx);

    event::emit(ProposalIntentExecuted { ... });
}
```

**When Janitor Saves You**:
1. Frontend forgets to add `destroy_empty_intent()` call
2. User abandons transaction mid-execution
3. PTB construction bug omits cleanup step
4. Intent key gets lost/corrupted

**How Janitor Works**:
- Tracks all created intents in an `IntentIndex` (vector + table)
- Uses round-robin scanning to find expired intents (gas-efficient)
- Sui's storage rebate incentivizes external cleaners to call it
- Called automatically during `finalize_execution()`

**Result**: Intent cleanup is **both explicit (returned key) AND implicit (janitor)**. You can't trust all callers, so the janitor is your safety net.

---

### Complete Data Flow Diagram

```
┌─────────────────────────────────────────────────────────────────────┐
│ PROPOSAL CREATION                                                   │
└─────────────────────────────────────────────────────────────────────┘
                                   │
        User creates intent spec   │
        via build_intent! macro    │
                                   │
                                   ▼
        ┌───────────────────────────────────────┐
        │ InitActionSpecs (Blueprint)           │
        │                                       │
        │ • action_type: TypeName               │
        │ • action_data: vector<u8> (BCS)       │
        │ • version: u8                         │
        └───────────────────────────────────────┘
                                   │
                Store in proposal  │
                                   ▼
        ┌───────────────────────────────────────┐
        │ Proposal.outcome_data                 │
        │                                       │
        │ intent_specs: [                       │
        │   Some(IntentSpec),  // Outcome 0     │
        │   Some(IntentSpec),  // Outcome 1     │
        │   None,              // Outcome 2     │
        │ ]                                     │
        └───────────────────────────────────────┘
                                   │
                                   │
┌─────────────────────────────────────────────────────────────────────┐
│ MARKET TRADING & FINALIZATION                                       │
└─────────────────────────────────────────────────────────────────────┘
                                   │
         Prediction market vote    │
         Market resolves           │
                                   ▼
        ┌───────────────────────────────────────┐
        │ finalize_proposal_market()            │
        │                                       │
        │ 1. Calculate winning outcome (TWAP)   │
        │ 2. Cancel losing outcome intents      │
        │ 3. Set winning_outcome                │
        └───────────────────────────────────────┘
                                   │
                  Only winner      │
                  survives         ▼
        ┌───────────────────────────────────────┐
        │ intent_specs: [                       │
        │   Some(IntentSpec),  // Winner        │
        │   None,              // Cancelled     │
        │   None,              // Cancelled     │
        │ ]                                     │
        └───────────────────────────────────────┘
                                   │
                                   │
┌─────────────────────────────────────────────────────────────────────┐
│ EXECUTION (JIT PATTERN)                                             │
└─────────────────────────────────────────────────────────────────────┘
                                   │
    User calls execute_proposal_   │
    intent()                       ▼
        ┌───────────────────────────────────────┐
        │ execute_proposal_intent()             │
        │                                       │
        │ 1. take_intent_spec_for_outcome()     │
        │    (removes from proposal)            │
        │                                       │
        │ 2. create_and_store_intent_from_spec()│
        │    → Creates runtime Intent           │
        │    → Generates key: jit_intent_...    │
        │                                       │
        │ 3. create_executable()                │
        │    → Returns Executable hot potato    │
        └───────────────────────────────────────┘
                                   │
                        Returns    │
                        Executable ▼
        ┌───────────────────────────────────────┐
        │ PTB Execution                         │
        │                                       │
        │ tx.moveCall(do_action_1, executable)  │
        │ tx.moveCall(do_action_2, executable)  │
        │ tx.moveCall(confirm_execution, exec)  │
        │ tx.moveCall(destroy_empty_intent)     │
        └───────────────────────────────────────┘
                                   │
                          Done ✓   │
                                   ▼
```

---

### Key Architectural Decisions

#### 1. **Why JIT Intent Creation?**

| Approach | Storage Overhead | Security Risk | Complexity |
|----------|-----------------|---------------|------------|
| **Pre-create all intents** | ❌ High (N outcomes × M actions) | ❌ Stale intents in storage | ❌ Need cleanup logic |
| **JIT creation** (current) | ✅ Low (only winner) | ✅ No stale data | ✅ Simple: create → execute → destroy |

**JIT is optimal**: You only materialize the winning outcome's intent when needed.

#### 2. **Why Scoped Witnesses?**

```move
public struct CancelWitness has drop {
    proposal: address,      // Unique to THIS proposal
    outcome_index: u64,     // Unique to THIS outcome
}
```

**Attack prevented**:
```move
// ❌ WITHOUT scoped witness: Attacker could cancel ANY proposal's intent
cancel_intent(attacker_controlled_key);

// ✅ WITH scoped witness: Can only cancel this specific proposal outcome
let witness = proposal::make_cancel_witness(proposal, outcome_index);
// witness is cryptographically bound to (proposal, outcome_index)
```

#### 3. **Why PTB Instead of Generic Executor?**

**Generic Executor** (old approach):
```move
public fun execute(executable: Executable) {
    while (has_actions(executable)) {
        let action_type = peek_action_type(executable);

        // 450-line type dispatcher 😱
        if (action_type == SET_PROPOSALS_ENABLED) {
            do_set_proposals_enabled(executable, ...);
        } else if (action_type == UPDATE_NAME) {
            do_update_name(executable, ...);
        } else if (action_type == VAULT_TRANSFER) {
            do_vault_transfer(executable, ...);
        }
        // ... 50+ more actions
    }
}
```

**Problems**:
- ❌ Large attack surface (dispatcher logic)
- ❌ Gas overhead (type matching at runtime)
- ❌ Hard to pass typed objects between actions

**PTB** (current approach):
```move
// Frontend builds typed call sequence
tx.moveCall(do_set_proposals_enabled, [executable, ...]);
tx.moveCall(do_vault_transfer, [executable, ...]);
```

**Benefits**:
- ✅ Compile-time type safety
- ✅ Minimal on-chain code
- ✅ Natural object passing
- ✅ Gas efficient

---

### Common Patterns

#### Pattern 1: Simple Config Update

```move
// 1. Create intent spec
account.build_intent!(
    params,
    outcome,
    b"update_name".to_string(),
    version::current(),
    ConfigIntent {},
    ctx,
    |intent, iw| {
        let action = config_actions::new_update_name_action(new_name);
        intent.add_typed_action(
            action_type_markers::update_name(),
            bcs::to_bytes(&action),
            iw,
        );
    },
);

// 2. Proposal wins, execute via PTB
const [exec] = tx.moveCall(execute_proposal_intent, [...]);
tx.moveCall(do_update_name, [exec, account, version, witness, clock]);
tx.moveCall(confirm_execution, [account, exec]);
tx.moveCall(destroy_empty_intent, [account, intentKey]);
```

#### Pattern 2: Multi-Action Governance

```move
// 1. Create multi-action intent spec
account.build_intent!(
    params,
    outcome,
    b"governance_batch".to_string(),
    version::current(),
    ConfigIntent {},
    ctx,
    |intent, iw| {
        // Action 1: Update trading params
        let action1 = config_actions::new_trading_params_update_action(...);
        intent.add_typed_action(
            action_type_markers::update_trading_config(),
            bcs::to_bytes(&action1),
            iw,
        );

        // Action 2: Update TWAP config
        let action2 = config_actions::new_twap_config_update_action(...);
        intent.add_typed_action(
            action_type_markers::update_twap_config(),
            bcs::to_bytes(&action2),
            iw,
        );

        // Action 3: Transfer from vault
        vault::new_spend_and_transfer(
            intent,
            account,
            vault_name,
            amount,
            recipient,
            iw,
        );
    },
);

// 2. Execute all atomically
const [exec] = tx.moveCall(execute_proposal_intent, [...]);
tx.moveCall(do_update_trading_params, [exec, ...]);
tx.moveCall(do_update_twap_config, [exec, ...]);
tx.moveCall(do_spend_and_transfer, [exec, ...], ['0x2::sui::SUI']);
tx.moveCall(confirm_execution, [account, exec]);
tx.moveCall(destroy_empty_intent, [account, intentKey]);
```

---

### Security Guarantees

1. **Intent Isolation**: Each proposal's intents are isolated via scoped witnesses
2. **Atomic Execution**: All actions succeed or entire transaction reverts
3. **Type Safety**: Action types verified at compile time
4. **Bounded Actions**: Max 4KB per action, configurable max actions per outcome
5. **Hot Potato Pattern**: `Executable` must be consumed (can't leak)
6. **JIT Creation**: No stale intents in storage
7. **Automatic Cleanup**: Losing outcomes cleaned up in finalization

---

### Debugging Tips

**Problem**: Intent execution fails with "IntentNotFound"
```
Solution: Check that proposal was finalized and outcome has an intent spec
```

**Problem**: Action execution fails with type mismatch
```
Solution: Ensure PTB calls do_* functions in the order actions were added
```

**Problem**: Can't destroy intent after execution
```
Solution: Verify all actions were executed (use confirm_execution first)
```

**Problem**: Losing outcome intents not cleaned up
```
Solution: Call finalize_proposal_market() which auto-cleans losing intents
```

---

## 3. Resource Patterns

### A. Resource Requests (Hot Potato) ✅

**Purpose**: Actions that RETURN objects to caller

**Location**: `futarchy_core/sources/resource_requests.move`

**When to use**:
- Action creates and returns LP tokens
- Action returns Walrus Blobs (can't serialize)
- Two-phase cross-transaction operations
- Init actions (high-risk = stricter compile-time enforcement)

**Example**:
```move
// Action returns LP tokens
let request = liquidity_actions::do_add_liquidity<...>(executable, account, pool, ...);
let lp_tokens = resource_requests::fulfill_with_coin(request, coin);
// Caller must handle lp_tokens
```

### B. Executable Resources (Bag) ✅

**Purpose**: Provide coins TO actions during runtime intent execution

**Location**: `futarchy_core/sources/executable_resources.move`

**When to use**:
- Runtime intents that need user-provided coins
- Batching actions with external resources
- "Accept coins + LP into AMM" pattern

**Example**:
```move
// Entry function
public entry fun execute_with_coins<AssetType, StableType>(
    account: &mut Account<FutarchyConfig>,
    intent_key: String,
    asset_coin: Coin<AssetType>,
    stable_coin: Coin<StableType>,
    pool: &mut UnifiedSpotPool<AssetType, StableType>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let (_outcome, mut exec) = account::create_executable(...);

    // Provide resources
    let exec_uid = executable::uid_mut_internal(&mut exec);
    resources::provide_coin(exec_uid, b"asset".to_string(), asset_coin, ctx);
    resources::provide_coin(exec_uid, b"stable".to_string(), stable_coin, ctx);

    // Execute actions (they take resources)
    vault::do_deposit<_, _, AssetType, _>(&mut exec, account, ...);
    liquidity_actions::do_add_liquidity<AssetType, StableType, _, _>(&mut exec, ...);

    // Verify all consumed
    resources::destroy_resources(executable::uid_mut_internal(&mut exec));

    account::confirm_execution(account, exec);
}
```

---

## Summary: When to Use What

### Init Actions (DAO Creation)
- ✅ Stage InitActionSpecs before raise
- ✅ Execute via PTB after raise with typed helpers
- ✅ Atomic, type-safe, tamper-proof

### Runtime Proposals (Governance)
- ✅ Create IntentSpec for each outcome
- ✅ Execute winner via PTB calling do_* functions
- ✅ JIT Intent creation → Executable → Actions → Cleanup

### Resource Requests (Hot Potato)
- ✅ Actions that return objects
- ✅ Two-phase operations
- ✅ Compile-time enforcement

### Executable Resources (Bag)
- ✅ User provides coins to runtime intents
- ✅ Actions take what they need
- ✅ Flexible batching

---

## Key Insight: ONE Pattern per Purpose

**You don't have "5 ways to do the same thing."** Each pattern serves a distinct purpose:

1. **Init Actions** = DAO creation bootstrapping
2. **Proposal Intents** = Governance execution
3. **Resource Requests** = Actions returning objects
4. **Executable Resources** = Providing inputs to actions

Each pattern is the OPTIMAL solution for its use case. ✅
