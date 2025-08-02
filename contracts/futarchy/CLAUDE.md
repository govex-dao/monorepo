# Claude Context for Futarchy Token Tests

## Project Overview
This is a Sui Move implementation of a futarchy prediction market system with conditional tokens. The token system manages asset, stable, and LP tokens that represent different market outcomes.

## Token System Architecture

### Token Types
- **ConditionalToken**: Represents conditional outcomes (YES/NO) for different asset types
  - Asset tokens (type 0)
  - Stable tokens (type 1)
  - LP tokens (type 2)
- **Supply**: Tracks total supply for each token type/outcome combination

### Key Token Operations
1. **Minting**: Create new conditional tokens through the escrow system
2. **Burning**: Destroy tokens and update supply tracking
3. **Splitting**: Divide a token into smaller denominations
4. **Merging**: Combine multiple tokens of the same type
5. **Transfer**: Move tokens between addresses (uses `public_transfer`)

## Test Structure

### Token Test Files
- `/tests/token/conditional_token_tests.move` - Core conditional token functionality
- `/tests/token/coin_escrow_tests.move` - Escrow and token conversion tests

### Key Test Cases

#### Conditional Token Tests
1. **Basic Operations**
   - `test_mint_and_burn` - Token lifecycle
   - `test_split` - Token division
   - `test_merge` - Token combination
   - `test_merge_many` - Batch token merging

2. **Edge Cases**
   - `test_destroy_zero_value_token` - Zero-balance token destruction
   - `test_mint_max_value` - Maximum value minting
   - `test_merge_many_wrong_asset_type` - Type validation (expects `EWrongTokenType`)

3. **Error Conditions**
   - Zero amount operations
   - Wrong market/outcome/type matching
   - Insufficient balance errors

#### Common Test Issues & Solutions
1. **Split Operation**: Cannot split entire balance (must be `balance > amount`)
2. **Zero Token Creation**: Use `mint_for_testing` with 0 balance for testing
3. **Transfer Errors**: Use `transfer::public_transfer` not `transfer::transfer`
4. **Expected Failure Codes**:
   - `ENonzeroBalance` (8) - For destroying non-empty tokens
   - `EWrongTokenType` (2) - For type mismatches
   - `EZeroAmount` (4) - For zero amount operations

### Test Constants
```move
const ADMIN: address = @0xA;
const USER1: address = @0x1;
const USER2: address = @0x2;

// Asset types
const ASSET_TYPE_ASSET: u8 = 0;
const ASSET_TYPE_STABLE: u8 = 1;
const ASSET_TYPE_LP: u8 = 2;

// Outcomes
const OUTCOME_YES: u8 = 0;
const OUTCOME_NO: u8 = 1;
```

## Running Token Tests

```bash
# Run all token tests
sui move test conditional_token_tests
sui move test coin_escrow_tests

# Run specific test
sui move test test_destroy_zero_value_token

# Run all tests
sui move test
```

## Important Testing Notes

1. **Test Isolation**: Each test creates its own MarketState and Clock
2. **Supply Tracking**: Always properly manage Supply objects when minting/burning
3. **Market State**: Use `market_state::init_trading_for_testing` to enable trading
4. **Error Constants**: Check `conditional_token.move` for correct error codes
5. **Transfer Requirements**: ConditionalToken has `store` ability, requires `public_transfer`

## Common Patterns

### Creating Test Tokens
```move
// Create supply tracker
let mut supply = conditional_token::new_supply(
    &state,
    ASSET_TYPE_ASSET,
    OUTCOME_YES,
    ctx,
);

// Mint token
let token = conditional_token::mint(
    &state,
    &mut supply,
    100, // amount
    USER1, // recipient
    &clock,
    ctx,
);
```

### Testing Zero-Balance Tokens
```move
// Use mint_for_testing to create zero-balance token
let zero_token = conditional_token::mint_for_testing(
    state.market_id(),
    ASSET_TYPE_ASSET,
    OUTCOME_YES,
    0, // zero balance
    ctx
);
conditional_token::destroy(zero_token);
```

## Current Test Status
✅ All 230 tests passing as of last run
- No compilation errors
- All edge cases properly handled
- Error conditions correctly tested

## Recommended Additional Tests

### ConditionalToken Tests

1. **Overflow/Underflow Protection**
   - `test_mint_overflow` - Attempt to mint u64::MAX tokens
   - `test_merge_overflow` - Merge tokens that would exceed u64::MAX
   - `test_supply_overflow` - Test supply tracking at maximum values

2. **Split Function Edge Cases**
   - `test_split_minimum_amounts` - Split with amount = 1
   - `test_split_and_return_recipient_self` - Split to same address
   - `test_split_chain` - Multiple consecutive splits on same token

3. **Extract Function Testing**
   - `test_extract_from_none` - Extract from empty Option (should fail)
   - `test_extract_from_some` - Normal extraction case
   - `test_extract_multiple_times` - Ensure Option is properly emptied

4. **Concurrent Operations**
   - `test_merge_after_partial_split` - Merge tokens that were just split
   - `test_split_merged_tokens` - Split tokens that were just merged
   - `test_parallel_supply_updates` - Multiple mints/burns in same tx

5. **Access Control**
   - `test_update_supply_permissions` - Ensure only authorized modules can update
   - `test_mint_with_wrong_supply` - Mint with mismatched supply object

### CoinEscrow Tests

1. **Fee Extraction Edge Cases**
   - `test_extract_fees_zero_balance` - Extract when no fees accumulated
   - `test_extract_fees_multiple_times` - Sequential fee extractions
   - `test_extract_fees_after_market_end` - Fee extraction timing

2. **Liquidity Edge Cases**
   - `test_deposit_liquidity_zero_amounts` - Deposit with 0 tokens
   - `test_remove_all_liquidity` - Complete liquidity removal
   - `test_liquidity_with_unequal_outcomes` - Non-uniform outcome distributions

3. **Token Set Verification**
   - `test_verify_empty_token_set` - Empty vector validation
   - `test_verify_partial_token_sets` - Missing some outcomes
   - `test_verify_token_set_wrong_order` - Outcomes in wrong sequence

4. **Redemption Scenarios**
   - `test_redeem_with_zero_balance_tokens` - Include 0-value tokens in set
   - `test_redeem_mixed_asset_types` - Mix of asset/stable tokens
   - `test_redeem_after_supply_burn` - Redeem when supply was partially burned

5. **State Transition Tests**
   - `test_operations_during_market_pause` - If pause functionality exists
   - `test_mint_at_exact_end_time` - Boundary condition at market end
   - `test_redeem_immediately_after_finalization` - Timing edge case

### Integration Test Scenarios

1. **Complex Token Flows**
   - `test_full_lifecycle_multiple_users` - Complete mint->trade->redeem flow
   - `test_token_migration_scenario` - Moving tokens between markets
   - `test_emergency_withdrawal_flow` - If emergency functions exist

2. **Supply Consistency**
   - `test_supply_invariants_hold` - Total supply = sum of all tokens
   - `test_supply_after_complex_operations` - Supply tracking accuracy
   - `test_cross_market_supply_isolation` - Supplies don't interfere

3. **Performance/Stress Tests**
   - `test_merge_many_maximum_tokens` - Merge with max vector size
   - `test_rapid_mint_burn_cycles` - High frequency operations
   - `test_large_liquidity_operations` - Big liquidity add/remove

### Error Handling Improvements

1. **Better Error Messages**
   - Test that each error code is reachable
   - Verify error messages are descriptive
   - Test error recovery scenarios

2. **Invalid State Prevention**
   - `test_prevent_negative_balances` - Ensure no underflows
   - `test_prevent_duplicate_supplies` - One supply per type/outcome
   - `test_prevent_orphaned_tokens` - Tokens without valid market