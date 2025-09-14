# Futarchy Actions Security Migration Plan

## Overview
All Futarchy action modules need to be migrated to match the Move Framework's secure pattern to prevent type confusion vulnerabilities.

## Current State Analysis

### Action Files to Fix (17 total):
1. **futarchy_actions** package (8 files):
   - config/config_actions.move
   - governance/governance_actions.move
   - governance/platform_fee_actions.move
   - init_actions.move
   - intent_lifecycle/founder_lock_actions.move
   - intent_lifecycle/protocol_admin_actions.move
   - liquidity/liquidity_actions.move
   - memo/memo_actions.move

2. **futarchy_lifecycle** package (5 files):
   - dissolution/dissolution_actions.move
   - factory/factory_with_init_actions.move
   - oracle/oracle_actions.move
   - payments/payment_actions.move
   - payments/stream_actions.move

3. **futarchy_multisig** package (2 files):
   - policy/policy_actions.move
   - security_council_actions.move

4. **futarchy_specialized_actions** package (1 file):
   - legal/operating_agreement_actions.move

5. **futarchy_vault** package (1 file):
   - custody_actions.move

## Migration Requirements for Each Action

### For EVERY action in EVERY file:

1. **Add Type Marker** (in futarchy_core/sources/action_types.move)
   ```move
   public struct MyAction has drop {}
   public fun my_action(): TypeName {
       type_name::with_defining_ids<MyAction>()
   }
   ```

2. **Add Destruction Function**
   ```move
   public fun destroy_my_action(action: MyActionData) {
       let MyActionData { field1: _, field2: _ } = action;
   }
   ```

3. **Fix do_ Function**
   Replace:
   ```move
   // OLD - VULNERABLE
   assert!(executable::is_current_action<Outcome, MyAction>(executable), EWrongAction);
   ```

   With:
   ```move
   // NEW - SECURE
   let specs = executable::intent(executable).action_specs();
   let spec = specs.borrow(executable::action_idx(executable));

   // CRITICAL: Assert action type before deserialization
   action_validation::assert_action_type<action_types::MyAction>(spec);

   let action_data = protocol_intents::action_spec_data(spec);

   // Check version
   let spec_version = protocol_intents::action_spec_version(spec);
   assert!(spec_version == 1, EUnsupportedActionVersion);

   // Deserialize with BCS reader
   let mut reader = bcs::new(*action_data);
   let field1 = bcs::peel_vec_u8(&mut reader).to_string();
   let field2 = bcs::peel_u64(&mut reader);

   // Validate all bytes consumed
   bcs_validation::validate_all_bytes_consumed(reader);
   ```

4. **Add/Fix new_ Function**
   ```move
   public fun new_my_action<Outcome, IW: drop>(
       intent: &mut Intent<Outcome>,
       field1: String,
       field2: u64,
       intent_witness: IW,
   ) {
       // Create action
       let action = MyActionData { field1, field2 };

       // Serialize
       let action_data = bcs::to_bytes(&action);

       // Add to intent
       intent.add_typed_action(
           action_types::my_action(),
           action_data,
           intent_witness
       );

       // Destroy
       destroy_my_action(action);
   }
   ```

5. **Add delete_ Function**
   ```move
   public fun delete_my_action(expired: &mut Expired) {
       let _spec = intents::remove_action_spec(expired);
   }
   ```

## Import Requirements

Every action file needs:
```move
use futarchy_core::{
    action_validation,
    action_types,
};
use account_protocol::{
    bcs_validation,
    // ... other imports
};
```

## Decoder Updates

All decoder files need:
- Replace `type_name::get` → `type_name::with_defining_ids`
- Replace `type_name::get_address` → `type_name::address_string`
- Replace `type_name::get_module` → `type_name::module_string`

## Testing Strategy

1. **Unit Tests**: Test each action's serialize/deserialize cycle
2. **Type Safety Tests**: Test wrong action type rejection
3. **Integration Tests**: Test full action flow through intents
4. **Compilation Tests**: Ensure all packages build

## Estimated Effort

- **Action Types**: ~100 action types to define
- **do_ Functions**: ~100 functions to fix
- **new_ Functions**: ~100 functions to add/fix
- **destroy_ Functions**: ~100 functions to add
- **delete_ Functions**: ~100 functions to add
- **Decoders**: ~20 decoder files to fix

Total: ~500+ code changes across 17 files

## Automated vs Manual

Due to the complexity and variety of action structures:
1. **Automated**: Import additions, decoder deprecation fixes
2. **Manual**: Action-specific destruction functions, BCS deserialization logic
3. **Semi-Automated**: Type assertions, function signatures

## Priority Order

1. **High Priority** (Core Actions):
   - config_actions.move
   - governance_actions.move
   - liquidity_actions.move
   - dissolution_actions.move

2. **Medium Priority** (Financial):
   - stream_actions.move
   - oracle_actions.move
   - platform_fee_actions.move
   - custody_actions.move

3. **Lower Priority** (Supporting):
   - memo_actions.move
   - operating_agreement_actions.move
   - security_council_actions.move
   - policy_actions.move

## Validation Checklist

For each action:
- [ ] Type marker defined in action_types.move
- [ ] Destruction function exists
- [ ] do_ function uses action_validation::assert_action_type
- [ ] do_ function validates all bytes consumed
- [ ] new_ function follows serialize-then-destroy
- [ ] delete_ function exists
- [ ] Decoder updated to non-deprecated APIs
- [ ] Tests pass

## Next Steps

1. Start with high-priority files
2. Fix one action at a time, testing after each
3. Update integration tests
4. Run full test suite
5. Deploy to testnet

This is a critical security fix that prevents type confusion attacks in the Futarchy governance system.