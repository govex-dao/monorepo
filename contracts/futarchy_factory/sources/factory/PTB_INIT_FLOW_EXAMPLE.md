# PTB-Native DAO Creation with Init Actions

## Architecture Overview

The system uses **PTBs as the dispatcher** - no central on-chain dispatcher needed. Each action has its own entry function that PTBs compose atomically.

## Complete Flow Example

### Step 1: Frontend/SDK Builds the PTB

```typescript
// Example TypeScript code for building the PTB
const tx = new TransactionBlock();

// 1. Create unshared DAO components (hot potatoes)
const [account, queue, spotPool] = tx.moveCall({
  target: `${FACTORY_PACKAGE}::factory::create_dao_unshared`,
  typeArguments: [AssetType, StableType],
  arguments: [
    factory,
    extensions,
    feeManager,
    payment,
    // ... DAO parameters
  ],
});

// 2. Add initial liquidity
tx.moveCall({
  target: `${LIFECYCLE_PACKAGE}::init_action_entry_functions::execute_add_liquidity`,
  typeArguments: [AssetType, StableType],
  arguments: [
    assetCoin,    // External resource from user
    stableCoin,   // External resource from user
    minLpOut,
    spotPool,     // Unshared hot potato
    clock,
  ],
});

// 3. Create security council
tx.moveCall({
  target: `${LIFECYCLE_PACKAGE}::init_action_entry_functions::execute_create_council`,
  typeArguments: [StableType],
  arguments: [
    councilName,
    members,
    threshold,
    maxProposals,
    account,      // Unshared hot potato
    queue,        // Unshared hot potato
  ],
});

// 4. Create operating agreement
tx.moveCall({
  target: `${LIFECYCLE_PACKAGE}::init_action_entry_functions::execute_create_agreement`,
  arguments: [
    title,
    lines,
    difficulties,
    immutableIndices,
    account,      // Unshared hot potato
  ],
});

// 5. Create payment streams
tx.moveCall({
  target: `${LIFECYCLE_PACKAGE}::init_action_entry_functions::execute_create_stream`,
  typeArguments: [StableType],
  arguments: [
    recipient,
    amountPerEpoch,
    epochs,
    cliffEpochs,
    cancellable,
    description,
    account,      // Unshared hot potato
    clock,
  ],
});

// 6. Update DAO configuration
tx.moveCall({
  target: `${LIFECYCLE_PACKAGE}::init_action_entry_functions::execute_update_config`,
  arguments: [
    daoName,
    iconUrl,
    description,
    proposalsEnabled,
    account,      // Unshared hot potato
  ],
});

// 7. FINAL STEP: Share all objects (atomicity checkpoint)
tx.moveCall({
  target: `${LIFECYCLE_PACKAGE}::init_action_entry_functions::finalize_and_share_dao`,
  typeArguments: [AssetType, StableType],
  arguments: [
    account,      // Hot potato consumed here
    queue,        // Hot potato consumed here
    spotPool,     // Hot potato consumed here
  ],
});

// Execute the PTB
await client.signAndExecuteTransactionBlock({
  signer: keypair,
  transactionBlock: tx,
});
```

## Key Design Benefits

### 1. No Central Dispatcher
- PTB orchestrates all calls
- Each action is independent
- No god file with all action knowledge

### 2. Atomic Guarantee
- Hot potato pattern ensures all-or-nothing
- If any step fails, entire DAO creation reverts
- Objects only shared after all init succeeds

### 3. Resource Management
- External resources (coins, caps) passed directly by PTB
- No need for complex placeholder system
- Type safety at compile time

### 4. Extensibility
- Add new init actions without modifying core
- Each action module owns its init functions
- Frontend controls composition

## Resource Request Pattern (When Needed)

For actions needing external resources not available during init:

```move
// Action returns ResourceRequest (hot potato)
public fun init_oracle_config(...): ResourceRequest<OracleConfig> {
    // Return request for oracle resources
}

// Caller fulfills in same PTB
public fun fulfill_oracle_request(
    request: ResourceRequest<OracleConfig>,
    oracle_pool: &mut OraclePool,  // External shared object
): ResourceReceipt<OracleConfig> {
    // Process with external resources
}
```

## Validation Flow

### 1. Factory Validation
- Stable coin type allowed
- Payment sufficient
- Parameters within bounds

### 2. Action-Level Validation
- Each entry function validates its inputs
- Type system ensures correct resources
- Amounts, thresholds, periods checked

### 3. Atomic Enforcement
- Hot potatoes must be consumed
- No partial execution possible
- Share only happens at end

## Error Handling

Errors abort the entire PTB:
- `EInvalidAmount`: Zero or negative amounts
- `EInvalidThreshold`: Council threshold issues
- `EInvalidPeriod`: Time periods out of range
- `EStableTypeNotAllowed`: Unsupported stable coin

## Security Considerations

1. **No Reentrancy**: Sui's model prevents reentrancy
2. **Atomic Execution**: All-or-nothing via hot potatoes
3. **Type Safety**: Compile-time type checking
4. **Resource Isolation**: Unshared objects during init
5. **Validation Layers**: Multiple validation points

## Integration with Launchpad

When using launchpad for fundraising:

```typescript
// Launchpad creates DAO with raised funds
const [account, queue, spotPool] = tx.moveCall({
  target: `${LAUNCHPAD_PACKAGE}::launchpad::finalize_and_create_dao`,
  // Returns unshared objects for init
});

// Then execute init actions as above
// Finally share the objects
```

## Best Practices

1. **Order Init Actions Logically**
   - Config updates first
   - Liquidity/funds second
   - Governance structures third

2. **Validate Client-Side First**
   - Check parameters before building PTB
   - Estimate gas requirements
   - Verify resource availability

3. **Handle Failures Gracefully**
   - PTB reverts atomically
   - Show clear error messages
   - Allow retry with corrected parameters

4. **Test Init Sequences**
   - Test each action independently
   - Test full sequences on testnet
   - Verify state after creation