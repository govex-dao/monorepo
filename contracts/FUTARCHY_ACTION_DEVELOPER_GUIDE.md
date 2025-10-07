# Futarchy Action Developer Guide

## Overview
This guide outlines the **exact patterns** developers must follow when creating or modifying actions in the Futarchy system to match the Move Framework's security patterns.

## Critical Security Pattern: Serialize-Then-Destroy

All actions in Futarchy MUST follow the same pattern as Move Framework to prevent type confusion attacks.

## The Complete Action Lifecycle

### 1. Action Type Definition (in `futarchy_core/sources/action_types.move`)

```move
// Define a marker type with drop ability ONLY
public struct MyNewAction has drop {}

// Add to the action types module
public fun my_new_action(): TypeName {
    type_name::with_defining_ids<MyNewAction>()
}
```

### 2. Action Struct Definition (in action module)

```move
// The actual action data struct - must have drop and store
public struct MyActionData has drop, store {
    param1: String,
    param2: u64,
    param3: address,
}
```

### 3. Destruction Function (MANDATORY)

```move
// CRITICAL: Every action MUST have a destruction function
public fun destroy_my_action(action: MyActionData) {
    let MyActionData {
        param1: _,
        param2: _,
        param3: _
    } = action;
}
```

### 4. New Function (Builder Pattern)

```move
// Creates action, serializes it, adds to intent, then destroys
public fun new_my_action<Outcome, IW: drop>(
    intent: &mut Intent<Outcome>,
    param1: String,
    param2: u64,
    param3: address,
    intent_witness: IW,
) {
    // Step 1: Create the action struct
    let action = MyActionData { param1, param2, param3 };

    // Step 2: Serialize to bytes
    let action_data = bcs::to_bytes(&action);

    // Step 3: Add to intent with type marker
    intent.add_typed_action(
        action_types::my_new_action(),  // TypeName marker
        action_data,                    // Pre-serialized bytes
        intent_witness
    );

    // Step 4: CRITICAL - Explicitly destroy the action
    destroy_my_action(action);
}
```

### 5. Do Function (Execution Pattern)

```move
public fun do_my_action<Config, Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<Config>,
    version_witness: VersionWitness,
    _intent_witness: IW,
    clock: &Clock,  // if needed
    ctx: &mut TxContext,
) {
    // Step 1: Verify this is the right account
    executable.intent().assert_is_account(account.addr());

    // Step 2: Get the action spec
    let specs = executable.intent().action_specs();
    let spec = specs.borrow(executable.action_idx());

    // Step 3: CRITICAL - Assert action type BEFORE deserialization
    action_validation::assert_action_type<MyNewAction>(spec);

    // Step 4: Get action data
    let action_data = intents::action_spec_data(spec);

    // Step 5: Check version (if versioned)
    let spec_version = intents::action_spec_version(spec);
    assert!(spec_version == 1, EUnsupportedActionVersion);

    // Step 6: Deserialize with BCS reader
    let mut reader = bcs::new(*action_data);
    let param1 = bcs::peel_vec_u8(&mut reader).to_string();
    let param2 = bcs::peel_u64(&mut reader);
    let param3 = bcs::peel_address(&mut reader);

    // Step 7: Validate all bytes consumed
    bcs_validation::validate_all_bytes_consumed(reader);

    // Step 8: Execute the action logic
    // ... your action implementation ...

    // Step 9: Increment action index
    executable::increment_action_idx(executable);
}
```

### 6. Delete Function (Cleanup)

```move
public fun delete_my_action(expired: &mut Expired) {
    let _spec = intents::remove_action_spec(expired);
    // ActionSpec has drop, automatically cleaned up
}
```

### 7. Decoder Function (for frontend/SDK)

```move
// In decoder module
public fun decode_my_action(action_data: &vector<u8>): String {
    let mut reader = bcs::new(*action_data);
    let param1 = bcs::peel_vec_u8(&mut reader).to_string();
    let param2 = bcs::peel_u64(&mut reader);
    let param3 = bcs::peel_address(&mut reader);

    let mut result = b"MyAction(".to_string();
    result.append(b"param1: ".to_string());
    result.append(param1);
    result.append(b", param2: ".to_string());
    result.append(u64_to_string(param2));
    result.append(b", param3: ".to_string());
    result.append(address::to_string(param3));
    result.append(b")".to_string());

    result
}
```

## Complete Example: ConfigUpdateAction

Let's implement a complete action following all patterns:

### Step 1: Define Type Marker

```move
// In futarchy_core/sources/action_types.move
public struct ConfigUpdate has drop {}

public fun config_update(): TypeName {
    type_name::with_defining_ids<ConfigUpdate>()
}
```

### Step 2: Define Action Module

```move
module futarchy_actions::config_update_action;

use std::string::String;
use sui::bcs::{Self, BCS};
use futarchy_core::action_types;
use account_protocol::{
    action_validation,
    intents::{Self, Intent, Expired},
    executable::{Self, Executable},
    bcs_validation,
};

// Error codes
const EUnsupportedActionVersion: u64 = 1;

// Action data struct
public struct ConfigUpdateData has drop, store {
    setting_name: String,
    new_value: u64,
}

// Destruction function
public fun destroy_config_update(action: ConfigUpdateData) {
    let ConfigUpdateData { setting_name: _, new_value: _ } = action;
}

// Builder function
public fun new_config_update<Outcome, IW: drop>(
    intent: &mut Intent<Outcome>,
    setting_name: String,
    new_value: u64,
    intent_witness: IW,
) {
    let action = ConfigUpdateData { setting_name, new_value };
    let action_data = bcs::to_bytes(&action);

    intent.add_typed_action(
        action_types::config_update(),
        action_data,
        intent_witness
    );

    destroy_config_update(action);
}

// Execution function
public fun do_config_update<Config, Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<Config>,
    version_witness: VersionWitness,
    _intent_witness: IW,
) {
    executable.intent().assert_is_account(account.addr());

    let specs = executable.intent().action_specs();
    let spec = specs.borrow(executable.action_idx());

    // CRITICAL: Type check before deserialization
    action_validation::assert_action_type<action_types::ConfigUpdate>(spec);

    let action_data = intents::action_spec_data(spec);

    let spec_version = intents::action_spec_version(spec);
    assert!(spec_version == 1, EUnsupportedActionVersion);

    let mut reader = bcs::new(*action_data);
    let setting_name = bcs::peel_vec_u8(&mut reader).to_string();
    let new_value = bcs::peel_u64(&mut reader);

    bcs_validation::validate_all_bytes_consumed(reader);

    // Execute the config update
    update_config_setting(account, setting_name, new_value, version_witness);

    executable::increment_action_idx(executable);
}

// Cleanup function
public fun delete_config_update(expired: &mut Expired) {
    let _spec = intents::remove_action_spec(expired);
}
```

## Migration Checklist for Existing Futarchy Actions

For each existing action in Futarchy, verify:

### ✅ Type Safety Checklist

- [ ] **Type marker exists** in `action_types.move` with `has drop` only
- [ ] **Action struct** has `drop, store` abilities
- [ ] **Destruction function** exists and is called after serialization
- [ ] **new_* function** follows serialize-then-destroy pattern
- [ ] **do_* function** calls `action_validation::assert_action_type` BEFORE deserialization
- [ ] **BCS validation** calls `validate_all_bytes_consumed` after deserialization
- [ ] **delete_* function** exists for cleanup
- [ ] **Decoder function** exists for frontend/SDK usage

### ❌ Common Mistakes to Avoid

1. **DON'T** deserialize before type checking
```move
// WRONG - vulnerable to type confusion
let mut reader = bcs::new(*action_data);
let param = bcs::peel_u64(&mut reader);
// Only checking type after deserializing
```

2. **DON'T** forget to destroy action after serialization
```move
// WRONG - resource leak
let action = MyAction { ... };
let data = bcs::to_bytes(&action);
intent.add_typed_action(type, data, witness);
// Missing: destroy_my_action(action);
```

3. **DON'T** use strings for type identification
```move
// WRONG - runtime type errors
if (action_type == b"config_update") { ... }

// RIGHT - compile-time type safety
action_validation::assert_action_type<ConfigUpdate>(spec);
```

4. **DON'T** skip byte consumption validation
```move
// WRONG - may have trailing garbage
let mut reader = bcs::new(*data);
let value = bcs::peel_u64(&mut reader);
// Missing: validate_all_bytes_consumed(reader);
```

## Import Requirements

Every action module MUST import:

```move
use account_protocol::{
    action_validation,           // For type assertions
    intents::{Self, Intent, Expired},
    executable::{Self, Executable},
    bcs_validation,              // For byte validation
    version_witness::VersionWitness,
};
use sui::bcs::{Self, BCS};
use futarchy_core::action_types;    // Or wherever types are defined
```

## Testing Pattern

```move
#[test]
fun test_action_lifecycle() {
    // Test serialization round-trip
    let action = MyActionData { ... };
    let bytes = bcs::to_bytes(&action);

    let mut reader = bcs::new(bytes);
    let decoded_param1 = bcs::peel_vec_u8(&mut reader);
    // ... decode all fields

    // CRITICAL: Always test byte consumption
    bcs_validation::validate_all_bytes_consumed(reader);

    // Test destruction
    destroy_my_action(action);
}

#[test]
#[expected_failure(abort_code = action_validation::EWrongActionType)]
fun test_wrong_action_type() {
    // Test that wrong types are rejected
    // Create spec with WrongAction type but MyAction data
    // Should fail type assertion
}
```

## Hot Potato Pattern (When Needed)

If your action needs external resources (like shared objects), use hot potato:

```move
// Return a ResourceRequest (no abilities - must be consumed)
public fun do_create_proposal<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<Config>,
    version_witness: VersionWitness,
    _intent_witness: IW,
): ResourceRequest<CreateProposalAction> {
    // ... standard validation ...

    // Return request for resources
    ResourceRequest<CreateProposalAction> {
        account_addr: account.addr(),
        // ... request details
    }
}

// Caller must fulfill in same transaction
public fun fulfill_create_proposal(
    request: ResourceRequest<CreateProposalAction>,
    queue: &mut ProposalQueue,  // Shared resource
    // ... other resources
): ResourceReceipt<CreateProposalAction> {
    // Use resources and return receipt
}
```

## Summary: The Golden Rules

1. **ALWAYS** check type before deserialization using `action_validation::assert_action_type`
2. **ALWAYS** destroy action structs after serialization
3. **ALWAYS** validate all BCS bytes are consumed
4. **NEVER** use string-based type checking
5. **NEVER** store action structs - serialize and destroy immediately
6. **ALWAYS** increment action index after successful execution

## Code Review Checklist

Before submitting any action PR:

```
□ Type marker defined with `has drop` only
□ Action struct has `drop, store`
□ Destruction function exists
□ new_* follows serialize-then-destroy
□ do_* has type assertion FIRST
□ BCS validation checks all bytes consumed
□ delete_* function for cleanup
□ Decoder for frontend/SDK
□ Tests cover type safety
□ No deprecated APIs used
□ Imports action_validation module
```

This pattern ensures Futarchy actions are as secure as Move Framework actions and prevents type confusion vulnerabilities.