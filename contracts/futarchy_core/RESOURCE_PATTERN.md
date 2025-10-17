# The ONE Resource Pattern for Intents

## Concept

Actions are pure data. Resources (coins, objects) are provided in a Bag attached to the Executable.

```
Intent (data) → Executable + Resource Bag → Actions consume resources → Bag empty
```

## Usage

### 1. Create Intent (Pure Data)

```move
// Intent stores WHAT to do, not HOW to fund it
let mut intent = account::create_intent(...);

vault::new_deposit<Outcome, SUI, IW>(
    &mut intent,
    b"treasury".to_string(),
    1000, // amount (data only)
    witness,
);

liquidity_intents::add_liquidity<Outcome, SUI, USDC, IW>(
    &mut intent,
    1000, // sui amount
    1000, // usdc amount
    900,  // min lp
    witness,
);

account::insert_intent(account, intent, version, witness);
```

### 2. Execute with Resources (Entry Function)

```move
use futarchy_core::executable_resources as resources;
use account_protocol::executable;

public entry fun execute_with_coins<AssetType, StableType>(
    account: &mut Account<FutarchyConfig>,
    intent_key: String,
    asset_coin: Coin<AssetType>,
    stable_coin: Coin<StableType>,
    pool: &mut UnifiedSpotPool<AssetType, StableType>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Create executable
    let (_outcome, mut exec) = account::create_executable<_, _, MyWitness>(
        account,
        intent_key,
        clock,
        version::current(),
        MyWitness {},
        ctx,
    );

    // Provide resources
    let exec_uid = executable::uid_mut_internal(&mut exec);
    resources::provide_coin(exec_uid, b"asset".to_string(), asset_coin, ctx);
    resources::provide_coin(exec_uid, b"stable".to_string(), stable_coin, ctx);

    // Execute actions (they'll take resources from bag)
    vault::do_deposit<_, _, AssetType, _>(&mut exec, account, version::current(), MyWitness {}, clock, ctx);
    liquidity_actions::do_add_liquidity<AssetType, StableType, _, _>(&mut exec, account, pool, version::current(), MyWitness {}, clock, ctx);

    // Verify all resources consumed
    resources::destroy_resources(executable::uid_mut_internal(&mut exec));

    // Confirm execution
    account::confirm_execution(account, exec);
}
```

### 3. Action Executors Take Resources

```move
// In vault.move or wherever
public fun do_deposit<Config, Outcome, CoinType, IW>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<Config>,
    version: Version,
    witness: IW,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let action: DepositAction = /* parse from executable */;

    // Take coin from resources
    let exec_uid = executable::uid_mut_internal(executable);
    let coin = resources::take_coin<Outcome, CoinType>(
        exec_uid,
        b"deposit".to_string(), // or get name from action
    );

    // Use coin
    vault::deposit(account, action.vault_name, coin, version);
}
```

### 4. Liquidity Actions Use Resources

```move
public fun do_add_liquidity<AssetType, StableType, Outcome, IW>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    pool: &mut UnifiedSpotPool<AssetType, StableType>,
    version: Version,
    witness: IW,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let action: AddLiquidityAction = /* parse from executable */;

    // Take both coins from resources
    let exec_uid = executable::uid_mut_internal(executable);
    let asset_coin = resources::take_coin<Outcome, AssetType>(exec_uid, b"asset".to_string());
    let stable_coin = resources::take_coin<Outcome, StableType>(exec_uid, b"stable".to_string());

    // Add liquidity
    let lp_tokens = unified_spot_pool::add_liquidity(
        pool,
        asset_coin,
        stable_coin,
        action.min_lp_out,
        clock,
        ctx,
    );

    // Store LP tokens in account
    vault::deposit(account, b"lp_vault".to_string(), lp_tokens, version);
}
```

## Benefits

### ✅ Flexible
- Works for ANY action that needs resources
- Mix any actions in one intent
- No need for specific "batch" functions

### ✅ Simple
- One module (`executable_resources.move`)
- 3 functions: `provide_coin`, `take_coin`, `destroy_resources`
- Actions just take what they need

### ✅ Type-Safe
- Coins are typed at provision/take
- Compiler enforces correct types
- Runtime checks for existence

### ✅ Composable
- PTB can orchestrate complex flows
- Resources can be split/merged
- Works with existing action system

### ✅ Secure
- Intent created first (tamper-proof parameters)
- Resources verified at execution
- Must consume all resources (bag must be empty)

## Naming Conventions

Standard names for common resources:

| Resource | Name |
|----------|------|
| Asset coin for LP | `"asset"` |
| Stable coin for LP | `"stable"` |
| Coin for deposit | `"deposit"` |
| Stream funding | `"funding"` |
| Action-specific | `"action_{index}"` |

Actions can also encode resource names in their action data if needed.

## PTB Example

```typescript
const tx = new Transaction();

// Get coins
const assetCoin = tx.splitCoins(tx.gas, [1000]);
const stableCoin = tx.splitCoins(tx.gas, [1000]);

// Execute with resources
tx.moveCall({
  target: `${pkg}::my_module::execute_with_coins`,
  arguments: [
    account,
    intentKey,
    assetCoin,    // Provided here
    stableCoin,   // Provided here
    pool,
    clock,
  ],
  typeArguments: [assetType, stableType],
});
```

## Init Intents

For init intents, use the same pattern:
- Actions are data-only
- Resources provisioned during `complete_raise`
- Same `executable_resources` functions

## That's It

One pattern. One module. Works for everything.
