#[test_only]
module futarchy_lifecycle::dissolution_actions_tests;

use std::string;
use futarchy_lifecycle::dissolution_actions;

// === Test Coin Types ===

public struct TEST_ASSET has drop {}
public struct TEST_STABLE has drop {}

// === Basic Constructor Tests ===

#[test]
fun test_new_initiate_dissolution_action() {
    let action = dissolution_actions::new_initiate_dissolution_action(
        string::utf8(b"Market price below NAV"),
        0,  // Pro-rata distribution
        true,  // Burn unsold tokens
        1000000,  // Deadline
    );

    assert!(*dissolution_actions::get_reason(&action) == string::utf8(b"Market price below NAV"), 0);
    assert!(dissolution_actions::get_distribution_method(&action) == 0, 1);
    assert!(dissolution_actions::get_burn_unsold_tokens(&action) == true, 2);
    assert!(dissolution_actions::get_final_operations_deadline(&action) == 1000000, 3);
}

#[test]
fun test_new_batch_distribute_action() {
    let asset_types = vector[
        string::utf8(b"0x1::sui::SUI"),
        string::utf8(b"0x2::usdc::USDC"),
    ];

    let action = dissolution_actions::new_batch_distribute_action(asset_types);

    assert!(dissolution_actions::get_asset_types(&action).length() == 2, 0);
}

#[test]
fun test_new_finalize_dissolution_action() {
    let recipient = @0x0000000000000000000000000000000000000000000000000000000000000A11CE;

    let action = dissolution_actions::new_finalize_dissolution_action(
        recipient,
        false,
    );

    assert!(dissolution_actions::get_final_recipient(&action) == recipient, 0);
    assert!(dissolution_actions::get_destroy_account(&action) == false, 1);
}

#[test]
fun test_new_cancel_dissolution_action() {
    let action = dissolution_actions::new_cancel_dissolution_action(
        string::utf8(b"Community voted to continue"),
    );

    assert!(*dissolution_actions::get_cancel_reason(&action) == string::utf8(b"Community voted to continue"), 0);
}

#[test]
fun test_new_calculate_pro_rata_shares_action() {
    let action = dissolution_actions::new_calculate_pro_rata_shares_action(
        1000000,  // total supply
        true,     // exclude DAO tokens
    );

    let _ = action;
}

#[test]
fun test_new_cancel_all_streams_action() {
    let action = dissolution_actions::new_cancel_all_streams_action(
        true,  // return to treasury
    );

    let _ = action;
}

#[test]
fun test_new_withdraw_amm_liquidity_action() {
    let pool_id = object::id_from_address(@0xPOOL);

    let action = dissolution_actions::new_withdraw_amm_liquidity_action<TEST_ASSET, TEST_STABLE>(
        pool_id,
        true,  // burn LP tokens
    );

    let _ = action;
}

#[test]
fun test_new_distribute_assets_action() {
    let holders = vector[
        @0x0000000000000000000000000000000000000000000000000000000000000A11CE,
        @0x0000000000000000000000000000000000000000000000000000000000000B0B,
        @0x0000000000000000000000000000000000000000000000000000000000000C11,
    ];
    let holder_amounts = vector[100, 200, 300];  // Tokens held by each

    let action = dissolution_actions::new_distribute_assets_action<TEST_ASSET>(
        holders,
        holder_amounts,
        10000,  // Total to distribute
    );

    let _ = action;
}

// === Error Path Tests ===

#[test]
#[expected_failure(abort_code = dissolution_actions::EInvalidRatio)]
fun test_initiate_dissolution_empty_reason_fails() {
    let _action = dissolution_actions::new_initiate_dissolution_action(
        string::utf8(b""),  // Empty reason - should fail
        0,
        true,
        1000000,
    );
}

#[test]
#[expected_failure(abort_code = dissolution_actions::EInvalidRatio)]
fun test_initiate_dissolution_invalid_method_fails() {
    let _action = dissolution_actions::new_initiate_dissolution_action(
        string::utf8(b"Test"),
        3,  // Invalid method (only 0, 1, 2 allowed)
        true,
        1000000,
    );
}

#[test]
#[expected_failure(abort_code = dissolution_actions::EEmptyAssetList)]
fun test_batch_distribute_empty_list_fails() {
    let _action = dissolution_actions::new_batch_distribute_action(
        vector[],  // Empty list - should fail
    );
}

#[test]
#[expected_failure(abort_code = dissolution_actions::EInvalidRecipient)]
fun test_finalize_dissolution_zero_address_fails() {
    let _action = dissolution_actions::new_finalize_dissolution_action(
        @0x0,  // Zero address - should fail
        false,
    );
}

#[test]
#[expected_failure(abort_code = dissolution_actions::EInvalidRatio)]
fun test_cancel_dissolution_empty_reason_fails() {
    let _action = dissolution_actions::new_cancel_dissolution_action(
        string::utf8(b""),  // Empty reason - should fail
    );
}

#[test]
#[expected_failure(abort_code = dissolution_actions::EInvalidRatio)]
fun test_calculate_pro_rata_zero_supply_fails() {
    let _action = dissolution_actions::new_calculate_pro_rata_shares_action(
        0,  // Zero supply - should fail
        true,
    );
}

#[test]
#[expected_failure(abort_code = dissolution_actions::EEmptyAssetList)]
fun test_distribute_assets_empty_holders_fails() {
    let _action = dissolution_actions::new_distribute_assets_action<TEST_ASSET>(
        vector[],  // Empty holders
        vector[],
        10000,
    );
}

#[test]
#[expected_failure(abort_code = dissolution_actions::EInvalidRatio)]
fun test_distribute_assets_mismatched_lengths_fails() {
    let _action = dissolution_actions::new_distribute_assets_action<TEST_ASSET>(
        vector[
            @0x0000000000000000000000000000000000000000000000000000000000000A11CE,
            @0x0000000000000000000000000000000000000000000000000000000000000B0B,
        ],
        vector[100],  // Mismatched length
        10000,
    );
}

#[test]
#[expected_failure(abort_code = dissolution_actions::EInvalidRatio)]
fun test_distribute_assets_zero_amount_fails() {
    let _action = dissolution_actions::new_distribute_assets_action<TEST_ASSET>(
        vector[@0x0000000000000000000000000000000000000000000000000000000000000A11CE],
        vector[100],
        0,  // Zero distribution amount
    );
}

#[test]
#[expected_failure(abort_code = dissolution_actions::EInvalidRatio)]
fun test_distribute_assets_zero_holder_amounts_fails() {
    let _action = dissolution_actions::new_distribute_assets_action<TEST_ASSET>(
        vector[
            @0x0000000000000000000000000000000000000000000000000000000000000A11CE,
            @0x0000000000000000000000000000000000000000000000000000000000000B0B,
        ],
        vector[0, 0],  // All zeros - sum is zero
        10000,
    );
}
