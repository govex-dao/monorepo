#[test_only]
module futarchy_oracle::oracle_grant_tests;

use futarchy_oracle::oracle_actions::{Self, PriceBasedMintGrant, GrantClaimCap};
use std::string;
use sui::clock::{Self, Clock};
use sui::object;
use sui::test_scenario::{Self as ts, Scenario};
use sui::test_utils;

// === Test Coin Types ===

public struct ASSET has drop {}
public struct STABLE has drop {}

// === Test Constants ===

const ADMIN: address = @0xAD;
const RECIPIENT: address = @0xB0B;
const RECIPIENT2: address = @0xCA7;

const ONE_DAY_MS: u64 = 86_400_000;
const ONE_MONTH_MS: u64 = 2_592_000_000; // 30 days
const ONE_YEAR_MS: u64 = 31_536_000_000;

// ====================================================================
// === EMPLOYEE OPTIONS TESTS =========================================
// ====================================================================

#[test]
fun test_create_employee_option() {
    let mut scenario = ts::begin(ADMIN);
    let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
    clock.set_for_testing(1000);

    ts::next_tx(&mut scenario, ADMIN);
    {
        let _grant_id = oracle_actions::create_employee_option<ASSET, STABLE>(
            RECIPIENT,
            100_000, // 100k tokens
            1_000_000, // strike price
            3, // 3 month cliff
            4, // 4 year vesting
            3_000_000_000, // 3x launchpad multiplier
            10, // 10 year expiry
            object::id_from_address(@0xDA0),
            &clock,
            ts::ctx(&mut scenario),
        );
    };

    ts::next_tx(&mut scenario, RECIPIENT);
    {
        assert!(ts::has_most_recent_shared<PriceBasedMintGrant<ASSET, STABLE>>(), 0);
        assert!(ts::has_most_recent_for_address<GrantClaimCap>(RECIPIENT), 1);
    };

    test_utils::destroy(clock);
    ts::end(scenario);
}

#[test]
fun test_employee_option_view_functions() {
    let mut scenario = ts::begin(ADMIN);
    let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
    clock.set_for_testing(1000);

    ts::next_tx(&mut scenario, ADMIN);
    let grant_id = oracle_actions::create_employee_option<ASSET, STABLE>(
        RECIPIENT,
        100_000,
        1_000_000,
        3,
        4,
        3_000_000_000,
        10,
        object::id_from_address(@0xDA0),
        &clock,
        ts::ctx(&mut scenario),
    );

    ts::next_tx(&mut scenario, ADMIN);
    {
        let grant = ts::take_shared_by_id<PriceBasedMintGrant<ASSET, STABLE>>(&scenario, grant_id);

        assert!(oracle_actions::total_amount(&grant) == 100_000, 0);
        assert!(oracle_actions::claimed_amount(&grant) == 0, 1);
        assert!(!oracle_actions::is_canceled(&grant), 2);
        assert!(*oracle_actions::description(&grant) == string::utf8(b"Employee Stock Option"), 3);

        ts::return_shared(grant);
    };

    test_utils::destroy(clock);
    ts::end(scenario);
}

#[test]
fun test_employee_option_before_cliff() {
    let mut scenario = ts::begin(ADMIN);
    let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
    clock.set_for_testing(1000);

    ts::next_tx(&mut scenario, ADMIN);
    let grant_id = oracle_actions::create_employee_option<ASSET, STABLE>(
        RECIPIENT,
        100_000,
        1_000_000,
        3, // 3 month cliff
        4,
        3_000_000_000,
        10,
        object::id_from_address(@0xDA0),
        &clock,
        ts::ctx(&mut scenario),
    );

    ts::next_tx(&mut scenario, ADMIN);
    {
        let grant = ts::take_shared_by_id<PriceBasedMintGrant<ASSET, STABLE>>(&scenario, grant_id);

        // Before cliff - nothing claimable
        let claimable = oracle_actions::claimable_now(&grant, &clock);
        assert!(claimable == 0, 0);

        ts::return_shared(grant);
    };

    test_utils::destroy(clock);
    ts::end(scenario);
}

#[test]
fun test_employee_option_after_cliff() {
    let mut scenario = ts::begin(ADMIN);
    let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
    clock.set_for_testing(1000);

    ts::next_tx(&mut scenario, ADMIN);
    let grant_id = oracle_actions::create_employee_option<ASSET, STABLE>(
        RECIPIENT,
        100_000,
        1_000_000,
        3, // 3 month cliff
        4,
        3_000_000_000,
        10,
        object::id_from_address(@0xDA0),
        &clock,
        ts::ctx(&mut scenario),
    );

    // Advance 4 months
    clock.increment_for_testing(4 * ONE_MONTH_MS);

    ts::next_tx(&mut scenario, ADMIN);
    {
        let grant = ts::take_shared_by_id<PriceBasedMintGrant<ASSET, STABLE>>(&scenario, grant_id);

        // After cliff - some vested
        let claimable = oracle_actions::claimable_now(&grant, &clock);
        assert!(claimable > 0, 0);
        assert!(claimable < 100_000, 1); // Not fully vested

        ts::return_shared(grant);
    };

    test_utils::destroy(clock);
    ts::end(scenario);
}

#[test]
fun test_employee_option_fully_vested() {
    let mut scenario = ts::begin(ADMIN);
    let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
    clock.set_for_testing(1000);

    ts::next_tx(&mut scenario, ADMIN);
    let grant_id = oracle_actions::create_employee_option<ASSET, STABLE>(
        RECIPIENT,
        100_000,
        1_000_000,
        3,
        4, // 4 year vesting
        3_000_000_000,
        10,
        object::id_from_address(@0xDA0),
        &clock,
        ts::ctx(&mut scenario),
    );

    // Advance 4 years
    clock.increment_for_testing(4 * ONE_YEAR_MS);

    ts::next_tx(&mut scenario, ADMIN);
    {
        let grant = ts::take_shared_by_id<PriceBasedMintGrant<ASSET, STABLE>>(&scenario, grant_id);

        // Fully vested
        let claimable = oracle_actions::claimable_now(&grant, &clock);
        assert!(claimable == 100_000, 0);

        ts::return_shared(grant);
    };

    test_utils::destroy(clock);
    ts::end(scenario);
}

// ====================================================================
// === CONDITIONAL MINT TESTS =========================================
// ====================================================================

#[test]
fun test_create_conditional_mint() {
    let mut scenario = ts::begin(ADMIN);
    let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));

    ts::next_tx(&mut scenario, ADMIN);
    {
        oracle_actions::create_conditional_mint<ASSET, STABLE>(
            RECIPIENT,
            1_000, // mint amount
            2_000_000_000_000, // price threshold
            true, // above threshold
            3_600_000, // 1 hour cooldown
            5, // max 5 executions
            object::id_from_address(@0xDA0),
            &clock,
            ts::ctx(&mut scenario),
        );
    };

    ts::next_tx(&mut scenario, RECIPIENT);
    {
        assert!(ts::has_most_recent_shared<PriceBasedMintGrant<ASSET, STABLE>>(), 0);
        assert!(ts::has_most_recent_for_address<GrantClaimCap>(RECIPIENT), 1);
    };

    test_utils::destroy(clock);
    ts::end(scenario);
}

// ====================================================================
// === MILESTONE REWARDS TESTS ========================================
// ====================================================================

#[test]
fun test_create_milestone_rewards() {
    let mut scenario = ts::begin(ADMIN);
    let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
    clock.set_for_testing(1000);

    ts::next_tx(&mut scenario, ADMIN);
    {
        let tier_multipliers = vector[
            2_000_000_000, // 2x
            3_000_000_000, // 3x
            5_000_000_000, // 5x
        ];

        let tier_recipients = vector[
            vector[oracle_actions::new_recipient_mint(RECIPIENT, 10_000)],
            vector[oracle_actions::new_recipient_mint(RECIPIENT, 20_000)],
            vector[oracle_actions::new_recipient_mint(RECIPIENT, 30_000)],
        ];

        let tier_descriptions = vector[
            string::utf8(b"Tier 1: 2x"),
            string::utf8(b"Tier 2: 3x"),
            string::utf8(b"Tier 3: 5x"),
        ];

        let now = clock.timestamp_ms();

        oracle_actions::create_milestone_rewards<ASSET, STABLE>(
            tier_multipliers,
            tier_recipients,
            tier_descriptions,
            now,
            now + ONE_YEAR_MS,
            object::id_from_address(@0xDA0),
            &clock,
            ts::ctx(&mut scenario),
        );
    };

    ts::next_tx(&mut scenario, ADMIN);
    {
        // Milestone rewards are shared (no individual claim cap)
        assert!(ts::has_most_recent_shared<PriceBasedMintGrant<ASSET, STABLE>>(), 0);
    };

    test_utils::destroy(clock);
    ts::end(scenario);
}

#[test]
fun test_milestone_rewards_multi_recipient() {
    let mut scenario = ts::begin(ADMIN);
    let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));

    ts::next_tx(&mut scenario, ADMIN);
    {
        let tier_multipliers = vector[2_000_000_000];

        let tier_recipients = vector[
            vector[
                oracle_actions::new_recipient_mint(RECIPIENT, 10_000),
                oracle_actions::new_recipient_mint(RECIPIENT2, 5_000),
            ],
        ];

        let tier_descriptions = vector[string::utf8(b"Team Bonus")];

        let now = clock.timestamp_ms();

        oracle_actions::create_milestone_rewards<ASSET, STABLE>(
            tier_multipliers,
            tier_recipients,
            tier_descriptions,
            now,
            now + ONE_YEAR_MS,
            object::id_from_address(@0xDA0),
            &clock,
            ts::ctx(&mut scenario),
        );
    };

    ts::next_tx(&mut scenario, ADMIN);
    {
        assert!(ts::has_most_recent_shared<PriceBasedMintGrant<ASSET, STABLE>>(), 0);
    };

    test_utils::destroy(clock);
    ts::end(scenario);
}

// ====================================================================
// === PAUSE/UNPAUSE TESTS ============================================
// ====================================================================

#[test]
fun test_pause_grant() {
    let mut scenario = ts::begin(ADMIN);
    let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
    clock.set_for_testing(1000);

    ts::next_tx(&mut scenario, ADMIN);
    let grant_id = oracle_actions::create_employee_option<ASSET, STABLE>(
        RECIPIENT,
        100_000,
        1_000_000,
        0, // No cliff for simpler testing
        1,
        3_000_000_000,
        10,
        object::id_from_address(@0xDA0),
        &clock,
        ts::ctx(&mut scenario),
    );

    ts::next_tx(&mut scenario, ADMIN);
    {
        let mut grant = ts::take_shared_by_id<PriceBasedMintGrant<ASSET, STABLE>>(
            &scenario,
            grant_id,
        );

        oracle_actions::pause_grant(&mut grant, ONE_DAY_MS, &clock);

        // Paused grant has 0 claimable
        let claimable = oracle_actions::claimable_now(&grant, &clock);
        assert!(claimable == 0, 0);

        ts::return_shared(grant);
    };

    test_utils::destroy(clock);
    ts::end(scenario);
}

#[test]
fun test_unpause_grant() {
    let mut scenario = ts::begin(ADMIN);
    let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
    clock.set_for_testing(1000);

    ts::next_tx(&mut scenario, ADMIN);
    let grant_id = oracle_actions::create_employee_option<ASSET, STABLE>(
        RECIPIENT,
        100_000,
        1_000_000,
        0,
        1,
        3_000_000_000,
        10,
        object::id_from_address(@0xDA0),
        &clock,
        ts::ctx(&mut scenario),
    );

    ts::next_tx(&mut scenario, ADMIN);
    {
        let mut grant = ts::take_shared_by_id<PriceBasedMintGrant<ASSET, STABLE>>(
            &scenario,
            grant_id,
        );

        oracle_actions::pause_grant(&mut grant, ONE_DAY_MS, &clock);
        oracle_actions::unpause_grant(&mut grant, &clock);

        ts::return_shared(grant);
    };

    test_utils::destroy(clock);
    ts::end(scenario);
}

#[test]
fun test_auto_unpause() {
    let mut scenario = ts::begin(ADMIN);
    let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
    clock.set_for_testing(1000);

    ts::next_tx(&mut scenario, ADMIN);
    let grant_id = oracle_actions::create_employee_option<ASSET, STABLE>(
        RECIPIENT,
        100_000,
        1_000_000,
        0,
        1,
        3_000_000_000,
        10,
        object::id_from_address(@0xDA0),
        &clock,
        ts::ctx(&mut scenario),
    );

    ts::next_tx(&mut scenario, ADMIN);
    {
        let mut grant = ts::take_shared_by_id<PriceBasedMintGrant<ASSET, STABLE>>(
            &scenario,
            grant_id,
        );

        // Pause for 1 day
        oracle_actions::pause_grant(&mut grant, ONE_DAY_MS, &clock);

        // Advance 2 days
        clock.increment_for_testing(2 * ONE_DAY_MS);

        // Should auto-unpause
        oracle_actions::check_and_unpause(&mut grant, &clock);

        ts::return_shared(grant);
    };

    test_utils::destroy(clock);
    ts::end(scenario);
}

// ====================================================================
// === EMERGENCY FREEZE/UNFREEZE TESTS ================================
// ====================================================================

#[test]
fun test_emergency_freeze() {
    let mut scenario = ts::begin(ADMIN);
    let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
    clock.set_for_testing(1000);

    ts::next_tx(&mut scenario, ADMIN);
    let grant_id = oracle_actions::create_employee_option<ASSET, STABLE>(
        RECIPIENT,
        100_000,
        1_000_000,
        0,
        1,
        3_000_000_000,
        10,
        object::id_from_address(@0xDA0),
        &clock,
        ts::ctx(&mut scenario),
    );

    ts::next_tx(&mut scenario, ADMIN);
    {
        let mut grant = ts::take_shared_by_id<PriceBasedMintGrant<ASSET, STABLE>>(
            &scenario,
            grant_id,
        );

        oracle_actions::emergency_freeze(&mut grant, &clock);

        // Frozen grant has 0 claimable
        let claimable = oracle_actions::claimable_now(&grant, &clock);
        assert!(claimable == 0, 0);

        ts::return_shared(grant);
    };

    test_utils::destroy(clock);
    ts::end(scenario);
}

#[test]
fun test_emergency_unfreeze_then_unpause() {
    let mut scenario = ts::begin(ADMIN);
    let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
    clock.set_for_testing(1000);

    ts::next_tx(&mut scenario, ADMIN);
    let grant_id = oracle_actions::create_employee_option<ASSET, STABLE>(
        RECIPIENT,
        100_000,
        1_000_000,
        0,
        1,
        3_000_000_000,
        10,
        object::id_from_address(@0xDA0),
        &clock,
        ts::ctx(&mut scenario),
    );

    ts::next_tx(&mut scenario, ADMIN);
    {
        let mut grant = ts::take_shared_by_id<PriceBasedMintGrant<ASSET, STABLE>>(
            &scenario,
            grant_id,
        );

        // Freeze
        oracle_actions::emergency_freeze(&mut grant, &clock);

        // Unfreeze (doesn't auto-unpause)
        oracle_actions::emergency_unfreeze(&mut grant, &clock);

        // Must explicitly unpause
        oracle_actions::unpause_grant(&mut grant, &clock);

        ts::return_shared(grant);
    };

    test_utils::destroy(clock);
    ts::end(scenario);
}

// ====================================================================
// === ERROR PATH TESTS ===============================================
// ====================================================================

#[test]
#[expected_failure(abort_code = oracle_actions::EGrantPaused)]
fun test_pause_already_paused_fails() {
    let mut scenario = ts::begin(ADMIN);
    let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));

    ts::next_tx(&mut scenario, ADMIN);
    let grant_id = oracle_actions::create_employee_option<ASSET, STABLE>(
        RECIPIENT,
        100_000,
        1_000_000,
        0,
        1,
        3_000_000_000,
        10,
        object::id_from_address(@0xDA0),
        &clock,
        ts::ctx(&mut scenario),
    );

    ts::next_tx(&mut scenario, ADMIN);
    {
        let mut grant = ts::take_shared_by_id<PriceBasedMintGrant<ASSET, STABLE>>(
            &scenario,
            grant_id,
        );
        oracle_actions::pause_grant(&mut grant, ONE_DAY_MS, &clock);
        oracle_actions::pause_grant(&mut grant, ONE_DAY_MS, &clock); // Fails
        ts::return_shared(grant);
    };

    test_utils::destroy(clock);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = oracle_actions::EGrantNotPaused)]
fun test_unpause_not_paused_fails() {
    let mut scenario = ts::begin(ADMIN);
    let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));

    ts::next_tx(&mut scenario, ADMIN);
    let grant_id = oracle_actions::create_employee_option<ASSET, STABLE>(
        RECIPIENT,
        100_000,
        1_000_000,
        0,
        1,
        3_000_000_000,
        10,
        object::id_from_address(@0xDA0),
        &clock,
        ts::ctx(&mut scenario),
    );

    ts::next_tx(&mut scenario, ADMIN);
    {
        let mut grant = ts::take_shared_by_id<PriceBasedMintGrant<ASSET, STABLE>>(
            &scenario,
            grant_id,
        );
        oracle_actions::unpause_grant(&mut grant, &clock); // Fails
        ts::return_shared(grant);
    };

    test_utils::destroy(clock);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = oracle_actions::EEmergencyFrozen)]
fun test_freeze_already_frozen_fails() {
    let mut scenario = ts::begin(ADMIN);
    let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));

    ts::next_tx(&mut scenario, ADMIN);
    let grant_id = oracle_actions::create_employee_option<ASSET, STABLE>(
        RECIPIENT,
        100_000,
        1_000_000,
        0,
        1,
        3_000_000_000,
        10,
        object::id_from_address(@0xDA0),
        &clock,
        ts::ctx(&mut scenario),
    );

    ts::next_tx(&mut scenario, ADMIN);
    {
        let mut grant = ts::take_shared_by_id<PriceBasedMintGrant<ASSET, STABLE>>(
            &scenario,
            grant_id,
        );
        oracle_actions::emergency_freeze(&mut grant, &clock);
        oracle_actions::emergency_freeze(&mut grant, &clock); // Fails
        ts::return_shared(grant);
    };

    test_utils::destroy(clock);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = oracle_actions::EEmergencyFrozen)]
fun test_unpause_while_frozen_fails() {
    let mut scenario = ts::begin(ADMIN);
    let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));

    ts::next_tx(&mut scenario, ADMIN);
    let grant_id = oracle_actions::create_employee_option<ASSET, STABLE>(
        RECIPIENT,
        100_000,
        1_000_000,
        0,
        1,
        3_000_000_000,
        10,
        object::id_from_address(@0xDA0),
        &clock,
        ts::ctx(&mut scenario),
    );

    ts::next_tx(&mut scenario, ADMIN);
    {
        let mut grant = ts::take_shared_by_id<PriceBasedMintGrant<ASSET, STABLE>>(
            &scenario,
            grant_id,
        );
        oracle_actions::emergency_freeze(&mut grant, &clock);
        oracle_actions::unpause_grant(&mut grant, &clock); // Fails
        ts::return_shared(grant);
    };

    test_utils::destroy(clock);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = oracle_actions::EInvalidAmount)]
fun test_create_employee_option_zero_amount_fails() {
    let mut scenario = ts::begin(ADMIN);
    let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));

    ts::next_tx(&mut scenario, ADMIN);
    {
        let _grant_id = oracle_actions::create_employee_option<ASSET, STABLE>(
            RECIPIENT,
            0, // Invalid: zero amount
            1_000_000,
            3,
            4,
            3_000_000_000,
            10,
            object::id_from_address(@0xDA0),
            &clock,
            ts::ctx(&mut scenario),
        );
    };

    test_utils::destroy(clock);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = oracle_actions::EInvalidDuration)]
fun test_create_employee_option_invalid_cliff_fails() {
    let mut scenario = ts::begin(ADMIN);
    let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));

    ts::next_tx(&mut scenario, ADMIN);
    {
        let _grant_id = oracle_actions::create_employee_option<ASSET, STABLE>(
            RECIPIENT,
            100_000,
            1_000_000,
            50, // Invalid: 50 months > 4 years
            4,
            3_000_000_000,
            10,
            object::id_from_address(@0xDA0),
            &clock,
            ts::ctx(&mut scenario),
        );
    };

    test_utils::destroy(clock);
    ts::end(scenario);
}
