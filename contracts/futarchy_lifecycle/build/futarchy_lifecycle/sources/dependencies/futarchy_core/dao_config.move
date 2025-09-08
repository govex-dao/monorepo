/// DAO configuration management module
/// Provides centralized configuration structs and validation for futarchy DAOs
module futarchy_core::dao_config;

use std::{
    string::String,
    ascii::String as AsciiString,
};
use sui::url::Url;
use futarchy_one_shot_utils::constants;

// === Errors ===
const EInvalidMinAmount: u64 = 0; // Minimum amount must be positive
const EInvalidPeriod: u64 = 1; // Period must be positive
const EInvalidFee: u64 = 2; // Fee exceeds maximum (10000 bps = 100%)
const EInvalidMaxOutcomes: u64 = 3; // Max outcomes must be at least 2
const EInvalidTwapThreshold: u64 = 4; // TWAP threshold must be positive
const EInvalidProposalFee: u64 = 5; // Proposal fee must be positive
const EInvalidBondAmount: u64 = 6; // Bond amount must be positive
const EInvalidTwapParams: u64 = 7; // Invalid TWAP parameters
const EInvalidGracePeriod: u64 = 8; // Grace period too short
const EInvalidMaxConcurrentProposals: u64 = 9; // Max concurrent proposals must be positive
const EMaxOutcomesExceedsProtocol: u64 = 10; // Max outcomes exceeds protocol limit
const EMaxActionsExceedsProtocol: u64 = 11; // Max actions exceeds protocol limit

// === Constants ===
// Most constants are now in futarchy_utils::constants
// Only keep module-specific error codes here

// === Structs ===

/// Trading parameters configuration
public struct TradingParams has store, drop, copy {
    min_asset_amount: u64,
    min_stable_amount: u64,
    review_period_ms: u64,
    trading_period_ms: u64,
    amm_total_fee_bps: u64,
}

/// TWAP (Time-Weighted Average Price) configuration
public struct TwapConfig has store, drop, copy {
    start_delay: u64,
    step_max: u64,
    initial_observation: u128,
    threshold: u64,
}

/// Governance parameters configuration
public struct GovernanceConfig has store, drop, copy {
    max_outcomes: u64,
    max_actions_per_outcome: u64, // Maximum actions allowed per single outcome
    proposal_fee_per_outcome: u64,
    required_bond_amount: u64,
    max_concurrent_proposals: u64,
    proposal_recreation_window_ms: u64,
    max_proposal_chain_depth: u64,
    fee_escalation_basis_points: u64,
    proposal_creation_enabled: bool,
    accept_new_proposals: bool,
    max_intents_per_outcome: u64,
    optimistic_challenge_fee: u64, // Fee to challenge optimistic proposals
    optimistic_challenge_period_ms: u64, // Time period to challenge optimistic proposals (e.g., 10 days)
    eviction_grace_period_ms: u64,
    proposal_intent_expiry_ms: u64, // How long proposal intents remain valid
}

/// Metadata configuration
public struct MetadataConfig has store, drop, copy {
    dao_name: AsciiString,
    icon_url: Url,
    description: String,
}

/// Security configuration for dead-man switch
public struct SecurityConfig has store, drop, copy {
    deadman_enabled: bool,               // If true, dead-man switch recovery is enabled
    recovery_liveness_ms: u64,           // Inactivity threshold for dead-man switch (e.g., 30 days)
    require_deadman_council: bool,       // If true, all councils must support dead-man switch
}

/// Complete DAO configuration
public struct DaoConfig has store, drop, copy {
    trading_params: TradingParams,
    twap_config: TwapConfig,
    governance_config: GovernanceConfig,
    metadata_config: MetadataConfig,
    security_config: SecurityConfig,
}

// === Constructor Functions ===

/// Create a new trading parameters configuration
public fun new_trading_params(
    min_asset_amount: u64,
    min_stable_amount: u64,
    review_period_ms: u64,
    trading_period_ms: u64,
    amm_total_fee_bps: u64,
): TradingParams {
    // Validate inputs
    assert!(min_asset_amount > 0, EInvalidMinAmount);
    assert!(min_stable_amount > 0, EInvalidMinAmount);
    assert!(review_period_ms >= constants::min_review_period_ms(), EInvalidPeriod);
    assert!(trading_period_ms >= constants::min_trading_period_ms(), EInvalidPeriod);
    assert!(amm_total_fee_bps <= constants::max_fee_bps(), EInvalidFee);
    
    TradingParams {
        min_asset_amount,
        min_stable_amount,
        review_period_ms,
        trading_period_ms,
        amm_total_fee_bps,
    }
}

/// Create a new TWAP configuration
public fun new_twap_config(
    start_delay: u64,
    step_max: u64,
    initial_observation: u128,
    threshold: u64,
): TwapConfig {
    // Validate inputs - start_delay can be 0 for immediate TWAP start
    // This is a valid use case for certain market configurations
    assert!(step_max > 0, EInvalidTwapParams);
    assert!(initial_observation > 0, EInvalidTwapParams);
    assert!(threshold > 0, EInvalidTwapThreshold);
    
    TwapConfig {
        start_delay,
        step_max,
        initial_observation,
        threshold,
    }
}

/// Create a new governance configuration
public fun new_governance_config(
    max_outcomes: u64,
    max_actions_per_outcome: u64,
    proposal_fee_per_outcome: u64,
    required_bond_amount: u64,
    max_concurrent_proposals: u64,
    proposal_recreation_window_ms: u64,
    max_proposal_chain_depth: u64,
    fee_escalation_basis_points: u64,
    proposal_creation_enabled: bool,
    accept_new_proposals: bool,
    max_intents_per_outcome: u64,
    optimistic_challenge_fee: u64,
    optimistic_challenge_period_ms: u64,
    eviction_grace_period_ms: u64,
    proposal_intent_expiry_ms: u64,
): GovernanceConfig {
    // Validate inputs
    assert!(max_outcomes >= constants::min_outcomes(), EInvalidMaxOutcomes);
    assert!(max_outcomes <= constants::protocol_max_outcomes(), EMaxOutcomesExceedsProtocol);
    assert!(max_actions_per_outcome > 0 && max_actions_per_outcome <= constants::protocol_max_actions_per_outcome(), EMaxActionsExceedsProtocol);
    assert!(proposal_fee_per_outcome > 0, EInvalidProposalFee);
    assert!(required_bond_amount > 0, EInvalidBondAmount);
    assert!(max_concurrent_proposals > 0, EInvalidMaxConcurrentProposals);
    assert!(fee_escalation_basis_points <= constants::max_fee_bps(), EInvalidFee);
    assert!(max_intents_per_outcome > 0, EInvalidMaxOutcomes);
    assert!(optimistic_challenge_fee > 0, EInvalidProposalFee);
    assert!(optimistic_challenge_period_ms > 0, EInvalidPeriod); // Must be non-zero
    assert!(eviction_grace_period_ms >= constants::min_eviction_grace_period_ms(), EInvalidGracePeriod);
    
    GovernanceConfig {
        max_outcomes,
        max_actions_per_outcome,
        proposal_fee_per_outcome,
        required_bond_amount,
        max_concurrent_proposals,
        proposal_recreation_window_ms,
        max_proposal_chain_depth,
        fee_escalation_basis_points,
        proposal_creation_enabled,
        accept_new_proposals,
        max_intents_per_outcome,
        optimistic_challenge_fee,
        optimistic_challenge_period_ms,
        eviction_grace_period_ms,
        proposal_intent_expiry_ms,
    }
}

/// Create a new metadata configuration
public fun new_metadata_config(
    dao_name: AsciiString,
    icon_url: Url,
    description: String,
): MetadataConfig {
    MetadataConfig {
        dao_name,
        icon_url,
        description,
    }
}

/// Create a new security configuration
public fun new_security_config(
    deadman_enabled: bool,
    recovery_liveness_ms: u64,
    require_deadman_council: bool,
): SecurityConfig {
    SecurityConfig {
        deadman_enabled,
        recovery_liveness_ms,
        require_deadman_council,
    }
}

/// Create a complete DAO configuration
public fun new_dao_config(
    trading_params: TradingParams,
    twap_config: TwapConfig,
    governance_config: GovernanceConfig,
    metadata_config: MetadataConfig,
    security_config: SecurityConfig,
): DaoConfig {
    DaoConfig {
        trading_params,
        twap_config,
        governance_config,
        metadata_config,
        security_config,
    }
}

// === Getter Functions ===

// Trading params getters
public fun trading_params(config: &DaoConfig): &TradingParams { &config.trading_params }
public(package) fun trading_params_mut(config: &mut DaoConfig): &mut TradingParams { &mut config.trading_params }
public fun min_asset_amount(params: &TradingParams): u64 { params.min_asset_amount }
public fun min_stable_amount(params: &TradingParams): u64 { params.min_stable_amount }
public fun review_period_ms(params: &TradingParams): u64 { params.review_period_ms }
public fun trading_period_ms(params: &TradingParams): u64 { params.trading_period_ms }
public fun amm_total_fee_bps(params: &TradingParams): u64 { params.amm_total_fee_bps }

// TWAP config getters
public fun twap_config(config: &DaoConfig): &TwapConfig { &config.twap_config }
public(package) fun twap_config_mut(config: &mut DaoConfig): &mut TwapConfig { &mut config.twap_config }
public fun start_delay(twap: &TwapConfig): u64 { twap.start_delay }
public fun step_max(twap: &TwapConfig): u64 { twap.step_max }
public fun initial_observation(twap: &TwapConfig): u128 { twap.initial_observation }
public fun threshold(twap: &TwapConfig): u64 { twap.threshold }

// Governance config getters
public fun governance_config(config: &DaoConfig): &GovernanceConfig { &config.governance_config }
public(package) fun governance_config_mut(config: &mut DaoConfig): &mut GovernanceConfig { &mut config.governance_config }
public fun max_outcomes(gov: &GovernanceConfig): u64 { gov.max_outcomes }
public fun max_actions_per_outcome(gov: &GovernanceConfig): u64 { gov.max_actions_per_outcome }
public fun proposal_fee_per_outcome(gov: &GovernanceConfig): u64 { gov.proposal_fee_per_outcome }
public fun optimistic_challenge_fee(gov: &GovernanceConfig): u64 { gov.optimistic_challenge_fee }
public fun optimistic_challenge_period_ms(gov: &GovernanceConfig): u64 { gov.optimistic_challenge_period_ms }
public fun required_bond_amount(gov: &GovernanceConfig): u64 { gov.required_bond_amount }
public fun max_concurrent_proposals(gov: &GovernanceConfig): u64 { gov.max_concurrent_proposals }
public fun proposal_recreation_window_ms(gov: &GovernanceConfig): u64 { gov.proposal_recreation_window_ms }
public fun max_proposal_chain_depth(gov: &GovernanceConfig): u64 { gov.max_proposal_chain_depth }
public fun fee_escalation_basis_points(gov: &GovernanceConfig): u64 { gov.fee_escalation_basis_points }
public fun proposal_creation_enabled(gov: &GovernanceConfig): bool { gov.proposal_creation_enabled }
public fun accept_new_proposals(gov: &GovernanceConfig): bool { gov.accept_new_proposals }
public fun max_intents_per_outcome(gov: &GovernanceConfig): u64 { gov.max_intents_per_outcome }
public fun eviction_grace_period_ms(gov: &GovernanceConfig): u64 { gov.eviction_grace_period_ms }
public fun proposal_intent_expiry_ms(gov: &GovernanceConfig): u64 { gov.proposal_intent_expiry_ms }

// Metadata config getters
public fun metadata_config(config: &DaoConfig): &MetadataConfig { &config.metadata_config }
public(package) fun metadata_config_mut(config: &mut DaoConfig): &mut MetadataConfig { &mut config.metadata_config }
public fun dao_name(meta: &MetadataConfig): &AsciiString { &meta.dao_name }
public fun icon_url(meta: &MetadataConfig): &Url { &meta.icon_url }
public fun description(meta: &MetadataConfig): &String { &meta.description }

// Security config getters
public fun security_config(config: &DaoConfig): &SecurityConfig { &config.security_config }
public(package) fun security_config_mut(config: &mut DaoConfig): &mut SecurityConfig { &mut config.security_config }
public fun deadman_enabled(sec: &SecurityConfig): bool { sec.deadman_enabled }
public fun recovery_liveness_ms(sec: &SecurityConfig): u64 { sec.recovery_liveness_ms }
public fun require_deadman_council(sec: &SecurityConfig): bool { sec.require_deadman_council }

// === Update Functions ===

// === Direct Field Setters (Package-level) ===
// These functions provide efficient in-place field updates without struct copying

// Trading params direct setters
public(package) fun set_min_asset_amount(params: &mut TradingParams, amount: u64) {
    assert!(amount > 0, EInvalidMinAmount);
    params.min_asset_amount = amount;
}

public(package) fun set_min_stable_amount(params: &mut TradingParams, amount: u64) {
    assert!(amount > 0, EInvalidMinAmount);
    params.min_stable_amount = amount;
}

public(package) fun set_review_period_ms(params: &mut TradingParams, period: u64) {
    assert!(period >= constants::min_review_period_ms(), EInvalidPeriod);
    params.review_period_ms = period;
}

public(package) fun set_trading_period_ms(params: &mut TradingParams, period: u64) {
    assert!(period >= constants::min_trading_period_ms(), EInvalidPeriod);
    params.trading_period_ms = period;
}

public(package) fun set_amm_total_fee_bps(params: &mut TradingParams, fee_bps: u64) {
    assert!(fee_bps <= constants::max_fee_bps(), EInvalidFee);
    params.amm_total_fee_bps = fee_bps;
}

// TWAP config direct setters
public(package) fun set_start_delay(twap: &mut TwapConfig, delay: u64) {
    // Allow 0 for testing
    twap.start_delay = delay;
}

public(package) fun set_step_max(twap: &mut TwapConfig, max: u64) {
    assert!(max > 0, EInvalidTwapParams);
    twap.step_max = max;
}

public(package) fun set_initial_observation(twap: &mut TwapConfig, obs: u128) {
    assert!(obs > 0, EInvalidTwapParams);
    twap.initial_observation = obs;
}

public(package) fun set_threshold(twap: &mut TwapConfig, threshold: u64) {
    assert!(threshold > 0, EInvalidTwapThreshold);
    twap.threshold = threshold;
}

// Governance config direct setters
public(package) fun set_max_outcomes(gov: &mut GovernanceConfig, max: u64) {
    assert!(max >= constants::min_outcomes(), EInvalidMaxOutcomes);
    assert!(max <= constants::protocol_max_outcomes(), EMaxOutcomesExceedsProtocol);
    gov.max_outcomes = max;
}

public(package) fun set_max_actions_per_outcome(gov: &mut GovernanceConfig, max: u64) {
    assert!(max > 0 && max <= constants::protocol_max_actions_per_outcome(), EMaxActionsExceedsProtocol);
    gov.max_actions_per_outcome = max;
}

public(package) fun set_proposal_fee_per_outcome(gov: &mut GovernanceConfig, fee: u64) {
    assert!(fee > 0, EInvalidProposalFee);
    gov.proposal_fee_per_outcome = fee;
}

public(package) fun set_required_bond_amount(gov: &mut GovernanceConfig, amount: u64) {
    assert!(amount > 0, EInvalidBondAmount);
    gov.required_bond_amount = amount;
}

public(package) fun set_optimistic_challenge_fee(gov: &mut GovernanceConfig, amount: u64) {
    assert!(amount > 0, EInvalidProposalFee);
    gov.optimistic_challenge_fee = amount;
}

public(package) fun set_optimistic_challenge_period_ms(gov: &mut GovernanceConfig, period: u64) {
    assert!(period > 0, EInvalidPeriod); // Must be non-zero
    gov.optimistic_challenge_period_ms = period;
}

public(package) fun set_max_concurrent_proposals(gov: &mut GovernanceConfig, max: u64) {
    assert!(max > 0, EInvalidMaxConcurrentProposals);
    gov.max_concurrent_proposals = max;
}

public(package) fun set_proposal_recreation_window_ms(gov: &mut GovernanceConfig, window: u64) {
    gov.proposal_recreation_window_ms = window;
}

public(package) fun set_max_proposal_chain_depth(gov: &mut GovernanceConfig, depth: u64) {
    gov.max_proposal_chain_depth = depth;
}

public(package) fun set_fee_escalation_basis_points(gov: &mut GovernanceConfig, points: u64) {
    assert!(points <= constants::max_fee_bps(), EInvalidFee);
    gov.fee_escalation_basis_points = points;
}

public(package) fun set_proposal_creation_enabled(gov: &mut GovernanceConfig, enabled: bool) {
    gov.proposal_creation_enabled = enabled;
}

public(package) fun set_accept_new_proposals(gov: &mut GovernanceConfig, accept: bool) {
    gov.accept_new_proposals = accept;
}

public(package) fun set_max_intents_per_outcome(gov: &mut GovernanceConfig, max: u64) {
    assert!(max > 0, EInvalidMaxOutcomes);
    gov.max_intents_per_outcome = max;
}

public(package) fun set_eviction_grace_period_ms(gov: &mut GovernanceConfig, period: u64) {
    assert!(period >= constants::min_eviction_grace_period_ms(), EInvalidGracePeriod);
    gov.eviction_grace_period_ms = period;
}

public(package) fun set_proposal_intent_expiry_ms(gov: &mut GovernanceConfig, period: u64) {
    assert!(period >= constants::min_proposal_intent_expiry_ms(), EInvalidGracePeriod);
    gov.proposal_intent_expiry_ms = period;
}

// Metadata config direct setters
public(package) fun set_dao_name(meta: &mut MetadataConfig, name: AsciiString) {
    meta.dao_name = name;
}

public(package) fun set_icon_url(meta: &mut MetadataConfig, url: Url) {
    meta.icon_url = url;
}

public(package) fun set_description(meta: &mut MetadataConfig, desc: String) {
    meta.description = desc;
}

// Security config direct setters

public(package) fun set_deadman_enabled(sec: &mut SecurityConfig, val: bool) {
    sec.deadman_enabled = val;
}

public(package) fun set_recovery_liveness_ms(sec: &mut SecurityConfig, ms: u64) {
    sec.recovery_liveness_ms = ms;
}

public(package) fun set_require_deadman_council(sec: &mut SecurityConfig, val: bool) {
    sec.require_deadman_council = val;
}

/// Update trading parameters (returns new config)
public fun update_trading_params(config: &DaoConfig, new_params: TradingParams): DaoConfig {
    DaoConfig {
        trading_params: new_params,
        twap_config: config.twap_config,
        governance_config: config.governance_config,
        metadata_config: config.metadata_config,
        security_config: config.security_config,
    }
}

/// Update TWAP configuration (returns new config)
public fun update_twap_config(config: &DaoConfig, new_twap: TwapConfig): DaoConfig {
    DaoConfig {
        trading_params: config.trading_params,
        twap_config: new_twap,
        governance_config: config.governance_config,
        metadata_config: config.metadata_config,
        security_config: config.security_config,
    }
}

/// Update governance configuration (returns new config)
public fun update_governance_config(config: &DaoConfig, new_gov: GovernanceConfig): DaoConfig {
    DaoConfig {
        trading_params: config.trading_params,
        twap_config: config.twap_config,
        governance_config: new_gov,
        metadata_config: config.metadata_config,
        security_config: config.security_config,
    }
}

/// Update metadata configuration (returns new config)
public fun update_metadata_config(config: &DaoConfig, new_meta: MetadataConfig): DaoConfig {
    DaoConfig {
        trading_params: config.trading_params,
        twap_config: config.twap_config,
        governance_config: config.governance_config,
        metadata_config: new_meta,
        security_config: config.security_config,
    }
}

/// Update security configuration (returns new config)
public fun update_security_config(config: &DaoConfig, new_sec: SecurityConfig): DaoConfig {
    DaoConfig {
        trading_params: config.trading_params,
        twap_config: config.twap_config,
        governance_config: config.governance_config,
        metadata_config: config.metadata_config,
        security_config: new_sec,
    }
}

// === Default Configuration ===

/// Get default trading parameters for testing
public fun default_trading_params(): TradingParams {
    TradingParams {
        min_asset_amount: 1000000, // 1 token with 6 decimals
        min_stable_amount: 1000000, // 1 stable with 6 decimals
        review_period_ms: 86400000, // 24 hours
        trading_period_ms: 604800000, // 7 days
        amm_total_fee_bps: 30, // 0.3%
    }
}

/// Get default TWAP configuration for testing
public fun default_twap_config(): TwapConfig {
    TwapConfig {
        start_delay: 300000, // 5 minutes
        step_max: 300000, // 5 minutes
        initial_observation: 1000000000000, // Initial price observation
        threshold: 10, // 10% threshold
    }
}

/// Get default governance configuration for testing
public fun default_governance_config(): GovernanceConfig {
    GovernanceConfig {
        max_outcomes: constants::default_max_outcomes(),
        max_actions_per_outcome: constants::default_max_actions_per_outcome(),
        proposal_fee_per_outcome: 1000000, // 1 token per outcome
        required_bond_amount: 10000000, // 10 tokens
        max_concurrent_proposals: 5,
        proposal_recreation_window_ms: constants::default_proposal_recreation_window_ms(),
        max_proposal_chain_depth: constants::default_max_proposal_chain_depth(),
        fee_escalation_basis_points: constants::default_fee_escalation_bps(),
        proposal_creation_enabled: true,
        accept_new_proposals: true,
        max_intents_per_outcome: 10, // Allow up to 10 intents per outcome
        optimistic_challenge_fee: constants::default_optimistic_challenge_fee(),
        optimistic_challenge_period_ms: constants::default_optimistic_challenge_period_ms(),
        eviction_grace_period_ms: constants::default_eviction_grace_period_ms(),
        proposal_intent_expiry_ms: constants::default_proposal_intent_expiry_ms(),
    }
}

/// Get default security configuration
public fun default_security_config(): SecurityConfig {
    SecurityConfig {
        deadman_enabled: false,          // Opt-in feature
        recovery_liveness_ms: 2_592_000_000, // 30 days default
        require_deadman_council: false,  // Optional
    }
}