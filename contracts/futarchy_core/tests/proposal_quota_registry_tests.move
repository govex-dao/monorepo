#[test_only]
module futarchy_core::proposal_quota_registry_tests;

use futarchy_core::proposal_quota_registry::{Self, ProposalQuotaRegistry};
use sui::clock::{Self, Clock};
use sui::test_scenario::{Self as ts, Scenario};
use sui::test_utils::destroy;

// === Imports ===

// === Constants ===

const OWNER: address = @0xCAFE;
const USER1: address = @0xBEEF;
const USER2: address = @0xDEAD;
const USER3: address = @0xFACE;

const ONE_DAY_MS: u64 = 86_400_000;
const THIRTY_DAYS_MS: u64 = 2_592_000_000;

// === Helpers ===

fun start(): (Scenario, ProposalQuotaRegistry, Clock, ID) {
    let mut scenario = ts::begin(OWNER);
    let dao_id = object::id_from_address(@0xDA0);
    let registry = proposal_quota_registry::new(dao_id, scenario.ctx());
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(1000);
    (scenario, registry, clock, dao_id)
}

fun end(scenario: Scenario, registry: ProposalQuotaRegistry, clock: Clock) {
    destroy(registry);
    destroy(clock);
    ts::end(scenario);
}

// === Tests ===

#[test]
fun test_new_registry() {
    let (scenario, registry, clock, dao_id) = start();

    // Verify initial state
    assert!(proposal_quota_registry::dao_id(&registry) == dao_id, 0);
    assert!(!proposal_quota_registry::has_quota(&registry, USER1), 1);

    end(scenario, registry, clock);
}

#[test]
fun test_set_quota_single_user() {
    let (scenario, mut registry, mut clock, dao_id) = start();

    // Set quota: 5 proposals per 30 days at 100 SUI reduced fee
    proposal_quota_registry::set_quotas(
        &mut registry,
        dao_id,
        vector[USER1],
        5,
        THIRTY_DAYS_MS,
        100,
        &clock,
    );

    // Verify quota was set
    assert!(proposal_quota_registry::has_quota(&registry, USER1), 0);

    let (has_quota, remaining, reduced_fee) = proposal_quota_registry::get_quota_status(
        &registry,
        USER1,
        &clock,
    );
    assert!(has_quota, 1);
    assert!(remaining == 5, 2);
    assert!(reduced_fee == 100, 3);

    end(scenario, registry, clock);
}

#[test]
fun test_set_quota_multiple_users() {
    let (scenario, mut registry, mut clock, dao_id) = start();

    // Set quota for 3 users
    proposal_quota_registry::set_quotas(
        &mut registry,
        dao_id,
        vector[USER1, USER2, USER3],
        10,
        THIRTY_DAYS_MS,
        50,
        &clock,
    );

    // Verify all have quotas
    assert!(proposal_quota_registry::has_quota(&registry, USER1), 0);
    assert!(proposal_quota_registry::has_quota(&registry, USER2), 1);
    assert!(proposal_quota_registry::has_quota(&registry, USER3), 2);

    end(scenario, registry, clock);
}

#[test]
fun test_update_existing_quota() {
    let (scenario, mut registry, mut clock, dao_id) = start();

    // Set initial quota
    proposal_quota_registry::set_quotas(
        &mut registry,
        dao_id,
        vector[USER1],
        5,
        THIRTY_DAYS_MS,
        100,
        &clock,
    );

    // Update quota
    proposal_quota_registry::set_quotas(
        &mut registry,
        dao_id,
        vector[USER1],
        10,
        THIRTY_DAYS_MS,
        50,
        &clock,
    );

    // Verify updated values
    let (has_quota, remaining, reduced_fee) = proposal_quota_registry::get_quota_status(
        &registry,
        USER1,
        &clock,
    );
    assert!(has_quota, 0);
    assert!(remaining == 10, 1); // New amount
    assert!(reduced_fee == 50, 2); // New fee

    end(scenario, registry, clock);
}

#[test]
fun test_remove_quota() {
    let (scenario, mut registry, mut clock, dao_id) = start();

    // Set quota
    proposal_quota_registry::set_quotas(
        &mut registry,
        dao_id,
        vector[USER1],
        5,
        THIRTY_DAYS_MS,
        100,
        &clock,
    );
    assert!(proposal_quota_registry::has_quota(&registry, USER1), 0);

    // Remove quota by setting amount to 0
    proposal_quota_registry::set_quotas(&mut registry, dao_id, vector[USER1], 0, 0, 0, &clock);

    // Verify quota removed
    assert!(!proposal_quota_registry::has_quota(&registry, USER1), 1);

    end(scenario, registry, clock);
}

#[test]
#[expected_failure(abort_code = proposal_quota_registry::EWrongDao)]
fun test_set_quota_wrong_dao_fails() {
    let (scenario, mut registry, mut clock, _dao_id) = start();

    let wrong_dao = object::id_from_address(@0xBAD);

    // Should abort - wrong DAO
    proposal_quota_registry::set_quotas(
        &mut registry,
        wrong_dao,
        vector[USER1],
        5,
        THIRTY_DAYS_MS,
        100,
        &clock,
    );

    end(scenario, registry, clock);
}

#[test]
#[expected_failure(abort_code = proposal_quota_registry::EInvalidQuotaParams)]
fun test_set_quota_zero_period_fails() {
    let (scenario, mut registry, mut clock, dao_id) = start();

    // Should abort - quota_period_ms is 0 but quota_amount > 0
    proposal_quota_registry::set_quotas(&mut registry, dao_id, vector[USER1], 5, 0, 100, &clock);

    end(scenario, registry, clock);
}

#[test]
fun test_check_quota_available() {
    let (scenario, mut registry, mut clock, dao_id) = start();

    // Set quota
    proposal_quota_registry::set_quotas(
        &mut registry,
        dao_id,
        vector[USER1],
        5,
        THIRTY_DAYS_MS,
        100,
        &clock,
    );

    // Check availability
    let (has_quota, reduced_fee) = proposal_quota_registry::check_quota_available(
        &registry,
        dao_id,
        USER1,
        &clock,
    );

    assert!(has_quota, 0);
    assert!(reduced_fee == 100, 1);

    end(scenario, registry, clock);
}

#[test]
fun test_check_quota_available_no_quota() {
    let (scenario, registry, mut clock, dao_id) = start();

    // Check availability for user without quota
    let (has_quota, reduced_fee) = proposal_quota_registry::check_quota_available(
        &registry,
        dao_id,
        USER1,
        &clock,
    );

    assert!(!has_quota, 0);
    assert!(reduced_fee == 0, 1);

    end(scenario, registry, clock);
}

#[test]
fun test_use_quota() {
    let (scenario, mut registry, mut clock, dao_id) = start();

    // Set quota of 3
    proposal_quota_registry::set_quotas(
        &mut registry,
        dao_id,
        vector[USER1],
        3,
        THIRTY_DAYS_MS,
        100,
        &clock,
    );

    // Use one quota
    proposal_quota_registry::use_quota(&mut registry, dao_id, USER1, &clock);

    // Verify remaining
    let (has_quota, remaining, _fee) = proposal_quota_registry::get_quota_status(
        &registry,
        USER1,
        &clock,
    );
    assert!(has_quota, 0);
    assert!(remaining == 2, 1);

    end(scenario, registry, clock);
}

#[test]
fun test_use_quota_multiple_times() {
    let (scenario, mut registry, mut clock, dao_id) = start();

    // Set quota of 3
    proposal_quota_registry::set_quotas(
        &mut registry,
        dao_id,
        vector[USER1],
        3,
        THIRTY_DAYS_MS,
        100,
        &clock,
    );

    // Use all 3 quotas
    proposal_quota_registry::use_quota(&mut registry, dao_id, USER1, &clock);
    proposal_quota_registry::use_quota(&mut registry, dao_id, USER1, &clock);
    proposal_quota_registry::use_quota(&mut registry, dao_id, USER1, &clock);

    // Verify all used
    let (has_quota, remaining, _fee) = proposal_quota_registry::get_quota_status(
        &registry,
        USER1,
        &clock,
    );
    assert!(!has_quota, 0); // No quota left
    assert!(remaining == 0, 1);

    end(scenario, registry, clock);
}

#[test]
fun test_use_quota_beyond_limit_safe() {
    let (scenario, mut registry, mut clock, dao_id) = start();

    // Set quota of 2
    proposal_quota_registry::set_quotas(
        &mut registry,
        dao_id,
        vector[USER1],
        2,
        THIRTY_DAYS_MS,
        100,
        &clock,
    );

    // Try to use 3 times (should safely handle)
    proposal_quota_registry::use_quota(&mut registry, dao_id, USER1, &clock);
    proposal_quota_registry::use_quota(&mut registry, dao_id, USER1, &clock);
    proposal_quota_registry::use_quota(&mut registry, dao_id, USER1, &clock); // Over limit, but safe

    // Should still be at limit, not overflow
    let (has_quota, remaining, _fee) = proposal_quota_registry::get_quota_status(
        &registry,
        USER1,
        &clock,
    );
    assert!(!has_quota, 0);
    assert!(remaining == 0, 1);

    end(scenario, registry, clock);
}

#[test]
fun test_quota_period_reset() {
    let (scenario, mut registry, mut clock, dao_id) = start();

    // Set quota of 3 with 1-day period
    clock.set_for_testing(1000);
    proposal_quota_registry::set_quotas(
        &mut registry,
        dao_id,
        vector[USER1],
        3,
        ONE_DAY_MS,
        100,
        &clock,
    );

    // Use all 3
    proposal_quota_registry::use_quota(&mut registry, dao_id, USER1, &clock);
    proposal_quota_registry::use_quota(&mut registry, dao_id, USER1, &clock);
    proposal_quota_registry::use_quota(&mut registry, dao_id, USER1, &clock);

    // Verify all used
    let (has_quota, remaining, _fee) = proposal_quota_registry::get_quota_status(
        &registry,
        USER1,
        &clock,
    );
    assert!(!has_quota, 0);
    assert!(remaining == 0, 1);

    // Advance time by 1 day + 1ms
    clock.set_for_testing(1000 + ONE_DAY_MS + 1);

    // Check quota - should be reset
    let (has_quota2, remaining2, _fee2) = proposal_quota_registry::get_quota_status(
        &registry,
        USER1,
        &clock,
    );
    assert!(has_quota2, 2);
    assert!(remaining2 == 3, 3); // Fully reset

    end(scenario, registry, clock);
}

#[test]
fun test_quota_period_reset_on_use() {
    let (scenario, mut registry, mut clock, dao_id) = start();

    // Set quota
    clock.set_for_testing(1000);
    proposal_quota_registry::set_quotas(
        &mut registry,
        dao_id,
        vector[USER1],
        3,
        ONE_DAY_MS,
        100,
        &clock,
    );

    // Use one
    proposal_quota_registry::use_quota(&mut registry, dao_id, USER1, &clock);

    // Advance time past period
    clock.set_for_testing(1000 + ONE_DAY_MS + 1);

    // Use quota - should reset period and count as 1 used in new period
    proposal_quota_registry::use_quota(&mut registry, dao_id, USER1, &clock);

    // Should have 2 remaining in new period
    let (_has_quota, remaining, _fee) = proposal_quota_registry::get_quota_status(
        &registry,
        USER1,
        &clock,
    );
    assert!(remaining == 2, 0);

    end(scenario, registry, clock);
}

#[test]
fun test_quota_period_alignment() {
    let (scenario, mut registry, mut clock, dao_id) = start();

    // Set quota starting at time 1000
    clock.set_for_testing(1000);
    proposal_quota_registry::set_quotas(
        &mut registry,
        dao_id,
        vector[USER1],
        5,
        ONE_DAY_MS,
        100,
        &clock,
    );

    // Advance time by 2.5 days (2 full periods + 0.5)
    clock.set_for_testing(1000 + (ONE_DAY_MS * 2) + (ONE_DAY_MS / 2));

    // Use quota - should align to period boundaries
    proposal_quota_registry::use_quota(&mut registry, dao_id, USER1, &clock);

    // Should have used 1 in the 3rd period
    let (_has_quota, remaining, _fee) = proposal_quota_registry::get_quota_status(
        &registry,
        USER1,
        &clock,
    );
    assert!(remaining == 4, 0);

    end(scenario, registry, clock);
}

#[test]
fun test_use_quota_no_quota_safe() {
    let (scenario, mut registry, mut clock, dao_id) = start();

    // Try to use quota for user without quota (should not crash)
    proposal_quota_registry::use_quota(&mut registry, dao_id, USER1, &clock);

    // User still has no quota
    assert!(!proposal_quota_registry::has_quota(&registry, USER1), 0);

    end(scenario, registry, clock);
}

#[test]
fun test_get_quota_status_multiple_periods_elapsed() {
    let (scenario, mut registry, mut clock, dao_id) = start();

    // Set quota
    clock.set_for_testing(1000);
    proposal_quota_registry::set_quotas(
        &mut registry,
        dao_id,
        vector[USER1],
        5,
        ONE_DAY_MS,
        100,
        &clock,
    );

    // Use 2 quotas
    proposal_quota_registry::use_quota(&mut registry, dao_id, USER1, &clock);
    proposal_quota_registry::use_quota(&mut registry, dao_id, USER1, &clock);

    // Verify 3 remaining
    let (_has, remaining1, _fee) = proposal_quota_registry::get_quota_status(
        &registry,
        USER1,
        &clock,
    );
    assert!(remaining1 == 3, 0);

    // Advance time by 10 days (multiple periods)
    clock.set_for_testing(1000 + (ONE_DAY_MS * 10));

    // Check status - should be fully reset regardless of multiple periods
    let (_has2, remaining2, _fee2) = proposal_quota_registry::get_quota_status(
        &registry,
        USER1,
        &clock,
    );
    assert!(remaining2 == 5, 1); // Fully reset

    end(scenario, registry, clock);
}

#[test]
fun test_free_quota() {
    let (scenario, mut registry, mut clock, dao_id) = start();

    // Set quota with 0 fee (free)
    proposal_quota_registry::set_quotas(
        &mut registry,
        dao_id,
        vector[USER1],
        10,
        THIRTY_DAYS_MS,
        0,
        &clock,
    );

    // Check fee is 0
    let (has_quota, reduced_fee) = proposal_quota_registry::check_quota_available(
        &registry,
        dao_id,
        USER1,
        &clock,
    );
    assert!(has_quota, 0);
    assert!(reduced_fee == 0, 1); // Free

    end(scenario, registry, clock);
}

#[test]
fun test_batch_quota_operations() {
    let (scenario, mut registry, mut clock, dao_id) = start();

    // Set quotas for 3 users with different params
    proposal_quota_registry::set_quotas(
        &mut registry,
        dao_id,
        vector[USER1, USER2, USER3],
        5,
        THIRTY_DAYS_MS,
        100,
        &clock,
    );

    // Use different amounts for each
    proposal_quota_registry::use_quota(&mut registry, dao_id, USER1, &clock); // 1 used
    proposal_quota_registry::use_quota(&mut registry, dao_id, USER2, &clock); // 1 used
    proposal_quota_registry::use_quota(&mut registry, dao_id, USER2, &clock); // 2 used

    // Verify individual status
    let (_h1, r1, _f1) = proposal_quota_registry::get_quota_status(&registry, USER1, &clock);
    let (_h2, r2, _f2) = proposal_quota_registry::get_quota_status(&registry, USER2, &clock);
    let (_h3, r3, _f3) = proposal_quota_registry::get_quota_status(&registry, USER3, &clock);

    assert!(r1 == 4, 0);
    assert!(r2 == 3, 1);
    assert!(r3 == 5, 2);

    end(scenario, registry, clock);
}
