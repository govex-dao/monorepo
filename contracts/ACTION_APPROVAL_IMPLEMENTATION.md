# Action Approval System Implementation Plan

## Overview
Implement a system where all actions in a winning futarchy outcome must execute atomically, with proper approval checks for actions that require Security Council (SC) approval.

## Core Problem
- Actions in a winning outcome must ALL execute or NONE execute (atomic)
- Some actions require Security Council approval in addition to DAO vote
- A DAO can have multiple Security Councils with different responsibilities
- We need to check approvals WITHOUT knowing action types at compile time

## Key Design Decisions

### 1. Use vector<u8> Instead of String
- **Why**: Gas efficiency - vectors are more efficient than String in Move
- **Where**: Category names, action types, council names
- **Example**: `b"treasury"` instead of `string::utf8(b"treasury")`

### 2. Action Descriptors
Simple metadata attached to each action:
```move
public struct ActionDescriptor has copy, drop, store {
    category: vector<u8>,        // e.g., b"treasury", b"governance"
    action: vector<u8>,          // e.g., b"spend", b"mint"
    required_council: Option<ID>, // Specific council if needed
    required_object: Option<ID>,  // Specific object if needed
}
```

### 3. Approval Modes
```move
const MODE_DAO_ONLY: u8 = 0;        // Just DAO vote (default)
const MODE_COUNCIL_ONLY: u8 = 1;    // Just council, no DAO vote
const MODE_DAO_OR_COUNCIL: u8 = 2;  // Either DAO or council
const MODE_DAO_AND_COUNCIL: u8 = 3; // Both DAO and council required
```

## Implementation Scope

### Phase 1: Core Infrastructure
1. **action_descriptor.move** in extensions package
   - Simple descriptor struct
   - Helper functions to create/check descriptors
   - NO risk levels, gas estimates, or extra complexity

2. **Update intents.move**
   - Add `action_descriptors: vector<ActionDescriptor>` field
   - Add `add_action_with_descriptor()` function
   - Initialize empty vector in `new_intent()`

### Phase 2: Policy Registry Enhancement
Update `policy_registry.move` to support:
```move
public struct PolicyRegistry has store {
    // Existing
    policies: Table<String, Policy>,
    critical_policies: vector<String>,
    
    // NEW: Multi-council support
    pattern_councils: Table<vector<u8>, ID>,     // b"treasury/mint" → council_id
    object_councils: Table<ID, ID>,              // object_id → council_id
    registered_councils: vector<ID>,             // All councils for this DAO
    council_names: Table<ID, vector<u8>>,        // council_id → b"Treasury Council"
    
    // NEW: Approval modes per pattern
    pattern_modes: Table<vector<u8>, u8>,        // b"treasury/mint" → MODE_DAO_AND_COUNCIL
}
```

### Phase 3: Descriptor Analyzer
New module `descriptor_analyzer.move`:
```move
public fun analyze_requirements(
    intent: &Intent<Outcome>,
    registry: &PolicyRegistry
): ApprovalRequirement {
    // Check all descriptors
    // Determine which councils needed
    // Return requirement with mode
}

public fun check_approvals(
    requirement: &ApprovalRequirement,
    dao_approved: bool,
    council_approved: bool
): bool {
    // Check if approvals satisfy requirement based on mode
}
```

### Phase 4: Update Action Dispatcher
Add approval checkpoint in `action_dispatcher.move`:
```move
public fun execute_with_approvals<IW: copy + drop, Outcome>(
    executable: Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    multisigs: vector<WeightedMultisig>,  // Pass all SCs
    witness: IW,
    clock: &Clock,
    ctx: &mut TxContext,
): Executable<Outcome> {
    // 1. Get policy registry
    // 2. Analyze all action descriptors
    // 3. Check DAO approval (winning outcome = approved)
    // 4. Check required council approvals
    // 5. Assert all approvals satisfied
    // 6. Execute actions atomically
}
```

### Phase 5: Update Action Creation Functions
For each action type, add descriptor support:

#### Example: Vault Actions
```move
// In vault.move
public fun new_spend_with_descriptor<Outcome, CoinType, IW: drop>(
    intent: &mut Intent<Outcome>,
    name: String,
    amount: u64,
    intent_witness: IW,
) {
    let descriptor = action_descriptor::new(
        b"treasury",
        b"spend",
        option::none(),  // Use default council for treasury
        option::none()   // No specific object
    );
    intent.add_action_with_descriptor(
        SpendAction<CoinType> { name, amount },
        descriptor,
        intent_witness
    );
}
```

## Actions Needing Descriptors

### Move Framework Actions
- **Vault**: spend, deposit, transfer
- **Currency**: mint, burn
- **Owned**: transfer ownership

### Futarchy Actions
- **Governance**: create_proposal, update_config
- **Liquidity**: create_pool, update_parameters
- **Oracle**: conditional_mint, tiered_mint
- **Dissolution**: initiate, distribute
- **Stream**: create_stream, cancel_stream
- **Operating Agreement**: update_terms

## Multiple Security Councils Example

A DAO might have:
1. **Treasury Council** (ID: 0x123...)
   - Controls: treasury/spend, treasury/mint
   - Mode: DAO_AND_COUNCIL

2. **Technical Council** (ID: 0x456...)
   - Controls: upgrade/*, config/*
   - Mode: DAO_OR_COUNCIL

3. **Emergency Council** (ID: 0x789...)
   - Controls: emergency/*
   - Mode: COUNCIL_ONLY (no DAO vote needed)

## Execution Flow

1. **Proposal Passes**: Winning outcome determined
2. **Get Executable**: Extract executable from winning outcome
3. **Check Approvals**:
   - Analyze all action descriptors
   - Determine which councils needed
   - Check if required councils have approved
4. **Execute Atomically**:
   - If all approvals present: execute all actions
   - If any approval missing: revert with error

## Key Invariants

1. **Atomicity**: All actions execute or none execute
2. **No Execution Without Approval**: Cannot bypass required approvals
3. **DAO Approval = Winning Outcome**: Having executable means DAO approved
4. **Council Approval = Signed Intent**: Council must sign same intent hash

## Implementation Order

1. ✅ Create action_descriptor.move
2. ✅ Update intents.move with descriptor storage
3. ✅ Create descriptor_analyzer.move
4. ✅ Update action_dispatcher with approval checking
5. ⏳ Update existing action creation functions
6. ⏳ Enhance policy_registry for multi-council
7. ⏳ Add council registration functions
8. ⏳ Test with multiple councils

## Notes

- Keep it simple - no risk levels, gas estimates, or complex metadata
- Use vector<u8> for efficiency
- Focus on approval requirements only
- Ensure backward compatibility where possible