# Oracle Package Test Suite

## Overview

This directory contains comprehensive tests for the `futarchy_oracle` package, covering oracle mint grants, price-based minting, and governance actions.

## Test Files

### 1. `oracle_helpers_tests.move`
**Status:** ✅ Ready to run
**Purpose:** Tests helper functions and action constructors

**Coverage:**
- Helper functions (price conditions, repeat config, recipient mints)
- Action constructors (new_create_employee_option, new_create_vesting_grant, etc.)
- All 8 action type constructors

**Tests:**
- `test_relative_price_condition` - Create launchpad-relative price condition
- `test_absolute_price_condition` - Create absolute price threshold
- `test_repeat_config` - Create repeatability configuration
- `test_new_recipient_mint` - Create recipient mint allocation
- `test_new_create_employee_option` - Employee option action constructor
- `test_new_create_vesting_grant` - Vesting grant action constructor
- `test_new_create_conditional_mint` - Conditional mint action constructor
- `test_new_cancel_grant` - Cancel grant action constructor
- `test_new_pause_grant` - Pause grant action constructor
- `test_new_unpause_grant` - Unpause grant action constructor
- `test_new_emergency_freeze_grant` - Emergency freeze action constructor
- `test_new_emergency_unfreeze_grant` - Emergency unfreeze action constructor

### 2. `oracle_actions_tests.move`
**Status:** ⏸️ Pending (requires test infrastructure optimization)
**Purpose:** Integration tests for grant creation and lifecycle

**Planned Coverage:**
- Employee option creation and vesting
- Simple vesting grant creation
- Conditional mint creation and execution
- Milestone rewards with tiers
- Pause/Resume functionality
- Emergency freeze/unfreeze
- Grant cancellation
- Vesting calculations and time-based logic

**Planned Tests:**
- `test_create_employee_option_basic` - Basic employee option creation
- `test_create_vesting_grant_basic` - Basic vesting grant creation
- `test_employee_option_vesting_schedule` - Vesting over time with cliff
- `test_pause_and_resume` - Pause/resume mechanics
- `test_emergency_freeze` - Emergency freeze prevents claims
- `test_conditional_mint_execution` - Price-triggered minting
- `test_milestone_tier_execution` - Multi-tier milestone rewards
- `test_claim_vested_tokens` - Token claiming flow
- `test_cancel_unvested_grant` - Cancellation logic

### 3. `oracle_decoder_tests.move`
**Status:** 📝 To be created
**Purpose:** Tests BCS serialization/deserialization

**Planned Coverage:**
- Decoder registration
- BCS encoding/decoding for all action types
- Human-readable field generation
- Security validation (trailing byte attacks)

### 4. `oracle_intents_tests.move`
**Status:** 📝 To be created
**Purpose:** Tests intent builder functions

**Planned Coverage:**
- Intent spec creation
- Action addition to intents
- BCS serialization integration
- Type parameter validation

## Running Tests

### Run All Tests
```bash
sui move test --skip-fetch-latest-git-deps
```

### Run Specific Test File
```bash
sui move test --skip-fetch-latest-git-deps --filter oracle_helpers_tests
```

### Run Specific Test
```bash
sui move test --skip-fetch-latest-git-deps test_new_create_employee_option
```

### Run With Coverage (using sui-tracing binary)
```bash
~/sui-tracing/target/release/sui move test --coverage
~/sui-tracing/target/release/sui move coverage summary
~/sui-tracing/target/release/sui move coverage source --module oracle_actions
```

## Test Patterns

### 1. Helper Function Tests
Simple unit tests that verify helper functions compile and don't abort:

```move
#[test]
fun test_helper() {
    let result = oracle_actions::helper_function(args);
    let _ = result; // Verify no abort
}
```

### 2. Action Constructor Tests
Verify action structs can be created with valid parameters:

```move
#[test]
fun test_new_action() {
    public struct ASSET has drop {}
    public struct STABLE has drop {}

    let action = oracle_actions::new_create_action<ASSET, STABLE>(params);
    let _ = action;
}
```

### 3. Integration Tests (oracle_actions_tests.move)
Full end-to-end tests using test_scenario:

```move
#[test]
fun test_integration() {
    let mut scenario = ts::begin(ADMIN);
    let clock = clock::create_for_testing(ts::ctx(&mut scenario));

    // Create grant
    ts::next_tx(&mut scenario, ADMIN);
    {
        oracle_actions::create_grant<ASSET, STABLE>(params, &clock, ctx);
    };

    // Verify creation
    ts::next_tx(&mut scenario, RECIPIENT);
    {
        assert!(ts::has_most_recent_shared<PriceBasedMintGrant<ASSET, STABLE>>(), 0);
    };

    test_utils::destroy(clock);
    ts::end(scenario);
}
```

### 4. Time-Based Tests
Test vesting schedules and time-dependent logic:

```move
#[test]
fun test_vesting_over_time() {
    // Create grant with vesting
    // Advance time before cliff → expect 0 claimable
    // Advance time after cliff → expect partial vesting
    // Advance time to completion → expect full amount
}
```

## Expected Error Tests

Tests should also verify error conditions:

```move
#[test]
#[expected_failure(abort_code = oracle_actions::EInvalidAmount)]
fun test_zero_amount_fails() {
    oracle_actions::create_vesting_grant(
        recipient,
        0,  // Should fail - zero amount
        cliff,
        duration,
        dao_id,
        clock,
        ctx
    );
}
```

## Test Data Constants

Standard test addresses and values:

```move
const ADMIN: address = @0xAD;
const RECIPIENT: address = @0xB0B;
const DAO_ID_ADDR: address = @0xDA0;

const ONE_DAY_MS: u64 = 86_400_000;
const ONE_MONTH_MS: u64 = 2_592_000_000;
const ONE_YEAR_MS: u64 = 31_536_000_000;
```

## Coverage Goals

- **Helper Functions:** 100% coverage
- **Action Constructors:** 100% coverage
- **Grant Creation:** 90%+ coverage
- **Vesting Logic:** 95%+ coverage
- **Emergency Controls:** 100% coverage
- **BCS Serialization:** 100% coverage

## Known Limitations

1. **Test Performance:** Large dependency tree may cause slow compilation
2. **Oracle Integration:** Tests don't include actual price oracle (mocked/stubbed)
3. **Treasury Integration:** Tests don't mint actual tokens (would require TreasuryCap)

## Future Enhancements

- [ ] Add property-based testing with randomized inputs
- [ ] Add fuzzing tests for BCS deserialization
- [ ] Add gas profiling tests
- [ ] Add multi-user claiming scenarios
- [ ] Add edge case tests (overflow, underflow, etc.)

## Test Maintenance

When adding new features:
1. Add unit tests for new helper functions
2. Add constructor tests for new action types
3. Add integration tests for new grant types
4. Update this README with new test coverage
5. Verify all existing tests still pass
