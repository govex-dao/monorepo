# Futarchy Actions Security Migration - Complete Todo List

## 🚨 Critical Security Context

### The Vulnerability
The Futarchy system currently has a **critical type confusion vulnerability** where actions can be executed by the wrong handlers because there's no type validation before BCS deserialization. This allows attackers to:
- Send a `TransferFunds` action to a `UpdateConfig` handler
- Bypass access controls and authorization
- Potentially drain funds or corrupt DAO state

### The Fix
Implement the same secure pattern used in Move Framework:
1. **Type validation BEFORE deserialization** using `action_validation::assert_action_type`
2. **Serialize-then-destroy pattern** to prevent resource leaks
3. **BCS validation** to ensure all bytes are consumed
4. **Type markers** for compile-time type safety

## 📊 Migration Scope

- **17 action files** across 6 packages
- **~100 different action types** to migrate
- **~500+ code changes** required
- **Critical for mainnet deployment**

## ✅ Completed Prerequisites

- [x] Created `action_validation.move` helper in futarchy_core
- [x] Created `action_types.move` with ~100 type markers
- [x] Created developer guide (FUTARCHY_ACTION_DEVELOPER_GUIDE.md)
- [x] Created migration plan (FUTARCHY_ACTIONS_MIGRATION_PLAN.md)
- [x] Created initial fix script (fix_futarchy_actions.sh)

## 📋 Detailed Migration Todo List

### Phase 1: High Priority Core Actions

#### Config Actions (futarchy_actions/sources/config/config_actions.move)
- [ ] **Task 1**: Add imports for `action_validation` and `action_types` modules
- [ ] **Task 2**: Replace `is_current_action` with `assert_action_type` for:
  - SetProposalsEnabledAction
  - UpdateNameAction
  - TradingParamsUpdateAction
  - MetadataUpdateAction
  - TwapConfigUpdateAction
  - GovernanceUpdateAction
  - MetadataTableUpdateAction
  - SlashDistributionUpdateAction
  - QueueParamsUpdateAction
- [ ] **Task 3**: Add destruction functions for all 9 action types
- [ ] **Task 4**: Update all do_ functions to use BCS reader pattern with validation
- [ ] **Task 5**: Add/fix new_ functions with serialize-then-destroy pattern
- [ ] **Task 6**: Add delete_ functions for cleanup from expired intents

#### Governance Actions (futarchy_actions/sources/governance/governance_actions.move)
- [ ] **Task 7**: Add imports and fix actions:
  - CreateProposalAction
  - ProposalReservationAction
  - Fix hot potato pattern for ResourceRequest

#### Platform Fee Actions (futarchy_actions/sources/governance/platform_fee_actions.move)
- [ ] **Task 8**: Add imports and fix:
  - CollectPlatformFeeAction
  - Replace `is_current_action` with type validation

#### Liquidity Actions (futarchy_actions/sources/liquidity/liquidity_actions.move)
- [ ] **Task 9**: Fix all 8 liquidity action types:
  - CreatePoolAction
  - UpdatePoolParamsAction
  - AddLiquidityAction
  - RemoveLiquidityAction
  - SwapAction
  - CollectFeesAction
  - SetPoolEnabledAction
  - WithdrawFeesAction

### Phase 2: Critical Financial Actions

#### Dissolution Actions (futarchy_lifecycle/sources/dissolution/dissolution_actions.move)
- [ ] **Task 10**: Fix all 8 dissolution actions:
  - InitiateDissolutionAction
  - CancelDissolutionAction
  - DistributeAssetAction
  - TransferStreamsToTreasuryAction
  - CancelStreamsInBagAction
  - WithdrawAllCondLiquidityAction
  - WithdrawAllSpotLiquidityAction
  - FinalizeDissolutionAction

#### Stream Actions (futarchy_lifecycle/sources/payments/stream_actions.move)
- [ ] **Task 11**: Fix all 5 stream actions:
  - CreateStreamAction
  - CancelStreamAction
  - WithdrawStreamAction
  - CreateProjectStreamAction
  - CreateBudgetStreamAction

#### Oracle Actions (futarchy_lifecycle/sources/oracle/oracle_actions.move)
- [ ] **Task 12**: Fix oracle actions:
  - ReadOraclePriceAction
  - ConditionalMintAction (hot potato pattern)
  - TieredMintAction (hot potato pattern)

### Phase 3: Supporting Actions

#### Memo Actions (futarchy_actions/sources/memo/memo_actions.move)
- [ ] **Task 13**: Fix memo actions:
  - EmitMemoAction
  - EmitDecisionAction

#### Operating Agreement Actions (futarchy_specialized_actions/sources/legal/operating_agreement_actions.move)
- [ ] **Task 14**: Fix all 7 agreement actions:
  - CreateOperatingAgreementAction
  - AddLineAction
  - RemoveLineAction
  - UpdateLineAction
  - BatchAddLinesAction
  - BatchRemoveLinesAction
  - LockOperatingAgreementAction

#### Custody Actions (futarchy_vault/sources/custody_actions.move)
- [ ] **Task 15**: Fix all 4 custody actions:
  - CreateCustodyAccountAction
  - CustodyDepositAction
  - CustodyWithdrawAction
  - CustodyTransferAction

#### Security Council Actions (futarchy_multisig/sources/security_council_actions.move)
- [ ] **Task 16**: Fix all 7 council actions:
  - CreateCouncilAction
  - AddCouncilMemberAction
  - RemoveCouncilMemberAction
  - UpdateCouncilThresholdAction
  - ProposeCouncilActionAction
  - ApproveCouncilActionAction
  - ExecuteCouncilActionAction

#### Policy Actions (futarchy_multisig/sources/policy/policy_actions.move)
- [ ] **Task 17**: Fix policy actions:
  - CreatePolicyAction
  - UpdatePolicyAction
  - RemovePolicyAction

#### Founder Lock Actions (futarchy_actions/sources/intent_lifecycle/founder_lock_actions.move)
- [ ] **Task 18**: Fix founder lock actions:
  - CreateFounderLockAction
  - UnlockFounderTokensAction

#### Protocol Admin Actions (futarchy_actions/sources/intent_lifecycle/protocol_admin_actions.move)
- [ ] **Task 19**: Fix all 7 admin actions:
  - SetFactoryPausedAction
  - AddStableTypeAction
  - RemoveStableTypeAction
  - UpdateDaoCreationFeeAction
  - UpdateProposalFeeAction
  - UpdateTreasuryAddressAction
  - WithdrawProtocolFeesAction

#### Payment Actions (futarchy_lifecycle/sources/payments/payment_actions.move)
- [ ] **Task 20**: Fix payment-related actions

#### Factory Init Actions (futarchy_lifecycle/sources/factory/factory_with_init_actions.move)
- [ ] **Task 21**: Fix factory initialization actions

#### Init Actions (futarchy_actions/sources/init_actions.move)
- [ ] **Task 22**: Fix initialization action patterns

### Phase 4: Technical Debt Cleanup

#### Decoder Updates
- [ ] **Task 23**: Update all decoder files (~20 files):
  - Replace `type_name::get` → `type_name::with_defining_ids`
  - Replace `type_name::get_address` → `type_name::address_string`
  - Replace `type_name::get_module` → `type_name::module_string`

#### BCS Validation
- [ ] **Task 24**: Add `bcs_validation::validate_all_bytes_consumed` to all do_ functions

### Phase 5: Testing & Validation

#### Package Compilation Tests
- [ ] **Task 25**: Test compilation of futarchy_core package
- [ ] **Task 26**: Test compilation of futarchy_actions package
- [ ] **Task 27**: Test compilation of futarchy_lifecycle package
- [ ] **Task 28**: Test compilation of futarchy_multisig package
- [ ] **Task 29**: Test compilation of futarchy_specialized_actions package
- [ ] **Task 30**: Test compilation of futarchy_vault package
- [ ] **Task 31**: Test compilation of futarchy_dao package

#### Test Suite
- [ ] **Task 32**: Write unit tests for type safety in each action module
- [ ] **Task 33**: Run full test suite across all packages
- [ ] **Task 34**: Test wrong action type rejection (negative tests)
- [ ] **Task 35**: Document migration completion and results

## 🔧 Pattern to Apply for Each Action

### Before (Vulnerable):
```move
public fun do_action<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    version: VersionWitness,
    intent_witness: IW,
) {
    // VULNERABLE: Type check after deserialization
    assert!(executable::is_current_action<Outcome, MyAction>(executable), EWrongAction);

    // Deserialize without validation
    let action = my_action_from_bytes(*action_data);

    // Execute...
}
```

### After (Secure):
```move
public fun do_action<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    version: VersionWitness,
    intent_witness: IW,
) {
    // Get action spec
    let specs = executable::intent(executable).action_specs();
    let spec = specs.borrow(executable::action_idx(executable));

    // CRITICAL: Type check BEFORE deserialization
    action_validation::assert_action_type<action_types::MyAction>(spec);

    let action_data = protocol_intents::action_spec_data(spec);

    // Version check
    let spec_version = protocol_intents::action_spec_version(spec);
    assert!(spec_version == 1, EUnsupportedActionVersion);

    // Safe deserialization with BCS reader
    let mut reader = bcs::new(*action_data);
    let field1 = bcs::peel_vec_u8(&mut reader).to_string();
    let field2 = bcs::peel_u64(&mut reader);

    // Validate all bytes consumed
    bcs_validation::validate_all_bytes_consumed(reader);

    // Execute...

    // Increment action index
    executable::increment_action_idx(executable);
}
```

## 📈 Progress Tracking

| Phase | Tasks | Status | Priority |
|-------|-------|--------|----------|
| Prerequisites | Setup | ✅ Complete | - |
| Phase 1 | Tasks 1-9 | ⏳ Pending | 🔴 Critical |
| Phase 2 | Tasks 10-12 | ⏳ Pending | 🔴 Critical |
| Phase 3 | Tasks 13-22 | ⏳ Pending | 🟡 High |
| Phase 4 | Tasks 23-24 | ⏳ Pending | 🟡 High |
| Phase 5 | Tasks 25-35 | ⏳ Pending | 🟢 Required |

## 🎯 Success Criteria

1. **All actions validate type before deserialization**
2. **No deprecated APIs used**
3. **All packages compile without errors**
4. **Type confusion attacks are prevented**
5. **Test suite passes with 100% coverage**
6. **Ready for mainnet deployment**

## 📝 Notes

- Each task should be completed and tested individually
- Commit after each file is successfully migrated
- Run compilation tests frequently to catch issues early
- Use the developer guide for reference on patterns
- Document any deviations or special cases

## 🚀 Getting Started

1. Start with Task 1: Fix config_actions.move imports
2. Use the pattern examples above as templates
3. Test compilation after each major change
4. Check off tasks as completed
5. Update this document with any issues or learnings

This migration is **critical for security** and must be completed before mainnet deployment.