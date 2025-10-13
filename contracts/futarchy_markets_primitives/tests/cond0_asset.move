#[test_only]
module futarchy_markets_primitives::cond0_asset;

use sui::coin;

/// One-Time Witness for COND0_ASSET
public struct COND0_ASSET has drop {}

/// Initialize function called when module is published
fun init(witness: COND0_ASSET, ctx: &mut TxContext) {
    let (treasury_cap, metadata) = coin::create_currency(
        witness,
        0,  // decimals
        b"",  // empty symbol
        b"",  // empty name
        b"",  // empty description
        option::none(),  // no icon url
        ctx
    );

    // Transfer both to sender for use in tests
    transfer::public_transfer(treasury_cap, ctx.sender());
    transfer::public_transfer(metadata, ctx.sender());
}

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(COND0_ASSET {}, ctx);
}
