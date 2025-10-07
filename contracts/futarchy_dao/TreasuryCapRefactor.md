# TreasuryCap Storage Refactor Summary

## Current State ✅
**Good news!** The TreasuryCap is ALREADY being stored in the DAO's Account:

### 1. Factory Storage (lines 318-323, 487-492 in factory.move)
```move
// Use Move framework's currency::lock_cap for proper treasury cap storage
let auth = futarchy_config::authenticate(&account, ctx);
currency::lock_cap(
    auth,
    &mut account,
    cap,
    option::none() // No max supply limit for now
);
```

### 2. Launchpad Integration
- Launchpad holds TreasuryCap temporarily during fundraising
- On DAO creation, passes TreasuryCap to factory
- Factory stores it using `currency::lock_cap()`

## The Problem: Oracle Actions Still Use Hot Potato Pattern

Current oracle mint actions unnecessarily use hot potato pattern:
```move
// Current (BAD) - requires caller to provide TreasuryCap
let request = oracle_actions::do_conditional_mint(...);
let receipt = oracle_actions::fulfill_conditional_mint(
    request,
    treasury_cap,  // Caller must provide!
    amm_pool,
    ...
);
```

## The Solution: Use Stored TreasuryCap

The Move framework's currency module already provides everything we need:

### Available Functions:
- `currency::has_cap<Config, CoinType>(account)` - Check if cap exists
- `currency::do_mint<Config, Outcome, CoinType>()` - Mint using stored cap
- `currency::borrow_rules<Config, CoinType>()` - Get minting rules
- `currency::coin_type_supply<Config, CoinType>()` - Get total supply

### Refactored Pattern:
```move
// New (GOOD) - uses stored TreasuryCap
public fun do_conditional_mint<AssetType, Outcome, IW>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    witness: IW,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Check conditions...
    
    // Mint directly using stored cap - NO HOT POTATO!
    let coin = currency::do_mint<FutarchyConfig, Outcome, AssetType, IW>(
        executable,
        account,
        version::current(),
        witness,
        ctx
    );
    
    // Transfer to recipient
    transfer::public_transfer(coin, recipient);
}
```

## What Needs Refactoring

### 1. Oracle Actions (oracle_actions.move)
- Remove `ResourceRequest` / `ResourceReceipt` pattern
- Remove `fulfill_conditional_mint()` function
- Update `do_conditional_mint()` to use `currency::do_mint()`
- Update `do_tiered_mint()` to use `currency::do_mint()`

### 2. Action Dispatcher
- Remove hot potato handling for oracle actions
- Simplify `execute_oracle_mint()` function

### 3. Governance Actions
- Check if any governance actions need treasury cap
- Refactor to use stored cap if needed

## Benefits

1. **Simpler Code**: No more hot potato pattern for minting
2. **Better UX**: Callers don't need to provide TreasuryCap
3. **Atomic Operations**: Minting happens directly in action execution
4. **Consistent Pattern**: Aligns with how admin caps are handled

## Migration Path

1. **Phase 1**: Update oracle actions to use stored cap
2. **Phase 2**: Update dispatcher to remove hot potato handling
3. **Phase 3**: Document new pattern for future actions
4. **Phase 4**: Consider storing other resources (if any make sense)

## Other Resources to Consider Storing

### Should Store in Account:
- ✅ TreasuryCap (already done!)
- ✅ Admin capabilities (already done!)
- ✅ UpgradeCap (already done via currency module)
- ⚠️ Vesting schedules (could be owned by DAO)
- ⚠️ Reserved tokens (could be in DAO treasury)

### Cannot Store (Must Remain Shared):
- ❌ AMM pools (need to be publicly accessible)
- ❌ ProposalQueue (shared across DAOs)
- ❌ FeeManager (shared for protocol fees)
- ❌ Factory (shared for DAO creation)

## Next Steps

1. Refactor oracle_actions.move to remove hot potato pattern
2. Update action_dispatcher.move accordingly
3. Test that minting still works correctly
4. Document the new pattern for developers