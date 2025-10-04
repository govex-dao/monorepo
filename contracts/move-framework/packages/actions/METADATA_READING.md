# Reading Coin Metadata

## Overview

The `read_coin_metadata` function is a simple helper to read all metadata fields from a `CoinMetadata` object in one call.

## Function Signature

```move
public fun read_coin_metadata<CoinType>(
    metadata: &CoinMetadata<CoinType>,
): (ascii::String, String, String, ascii::String)
```

**Returns**: `(symbol, name, description, icon_url)`

## Usage in PTB (TypeScript)

```typescript
import { Transaction } from '@mysten/sui/transactions';

// Example: Read coin metadata before creating proposal
const tx = new Transaction();

// Read metadata from any CoinMetadata object
const [symbol, name, description, iconUrl] = tx.moveCall({
  target: 'account_actions::currency::read_coin_metadata',
  arguments: [
    tx.object(coinMetadataId)      // CoinMetadata object (shared)
  ],
  typeArguments: [
    '0x123::my_token::MY_TOKEN'    // Coin type
  ],
});

// Use the metadata in proposal creation
tx.moveCall({
  target: 'futarchy_markets::proposal::create',
  arguments: [
    /* ... other args ... */,
    symbol,       // ← Use coin symbol
    name,         // ← Use coin name
    iconUrl,      // ← Use coin icon
    /* ... */
  ],
});

await client.signAndExecuteTransaction({
  signer: keypair,
  transaction: tx,
});
```

## Use Cases

### 1. Dynamic Proposal Creation
```typescript
// Read actual coin metadata instead of hardcoding
const [symbol, name, desc, icon] = tx.moveCall({
  target: 'account_actions::currency::read_coin_metadata',
  arguments: [coinMetadata],
  typeArguments: [CoinType],
});

// Use in proposal
tx.moveCall({
  target: 'proposal::create',
  arguments: [symbol, name, icon, /* ... */],
});
```

### 2. Conditional Coin Metadata
```typescript
// Read base token metadata
const [symbol, name, , icon] = tx.moveCall({
  target: 'account_actions::currency::read_coin_metadata',
  arguments: [baseMetadata],
  typeArguments: [BaseType],
});

// Create conditional coin with matching branding
tx.moveCall({
  target: 'conditional_token::create',
  arguments: [
    tx.pure.string(`c_${symbol}`),
    tx.pure.string(`Conditional ${name}`),
    icon
  ],
});
```

## Notes

- **Simple Helper**: Just wraps CoinMetadata getters in one call
- **No Validation**: Reads from any CoinMetadata object
- **Type Safe**: Move's type system ensures correct CoinType
- **Gas Efficient**: Single function call returns all fields
