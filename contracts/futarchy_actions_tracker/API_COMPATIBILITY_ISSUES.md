# Futarchy DAO API Compatibility Issues

## Summary
After the package split of `futarchy_markets` into `futarchy_markets_core` and `futarchy_markets_operations`, the `proposal_lifecycle.move` module has extensive API incompatibilities that require significant refactoring.

## Issues Found

### 1. Missing Execution Module
**File**: `proposal_lifecycle.move` lines 148, 622, 678
**Issue**: Calls to `execute::run_with_governance()` and `execute::run_all()` don't exist
**Root Cause**: The `execute` module was renamed to `ptb_executor` and uses a different pattern
**Fix Required**: Remove these calls; the new PTB-based pattern doesn't use a centralized executor

### 2. Missing Config Function
**File**: `proposal_lifecycle.move` line 238
**Issue**: `futarchy_config::conditional_liquidity_ratio_bps()` doesn't exist
**Root Cause**: This is not a config getter - it's a parameter to `proposal::initialize_market()`
**Fix Required**: Either:
  - Calculate/determine the value and pass it to `initialize_market()`
  - Or default to a reasonable value (e.g., 5000 = 50%)

### 3. Wrong `authenticate()` Signature
**File**: `proposal_lifecycle.move` line 479
**Issue**: Missing `ctx` parameter
**Current**: `futarchy_config::authenticate(account)`
**Correct**: `futarchy_config::authenticate(account, ctx)`

### 4. Wrong `initialize_market()` Signature  
**File**: `proposal_lifecycle.move` line 247
**Issue**: Too few arguments - missing `conditional_liquidity_ratio_bps` parameter
**Fix**: Add the parameter at position 12 (after `amm_total_fee_bps`)

### 5. Wrong `get_pool_mut_by_outcome()` Signature
**File**: `proposal_lifecycle.move` line 345
**Issue**: Missing `escrow` parameter
**Current**: `proposal::get_pool_mut_by_outcome(proposal, winning_outcome as u8)`
**Correct**: `proposal::get_pool_mut_by_outcome(proposal, escrow, winning_outcome as u8)`
**Problem**: proposal_lifecycle doesn't have access to the escrow object

### 6. Wrong `get_twaps_for_proposal()` Signature
**File**: `proposal_lifecycle.move` line 1048
**Issue**: Missing `escrow` parameter  
**Current**: `proposal::get_twaps_for_proposal(proposal, clock)`
**Correct**: `proposal::get_twaps_for_proposal(proposal, escrow, clock)`
**Problem**: proposal_lifecycle doesn't have access to the escrow object

### 7. Wrong `calculate_current_winner()` Signature
**File**: `proposal_lifecycle.move` line 528
**Issue**: Missing `escrow` parameter
**Current**: `proposal::calculate_current_winner(proposal, clock)`
**Correct**: `proposal::calculate_current_winner(proposal, escrow, clock)`
**Problem**: proposal_lifecycle doesn't have access to the escrow object

### 8. Missing Early Resolve Functions
**File**: `proposal_lifecycle.move` lines 518, 528, 559, 572
**Issue**: These functions don't exist:
  - `proposal::check_early_resolve_eligibility()`
  - `proposal_fee_manager::pay_keeper_reward()`
  - `proposal::ProposalEarlyResolved` struct
**Fix**: These need to be checked in the actual modules to find correct names/locations

### 9. Move Language Issue: Option<&mut T> (RESOLVED)
**Status**: Fixed - SubsidyEscrow system has been completely removed
**Previous Issue**: Move doesn't allow mutable references in Option types

## Recommended Approach

Given the extent of these issues, there are two options:

### Option A: Architectural Fix (Recommended)
The `proposal_lifecycle` module needs access to the `TokenEscrow` object for many operations. The functions should be refactored to accept `escrow: &mut TokenEscrow<AssetType, StableType>` as a parameter.

### Option B: Quick Fix
Comment out or stub the problematic functions with TODOs and fix them incrementally as the API stabilizes.

## Files Requiring Changes
1. `/Users/admin/monorepo/contracts/futarchy_dao/sources/dao/governance/proposal_lifecycle.move`
2. Potentially other files that depend on proposal_lifecycle

## Status
- ✅ Fixed: 6 packages (oracle, factory, governance_actions, legal_actions, actions)
- ⏳ In Progress: futarchy_dao (proposal_lifecycle API mismatches)

