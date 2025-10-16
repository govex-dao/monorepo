#[test_only]
module futarchy_core::dao_config_tests;

use futarchy_core::dao_config::{Self, DaoConfig, TradingParams, TwapConfig, GovernanceConfig};
use futarchy_one_shot_utils::constants;
use std::ascii;
use std::string;
use sui::test_scenario;
use sui::url;

const ADMIN: address = @0xA;

// === Constructor Tests ===

#[test]
fun test_new_trading_params_basic() {
    let params = dao_config::new_trading_params(
        1000000, // min_asset
        1000000, // min_stable
        86400000, // review_period (24h)
        604800000, // trading_period (7 days)
        30, // conditional_fee_bps
        30, // spot_fee_bps
        0, // market_op_review (instant)
        1000, // max_amm_swap_percent_bps (10%)
        80, // conditional_liquidity_ratio_percent (80%, base 100)
    );

    assert!(dao_config::min_asset_amount(&params) == 1000000, 0);
    assert!(dao_config::min_stable_amount(&params) == 1000000, 1);
    assert!(dao_config::review_period_ms(&params) == 86400000, 2);
    assert!(dao_config::trading_period_ms(&params) == 604800000, 3);
}

#[test]
#[expected_failure(abort_code = dao_config::EInvalidMinAmount)]
fun test_new_trading_params_zero_asset_amount() {
    dao_config::new_trading_params(
        0, // Invalid!
        1000000,
        86400000,
        604800000,
        30,
        30,
        0,
        1000,
        80,
    );
}

#[test]
#[expected_failure(abort_code = dao_config::EInvalidMinAmount)]
fun test_new_trading_params_zero_stable_amount() {
    dao_config::new_trading_params(
        1000000,
        0, // Invalid!
        86400000,
        604800000,
        30,
        30,
        0,
        1000,
        80,
    );
}

#[test]
#[expected_failure(abort_code = dao_config::EInvalidPeriod)]
fun test_new_trading_params_review_period_too_short() {
    dao_config::new_trading_params(
        1000000,
        1000000,
        999, // Too short! Must be >= min_review_period_ms (1000)
        604800000,
        30,
        30,
        0,
        1000,
        80,
    );
}

#[test]
#[expected_failure(abort_code = dao_config::EInvalidPeriod)]
fun test_new_trading_params_trading_period_too_short() {
    dao_config::new_trading_params(
        1000000,
        1000000,
        86400000,
        999, // Too short! Must be >= min_trading_period_ms (1000)
        30,
        30,
        0,
        1000,
        80,
    );
}

#[test]
#[expected_failure(abort_code = dao_config::EInvalidFee)]
fun test_new_trading_params_conditional_fee_too_high() {
    dao_config::new_trading_params(
        1000000,
        1000000,
        86400000,
        604800000,
        20000, // > max_amm_fee_bps (10000)
        30,
        0,
        1000,
        80,
    );
}

#[test]
#[expected_failure(abort_code = dao_config::EInvalidFee)]
fun test_new_trading_params_spot_fee_too_high() {
    dao_config::new_trading_params(
        1000000,
        1000000,
        86400000,
        604800000,
        30,
        20000, // > max_amm_fee_bps (10000)
        0,
        1000,
        80,
    );
}

#[test]
#[expected_failure(abort_code = dao_config::EInvalidPeriod)]
fun test_new_trading_params_market_op_review_exceeds_regular() {
    dao_config::new_trading_params(
        1000000,
        1000000,
        86400000, // review_period
        604800000,
        30,
        30,
        86400001, // market_op_review > review_period
        1000,
        80,
    );
}

#[test]
#[expected_failure(abort_code = dao_config::EInvalidFee)]
fun test_new_trading_params_max_swap_percent_exceeds_100() {
    dao_config::new_trading_params(
        1000000,
        1000000,
        86400000,
        604800000,
        30,
        30,
        0,
        20000, // > 10000 (100%)
        80,
    );
}

#[test]
fun test_new_trading_params_market_op_review_zero_allowed() {
    let params = dao_config::new_trading_params(
        1000000,
        1000000,
        86400000,
        604800000,
        30,
        30,
        0, // Zero is valid (immediate trading)
        1000,
        80,
    );

    assert!(dao_config::market_op_review_period_ms(&params) == 0, 0);
}

// === TWAP Config Tests ===

#[test]
fun test_new_twap_config_basic() {
    let twap = dao_config::new_twap_config(
        300000, // start_delay (5 min)
        300000, // step_max (5 min)
        1000000000000, // initial_observation
        10, // threshold (10%)
    );

    assert!(dao_config::start_delay(&twap) == 300000, 0);
    assert!(dao_config::step_max(&twap) == 300000, 1);
    assert!(dao_config::initial_observation(&twap) == 1000000000000, 2);
    assert!(dao_config::threshold(&twap) == 10, 3);
}

#[test]
fun test_new_twap_config_zero_start_delay_allowed() {
    let twap = dao_config::new_twap_config(
        0, // Zero is valid for immediate TWAP
        300000,
        1000000000000,
        10,
    );

    assert!(dao_config::start_delay(&twap) == 0, 0);
}

#[test]
#[expected_failure(abort_code = dao_config::EInvalidTwapParams)]
fun test_new_twap_config_zero_step_max() {
    dao_config::new_twap_config(
        300000,
        0, // Invalid!
        1000000000000,
        10,
    );
}

#[test]
#[expected_failure(abort_code = dao_config::EInvalidTwapParams)]
fun test_new_twap_config_zero_initial_observation() {
    dao_config::new_twap_config(
        300000,
        300000,
        0, // Invalid!
        10,
    );
}

#[test]
#[expected_failure(abort_code = dao_config::EInvalidTwapThreshold)]
fun test_new_twap_config_zero_threshold() {
    dao_config::new_twap_config(
        300000,
        300000,
        1000000000000,
        0, // Invalid!
    );
}

// === Governance Config Tests ===

#[test]
fun test_new_governance_config_basic() {
    let gov = dao_config::new_governance_config(
        3, // max_outcomes
        5, // max_actions_per_outcome
        1000000, // proposal_fee_per_outcome
        10000000, // required_bond
        5, // max_concurrent_proposals
        86400000, // recreation_window
        3, // max_proposal_chain_depth
        500, // fee_escalation_bps
        true, // proposal_creation_enabled
        true, // accept_new_proposals
        10, // max_intents_per_outcome
        3600000, // eviction_grace_period (1 hour)
        86400000, // proposal_intent_expiry (24h)
        true, // enable_premarket_reservation_lock
    );

    assert!(dao_config::max_outcomes(&gov) == 3, 0);
    assert!(dao_config::max_actions_per_outcome(&gov) == 5, 1);
    assert!(dao_config::proposal_fee_per_outcome(&gov) == 1000000, 2);
}

#[test]
#[expected_failure(abort_code = dao_config::EInvalidMaxOutcomes)]
fun test_new_governance_config_max_outcomes_too_low() {
    dao_config::new_governance_config(
        1, // < min_outcomes (2)
        5,
        1000000,
        10000000,
        5,
        86400000,
        3,
        500,
        true,
        true,
        10,
        3600000,
        86400000,
        true,
    );
}

#[test]
#[expected_failure(abort_code = dao_config::EMaxOutcomesExceedsProtocol)]
fun test_new_governance_config_max_outcomes_exceeds_protocol() {
    dao_config::new_governance_config(
        1000, // > protocol_max_outcomes
        5,
        1000000,
        10000000,
        5,
        86400000,
        3,
        500,
        true,
        true,
        10,
        3600000,
        86400000,
        true,
    );
}

#[test]
#[expected_failure(abort_code = dao_config::EMaxActionsExceedsProtocol)]
fun test_new_governance_config_max_actions_zero() {
    dao_config::new_governance_config(
        3,
        0, // Invalid!
        1000000,
        10000000,
        5,
        86400000,
        3,
        500,
        true,
        true,
        10,
        3600000,
        86400000,
        true,
    );
}

#[test]
#[expected_failure(abort_code = dao_config::EInvalidProposalFee)]
fun test_new_governance_config_zero_proposal_fee() {
    dao_config::new_governance_config(
        3,
        5,
        0, // Invalid!
        10000000,
        5,
        86400000,
        3,
        500,
        true,
        true,
        10,
        3600000,
        86400000,
        true,
    );
}

#[test]
#[expected_failure(abort_code = dao_config::EInvalidBondAmount)]
fun test_new_governance_config_zero_bond() {
    dao_config::new_governance_config(
        3,
        5,
        1000000,
        0, // Invalid!
        5,
        86400000,
        3,
        500,
        true,
        true,
        10,
        3600000,
        86400000,
        true,
    );
}

#[test]
#[expected_failure(abort_code = dao_config::EInvalidMaxConcurrentProposals)]
fun test_new_governance_config_zero_concurrent_proposals() {
    dao_config::new_governance_config(
        3,
        5,
        1000000,
        10000000,
        0, // Invalid!
        86400000,
        3,
        500,
        true,
        true,
        10,
        3600000,
        86400000,
        true,
    );
}

#[test]
#[expected_failure(abort_code = dao_config::EInvalidFee)]
fun test_new_governance_config_fee_escalation_exceeds_max() {
    dao_config::new_governance_config(
        3,
        5,
        1000000,
        10000000,
        5,
        86400000,
        3,
        20000, // > max_fee_bps (10000)
        true,
        true,
        10,
        3600000,
        86400000,
        true,
    );
}

#[test]
#[expected_failure(abort_code = dao_config::EInvalidMaxOutcomes)]
fun test_new_governance_config_zero_intents_per_outcome() {
    dao_config::new_governance_config(
        3,
        5,
        1000000,
        10000000,
        5,
        86400000,
        3,
        500,
        true,
        true,
        0, // Invalid!
        3600000,
        86400000,
        true,
    );
}

#[test]
#[expected_failure(abort_code = dao_config::EInvalidGracePeriod)]
fun test_new_governance_config_grace_period_too_short() {
    dao_config::new_governance_config(
        3,
        5,
        1000000,
        10000000,
        5,
        86400000,
        3,
        500,
        true,
        true,
        10,
        1000, // < min_eviction_grace_period_ms
        86400000,
        true,
    );
}

// === Metadata Config Tests ===

#[test]
fun test_new_metadata_config_basic() {
    let meta = dao_config::new_metadata_config(
        ascii::string(b"MyDAO"),
        url::new_unsafe_from_bytes(b"https://example.com/icon.png"),
        string::utf8(b"A futarchy DAO"),
    );

    assert!(dao_config::dao_name(&meta) == &ascii::string(b"MyDAO"), 0);
    assert!(dao_config::description(&meta) == &string::utf8(b"A futarchy DAO"), 1);
}

// === Security Config Tests ===

#[test]
fun test_new_security_config_basic() {
    let sec = dao_config::new_security_config(
        true, // deadman_enabled
        2592000000, // recovery_liveness (30 days)
        false, // require_deadman_council
    );

    assert!(dao_config::deadman_enabled(&sec), 0);
    assert!(dao_config::recovery_liveness_ms(&sec) == 2592000000, 1);
    assert!(!dao_config::require_deadman_council(&sec), 2);
}

#[test]
fun test_new_security_config_deadman_disabled() {
    let sec = dao_config::new_security_config(
        false, // deadman_enabled
        0, // Can be 0 if disabled
        false,
    );

    assert!(!dao_config::deadman_enabled(&sec), 0);
}

// === Conditional Coin Config Tests ===

#[test]
fun test_new_conditional_coin_config_dynamic_mode() {
    use std::option;

    let coin_config = dao_config::new_conditional_coin_config(
        true, // use_outcome_index
        option::none(), // Derive from base token
    );

    assert!(dao_config::use_outcome_index(&coin_config), 0);
    assert!(dao_config::conditional_metadata(&coin_config).is_none(), 1);
}

#[test]
fun test_new_conditional_coin_config_with_metadata() {
    use std::option;

    let meta = dao_config::new_conditional_metadata(
        6, // decimals
        ascii::string(b"cDAO_"),
        url::new_unsafe_from_bytes(b"https://example.com/icon.png"),
    );

    let coin_config = dao_config::new_conditional_coin_config(
        false, // don't use outcome index
        option::some(meta),
    );

    assert!(!dao_config::use_outcome_index(&coin_config), 0);
    assert!(dao_config::conditional_metadata(&coin_config).is_some(), 1);
}

// === Quota Config Tests ===

#[test]
fun test_new_quota_config_disabled() {
    let quota = dao_config::new_quota_config(
        false, // disabled
        0, // Can be 0 if disabled
        0,
        0,
    );

    assert!(!dao_config::quota_enabled(&quota), 0);
}

#[test]
fun test_new_quota_config_enabled() {
    let quota = dao_config::new_quota_config(
        true, // enabled
        1, // default_quota_amount
        2592000000, // 30 days
        0, // free
    );

    assert!(dao_config::quota_enabled(&quota), 0);
    assert!(dao_config::default_quota_amount(&quota) == 1, 1);
    assert!(dao_config::default_quota_period_ms(&quota) == 2592000000, 2);
    assert!(dao_config::default_reduced_fee(&quota) == 0, 3);
}

#[test]
#[expected_failure(abort_code = dao_config::EInvalidQuotaParams)]
fun test_new_quota_config_enabled_zero_amount() {
    dao_config::new_quota_config(
        true, // enabled
        0, // Invalid when enabled!
        2592000000,
        0,
    );
}

#[test]
#[expected_failure(abort_code = dao_config::EInvalidPeriod)]
fun test_new_quota_config_enabled_zero_period() {
    dao_config::new_quota_config(
        true, // enabled
        1,
        0, // Invalid when enabled!
        0,
    );
}

// === Complete DAO Config Tests ===

#[test]
fun test_new_dao_config_basic() {
    let trading = dao_config::default_trading_params();
    let twap = dao_config::default_twap_config();
    let gov = dao_config::default_governance_config();
    let meta = dao_config::new_metadata_config(
        ascii::string(b"TestDAO"),
        url::new_unsafe_from_bytes(b"https://test.com/icon.png"),
        string::utf8(b"Test DAO"),
    );
    let sec = dao_config::default_security_config();
    let storage = dao_config::default_storage_config();
    let coin_config = dao_config::default_conditional_coin_config();
    let quota = dao_config::default_quota_config();
    let multisig = dao_config::default_multisig_config();
    let subsidy = dao_config::default_subsidy_config();

    let config = dao_config::new_dao_config(
        trading,
        twap,
        gov,
        meta,
        sec,
        storage,
        coin_config,
        quota,
        multisig,
        subsidy,
        1000000, // optimistic_challenge_fee
        259200000, // 3 days challenge period
        500000, // challenge_bounty
    );

    assert!(dao_config::optimistic_challenge_fee(&config) == 1000000, 0);
    assert!(dao_config::optimistic_challenge_period_ms(&config) == 259200000, 1);
    assert!(dao_config::challenge_bounty(&config) == 500000, 2);
}

#[test]
#[expected_failure(abort_code = dao_config::EInvalidProposalFee)]
fun test_new_dao_config_zero_challenge_fee() {
    let trading = dao_config::default_trading_params();
    let twap = dao_config::default_twap_config();
    let gov = dao_config::default_governance_config();
    let meta = dao_config::new_metadata_config(
        ascii::string(b"TestDAO"),
        url::new_unsafe_from_bytes(b"https://test.com/icon.png"),
        string::utf8(b"Test DAO"),
    );
    let sec = dao_config::default_security_config();
    let storage = dao_config::default_storage_config();
    let coin_config = dao_config::default_conditional_coin_config();
    let quota = dao_config::default_quota_config();
    let multisig = dao_config::default_multisig_config();
    let subsidy = dao_config::default_subsidy_config();

    dao_config::new_dao_config(
        trading,
        twap,
        gov,
        meta,
        sec,
        storage,
        coin_config,
        quota,
        multisig,
        subsidy,
        0, // Invalid!
        259200000,
        500000,
    );
}

#[test]
#[expected_failure(abort_code = dao_config::EInvalidPeriod)]
fun test_new_dao_config_zero_challenge_period() {
    let trading = dao_config::default_trading_params();
    let twap = dao_config::default_twap_config();
    let gov = dao_config::default_governance_config();
    let meta = dao_config::new_metadata_config(
        ascii::string(b"TestDAO"),
        url::new_unsafe_from_bytes(b"https://test.com/icon.png"),
        string::utf8(b"Test DAO"),
    );
    let sec = dao_config::default_security_config();
    let storage = dao_config::default_storage_config();
    let coin_config = dao_config::default_conditional_coin_config();
    let quota = dao_config::default_quota_config();
    let multisig = dao_config::default_multisig_config();
    let subsidy = dao_config::default_subsidy_config();

    dao_config::new_dao_config(
        trading,
        twap,
        gov,
        meta,
        sec,
        storage,
        coin_config,
        quota,
        multisig,
        subsidy,
        1000000,
        0, // Invalid!
        500000,
    );
}

#[test]
#[expected_failure(abort_code = dao_config::EInvalidChallengeBounty)]
fun test_new_dao_config_zero_challenge_bounty() {
    let trading = dao_config::default_trading_params();
    let twap = dao_config::default_twap_config();
    let gov = dao_config::default_governance_config();
    let meta = dao_config::new_metadata_config(
        ascii::string(b"TestDAO"),
        url::new_unsafe_from_bytes(b"https://test.com/icon.png"),
        string::utf8(b"Test DAO"),
    );
    let sec = dao_config::default_security_config();
    let storage = dao_config::default_storage_config();
    let coin_config = dao_config::default_conditional_coin_config();
    let quota = dao_config::default_quota_config();
    let multisig = dao_config::default_multisig_config();
    let subsidy = dao_config::default_subsidy_config();

    dao_config::new_dao_config(
        trading,
        twap,
        gov,
        meta,
        sec,
        storage,
        coin_config,
        quota,
        multisig,
        subsidy,
        1000000,
        259200000,
        0, // Invalid!
    );
}

// === State Validation Tests ===

#[test]
fun test_validate_config_update_safe_changes() {
    let trading = dao_config::default_trading_params();
    let twap = dao_config::default_twap_config();
    let gov = dao_config::default_governance_config();
    let meta = dao_config::new_metadata_config(
        ascii::string(b"TestDAO"),
        url::new_unsafe_from_bytes(b"https://test.com/icon.png"),
        string::utf8(b"Test DAO"),
    );
    let sec = dao_config::default_security_config();
    let storage = dao_config::default_storage_config();
    let coin_config = dao_config::default_conditional_coin_config();
    let quota = dao_config::default_quota_config();
    let multisig = dao_config::default_multisig_config();
    let subsidy = dao_config::default_subsidy_config();

    let current_config = dao_config::new_dao_config(
        trading,
        twap,
        gov,
        meta,
        sec,
        storage,
        coin_config,
        quota,
        multisig,
        subsidy,
        1000000,
        259200000,
        500000,
    );

    // Same config is always safe
    assert!(dao_config::validate_config_update(&current_config, &current_config, 0), 0);

    // Increasing limits is always safe
    let mut new_gov = gov;
    dao_config::set_max_concurrent_proposals(&mut new_gov, 10);
    let new_config = dao_config::update_governance_config(&current_config, new_gov);
    assert!(dao_config::validate_config_update(&current_config, &new_config, 3), 1);
}

#[test]
fun test_validate_config_update_unsafe_max_concurrent_below_active() {
    let trading = dao_config::default_trading_params();
    let twap = dao_config::default_twap_config();
    let mut gov = dao_config::default_governance_config();
    dao_config::set_max_concurrent_proposals(&mut gov, 10);

    let meta = dao_config::new_metadata_config(
        ascii::string(b"TestDAO"),
        url::new_unsafe_from_bytes(b"https://test.com/icon.png"),
        string::utf8(b"Test DAO"),
    );
    let sec = dao_config::default_security_config();
    let storage = dao_config::default_storage_config();
    let coin_config = dao_config::default_conditional_coin_config();
    let quota = dao_config::default_quota_config();
    let multisig = dao_config::default_multisig_config();
    let subsidy = dao_config::default_subsidy_config();

    let current_config = dao_config::new_dao_config(
        trading,
        twap,
        gov,
        meta,
        sec,
        storage,
        coin_config,
        quota,
        multisig,
        subsidy,
        1000000,
        259200000,
        500000,
    );

    // Try to reduce max_concurrent to 5 when there are 7 active proposals
    dao_config::set_max_concurrent_proposals(&mut gov, 5);
    let new_config = dao_config::update_governance_config(&current_config, gov);

    assert!(!dao_config::validate_config_update(&current_config, &new_config, 7), 0);
}

#[test]
fun test_validate_config_update_unsafe_reduce_max_outcomes_with_active() {
    let trading = dao_config::default_trading_params();
    let twap = dao_config::default_twap_config();
    let mut gov = dao_config::default_governance_config();
    dao_config::set_max_outcomes(&mut gov, 5);

    let meta = dao_config::new_metadata_config(
        ascii::string(b"TestDAO"),
        url::new_unsafe_from_bytes(b"https://test.com/icon.png"),
        string::utf8(b"Test DAO"),
    );
    let sec = dao_config::default_security_config();
    let storage = dao_config::default_storage_config();
    let coin_config = dao_config::default_conditional_coin_config();
    let quota = dao_config::default_quota_config();
    let multisig = dao_config::default_multisig_config();
    let subsidy = dao_config::default_subsidy_config();

    let current_config = dao_config::new_dao_config(
        trading,
        twap,
        gov,
        meta,
        sec,
        storage,
        coin_config,
        quota,
        multisig,
        subsidy,
        1000000,
        259200000,
        500000,
    );

    // Try to reduce max_outcomes to 3 when there are active proposals
    dao_config::set_max_outcomes(&mut gov, 3);
    let new_config = dao_config::update_governance_config(&current_config, gov);

    assert!(!dao_config::validate_config_update(&current_config, &new_config, 2), 0);
}

#[test]
fun test_validate_config_update_safe_reduce_when_no_active() {
    let trading = dao_config::default_trading_params();
    let twap = dao_config::default_twap_config();
    let mut gov = dao_config::default_governance_config();
    dao_config::set_max_outcomes(&mut gov, 5);

    let meta = dao_config::new_metadata_config(
        ascii::string(b"TestDAO"),
        url::new_unsafe_from_bytes(b"https://test.com/icon.png"),
        string::utf8(b"Test DAO"),
    );
    let sec = dao_config::default_security_config();
    let storage = dao_config::default_storage_config();
    let coin_config = dao_config::default_conditional_coin_config();
    let quota = dao_config::default_quota_config();
    let multisig = dao_config::default_multisig_config();
    let subsidy = dao_config::default_subsidy_config();

    let current_config = dao_config::new_dao_config(
        trading,
        twap,
        gov,
        meta,
        sec,
        storage,
        coin_config,
        quota,
        multisig,
        subsidy,
        1000000,
        259200000,
        500000,
    );

    // Safe to reduce max_outcomes when no active proposals
    dao_config::set_max_outcomes(&mut gov, 3);
    let new_config = dao_config::update_governance_config(&current_config, gov);

    assert!(dao_config::validate_config_update(&current_config, &new_config, 0), 0);
}
