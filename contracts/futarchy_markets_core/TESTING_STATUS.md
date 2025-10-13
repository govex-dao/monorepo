# Futarchy Markets Core - Testing Status & Plan

## Current Status (2025-10-13)

### Completed Modules ✅ (8/13)

1. **arbitrage_math.move** ✅
   - 40 tests total (32 main + 5 benchmarks + 3 fuzzing)
   - Commit: Pre-existing
   - Test file: `tests/arbitrage_math_tests.move`

2. **arbitrage_core.move** ✅
   - 15 tests covering core algorithms
   - Commit: Pre-existing
   - Test file: `tests/arbitrage_core_tests.move`

3. **arbitrage.move** ✅
   - 12 comprehensive tests for unified arbitrage
   - Tests main entry point for ANY outcome count (2, 3, 5 outcomes)
   - Both arbitrage directions (stable→asset, asset→stable)
   - Dust handling (return balance vs destroy)
   - Complete set burning (stable and asset)
   - Error testing (EInsufficientProfit)
   - Test file: `tests/arbitrage_tests.move`
   - Commit: ee7f70e

4. **early_resolve.move** ✅
   - 19 tests covering early resolution system
   - Commit: Pre-existing (ee7f70e)
   - Test file: `tests/early_resolve_tests.move`

5. **proposal.move** ✅
   - 15 tests covering proposal lifecycle
   - Commit: Pre-existing (ee7f70e)
   - Test file: `tests/proposal_tests.move`

6. **subsidy_escrow.move** ✅
   - 32 comprehensive tests covering all aspects
   - All 7 error codes tested
   - Permissionless cranking, rate limiting, proportional injection
   - Commit: 7529146
   - Test file: `tests/subsidy_escrow_tests.move`

7. **swap_position_registry.move** ✅
   - 29 tests covering DEX aggregator compatibility
   - Hot potato pattern (start_crank → unwrap_one → finish_crank)
   - Economic helper functions tested
   - Commit: 9b4c7ea
   - Test file: `tests/swap_position_registry_tests.move`

8. **swap_core.move** ✅
   - 16 comprehensive tests for core swap primitives
   - Hot potato session management (begin → swap → finalize)
   - Balance-based swaps (eliminates type explosion)
   - Both directions (asset→stable, stable→asset)
   - All 5 error codes tested (EInvalidOutcome, EInvalidState, EInsufficientOutput, ESessionMismatch, EProposalMismatch)
   - Security validations (session match, balance match, market state)
   - Works with 2, 3, 5 outcomes (key architecture feature)
   - Test file: `tests/swap_core_tests.move`
   - **Status**: Just completed, ready to commit

## What Was Being Worked On

**Task**: Verify that swap_position_registry tests actually compile and pass

**Progress**:
- Test file created with 34 tests
- Test helpers added to source module (destroy_for_testing functions)
- Build succeeds (no compilation errors)
- Tests not yet confirmed to run successfully
- Need to restore file from commit 9b4c7ea and verify tests pass

**Commands Used**:
```bash
# Run specific test module
~/sui-tracing/target/release/sui move test test_swap_position_registry --silence-warnings

# Run single test
~/sui-tracing/target/release/sui move test test_create_registry --silence-warnings

# Check build
~/sui-tracing/target/release/sui move build --silence-warnings

# Restore test file from commit
git show 9b4c7ea:contracts/futarchy_markets_core/tests/swap_position_registry_tests.move > tests/swap_position_registry_tests.move
```

## Next Steps - Immediate

1. **Restore swap_position_registry_tests.move** from commit 9b4c7ea
2. **Verify tests compile and pass**
3. **Update todo list** to mark swap_position_registry as complete
4. **Move to next module**

## Next Steps - Testing Pipeline

### Priority Order (Based on Dependencies)

**Next Module Recommendations** (pick one):

#### Option A: arbitrage.move
- **Purpose**: Unified arbitrage system entry points for ANY outcome count
- **Why Next**: Core functionality, depends on modules we might test
- **Key Functions**:
  - `execute_optimal_spot_arbitrage()` - Main arbitrage
  - `execute_spot_arb_stable_to_asset_direction()` - Stable→Asset
  - `execute_spot_arb_asset_to_stable_direction()` - Asset→Stable
  - `burn_complete_set_and_withdraw_*()` - Complete set burning
- **Dependencies**: UnifiedSpotPool, TokenEscrow, ConditionalMarketBalance, SwapSession
- **Test Scenarios**:
  - Basic arbitrage with 2 outcomes
  - Arbitrage with 3, 4, 5 outcomes (same function!)
  - Both directions
  - Minimum profit validation
  - Dust handling

#### Option B: arbitrage_core.move
- **Purpose**: Core arbitrage algorithms and validation logic
- **Why Next**: Foundation for arbitrage.move
- **Key Functions**:
  - `validate_profitable()` - Profitability checks
  - `spot_swap_*()` - Spot pool swaps
  - `deposit_*_for_quantum_mint()` - Quantum minting
  - `find_min_value()` - Minimum finding
  - `burn_and_withdraw_conditional_*()` - Conditional burning
- **Dependencies**: UnifiedSpotPool, TokenEscrow, SwapPositionRegistry

#### Option C: early_resolve.move
- **Purpose**: Early proposal resolution before natural expiry
- **Why Next**: Smaller module, might be easier
- **Test Scenarios**:
  - Early resolution triggering
  - State transitions
  - Payout calculations
  - Authorization checks

#### Option D: proposal.move
- **Purpose**: Proposal market lifecycle management
- **Why Next**: Already has some test helpers (lines 1696-1790)
- **Test Scenarios**:
  - Proposal creation
  - State transitions (PENDING → TRADING → PASSED/FAILED → EXECUTED)
  - Voting mechanisms
  - Resolution logic
  - Market finalization

### Remaining Modules ❌ (5/13)

1. **fee.move** - Fee management
2. **liquidity_initialize.move** - Initial liquidity setup
3. **quantum_lp_manager.move** - Quantum LP token management
4. **rng.move** - Random number generation
5. **unified_spot_pool.move** - Unified spot pool (spot/)

### Testing Progress: 8/13 modules (62% complete)

## Testing Philosophy (From TESTING_PLAN.md)

### Core Principles
1. **No Mocking** - Use real objects and state where possible
2. **Test Helpers** - Create helpers for complex setup (like coin initialization)
3. **Real Scenario Testing** - Test actual usage patterns, not just happy paths
4. **Error Testing** - Comprehensive coverage of error conditions
5. **Edge Cases** - Test boundaries, zero values, maximum values
6. **Integration Points** - Test how modules interact with dependencies

### Reference Pattern: coin_registry_tests.move

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

### Success Criteria Per Module

- ✅ All happy path scenarios covered
- ✅ All error conditions tested with `#[expected_failure]`
- ✅ Edge cases (zero, max values, boundaries)
- ✅ Integration points with dependencies
- ✅ 90%+ code coverage (line level)
- ✅ All public functions tested
- ✅ All error codes tested
- ✅ Event emissions validated

## Test Helper Requirements

### Test Coins Available
From `futarchy_one_shot_utils`:
- `test_coin_a::TEST_COIN_A`
- `test_coin_b::TEST_COIN_B`

### Test Helpers Pattern

```move
#[test_only]
public fun create_test_<object>(..., ctx: &mut TxContext): <Object> {
    // Setup object with proper initialization
}

#[test_only]
public fun destroy_for_testing<...>(object: <Object>) {
    // Proper cleanup (drop tables, delete UIDs, etc.)
}
```

### Test Helpers Found

**proposal.move** (lines 1696-1790):
- Has test helper functions including `create_test_proposal()`

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

## Key Context

### Architectural Points
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

## Repository Info

- **Working Directory**: `/Users/admin/monorepo/contracts/futarchy_markets_core`
- **Git Branch**: `dev`
- **Recent Commits**:
  - `9b4c7ea` - swap_position_registry tests
  - `7529146` - subsidy_escrow tests
  - `a442e52` - TESTING_PLAN.md

## Notes

- Tests use `sui::test_scenario` for transaction simulation
- Tests use `sui::test_utils::destroy()` for cleanup
- Custom sui binary at `~/sui-tracing/target/release/sui` for coverage analysis
- Test file naming: `<module_name>_tests.move` in `tests/` directory
- Test function naming: `test_<function_name>_<scenario>`
- Always destroy test objects (coins, clocks, registries)
- Tests must be deterministic (no random values)
- Each test should be independent and atomic
