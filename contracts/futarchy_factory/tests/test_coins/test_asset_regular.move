#[test_only]
#[allow(deprecated_usage)]
module futarchy_factory::test_asset_regular;

use sui::coin;

// OTW-compliant: struct name matches uppercase(module_name)
public struct TEST_ASSET_REGULAR has drop {}

#[test_only]
#[allow(deprecated_usage)]public fun init_for_testing(ctx: &mut TxContext) {
    let witness = TEST_ASSET_REGULAR {};
    let (treasury_cap, deny_cap, metadata) = coin::create_regulated_currency_v2(
        witness,
        6,
        b"TASR",
        b"Test Asset Regular",
        b"",
        option::none(),
        false,
        ctx
    );
    transfer::public_freeze_object(deny_cap);
    transfer::public_transfer(treasury_cap, ctx.sender());
    transfer::public_transfer(metadata, ctx.sender());
}
