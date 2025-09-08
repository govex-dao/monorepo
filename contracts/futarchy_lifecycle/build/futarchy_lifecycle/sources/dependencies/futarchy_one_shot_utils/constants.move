/// Centralized constants for the Futarchy protocol
/// This module contains all magic numbers and configuration constants
/// to ensure consistency across the codebase
module futarchy_one_shot_utils::constants;

// === AMM Fee Constants ===

/// Maximum fee in basis points (100%)
public fun max_fee_bps(): u64 { 10000 }

/// LP fee share in basis points (80% of fees go to LPs)
public fun lp_fee_share_bps(): u64 { 8000 }

/// Total fee basis points denominator (100%)
public fun total_fee_bps(): u64 { 10000 }

/// Default AMM total fee in basis points (0.3%)
public fun default_amm_total_fee_bps(): u64 { 30 }

// === Price Precision Constants ===

/// Basis points precision for price calculations (10^12)
/// We use high precision to prevent rounding to 0
public fun basis_points(): u64 { 1_000_000_000_000 }

/// Parts per million denominator for percentage calculations
public fun ppm_denominator(): u64 { 1_000_000 }

// === Time Constants ===

/// TWAP price cap window in milliseconds (60 seconds)
public fun twap_price_cap_window(): u64 { 60_000 }

/// One week in milliseconds
public fun one_week_ms(): u64 { 604_800_000 }

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

// === Validation Functions ===

/// Check if a fee is valid (not exceeding maximum)
public fun is_valid_fee(fee_bps: u64): bool {
    fee_bps <= max_fee_bps()
}

/// Check if a cap percentage is valid (not exceeding 100%)
public fun is_valid_cap_ppm(cap_ppm: u64): bool {
    cap_ppm <= ppm_denominator()
}