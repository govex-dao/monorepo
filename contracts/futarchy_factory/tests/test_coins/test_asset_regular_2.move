#[test_only]
#[allow(deprecated_usage)]
module futarchy_factory::test_asset_regular_2;

use sui::coin;

// OTW-compliant: struct name matches uppercase(module_name)
public struct TEST_ASSET_REGULAR_2 has drop {}

#[test_only]
#[allow(deprecated_usage)]public fun init_for_testing(ctx: &mut TxContext) {
    let witness = TEST_ASSET_REGULAR_2 {};
    let (treasury_cap, deny_cap, metadata) = coin::create_regulated_currency_v2(
        witness,
        6,
        b"TAS2",
        b"Test Asset Regular 2",
        b"",
        option::none(),
        false,
        ctx
    );
    transfer::public_freeze_object(deny_cap);
    transfer::public_transfer(treasury_cap, ctx.sender());
    transfer::public_transfer(metadata, ctx.sender());
}
