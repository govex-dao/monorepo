// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

/// DAO configuration management module
/// Provides centralized configuration structs and validation for futarchy DAOs
module futarchy_core::dao_config;

use futarchy_one_shot_utils::constants;
use futarchy_types::signed::{Self as signed, SignedU128};
use std::ascii::{Self, String as AsciiString};
use std::string::{Self, String};
use sui::url::{Self, Url};

// === Errors ===
const EInvalidMinAmount: u64 = 0; // Minimum amount must be positive
const EMinAmountTooLow: u64 = 16; // Minimum amount must be at least 100,000 (0.1 tokens with 6 decimals)
const EInvalidPeriod: u64 = 1; // Period must be positive
const EInvalidFee: u64 = 2; // Fee exceeds maximum (10000 bps = 100%)
const EInvalidMaxOutcomes: u64 = 3; // Max outcomes must be at least 2
const EInvalidTwapThreshold: u64 = 4; // TWAP threshold must be valid
const EInvalidProposalFee: u64 = 5; // Proposal fee must be positive
const EInvalidBondAmount: u64 = 6; // Bond amount must be positive
const EInvalidTwapParams: u64 = 7; // Invalid TWAP parameters
const EInvalidGracePeriod: u64 = 8; // Grace period too short
const EInvalidMaxConcurrentProposals: u64 = 9; // Max concurrent proposals must be positive
const EMaxOutcomesExceedsProtocol: u64 = 10; // Max outcomes exceeds protocol limit
const EMaxActionsExceedsProtocol: u64 = 11; // Max actions exceeds protocol limit
const EStateInconsistent: u64 = 12; // State would become inconsistent with this change
const EInvalidQuotaParams: u64 = 14; // Invalid quota parameters
const ENoConditionalMetadata: u64 = 15; // No conditional metadata available (neither CoinMetadata nor fallback config)
const ESponsoredThresholdMustBeNonPositive: u64 = 17; // Sponsored threshold must be ≤ 0
const ESponsoredThresholdExceedsProtocolMax: u64 = 18; // Sponsored threshold magnitude exceeds ±5%

// === Constants ===
// Most constants are now in futarchy_utils::constants
// Only keep module-specific error codes here

// Minimum liquidity amounts for conditional markets
// Ensures proposals NEVER blocked by quantum split k>=1000 check
//
// With min=100,000 and 99% ratio: spot keeps 100,000 * 1/100 = 1,000 each
// → k = 1,000 * 1,000 = 1,000,000 ✅ (well above AMM MINIMUM_LIQUIDITY = 1,000)
//
// Cost is trivial with common decimal counts:
// - 6 decimals (USDC): 100,000 = 0.1 tokens
// - 8 decimals (BTC-style): 100,000 = 0.001 tokens
// - 9 decimals (Sui): 100,000 = 0.0001 tokens (basically free)
const PROTOCOL_MIN_LIQUIDITY_AMOUNT: u64 = 100000;

// Protocol-level threshold bounds: ±5% maximum (duplicated here to avoid circular dependency)
const PROTOCOL_MAX_THRESHOLD_NEGATIVE: u128 = 50_000_000_000; // -5% (stored as magnitude, 0.05 * 1e12)

// === Structs ===

/// Trading parameters configuration
public struct TradingParams has copy, drop, store {
    min_asset_amount: u64,
    min_stable_amount: u64,
    review_period_ms: u64,
    trading_period_ms: u64,
    conditional_amm_fee_bps: u64, // Fee for conditional AMMs (prediction markets)
    spot_amm_fee_bps: u64, // Fee for spot AMM (base pool)
    // Market operation review period (for conditional raise/buyback)
    // Can be 0 to skip review and start trading immediately after market init
    market_op_review_period_ms: u64,
    // Max percentage (in basis points) of AMM reserves that can be auto-swapped per proposal
    // Default: 1000 bps (10%) - prevents market from becoming too illiquid for trading
    max_amm_swap_percent_bps: u64,
    // Percentage of liquidity that moves to conditional markets when proposal launches
    // Base 100 precision (1 = 1%, 80 = 80%, 99 = 99%)
    // Valid range: 1-99 (enforced to ensure both spot and conditional pools have liquidity)
    // Default: 80 (80%) - balances price discovery with spot trading
    conditional_liquidity_ratio_percent: u64,
}

/// TWAP (Time-Weighted Average Price) configuration
public struct TwapConfig has copy, drop, store {
    start_delay: u64,
    step_max: u64,
    initial_observation: u128,
    threshold: SignedU128,
}

/// Governance parameters configuration
public struct GovernanceConfig has copy, drop, store {
    max_outcomes: u64,
    max_actions_per_outcome: u64, // Maximum actions allowed per single outcome
    proposal_fee_per_outcome: u64,
    required_bond_amount: u64,
    fee_escalation_basis_points: u64,
    proposal_creation_enabled: bool,
    accept_new_proposals: bool,
    max_intents_per_outcome: u64,
    eviction_grace_period_ms: u64,
    proposal_intent_expiry_ms: u64, // How long proposal intents remain valid
    // If true, premarket proposals lock the queue reservation slot (anti-MEV)
    // If false, no reservation lock (more market init opportunities, less MEV protection)
    enable_premarket_reservation_lock: bool,
}

/// Metadata configuration
public struct MetadataConfig has copy, drop, store {
    dao_name: AsciiString,
    icon_url: Url,
    description: String,
}

/// Security configuration for dead-man switch
public struct SecurityConfig has copy, drop, store {
    deadman_enabled: bool, // If true, dead-man switch recovery is enabled
    recovery_liveness_ms: u64, // Inactivity threshold for dead-man switch (e.g., 30 days)
    require_deadman_council: bool, // If true, all councils must support dead-man switch
}

/// Storage configuration for DAO files
public struct StorageConfig has copy, drop, store {
    // REMOVED: allow_walrus_blobs - Walrus functionality moved to v3_futarchy_legal
}

/// Conditional coin metadata configuration for proposals
public struct ConditionalCoinConfig has copy, drop, store {
    use_outcome_index: bool, // If true, append outcome index to name
    // If Some(), use these hardcoded values for conditional tokens
    // If None(), derive conditional token names from base DAO token CoinMetadata
    conditional_metadata: Option<ConditionalMetadata>,
}

/// Metadata for conditional tokens (fallback if CoinMetadata can't be read)
public struct ConditionalMetadata has copy, drop, store {
    decimals: u8, // Decimals for conditional coins
    coin_name_prefix: AsciiString, // Prefix for coin names (e.g., "MyDAO_")
    coin_icon_url: Url, // Icon URL for conditional coins
}

/// Quota system configuration
public struct QuotaConfig has copy, drop, store {
    enabled: bool, // If true, quota system is active
    default_quota_amount: u64, // Default proposals per period for new allowlist members
    default_quota_period_ms: u64, // Default period for quotas (e.g., 30 days)
    default_reduced_fee: u64, // Default reduced fee (0 for free)
}

/// Sponsorship system configuration
/// Allows team members to sponsor external proposals by setting a fixed threshold
public struct SponsorshipConfig has copy, drop, store {
    enabled: bool, // If true, sponsorship system is active
    sponsored_threshold: SignedU128, // Fixed threshold for sponsored proposals (must be ≤ 0, e.g., 0 or -2%)
    waive_advancement_fees: bool, // Does sponsorship also waive advancement fees?
    default_sponsor_quota_amount: u64, // Default sponsorships per period
}

/// Complete DAO configuration
public struct DaoConfig has copy, drop, store {
    trading_params: TradingParams,
    twap_config: TwapConfig,
    governance_config: GovernanceConfig,
    metadata_config: MetadataConfig,
    security_config: SecurityConfig,
    storage_config: StorageConfig,
    conditional_coin_config: ConditionalCoinConfig,
    quota_config: QuotaConfig,
    sponsorship_config: SponsorshipConfig,
}

// === Constructor Functions ===

/// Create a new trading parameters configuration
public fun new_trading_params(
    min_asset_amount: u64,
    min_stable_amount: u64,
    review_period_ms: u64,
    trading_period_ms: u64,
    conditional_amm_fee_bps: u64,
    spot_amm_fee_bps: u64,
    market_op_review_period_ms: u64,
    max_amm_swap_percent_bps: u64,
    conditional_liquidity_ratio_percent: u64,
): TradingParams {
    // Validate inputs
    assert!(min_asset_amount > 0, EInvalidMinAmount);
    assert!(min_stable_amount > 0, EInvalidMinAmount);
    assert!(min_asset_amount >= PROTOCOL_MIN_LIQUIDITY_AMOUNT, EMinAmountTooLow);
    assert!(min_stable_amount >= PROTOCOL_MIN_LIQUIDITY_AMOUNT, EMinAmountTooLow);
    assert!(review_period_ms >= constants::min_review_period_ms(), EInvalidPeriod);
    assert!(trading_period_ms >= constants::min_trading_period_ms(), EInvalidPeriod);
    assert!(conditional_amm_fee_bps <= constants::max_amm_fee_bps(), EInvalidFee);
    assert!(spot_amm_fee_bps <= constants::max_amm_fee_bps(), EInvalidFee);

    // Market op review period can be 0 for immediate trading
    // Should not exceed regular review period (market ops are meant to be faster or equal)
    assert!(market_op_review_period_ms <= review_period_ms, EInvalidPeriod);

    // Max swap percent must be reasonable (0-100%)
    assert!(max_amm_swap_percent_bps <= constants::max_fee_bps(), EInvalidFee);

    // Conditional liquidity ratio must be within valid range (base 100: 1-99%)
    // Ensures both spot and conditional pools always have liquidity
    assert!(
        conditional_liquidity_ratio_percent >= constants::min_conditional_liquidity_percent() &&
        conditional_liquidity_ratio_percent <= constants::max_conditional_liquidity_percent(),
        EInvalidFee,
    );

    TradingParams {
        min_asset_amount,
        min_stable_amount,
        review_period_ms,
        trading_period_ms,
        conditional_amm_fee_bps,
        spot_amm_fee_bps,
        market_op_review_period_ms,
        max_amm_swap_percent_bps,
        conditional_liquidity_ratio_percent,
    }
}

/// Create a new TWAP configuration
public fun new_twap_config(
    start_delay: u64,
    step_max: u64,
    initial_observation: u128,
    threshold: SignedU128,
): TwapConfig {
    // Validate inputs - start_delay can be 0 for immediate TWAP start
    // This is a valid use case for certain market configurations
    assert!(step_max > 0, EInvalidTwapParams);
    assert!(initial_observation > 0, EInvalidTwapParams);

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
    fee_escalation_basis_points: u64,
    proposal_creation_enabled: bool,
    accept_new_proposals: bool,
    max_intents_per_outcome: u64,
    eviction_grace_period_ms: u64,
    proposal_intent_expiry_ms: u64,
    enable_premarket_reservation_lock: bool,
): GovernanceConfig {
    // Validate inputs
    assert!(max_outcomes >= constants::min_outcomes(), EInvalidMaxOutcomes);
    assert!(max_outcomes <= constants::protocol_max_outcomes(), EMaxOutcomesExceedsProtocol);
    assert!(
        max_actions_per_outcome > 0 && max_actions_per_outcome <= constants::protocol_max_actions_per_outcome(),
        EMaxActionsExceedsProtocol,
    );
    assert!(proposal_fee_per_outcome > 0, EInvalidProposalFee);
    assert!(required_bond_amount > 0, EInvalidBondAmount);
    assert!(fee_escalation_basis_points <= constants::max_fee_bps(), EInvalidFee);
    assert!(max_intents_per_outcome > 0, EInvalidMaxOutcomes);
    assert!(
        eviction_grace_period_ms >= constants::min_eviction_grace_period_ms(),
        EInvalidGracePeriod,
    );

    GovernanceConfig {
        max_outcomes,
        max_actions_per_outcome,
        proposal_fee_per_outcome,
        required_bond_amount,
        fee_escalation_basis_points,
        proposal_creation_enabled,
        accept_new_proposals,
        max_intents_per_outcome,
        eviction_grace_period_ms,
        proposal_intent_expiry_ms,
        enable_premarket_reservation_lock,
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

/// Create a new storage configuration
public fun new_storage_config(): StorageConfig {
    StorageConfig {}
}

/// Create conditional coin config
public fun new_conditional_coin_config(
    use_outcome_index: bool,
    conditional_metadata: Option<ConditionalMetadata>,
): ConditionalCoinConfig {
    ConditionalCoinConfig {
        use_outcome_index,
        conditional_metadata,
    }
}

/// Create new conditional metadata
public fun new_conditional_metadata(
    decimals: u8,
    coin_name_prefix: AsciiString,
    coin_icon_url: Url,
): ConditionalMetadata {
    ConditionalMetadata {
        decimals,
        coin_name_prefix,
        coin_icon_url,
    }
}

/// Getters for ConditionalMetadata fields
public fun conditional_metadata_decimals(meta: &ConditionalMetadata): u8 { meta.decimals }

public fun conditional_metadata_prefix(meta: &ConditionalMetadata): AsciiString {
    meta.coin_name_prefix
}

public fun conditional_metadata_icon(meta: &ConditionalMetadata): Url { meta.coin_icon_url }

/// Create a new quota configuration
public fun new_quota_config(
    enabled: bool,
    default_quota_amount: u64,
    default_quota_period_ms: u64,
    default_reduced_fee: u64,
): QuotaConfig {
    if (enabled) {
        assert!(default_quota_amount > 0, EInvalidQuotaParams);
        assert!(default_quota_period_ms > 0, EInvalidPeriod);
    };
    QuotaConfig {
        enabled,
        default_quota_amount,
        default_quota_period_ms,
        default_reduced_fee,
    }
}

/// Create a new sponsorship configuration
public fun new_sponsorship_config(
    enabled: bool,
    sponsored_threshold: SignedU128,
    waive_advancement_fees: bool,
    default_sponsor_quota_amount: u64,
): SponsorshipConfig {
    if (enabled) {
        assert!(default_sponsor_quota_amount > 0, EInvalidQuotaParams);

        // Protocol-level validation: sponsored_threshold must be ≤ 0 and magnitude ≤ 5%
        let magnitude = signed::magnitude(&sponsored_threshold);
        let is_negative = signed::is_negative(&sponsored_threshold);

        // Must be zero or negative
        assert!(is_negative || magnitude == 0, ESponsoredThresholdMustBeNonPositive);

        // If negative, magnitude must be ≤ 5%
        if (is_negative) {
            assert!(magnitude <= PROTOCOL_MAX_THRESHOLD_NEGATIVE, ESponsoredThresholdExceedsProtocolMax);
        };
    };

    SponsorshipConfig {
        enabled,
        sponsored_threshold,
        waive_advancement_fees,
        default_sponsor_quota_amount,
    }
}


/// Create a complete DAO configuration
public fun new_dao_config(
    trading_params: TradingParams,
    twap_config: TwapConfig,
    governance_config: GovernanceConfig,
    metadata_config: MetadataConfig,
    security_config: SecurityConfig,
    storage_config: StorageConfig,
    conditional_coin_config: ConditionalCoinConfig,
    quota_config: QuotaConfig,
    sponsorship_config: SponsorshipConfig,
): DaoConfig {
    DaoConfig {
        trading_params,
        twap_config,
        governance_config,
        metadata_config,
        security_config,
        storage_config,
        conditional_coin_config,
        quota_config,
        sponsorship_config,
    }
}

// === Getter Functions ===

// Trading params getters
public fun trading_params(config: &DaoConfig): &TradingParams { &config.trading_params }

public(package) fun trading_params_mut(config: &mut DaoConfig): &mut TradingParams {
    &mut config.trading_params
}

public fun min_asset_amount(params: &TradingParams): u64 { params.min_asset_amount }

public fun min_stable_amount(params: &TradingParams): u64 { params.min_stable_amount }

public fun review_period_ms(params: &TradingParams): u64 { params.review_period_ms }

public fun trading_period_ms(params: &TradingParams): u64 { params.trading_period_ms }

public fun conditional_amm_fee_bps(params: &TradingParams): u64 { params.conditional_amm_fee_bps }

public fun spot_amm_fee_bps(params: &TradingParams): u64 { params.spot_amm_fee_bps }

public fun market_op_review_period_ms(params: &TradingParams): u64 {
    params.market_op_review_period_ms
}

public fun max_amm_swap_percent_bps(params: &TradingParams): u64 { params.max_amm_swap_percent_bps }

public fun conditional_liquidity_ratio_percent(params: &TradingParams): u64 {
    params.conditional_liquidity_ratio_percent
}

// TWAP config getters
public fun twap_config(config: &DaoConfig): &TwapConfig { &config.twap_config }

public(package) fun twap_config_mut(config: &mut DaoConfig): &mut TwapConfig {
    &mut config.twap_config
}

public fun start_delay(twap: &TwapConfig): u64 { twap.start_delay }

public fun step_max(twap: &TwapConfig): u64 { twap.step_max }

public fun initial_observation(twap: &TwapConfig): u128 { twap.initial_observation }

public fun threshold(twap: &TwapConfig): &SignedU128 {
    &twap.threshold
}

// Governance config getters
public fun governance_config(config: &DaoConfig): &GovernanceConfig { &config.governance_config }

public(package) fun governance_config_mut(config: &mut DaoConfig): &mut GovernanceConfig {
    &mut config.governance_config
}

public fun max_outcomes(gov: &GovernanceConfig): u64 { gov.max_outcomes }

public fun max_actions_per_outcome(gov: &GovernanceConfig): u64 { gov.max_actions_per_outcome }

public fun proposal_fee_per_outcome(gov: &GovernanceConfig): u64 { gov.proposal_fee_per_outcome }

public fun required_bond_amount(gov: &GovernanceConfig): u64 { gov.required_bond_amount }

// REMOVED: proposal_recreation_window_ms and max_proposal_chain_depth (second-order proposals deleted)

public fun fee_escalation_basis_points(gov: &GovernanceConfig): u64 {
    gov.fee_escalation_basis_points
}

public fun proposal_creation_enabled(gov: &GovernanceConfig): bool { gov.proposal_creation_enabled }

public fun accept_new_proposals(gov: &GovernanceConfig): bool { gov.accept_new_proposals }

public fun max_intents_per_outcome(gov: &GovernanceConfig): u64 { gov.max_intents_per_outcome }

public fun eviction_grace_period_ms(gov: &GovernanceConfig): u64 { gov.eviction_grace_period_ms }

public fun proposal_intent_expiry_ms(gov: &GovernanceConfig): u64 { gov.proposal_intent_expiry_ms }

public fun enable_premarket_reservation_lock(gov: &GovernanceConfig): bool {
    gov.enable_premarket_reservation_lock
}

// Metadata config getters
public fun metadata_config(config: &DaoConfig): &MetadataConfig { &config.metadata_config }

public(package) fun metadata_config_mut(config: &mut DaoConfig): &mut MetadataConfig {
    &mut config.metadata_config
}

public fun dao_name(meta: &MetadataConfig): &AsciiString { &meta.dao_name }

public fun icon_url(meta: &MetadataConfig): &Url { &meta.icon_url }

public fun description(meta: &MetadataConfig): &String { &meta.description }

// Security config getters
public fun security_config(config: &DaoConfig): &SecurityConfig { &config.security_config }

public(package) fun security_config_mut(config: &mut DaoConfig): &mut SecurityConfig {
    &mut config.security_config
}

public fun deadman_enabled(sec: &SecurityConfig): bool { sec.deadman_enabled }

public fun recovery_liveness_ms(sec: &SecurityConfig): u64 { sec.recovery_liveness_ms }

public fun require_deadman_council(sec: &SecurityConfig): bool { sec.require_deadman_council }

// Storage config getters
public fun storage_config(config: &DaoConfig): &StorageConfig { &config.storage_config }

public fun storage_config_mut(config: &mut DaoConfig): &mut StorageConfig {
    &mut config.storage_config
}

// REMOVED: allow_walrus_blobs getter - Walrus functionality moved to v3_futarchy_legal

// Conditional coin config getters
public fun conditional_coin_config(config: &DaoConfig): &ConditionalCoinConfig {
    &config.conditional_coin_config
}

public(package) fun conditional_coin_config_mut(
    config: &mut DaoConfig,
): &mut ConditionalCoinConfig { &mut config.conditional_coin_config }

public fun use_outcome_index(coin_config: &ConditionalCoinConfig): bool {
    coin_config.use_outcome_index
}

public fun conditional_metadata(coin_config: &ConditionalCoinConfig): &Option<ConditionalMetadata> {
    &coin_config.conditional_metadata
}

/// Get the coin name prefix from conditional metadata (if available)
/// Returns None if no conditional metadata is set
public fun coin_name_prefix(coin_config: &ConditionalCoinConfig): Option<AsciiString> {
    if (coin_config.conditional_metadata.is_some()) {
        option::some(coin_config.conditional_metadata.borrow().coin_name_prefix)
    } else {
        option::none()
    }
}

// ConditionalMetadata getters
public fun conditional_decimals(meta: &ConditionalMetadata): u8 { meta.decimals }

public fun conditional_coin_name_prefix(meta: &ConditionalMetadata): &AsciiString {
    &meta.coin_name_prefix
}

public fun conditional_coin_icon_url(meta: &ConditionalMetadata): &Url { &meta.coin_icon_url }

/// Derive conditional token metadata from base token's CoinMetadata (PREFERRED)
/// Reads decimals, symbol, and icon from the base DAO token and derives conditional token metadata
/// Returns: (decimals, name_prefix, icon_url)
///
/// Example: Base token "MYDAO" → Conditional prefix "c_MYDAO_"
public fun derive_conditional_metadata_from_coin<CoinType>(
    metadata: &sui::coin::CoinMetadata<CoinType>,
): (u8, AsciiString, Url) {
    let decimals = metadata.get_decimals();
    let symbol = metadata.get_symbol();
    let icon = metadata.get_icon_url().extract().inner_url();

    // Derive conditional token prefix: c_SYMBOL_
    let prefix_bytes = b"c_";
    let symbol_bytes = symbol.into_bytes();
    let suffix_bytes = b"_";

    let mut combined = vector::empty<u8>();
    vector::append(&mut combined, prefix_bytes);
    vector::append(&mut combined, symbol_bytes);
    vector::append(&mut combined, suffix_bytes);

    (decimals, combined.to_ascii_string(), url::new_unsafe(icon))
}

/// Get conditional token metadata from hardcoded fallback config
/// Use only if CoinMetadata is unavailable/lost to prevent DAO from bricking
/// Returns: (decimals, name_prefix, icon_url)
/// Aborts if no fallback metadata is configured
public fun get_conditional_metadata_from_config(
    coin_config: &ConditionalCoinConfig,
): (u8, AsciiString, Url) {
    assert!(coin_config.conditional_metadata.is_some(), ENoConditionalMetadata);
    let meta = coin_config.conditional_metadata.borrow();
    (meta.decimals, *&meta.coin_name_prefix, *&meta.coin_icon_url)
}

// Quota config getters
public fun quota_config(config: &DaoConfig): &QuotaConfig { &config.quota_config }

public(package) fun quota_config_mut(config: &mut DaoConfig): &mut QuotaConfig {
    &mut config.quota_config
}

public fun quota_enabled(quota: &QuotaConfig): bool { quota.enabled }

public fun default_quota_amount(quota: &QuotaConfig): u64 { quota.default_quota_amount }

public fun default_quota_period_ms(quota: &QuotaConfig): u64 { quota.default_quota_period_ms }

public fun default_reduced_fee(quota: &QuotaConfig): u64 { quota.default_reduced_fee }

// Sponsorship config getters
public fun sponsorship_config(config: &DaoConfig): &SponsorshipConfig { &config.sponsorship_config }

public fun sponsorship_config_mut(config: &mut DaoConfig): &mut SponsorshipConfig {
    &mut config.sponsorship_config
}

public fun sponsorship_enabled(sponsorship: &SponsorshipConfig): bool { sponsorship.enabled }

public fun sponsored_threshold(sponsorship: &SponsorshipConfig): SignedU128 { sponsorship.sponsored_threshold }

public fun waive_advancement_fees(sponsorship: &SponsorshipConfig): bool { sponsorship.waive_advancement_fees }

public fun default_sponsor_quota_amount(sponsorship: &SponsorshipConfig): u64 { sponsorship.default_sponsor_quota_amount }

// === Update Functions ===

// === State Validation Functions ===

/// Check if a config update would cause state inconsistency
/// Returns true if the update is safe, false otherwise
public fun validate_config_update(
    current_config: &DaoConfig,
    new_config: &DaoConfig,
    active_proposals: u64,
): bool {
    let current_gov = governance_config(current_config);
    let new_gov = governance_config(new_config);

    // Check 1: Can't reduce max_outcomes below what existing proposals might have
    // This is a conservative check - in production you'd check actual proposals
    if (max_outcomes(new_gov) < max_outcomes(current_gov)) {
        if (active_proposals > 0) {
            return false // Unsafe to reduce when proposals are active
        }
    };

    // Check 3: Can't reduce max_actions_per_outcome if proposals are active
    if (max_actions_per_outcome(new_gov) < max_actions_per_outcome(current_gov)) {
        if (active_proposals > 0) {
            return false // Unsafe to reduce when proposals are active
        }
    };

    // Check 4: Grace periods can't be reduced to zero
    if (eviction_grace_period_ms(new_gov) == 0) {
        return false
    };

    // Check 5: Trading periods must be reasonable
    let new_trading = trading_params(new_config);
    if (review_period_ms(new_trading) == 0 || trading_period_ms(new_trading) == 0) {
        return false
    };

    true
}

// === Direct Field Setters (Package-level) ===
// These functions provide efficient in-place field updates without struct copying

// Trading params direct setters
public(package) fun set_min_asset_amount(params: &mut TradingParams, amount: u64) {
    assert!(amount > 0, EInvalidMinAmount);
    assert!(amount >= PROTOCOL_MIN_LIQUIDITY_AMOUNT, EMinAmountTooLow);
    params.min_asset_amount = amount;
}

public(package) fun set_min_stable_amount(params: &mut TradingParams, amount: u64) {
    assert!(amount > 0, EInvalidMinAmount);
    assert!(amount >= PROTOCOL_MIN_LIQUIDITY_AMOUNT, EMinAmountTooLow);
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

public(package) fun set_conditional_amm_fee_bps(params: &mut TradingParams, fee_bps: u64) {
    assert!(fee_bps <= constants::max_amm_fee_bps(), EInvalidFee);
    params.conditional_amm_fee_bps = fee_bps;
}

public(package) fun set_spot_amm_fee_bps(params: &mut TradingParams, fee_bps: u64) {
    assert!(fee_bps <= constants::max_amm_fee_bps(), EInvalidFee);
    params.spot_amm_fee_bps = fee_bps;
}

public(package) fun set_market_op_review_period_ms(params: &mut TradingParams, period: u64) {
    // Market op review can be 0 for immediate trading
    // But should not exceed regular review period
    assert!(period <= params.review_period_ms, EInvalidPeriod);
    params.market_op_review_period_ms = period;
}

public(package) fun set_max_amm_swap_percent_bps(params: &mut TradingParams, percent_bps: u64) {
    assert!(percent_bps <= constants::max_fee_bps(), EInvalidFee);
    params.max_amm_swap_percent_bps = percent_bps;
}

public(package) fun set_conditional_liquidity_ratio_percent(
    params: &mut TradingParams,
    ratio_percent: u64,
) {
    // Enforce valid range using configurable constants (base 100: 1-99%)
    assert!(
        ratio_percent >= constants::min_conditional_liquidity_percent() &&
        ratio_percent <= constants::max_conditional_liquidity_percent(),
        EInvalidFee,
    );
    params.conditional_liquidity_ratio_percent = ratio_percent;
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

public(package) fun set_threshold(twap: &mut TwapConfig, threshold: SignedU128) {
    twap.threshold = threshold;
}

// Governance config direct setters
public(package) fun set_max_outcomes(gov: &mut GovernanceConfig, max: u64) {
    assert!(max >= constants::min_outcomes(), EInvalidMaxOutcomes);
    assert!(max <= constants::protocol_max_outcomes(), EMaxOutcomesExceedsProtocol);
    // Note: Caller must ensure no active proposals exceed this limit
    gov.max_outcomes = max;
}

public(package) fun set_max_actions_per_outcome(gov: &mut GovernanceConfig, max: u64) {
    assert!(
        max > 0 && max <= constants::protocol_max_actions_per_outcome(),
        EMaxActionsExceedsProtocol,
    );
    // Note: Caller must ensure no active proposals exceed this limit
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

// REMOVED: Setters for proposal_recreation_window_ms and max_proposal_chain_depth

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

public(package) fun set_enable_premarket_reservation_lock(
    gov: &mut GovernanceConfig,
    enabled: bool,
) {
    gov.enable_premarket_reservation_lock = enabled;
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

// Storage config direct setters
// REMOVED: set_allow_walrus_blobs - Walrus functionality moved to v3_futarchy_legal

// Conditional coin config direct setters

public(package) fun set_conditional_metadata(
    coin_config: &mut ConditionalCoinConfig,
    metadata: Option<ConditionalMetadata>,
) {
    coin_config.conditional_metadata = metadata;
}

public(package) fun set_use_outcome_index(
    coin_config: &mut ConditionalCoinConfig,
    use_index: bool,
) {
    coin_config.use_outcome_index = use_index;
}

// Quota config direct setters

public(package) fun set_quota_enabled(quota: &mut QuotaConfig, enabled: bool) {
    quota.enabled = enabled;
}

public(package) fun set_default_quota_amount(quota: &mut QuotaConfig, amount: u64) {
    if (quota.enabled) {
        assert!(amount > 0, EInvalidQuotaParams);
    };
    quota.default_quota_amount = amount;
}

public(package) fun set_default_quota_period_ms(quota: &mut QuotaConfig, period: u64) {
    if (quota.enabled) {
        assert!(period > 0, EInvalidPeriod);
    };
    quota.default_quota_period_ms = period;
}

public(package) fun set_default_reduced_fee(quota: &mut QuotaConfig, fee: u64) {
    quota.default_reduced_fee = fee;
}

// Sponsorship config direct setters

public fun set_sponsorship_enabled(sponsorship: &mut SponsorshipConfig, enabled: bool) {
    sponsorship.enabled = enabled;
}

public fun set_sponsored_threshold(sponsorship: &mut SponsorshipConfig, threshold: SignedU128) {
    // Protocol-level validation: sponsored_threshold must be ≤ 0 and magnitude ≤ 5%
    let magnitude = signed::magnitude(&threshold);
    let is_negative = signed::is_negative(&threshold);

    // Must be zero or negative
    assert!(is_negative || magnitude == 0, ESponsoredThresholdMustBeNonPositive);

    // If negative, magnitude must be ≤ 5%
    if (is_negative) {
        assert!(magnitude <= PROTOCOL_MAX_THRESHOLD_NEGATIVE, ESponsoredThresholdExceedsProtocolMax);
    };

    sponsorship.sponsored_threshold = threshold;
}

public fun set_waive_advancement_fees(sponsorship: &mut SponsorshipConfig, waive: bool) {
    sponsorship.waive_advancement_fees = waive;
}

public fun set_default_sponsor_quota_amount(sponsorship: &mut SponsorshipConfig, amount: u64) {
    if (sponsorship.enabled) {
        assert!(amount > 0, EInvalidQuotaParams);
    };
    sponsorship.default_sponsor_quota_amount = amount;
}

// === String conversion wrapper functions ===

/// Set DAO name from String (converts to AsciiString)
public(package) fun set_dao_name_string(meta: &mut MetadataConfig, name: String) {
    meta.dao_name = string::to_ascii(name);
}

/// Set icon URL from String (creates Url from AsciiString)
public(package) fun set_icon_url_string(meta: &mut MetadataConfig, url_str: String) {
    let ascii_url = string::to_ascii(url_str);
    meta.icon_url = url::new_unsafe(ascii_url);
}

/// Update trading parameters (returns new config)
public fun update_trading_params(config: &DaoConfig, new_params: TradingParams): DaoConfig {
    DaoConfig {
        trading_params: new_params,
        twap_config: config.twap_config,
        governance_config: config.governance_config,
        metadata_config: config.metadata_config,
        security_config: config.security_config,
        storage_config: config.storage_config,
        conditional_coin_config: config.conditional_coin_config,
        quota_config: config.quota_config,
        sponsorship_config: config.sponsorship_config,
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
        storage_config: config.storage_config,
        conditional_coin_config: config.conditional_coin_config,
        quota_config: config.quota_config,
        sponsorship_config: config.sponsorship_config,
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
        storage_config: config.storage_config,
        conditional_coin_config: config.conditional_coin_config,
        quota_config: config.quota_config,
        sponsorship_config: config.sponsorship_config,
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
        storage_config: config.storage_config,
        conditional_coin_config: config.conditional_coin_config,
        quota_config: config.quota_config,
        sponsorship_config: config.sponsorship_config,
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
        storage_config: config.storage_config,
        conditional_coin_config: config.conditional_coin_config,
        quota_config: config.quota_config,
        sponsorship_config: config.sponsorship_config,
    }
}

/// Update storage configuration (returns new config)
public fun update_storage_config(config: &DaoConfig, new_storage: StorageConfig): DaoConfig {
    DaoConfig {
        trading_params: config.trading_params,
        twap_config: config.twap_config,
        governance_config: config.governance_config,
        metadata_config: config.metadata_config,
        security_config: config.security_config,
        storage_config: new_storage,
        conditional_coin_config: config.conditional_coin_config,
        quota_config: config.quota_config,
        sponsorship_config: config.sponsorship_config,
    }
}

/// Update conditional coin configuration (returns new config)
public fun update_conditional_coin_config(
    config: &DaoConfig,
    new_coin_config: ConditionalCoinConfig,
): DaoConfig {
    DaoConfig {
        trading_params: config.trading_params,
        twap_config: config.twap_config,
        governance_config: config.governance_config,
        metadata_config: config.metadata_config,
        security_config: config.security_config,
        storage_config: config.storage_config,
        conditional_coin_config: new_coin_config,
        quota_config: config.quota_config,
        sponsorship_config: config.sponsorship_config,
    }
}

/// Update quota configuration (returns new config)
public fun update_quota_config(config: &DaoConfig, new_quota: QuotaConfig): DaoConfig {
    DaoConfig {
        trading_params: config.trading_params,
        twap_config: config.twap_config,
        governance_config: config.governance_config,
        metadata_config: config.metadata_config,
        security_config: config.security_config,
        storage_config: config.storage_config,
        conditional_coin_config: config.conditional_coin_config,
        quota_config: new_quota,
        sponsorship_config: config.sponsorship_config,
    }
}

/// Update sponsorship configuration (returns new config)
public fun update_sponsorship_config(config: &DaoConfig, new_sponsorship: SponsorshipConfig): DaoConfig {
    DaoConfig {
        trading_params: config.trading_params,
        twap_config: config.twap_config,
        governance_config: config.governance_config,
        metadata_config: config.metadata_config,
        security_config: config.security_config,
        storage_config: config.storage_config,
        conditional_coin_config: config.conditional_coin_config,
        quota_config: config.quota_config,
        sponsorship_config: new_sponsorship,
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
        conditional_amm_fee_bps: 30, // 0.3% for conditional markets
        spot_amm_fee_bps: 30, // 0.3% for spot pool
        market_op_review_period_ms: 0, // 0 = immediate (allows atomic market init)
        max_amm_swap_percent_bps: 1000, // 10% max swap per proposal (prevents illiquidity)
        conditional_liquidity_ratio_percent: constants::default_conditional_liquidity_percent(), // 80% to conditional markets (base 100)
    }
}

/// Get default TWAP configuration for testing
public fun default_twap_config(): TwapConfig {
    TwapConfig {
        start_delay: 300000, // 5 minutes
        step_max: 300000, // 5 minutes
        initial_observation: 1000000000000, // Initial price observation
        threshold: signed::from_u64(10), // 10% threshold
    }
}

/// Get default governance configuration for testing
public fun default_governance_config(): GovernanceConfig {
    GovernanceConfig {
        max_outcomes: constants::default_max_outcomes(),
        max_actions_per_outcome: constants::default_max_actions_per_outcome(),
        proposal_fee_per_outcome: 1000000, // 1 token per outcome
        required_bond_amount: 10000000, // 10 tokens
        fee_escalation_basis_points: constants::default_fee_escalation_bps(),
        proposal_creation_enabled: true,
        accept_new_proposals: true,
        max_intents_per_outcome: 10, // Allow up to 10 intents per outcome
        eviction_grace_period_ms: constants::default_eviction_grace_period_ms(),
        proposal_intent_expiry_ms: constants::default_proposal_intent_expiry_ms(),
        enable_premarket_reservation_lock: true, // Default: true for MEV protection
    }
}

/// Get default security configuration
public fun default_security_config(): SecurityConfig {
    SecurityConfig {
        deadman_enabled: false, // Opt-in feature
        recovery_liveness_ms: 2_592_000_000, // 30 days default
        require_deadman_council: false, // Optional
    }
}

/// Get default storage configuration
public fun default_storage_config(): StorageConfig {
    StorageConfig {}
}

/// Get default conditional coin configuration (dynamic mode - derives from base token)
public fun default_conditional_coin_config(): ConditionalCoinConfig {
    ConditionalCoinConfig {
        use_outcome_index: true,
        conditional_metadata: option::none(), // Derive from base DAO token
    }
}

/// Get default quota configuration
public fun default_quota_config(): QuotaConfig {
    QuotaConfig {
        enabled: false, // Opt-in feature
        default_quota_amount: 1, // 1 proposal per period by default
        default_quota_period_ms: 2_592_000_000, // 30 days
        default_reduced_fee: 0, // Free by default
    }
}

/// Get default sponsorship configuration
public fun default_sponsorship_config(): SponsorshipConfig {
    SponsorshipConfig {
        enabled: false, // Opt-in feature
        sponsored_threshold: signed::from_u64(0), // Zero threshold by default
        waive_advancement_fees: false, // Don't waive fees by default
        default_sponsor_quota_amount: 1, // 1 sponsorship per period by default
    }
}

