# Implementation Plan: Move Framework Improvements

## Overview
This plan details the implementation of two critical improvements to the Move framework fork:
1. **Replace ExecutionContext with Pure Hot Potato Chain** - Eliminate storage costs and coupling
2. **Replace Drop Ability with Explicit Destruction Functions** - Restore Move's resource safety

These changes will improve the system's rating from 7/10 to 9/10 while maintaining type safety and eliminating potential footguns.

---

## 📋 Implementation Task List

### Phase 1: Design hot potato result types for all actions
### Phase 2: Remove ExecutionContext from Executable struct
### Phase 3: Update all action modules to return result types
### Phase 4: Remove drop ability from all action structs
### Phase 5: Add explicit destruction functions for each action
### Phase 6: Update Intent and Executable destruction flow
### Phase 7: Update tests for new patterns
### Phase 8: Update documentation and examples

---

## Part 1: Pure Hot Potato Chain Implementation

### 🎯 **Goal**
Replace the storage-based ExecutionContext with zero-cost hot potato result chaining, eliminating Table operations and enforcing compile-time type safety for data flow between actions.

### 📚 **Context**
Currently, ExecutionContext uses an expensive Table to store object IDs that actions can reference. This adds ~200 gas per operation and creates coupling between actions. The hot potato pattern passes data through the stack with zero storage cost.

### 🏗️ **Architecture**

```move
// OLD: Storage-based context
public struct ExecutionContext has store {
    created_objects: Table<u64, ID>,  // Expensive storage
}

// NEW: Hot potato results
public struct ActionResult<phantom T> {
    object_id: ID,
    // No abilities - must be consumed
}
```

---

## 📝 **Detailed Implementation Steps**

### **Phase 1: Design Hot Potato Result Types**

#### 1.1 Create `action_results.move` module
**File**: `/contracts/move-framework/packages/protocol/sources/types/action_results.move`

```move
// ============================================================================
// FORK MODIFICATION NOTICE - Hot Potato Action Results
// ============================================================================
// Zero-cost result passing between actions using hot potato pattern.
//
// PURPOSE:
// - Replace ExecutionContext with compile-time safe result chaining
// - Eliminate Table storage costs (~200 gas per operation)
// - Enforce explicit data dependencies between actions
// ============================================================================

module account_protocol::action_results;

use sui::object::ID;

// Generic result wrapper for any action that creates objects
public struct ActionResult<phantom T> {
    object_id: ID,
    // Additional fields can be added per action type
}

// Specific result types for common patterns
public struct TransferResult {
    transferred_id: ID,
    recipient: address,
}

public struct MintResult {
    coin_id: ID,
    amount: u64,
}

public struct CreateStreamResult {
    stream_id: ID,
    beneficiary: address,
}

public struct CreateProposalResult {
    proposal_id: ID,
    proposal_number: u64,
}

// Result chain for complex multi-step operations
public struct ResultChain {
    // Can hold multiple results in sequence
    results: vector<ID>,
}

// Constructor functions
public fun new_action_result<T>(object_id: ID): ActionResult<T> {
    ActionResult { object_id }
}

public fun new_transfer_result(id: ID, recipient: address): TransferResult {
    TransferResult { transferred_id: id, recipient }
}

// Destructor functions to extract data
public fun destroy_action_result<T>(result: ActionResult<T>): ID {
    let ActionResult { object_id } = result;
    object_id
}

public fun destroy_transfer_result(result: TransferResult): (ID, address) {
    let TransferResult { transferred_id, recipient } = result;
    (transferred_id, recipient)
}
```

### **Phase 2: Remove ExecutionContext from Executable**

#### 2.1 Update `executable.move`
**File**: `/contracts/move-framework/packages/protocol/sources/types/executable.move`

```move
// REMOVE these parts:
// - ExecutionContext struct
// - max_placeholders() function
// - All placeholder management functions (add/get/remove_placeholder)

// OLD struct (remove this)
public struct Executable<phantom Outcome> {
    intent: Intent<Outcome>,
    action_idx: u64,
    ctx: ExecutionContext,  // REMOVE THIS
}

// NEW struct
public struct Executable<phantom Outcome> {
    intent: Intent<Outcome>,
    action_idx: u64,
    // No context - data passes through hot potatoes
}

// Update constructor
public(package) fun new<Outcome: store>(
    intent: Intent<Outcome>,
): Executable<Outcome> {
    Executable {
        intent,
        action_idx: 0,
        // No context initialization
    }
}
```

### **Phase 3: Update Action Modules**

#### 3.1 Example: Update `vault.move` SpendAction
**File**: `/contracts/move-framework/packages/actions/sources/lib/vault.move`

```move
// OLD: Action execution with ExecutionContext
public fun do_spend<Config, Outcome: store, CoinType, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<Config>,
    version: VersionWitness,
    witness: IW,
    ctx: &mut TxContext,
): Coin<CoinType> {
    // ... existing logic ...
}

// NEW: Action execution returns result
public fun do_spend<Config, Outcome: store, CoinType, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<Config>,
    version: VersionWitness,
    witness: IW,
    ctx: &mut TxContext,
): (Coin<CoinType>, SpendResult) {  // Returns both coin and result
    // ... existing logic ...
    let coin = vault.spend<CoinType>(amount, version, ctx);
    let result = SpendResult {
        coin_id: object::id(&coin),
        amount: coin::value(&coin),
        vault_name: name.clone(),
    };
    (coin, result)
}

// Add result type
public struct SpendResult {
    coin_id: ID,
    amount: u64,
    vault_name: String,
}
```

#### 3.2 Update chained actions to accept results
**File**: `/contracts/move-framework/packages/actions/sources/lib/transfer.move`

```move
// OLD: No connection to previous actions
public fun do_transfer<T: key + store>(
    recipients: vector<address>,
    objects: vector<T>,
) {
    // ... transfer logic ...
}

// NEW: Can accept result from previous action
public fun do_transfer_from_spend<T: key + store>(
    spend_result: SpendResult,  // Consume the result
    recipients: vector<address>,
    objects: vector<T>,
) {
    // Can use spend_result data if needed
    let (coin_id, amount, vault_name) = destroy_spend_result(spend_result);

    // ... transfer logic ...
}
```

---

## Part 2: Explicit Destruction Functions Implementation

### 🎯 **Goal**
Remove the `drop` ability from all action structs and require explicit destruction, restoring Move's resource safety guarantees and preventing silent action loss.

### 📚 **Context**
Currently, actions have `drop` ability which allows them to be silently discarded. This could hide bugs where actions are created but never executed. Explicit destruction forces developers to handle every action's lifecycle.

### **Phase 4: Remove Drop Ability**

#### 4.1 Update all action struct definitions
**Example in `vault.move`**:

```move
// OLD: Has drop ability
public struct SpendAction has store, drop {
    vault_name: String,
    amount: u64,
}

// NEW: No drop ability
public struct SpendAction has store {
    vault_name: String,
    amount: u64,
}
```

Apply this to ALL action structs in:
- `/contracts/move-framework/packages/actions/sources/lib/vault.move`
- `/contracts/move-framework/packages/actions/sources/lib/currency.move`
- `/contracts/move-framework/packages/actions/sources/lib/transfer.move`
- `/contracts/move-framework/packages/actions/sources/lib/vesting.move`
- `/contracts/move-framework/packages/actions/sources/lib/kiosk.move`
- `/contracts/move-framework/packages/actions/sources/lib/access_control.move`
- `/contracts/move-framework/packages/protocol/sources/actions/owned.move`
- `/contracts/move-framework/packages/protocol/sources/actions/config.move`

### **Phase 5: Add Explicit Destruction Functions**

#### 5.1 Add destruction function for each action
**Template pattern for each action module**:

```move
// Add to each action module (e.g., vault.move)

// ============== DESTRUCTION FUNCTIONS ==============

/// Destroy a SpendAction after successful execution
public fun destroy_spend_action(
    action: SpendAction,
    result: &SpendResult,  // Proof of execution
) {
    // Validate the action was properly executed
    assert!(result.amount > 0, EActionNotExecuted);

    // Explicit destruction
    let SpendAction { vault_name: _, amount: _ } = action;

    // Could emit event here for tracking
}

/// Destroy a SpendAction that failed or was cancelled
public fun destroy_spend_action_cancelled(
    action: SpendAction,
    reason: String,
) {
    // Log cancellation reason if needed
    let SpendAction { vault_name: _, amount: _ } = action;

    // Could emit cancellation event
}

// Error codes
const EActionNotExecuted: u64 = 1001;
```

### **Phase 6: Update Intent and Executable Destruction Flow**

#### 6.1 Modify the `Expired` struct and cleanup flow
**File**: `/contracts/move-framework/packages/protocol/sources/types/intents.move`

```move
// The Expired struct now tracks which actions were executed
public struct Expired<phantom Outcome> {
    action_specs: vector<ActionSpec>,
    executed_actions: vector<bool>,  // NEW: Track execution status
    outcome: Outcome,
    intent_id: ID,
}

// Update cleanup functions to require destruction proof
public fun cleanup_expired<Outcome: drop>(
    expired: Expired<Outcome>,
    destruction_proofs: vector<DestructionProof>,
) {
    let Expired {
        action_specs,
        executed_actions,
        outcome: _,
        intent_id: _
    } = expired;

    // Verify all actions have destruction proofs
    assert!(
        vector::length(&destruction_proofs) == vector::length(&action_specs),
        EIncompleteCleanup
    );

    // Process each destruction proof
    let i = 0;
    while (i < vector::length(&destruction_proofs)) {
        let proof = vector::pop_back(&mut destruction_proofs);
        let executed = *vector::borrow(&executed_actions, i);
        validate_destruction_proof(proof, executed);
        i = i + 1;
    };
}

public struct DestructionProof has drop {
    action_type: TypeName,
    destroyed: bool,
    execution_result: Option<ID>,
}
```

---

## 🔄 **Migration Strategy**

### **Phase 7: Update Tests**

#### 7.1 Test Template for New Pattern
```move
#[test]
fun test_hot_potato_chain() {
    // Create first action
    let spend_action = new_spend_action("vault", 100);

    // Execute and get result
    let (coin, spend_result) = do_spend(
        &mut executable,
        &mut account,
        version_witness,
        witness,
        ctx
    );

    // Chain to next action
    let transfer_action = new_transfer_action(recipient);
    do_transfer_from_spend(
        spend_result,  // Consume the result
        vector[recipient],
        vector[coin]
    );

    // Explicit cleanup required
    destroy_spend_action(spend_action, &spend_result);
    destroy_transfer_action(transfer_action);
}
```

### **Phase 8: Documentation Updates**

#### 8.1 Update README.md with new patterns
```markdown
## Action Execution Pattern

### Hot Potato Result Chaining
Actions that create objects return typed results that must be consumed:

```move
// Execute first action
let (coin, spend_result) = vault::do_spend(...);

// Pass result to next action
transfer::do_transfer_from_spend(spend_result, ...);
```

### Explicit Action Destruction
All actions must be explicitly destroyed after execution:

```move
// After successful execution
vault::destroy_spend_action(action, &result);

// After cancellation
vault::destroy_spend_action_cancelled(action, reason);
```
```

---

## 📊 **Impact Analysis**

### **Performance Improvements**
- **Remove ~200 gas per ExecutionContext operation**
- **Eliminate Table storage costs**
- **Reduce memory allocation**

### **Safety Improvements**
- **Compile-time guarantee that results are consumed**
- **No silent action dropping**
- **Explicit lifecycle management**

### **Developer Experience**
- **Clearer data flow between actions**
- **Better IDE support with typed results**
- **Easier to debug action execution**

---

## 🚧 **Potential Challenges & Solutions**

### Challenge 1: Complex PTB Construction
**Problem**: Hot potato chaining requires careful PTB construction
**Solution**: Provide helper functions in SDK:
```typescript
// SDK helper
function chainActions(txb: TransactionBlock, actions: Action[]) {
    let lastResult = null;
    for (const action of actions) {
        lastResult = txb.moveCall({
            target: action.target,
            arguments: lastResult ? [lastResult, ...action.args] : action.args
        });
    }
    return lastResult;
}
```

### Challenge 2: Breaking Changes
**Problem**: Existing code won't compile
**Solution**: Migration guide with:
1. Automated script to remove `drop` from structs
2. Template destruction functions
3. Clear upgrade path

### Challenge 3: Action Ordering Dependencies
**Problem**: Some actions might not have clear dependencies
**Solution**: Optional result pattern:
```move
public fun do_action(
    previous: Option<ActionResult<T>>,  // Optional chaining
    ...
)
```

---

## 🎯 **Success Criteria**

1. ✅ All ExecutionContext code removed
2. ✅ All actions return typed results
3. ✅ No action structs have `drop` ability
4. ✅ Every action has destruction functions
5. ✅ All tests pass with new patterns
6. ✅ Gas costs reduced by >30% for multi-action intents
7. ✅ Zero silent action drops possible

---

## 📅 **Estimated Timeline**

- **Phase 1-2**: 2 days - Design and remove ExecutionContext
- **Phase 3**: 3 days - Update all action modules
- **Phase 4-5**: 2 days - Remove drop and add destruction
- **Phase 6**: 1 day - Update cleanup flow
- **Phase 7-8**: 2 days - Tests and documentation

**Total: ~10 days for complete implementation**

---

## 🔗 **References**

- [Move Book - Hot Potato Pattern](https://move-book.com/advanced-topics/hot-potato-pattern.html)
- [Sui Docs - Resource Safety](https://docs.sui.io/concepts/sui-move-concepts/patterns#hot-potato)
- Original ExecutionContext implementation: `/contracts/move-framework/packages/protocol/sources/types/executable.move`

---

## 📝 **Implementation Checklist**

### Files to Modify

#### Protocol Package
- [ ] `/packages/protocol/sources/types/action_results.move` - NEW FILE
- [ ] `/packages/protocol/sources/types/executable.move` - Remove ExecutionContext
- [ ] `/packages/protocol/sources/types/intents.move` - Update Expired struct
- [ ] `/packages/protocol/sources/actions/owned.move` - Remove drop, add destruction
- [ ] `/packages/protocol/sources/actions/config.move` - Remove drop, add destruction

#### Actions Package
- [ ] `/packages/actions/sources/lib/vault.move` - Remove drop, add results
- [ ] `/packages/actions/sources/lib/currency.move` - Remove drop, add results
- [ ] `/packages/actions/sources/lib/transfer.move` - Remove drop, add results
- [ ] `/packages/actions/sources/lib/vesting.move` - Remove drop, add results
- [ ] `/packages/actions/sources/lib/kiosk.move` - Remove drop, add results
- [ ] `/packages/actions/sources/lib/access_control.move` - Remove drop, add results
- [ ] `/packages/actions/sources/lib/package_upgrade.move` - Remove drop, add results

#### Documentation
- [ ] `/README.md` - Update with new patterns
- [ ] `/examples/` - Update example code
- [ ] `/MIGRATION.md` - NEW FILE for upgrade guide

### Testing Requirements

#### Unit Tests
- [ ] Test hot potato result chaining
- [ ] Test explicit destruction functions
- [ ] Test failure cases (cancelled actions)
- [ ] Test complex multi-action chains

#### Integration Tests
- [ ] Test with existing DAO proposals
- [ ] Test gas cost improvements
- [ ] Test PTB construction patterns
- [ ] Test migration from old to new system

### Review Checklist

- [ ] All actions have destruction functions
- [ ] No action struct has `drop` ability
- [ ] ExecutionContext completely removed
- [ ] All tests pass
- [ ] Documentation updated
- [ ] Migration guide complete
- [ ] Gas benchmarks show improvement

---

## 🚀 **Getting Started**

1. **Create a new branch**: `git checkout -b hot-potato-improvements`
2. **Start with Phase 1**: Create the `action_results.move` module
3. **Test incrementally**: Update one action module at a time
4. **Document as you go**: Update fork notes in each file
5. **Benchmark gas costs**: Compare before and after

This implementation plan provides a complete path to upgrading the system from storage-based context to zero-cost hot potato chaining while maintaining type safety and improving resource management.