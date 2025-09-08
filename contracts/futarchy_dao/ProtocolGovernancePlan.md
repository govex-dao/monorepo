# Protocol Governance Plan

## Goal
Enable the futarchy protocol to be governed by one of its own DAOs (dogfooding), allowing the owner DAO and its security council to control all platform admin functions.

## Current State

### Existing Admin Capabilities
1. **FeeAdminCap** - Controls fee management (in `fee.move`)
   - Update DAO creation fees
   - Update proposal creation fees  
   - Update monthly platform fees
   - Withdraw collected fees
   - Apply discounts

2. **FactoryOwnerCap** - Controls factory settings (in `factory.move`)
   - Pause/unpause factory
   - Add/remove allowed stable types
   - Control DAO creation parameters

3. **ValidatorAdminCap** - Controls DAO verification (in `factory.move`)
   - Verify DAOs for special privileges
   - Manage validator list

### Problems with Current Design
- [ ] Three separate admin caps are complex to manage
- [ ] No clear path for a DAO to hold and use these caps
- [ ] No security council emergency powers
- [ ] Caps are transferred to deployer, not to a DAO

## Proposed Solution

### Phase 1: Three-Tier Admin System
Keep three separate admin caps with clear separation of concerns:

1. **FinancialAdminCap** (High Risk - DAO Governance)
   - Withdraw platform fees
   - Update fee amounts
   - Apply discounts
   - Access to treasury
   
2. **ValidatorAdminCap** (Low Risk - Security Council)
   - Verify DAOs
   - Manage validator list
   - Emergency pause
   - No financial access
   
3. **FactoryAdminCap** (Medium Risk - DAO or Separate)
   - Add/remove stable types
   - Update factory parameters
   - Control DAO creation settings
   - No direct financial access

### Phase 2: DAO Integration
- [ ] Owner DAO stores `FinancialAdminCap` using Account's `owned` module
- [ ] Create financial governance actions that use `owned::withdraw` to access cap
- [ ] Owner DAO stores `FactoryOwnerCap` (or delegate to sub-DAO)
- [ ] Create factory governance actions using Account Protocol patterns

### Phase 3: Security Council Integration  
- [ ] Security Council's Account holds `ValidatorAdminCap` in `owned`
- [ ] Council can directly execute without governance:
  - [ ] Emergency factory pause
  - [ ] DAO verification/de-verification
  - [ ] NO access to fees or financial functions
- [ ] Use Account Protocol's role system for council members

## Implementation Checklist

### Step 1: Refactor Admin Capabilities
- [ ] Rename current caps for clarity:
  - [ ] `FeeAdminCap` → `FinancialAdminCap` 
  - [ ] `FactoryOwnerCap` → Keep as is (already clear)
  - [ ] `ValidatorAdminCap` → Keep as is (already clear)
- [ ] These caps should be stored in Move framework Account's `owned` module
- [ ] Use Account Protocol's native capability storage

### Step 2: Update Existing Modules
- [ ] Update `fee.move`:
  - [ ] Add `protocol_admin_id: ID` field to FeeManager
  - [ ] Change all admin functions to accept `ProtocolAdminCap`
  - [ ] Add migration function to set protocol_admin_id
  - [ ] Keep old functions with deprecation notice

- [ ] Update `factory.move`:
  - [ ] Add `protocol_admin_id: ID` field to Factory  
  - [ ] Change all admin functions to accept `ProtocolAdminCap`
  - [ ] Merge ValidatorAdminCap functionality
  - [ ] Add migration function

### Step 3: Create Governance Actions
- [ ] Create `financial_governance_actions.move`:
  - [ ] Actions for fee updates and withdrawals
  - [ ] Use `owned::withdraw` to get `FinancialAdminCap` from Account
  - [ ] Return cap to Account after use
  
- [ ] Create `factory_governance_actions.move`:
  - [ ] Actions for factory configuration
  - [ ] Use `owned::withdraw` to get `FactoryOwnerCap` from Account
  - [ ] Return cap to Account after use

- [ ] Security council doesn't need actions (direct execution)

### Step 4: Add Dispatcher Support
- [ ] Add to `action_dispatcher.move`:
  - [ ] Import protocol governance module
  - [ ] Create `execute_protocol_governance` function
  - [ ] Handle resource requirements (Factory, FeeManager)

### Step 5: Security Council Integration
- [ ] Add `security_council_actions.move`:
  - [ ] Emergency pause action
  - [ ] Limited fee withdrawal action
  - [ ] Override mechanisms with time locks
  - [ ] Multi-sig support if needed

### Step 6: Migration Path
- [ ] Create migration entry function that:
  - [ ] Creates new ProtocolAdminCap
  - [ ] Updates Factory and FeeManager with new cap ID
  - [ ] Burns old caps (optional)
  - [ ] Transfers new cap to owner DAO

## Benefits of Three-Cap Design

1. **Separation of Concerns**: Financial, operational, and emergency powers separated
2. **Risk Management**: High-risk financial operations require full governance
3. **Fast Emergency Response**: Security council can pause without touching funds
4. **Native Integration**: Uses Account Protocol's built-in `owned` module
5. **Dogfooding**: Protocol governed by its own futarchy system
6. **Flexibility**: Each cap can be held by different entities based on risk

## Risks and Mitigations

| Risk | Mitigation |
|------|------------|
| Loss of admin cap | Security council backup access |
| DAO becomes malicious | Time delays, council veto power |
| Migration fails | Keep old caps functional during transition |
| Emergency response too slow | Council fast-track for critical issues |

## Timeline

1. **Week 1**: Implement unified admin cap
2. **Week 2**: Update existing modules
3. **Week 3**: Create governance actions
4. **Week 4**: Test and deploy

## Open Questions

- [ ] Should security council have veto power over normal governance?
- [ ] What time delays for different action types?
- [ ] Should some functions remain permanently with deployer?
- [ ] How to handle protocol upgrades (Move framework handles)?
- [ ] Should fee withdrawal go to DAO treasury or separate address?

## Next Steps

1. Review and approve this plan
2. Start with Step 1: Create unified admin module
3. Test on devnet before mainnet migration