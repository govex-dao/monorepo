#[test_only]
module futarchy_core::futarchy_config_tests;

use futarchy_core::dao_config;
use futarchy_core::futarchy_config;
use std::string;
use sui::test_scenario as ts;

const ADMIN: address = @0xAD;

// Phantom types for testing
public struct TestAsset has drop {}
public struct TestStable has drop {}

// === Slash Distribution Tests ===

#[test]
fun test_new_slash_distribution_valid() {
    let dist = futarchy_config::new_slash_distribution(
        2500, // 25% slasher reward
        2500, // 25% dao treasury
        2500, // 25% protocol
        2500, // 25% burn
    );

    assert!(futarchy_config::slasher_reward_bps(&dist) == 2500, 0);
    assert!(futarchy_config::dao_treasury_bps(&dist) == 2500, 1);
    assert!(futarchy_config::protocol_bps(&dist) == 2500, 2);
    assert!(futarchy_config::burn_bps(&dist) == 2500, 3);
}

#[test]
#[expected_failure(abort_code = futarchy_config::EInvalidSlashDistribution)]
fun test_new_slash_distribution_not_100_percent() {
    futarchy_config::new_slash_distribution(
        2500, // 25%
        2500, // 25%
        2500, // 25%
        2000, // 20% - Total is 95%, not 100%!
    );
}

#[test]
#[expected_failure(abort_code = futarchy_config::EInvalidSlashDistribution)]
fun test_new_slash_distribution_exceeds_100_percent() {
    futarchy_config::new_slash_distribution(
        3000, // 30%
        3000, // 30%
        3000, // 30%
        3000, // 30% - Total is 120%!
    );
}

#[test]
fun test_new_slash_distribution_all_to_one() {
    // Valid: all 100% to slasher
    let dist = futarchy_config::new_slash_distribution(
        10000, // 100% slasher
        0,
        0,
        0,
    );

    assert!(futarchy_config::slasher_reward_bps(&dist) == 10000, 0);
}

#[test]
fun test_new_slash_distribution_all_burned() {
    // Valid: all 100% burned
    let dist = futarchy_config::new_slash_distribution(
        0,
        0,
        0,
        10000, // 100% burn
    );

    assert!(futarchy_config::burn_bps(&dist) == 10000, 0);
}

// === FutarchyConfig Constructor Tests ===

#[test]
fun test_new_futarchy_config_basic() {
    let dao_config = dao_config::new_dao_config(
        dao_config::default_trading_params(),
        dao_config::default_twap_config(),
        dao_config::default_governance_config(),
        dao_config::new_metadata_config(
            std::ascii::string(b"TestDAO"),
            sui::url::new_unsafe_from_bytes(b"https://test.com/icon.png"),
            string::utf8(b"Test DAO"),
        ),
        dao_config::default_security_config(),
        dao_config::default_storage_config(),
        dao_config::default_conditional_coin_config(),
        dao_config::default_quota_config(),
        dao_config::default_multisig_config(),
        dao_config::default_subsidy_config(),
        1000000,
        259200000,
        500000,
    );

    let slash_dist = futarchy_config::new_slash_distribution(
        2500,
        2500,
        2500,
        2500,
    );

    let config = futarchy_config::new<TestAsset, TestStable>(
        dao_config,
        slash_dist,
    );

    // Check default values
    assert!(futarchy_config::proposal_pass_reward(&config) == 0, 0);
    assert!(futarchy_config::outcome_win_reward(&config) == 0, 1);
    assert!(futarchy_config::review_to_trading_fee(&config) == 1_000_000_000, 2);
    assert!(futarchy_config::finalization_fee(&config) == 1_000_000_000, 3);
    assert!(futarchy_config::verification_level(&config) == 0, 4);
    assert!(futarchy_config::dao_score(&config) == 0, 5);
}

#[test]
#[expected_failure(abort_code = futarchy_config::EInvalidSlashDistribution)]
fun test_new_futarchy_config_invalid_slash() {
    let dao_config = dao_config::new_dao_config(
        dao_config::default_trading_params(),
        dao_config::default_twap_config(),
        dao_config::default_governance_config(),
        dao_config::new_metadata_config(
            std::ascii::string(b"TestDAO"),
            sui::url::new_unsafe_from_bytes(b"https://test.com/icon.png"),
            string::utf8(b"Test DAO"),
        ),
        dao_config::default_security_config(),
        dao_config::default_storage_config(),
        dao_config::default_conditional_coin_config(),
        dao_config::default_quota_config(),
        dao_config::default_multisig_config(),
        dao_config::default_subsidy_config(),
        1000000,
        259200000,
        500000,
    );

    let invalid_slash = futarchy_config::new_slash_distribution(
        5000,
        5000,
        5000,
        5000, // 200%!
    );

    futarchy_config::new<TestAsset, TestStable>(
        dao_config,
        invalid_slash,
    );
}

// === Config Update Tests ===

#[test]
fun test_with_rewards() {
    let dao_config = dao_config::new_dao_config(
        dao_config::default_trading_params(),
        dao_config::default_twap_config(),
        dao_config::default_governance_config(),
        dao_config::new_metadata_config(
            std::ascii::string(b"TestDAO"),
            sui::url::new_unsafe_from_bytes(b"https://test.com/icon.png"),
            string::utf8(b"Test DAO"),
        ),
        dao_config::default_security_config(),
        dao_config::default_storage_config(),
        dao_config::default_conditional_coin_config(),
        dao_config::default_quota_config(),
        dao_config::default_multisig_config(),
        dao_config::default_subsidy_config(),
        1000000,
        259200000,
        500000,
    );

    let slash_dist = futarchy_config::new_slash_distribution(2500, 2500, 2500, 2500);
    let config = futarchy_config::new<TestAsset, TestStable>(dao_config, slash_dist);

    let updated = futarchy_config::with_rewards(
        config,
        5_000_000, // proposal_pass_reward
        3_000_000, // outcome_win_reward
        2_000_000_000, // review_to_trading_fee
        2_000_000_000, // finalization_fee
    );

    assert!(futarchy_config::proposal_pass_reward(&updated) == 5_000_000, 0);
    assert!(futarchy_config::outcome_win_reward(&updated) == 3_000_000, 1);
    assert!(futarchy_config::review_to_trading_fee(&updated) == 2_000_000_000, 2);
    assert!(futarchy_config::finalization_fee(&updated) == 2_000_000_000, 3);
}

#[test]
fun test_with_verification_level() {
    let dao_config = dao_config::new_dao_config(
        dao_config::default_trading_params(),
        dao_config::default_twap_config(),
        dao_config::default_governance_config(),
        dao_config::new_metadata_config(
            std::ascii::string(b"TestDAO"),
            sui::url::new_unsafe_from_bytes(b"https://test.com/icon.png"),
            string::utf8(b"Test DAO"),
        ),
        dao_config::default_security_config(),
        dao_config::default_storage_config(),
        dao_config::default_conditional_coin_config(),
        dao_config::default_quota_config(),
        dao_config::default_multisig_config(),
        dao_config::default_subsidy_config(),
        1000000,
        259200000,
        500000,
    );

    let slash_dist = futarchy_config::new_slash_distribution(2500, 2500, 2500, 2500);
    let config = futarchy_config::new<TestAsset, TestStable>(dao_config, slash_dist);

    let updated = futarchy_config::with_verification_level(config, 3); // Premium

    assert!(futarchy_config::verification_level(&updated) == 3, 0);
}

#[test]
fun test_with_dao_score() {
    let dao_config = dao_config::new_dao_config(
        dao_config::default_trading_params(),
        dao_config::default_twap_config(),
        dao_config::default_governance_config(),
        dao_config::new_metadata_config(
            std::ascii::string(b"TestDAO"),
            sui::url::new_unsafe_from_bytes(b"https://test.com/icon.png"),
            string::utf8(b"Test DAO"),
        ),
        dao_config::default_security_config(),
        dao_config::default_storage_config(),
        dao_config::default_conditional_coin_config(),
        dao_config::default_quota_config(),
        dao_config::default_multisig_config(),
        dao_config::default_subsidy_config(),
        1000000,
        259200000,
        500000,
    );

    let slash_dist = futarchy_config::new_slash_distribution(2500, 2500, 2500, 2500);
    let config = futarchy_config::new<TestAsset, TestStable>(dao_config, slash_dist);

    let updated = futarchy_config::with_dao_score(config, 9500);

    assert!(futarchy_config::dao_score(&updated) == 9500, 0);
}

#[test]
fun test_with_slash_distribution() {
    let dao_config = dao_config::new_dao_config(
        dao_config::default_trading_params(),
        dao_config::default_twap_config(),
        dao_config::default_governance_config(),
        dao_config::new_metadata_config(
            std::ascii::string(b"TestDAO"),
            sui::url::new_unsafe_from_bytes(b"https://test.com/icon.png"),
            string::utf8(b"Test DAO"),
        ),
        dao_config::default_security_config(),
        dao_config::default_storage_config(),
        dao_config::default_conditional_coin_config(),
        dao_config::default_quota_config(),
        dao_config::default_multisig_config(),
        dao_config::default_subsidy_config(),
        1000000,
        259200000,
        500000,
    );

    let old_slash = futarchy_config::new_slash_distribution(2500, 2500, 2500, 2500);
    let config = futarchy_config::new<TestAsset, TestStable>(dao_config, old_slash);

    let new_slash = futarchy_config::new_slash_distribution(
        5000, // 50% slasher
        2000, // 20% dao
        2000, // 20% protocol
        1000, // 10% burn
    );

    let updated = futarchy_config::with_slash_distribution(config, new_slash);
    let dist = futarchy_config::slash_distribution(&updated);

    assert!(futarchy_config::slasher_reward_bps(dist) == 5000, 0);
    assert!(futarchy_config::dao_treasury_bps(dist) == 2000, 1);
    assert!(futarchy_config::protocol_bps(dist) == 2000, 2);
    assert!(futarchy_config::burn_bps(dist) == 1000, 3);
}

// === DaoState Tests ===

#[test]
fun test_new_dao_state() {
    let state = futarchy_config::new_dao_state();

    assert!(futarchy_config::operational_state(&state) == futarchy_config::state_active(), 0);
    assert!(futarchy_config::active_proposals(&state) == 0, 1);
    assert!(futarchy_config::total_proposals(&state) == 0, 2);
    assert!(!futarchy_config::verification_pending(&state), 3);

    futarchy_config::destroy_dao_state_for_testing(state);
}

#[test]
fun test_dao_state_proposal_counters() {
    let mut state = futarchy_config::new_dao_state();

    futarchy_config::increment_active_proposals(&mut state);
    futarchy_config::increment_total_proposals(&mut state);

    assert!(futarchy_config::active_proposals(&state) == 1, 0);
    assert!(futarchy_config::total_proposals(&state) == 1, 1);

    futarchy_config::increment_active_proposals(&mut state);
    futarchy_config::increment_total_proposals(&mut state);

    assert!(futarchy_config::active_proposals(&state) == 2, 2);
    assert!(futarchy_config::total_proposals(&state) == 2, 3);

    futarchy_config::decrement_active_proposals(&mut state);

    assert!(futarchy_config::active_proposals(&state) == 1, 4);
    assert!(futarchy_config::total_proposals(&state) == 2, 5); // Total never decrements

    futarchy_config::destroy_dao_state_for_testing(state);
}

#[test]
#[expected_failure]
fun test_dao_state_decrement_active_when_zero() {
    let mut state = futarchy_config::new_dao_state();

    // Should abort - can't decrement when already 0
    futarchy_config::decrement_active_proposals(&mut state);

    // Will never reach here due to expected failure, but needed for compile
    futarchy_config::destroy_dao_state_for_testing(state);
}

#[test]
fun test_dao_state_operational_state_changes() {
    let mut state = futarchy_config::new_dao_state();

    assert!(futarchy_config::operational_state(&state) == futarchy_config::state_active(), 0);

    futarchy_config::set_operational_state(&mut state, futarchy_config::state_paused());
    assert!(futarchy_config::operational_state(&state) == futarchy_config::state_paused(), 1);

    futarchy_config::destroy_dao_state_for_testing(state);
}

#[test]
fun test_dao_state_attestation_url() {
    let mut state = futarchy_config::new_dao_state();

    assert!(futarchy_config::attestation_url(&state) == &string::utf8(b""), 0);

    futarchy_config::set_attestation_url(&mut state, string::utf8(b"https://verify.dao.com"));
    assert!(
        futarchy_config::attestation_url(&state) == &string::utf8(b"https://verify.dao.com"),
        1,
    );

    futarchy_config::destroy_dao_state_for_testing(state);
}

#[test]
fun test_dao_state_verification_pending() {
    let mut state = futarchy_config::new_dao_state();

    assert!(!futarchy_config::verification_pending(&state), 0);

    futarchy_config::set_verification_pending(&mut state, true);
    assert!(futarchy_config::verification_pending(&state), 1);

    futarchy_config::set_verification_pending(&mut state, false);
    assert!(!futarchy_config::verification_pending(&state), 2);

    futarchy_config::destroy_dao_state_for_testing(state);
}

#[test]
fun test_set_proposals_enabled_pauses_dao() {
    let mut state = futarchy_config::new_dao_state();

    assert!(futarchy_config::operational_state(&state) == futarchy_config::state_active(), 0);

    futarchy_config::set_proposals_enabled(&mut state, false);
    assert!(futarchy_config::operational_state(&state) == futarchy_config::state_paused(), 1);

    futarchy_config::set_proposals_enabled(&mut state, true);
    assert!(futarchy_config::operational_state(&state) == futarchy_config::state_active(), 2);

    futarchy_config::destroy_dao_state_for_testing(state);
}

// === FutarchyOutcome Tests ===

#[test]
fun test_new_futarchy_outcome() {
    use std::option;

    let outcome = futarchy_config::new_futarchy_outcome(
        string::utf8(b"test_intent"),
        1000000, // min_execution_time
    );

    assert!(futarchy_config::outcome_min_execution_time(&outcome) == 1000000, 0);
}

#[test]
fun test_new_futarchy_outcome_full() {
    use std::option;
    use sui::object;

    let proposal_id = object::id_from_address(@0xCAFE);
    let market_id = object::id_from_address(@0xBEEF);

    let outcome = futarchy_config::new_futarchy_outcome_full(
        string::utf8(b"test_intent"),
        option::some(proposal_id),
        option::some(market_id),
        true, // approved
        1000000,
    );

    assert!(futarchy_config::outcome_min_execution_time(&outcome) == 1000000, 0);
}

#[test]
fun test_set_outcome_proposal_and_market() {
    use std::option;
    use sui::object;

    let mut outcome = futarchy_config::new_futarchy_outcome(
        string::utf8(b"test_intent"),
        1000000,
    );

    let proposal_id = object::id_from_address(@0xCAFE);
    let market_id = object::id_from_address(@0xBEEF);

    futarchy_config::set_outcome_proposal_and_market(&mut outcome, proposal_id, market_id);

    // Can't directly test IDs since no getters, but function doesn't abort
}

#[test]
fun test_set_outcome_approved() {
    use std::option;

    let mut outcome = futarchy_config::new_futarchy_outcome(
        string::utf8(b"test_intent"),
        1000000,
    );

    futarchy_config::set_outcome_approved(&mut outcome, true);
    futarchy_config::set_outcome_approved(&mut outcome, false);
}

#[test]
fun test_set_outcome_intent_key() {
    use std::option;

    let mut outcome = futarchy_config::new_futarchy_outcome(
        string::utf8(b"old_key"),
        1000000,
    );

    futarchy_config::set_outcome_intent_key(&mut outcome, string::utf8(b"new_key"));
}

// === Launchpad Initial Price Tests ===

#[test]
fun test_launchpad_initial_price_not_set() {
    use std::option;

    let dao_config = dao_config::new_dao_config(
        dao_config::default_trading_params(),
        dao_config::default_twap_config(),
        dao_config::default_governance_config(),
        dao_config::new_metadata_config(
            std::ascii::string(b"TestDAO"),
            sui::url::new_unsafe_from_bytes(b"https://test.com/icon.png"),
            string::utf8(b"Test DAO"),
        ),
        dao_config::default_security_config(),
        dao_config::default_storage_config(),
        dao_config::default_conditional_coin_config(),
        dao_config::default_quota_config(),
        dao_config::default_multisig_config(),
        dao_config::default_subsidy_config(),
        1000000,
        259200000,
        500000,
    );

    let slash_dist = futarchy_config::new_slash_distribution(2500, 2500, 2500, 2500);
    let config = futarchy_config::new<TestAsset, TestStable>(dao_config, slash_dist);

    assert!(futarchy_config::get_launchpad_initial_price(&config).is_none(), 0);
}

#[test]
fun test_set_launchpad_initial_price() {
    use std::option;

    let dao_config = dao_config::new_dao_config(
        dao_config::default_trading_params(),
        dao_config::default_twap_config(),
        dao_config::default_governance_config(),
        dao_config::new_metadata_config(
            std::ascii::string(b"TestDAO"),
            sui::url::new_unsafe_from_bytes(b"https://test.com/icon.png"),
            string::utf8(b"Test DAO"),
        ),
        dao_config::default_security_config(),
        dao_config::default_storage_config(),
        dao_config::default_conditional_coin_config(),
        dao_config::default_quota_config(),
        dao_config::default_multisig_config(),
        dao_config::default_subsidy_config(),
        1000000,
        259200000,
        500000,
    );

    let slash_dist = futarchy_config::new_slash_distribution(2500, 2500, 2500, 2500);
    let mut config = futarchy_config::new<TestAsset, TestStable>(dao_config, slash_dist);

    futarchy_config::set_launchpad_initial_price(&mut config, 5_000_000_000_000);

    let price = futarchy_config::get_launchpad_initial_price(&config);
    assert!(price.is_some(), 0);
    assert!(price.destroy_some() == 5_000_000_000_000, 1);
}

#[test]
#[expected_failure(abort_code = futarchy_config::ELaunchpadPriceAlreadySet)]
fun test_set_launchpad_initial_price_twice() {
    use std::option;

    let dao_config = dao_config::new_dao_config(
        dao_config::default_trading_params(),
        dao_config::default_twap_config(),
        dao_config::default_governance_config(),
        dao_config::new_metadata_config(
            std::ascii::string(b"TestDAO"),
            sui::url::new_unsafe_from_bytes(b"https://test.com/icon.png"),
            string::utf8(b"Test DAO"),
        ),
        dao_config::default_security_config(),
        dao_config::default_storage_config(),
        dao_config::default_conditional_coin_config(),
        dao_config::default_quota_config(),
        dao_config::default_multisig_config(),
        dao_config::default_subsidy_config(),
        1000000,
        259200000,
        500000,
    );

    let slash_dist = futarchy_config::new_slash_distribution(2500, 2500, 2500, 2500);
    let mut config = futarchy_config::new<TestAsset, TestStable>(dao_config, slash_dist);

    futarchy_config::set_launchpad_initial_price(&mut config, 5_000_000_000_000);

    // Should abort - can only set once!
    futarchy_config::set_launchpad_initial_price(&mut config, 6_000_000_000_000);
}
