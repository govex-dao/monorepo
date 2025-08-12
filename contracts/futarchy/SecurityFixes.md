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

