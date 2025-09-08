# Garbage Collection System Documentation

## Overview

The Futarchy DAO Garbage Collection (GC) system is responsible for cleaning up expired intents and their associated actions from the Account Protocol. This prevents memory leaks and ensures efficient storage management.

## Architecture

The GC system consists of three main components:

### 1. **gc_janitor.move** - The Cleanup Engine
- Main entry point for garbage collection operations
- Handles both individual and batch cleanup of expired intents
- Manages generic type resolution for common coin types
- Provides both public functions and entry functions for flexibility

### 2. **gc_registry.move** - The Action Registry
- Central registry of all delete functions for different action types
- Maps action types to their corresponding cleanup functions
- Handles special cases like owned objects that need Account access

### 3. **execute.move** - Integrated Cleanup
- Automatically invokes GC after executing one-shot intents
- Ensures proper cleanup during normal proposal execution flow

## Key Features

### Automatic Cleanup
The system automatically cleans up one-shot intents after execution:
```move
// In execute.move
if (intent.execution_times().is_empty()) {
    let mut expired = account::destroy_empty_intent<FutarchyConfig, FutarchyOutcome>(account, key);
    gc_janitor::drain_all_public(account, &mut expired);
    intents::destroy_empty_expired(expired);
}
```

### Generic Type Handling
The system handles common generic types used in the protocol:
- **Coins**: SUI, SPOT, YES, NO
- **Pairs**: SPOT/SUI, YES/SUI, NO/SUI

For other generic types, you can extend the system by adding them to `drain_common_generics()`.

### Batch Processing
Process multiple expired intents efficiently:
```move
gc_janitor::sweep_expired_intents(account, keys, max_n, clock)
```

## Supported Action Types

### Non-Generic Actions
- **Config Actions**: Trading params, metadata, governance settings
- **Operating Agreement**: Line updates, insertions, removals
- **Security Council**: Council creation, membership updates
- **Policy Actions**: Policy settings and removals
- **Dissolution**: Initiation, distribution, finalization
- **Package Upgrades**: Upgrade commits and policy restrictions
- **Stream/Payment** (non-generic): Recipient updates, withdrawer management
- **Governance**: Proposal creation and reservations
- **Memo Actions**: Event emissions

### Generic Actions (Common Types)
- **Vault Operations**: Spend, deposit, coin type management
- **Currency Operations**: Mint, burn, metadata updates
- **Stream Operations**: Create, execute, cancel payments
- **Oracle Operations**: Conditional and tiered minting
- **Liquidity Operations**: Add/remove liquidity, pool creation

## Usage

### Manual Cleanup

#### Single Intent Cleanup
```move
// Clean up a specific expired intent
gc_janitor::delete_expired_by_key(
    account,
    intent_key,
    clock
);
```

#### Batch Cleanup
```move
// Clean up multiple expired intents (up to 10 per transaction)
let keys = vector[key1, key2, key3];
gc_janitor::cleanup_expired_intents(
    account,
    keys,
    clock
);
```

### Checking Intent Expiration
```move
// Check if an intent has expired
let is_expired = gc_janitor::is_intent_expired(
    account,
    &intent_key,
    clock
);
```

### Entry Functions
For use in transactions:
```move
// Single intent cleanup
public entry fun cleanup_expired_intent(
    account: &mut Account<FutarchyConfig>,
    key: String,
    clock: &Clock
)

// Batch cleanup (processes up to 10 intents)
public entry fun cleanup_expired_intents(
    account: &mut Account<FutarchyConfig>,
    keys: vector<String>,
    clock: &Clock
)
```

## Extending the System

### Adding New Action Types

1. **Create Delete Function** in the action module:
```move
public fun delete_my_action<T>(expired: &mut Expired) {
    let MyAction<T> { field1: _, field2: _ } = expired.remove_action();
}
```

2. **Register in gc_registry.move**:
```move
public fun delete_my_action<T>(expired: &mut Expired) {
    my_module::delete_my_action<T>(expired);
}
```

3. **Add to gc_janitor.move**:
- For non-generic actions, add to `drain_all()`
- For generic actions, add to appropriate helper functions or create new ones

### Adding New Generic Types

1. **Import the type** in gc_janitor.move:
```move
use my_package::my_token::MYTOKEN;
```

2. **Add to drain_common_generics()**:
```move
drain_vault_actions_for_coin<MYTOKEN>(expired);
drain_currency_actions_for_coin<MYTOKEN>(expired);
drain_stream_actions_for_coin<MYTOKEN>(expired);
```

## Best Practices

1. **Always implement delete functions** for new action types
2. **Test cleanup thoroughly** using the test suite in gc_tests.move
3. **Handle generic types explicitly** for common coins/tokens
4. **Use batch cleanup** for efficiency when cleaning multiple intents
5. **Set appropriate gas limits** - batch operations can be gas-intensive

## Performance Considerations

- **Batch Size**: Limited to 10 intents per transaction to avoid gas limits
- **Generic Resolution**: Pre-compiled for common types to avoid runtime overhead
- **Lazy Evaluation**: Only cleans up intents that are actually expired

## Error Handling

The system gracefully handles:
- Non-existent intents
- Already cleaned intents  
- Intents with future execution times (not expired)
- Missing or unknown action types

## Security

- Only expired intents can be cleaned up
- Account access required for owned object cleanup
- No ability to delete active or future intents
- Proper authorization checks in place

## Testing

Comprehensive test suite available in `tests/gc_tests.move`:
- Empty intent cleanup
- Config action cleanup
- Stream action cleanup
- Multiple intent sweep
- Generic action cleanup
- Recurring intent protection
- Entry function testing

Run tests:
```bash
sui move test --filter gc_tests
```

## Monitoring

Key metrics to track:
- Number of expired intents pending cleanup
- Gas costs for cleanup operations
- Frequency of cleanup operations
- Types of actions being cleaned up

## Future Improvements

1. **Dynamic Generic Resolution**: Runtime type discovery for arbitrary generic types
2. **Automated Cleanup**: Background service for periodic cleanup
3. **Gas Optimization**: Further batching and optimization strategies
4. **Analytics**: Built-in metrics and reporting