# Agent 2: Financial Actions Migration

## 🎯 Assignment: Financial & Liquidity Actions

You are responsible for fixing all financial operations including liquidity, dissolution, streams, and oracle actions.

## 🚨 Critical Security Context

The Futarchy system has a **type confusion vulnerability** where actions can be executed by wrong handlers due to missing type validation before BCS deserialization. You must add type checks BEFORE deserialization.

## 📦 Your Packages

1. **futarchy_actions** package (liquidity actions)
2. **futarchy_lifecycle** package (dissolution, streams, oracle, payments)
3. **futarchy_core** package (for imports)

## ✅ Prerequisites Already Complete

- `action_validation.move` helper exists in futarchy_core
- `action_types.move` with type markers exists in futarchy_core
- Developer guide available at FUTARCHY_ACTION_DEVELOPER_GUIDE.md

## 📋 Your Todo List

### File 1: liquidity_actions.move (futarchy_actions/sources/liquidity/liquidity_actions.move)
- [ ] Add imports for `action_validation` and `action_types`
- [ ] Fix ALL 8 liquidity action types with type validation:
  - CreatePoolAction
  - UpdatePoolParamsAction
  - AddLiquidityAction
  - RemoveLiquidityAction
  - SwapAction
  - CollectFeesAction
  - SetPoolEnabledAction
  - WithdrawFeesAction
- [ ] Add destruction functions for all 8 action types
- [ ] Update all do_ functions to use BCS reader pattern
- [ ] Add/fix new_ functions with serialize-then-destroy
- [ ] Add delete_ functions for cleanup

### File 2: dissolution_actions.move (futarchy_lifecycle/sources/dissolution/dissolution_actions.move)
- [ ] Add imports for `action_validation` and `action_types`
- [ ] Fix ALL 8 dissolution actions:
  - InitiateDissolutionAction
  - CancelDissolutionAction
  - DistributeAssetAction
  - TransferStreamsToTreasuryAction
  - CancelStreamsInBagAction
  - WithdrawAllCondLiquidityAction
  - WithdrawAllSpotLiquidityAction
  - FinalizeDissolutionAction
- [ ] Add destruction functions for all 8 action types
- [ ] Update all do_ functions with BCS validation
- [ ] Add delete_ functions

### File 3: stream_actions.move (futarchy_lifecycle/sources/payments/stream_actions.move)
- [ ] Add imports for `action_validation` and `action_types`
- [ ] Fix ALL 5 stream actions:
  - CreateStreamAction
  - CancelStreamAction
  - WithdrawStreamAction
  - CreateProjectStreamAction
  - CreateBudgetStreamAction
- [ ] Add destruction functions for all 5 action types
- [ ] Update all do_ functions with BCS validation
- [ ] Add delete_ functions

### File 4: oracle_actions.move (futarchy_lifecycle/sources/oracle/oracle_actions.move)
- [ ] Add imports for `action_validation` and `action_types`
- [ ] Fix oracle actions with type validation:
  - ReadOraclePriceAction
  - ConditionalMintAction (note: uses hot potato pattern)
  - TieredMintAction (note: uses hot potato pattern)
- [ ] Add destruction functions
- [ ] Handle hot potato ResourceRequest pattern correctly
- [ ] Add delete_ functions

### File 5: payment_actions.move (futarchy_lifecycle/sources/payments/payment_actions.move)
- [ ] Add imports for `action_validation` and `action_types`
- [ ] Fix all payment-related actions
- [ ] Add destruction functions
- [ ] Update do_ functions with BCS validation
- [ ] Add delete_ functions

### File 6: factory_with_init_actions.move (futarchy_lifecycle/sources/factory/factory_with_init_actions.move)
- [ ] Add imports for `action_validation` and `action_types`
- [ ] Fix factory initialization actions
- [ ] Add type validation for all factory actions
- [ ] Add destruction functions
- [ ] Ensure serialize-then-destroy pattern

### File 7: Update Financial Decoders
- [ ] Fix liquidity_decoder.move - replace deprecated type_name APIs
- [ ] Fix dissolution_decoder.move - replace deprecated type_name APIs
- [ ] Fix stream_decoder.move - replace deprecated type_name APIs
- [ ] Fix oracle_decoder.move - replace deprecated type_name APIs
- [ ] Fix payment_decoder.move - replace deprecated type_name APIs
- [ ] Replace all `type_name::get` → `type_name::with_defining_ids`
- [ ] Replace all `type_name::get_address` → `type_name::address_string`
- [ ] Replace all `type_name::get_module` → `type_name::module_string`

### File 8: Compilation Testing
- [ ] Test compilation of futarchy_lifecycle package
- [ ] Test compilation of futarchy_actions package (liquidity module)
- [ ] Ensure no compilation errors after changes

## 🔧 Pattern You Must Apply

### For Actions with Hot Potato (Oracle/Mint):
```move
public fun do_oracle_action<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    version: VersionWitness,
    intent_witness: IW,
): ResourceRequest<OracleAction> {  // Returns hot potato
    // Same validation pattern
    let specs = executable::intent(executable).action_specs();
    let spec = specs.borrow(executable::action_idx(executable));

    // CRITICAL: Type check first
    action_validation::assert_action_type<action_types::OracleAction>(spec);

    // ... deserialize safely ...

    // Return request for resources
    ResourceRequest<OracleAction> { ... }
}
```

### For Standard Actions:
```move
public fun do_action<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    version: VersionWitness,
    intent_witness: IW,
) {
    // Get spec and validate type BEFORE deserialization
    let specs = executable::intent(executable).action_specs();
    let spec = specs.borrow(executable::action_idx(executable));
    action_validation::assert_action_type<action_types::MyAction>(spec);

    let action_data = protocol_intents::action_spec_data(spec);

    // Safe BCS deserialization
    let mut reader = bcs::new(*action_data);
    // ... peel fields ...
    bcs_validation::validate_all_bytes_consumed(reader);

    // Execute and increment
    executable::increment_action_idx(executable);
}
```

## 📊 Your Deliverables

1. All 8 files fully migrated to secure pattern
2. ~29 action types properly secured (8 liquidity + 8 dissolution + 5 streams + 3 oracle + 5 other)
3. All packages compile without errors
4. Special handling for hot potato patterns preserved

## 🚀 Start Here

1. Begin with liquidity_actions.move (most complex with 8 actions)
2. Then dissolution_actions.move (critical for DAO shutdown)
3. Handle hot potato patterns carefully in oracle_actions.move
4. Complete one file fully before moving to next