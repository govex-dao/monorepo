#[test_only]
module futarchy_markets_primitives::cond0_stable;

use sui::coin;

public struct COND0_STABLE has drop {}

fun init(witness: COND0_STABLE, ctx: &mut TxContext) {
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
public fun init_for_testing(ctx: &mut TxContext) {
    init(COND0_STABLE {}, ctx);
}
