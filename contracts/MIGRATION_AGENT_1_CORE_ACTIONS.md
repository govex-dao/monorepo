# Agent 1: Core Actions Migration

## 🎯 Assignment: Core Futarchy Actions

You are responsible for fixing the core configuration and governance actions that are central to DAO operations.

## 🚨 Critical Security Context

The Futarchy system has a **type confusion vulnerability** where actions can be executed by wrong handlers due to missing type validation before BCS deserialization. You must add type checks BEFORE deserialization.

## 📦 Your Packages

1. **futarchy_actions** package (primary focus)
2. **futarchy_core** package (for imports)

## ✅ Prerequisites Already Complete

- `action_validation.move` helper exists in futarchy_core
- `action_types.move` with type markers exists in futarchy_core
- Developer guide available at FUTARCHY_ACTION_DEVELOPER_GUIDE.md

## 📋 Your Todo List

### File 1: config_actions.move (futarchy_actions/sources/config/config_actions.move)
- [ ] Add imports for `action_validation` and `action_types` modules
- [ ] Replace ALL `is_current_action` calls with `assert_action_type` for:
  - SetProposalsEnabledAction
  - UpdateNameAction
  - TradingParamsUpdateAction
  - MetadataUpdateAction
  - TwapConfigUpdateAction
  - GovernanceUpdateAction
  - MetadataTableUpdateAction
  - SlashDistributionUpdateAction
  - QueueParamsUpdateAction
- [ ] Add destruction functions for all 9 action types
- [ ] Update ALL do_ functions to use BCS reader pattern with validation
- [ ] Add/fix new_ functions with serialize-then-destroy pattern
- [ ] Add delete_ functions for cleanup from expired intents

### File 2: governance_actions.move (futarchy_actions/sources/governance/governance_actions.move)
- [ ] Add imports for `action_validation` and `action_types`
- [ ] Fix CreateProposalAction with type validation
- [ ] Fix ProposalReservationAction with type validation
- [ ] Add destruction functions
- [ ] Fix hot potato pattern for ResourceRequest if present
- [ ] Add delete_ functions

### File 3: platform_fee_actions.move (futarchy_actions/sources/governance/platform_fee_actions.move)
- [ ] Add imports for `action_validation` and `action_types`
- [ ] Replace `is_current_action` with `assert_action_type`
- [ ] Fix CollectPlatformFeeAction
- [ ] Add destruction functions
- [ ] Update do_ functions with BCS validation
- [ ] Add delete_ functions

### File 4: memo_actions.move (futarchy_actions/sources/memo/memo_actions.move)
- [ ] Add imports for `action_validation` and `action_types`
- [ ] Fix EmitMemoAction with type validation
- [ ] Fix EmitDecisionAction with type validation
- [ ] Add destruction functions
- [ ] Update do_ functions with BCS validation
- [ ] Add delete_ functions

### File 5: init_actions.move (futarchy_actions/sources/init_actions.move)
- [ ] Add imports for `action_validation` and `action_types`
- [ ] Fix initialization action patterns
- [ ] Add type validation for all init actions
- [ ] Add destruction functions
- [ ] Ensure serialize-then-destroy pattern

### File 6: Update Config Decoders
- [ ] Fix config_decoder.move - replace deprecated type_name APIs
- [ ] Fix governance_decoder.move - replace deprecated type_name APIs
- [ ] Fix platform_fee_decoder.move - replace deprecated type_name APIs
- [ ] Fix memo_decoder.move - replace deprecated type_name APIs
- [ ] Replace all `type_name::get` → `type_name::with_defining_ids`
- [ ] Replace all `type_name::get_address` → `type_name::address_string`
- [ ] Replace all `type_name::get_module` → `type_name::module_string`

### File 7: Compilation Testing
- [ ] Test compilation of futarchy_core package
- [ ] Test compilation of futarchy_actions package
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

    // Step 6: Validate all bytes consumed
    bcs_validation::validate_all_bytes_consumed(reader);

    // Step 7: Execute action logic

    // Step 8: Increment action index
    executable::increment_action_idx(executable);
}
```

### For EVERY new_ function:
```move
public fun new_action<Outcome, IW: drop>(
    intent: &mut Intent<Outcome>,
    field1: String,
    field2: u64,
    intent_witness: IW,
) {
    // Create, serialize, add, destroy
    let action = MyActionData { field1, field2 };
    let action_data = bcs::to_bytes(&action);
    intent.add_typed_action(
        action_types::my_action(),
        action_data,
        intent_witness
    );
    destroy_my_action(action);
}
```

## 📊 Your Deliverables

1. All 7 files fully migrated to secure pattern
2. ~25 action types properly secured
3. All packages compile without errors
4. No deprecated APIs remaining

## 🚀 Start Here

1. Begin with config_actions.move as it has the most actions
2. Use the FUTARCHY_ACTION_DEVELOPER_GUIDE.md for reference
3. Compile frequently to catch errors early
4. Complete one file fully before moving to next