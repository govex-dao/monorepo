# Security Fixes Todo List

## P0 - Critical Issues (Must Fix)

### 1. [x] Fix arithmetic overflow in mul_div_to_128
**File**: `sources/math.move`
**Issue**: Multiplying two u128 values directly will overflow. Need to use u256 for intermediate product.
**Fix**: Change `a_128 * b_128` to use u256 like other functions (mul_div_mixed, calculate_output)

### 2. [x] Fix AMM initial LP supply logic inconsistency
**File**: `sources/core/amm.move`
**Issue**: Comment says minimum LP is locked for first provider, but code just returns k with no lock/burn
**Fix**: Either implement MINIMUM_LIQUIDITY lock (like Uniswap) or update documentation to match actual behavior

### 3. [x] Standardize type identity on TypeName
**Files**: `sources/factory.move`, `sources/futarchy_vault.move`
**Issue**: Factory uses UTF8String from type_name::get_with_original_ids, vault uses VecSet<TypeName>
**Fix**: Use TypeName everywhere for type checking, only convert to string for events/display

## P1 - Important Issues

### 4. [x] Replace placeholder IDs created via object::id_from_address(@0x0)
**Files**: Multiple locations in codebase
**Issue**: Using @0x0-derived IDs as sentinels is brittle
**Fix**: Use Option<ID> = none instead, only set to some(valid_id) once created

### 5. [ ] Fix AMM fee accounting and protocol fee semantics
**File**: `sources/core/amm.move`
**Issue**: Fee split is asymmetrical - LP portion in reserves, protocol portion tracked separately
**Fix**: Verify K-invariant is maintained, add tests for conservation and fee capture

### 6. [ ] Clarify stream execution path split
**File**: `sources/actions/stream_actions.move`
**Issue**: Validation-only vs with_coin flows are confusing
**Fix**: Document clearly or unify the execution pattern

### 7. [ ] Verify transfer to account object address pattern
**Files**: Multiple locations
**Issue**: Coins transferred to object::id_address(account) might not be recoverable
**Fix**: Verify this matches account_protocol's custody model, add documentation

### 8. [ ] Optimize event payload sizes
**Files**: Various event definitions
**Issue**: Some events carry large vectors that could blow up gas costs
**Fix**: Consider pagination or delta events for large state changes

## P2 - Design Consistency

### 9. [ ] Standardize share_object vs public_share_object usage
**Files**: Throughout codebase
**Issue**: Mixed usage patterns
**Fix**: Pick one and standardize

### 10. [ ] Reduce duplicate test vs prod creation code
**Files**: Various modules with test helpers
**Issue**: Duplication increases divergence risk
**Fix**: Create shared helpers

### 11. [ ] Document error codes
**Files**: All modules with error constants
**Issue**: No documentation for error meanings
**Fix**: Add comments explaining each error

### 12. [ ] Remove decimal assumptions
**Files**: Various comments assuming 6 decimals
**Issue**: Hardcoded assumptions about coin decimals
**Fix**: Make decimal handling generic or store metadata

## Additional Critical Issues

### 13. [x] Fix priority queue bond handling bug on eviction
**File**: `sources/utils/priority_queue.move` (line ~399)
**Issue**: On eviction, unconditionally calls bond.destroy_none() which aborts if bond is Some
**Fix**: Handle Some/None explicitly - if Some, extract and slash/refund; if None, destroy_none()

### 14. [x] Fix swap fee asymmetry in account_spot_pool
**File**: `sources/core/account_spot_pool.move`
**Issue**: swap_asset_to_stable applies fee on output, swap_stable_to_asset applies fee on input
**Fix**: Verified both already use fee-on-input consistently via calculate_output function

### 15. [x] Remove sentinel IDs in DAO creation
**File**: `sources/factory.move` (create_dao_internal_with_extensions)
**Issue**: Uses object::id_from_address(@0x0) for temp_queue_id and temp_dao_pool_id
**Fix**: Use Option<ID> = none for unset values, only set some(real_id) once object exists

### 16. [x] Fix dispatcher partial execution confirmation
**File**: `sources/actions/action_dispatcher.move`
**Issue**: Can call confirm_execution after breaking on unknown action type, leaving actions unexecuted
**Fix**: Assert no remaining actions before confirm_execution or explicitly abort on unknown types

### 17. [x] Make payment IDs robust
**File**: `sources/actions/stream_actions.move` (generate_payment_id)
**Issue**: Ad-hoc string scheme has collision risk
**Fix**: Generate UID via object::new(ctx) and use that ID as payment_id

### 18. [x] Secure unverified account creation path
**File**: `sources/core/futarchy_config.move` (new_account_unverified)
**Issue**: Bypasses Extensions registry checks if misused
**Fix**: Updated factory.move to use new_account_with_extensions instead of new_account_unverified

### 19. [x] Fix proposal ID mismatch issue
**File**: `sources/core/proposal.move` (initialize_market)
**Issue**: Creates new on-chain Proposal but returns caller's parameter proposal_id, causing confusion
**Fix**: Return actual on-chain proposal ID, maintain clear mapping via events/storage

## Testing Requirements

- [ ] Run `sui move test --silence-warnings` after each fix
- [ ] Ensure all 285 tests still pass
- [ ] Add specific tests for fixed vulnerabilities