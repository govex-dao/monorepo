# Full Action Migration Checklist

## Architecture Update ✅
**ExecutionContext is now in the core framework!** No need for ExecutionBundle or separate modules.

### Core Framework Changes (COMPLETE)
- ✅ ExecutionContext embedded directly in Executable
- ✅ account::create_executable now takes TxContext
- ✅ All placeholder methods in executable.move
- ✅ Single hot potato pattern (no bundles)

### Import Changes for Actions
```move
// OLD - Don't use these
use account_protocol::execution_context::{Self, ExecutionContext};
use futarchy_dao::execution_bundle::{Self, ExecutionBundle};

// NEW - Use these
use account_protocol::executable::{Self, Executable, ExecutionContext};
```

### PTB Flow
```typescript
const executable = execute_proposal_start(account, proposal, clock);
execute_config_actions(executable, account);
execute_council_actions(executable, account, extensions, clock);
execute_liquidity_actions(executable, account, amm, coins, clock);
execute_proposal_end(account, executable);
```

## Actions & Intents Files to Migrate

### Total Files Found
- **15 Action files** to update
- **13 Intent files** to update

## Migration Status

### 1. Config Module (/futarchy_actions/sources/config/)
- [x] `config_actions.move` - Added `drop, copy` abilities to all actions
- [x] `config_intents.move` - Converted to use `add_action_spec()`

### 2. Liquidity Module (/futarchy_actions/sources/liquidity/)
- [x] `liquidity_actions.move` - **CreatePool** has `placeholder_out`, **UpdatePoolParams/SetPoolStatus** have `placeholder_in`
- [x] `liquidity_intents.move` - Converted to use `add_action_spec()`, added placeholder helpers

### 3. Stream/Payments Module (/futarchy_lifecycle/sources/payments/)
- [x] `stream_actions.move` - Added `drop, copy` abilities (Note: Stream IDs are strings, not object IDs, so placeholders not applicable)
- [x] `stream_intents.move` - Converted to use `add_action_spec()` where applicable

### 4. Dissolution Module (/futarchy_lifecycle/sources/dissolution/)
- [x] `dissolution_actions.move` - Added `drop, copy` abilities to all actions
- [x] `dissolution_intents.move` - Converted to use `add_action_spec()`

### 5. Oracle Module (/futarchy_lifecycle/sources/oracle/)
- [x] `oracle_actions.move` - Added `drop, copy` abilities to all actions
- [x] `oracle_intents.move` - Converted to use `add_action_spec()`

### 6. Security Council Module (/futarchy_multisig/sources/)
- [x] `security_council_actions_with_placeholders.move` - COMPLETE example
- [x] `security_council_dispatcher.move` - COMPLETE dispatcher
- [ ] `security_council_intents.move` - Update remaining functions
- [ ] `policy_actions.move` - Add placeholder support for policy operations
- [ ] `optimistic_intents.move` - Convert to new pattern
- [ ] `upgrade_cap_intents.move` - Convert to new pattern

### 7. Vault/Custody Module (/futarchy_vault/sources/)
- [x] `custody_actions.move` - Added `drop, copy` abilities (works with existing object IDs, no placeholders needed)

### 8. Governance Module (/futarchy_actions/sources/governance/)
- [x] `governance_actions.move` - Already has correct abilities
- [ ] `platform_fee_actions.move` - Likely standalone

### 9. Operating Agreement Module (/futarchy_specialized_actions/sources/legal/)
- [x] `operating_agreement_actions.move` - Added `drop, copy` abilities to all actions
- [x] `operating_agreement_intents.move` - Converted to use `add_action_spec()`

### 10. Protocol Admin Module (/futarchy_actions/sources/intent_lifecycle/)
- [ ] `protocol_admin_actions.move` - Check for patterns
- [ ] `protocol_admin_intents.move` - Convert to new pattern
- [ ] `founder_lock_actions.move` - May need placeholders for locks
- [ ] `founder_lock_intents.move` - Convert to new pattern

### 11. Other Modules
- [ ] `init_actions.move` - Special case for DAO initialization
- [ ] `memo_actions.move` - Standalone (no placeholders)
- [ ] `memo_intents.move` - Simple conversion

## Migration Steps for Each Module

### For Each Action File:

1. **Identify Pattern**:
   ```move
   // Creates object? → Add placeholder_out
   // Uses object? → Add placeholder_in
   // Standalone? → No struct changes
   ```

2. **Update Structs** (if needed):
   ```move
   public struct CreatePoolAction has store, drop, copy {
       // ... existing fields ...
       placeholder_out: Option<u64>, // Optional for flexibility
   }
   ```

3. **Update Constructors**:
   ```move
   public fun new_create_pool(
       // ... existing params ...
       placeholder_out: Option<u64>,
   ): CreatePoolAction {
       // ...
   }
   ```

4. **Update Handlers**:
   ```move
   public fun do_create_pool(
       context: &mut ExecutionContext, // From executable.move
       params: CreatePoolAction,
       // ... other params ...
   ) {
       // ... create pool ...
       if (params.placeholder_out.is_some()) {
           executable::register_placeholder( // Note: executable:: not execution_context::
               context,
               *params.placeholder_out.borrow(),
               pool_id
           );
       }
   }
   ```

### For Each Intent File:

1. **Update Imports**:
   ```move
   use account_protocol::intents;
   // No need to import execution_context - it's all in executable now
   ```

2. **Update Intent Building**:
   ```move
   dao.build_intent!(/* ... */, |intent, iw| {
       // Reserve placeholders if needed
       let pool_placeholder = intents::reserve_placeholder_id(intent);

       // Use add_action_spec instead of old methods
       intents::add_action_spec(
           intent,
           action,
           action_types::CreatePool {},
           iw
       );
   });
   ```

## Dispatcher Updates Needed

Create new category dispatchers for:
- [x] `config_dispatcher.move` - COMPLETE
- [x] `security_council_dispatcher.move` - COMPLETE
- [ ] `vault_dispatcher.move`
- [ ] `stream_dispatcher.move`
- [ ] `dissolution_dispatcher.move`
- [ ] `governance_dispatcher.move`
- [ ] `oracle_dispatcher.move`
- [x] `liquidity_dispatcher.move` - COMPLETE with placeholder support

Each following the pattern:
```move
public fun execute_category_actions(
    executable: &mut Executable<ProposalOutcome>, // Single hot potato!
    // ... category-specific resources ...
) {
    // Get context if needed for placeholders
    let context = executable::context_mut(executable);

    while (executable::action_idx(executable) < total) {
        if (is_category_action(action_type)) {
            // Process
            executable::increment_action_idx(executable);
        } else {
            break; // Let next dispatcher handle
        }
    }
}
```

## Priority Order

1. **High Priority** (Create/Use patterns):
   - Liquidity (pools)
   - Streams (payment streams)
   - Vault (treasury vaults)
   - Security Council (remaining functions)

2. **Medium Priority** (Some interdependencies):
   - Dissolution (asset distribution)
   - Oracle (price-based actions)
   - Governance (proposal creation)

3. **Low Priority** (Mostly standalone):
   - Config (settings)
   - Memo (events only)
   - Operating Agreement (text management)
   - Platform Fees (standalone)

## Testing Strategy

For each migrated module:
1. Unit test handlers with ExecutionContext from executable.move
2. Integration test complete workflows
3. Test placeholder resolution between actions
4. Verify sequential dispatcher processing
5. Test PTB composition with multiple dispatchers

## Estimated Effort

- **15 action files** × 30 min avg = 7.5 hours
- **13 intent files** × 20 min avg = 4.3 hours
- **5 new dispatchers** × 45 min = 3.75 hours (2 already done)
- **Testing** = 4 hours
- **Total**: ~18 hours of focused work

## Key Architecture Points

1. **NO ExecutionBundle** - ExecutionContext is embedded in Executable
2. **NO separate execution_context module** - Everything is in executable.move
3. **NO monolithic dispatcher** - Only category-specific dispatchers
4. **PTB composition** - Client chains dispatchers together
5. **Single hot potato** - Just pass Executable, not a bundle