# Policy System Implementation - Detailed Task List

## Phase 1: Revert PolicyRequirement to Inline Storage (HIGH PRIORITY)

### 1.1 Delete PolicyRequirement Module
- [ ] Delete `futarchy_multisig/sources/policy/policy_requirement.move`
- [ ] Remove from `futarchy_multisig/Move.toml` dependencies (if added)
- [ ] Remove imports from files that use it

### 1.2 Revert QueuedProposal (priority_queue.move)
- [ ] Replace `policy_requirement_id: ID` with three fields:
  - [ ] `policy_mode: u8`
  - [ ] `required_council_id: Option<ID>`
  - [ ] `council_approval_proof: Option<ID>`
- [ ] Update `new_queued_proposal()` signature (3 params instead of 1 ID)
- [ ] Update `new_queued_proposal_with_bond()` signature
- [ ] Update getter: `get_policy_requirement_id()` → 3 separate getters
- [ ] Update destructor in eviction flow (3 fields instead of 1)
- [ ] Update destructor in timeout flow
- [ ] Update destructor in extraction flow

### 1.3 Revert Proposal (proposal.move)
- [ ] Replace `policy_requirement_ids: vector<ID>` with three vectors:
  - [ ] `policy_modes: vector<u8>`
  - [ ] `required_council_ids: vector<Option<ID>>`
  - [ ] `council_approval_proofs: vector<Option<ID>>`
- [ ] Update `new_proposal()` initialization (3 empty vectors)
- [ ] Update `new_proposal_with_liquidity()` initialization
- [ ] Update `add_outcome()` to push to 3 vectors (not 1)
- [ ] Update `set_intent_spec_for_outcome()` signature (3 params instead of 1 ID)
- [ ] Update getters:
  - [ ] `get_policy_requirement_id_for_outcome()` → 3 separate getters
  - [ ] `get_all_policy_requirement_ids()` → 3 separate getters
- [ ] Update any outcome removal logic

### 1.4 Revert ProposalReservation (governance_actions.move)
- [ ] Replace `policy_requirement_id: ID` with three fields in struct:
  - [ ] `policy_mode: u8`
  - [ ] `required_council_id: Option<ID>`
  - [ ] `council_approval_proof: Option<ID>`
- [ ] Update `create_reservation()` signature (3 params instead of 1 ID)
- [ ] Update `create_queued_proposal_from_reservation()` to pass 3 fields
- [ ] Update destructor (3 fields instead of 1)

### 1.5 Revert Proposal Creation Logic (governance_actions.move)
- [ ] Remove `policy_requirement::create_and_share()` calls
- [ ] Remove `policy_requirement::create_dao_only()` calls
- [ ] Remove `use futarchy_multisig::policy_requirement` import
- [ ] Change policy analysis loop to store inline values directly:
  - [ ] Extract mode, council_id_opt, approval_proof_opt
  - [ ] Store in local variables (not create shared objects)
  - [ ] Build vectors for Proposal (3 vectors of values)
  - [ ] Use first entry for QueuedProposal (3 scalar values)
  - [ ] Use first entry for ProposalReservation (3 scalar values)
- [ ] Update `create_queued_proposal_with_id()` call (3 params)
- [ ] Update `create_reservation()` call (3 params)
- [ ] Update helper functions that use policy data

### 1.6 Revert Execution Validation (governance_intents.move)
- [ ] Replace `proposal::get_policy_requirement_id_for_outcome()` call
- [ ] Add direct field access for validation:
  - [ ] Get policy mode from proposal
  - [ ] Get required_council_id from proposal
  - [ ] Get council_approval_proof from proposal
- [ ] Update validation logic (check mode directly, not ID != 0x0)
- [ ] Update comments to reflect inline storage

### 1.7 Build & Test
- [ ] Build futarchy_core package
- [ ] Build futarchy_markets package
- [ ] Build futarchy_actions package
- [ ] Build futarchy_governance_actions package
- [ ] Build futarchy_multisig package
- [ ] Run tests for priority_queue
- [ ] Run tests for proposal
- [ ] Run tests for governance_actions
- [ ] Verify no regressions

---

## Phase 2: Complete Type-Level Policy Migration (MEDIUM PRIORITY)

### 2.1 Discovery Phase
- [ ] Find all parameterized action structs in Move Framework
- [ ] Find all parameterized action structs in Futarchy packages
- [ ] Create inventory list with files and line numbers
- [ ] Categorize by: has `drop`, needs `drop`, no phantom params

### 2.2 Move Framework - Currency Actions
- [ ] `currency.move::DisableAction<CoinType>` - Add `drop` ability
- [ ] `currency.move::DisableAction<CoinType>` - Update `new_disable()` registration
- [ ] `currency.move::DisableAction<CoinType>` - Remove destroy function
- [ ] `currency.move::UpdateAction<CoinType>` - Add `drop` ability
- [ ] `currency.move::UpdateAction<CoinType>` - Update `new_update()` registration
- [ ] `currency.move::UpdateAction<CoinType>` - Remove destroy function
- [ ] Build and test

### 2.3 Move Framework - Owned Actions
- [ ] Check if `owned.move` has parameterized actions
- [ ] If yes, migrate following same pattern
- [ ] Build and test

### 2.4 Move Framework - Vesting Actions
- [ ] Check `vesting.move` for additional parameterized actions
- [ ] Migrate any found actions
- [ ] Build and test

### 2.5 Move Framework - Transfer Actions
- [ ] Check `transfer.move` for coin-type parameters
- [ ] Migrate any found actions
- [ ] Build and test

### 2.6 Futarchy - Stream Actions Discovery
- [ ] `stream_actions.move::CreateStreamAction<CoinType>` - Check if has `drop`
- [ ] `stream_actions.move::CreatePaymentAction<CoinType>` - Check if has `drop`
- [ ] `stream_actions.move::RequestWithdrawalAction<CoinType>` - Check if has `drop`
- [ ] `stream_actions.move::ProcessPendingWithdrawalAction<CoinType>` - Check if has `drop`
- [ ] `stream_actions.move::ExecutePaymentAction<CoinType>` - Check if has `drop`
- [ ] List all other stream actions with CoinType

### 2.7 Futarchy - Stream Actions Migration
- [ ] For each stream action:
  - [ ] Add `drop` ability if needed
  - [ ] Update `new_*()` function to use action as witness
  - [ ] Remove destroy function
  - [ ] Update tests if needed
- [ ] Build and test futarchy_streams package

### 2.8 Futarchy - Oracle Actions Discovery
- [ ] List all oracle actions with `phantom CoinType`
- [ ] Check which have `drop` ability
- [ ] Note: oracle_actions.move location

### 2.9 Futarchy - Oracle Actions Migration
- [ ] For each oracle action:
  - [ ] Add `drop` ability if needed
  - [ ] Update registration
  - [ ] Remove destroy function
- [ ] Build and test futarchy_lifecycle package

### 2.10 Futarchy - Liquidity Actions Discovery
- [ ] `CreatePoolAction<AssetType, StableType>` - Note multi-param
- [ ] `AddLiquidityAction<AssetType, StableType>`
- [ ] `RemoveLiquidityAction<AssetType, StableType>`
- [ ] Other liquidity actions
- [ ] Check which have `drop` ability

### 2.11 Futarchy - Liquidity Actions Migration
- [ ] For each liquidity action:
  - [ ] Add `drop` ability if needed
  - [ ] Update registration (preserves both type params)
  - [ ] Remove destroy function
- [ ] Build and test futarchy_actions package

### 2.12 Futarchy - Dissolution Actions Discovery
- [ ] Check `dissolution_actions.move` for parameterized actions
- [ ] List actions with CoinType parameters

### 2.13 Futarchy - Dissolution Actions Migration
- [ ] For each dissolution action:
  - [ ] Add `drop` ability if needed
  - [ ] Update registration
  - [ ] Remove destroy function
- [ ] Build and test

### 2.14 Futarchy - Remaining Actions Discovery
- [ ] Check all other futarchy packages for parameterized actions
- [ ] List: founder lock, dividends, commitment actions
- [ ] Create comprehensive list

### 2.15 Futarchy - Remaining Actions Migration
- [ ] Migrate all remaining actions
- [ ] Build and test each package

### 2.16 Policy Analyzer Updates
- [ ] Add `VaultDeposit` to `try_extract_coin_type()`
- [ ] Add `VestingCreate` to `try_extract_coin_type()` (complex - many fields)
- [ ] Add stream actions to coin type extraction
- [ ] Add oracle actions to coin type extraction
- [ ] Add liquidity actions (extract first type param)
- [ ] Create `try_extract_cap_type()` for access control
- [ ] Update `analyze_requirements_comprehensive()` to use cap type
- [ ] Build and test futarchy_multisig

### 2.17 Integration Testing
- [ ] Test: Different policies for SUI vs USDC spending
- [ ] Test: OBJECT policy overrides TYPE policy
- [ ] Test: TYPE policy overrides ACTION policy
- [ ] Test: Multi-type actions (pool creation with AssetType)
- [ ] Test: Capability type policies (borrow AdminCap vs UserCap)
- [ ] Create end-to-end test scenarios

### 2.18 Documentation
- [ ] Update CLAUDE.md with type-level policy examples
- [ ] Update policy system documentation
- [ ] Add example policies to tests
- [ ] Document new action template pattern

---

## Phase 3: Add Execution-Time Enforcement (LOW PRIORITY)

### 3.1 Add Validation in proposal_lifecycle.move
- [ ] Locate `execute_approved_proposal_with_fee()` function
- [ ] Add policy mode check before execution
- [ ] Add council approval proof validation
- [ ] Add error code: `EPolicyViolation`

### 3.2 Implement Validation Logic
- [ ] Get policy mode from proposal (direct field access)
- [ ] If mode == 3 (MODE_DAO_AND_COUNCIL):
  - [ ] Assert council_approval_proof.is_some()
  - [ ] Optionally: validate ApprovedIntentSpec still exists
  - [ ] Optionally: validate ApprovedIntentSpec not revoked
- [ ] Add comments explaining defense-in-depth

### 3.3 Testing
- [ ] Test: MODE_DAO_ONLY executes without council approval
- [ ] Test: MODE_DAO_AND_COUNCIL requires proof at execution
- [ ] Test: Missing proof aborts with EPolicyViolation
- [ ] Test: Valid proof allows execution

### 3.4 Documentation
- [ ] Document execution-time validation
- [ ] Update security model documentation
- [ ] Add defense-in-depth explanation

---

## Final Checklist

### Code Quality
- [ ] All packages build without errors
- [ ] All packages build without warnings
- [ ] All tests pass
- [ ] No regressions in existing functionality

### Documentation
- [ ] POLICY_SYSTEM_PLAN.md is accurate
- [ ] CLAUDE.md updated with policy system details
- [ ] Inline code comments are clear
- [ ] Security properties documented

### Testing
- [ ] Unit tests for policy storage
- [ ] Unit tests for policy hierarchy
- [ ] Integration tests for type-level policies
- [ ] End-to-end tests for council approval flow
- [ ] Execution-time enforcement tests

### Git
- [ ] Commit Phase 1 changes
- [ ] Commit Phase 2 changes
- [ ] Commit Phase 3 changes
- [ ] Update relevant documentation files

---

## Progress Tracking

**Phase 1 Status**: ⏳ Not Started
**Phase 2 Status**: ⏳ Not Started
**Phase 3 Status**: ⏳ Not Started

**Total Tasks**: 122
**Completed**: 0
**Remaining**: 122

---

## Notes

- Focus on Phase 1 first - it's the most critical
- Phase 2 can be done incrementally (package by package)
- Phase 3 can wait until Phase 1 & 2 are complete
- Test after every major change
- Commit frequently with descriptive messages
