# Futarchy Markets Core - Comprehensive Testing Plan

## Overview

This document tracks the comprehensive testing effort for all modules in `futarchy_markets_core`. The goal is to achieve professional-level test coverage as a principal engineer, using real test helpers without mocking, following the patterns established in `coin_registry_tests.move`.

## Testing Philosophy

### Core Principles
1. **No Mocking** - Use real objects and state where possible
2. **Test Helpers** - Create helpers for complex setup (like coin initialization)
3. **Real Scenario Testing** - Test actual usage patterns, not just happy paths
4. **Error Testing** - Comprehensive coverage of error conditions
5. **Edge Cases** - Test boundaries, zero values, maximum values
6. **Integration Points** - Test how modules interact with dependencies

### Reference Pattern: coin_registry_tests.move

Key patterns to follow from the reference test file:

```move
// 1. Test helper for coin initialization
futarchy_one_shot_utils::test_coin_a::init_for_testing(ts::ctx(&mut scenario));

// 2. Proper scenario setup
let mut scenario = ts::begin(@0x1);
ts::next_tx(&mut scenario, @0x1);

// 3. Take objects from sender
let treasury_cap = ts::take_from_sender<TreasuryCap<TEST_COIN_A>>(&scenario);

// 4. Test structure: Create, Act, Assert, Cleanup
let registry = coin_registry::create_registry(ctx);
coin_registry::deposit_coin_set(...);
assert!(coin_registry::total_sets(&registry) == 1, 0);
sui::test_utils::destroy(registry);

// 5. Error testing with expected_failure
#[test]
#[expected_failure(abort_code = 1)] // EInsufficientFee
fun test_insufficient_fee() { ... }
```

## Module Testing Status

### ✅ Completed
- **arbitrage_math.move** - Already has comprehensive tests including fuzzing and benchmarks

### 🔨 In Progress
- [Track using todo list]

### 📋 Pending Tests

#### 1. arbitrage.move
**Purpose**: Unified arbitrage system entry points for ANY outcome count

**Key Functions to Test**:
- `execute_optimal_spot_arbitrage()` - Main arbitrage function
- `execute_spot_arb_stable_to_asset_direction()` - Stable→Asset arbitrage
- `execute_spot_arb_asset_to_stable_direction()` - Asset→Stable arbitrage
- `burn_complete_set_and_withdraw_stable()` - Complete set burning
- `burn_complete_set_and_withdraw_asset()` - Complete set burning

**Test Scenarios**:
- Basic arbitrage with 2 outcomes
- Arbitrage with 3, 4, 5 outcomes (same function!)
- Both directions (stable→asset, asset→stable)
- Minimum profit validation
- Dust handling (registry vs balance return)
- Zero amount errors
- Insufficient profit errors
- Market state validation

**Dependencies**: UnifiedSpotPool, TokenEscrow, ConditionalMarketBalance, SwapSession

---

#### 2. arbitrage_core.move
**Purpose**: Core arbitrage algorithms and validation logic

**Key Functions to Test**:
- `validate_profitable()` - Profitability checks
- `spot_swap_stable_to_asset()` - Spot pool swaps
- `spot_swap_asset_to_stable()` - Spot pool swaps
- `deposit_asset_for_quantum_mint()` - Quantum minting
- `deposit_stable_for_quantum_mint()` - Quantum minting
- `find_min_value()` - Minimum finding across vector
- `withdraw_stable()`, `withdraw_asset()` - Withdrawals
- `burn_and_withdraw_conditional_asset()` - Conditional burning
- `burn_and_withdraw_conditional_stable()` - Conditional burning

**Test Scenarios**:
- Validate profitable with different market conditions
- Quantum minting (1 spot → N conditional)
- Finding minimum across multiple coins
- Burning and withdrawing conditionals
- Insufficient profit validation
- Edge cases with zero values

**Dependencies**: UnifiedSpotPool, TokenEscrow, SwapPositionRegistry

---

#### 3. conditional/subsidy_escrow.move
**Purpose**: Subsidy escrow execution for conditional AMMs

**Key Functions to Test**:
- `create_escrow()` - Escrow creation
- `crank_subsidy()` - Keeper cranking (permissionless)
- `finalize_escrow()` - Return remainder to treasury
- `destroy_escrow()` - Cleanup
- `inject_subsidy_proportional()` - Proportional injection
- Getters: `escrow_proposal_id()`, `escrow_total_subsidy()`, etc.

**Test Scenarios**:
- Create escrow with proper config
- Crank subsidy multiple times
- Rate limiting (MIN_CRANK_INTERVAL_MS = 5 minutes)
- Keeper fee calculation and payment
- Proportional subsidy injection (maintains price ratio)
- Finalize and return remainder
- Destroy after finalization
- Error cases:
  - Zero subsidy
  - Subsidy exhausted
  - Proposal mismatch
  - AMM mismatch
  - Too early crank
  - Finalized escrow

**Dependencies**: ProtocolSubsidyConfig, LiquidityPool, Clock

**Important Details**:
- Flat keeper fee per crank (0.1 SUI default)
- Subsidy distributed evenly across all outcomes
- Must maintain price ratio when adding liquidity
- TWAP update after each injection

---

#### 4. early_resolve.move
**Purpose**: Early proposal resolution before natural expiry

**Test Scenarios**:
- Early resolution triggering
- State transitions
- Payout calculations
- Authorization checks

---

#### 5. fee.move
**Purpose**: Fee management for protocol operations

**Test Scenarios**:
- Fee collection
- Fee distribution
- Fee configuration updates
- Multiple fee types

---

#### 6. liquidity_initialize.move
**Purpose**: Initial liquidity setup for new pools

**Test Scenarios**:
- First liquidity provision
- LP token minting
- Reserve initialization
- Minimum liquidity requirements

---

#### 7. proposal.move
**Purpose**: Proposal market lifecycle management

**Test Scenarios**:
- Proposal creation
- State transitions (PENDING → TRADING → PASSED/FAILED → EXECUTED)
- Voting mechanisms
- Resolution logic
- Market finalization

---

#### 8. quantum_lp_manager.move
**Purpose**: Quantum LP token management for conditional markets

**Test Scenarios**:
- Quantum LP minting (simultaneous across outcomes)
- LP token burning
- Position tracking
- Reward distribution

---

#### 9. spot/unified_spot_pool.move
**Purpose**: Unified spot pool for base asset trading

**Test Scenarios**:
- Swap operations (both directions)
- Liquidity add/remove
- TWAP oracle updates
- Fee calculations
- Slippage protection
- Reserve management

---

#### 10. swap_core.move
**Purpose**: Core swap operations for conditional markets

**Test Scenarios**:
- Conditional swaps
- Balance-based operations
- Session management
- Multiple outcome handling
- Atomic swap execution

---

#### 11. swap_position_registry.move
**Purpose**: Position tracking for conditional swaps

**Test Scenarios**:
- Position creation
- Position updates
- Position queries
- Dust tracking
- Registry cleanup

---

## Test Helper Requirements

### Test Coins
Use existing test coins from `futarchy_one_shot_utils`:
- `test_coin_a::TEST_COIN_A`
- `test_coin_b::TEST_COIN_B`

### Test Helpers Needed

#### Market Setup Helper
```move
#[test_only]
public fun create_test_market<AssetType, StableType>(
    outcome_count: u8,
    ctx: &mut TxContext,
): (UnifiedSpotPool<AssetType, StableType>, TokenEscrow<AssetType, StableType>) {
    // Setup market with proper initialization
}
```

#### Liquidity Helper
```move
#[test_only]
public fun add_test_liquidity<AssetType, StableType>(
    pool: &mut UnifiedSpotPool<AssetType, StableType>,
    asset_amount: u64,
    stable_amount: u64,
    ctx: &mut TxContext,
) {
    // Add liquidity for testing
}
```

#### Clock Helper
```move
#[test_only]
public fun create_test_clock_at_time(timestamp_ms: u64, ctx: &mut TxContext): Clock {
    let mut clock = clock::create_for_testing(ctx);
    clock::set_for_testing(&mut clock, timestamp_ms);
    clock
}
```

## Running Tests

```bash
# Run all tests with coverage
~/sui-tracing/target/release/sui move test --coverage

# Run tests for specific module
~/sui-tracing/target/release/sui move test test_<module_name>

# Silence warnings
~/sui-tracing/target/release/sui move test --silence-warnings

# View coverage summary
~/sui-tracing/target/release/sui move coverage summary

# View coverage for specific module
~/sui-tracing/target/release/sui move coverage source --module <module_name>
```

## Success Criteria

For each module:
- ✅ All happy path scenarios covered
- ✅ All error conditions tested with `#[expected_failure]`
- ✅ Edge cases (zero, max values, boundaries)
- ✅ Integration points with dependencies
- ✅ 90%+ code coverage (line level)
- ✅ All public functions tested
- ✅ All error codes tested
- ✅ Event emissions validated

## Parallel Agent Execution

Multiple agents will work on different files simultaneously. Each agent will:
1. Read the module source code thoroughly
2. Identify all public functions and error codes
3. Create comprehensive test scenarios
4. Write tests following the reference pattern
5. Ensure proper cleanup and no resource leaks
6. Add test-only helper functions where needed

## Context for Agents

### Key Architectural Points
- **Quantum Liquidity**: 1 spot token → 1 conditional token for EACH outcome simultaneously
- **Hanson-Style Futarchy**: Liquidity exists across multiple conditional markets at once
- **Balance-Based Operations**: Use ConditionalMarketBalance to avoid type explosion
- **Complete Sets**: Must have equal amounts across ALL outcomes to burn
- **Dust**: Excess conditional tokens that don't form complete sets
- **TWAP Oracle**: Write-through pattern required (write before read)

### Important Dependencies
- `futarchy_markets_primitives::conditional_amm` - Conditional AMM pools
- `futarchy_markets_primitives::coin_escrow` - Token escrow for quantum minting
- `futarchy_markets_primitives::conditional_balance` - Balance tracking object
- `futarchy_markets_primitives::market_state` - Market state management
- `futarchy_one_shot_utils::math` - Math utilities
- `futarchy_core::subsidy_config` - Subsidy configuration

### Test Utilities Available
- `sui::test_scenario` - Transaction simulation
- `sui::test_utils::destroy()` - Destroy objects with drop
- `sui::coin::{mint_for_testing, burn_for_testing}` - Test coin operations
- `sui::clock::{create_for_testing, destroy_for_testing}` - Test clock
- `sui::balance::{create_for_testing, destroy_for_testing}` - Test balances

## Notes for Implementation

1. **Test File Naming**: `<module_name>_tests.move` in `tests/` directory
2. **Test Function Naming**: `test_<function_name>_<scenario>` for clarity
3. **Error Code Documentation**: Comment which error code is expected
4. **Cleanup**: Always destroy test objects (coins, clocks, registries)
5. **Deterministic**: Tests must be deterministic (no random values)
6. **Atomic**: Each test should be independent and not affect others

## Progress Tracking

Track progress in the todo list. Mark each file when:
- [ ] Test file created
- [ ] All public functions covered
- [ ] All error cases covered
- [ ] Edge cases tested
- [ ] Integration tests added
- [ ] Test compiles
- [ ] All tests pass
- [ ] Code review completed

---

**Last Updated**: 2025-10-13
**Status**: Testing in progress
**Completion**: 1/13 modules tested (arbitrage_math.move ✓)
