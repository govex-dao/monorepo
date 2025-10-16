# Bug 1: Authorization Bypass in Optimistic Intent Cancellation

## Problem

The check `assert!(intent.proposer == sender, ENotProposer)` fails because:
- `do_cancel_optimistic_intent` executes in the **DAO's context** (not council context)
- `tx_context::sender(ctx)` returns the transaction **executor**, not the original proposer
- When a council approves cancellation via multisig, the executor can be anyone

## Solution 1: Remove Proposer Check (IMPLEMENTED ✅)

**Approach**: Remove the broken check entirely. Security is enforced by the council's multisig approval.

**Security Model**:
1. Council member proposes cancellation via `request_cancel_optimistic_intent()`
2. Council multisig approves the cancellation intent
3. Anyone can execute the approved intent (`do_cancel_optimistic_intent`)

**Pros**:
- ✅ Simplest solution
- ✅ Clear security boundary (multisig approval = authorization)
- ✅ Follows standard intent execution pattern
- ✅ No additional storage overhead
- ✅ Consistent with other DAO actions

**Cons**:
- ❌ Cannot restrict execution to original proposer (but this is by design)

**Code**:
```move
// Check intent exists
assert!(table::contains(&storage.intents, action.intent_id), EIntentNotFound);
let intent = table::borrow_mut(&mut storage.intents, action.intent_id);

// SECURITY MODEL: Authorization enforced by council's multisig approval
// (No proposer check needed)

// Check not already cancelled or executed
assert!(!intent.is_cancelled, EIntentAlreadyCancelled);
```

---

## Solution 2: Store Council ID in OptimisticIntent

**Approach**: Add `council_id` field to track which council created each intent. Verify the executing intent came from the correct council.

**Changes Required**:

1. **Update OptimisticIntent struct**:
```move
public struct OptimisticIntent has store {
    id: ID,
    intent_key: String,
    proposer: address,
    council_id: ID,  // ← NEW: Which council created this
    title: String,
    description: String,
    // ... rest of fields
}
```

2. **Update creation logic**:
```move
public fun do_create_optimistic_intent<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    _version_witness: VersionWitness,
    witness: IW,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // ... deserialization ...

    // Extract council ID from the executable's intent
    let executing_account = protocol_intents::account(executable::intent(executable));
    let council_id = object::id_from_address(executing_account);

    let intent = OptimisticIntent {
        id: intent_id,
        intent_key: action.intent_key,
        proposer: tx_context::sender(ctx),
        council_id,  // ← Store which council created it
        title: action.title,
        // ... rest of fields
    };
}
```

3. **Update cancellation logic**:
```move
public fun do_cancel_optimistic_intent<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    _version_witness: VersionWitness,
    witness: IW,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // ... existing code ...

    // Extract the council ID from the executable's intent
    let executing_account = protocol_intents::account(executable::intent(executable));
    let executing_council_id = object::id_from_address(executing_account);

    // Verify the cancellation comes from the same council that created the intent
    assert!(intent.council_id == executing_council_id, EWrongCouncil);

    // Check not already cancelled or executed
    assert!(!intent.is_cancelled, EIntentAlreadyCancelled);
    // ... rest of logic
}
```

**Pros**:
- ✅ Prevents council A from canceling council B's intents
- ✅ Better accountability (tracks council ownership)
- ✅ Reusable abstraction pattern for other cross-council operations
- ✅ Type-safe (council ID is verified at creation)

**Cons**:
- ❌ More complex (requires struct migration for existing intents)
- ❌ Extra storage (32 bytes per intent)
- ❌ Doesn't actually increase security (multisig approval already gates this)

---

## Solution 3: Use Executable Intent Metadata (Most Flexible)

**Approach**: Extract the executing account address from the `Executable`'s `Intent` object and verify it's a registered council.

**Changes Required**:

1. **Add helper function**:
```move
/// Extract the account address from an executable
/// This returns the account that approved the intent being executed
fun get_executing_account<Outcome: store>(executable: &Executable<Outcome>): address {
    let intent = executable::intent(executable);
    protocol_intents::account(intent)
}

/// Verify the executing account is a registered council
fun verify_council_authorization(
    dao: &Account<FutarchyConfig>,
    executing_account: address,
) {
    let council_id = object::id_from_address(executing_account);

    // Check if council is registered
    let registry: &CouncilRegistry = account::borrow_managed_data(
        dao,
        CouncilRegistryKey {},
        version::current()
    );

    assert!(
        table::contains(&registry.councils, council_id),
        ENotSecurityCouncil
    );
}
```

2. **Update cancellation logic**:
```move
public fun do_cancel_optimistic_intent<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    _version_witness: VersionWitness,
    witness: IW,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // ... deserialization ...

    // Extract executing account and verify it's a registered council
    let executing_account = get_executing_account(executable);
    verify_council_authorization(account, executing_account);

    // Check intent exists
    assert!(table::contains(&storage.intents, action.intent_id), EIntentNotFound);
    let intent = table::borrow_mut(&mut storage.intents, action.intent_id);

    // OPTIONAL: Also verify it's the SAME council that created the intent
    // (Only if you want to prevent cross-council cancellations)
    // let intent_council = object::id_from_address(intent.proposer);
    // assert!(intent_council == object::id_from_address(executing_account), EWrongCouncil);

    // Check not already cancelled or executed
    assert!(!intent.is_cancelled, EIntentAlreadyCancelled);
    // ... rest of logic
}
```

**Pros**:
- ✅ **Reusable pattern** for all council actions
- ✅ Verifies council registration dynamically
- ✅ No struct changes needed
- ✅ Clean abstraction (`verify_council_authorization` helper)
- ✅ Works for any council-gated action

**Cons**:
- ❌ Slightly more gas (reads council registry on every call)
- ❌ Redundant check (multisig already ensures authorization)

---

## Solution 4: Hybrid - Store Both Council ID + Verify at Runtime

**Approach**: Combine Solution 2 and 3 for maximum security.

**Changes**: Store `council_id` in `OptimisticIntent` + verify executing account matches at runtime.

**Pros**:
- ✅ Maximum security (defense in depth)
- ✅ Prevents cross-council interference
- ✅ Clear audit trail

**Cons**:
- ❌ Most complex
- ❌ Highest gas cost
- ❌ Overkill (multisig approval already provides security)

---

## Recommendation

**Use Solution 1** (Remove Proposer Check) ✅

**Reasoning**:
1. **Simplicity**: No additional storage, no struct migrations
2. **Standard pattern**: Matches how other DAO actions work (multisig approval = authorization)
3. **Clear security model**: The council's multisig approval IS the authorization check
4. **Sufficient security**: The intent system already ensures only approved actions execute

**When to use alternatives**:
- **Solution 2/3**: If you need to prevent **cross-council interference** (e.g., Council A canceling Council B's intents)
- **Solution 4**: If you're building a **multi-tenancy system** where councils are mutually distrustful

For a typical DAO with trusted councils, **Solution 1 is the right choice**.

---

## Implementation Status

✅ **Solution 1 has been implemented** in `/contracts/futarchy_multisig/sources/optimistic_intents.move:553-563`

The fix includes:
- Removed the broken `assert!(intent.proposer == sender, ENotProposer)` check
- Added comprehensive security model documentation
- Clarified that `proposer` field is for audit/accountability only

---

## Testing Recommendations

1. **Happy path**: Council member proposes → Council approves → Execute successfully
2. **Authorization**: Non-council cannot create cancellation intent (blocked at intent creation)
3. **Idempotency**: Cannot cancel already-cancelled intent
4. **Race condition**: Cannot cancel already-executed intent
5. **Multisig**: Cancellation requires threshold approvals from council

No changes needed to existing tests - the multisig layer already enforces authorization.
