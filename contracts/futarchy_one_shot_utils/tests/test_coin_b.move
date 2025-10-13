#[test_only]
module futarchy_one_shot_utils::test_coin_b;

use sui::coin;

/// One-Time Witness for TEST_COIN_B
public struct TEST_COIN_B has drop {}

/// Initialize function called when module is published
fun init(witness: TEST_COIN_B, ctx: &mut TxContext) {
    let (treasury_cap, metadata) = coin::create_currency(
        witness,
        6,  // decimals
        b"",  // empty symbol
        b"",  // empty name
        b"",  // empty description
        option::none(),  // no icon url
        ctx
    );

    // Transfer both to sender for use in tests
    // Don't freeze metadata so it can be moved into registry
    transfer::public_transfer(treasury_cap, ctx.sender());
    transfer::public_transfer(metadata, ctx.sender());
}

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(TEST_COIN_B {}, ctx);
}

#[test_only]
public fun create_with_name(ctx: &mut TxContext) {
    let (treasury_cap, metadata) = coin::create_currency(
        TEST_COIN_B {},
        6,
        b"",
        b"Test Coin Name",
        b"",
        option::none(),
        ctx
    );
    transfer::public_transfer(treasury_cap, ctx.sender());
    transfer::public_transfer(metadata, ctx.sender());
}

#[test_only]
public fun create_with_description(ctx: &mut TxContext) {
    let (treasury_cap, metadata) = coin::create_currency(
        TEST_COIN_B {},
        6,
        b"",
        b"",
        b"Test description",
        option::none(),
        ctx
    );
    transfer::public_transfer(treasury_cap, ctx.sender());
    transfer::public_transfer(metadata, ctx.sender());
}

#[test_only]
public fun create_with_symbol(ctx: &mut TxContext) {
    let (treasury_cap, metadata) = coin::create_currency(
        TEST_COIN_B {},
        6,
        b"TST",
        b"",
        b"",
        option::none(),
        ctx
    );
    transfer::public_transfer(treasury_cap, ctx.sender());
    transfer::public_transfer(metadata, ctx.sender());
}

#[test_only]
public fun create_with_icon(ctx: &mut TxContext) {
    use sui::url;
    let (treasury_cap, metadata) = coin::create_currency(
        TEST_COIN_B {},
        6,
        b"",
        b"",
        b"",
        option::some(url::new_unsafe_from_bytes(b"https://example.com/icon.png")),
        ctx
    );
    transfer::public_transfer(treasury_cap, ctx.sender());
    transfer::public_transfer(metadata, ctx.sender());
}

#[test_only]
public fun create_with_all_metadata(ctx: &mut TxContext) {
    use sui::url;
    let (treasury_cap, metadata) = coin::create_currency(
        TEST_COIN_B {},
        6,
        b"TST",
        b"Test Coin",
        b"A test coin",
        option::some(url::new_unsafe_from_bytes(b"https://example.com/icon.png")),
        ctx
    );
    transfer::public_transfer(treasury_cap, ctx.sender());
    transfer::public_transfer(metadata, ctx.sender());
}
