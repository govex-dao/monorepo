#[test_only]
module futarchy_one_shot_utils::test_coin_a;

use sui::coin;

/// One-Time Witness for TEST_COIN_A
public struct TEST_COIN_A has drop {}

/// Initialize function called when module is published
fun init(witness: TEST_COIN_A, ctx: &mut TxContext) {
    let (treasury_cap, metadata) = coin::create_currency(
        witness,
        6, // decimals
        b"", // empty symbol
        b"", // empty name
        b"", // empty description
        option::none(), // no icon url
        ctx,
    );

    // Transfer both to sender for use in tests
    // Don't freeze metadata so it can be moved into registry
    transfer::public_transfer(treasury_cap, ctx.sender());
    transfer::public_transfer(metadata, ctx.sender());
}

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(TEST_COIN_A {}, ctx);
}
