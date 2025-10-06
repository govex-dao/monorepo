#[test_only]
module futarchy_oracle::oracle_actions_tests;

use sui::test_scenario::{Self as ts, Scenario};
use sui::clock::{Self, Clock};
use sui::object;
use sui::test_utils;
use futarchy_oracle::oracle_actions::{Self, PriceBasedMintGrant, GrantClaimCap};

// === Test Coin Types ===

public struct ASSET_COIN has drop {}
public struct STABLE_COIN has drop {}

// === Test Constants ===

const ADMIN: address = @0xAD;
const RECIPIENT: address = @0xB0B;
const DAO_ID_ADDR: address = @0xDA0;

const ONE_DAY_MS: u64 = 86_400_000;
const ONE_MONTH_MS: u64 = 2_592_000_000; // 30 days
const ONE_YEAR_MS: u64 = 31_536_000_000;

// === Helper Functions ===

fun start_test(): Scenario {
    ts::begin(ADMIN)
}

// === Basic Creation Tests ===

#[test]
fun test_create_employee_option_basic() {
    let mut scenario = start_test();
    let test_clock = clock::create_for_testing(ts::ctx(&mut scenario));

    // Set initial time
    clock::set_for_testing(&test_clock, 1000);

    ts::next_tx(&mut scenario, ADMIN);
    {
        let ctx = ts::ctx(&mut scenario);

        // Create employee option grant
        oracle_actions::create_employee_option<ASSET_COIN, STABLE_COIN>(
            RECIPIENT,              // recipient
            100_000,                // total_amount (100k tokens)
            1_000_000_000,          // strike_price (1 STABLE per ASSET)
            3,                      // cliff_months (3 months)
            4,                      // total_vesting_years (4 years)
            3_000_000_000,          // launchpad_multiplier (3x)
            10,                     // expiry_years (10 years)
            object::id_from_address(DAO_ID_ADDR), // dao_id
            &test_clock,
            ctx,
        );
    };

    ts::next_tx(&mut scenario, RECIPIENT);
    {
        // Verify grant was created and shared
        assert!(ts::has_most_recent_shared<PriceBasedMintGrant<ASSET_COIN, STABLE_COIN>>(), 0);

        // Verify claim cap was transferred to recipient
        assert!(ts::has_most_recent_for_address<GrantClaimCap>(RECIPIENT), 1);
    };

    test_utils::destroy(test_clock);
    ts::end(scenario);
}

#[test]
fun test_create_vesting_grant_basic() {
    let mut scenario = start_test();
    let test_clock = clock::create_for_testing(ts::ctx(&mut scenario));

    clock::set_for_testing(&test_clock, 1000);

    ts::next_tx(&mut scenario, ADMIN);
    {
        let ctx = ts::ctx(&mut scenario);

        // Create simple vesting grant
        oracle_actions::create_vesting_grant<ASSET_COIN, STABLE_COIN>(
            RECIPIENT,              // recipient
            50_000,                 // total_amount (50k tokens)
            6,                      // cliff_months (6 months)
            2,                      // total_vesting_years (2 years)
            object::id_from_address(DAO_ID_ADDR), // dao_id
            &test_clock,
            ctx,
        );
    };

    ts::next_tx(&mut scenario, RECIPIENT);
    {
        // Verify grant was created
        assert!(ts::has_most_recent_shared<PriceBasedMintGrant<ASSET_COIN, STABLE_COIN>>(), 0);

        // Verify claim cap was transferred
        assert!(ts::has_most_recent_for_address<GrantClaimCap>(RECIPIENT), 1);
    };

    test_utils::destroy(test_clock);
    ts::end(scenario);
}
