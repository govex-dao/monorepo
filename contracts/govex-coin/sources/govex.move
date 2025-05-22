module govex::govex {
    use sui::coin;
    use sui::url;

    const TOTAL_GVX_SUPPLY_TO_MINT: u64 = 750_000_000; // 750M govex
    const DECIMALS: u8 = 9;
    const SYMBOL: vector<u8> = b"GOVEX";
    const NAME: vector<u8> = b"Govex";
    const DESCRIPTION: vector<u8> = b"The native token for the Govex Protocol.";
    const ICON_URL: vector<u8> = b"https://www.govex.ai/images/govex-icon.png";

    /// The type identifier of our coin
    public struct GOVEX has drop {}

    /// Initialize new coin type
    fun init(witness: GOVEX, ctx: &mut TxContext) {
        let (mut treasury_cap, metadata) = coin::create_currency<GOVEX>(
            witness,
            DECIMALS,
            SYMBOL,
            NAME,
            DESCRIPTION,
            option::some(url::new_unsafe_from_bytes(ICON_URL)),
            ctx
        );

        let units_per_govex = 10u64.pow(DECIMALS);
        let total_supply_to_mint = TOTAL_GVX_SUPPLY_TO_MINT * units_per_govex;

        // Transfer and mint the total initial supply of GVX to the publisher.
        coin::mint_and_transfer(&mut treasury_cap, total_supply_to_mint, ctx.sender(), ctx);

        // Return the metadata object, to keep the token metadata mutable.
        transfer::public_transfer(metadata, ctx.sender());

        // Return the treasury cap to the publisher, to keep the token mintable.
        transfer::public_transfer(treasury_cap, ctx.sender());
    }
}