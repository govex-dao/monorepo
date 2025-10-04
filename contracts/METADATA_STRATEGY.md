# DAO Token Metadata Strategy

## Overview

DAOs can now choose between **hardcoded metadata** (set at creation) or **dynamic metadata reading** from their locked TreasuryCap.

## Configuration Flag

Added to `ConditionalCoinConfig` in `/contracts/futarchy_core/sources/dao_config.move`:

```move
public struct ConditionalCoinConfig has store, drop, copy {
    coin_name_prefix: AsciiString,       // Prefix for coin names (e.g., "MyDAO_")
    coin_icon_url: Url,                  // Icon URL for conditional coins
    use_outcome_index: bool,             // If true, append outcome index to name
    use_hardcoded_metadata: bool,        // NEW: If true, use hardcoded; if false, read from TreasuryCap
}
```

## Usage Pattern

### Option 1: Hardcoded Metadata (Default - Backward Compatible)

```typescript
// At DAO creation
const config = {
  // ...
  conditional_coin_config: {
    coin_name_prefix: 'MyDAO_',
    coin_icon_url: 'https://mydao.com/icon.png',
    use_outcome_index: true,
    use_hardcoded_metadata: true  // ← Use hardcoded values
  }
};

// During proposal creation - use hardcoded values from config
const metadata = {
  symbol: config.conditional_coin_config.coin_name_prefix,
  icon: config.conditional_coin_config.coin_icon_url
};
```

### Option 2: Dynamic Reading from CoinMetadata

```typescript
// At DAO creation
const config = {
  // ...
  conditional_coin_config: {
    coin_name_prefix: '',  // Ignored when use_hardcoded_metadata = false
    coin_icon_url: '',     // Ignored when use_hardcoded_metadata = false
    use_outcome_index: true,
    use_hardcoded_metadata: false  // ← Read from CoinMetadata
  }
};

// During proposal creation - read from CoinMetadata
const tx = new Transaction();

// Check the flag
const coinConfig = daoConfig.conditional_coin_config;
if (!coinConfig.use_hardcoded_metadata) {
  // Read actual metadata from CoinMetadata object
  const [symbol, name, desc, icon] = tx.moveCall({
    target: 'account_actions::currency::read_coin_metadata',
    arguments: [coinMetadata],
    typeArguments: [DaoTokenType],
  });

  // Use in proposal
  tx.moveCall({
    target: 'futarchy_markets::proposal::create',
    arguments: [/* ... */, symbol, name, icon, /* ... */],
  });
} else {
  // Use hardcoded values from config
  tx.moveCall({
    target: 'futarchy_markets::proposal::create',
    arguments: [
      /* ... */,
      coinConfig.coin_name_prefix,
      coinConfig.coin_icon_url,
      /* ... */
    ],
  });
}
```

## Implementation Flow

### Frontend Logic

```typescript
async function createProposal(dao: DAO, proposalData: ProposalData) {
  const tx = new Transaction();
  const config = dao.config;
  const coinConfig = config.conditional_coin_config;

  let symbol, name, icon;

  if (coinConfig.use_hardcoded_metadata) {
    // Strategy 1: Use hardcoded metadata
    symbol = coinConfig.coin_name_prefix;
    icon = coinConfig.coin_icon_url;
    name = `${coinConfig.coin_name_prefix} Conditional`;
  } else {
    // Strategy 2: Read from CoinMetadata
    [symbol, name, , icon] = tx.moveCall({
      target: 'account_actions::currency::read_coin_metadata',
      arguments: [
        tx.object(dao.coinMetadataId)
      ],
      typeArguments: [
        dao.tokenType
      ],
    });
  }

  // Create proposal with appropriate metadata
  tx.moveCall({
    target: 'futarchy_markets::proposal::create',
    arguments: [
      /* ... other args ... */,
      symbol,
      name,
      icon,
      /* ... */
    ],
  });

  return tx;
}
```

## Benefits by Strategy

### Hardcoded Metadata (use_hardcoded_metadata = true)

✅ **Pros:**
- Faster (no extra read call)
- Simpler PTB structure
- Gas efficient
- Known values at DAO creation

❌ **Cons:**
- Metadata can drift from actual token
- Must update config if token metadata changes
- Less dynamic

### Dynamic Reading (use_hardcoded_metadata = false)

✅ **Pros:**
- Always matches actual DAO token
- Automatically updates if token metadata changes
- No config updates needed
- Trusted verification via TreasuryCap ownership

❌ **Cons:**
- Extra PTB call required
- Slightly higher gas cost
- Requires CoinMetadata object reference

## Default Behavior

```move
public fun default_conditional_coin_config(): ConditionalCoinConfig {
    ConditionalCoinConfig {
        coin_name_prefix: ascii::string(b"c_"),
        coin_icon_url: url::new_unsafe(ascii::string(b"https://via.placeholder.com/150")),
        use_outcome_index: true,
        use_hardcoded_metadata: true,  // ← Default: backward compatible
    }
}
```

**Default is `true` for backward compatibility** - existing DAOs continue using hardcoded metadata.

## Getter Function

```move
// In dao_config.move:422
public fun use_hardcoded_metadata(coin_config: &ConditionalCoinConfig): bool {
    coin_config.use_hardcoded_metadata
}
```

## Migration Strategy

### For Existing DAOs
- No changes required - defaults to `use_hardcoded_metadata: true`
- Continues using existing hardcoded prefix/icon

### For New DAOs
- Choose strategy at creation:
  - `true` = Hardcoded (simpler, faster)
  - `false` = Dynamic (always accurate)

### To Switch Strategies
Update DAO config via governance proposal:
```move
futarchy_config::update_conditional_coin_config(
    config,
    new_conditional_coin_config(
        prefix,
        icon,
        use_index,
        false  // ← Switch to dynamic reading
    )
)
```

## Security Notes

### Hardcoded Mode
- No security implications
- Values are stored in DAO config
- Can be updated via governance

### Dynamic Mode
- **Secure**: Uses `read_locked_coin_metadata` with TreasuryCap verification
- **Type-safe**: Move's type system enforces correct CoinMetadata
- **Trusted**: Verifies DAO owns TreasuryCap for the coin type
- See: `/contracts/move-framework/packages/actions/METADATA_READING.md`

## Recommendation

**For most DAOs**: Use `use_hardcoded_metadata: false` (dynamic reading)
- Ensures metadata always matches actual token
- Prevents drift between config and reality
- Minimal gas overhead for accuracy guarantee

**Use hardcoded only if**:
- Gas optimization is critical
- Metadata will never change
- Simplicity is preferred over accuracy
