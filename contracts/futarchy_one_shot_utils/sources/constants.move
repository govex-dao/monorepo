/// Centralized constants for the Futarchy protocol
/// This module contains all magic numbers and configuration constants
/// to ensure consistency across the codebase
module futarchy_one_shot_utils::constants;

// === AMM Fee Constants ===

/// Maximum fee in basis points (100%) - for calculations only
public fun max_fee_bps(): u64 { 10000 }

/// Maximum AMM fee in basis points (5%) - hard cap for all AMM fees
public fun max_amm_fee_bps(): u64 { 500 }

/// LP fee share in basis points for CONDITIONAL AMMs (80% of fees go to LPs)
public fun conditional_lp_fee_share_bps(): u64 { 8000 }

/// Protocol fee share in basis points for CONDITIONAL AMMs (20% of fees go to protocol)
public fun conditional_protocol_fee_share_bps(): u64 { 2000 }

/// LP fee share in basis points for SPOT AMM (90% of fees go to LPs)
public fun spot_lp_fee_share_bps(): u64 { 9000 }

/// Protocol fee share in basis points for SPOT AMM (10% of fees go to protocol)
public fun spot_protocol_fee_share_bps(): u64 { 1000 }

/// Total fee basis points denominator (100%)
public fun total_fee_bps(): u64 { 10000 }

/// Default AMM total fee in basis points (0.3%)
public fun default_amm_total_fee_bps(): u64 { 30 }

// === Price Precision Constants ===

/// Price scale for AMM calculations (10^12)
/// Used for high-precision reserve ratio calculations
public fun price_scale(): u128 { 1_000_000_000_000 }

/// Basis points precision for price calculations (10^12)
/// We use high precision to prevent rounding to 0
public fun basis_points(): u64 { 1_000_000_000_000 }

/// Price multiplier scale (10^9)
/// Used for relative price calculations (e.g., 2_000_000_000 = 2.0x)
/// Matches AMM spot price precision
public fun price_multiplier_scale(): u64 { 1_000_000_000 }

/// Parts per million denominator for percentage calculations
public fun ppm_denominator(): u64 { 1_000_000 }

// === Time Constants ===

/// TWAP price cap window in milliseconds (60 seconds)
public fun twap_price_cap_window(): u64 { 60_000 }

/// One week in milliseconds
public fun one_week_ms(): u64 { 604_800_000 }

/// Seal reveal grace period (7 days in milliseconds)
/// Time after launchpad deadline to decrypt Seal-encrypted max raise
public fun seal_reveal_grace_period_ms(): u64 { 604_800_000 }

/// Default permit expiry time (5 minutes)
public fun default_permit_expiry_ms(): u64 { 5 * 60_000 }

// === Governance Constants ===

/// Maximum concurrent proposals allowed in the queue
public fun max_concurrent_proposals(): u64 { 100 }

/// Maximum queue size for proposals
public fun max_queue_size(): u64 { 100 }

/// Grace period for proposal eviction
public fun proposal_grace_period_ms(): u64 { 24 * 60 * 60_000 } // 24 hours

/// Protocol-level maximum outcomes per proposal
public fun protocol_max_outcomes(): u64 { 100 }

/// Protocol-level maximum actions per proposal (across all outcomes)
public fun protocol_max_actions(): u64 { 50 }

/// Protocol-level maximum actions per single outcome
public fun protocol_max_actions_per_outcome(): u64 { 20 }

/// Default maximum outcomes per proposal for DAOs
public fun default_max_outcomes(): u64 { 10 }

/// Default maximum actions per proposal for DAOs (across all outcomes)
public fun default_max_actions_per_proposal(): u64 { 10 }

/// Default maximum actions per outcome for DAOs
public fun default_max_actions_per_outcome(): u64 { 5 }

/// Minimum number of outcomes for any proposal
public fun min_outcomes(): u64 { 2 }

/// Minimum review period in milliseconds
public fun min_review_period_ms(): u64 { 1000 } // 1 second for testing

/// Minimum trading period in milliseconds  
public fun min_trading_period_ms(): u64 { 1000 } // 1 second for testing

/// Minimum grace period for eviction in milliseconds
public fun min_eviction_grace_period_ms(): u64 { 300000 } // 5 minutes

/// Minimum proposal intent expiry in milliseconds
public fun min_proposal_intent_expiry_ms(): u64 { 3600000 } // 1 hour

/// Default optimistic challenge fee (1 billion MIST = 1 token)
public fun default_optimistic_challenge_fee(): u64 { 1_000_000_000 }

/// Default optimistic challenge period in milliseconds (10 days)
public fun default_optimistic_challenge_period_ms(): u64 { 864_000_000 }

/// Default eviction grace period in milliseconds (2 hours)
public fun default_eviction_grace_period_ms(): u64 { 7_200_000 }

/// Default proposal intent expiry in milliseconds (30 days)
public fun default_proposal_intent_expiry_ms(): u64 { 2_592_000_000 }

/// Default proposal recreation window in milliseconds (24 hours)
public fun default_proposal_recreation_window_ms(): u64 { 86_400_000 }

/// Default max proposal chain depth
public fun default_max_proposal_chain_depth(): u64 { 3 }

/// Default fee escalation basis points (5%)
public fun default_fee_escalation_bps(): u64 { 500 }

// === Cleanup Constants ===

/// Maximum intents that can be cleaned in one call
public fun max_cleanup_per_call(): u64 { 20 }

/// Maximum pending withdrawals per payment stream
public fun max_pending_withdrawals(): u64 { 10 }

// === Market Constants ===

/// Number of outcomes for binary markets
public fun binary_outcomes(): u64 { 2 }

/// Token type constants
public fun token_type_asset(): u8 { 0 }
public fun token_type_stable(): u8 { 1 }
public fun token_type_lp(): u8 { 2 }

// === Document Registry Constants ===

/// Maximum chunks per document (limited by per-tx dynamic field access)
public fun max_chunks_per_document(): u64 { 1000 }

/// Maximum documents per DAO (soft limit for reasonable DAOs)
public fun max_documents_per_dao(): u64 { 1000 }

/// Maximum traversal limit for document queries (pagination)
public fun max_traversal_limit(): u64 { 1000 }

// === Treasury & Payment Constants ===
//
// UPGRADABLE LIMITS PATTERN:
// These constants are referenced by move-framework modules (vault, vesting, stream_utils)
// but defined here for centralized upgradability.
//
// To change these limits system-wide:
// 1. Update the values below
// 2. Deploy new version of futarchy_one_shot_utils
// 3. Redeploy dependent packages (they'll pick up new limits)
//
// This enables DAOs to adjust limits via package upgrade proposals
// without modifying the core framework code.

/// Maximum beneficiaries per stream/vesting
/// Used by vault streams and vesting to limit multi-beneficiary coordination
/// Current: 100 (reasonable for most DAO coordination scenarios)
/// To increase: Update here and redeploy. Consider gas costs for large beneficiary lists.
public fun max_beneficiaries(): u64 { 100 }

// === Launchpad Constants ===

/// The duration for every launchpad raise (4 days in milliseconds)
public fun launchpad_duration_ms(): u64 { 345_600_000 }

/// Claim period after successful raise before creator can sweep dust (14 days)
public fun launchpad_claim_period_ms(): u64 { 1_209_600_000 }

/// Minimum SUI fee per contribution (0.1 SUI) to prevent spam and fund settlement cranking
public fun launchpad_crank_fee_per_contribution(): u64 { 100_000_000 }

/// Reward per cap processed during settlement cranking (0.05 SUI)
public fun launchpad_reward_per_cap_processed(): u64 { 50_000_000 }

/// Maximum number of unique cap values to prevent unbounded heap
/// Limits settlement gas costs (100 caps × 0.05 SUI = 5 SUI max)
public fun launchpad_max_unique_caps(): u64 { 100 }

/// Maximum number of init actions during DAO creation
public fun launchpad_max_init_actions(): u64 { 20 }

/// Estimated max gas per init action
public fun launchpad_max_gas_per_action(): u64 { 1_000_000 }

// === Validation Functions ===

/// Check if a fee is valid (not exceeding maximum)
public fun is_valid_fee(fee_bps: u64): bool {
    fee_bps <= max_fee_bps()
}

/// Check if a cap percentage is valid (not exceeding 100%)
public fun is_valid_cap_ppm(cap_ppm: u64): bool {
    cap_ppm <= ppm_denominator()
}