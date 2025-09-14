# Agent 3: Supporting Actions Migration

## 🎯 Assignment: Supporting & Administrative Actions

You are responsible for fixing all supporting actions including custody, multisig, legal agreements, and admin functions.

## 🚨 Critical Security Context

The Futarchy system has a **type confusion vulnerability** where actions can be executed by wrong handlers due to missing type validation before BCS deserialization. You must add type checks BEFORE deserialization.

## 📦 Your Packages

1. **futarchy_vault** package (custody actions)
2. **futarchy_multisig** package (council and policy actions)
3. **futarchy_specialized_actions** package (operating agreements)
4. **futarchy_actions** package (admin and founder lock actions)
5. **futarchy_core** package (for imports)

## ✅ Prerequisites Already Complete

- `action_validation.move` helper exists in futarchy_core
- `action_types.move` with type markers exists in futarchy_core
- Developer guide available at FUTARCHY_ACTION_DEVELOPER_GUIDE.md

## 📋 Your Todo List

### File 1: custody_actions.move (futarchy_vault/sources/custody_actions.move)
- [ ] Add imports for `action_validation` and `action_types`
- [ ] Fix ALL 4 custody actions:
  - CreateCustodyAccountAction
  - CustodyDepositAction
  - CustodyWithdrawAction
  - CustodyTransferAction
- [ ] Add destruction functions for all 4 action types
- [ ] Update all do_ functions with BCS validation
- [ ] Add/fix new_ functions with serialize-then-destroy
- [ ] Add delete_ functions for cleanup

### File 2: security_council_actions.move (futarchy_multisig/sources/security_council_actions.move)
- [ ] Add imports for `action_validation` and `action_types`
- [ ] Fix ALL 7 council actions:
  - CreateCouncilAction
  - AddCouncilMemberAction
  - RemoveCouncilMemberAction
  - UpdateCouncilThresholdAction
  - ProposeCouncilActionAction
  - ApproveCouncilActionAction
  - ExecuteCouncilActionAction
- [ ] Add destruction functions for all 7 action types
- [ ] Update all do_ functions with BCS validation
- [ ] Add delete_ functions

### File 3: policy_actions.move (futarchy_multisig/sources/policy/policy_actions.move)
- [ ] Add imports for `action_validation` and `action_types`
- [ ] Fix ALL 3 policy actions:
  - CreatePolicyAction
  - UpdatePolicyAction
  - RemovePolicyAction
- [ ] Add destruction functions for all 3 action types
- [ ] Update all do_ functions with BCS validation
- [ ] Add delete_ functions

### File 4: operating_agreement_actions.move (futarchy_specialized_actions/sources/legal/operating_agreement_actions.move)
- [ ] Add imports for `action_validation` and `action_types`
- [ ] Fix ALL 7 agreement actions:
  - CreateOperatingAgreementAction
  - AddLineAction
  - RemoveLineAction
  - UpdateLineAction
  - BatchAddLinesAction
  - BatchRemoveLinesAction
  - LockOperatingAgreementAction
- [ ] Add destruction functions for all 7 action types
- [ ] Update all do_ functions with BCS validation
- [ ] Add delete_ functions

### File 5: protocol_admin_actions.move (futarchy_actions/sources/intent_lifecycle/protocol_admin_actions.move)
- [ ] Add imports for `action_validation` and `action_types`
- [ ] Fix ALL 7 admin actions:
  - SetFactoryPausedAction
  - AddStableTypeAction
  - RemoveStableTypeAction
  - UpdateDaoCreationFeeAction
  - UpdateProposalFeeAction
  - UpdateTreasuryAddressAction
  - WithdrawProtocolFeesAction
- [ ] Add destruction functions for all 7 action types
- [ ] Update all do_ functions with BCS validation
- [ ] Add delete_ functions

### File 6: founder_lock_actions.move (futarchy_actions/sources/intent_lifecycle/founder_lock_actions.move)
- [ ] Add imports for `action_validation` and `action_types`
- [ ] Fix ALL 2 founder lock actions:
  - CreateFounderLockAction
  - UnlockFounderTokensAction
- [ ] Add destruction functions for both action types
- [ ] Update all do_ functions with BCS validation
- [ ] Add delete_ functions

### File 7: Update Supporting Decoders
- [ ] Fix custody_decoder.move - replace deprecated type_name APIs
- [ ] Fix security_council_decoder.move - replace deprecated type_name APIs
- [ ] Fix policy_decoder.move - replace deprecated type_name APIs
- [ ] Fix operating_agreement_decoder.move - replace deprecated type_name APIs
- [ ] Fix protocol_admin_decoder.move - replace deprecated type_name APIs
- [ ] Fix founder_lock_decoder.move - replace deprecated type_name APIs
- [ ] Replace all `type_name::get` → `type_name::with_defining_ids`
- [ ] Replace all `type_name::get_address` → `type_name::address_string`
- [ ] Replace all `type_name::get_module` → `type_name::module_string`

### File 8: Compilation Testing
- [ ] Test compilation of futarchy_vault package
- [ ] Test compilation of futarchy_multisig package
- [ ] Test compilation of futarchy_specialized_actions package
- [ ] Test compilation of futarchy_actions package (admin modules)
- [ ] Test compilation of futarchy_dao package (final integration)
- [ ] Ensure no compilation errors after changes

## 🔧 Pattern You Must Apply

### For EVERY do_ function:
```move
public fun do_action<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    version: VersionWitness,
    intent_witness: IW,
) {
    // Step 1: Get action spec
    let specs = executable::intent(executable).action_specs();
    let spec = specs.borrow(executable::action_idx(executable));

    // Step 2: CRITICAL - Type check BEFORE deserialization
    action_validation::assert_action_type<action_types::MyAction>(spec);

    // Step 3: Get action data
    let action_data = protocol_intents::action_spec_data(spec);

    // Step 4: Version check
    let spec_version = protocol_intents::action_spec_version(spec);
    assert!(spec_version == 1, EUnsupportedActionVersion);

    // Step 5: Safe deserialization with BCS reader
    let mut reader = bcs::new(*action_data);
    let field1 = bcs::peel_vec_u8(&mut reader).to_string();
    let field2 = bcs::peel_u64(&mut reader);
    let field3 = bcs::peel_address(&mut reader);

    // Step 6: Validate all bytes consumed
    bcs_validation::validate_all_bytes_consumed(reader);

    // Step 7: Execute action logic
    // ... your logic here ...

    // Step 8: Increment action index
    executable::increment_action_idx(executable);
}
```

### For EVERY destruction function:
```move
public fun destroy_my_action(action: MyActionData) {
    let MyActionData {
        field1: _,
        field2: _,
        field3: _,
        // List ALL fields with _
    } = action;
}
```

### For EVERY new_ function:
```move
public fun new_my_action<Outcome, IW: drop>(
    intent: &mut Intent<Outcome>,
    field1: String,
    field2: u64,
    field3: address,
    intent_witness: IW,
) {
    // Create the action
    let action = MyActionData { field1, field2, field3 };

    // Serialize it
    let action_data = bcs::to_bytes(&action);

    // Add to intent with type marker
    intent.add_typed_action(
        action_types::my_action(),  // From action_types module
        action_data,
        intent_witness
    );

    // CRITICAL: Destroy the action
    destroy_my_action(action);
}
```

## 📊 Your Deliverables

1. All 8 files fully migrated to secure pattern
2. ~30 action types properly secured (4 custody + 7 council + 3 policy + 7 agreement + 7 admin + 2 founder)
3. All packages compile without errors
4. Complete test of final futarchy_dao integration

## 🚀 Start Here

1. Begin with custody_actions.move (simplest with only 4 actions)
2. Then security_council_actions.move (critical for multisig)
3. Complete operating_agreement_actions.move (complex with 7 actions)
4. Finish with admin actions (protocol-wide impact)
5. Test final integration with futarchy_dao package