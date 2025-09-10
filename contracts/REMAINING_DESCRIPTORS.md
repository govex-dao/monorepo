# Remaining Actions Needing Descriptors

## Summary
We need to add descriptors to all remaining futarchy actions. Each action should have a unique, meaningful descriptor that clearly identifies what it does.

## Completed ✅
- Move Framework vault actions (spend, deposit, transfer)
- Move Framework currency actions (mint, burn)
- Move Framework owned actions (withdraw)
- Move Framework package upgrade actions (upgrade, commit, restrict)
- Some config actions
- Some liquidity actions

## Remaining Actions to Update

### Futarchy Lifecycle
- **Stream Actions**:
  - `b"stream", b"create"`
  - `b"stream", b"cancel"`
  - `b"stream", b"withdraw"`
  - `b"stream", b"update_recipient"`

- **Dissolution Actions**:
  - `b"dissolution", b"initiate"`
  - `b"dissolution", b"finalize"`
  - `b"dissolution", b"distribute"`
  - `b"dissolution", b"claim"`

- **Oracle Actions**:
  - `b"oracle", b"conditional_mint"`
  - `b"oracle", b"tiered_mint"`
  - `b"oracle", b"read_price"`
  - `b"oracle", b"update_oracle"`

### Futarchy Actions
- **Commitment Actions**:
  - `b"commitment", b"create"`
  - `b"commitment", b"execute"`
  - `b"commitment", b"withdraw"`
  - `b"commitment", b"update_recipient"`

- **Governance Actions**:
  - `b"governance", b"create_proposal"`
  - Already have various config update actions

### Futarchy Specialized Actions
- **Operating Agreement Actions**:
  - `b"legal", b"update_operating_agreement"`
  - `b"legal", b"update_terms"`
  - `b"legal", b"update_signatories"`

## Pattern for Adding Descriptors

Replace:
```move
intent.add_action(action, intent_witness);
```

With:
```move
let descriptor = action_descriptor::new(b"category", b"specific_action");
intent.add_action_with_descriptor(action, descriptor, intent_witness);
```

## Files to Update
1. `/Users/admin/monorepo/contracts/futarchy_lifecycle/sources/payments/stream_intents.move`
2. `/Users/admin/monorepo/contracts/futarchy_lifecycle/sources/dissolution/dissolution_intents.move`
3. `/Users/admin/monorepo/contracts/futarchy_lifecycle/sources/oracle_actions.move`
4. `/Users/admin/monorepo/contracts/futarchy_actions/sources/commitment_*`
5. `/Users/admin/monorepo/contracts/futarchy_specialized_actions/sources/legal/operating_agreement_intents.move`

## Implementation Strategy
1. Add import for action_descriptor to each file
2. Replace each add_action call with add_action_with_descriptor
3. Use meaningful, unique descriptors for each action type
4. Test compilation after each file update