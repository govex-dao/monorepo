# Extension Action Guide

## Overview

The futarchy governance system supports extensible actions. Any package can define new action types that work with the intent execution system.

## Action Cleanup Requirements

All actions must be cleanable when intents expire. There are two ways to satisfy this:

### Option 1: Droppable Actions (Recommended)

If your action contains **no resources** (no Coins, Objects, or Capabilities), give it the `drop` ability:

```move
public struct MyAction has store, drop {
    amount: u64,
    recipient: address,
    description: String,
}
```

**Actions with `drop` are automatically cleaned up** when intents expire. No delete function needed.

### Option 2: Actions with Resources

If your action contains resources that can't be dropped, you MUST provide a public delete function:

```move
public struct MyComplexAction has store {
    coins: Coin<SUI>,  // Resource - can't be dropped!
    recipient: address,
}

/// REQUIRED: Delete function for cleanup
public fun delete_my_complex_action(expired: &mut Expired) {
    use account_protocol::intents;

    // Remove the action spec from expired
    let spec = intents::remove_action_spec(expired);

    // Deserialize the action
    let action_bytes = intents::action_spec_action_data(spec);
    let action: MyComplexAction = bcs::from_bytes(&action_bytes);

    // Handle the resource (return to sender, burn, etc.)
    let MyComplexAction { coins, recipient } = action;
    transfer::public_transfer(coins, recipient);
}
```

## How Cleanup Works

### System Architecture

1. **Permissionless Cleanup**: Anyone can clean up expired intents
2. **Storage Rebate**: Cleaners receive the storage deposit as incentive
3. **Keeper Bots**: Off-chain bots monitor for expired intents and build cleanup PTBs

### Cleanup Flow

When an intent expires:

```
1. Keeper calls: account::delete_expired_intent(account, key)
   → Returns Expired hot potato containing action specs

2. Keeper builds PTB to drain the Expired:
   - For droppable actions: Automatically handled
   - For non-droppable actions: Call delete_* functions

3. Keeper destroys empty Expired
   → Receives storage rebate
```

### Example Keeper PTB

```move
// PTB built by keeper bot:
let mut expired = account::delete_expired_intent(account, key, clock, ctx);

// Clean up each action type in the expired intent
my_package::delete_my_complex_action(&mut expired);
vault::delete_spend<SUI>(&mut expired);
transfer::delete_transfer(&mut expired);

// Destroy the now-empty expired intent
expired.destroy_empty();
```

## Extension Developer Checklist

When creating a new action type:

- [ ] Define your action struct
- [ ] Choose cleanup strategy:
  - [ ] **Droppable**: Add `drop` ability (if no resources)
  - [ ] **Manual**: Implement `public fun delete_*` function
- [ ] Test that cleanup works (see tests below)
- [ ] Document your delete function for keeper bot developers

## No Registry Required

**Important**: There is NO centralized registry for delete functions. Keepers discover action types by:
- Indexing on-chain intents
- Reading package metadata
- Building custom PTBs per action type

This design is:
- ✅ Fully extensible (no hardcoded limits)
- ✅ Permissionless (no governance approval needed)
- ✅ Simple (no registry maintenance)

## Testing Your Delete Function

```move
#[test]
fun test_delete_my_action() {
    let ctx = &mut tx_context::dummy();
    let clock = clock::create_for_testing(ctx);
    let mut intents = intents::empty(ctx);

    // Create intent with your action
    let params = intents::new_params(
        b"test".to_string(),
        b"test action".to_string(),
        vector[1000],
        2000,
        &clock,
        ctx
    );

    let mut intent = account::create_intent(
        params,
        TestOutcome {},
        b"test".to_string(),
        version::current(),
        TestWitness(),
        ctx
    );

    // Add your action
    let action = MyComplexAction { coins, recipient };
    let action_bytes = bcs::to_bytes(&action);
    intent.add_typed_action(
        MyComplexActionMarker {},
        action_bytes,
        TestWitness()
    );

    // Store and destroy to get Expired
    intents.add_intent(intent);
    let mut expired = intents.destroy_intent<TestOutcome>(b"test".to_string(), ctx);

    // Test your delete function
    delete_my_complex_action(&mut expired);

    // Should be empty now
    assert!(expired.expired_action_count() == 0);
    expired.destroy_empty();

    // Cleanup
    destroy(intents);
    destroy(clock);
}
```

## Common Patterns

### Pattern 1: Actions with Coins

```move
public fun delete_spend_action<CoinType>(expired: &mut Expired) {
    let spec = intents::remove_action_spec(expired);
    let action: SpendAction<CoinType> = bcs::from_bytes(&intents::action_spec_action_data(spec));

    let SpendAction { amount: _, recipient: _ } = action;
    // Coins were already extracted during execution
    // Just destroy the action struct
}
```

### Pattern 2: Actions with Objects

```move
public fun delete_withdraw_object(expired: &mut Expired, account: &Account) {
    let spec = intents::remove_action_spec(expired);
    let action: WithdrawObjectAction = bcs::from_bytes(&intents::action_spec_action_data(spec));

    let WithdrawObjectAction { object_id, recipient } = action;
    // Object already transferred during execution
    // Just destroy the action struct
}
```

### Pattern 3: Generic Actions

```move
public fun delete_mint_action<CoinType>(expired: &mut Expired) {
    let spec = intents::remove_action_spec(expired);
    let action: MintAction<CoinType> = bcs::from_bytes(&intents::action_spec_action_data(spec));

    let MintAction { amount: _, recipient: _ } = action;
    // Treasury cap was used during execution
    // Just destroy the action struct
}
```

## Troubleshooting

### "EActionsNotEmpty" error when destroying Expired

**Problem**: Expired still contains action specs that haven't been cleaned up.

**Solution**: Ensure you call `delete_*` for EVERY action type in the expired intent, or make all actions droppable.

### Keeper bots aren't cleaning up my actions

**Problem**: Keeper doesn't know about your custom delete function.

**Solutions**:
1. Make your actions droppable (add `drop` ability)
2. Document your delete function for keeper bot developers
3. Run your own keeper bot that knows your action types
4. Ensure cleanup is profitable (storage rebate > gas cost)

## Best Practices

1. **Prefer `drop` ability**: Simplest for everyone
2. **Document delete functions**: Help keeper bot developers
3. **Test cleanup**: Don't ship actions that can't be cleaned
4. **Handle edge cases**: What if resources already extracted?
5. **Consider gas costs**: Simple cleanup = more likely to be cleaned

## See Also

- `account_protocol::intents` - Intent and Expired types
- `account_protocol::account::delete_expired_intent()` - Cleanup entry point
- `move-framework/packages/actions/sources/lib/` - Reference implementations
