# Intent Execution Control Implementation Plan
(decided not to do this because of YAGNI principle) only streams need this
## Executive Summary

Implement core execution control primitives in the Intent system to prevent rapid execution attacks, enable admin control, and potentially deprecate the complex streams system with a simpler recurring intent pattern.

## Key Features from Streams Analysis

Your VaultStream implementation has several sophisticated features we should consider:

1. **Multiple beneficiaries** with whitelist (`additional_beneficiaries: vector<address>`)
2. **Pause/resume functionality** with duration tracking
3. **Cancellability control** (`is_cancellable: bool`)
4. **Transfer capability** (`is_transferable: bool`)
5. **Rate limiting** (`max_per_withdrawal`, `min_interval_ms`)
6. **Metadata** for description/notes

## Core Intent Modifications

### Phase 1: Update Intent Struct

**File**: `/contracts/move-framework/packages/protocol/sources/types/intents.move`

```move
public struct Intent<Outcome> has store {
    // === Existing fields ===
    type_: TypeName,
    key: String,
    description: String,
    account: address,
    creator: address,
    creation_time: u64,
    execution_times: vector<u64>,
    expiration_time: u64,
    role: String,
    action_specs: vector<ActionSpec>,
    next_placeholder_id: u64,
    outcome: Outcome,

    // === NEW: Execution Control Fields ===
    // Cooldown between executions (0 = no limit)
    min_interval_ms: u64,

    // Track last execution (0 = never executed)
    last_execution: u64,

    // Total execution limit (0 = unlimited)
    max_executions: u64,

    // Track execution count
    executions_count: u64,

    // === NEW: Admin Control Fields ===
    // Who can cancel/pause (@0x0 = nobody)
    admin: address,

    // Pause until timestamp (0 = not paused)
    paused_until: u64,

    // === NEW: Beneficiary Control (from streams) ===
    // Whitelist of allowed executors (empty = anyone)
    allowed_executors: vector<address>,

    // Whether intent can be transferred to new owner
    is_transferable: bool,

    // Metadata for notes/description
    metadata: Option<String>,
}
```

### Phase 2: Update Params Struct

**File**: `/contracts/move-framework/packages/protocol/sources/types/intents.move`

```move
public struct ParamsFieldsV1 has copy, drop, store {
    key: String,
    description: String,
    creation_time: u64,
    execution_times: vector<u64>,
    expiration_time: u64,

    // === NEW Fields ===
    min_interval_ms: u64,
    max_executions: u64,
    admin: address,
    allowed_executors: vector<address>,
    is_transferable: bool,
    metadata: Option<String>,
}
```

### Phase 3: Core Execution Functions

**File**: `/contracts/move-framework/packages/protocol/sources/types/executable.move`

```move
public(package) fun new<Outcome: store>(
    intent: &mut Intent<Outcome>,
    clock: &Clock,
    ctx: &mut TxContext,
): Executable<Outcome> {
    // NEW: Check if paused
    assert!(clock.timestamp_ms() >= intent.paused_until, EPaused);

    // NEW: Check cooldown
    if (intent.min_interval_ms > 0 && intent.last_execution > 0) {
        assert!(
            clock.timestamp_ms() >= intent.last_execution + intent.min_interval_ms,
            ETooSoonToExecute
        );
    }

    // NEW: Check max executions
    if (intent.max_executions > 0) {
        assert!(
            intent.executions_count < intent.max_executions,
            EMaxExecutionsReached
        );
    }

    // NEW: Check executor whitelist
    if (!intent.allowed_executors.is_empty()) {
        assert!(
            intent.allowed_executors.contains(&tx_context::sender(ctx)),
            ENotAllowedExecutor
        );
    }

    // Check execution time (existing)
    assert!(!intent.execution_times.is_empty(), ENoExecutionTime);
    let next_time = intent.execution_times[0];
    assert!(clock.timestamp_ms() >= next_time, ENotTimeYet);

    // Pop execution time
    intent.execution_times.remove(0);

    // NEW: Update tracking BEFORE creating executable
    intent.last_execution = clock.timestamp_ms();
    intent.executions_count = intent.executions_count + 1;

    Executable {
        intent: *intent,  // Copy intent
        action_idx: 0,
    }
}
```

### Phase 4: Admin Control Functions

**File**: `/contracts/move-framework/packages/protocol/sources/types/intents.move`

```move
/// Admin can cancel an intent
public fun admin_cancel<Outcome: store + drop>(
    intents: &mut Intents,
    key: String,
    ctx: &TxContext,
): Intent<Outcome> {
    let mut intent = intents.inner.remove(key);

    // Check admin permission
    assert!(intent.admin != @0x0, ENotCancellable);
    assert!(intent.admin == tx_context::sender(ctx), ENotAdmin);

    // Clear all future executions
    intent.execution_times = vector::empty();

    intent
}

/// Admin can pause an intent
public fun admin_pause<Outcome: store>(
    intents: &mut Intents,
    key: String,
    pause_until: u64,
    clock: &Clock,
    ctx: &TxContext,
) {
    let intent = intents.inner.borrow_mut<String, Intent<Outcome>>(key);

    // Check admin permission
    assert!(intent.admin != @0x0, EPauseable);
    assert!(intent.admin == tx_context::sender(ctx), ENotAdmin);

    // Set pause
    intent.paused_until = pause_until;
}

/// Admin can transfer intent ownership
public fun admin_transfer<Outcome: store>(
    intents: &mut Intents,
    key: String,
    new_admin: address,
    ctx: &TxContext,
) {
    let intent = intents.inner.borrow_mut<String, Intent<Outcome>>(key);

    // Check permission
    assert!(intent.is_transferable, ENotTransferable);
    assert!(intent.admin == tx_context::sender(ctx), ENotAdmin);

    // Transfer
    intent.admin = new_admin;
}

/// Admin can update executor whitelist
public fun admin_update_executors<Outcome: store>(
    intents: &mut Intents,
    key: String,
    new_executors: vector<address>,
    ctx: &TxContext,
) {
    let intent = intents.inner.borrow_mut<String, Intent<Outcome>>(key);

    // Check admin permission
    assert!(intent.admin == tx_context::sender(ctx), ENotAdmin);

    // Update whitelist
    intent.allowed_executors = new_executors;
}
```

## New Transfer Action for Crank Incentives

**File**: `/contracts/move-framework/packages/actions/sources/lib/transfer.move`

```move
/// Action to transfer to transaction sender (for crank fees)
public struct TransferToSenderAction has store {
    // No recipient field - uses tx_context::sender
}

/// Create transfer to sender action
public fun new_transfer_to_sender<Outcome, IW: drop>(
    intent: &mut Intent<Outcome>,
    intent_witness: IW,
) {
    let action = TransferToSenderAction {};
    let action_data = bcs::to_bytes(&action);

    intent.add_typed_action(
        framework_action_types::transfer_to_sender(),
        action_data,
        intent_witness
    );

    let TransferToSenderAction {} = action;
}

/// Execute transfer to sender
public fun do_transfer_to_sender<Outcome: store, T: key + store, IW: drop>(
    executable: &mut Executable<Outcome>,
    object: T,
    _intent_witness: IW,
    ctx: &mut TxContext,
) {
    // Verify action type
    let specs = executable.intent().action_specs();
    let spec = specs.borrow(executable.action_idx());
    action_validation::assert_action_type<TransferToSender>(spec);

    // Transfer to caller
    transfer::public_transfer(object, tx_context::sender(ctx));
    executable::increment_action_idx(executable);
}
```

## Migration Strategy

### Files to Update

1. **Core Protocol** (Day 1)
   - [ ] `/contracts/move-framework/packages/protocol/sources/types/intents.move`
   - [ ] `/contracts/move-framework/packages/protocol/sources/types/executable.move`
   - [ ] `/contracts/move-framework/packages/protocol/sources/account.move`

2. **Action Libraries** (Day 2)
   - [ ] `/contracts/move-framework/packages/actions/sources/lib/transfer.move`
   - [ ] `/contracts/move-framework/packages/extensions/sources/framework_action_types.move`

3. **Intent Creation Sites** (Day 2-3)
   - [ ] All `new_params()` calls - add new fields
   - [ ] All `new_intent()` calls - pass new params
   - [ ] Test files - update fixtures

4. **Futarchy Specific** (Day 3)
   - [ ] Update proposal creation to set admin
   - [ ] Add crank entry functions
   - [ ] Update governance actions

## Deprecation Analysis: Streams vs Recurring Intents

### What Streams Provide
1. **Complex vesting math** with cliffs and linear release
2. **Multiple beneficiaries** with add/remove
3. **Pause/resume** with duration tracking
4. **Isolated funding pools** vs direct treasury

### What Recurring Intents Can Replace
1. **Simple recurring payments** (salaries, grants)
2. **Scheduled transfers** with fixed amounts
3. **Crank-incentivized operations**

### Recommendation: Keep Both
- **Keep Streams** for complex vesting (employees, investors)
- **Use Recurring Intents** for simple repeated actions (crank ops, recurring transfers)

## Implementation Checklist

### Day 1: Core Changes
- [ ] Update Intent struct with new fields
- [ ] Update Params struct
- [ ] Implement execution checks in executable.move
- [ ] Add error codes

### Day 2: Admin Functions
- [ ] Implement admin_cancel
- [ ] Implement admin_pause
- [ ] Implement admin_transfer
- [ ] Implement admin_update_executors
- [ ] Add TransferToSenderAction

### Day 3: Integration
- [ ] Update all intent creation sites
- [ ] Add helper functions for common patterns
- [ ] Create crank entry functions
- [ ] Update tests

### Day 4: Testing & Documentation
- [ ] Test cooldown enforcement
- [ ] Test admin controls
- [ ] Test executor whitelist
- [ ] Document new fields and functions

## Breaking Changes

Since no backward compatibility needed:

1. **All intent creation will break** - Need to pass new params
2. **Executable creation needs Clock** - Add parameter
3. **New error codes** - Update error handling

## Security Considerations

1. **Default admin to @0x0** - Uncancellable by default
2. **Check cooldown BEFORE creating executable** - Prevent race
3. **Update count atomically** - Prevent double execution
4. **Whitelist empty = permissionless** - Safe default

## Gas Optimization

1. Keep checks simple - No loops in hot path
2. Use Option only where needed - Direct fields cheaper
3. Early exit on common case - Most intents won't have restrictions

## Future Enhancements

1. **Execution rewards** - Track who executed for rewards
2. **Priority fees** - Higher fee for urgent execution
3. **Batch operations** - Admin update multiple intents
4. **Delegation** - Allow admin to delegate specific permissions