module my_stable::my_stable {
    use sui::coin::{Self, Coin, TreasuryCap};
    use sui::transfer;
    use sui::tx_context::{Self, TxContext};
    use std::option;
	use sui::url::{Self, Url};

    /// The type identifier of our coin
    public struct MY_STABLE has drop {}

    /// Initialize new coin type and make TreasuryCap shared
    fun init(witness: MY_STABLE, ctx: &mut TxContext) {
        let (treasury, metadata) = coin::create_currency(
            witness,
            6,                  // decimals
            b"STABLE",       // symbol
            b"test_stable",               // name
            b"",              // description
            option::some(url::new_unsafe_from_bytes(b"https://s3.coinmarketcap.com/static-gravity/image/5a8229787b5e4c809b5914eef709b59a.png")),       // url
            ctx
        );
        // Freeze the metadata object
        transfer::public_freeze_object(metadata);
        // Make the treasury cap shared so anyone can mint
        transfer::public_share_object(treasury);
    }

    /// Mint new coins. Anyone can mint since TreasuryCap is shared.
    public entry fun mint(
        treasury_cap: &mut TreasuryCap<MY_STABLE>, 
        amount: u64, 
        recipient: address, 
        ctx: &mut TxContext
    ) {
        let coin = coin::mint(treasury_cap, amount, ctx);
        transfer::public_transfer(coin, recipient)
    }

    /// Burn coins. Anyone can burn since TreasuryCap is shared.
    public entry fun burn(
        treasury_cap: &mut TreasuryCap<MY_STABLE>,
        coin_to_burn: Coin<MY_STABLE>
    ): u64 {
        coin::burn(treasury_cap, coin_to_burn)
    }
}