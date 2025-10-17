#[test_only]
module futarchy_lifecycle::dissolution_flow_tests;

use account_extensions::extensions as extensions;
use account_protocol::account::{Self, Account};
use account_protocol::executable::{Self, Executable};
use account_protocol::intents;
use account_protocol::version_witness;
use futarchy_types::action_type_markers;
use futarchy_core::futarchy_config::{Self, FutarchyConfig};
use futarchy_lifecycle::dissolution_actions;
use futarchy_lifecycle::dissolution_auction;
use futarchy_markets_core::unified_spot_pool;
use futarchy_vault::futarchy_vault;
use std::bcs;
use std::string;
use std::vector;
use sui::clock::{Self as clock, Clock};
use sui::coin as coin;
use sui::object::{Self as object, UID, ID};
use sui::sui::SUI;
use sui::test_scenario as ts;
use sui::tx_context::TxContext;

const ADMIN: address = @0xA;
const ALICE: address = @0xA11CE;
const BOB: address = @0xB0B;

/// Dummy asset coin for AMM testing
public struct TEST_ASSET has drop {}
/// Dummy stable coin for AMM testing
public struct TEST_STABLE has drop {}

/// Collectible object to auction during dissolution
public struct TestCollectible has key, store {
    id: UID,
}

fun create_test_account(scenario: &mut ts::Scenario): Account<FutarchyConfig> {
    let extensions = extensions::empty(ts::ctx(scenario));
    futarchy_config::new_account(
        string::utf8(b"Test DAO"),
        extensions,
        ts::ctx(scenario),
    )
}

fun create_collectible(ctx: &mut TxContext): TestCollectible {
    TestCollectible { id: object::new(ctx) }
}

fun destroy_collectible(collectible: TestCollectible) {
    let TestCollectible { id } = collectible;
    object::delete(id);
}

#[test]
fun test_dissolution_happy_path() {
    let mut scenario = ts::begin(ADMIN);
    let mut account = create_test_account(&mut scenario);
    let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
    // Initialize vault storage for completeness
    futarchy_vault::init_vault(
        &mut account,
        version_witness::test_create(),
        ts::ctx(&mut scenario),
    );

    // Prepare AMM pool that we will withdraw during dissolution
    let mut pool = unified_spot_pool::create_pool_for_testing<TEST_ASSET, TEST_STABLE>(
        1_000,
        2_000,
        30,
        ts::ctx(&mut scenario),
    );
    let pool_id = object::id(&pool);
    let lp_supply = unified_spot_pool::lp_supply(&pool);

    // Object that will be auctioned during dissolution
    let collectible = create_collectible(ts::ctx(&mut scenario));
    let collectible_id = object::id(&collectible);

    // Build dissolution intent with required actions
    let mut builder = intents::intent_builder(ts::ctx(&mut scenario));

    let init_action = dissolution_actions::new_initiate_dissolution_action(
        string::utf8(b"Protocol wind-down"),
        0,
        true,
        86_400_000,
    );
    intents::add_action(
        &mut builder,
        action_types::initiate_dissolution(),
        bcs::to_bytes(&init_action),
    );

    let cancel_streams_action = dissolution_actions::new_cancel_all_streams_action(true);
    intents::add_action(
        &mut builder,
        action_types::cancel_all_streams(),
        bcs::to_bytes(&cancel_streams_action),
    );

    let pro_rata_action = dissolution_actions::new_calculate_pro_rata_shares_action(1_000, false);
    intents::add_action(
        &mut builder,
        action_types::calculate_pro_rata_shares(),
        bcs::to_bytes(&pro_rata_action),
    );

    let withdraw_action = dissolution_actions::new_withdraw_amm_liquidity_action<
        TEST_ASSET,
        TEST_STABLE,
    >(
        pool_id,
        lp_supply,
        true,
    );
    intents::add_action(
        &mut builder,
        action_types::withdraw_all_spot_liquidity(),
        bcs::to_bytes(&withdraw_action),
    );

    let create_auction_action = dissolution_actions::new_create_auction_action<
        TestCollectible,
        SUI,
    >(
        collectible_id,
        10,
        86_400_000,
    );
    intents::add_action(
        &mut builder,
        action_types::create_auction(),
        bcs::to_bytes(&create_auction_action),
    );

    let distribute_action = dissolution_actions::new_distribute_assets_action<SUI>(
        vector[ALICE, BOB],
        vector[1, 1],
        100,
    );
    intents::add_action(
        &mut builder,
        action_types::distribute_asset(),
        bcs::to_bytes(&distribute_action),
    );

    let finalize_action = dissolution_actions::new_finalize_dissolution_action(
        ADMIN,
        false,
    );
    intents::add_action(
        &mut builder,
        action_types::finalize_dissolution(),
        bcs::to_bytes(&finalize_action),
    );

    let intent_spec = intents::build(builder);
    let mut executable = executable::test_new<u8>(intent_spec, 0);

    // Step 1: initiate dissolution
    dissolution_actions::do_initiate_dissolution<u8, bool>(
        &mut executable,
        &mut account,
        version_witness::test_create(),
        false,
        ts::ctx(&mut scenario),
    );
    assert!(futarchy_config::operational_state(futarchy_config::state(&account)) == 1, 0);

    // Step 2: cancel streams (no streams exist, but ensures action routing works)
    dissolution_actions::do_cancel_all_streams<u8, SUI, bool>(
        &mut executable,
        &mut account,
        version_witness::test_create(),
        false,
        &clock,
        ts::ctx(&mut scenario),
    );

    // Step 3: calculate pro-rata shares metadata
    dissolution_actions::do_calculate_pro_rata_shares<u8, bool>(
        &mut executable,
        &mut account,
        version_witness::test_create(),
        false,
        ts::ctx(&mut scenario),
    );

    // Step 4: withdraw AMM liquidity via resource request pattern
    let withdraw_request = dissolution_actions::do_withdraw_amm_liquidity<
        u8,
        TEST_ASSET,
        TEST_STABLE,
        bool,
    >(
        &mut executable,
        &mut account,
        version_witness::test_create(),
        false,
        ts::ctx(&mut scenario),
    );
    let (
        asset_coin,
        stable_coin,
        withdraw_receipt,
    ) = dissolution_actions::fulfill_withdraw_amm_liquidity<TEST_ASSET, TEST_STABLE>(
        withdraw_request,
        &mut pool,
        ts::ctx(&mut scenario),
    );
    dissolution_actions::confirm_withdraw_amm_liquidity(withdraw_receipt);
    coin::burn_for_testing(asset_coin);
    coin::burn_for_testing(stable_coin);

    // Step 5: create auction and finalize it after expiry
    let create_request = dissolution_actions::do_create_auction<u8, bool>(
        &mut executable,
        &mut account,
        version_witness::test_create(),
        false,
        ts::ctx(&mut scenario),
    );
    let auction_id = dissolution_actions::fulfill_create_auction<TestCollectible, SUI>(
        create_request,
        &mut account,
        collectible,
        &clock,
        ts::ctx(&mut scenario),
    );
    assert!(auction_id != @0x0.to_id(), 1);

    clock::increment_for_testing(&mut clock, 86_400_001);
    {
        let mut auction = ts::take_shared<dissolution_auction::DissolutionAuction<SUI>>(&scenario);
        let (
            collectible_back,
            winning_coin,
            finalize_receipt,
        ) = dissolution_auction::finalize_auction<TestCollectible, SUI>(
            &mut auction,
            &mut account,
            &clock,
            ts::ctx(&mut scenario),
        );
        destroy_collectible(collectible_back);
        coin::burn_for_testing(winning_coin);
        let (_finalized_id, _winner, _amount) = dissolution_auction::confirm_finalization(
            finalize_receipt,
        );
        ts::return_shared(auction);
    };
    assert!(dissolution_auction::all_auctions_complete(&account), 2);

    // Step 6: distribute assets (exact split, no remainder)
    let distribution_coin = coin::mint_for_testing<SUI>(100, ts::ctx(&mut scenario));
    dissolution_actions::do_distribute_assets<u8, SUI, bool>(
        &mut executable,
        &mut account,
        version_witness::test_create(),
        false,
        distribution_coin,
        ts::ctx(&mut scenario),
    );

    // Step 7: finalize dissolution
    dissolution_actions::do_finalize_dissolution<u8, bool>(
        &mut executable,
        &mut account,
        version_witness::test_create(),
        false,
        ts::ctx(&mut scenario),
    );
    assert!(futarchy_config::operational_state(futarchy_config::state(&account)) == 3, 3);
    assert!(executable::action_idx(&executable) == 7, 4);

    // Cleanup test resources
    unified_spot_pool::destroy_for_testing<TEST_ASSET, TEST_STABLE>(pool);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = 5)] // EDissolutionNotActive
fun test_double_finalization_fails() {
    let mut scenario = ts::begin(ADMIN);
    let mut account = create_test_account(&mut scenario);
    let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
    futarchy_vault::init_vault(
        &mut account,
        version_witness::test_create(),
        ts::ctx(&mut scenario),
    );

    // Create simple dissolution intent with only initiate and finalize actions
    let mut builder = intents::intent_builder(ts::ctx(&mut scenario));

    let init_action = dissolution_actions::new_initiate_dissolution_action(
        string::utf8(b"Test double finalization protection"),
        0,
        true,
        86_400_000,
    );
    intents::add_action(
        &mut builder,
        action_types::initiate_dissolution(),
        bcs::to_bytes(&init_action),
    );

    let finalize_action = dissolution_actions::new_finalize_dissolution_action(
        ADMIN,
        false,
    );
    intents::add_action(
        &mut builder,
        action_types::finalize_dissolution(),
        bcs::to_bytes(&finalize_action),
    );

    let intent_spec = intents::build(builder);
    let mut executable = executable::test_new<u8>(intent_spec, 0);

    // Step 1: Initiate dissolution (state -> DISSOLVING)
    dissolution_actions::do_initiate_dissolution<u8, bool>(
        &mut executable,
        &mut account,
        version_witness::test_create(),
        false,
        ts::ctx(&mut scenario),
    );
    assert!(futarchy_config::operational_state(futarchy_config::state(&account)) == 1, 0);

    // Initialize auction counter (required before finalization)
    dissolution_auction::init_auction_counter(&mut account);

    // Step 2: First finalization succeeds (state -> DISSOLVED)
    dissolution_actions::do_finalize_dissolution<u8, bool>(
        &mut executable,
        &mut account,
        version_witness::test_create(),
        false,
        ts::ctx(&mut scenario),
    );
    assert!(futarchy_config::operational_state(futarchy_config::state(&account)) == 3, 1);
    assert!(executable::action_idx(&executable) == 2, 2);

    // Step 3: Attempt second finalization - SHOULD FAIL
    // State is DISSOLVED (3), but finalize checks for DISSOLVING (1)
    // This will abort with EDissolutionNotActive (code 5)
    dissolution_actions::do_finalize_dissolution<u8, bool>(
        &mut executable,
        &mut account,
        version_witness::test_create(),
        false,
        ts::ctx(&mut scenario),
    );

    // Cleanup (never reached due to expected abort)
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}
