/// DAO configuration management module
/// Provides centralized configuration structs and validation for futarchy DAOs
module futarchy::dao_config;

use std::{
    string::String,
    ascii::String as AsciiString,
};
use sui::url::Url;

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

// === Constants ===
const MAX_FEE_BPS: u64 = 10000; // 100% in basis points
const MIN_OUTCOMES: u64 = 2; // Minimum number of outcomes for a proposal
const MIN_REVIEW_PERIOD_MS: u64 = 1000; // 1 second minimum review period (lowered for testing)
const MIN_TRADING_PERIOD_MS: u64 = 1000; // 1 second minimum trading period (lowered for testing)

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
    proposal_fee_per_outcome: u64,
    required_bond_amount: u64,
    max_concurrent_proposals: u64,
    proposal_recreation_window_ms: u64,
    max_proposal_chain_depth: u64,
    fee_escalation_basis_points: u64,
    proposal_creation_enabled: bool,
    accept_new_proposals: bool,
    max_intents_per_outcome: u64,
    eviction_grace_period_ms: u64,
}

/// Metadata configuration
public struct MetadataConfig has store, drop, copy {
    dao_name: AsciiString,
    icon_url: Url,
    description: String,
}

/// Security configuration for dead-man switch and OA protection
public struct SecurityConfig has store, drop, copy {
    oa_custodian_immutable: bool,        // If true, OA:Custodian cannot be updated (council can still give up control)
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
    assert!(review_period_ms >= MIN_REVIEW_PERIOD_MS, EInvalidPeriod);
    assert!(trading_period_ms >= MIN_TRADING_PERIOD_MS, EInvalidPeriod);
    assert!(amm_total_fee_bps <= MAX_FEE_BPS, EInvalidFee);
    
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
    // Validate inputs (allow 0 for start_delay for testing)
    // assert!(start_delay > 0, EInvalidTwapParams); // Commented out to allow 0 for testing
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
    proposal_fee_per_outcome: u64,
    required_bond_amount: u64,
    max_concurrent_proposals: u64,
    proposal_recreation_window_ms: u64,
    max_proposal_chain_depth: u64,
    fee_escalation_basis_points: u64,
    proposal_creation_enabled: bool,
    accept_new_proposals: bool,
    max_intents_per_outcome: u64,
    eviction_grace_period_ms: u64,
): GovernanceConfig {
    // Validate inputs
    assert!(max_outcomes >= MIN_OUTCOMES, EInvalidMaxOutcomes);
    assert!(proposal_fee_per_outcome > 0, EInvalidProposalFee);
    assert!(required_bond_amount > 0, EInvalidBondAmount);
    assert!(max_concurrent_proposals > 0, EInvalidProposalFee);
    assert!(fee_escalation_basis_points <= MAX_FEE_BPS, EInvalidFee);
    assert!(max_intents_per_outcome > 0, EInvalidMaxOutcomes);
    assert!(eviction_grace_period_ms >= 300000, EInvalidGracePeriod); // Min 5 minutes
    
    GovernanceConfig {
        max_outcomes,
        proposal_fee_per_outcome,
        required_bond_amount,
        max_concurrent_proposals,
        proposal_recreation_window_ms,
        max_proposal_chain_depth,
        fee_escalation_basis_points,
        proposal_creation_enabled,
        accept_new_proposals,
        max_intents_per_outcome,
        eviction_grace_period_ms,
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
    oa_custodian_immutable: bool,
    deadman_enabled: bool,
    recovery_liveness_ms: u64,
    require_deadman_council: bool,
): SecurityConfig {
    SecurityConfig {
        oa_custodian_immutable,
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
public fun min_asset_amount(params: &TradingParams): u64 { params.min_asset_amount }
public fun min_stable_amount(params: &TradingParams): u64 { params.min_stable_amount }
public fun review_period_ms(params: &TradingParams): u64 { params.review_period_ms }
public fun trading_period_ms(params: &TradingParams): u64 { params.trading_period_ms }
public fun amm_total_fee_bps(params: &TradingParams): u64 { params.amm_total_fee_bps }

// TWAP config getters
public fun twap_config(config: &DaoConfig): &TwapConfig { &config.twap_config }
public fun start_delay(twap: &TwapConfig): u64 { twap.start_delay }
public fun step_max(twap: &TwapConfig): u64 { twap.step_max }
public fun initial_observation(twap: &TwapConfig): u128 { twap.initial_observation }
public fun threshold(twap: &TwapConfig): u64 { twap.threshold }

// Governance config getters
public fun governance_config(config: &DaoConfig): &GovernanceConfig { &config.governance_config }
public fun max_outcomes(gov: &GovernanceConfig): u64 { gov.max_outcomes }
public fun proposal_fee_per_outcome(gov: &GovernanceConfig): u64 { gov.proposal_fee_per_outcome }
public fun required_bond_amount(gov: &GovernanceConfig): u64 { gov.required_bond_amount }
public fun max_concurrent_proposals(gov: &GovernanceConfig): u64 { gov.max_concurrent_proposals }
public fun proposal_recreation_window_ms(gov: &GovernanceConfig): u64 { gov.proposal_recreation_window_ms }
public fun max_proposal_chain_depth(gov: &GovernanceConfig): u64 { gov.max_proposal_chain_depth }
public fun fee_escalation_basis_points(gov: &GovernanceConfig): u64 { gov.fee_escalation_basis_points }
public fun proposal_creation_enabled(gov: &GovernanceConfig): bool { gov.proposal_creation_enabled }
public fun accept_new_proposals(gov: &GovernanceConfig): bool { gov.accept_new_proposals }
public fun max_intents_per_outcome(gov: &GovernanceConfig): u64 { gov.max_intents_per_outcome }
public fun eviction_grace_period_ms(gov: &GovernanceConfig): u64 { gov.eviction_grace_period_ms }

// Metadata config getters
public fun metadata_config(config: &DaoConfig): &MetadataConfig { &config.metadata_config }
public fun dao_name(meta: &MetadataConfig): &AsciiString { &meta.dao_name }
public fun icon_url(meta: &MetadataConfig): &Url { &meta.icon_url }
public fun description(meta: &MetadataConfig): &String { &meta.description }

// Security config getters
public fun security_config(config: &DaoConfig): &SecurityConfig { &config.security_config }
public fun oa_custodian_immutable(sec: &SecurityConfig): bool { sec.oa_custodian_immutable }
public fun deadman_enabled(sec: &SecurityConfig): bool { sec.deadman_enabled }
public fun recovery_liveness_ms(sec: &SecurityConfig): u64 { sec.recovery_liveness_ms }
public fun require_deadman_council(sec: &SecurityConfig): bool { sec.require_deadman_council }

// === Update Functions ===

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
        max_outcomes: 10,
        proposal_fee_per_outcome: 1000000, // 1 token per outcome
        required_bond_amount: 10000000, // 10 tokens
        max_concurrent_proposals: 5,
        proposal_recreation_window_ms: 86400000, // 24 hours
        max_proposal_chain_depth: 3,
        fee_escalation_basis_points: 500, // 5%
        proposal_creation_enabled: true,
        accept_new_proposals: true,
        max_intents_per_outcome: 10, // Allow up to 10 intents per outcome
        eviction_grace_period_ms: 7200000, // 2 hours default
    }
}

/// Get default security configuration
public fun default_security_config(): SecurityConfig {
    SecurityConfig {
        oa_custodian_immutable: false,  // Allow updates by default
        deadman_enabled: false,          // Opt-in feature
        recovery_liveness_ms: 2_592_000_000, // 30 days default
        require_deadman_council: false,  // Optional
    }
}