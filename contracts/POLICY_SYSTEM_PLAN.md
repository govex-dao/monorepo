# Policy System Implementation Plan

## Executive Summary

This document outlines the complete plan for the Futarchy policy enforcement system, including:
1. **✅ COMPLETED**: Council pre-approval system via shared `ApprovedIntentSpec` objects
2. **✅ COMPLETED**: Policy hierarchy (OBJECT > TYPE > ACTION)
3. **🔄 IN PROGRESS**: Type-level policies via parameterized action registration
4. **⏭️ NEXT**: Revert PolicyRequirement shared objects to inline storage
5. **⏭️ FUTURE**: Execution-time policy enforcement

---

## Part 1: Policy Storage Architecture (NEEDS REVERT)

### Current State (INCORRECT)

PolicyRequirement data is stored in shared objects:
```move
public struct PolicyRequirement has key {
    id: UID,
    mode: u8,
    required_council_id: Option<ID>,
    council_approval_proof: Option<ID>,
}
```

**Problems**:
- Creates permanent shared objects (never deleted)
- No actual deduplication (new object per proposal)
- More expensive (consensus reads, creation gas)
- More complex (7 files changed, indirection)
- Actually uses MORE storage than inline (446 bytes vs 296 bytes)

### Target State (CORRECT)

**Use inline storage** in all structs:

```move
// In QueuedProposal, Proposal, ProposalReservation
public struct QueuedProposal<StableCoin> has store {
    // ... other fields ...

    // Policy enforcement (74 bytes)
    policy_mode: u8,
    required_council_id: Option<ID>,
    council_approval_proof: Option<ID>,
}

public struct Proposal<AssetType, StableType> has key {
    // ... other fields ...

    // Policy enforcement per outcome (74 bytes × N outcomes)
    policy_modes: vector<u8>,
    required_council_ids: vector<Option<ID>>,
    council_approval_proofs: vector<Option<ID>>,
}

public struct ProposalReservation has store {
    // ... other fields ...

    // Policy enforcement (74 bytes)
    policy_mode: u8,
    required_council_id: Option<ID>,
    council_approval_proof: Option<ID>,
}
```

**Benefits**:
- ✅ Simple, obvious, direct
- ✅ Auto-cleanup when proposal deleted
- ✅ No consensus overhead
- ✅ Locks in policy at creation time (same security property)
- ✅ Available for execution-time validation
- ✅ Preserved through eviction/recreation

**What needs to change**:
1. Revert `futarchy_multisig/sources/policy/policy_requirement.move` (delete file)
2. Revert `futarchy_core/sources/queue/priority_queue.move` (restore 3 fields)
3. Revert `futarchy_markets/sources/proposal.move` (restore 3 field vectors)
4. Revert `futarchy_actions/sources/governance/governance_actions.move` (inline storage)
5. Revert `futarchy_governance_actions/sources/governance/governance_intents.move` (direct field access)

---

## Part 2: Type-Level Policies (IN PROGRESS)

### Problem Statement

Actions are registered with non-parameterized TypeNames, losing type information:

```move
// ❌ BEFORE: Type parameter lost
intent.add_typed_action(
    framework_action_types::vault_spend(),  // "VaultSpend" (no CoinType)
    bcs::to_bytes(&action),
    witness
);
```

**Result**: Cannot differentiate "Spending SUI" vs "Spending USDC" for policies.

### Solution

Use action structs themselves as type witnesses:

```move
// ✅ AFTER: Type parameter preserved
let action = SpendAction<CoinType> { name, amount };
intent.add_typed_action(
    action,  // TypeName: "SpendAction<0x2::sui::SUI>"
    bcs::to_bytes(&action),
    witness
);
```

### Policy Hierarchy (OVERRIDE Semantics)

```
1. OBJECT (highest)   - "This specific stream (0x123) needs Treasury Council"
   ↓
2. TYPE (middle)      - "Spending SUI needs DAO, spending USDC needs Council"
   ↓
3. ACTION (lowest)    - "All vault spends need Treasury Council"
```

**First match wins, lower tiers skipped.**

### Migration Pattern

#### Step 1: Add `drop` Ability
```move
// BEFORE
public struct SpendAction<phantom CoinType> has store {
    name: String,
    amount: u64,
}

// AFTER
public struct SpendAction<phantom CoinType> has store, drop {
    name: String,
    amount: u64,
}
```

#### Step 2: Update Registration
```move
// BEFORE
public fun new_spend<Outcome, CoinType, IW: drop>(
    intent: &mut Intent<Outcome>,
    name: String,
    amount: u64,
    intent_witness: IW,
) {
    let action = SpendAction<CoinType> { name, amount };
    let action_data = bcs::to_bytes(&action);

    intent.add_typed_action(
        framework_action_types::vault_spend(),  // ❌ Non-parameterized
        action_data,
        intent_witness
    );

    destroy_spend_action(action);
}

// AFTER
public fun new_spend<Outcome, CoinType, IW: drop>(
    intent: &mut Intent<Outcome>,
    name: String,
    amount: u64,
    intent_witness: IW,
) {
    let action = SpendAction<CoinType> { name, amount };
    let action_data = bcs::to_bytes(&action);

    intent.add_typed_action(
        action,  // ✅ Preserves CoinType in TypeName
        action_data,
        intent_witness
    );

    // No destroy needed - action consumed
}
```

#### Step 3: No Changes to `do_` Functions

Execution functions already work correctly - no changes needed.

### Progress

**✅ Completed (4 actions)**:
- vault.move: DepositAction, SpendAction
- currency.move: MintAction, BurnAction

**🔲 Remaining (~46 actions)**:
- currency.move: DisableAction, UpdateAction
- vesting.move: CreateVestingAction, CancelVestingAction
- Stream actions (~12)
- Oracle actions (~8)
- Liquidity actions (~8)
- Dissolution actions (~5)
- Other Futarchy actions (~11)

### Timeline

**Estimate**: 14-19 hours (2-3 days focused work)

**Phases**:
1. Discovery (1 hour)
2. Move Framework (2-3 hours)
3. Futarchy Streams (2-3 hours)
4. Futarchy Oracle (2 hours)
5. Futarchy Liquidity (2-3 hours)
6. Remaining Futarchy (2-3 hours)
7. Integration Testing (2-3 hours)
8. Documentation (1 hour)

---

## Part 3: Council Pre-Approval System (COMPLETED ✅)

### Architecture

Security councils approve IntentSpecs by creating shared `ApprovedIntentSpec` objects:

```move
public struct ApprovedIntentSpec has key {
    id: UID,
    intent_spec_bytes: vector<u8>,  // BCS-serialized InitActionSpecs
    dao_id: ID,
    council_id: ID,
    approved_at_ms: u64,
    expires_at_ms: u64,
    metadata: String,
    used_count: u64,
}
```

### Flow

```
1. Council creates approval via multisig
   ↓
2. Shared ApprovedIntentSpec object created (ID: 0xABC123)
   ↓
3. User creates proposal, passes approval object reference
   ↓
4. System validates:
   - Object exists ✅
   - DAO ID matches ✅
   - Council ID matches ✅
   - Not expired ✅
   - IntentSpec matches ✅ (BCS comparison)
   ↓
5. Proposal queued for futarchy voting
```

### Benefits

- ✅ Type-safe (object has `key` ability)
- ✅ No hash matching needed
- ✅ Integrates with existing multisig
- ✅ Flexible expiration
- ✅ Revocable (delete object)
- ✅ Auditable (events, usage counter)

**Files**:
- `futarchy_multisig/sources/policy/approved_intent_spec.move` (NEW)
- `futarchy_multisig/sources/security_council_actions.move` (MODIFIED)
- `futarchy_actions/sources/governance/governance_actions.move` (MODIFIED)

---

## Part 4: Execution-Time Enforcement (FUTURE)

### Current Gap

**Problem**: MODE_DAO_AND_COUNCIL (mode 3) policies checked at creation but NOT at execution.

```move
// At proposal creation ✅
if (mode == 3) {
    assert!(approved_spec_opt.is_some(), ECouncilApprovalRequired);
}

// At proposal execution ❌
assert!(winning_outcome == OUTCOME_ACCEPTED);
// NO CHECK that council approved!
```

### Solution (Using Inline Storage)

```move
// During execution in proposal_lifecycle.move
public fun execute_approved_proposal(...) {
    // Validate policy was satisfied
    if (proposal.policy_mode == 3) {
        assert!(proposal.council_approval_proof.is_some(), EPolicyViolation);
        // Could also validate ApprovedIntentSpec still exists and not revoked
    }

    // Rest of execution...
}
```

**Why inline storage is better for this**:
- Direct field access (no ID lookup)
- Available immediately
- No transaction dependency on shared object
- Simple validation logic

---

## Implementation Priority

### Phase 1: Revert PolicyRequirement (HIGH PRIORITY)
**Time**: 2-3 hours
**Reason**: Wrong architecture, creates permanent object bloat

**Tasks**:
1. Delete `futarchy_multisig/sources/policy/policy_requirement.move`
2. Restore inline fields in `priority_queue.move`
3. Restore inline fields in `proposal.move`
4. Update `governance_actions.move` to store inline
5. Update `governance_intents.move` to read inline fields
6. Test build and existing functionality

### Phase 2: Complete Type-Level Policies (MEDIUM PRIORITY)
**Time**: 14-19 hours
**Reason**: Enables granular governance (SUI vs USDC policies)

**Tasks**:
1. Discovery - find all parameterized actions
2. Migrate Move Framework actions (vault, currency, vesting, access_control)
3. Migrate Futarchy actions (streams, oracle, liquidity, dissolution)
4. Integration testing
5. Documentation

### Phase 3: Add Execution-Time Enforcement (LOW PRIORITY)
**Time**: 2-3 hours
**Reason**: Defense in depth, but creation-time check already works

**Tasks**:
1. Add validation in `proposal_lifecycle.move::execute_approved_proposal()`
2. Check `policy_mode` field
3. Validate `council_approval_proof` exists if mode == 3
4. Test enforcement

---

## Success Criteria

### Phase 1 Complete When:
- [ ] PolicyRequirement module deleted
- [ ] All structs use inline storage
- [ ] Build succeeds
- [ ] No regressions in existing tests
- [ ] Policy lock-in still works (verified in tests)

### Phase 2 Complete When:
- [ ] All ~50 parameterized actions migrated
- [ ] All packages build and test successfully
- [ ] Type-level policies functional for all coin types
- [ ] Documentation updated
- [ ] Example policies demonstrated in tests

### Phase 3 Complete When:
- [ ] Execution-time validation added
- [ ] Tests verify MODE_DAO_AND_COUNCIL enforcement
- [ ] Defense-in-depth security achieved

---

## File Locations

**Policy System**:
- `futarchy_multisig/sources/policy/policy_registry.move` - Policy storage
- `futarchy_multisig/sources/policy/intent_spec_analyzer.move` - Policy analysis
- `futarchy_multisig/sources/policy/approved_intent_spec.move` - Council approvals

**Proposal Storage**:
- `futarchy_core/sources/queue/priority_queue.move` - QueuedProposal
- `futarchy_markets/sources/proposal.move` - Proposal
- `futarchy_actions/sources/governance/governance_actions.move` - ProposalReservation

**Enforcement Points**:
- `futarchy_actions/sources/governance/governance_actions.move` - Creation-time check
- `futarchy_governance_actions/sources/governance/governance_intents.move` - Execution entry
- `futarchy_dao/sources/proposal_lifecycle.move` - Execution logic

**Action Framework**:
- `move-framework/packages/actions/sources/lib/vault.move`
- `move-framework/packages/actions/sources/lib/currency.move`
- `move-framework/packages/actions/sources/lib/vesting.move`
- `move-framework/packages/actions/sources/lib/access_control.move`
- `futarchy_streams/sources/stream_actions.move`
- `futarchy_lifecycle/sources/oracle/oracle_actions.move`
- `futarchy_actions/sources/liquidity/liquidity_actions.move`

---

## Quick Reference

### Policy Modes
```move
MODE_DAO_ONLY (0)        // Just DAO vote
MODE_COUNCIL_ONLY (1)    // Just council approval
MODE_DAO_OR_COUNCIL (2)  // Either DAO or council
MODE_DAO_AND_COUNCIL (3) // Both required (needs pre-approval)
```

### Discovery Commands
```bash
# Find all parameterized actions
grep -r "public struct.*Action.*phantom.*has" contracts --include="*.move" | grep -v build

# Find registration sites
grep -r "add_typed_action\|add_action_spec" contracts/move-framework --include="*.move"
grep -r "add_typed_action\|add_action_spec" contracts/futarchy_* --include="*.move" | grep -v build
```

### Build Commands
```bash
# Build Move Framework
cd contracts/move-framework/packages/actions
sui move build --silence-warnings

# Build Futarchy package
cd contracts/futarchy_actions
sui move build --silence-warnings

# Build all
cd contracts
./deploy_verified.sh
```

---

## Conclusion

The policy system has solid foundations but needs course correction:

**Keep**:
- ✅ Council pre-approval via ApprovedIntentSpec objects
- ✅ Policy hierarchy (OBJECT > TYPE > ACTION)
- ✅ Pre-approval prevents spam markets
- ✅ Type-level policy infrastructure

**Fix**:
- 🔄 Revert PolicyRequirement shared objects → Use inline storage (74 bytes is fine!)
- 🔄 Complete parameterized action migration for type-level policies
- 🔄 Add execution-time enforcement for defense in depth

**Result**: Simple, secure, performant policy system with granular governance control.
