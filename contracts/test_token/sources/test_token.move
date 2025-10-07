module test_token::test_token {
    use sui::coin::{Self, TreasuryCap};
    use sui::url;

    /// One-time witness for token creation
    public struct TEST_TOKEN has drop {}

    /// Module initializer - called once when the module is published
    fun init(witness: TEST_TOKEN, ctx: &mut TxContext) {
        let (treasury_cap, metadata) = coin::create_currency(
            witness,
            9, // decimals
            b"TEST", // symbol
            b"Test Token", // name
            b"Test token for launchpad creation", // description
            option::some(url::new_unsafe_from_bytes(b"https://example.com/icon.png")), // icon URL
            ctx
        );

        // Transfer the TreasuryCap to the sender
        transfer::public_transfer(treasury_cap, tx_context::sender(ctx));

        // Freeze the metadata so it can't be changed
        transfer::public_freeze_object(metadata);
    }
}
