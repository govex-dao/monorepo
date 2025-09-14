# Move Framework Changes for Assembly Line Architecture

## Executive Summary

The ExecutionContext and placeholder system has been elevated from a "Futarchy-specific feature" to a **core capability of the Account Protocol framework**. This makes the powerful create-then-use pattern available to all protocols building on this framework.

## Core Framework Files Modified

### 1. `/move-framework/packages/protocol/sources/types/executable.move` ✅

#### Added ExecutionContext Struct
```move
/// The temporary "workbench" for passing data between actions in a single transaction.
/// This is embedded directly in the Executable for logical cohesion.
public struct ExecutionContext has store {
    // Maps a temporary u64 placeholder ID to the real ID of a newly created object
    created_objects: Table<u64, ID>,
}
```

#### Enhanced Executable Struct
```move
public struct Executable<Outcome: store> {
    intent: Intent<Outcome>,
    action_idx: u64,
    context: ExecutionContext, // NEW: Embedded context for data passing
}
```

#### Key Changes:
- ✅ `new()` function now takes `&mut TxContext` to create the Table
- ✅ `destroy()` function cleans up the ExecutionContext Table
- ✅ Added `context()` and `context_mut()` accessors
- ✅ Added placeholder methods: `register_placeholder()`, `resolve_placeholder()`, `has_placeholder()`
- ✅ Added `increment_action_idx()` for sequential processing

### 2. `/move-framework/packages/protocol/sources/account.move` ✅

#### Modified create_executable Function
```move
// BEFORE
public fun create_executable<Config, Outcome: store + copy, CW: drop>(
    account: &mut Account<Config>,
    key: String,
    clock: &Clock,
    version_witness: VersionWitness,
    config_witness: CW,
): (Outcome, Executable<Outcome>)

// AFTER
public fun create_executable<Config, Outcome: store + copy, CW: drop>(
    account: &mut Account<Config>,
    key: String,
    clock: &Clock,
    version_witness: VersionWitness,
    config_witness: CW,
    ctx: &mut TxContext, // NEW: Essential for creating ExecutionContext
): (Outcome, Executable<Outcome>)
```

### 3. `/move-framework/packages/protocol/sources/types/intents.move` ✅

#### Added ActionSpec Struct
```move
/// A blueprint for a single action within an intent.
public struct ActionSpec has store, copy, drop {
    action_type: TypeName,      // The type of the action struct
    action_data: vector<u8>,    // The BCS-serialized action struct
}
```

#### Enhanced Intent Struct
```move
public struct Intent<Outcome> has store {
    // ... existing fields ...
    action_specs: vector<ActionSpec>,     // NEW: Structured action specifications
    next_placeholder_id: u64,             // NEW: Counter for unique placeholder IDs
}
```

#### New Methods:
- ✅ `reserve_placeholder_id()` - Get unique placeholder IDs
- ✅ `add_action_spec()` - Add actions with type safety
- ✅ `action_specs()` accessor
- ✅ `action_spec_type()` and `action_spec_data()` helpers

## Why These Changes Matter

### 1. **Universal Pattern**
The create-then-use pattern is not unique to Futarchy. Any protocol on this framework can now:
- Create an object in one action
- Use that object in subsequent actions
- All within a single atomic transaction

### 2. **Clean Architecture**
- ExecutionContext lifecycle perfectly aligns with Executable
- Single hot potato instead of bundles or wrappers
- All functionality in one logical place

### 3. **Type Safety**
- ActionSpec with TypeName ensures compile-time type checking
- BCS serialization maintains type information
- No string-based routing

## Migration Checklist for Framework Users

### ✅ Completed Framework Changes
- [x] ExecutionContext added to executable.move
- [x] Executable struct enhanced with context field
- [x] create_executable signature updated
- [x] ActionSpec added to intents.move
- [x] Intent struct enhanced with action_specs
- [x] All placeholder methods implemented

### 🔄 Required Updates in Your Code

#### 1. Update create_executable Calls
```move
// OLD
let (outcome, executable) = account::create_executable(
    account, key, clock, version, witness
);

// NEW - Must pass TxContext
let (outcome, executable) = account::create_executable(
    account, key, clock, version, witness, ctx
);
```

#### 2. Update Action Structs (if using placeholders)
```move
// For actions that CREATE objects
public struct CreateSomethingAction has store, drop, copy {
    // ... existing fields ...
    placeholder_out: Option<u64>, // NEW: Where to write the ID
}

// For actions that USE objects
public struct UseSomethingAction has store, drop, copy {
    placeholder_in: Option<u64>,  // NEW: Where to read the ID from
    direct_id: Option<ID>,        // Alternative for backward compat
}
```

#### 3. Update Handlers
```move
// For CREATE actions
public fun do_create_something(
    context: &mut ExecutionContext, // From executable::context_mut()
    params: CreateSomethingAction,
    // ... other params ...
) {
    let new_obj = create_something();
    let obj_id = object::id(&new_obj);

    if (params.placeholder_out.is_some()) {
        executable::register_placeholder(
            context,
            *params.placeholder_out.borrow(),
            obj_id
        );
    }
}

// For USE actions
public fun do_use_something(
    context: &ExecutionContext, // From executable::context()
    params: UseSomethingAction,
    // ... other params ...
) {
    let obj_id = if (params.placeholder_in.is_some()) {
        executable::resolve_placeholder(
            context,
            *params.placeholder_in.borrow()
        )
    } else {
        *params.direct_id.borrow()
    };
    // Use obj_id...
}
```

#### 4. Update Intent Building
```move
// OLD
dao.build_intent!(params, outcome, ..., |intent, iw| {
    intents::add_action(intent, action, descriptor, iw);
});

// NEW
dao.build_intent!(params, outcome, ..., |intent, iw| {
    // Reserve placeholders
    let obj_placeholder = intents::reserve_placeholder_id(intent);

    // Add actions with placeholders
    intents::add_action_spec(
        intent,
        CreateSomethingAction { ..., placeholder_out: option::some(obj_placeholder) },
        action_types::CreateSomething {},
        iw
    );

    intents::add_action_spec(
        intent,
        UseSomethingAction { placeholder_in: option::some(obj_placeholder), ... },
        action_types::UseSomething {},
        iw
    );
});
```

## Import Reference

### ❌ OLD Imports (Remove These)
```move
use account_protocol::execution_context::{Self, ExecutionContext};
use futarchy_dao::execution_bundle::{Self, ExecutionBundle};
use some_package::action_dispatcher_v2;
```

### ✅ NEW Imports (Use These)
```move
use account_protocol::executable::{Self, Executable, ExecutionContext};
use account_protocol::intents::{Self, ActionSpec};
```

## PTB Composition Pattern

### Client-Side TypeScript
```typescript
const tx = new TransactionBlock();

// 1. Start execution - creates Executable with embedded ExecutionContext
const executable = tx.moveCall({
    target: `${pkg}::execute_ptb::execute_proposal_start`,
    arguments: [account, proposal, clock],
});

// 2. Chain category dispatchers (each processes its actions sequentially)
tx.moveCall({
    target: `${pkg}::config_dispatcher::execute_config_actions`,
    arguments: [executable, account],
});

tx.moveCall({
    target: `${pkg}::council_dispatcher::execute_council_actions`,
    arguments: [executable, account, extensions, clock],
});

// 3. End execution - destroys Executable and cleans up ExecutionContext
tx.moveCall({
    target: `${pkg}::execute_ptb::execute_proposal_end`,
    arguments: [account, executable],
});
```

## Benefits of Framework-Level Integration

1. **Atomic Composition**: Complex multi-step operations in single transaction
2. **Universal Availability**: Any protocol can use placeholders
3. **Clean Hot Potato**: Single Executable, no wrappers needed
4. **Logical Cohesion**: Context lifecycle tied to Executable
5. **Type Safety**: Compile-time checking with TypeName
6. **Efficient Processing**: Sequential cursor-based execution

## Common Patterns

### Pattern 1: Create and Configure
```move
let obj_id = reserve_placeholder_id(intent);
add_action_spec(intent, Create { placeholder_out: obj_id });
add_action_spec(intent, Configure { placeholder_in: obj_id });
```

### Pattern 2: Create Multiple, Use Together
```move
let obj1 = reserve_placeholder_id(intent);
let obj2 = reserve_placeholder_id(intent);
add_action_spec(intent, Create { placeholder_out: obj1 });
add_action_spec(intent, Create { placeholder_out: obj2 });
add_action_spec(intent, Combine { input1: obj1, input2: obj2 });
```

## Troubleshooting

### Error: "cannot borrow as mutable"
- Use `executable::context_mut()` for write operations
- Use `executable::context()` for read-only operations

### Error: "placeholder not found"
- Ensure CREATE action executes before USE action
- Verify placeholder IDs match
- Check that register_placeholder was called

### Error: "table not empty"
- All placeholders must be consumed or cleaned up
- Check that all registered IDs are being used

## Summary

The Move framework now natively supports the assembly line pattern through:
- **ExecutionContext** embedded in Executable
- **Placeholder system** for passing data between actions
- **ActionSpec** for type-safe action routing
- **Sequential processing** with action_idx cursor

This is a foundational enhancement that makes the framework more powerful for all users, not just Futarchy.