#[test_only]
module futarchy_markets_primitives::test_conditional_coins;

use sui::coin;

// === Conditional Coin Types for Testing ===
// These are blank coin types used for testing conditional markets
// Pattern: Cond{N}{Type} where N is outcome index, Type is Asset or Stable
// Each coin type follows the proper OTW pattern with init() function

// === Outcome 0 Asset Conditional Coin ===

public struct COND0_ASSET has drop {}

fun init_cond0_asset(witness: COND0_ASSET, ctx: &mut TxContext) {
    let (treasury_cap, metadata) = coin::create_currency(
        witness,
        0,  // decimals
        b"",  // empty symbol
        b"",  // empty name
        b"",  // empty description
        option::none(),  // no icon url
        ctx
    );
    transfer::public_transfer(treasury_cap, ctx.sender());
    transfer::public_transfer(metadata, ctx.sender());
}

#[test_only]
public fun init_cond0_asset_for_testing(ctx: &mut TxContext) {
    init_cond0_asset(COND0_ASSET {}, ctx);
}

// === Outcome 0 Stable Conditional Coin ===

public struct COND0_STABLE has drop {}

fun init_cond0_stable(witness: COND0_STABLE, ctx: &mut TxContext) {
    let (treasury_cap, metadata) = coin::create_currency(
        witness,
        0,
        b"",
        b"",
        b"",
        option::none(),
        ctx
    );
    transfer::public_transfer(treasury_cap, ctx.sender());
    transfer::public_transfer(metadata, ctx.sender());
}

#[test_only]
public fun init_cond0_stable_for_testing(ctx: &mut TxContext) {
    init_cond0_stable(COND0_STABLE {}, ctx);
}

// === Outcome 1 Asset Conditional Coin ===

public struct COND1_ASSET has drop {}

fun init_cond1_asset(witness: COND1_ASSET, ctx: &mut TxContext) {
    let (treasury_cap, metadata) = coin::create_currency(
        witness,
        0,
        b"",
        b"",
        b"",
        option::none(),
        ctx
    );
    transfer::public_transfer(treasury_cap, ctx.sender());
    transfer::public_transfer(metadata, ctx.sender());
}

#[test_only]
public fun init_cond1_asset_for_testing(ctx: &mut TxContext) {
    init_cond1_asset(COND1_ASSET {}, ctx);
}

// === Outcome 1 Stable Conditional Coin ===

public struct COND1_STABLE has drop {}

fun init_cond1_stable(witness: COND1_STABLE, ctx: &mut TxContext) {
    let (treasury_cap, metadata) = coin::create_currency(
        witness,
        0,
        b"",
        b"",
        b"",
        option::none(),
        ctx
    );
    transfer::public_transfer(treasury_cap, ctx.sender());
    transfer::public_transfer(metadata, ctx.sender());
}

#[test_only]
public fun init_cond1_stable_for_testing(ctx: &mut TxContext) {
    init_cond1_stable(COND1_STABLE {}, ctx);
}

// === Outcome 2 Asset Conditional Coin ===

public struct COND2_ASSET has drop {}

fun init_cond2_asset(witness: COND2_ASSET, ctx: &mut TxContext) {
    let (treasury_cap, metadata) = coin::create_currency(
        witness,
        0,
        b"",
        b"",
        b"",
        option::none(),
        ctx
    );
    transfer::public_transfer(treasury_cap, ctx.sender());
    transfer::public_transfer(metadata, ctx.sender());
}

#[test_only]
public fun init_cond2_asset_for_testing(ctx: &mut TxContext) {
    init_cond2_asset(COND2_ASSET {}, ctx);
}

// === Outcome 2 Stable Conditional Coin ===

public struct COND2_STABLE has drop {}

fun init_cond2_stable(witness: COND2_STABLE, ctx: &mut TxContext) {
    let (treasury_cap, metadata) = coin::create_currency(
        witness,
        0,
        b"",
        b"",
        b"",
        option::none(),
        ctx
    );
    transfer::public_transfer(treasury_cap, ctx.sender());
    transfer::public_transfer(metadata, ctx.sender());
}

#[test_only]
public fun init_cond2_stable_for_testing(ctx: &mut TxContext) {
    init_cond2_stable(COND2_STABLE {}, ctx);
}
