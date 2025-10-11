/// Protocol-level configuration for liquidity subsidy system
/// This module contains ONLY the config struct and basic operations
/// Execution logic (SubsidyEscrow, crank_subsidy) lives in futarchy_markets::subsidy_escrow
module futarchy_core::subsidy_config;

// === Constants ===
const EInvalidConfig: u64 = 0;

const DEFAULT_CRANK_STEPS: u64 = 100;
const DEFAULT_SUBSIDY_PER_OUTCOME_PER_CRANK: u64 = 100_000_000;  // 0.1 SUI per outcome per crank
const DEFAULT_KEEPER_FEE_PER_CRANK: u64 = 100_000_000;           // 0.1 SUI per crank (flat)
const MIN_CRANK_INTERVAL_MS: u64 = 300_000;                      // 5 minutes minimum between cranks

// === Struct ===

/// Protocol-level configuration for liquidity subsidy system
/// Stored in DaoConfig
public struct ProtocolSubsidyConfig has store, copy, drop {
    enabled: bool,                              // If true, subsidies are enabled
    subsidy_per_outcome_per_crank: u64,         // SUI amount per outcome per crank
    crank_steps: u64,                           // Total cranks allowed (default: 100)
    keeper_fee_per_crank: u64,                  // Flat SUI fee per crank (default: 0.1 SUI)
    min_crank_interval_ms: u64,                 // Minimum time between cranks
}

// === Constructor Functions ===

/// Create default protocol subsidy config (enabled with sensible defaults)
public fun new_protocol_config(): ProtocolSubsidyConfig {
    ProtocolSubsidyConfig {
        enabled: true,
        subsidy_per_outcome_per_crank: DEFAULT_SUBSIDY_PER_OUTCOME_PER_CRANK,
        crank_steps: DEFAULT_CRANK_STEPS,
        keeper_fee_per_crank: DEFAULT_KEEPER_FEE_PER_CRANK,
        min_crank_interval_ms: MIN_CRANK_INTERVAL_MS,
    }
}

/// Create custom protocol subsidy config
public fun new_protocol_config_custom(
    enabled: bool,
    subsidy_per_outcome_per_crank: u64,
    crank_steps: u64,
    keeper_fee_per_crank: u64,
    min_crank_interval_ms: u64,
): ProtocolSubsidyConfig {
    assert!(crank_steps > 0, EInvalidConfig);

    ProtocolSubsidyConfig {
        enabled,
        subsidy_per_outcome_per_crank,
        crank_steps,
        keeper_fee_per_crank,
        min_crank_interval_ms,
    }
}

// === Calculation Functions ===

/// Calculate total subsidy needed for a proposal
/// Formula: subsidy_per_outcome_per_crank × outcome_count × crank_steps
public fun calculate_total_subsidy(
    config: &ProtocolSubsidyConfig,
    outcome_count: u64,
): u64 {
    config.subsidy_per_outcome_per_crank * outcome_count * config.crank_steps
}

// === Getters ===

public fun protocol_enabled(config: &ProtocolSubsidyConfig): bool { config.enabled }
public fun subsidy_per_outcome_per_crank(config: &ProtocolSubsidyConfig): u64 { config.subsidy_per_outcome_per_crank }
public fun crank_steps(config: &ProtocolSubsidyConfig): u64 { config.crank_steps }
public fun keeper_fee_per_crank(config: &ProtocolSubsidyConfig): u64 { config.keeper_fee_per_crank }
public fun min_crank_interval_ms(config: &ProtocolSubsidyConfig): u64 { config.min_crank_interval_ms }

// === Setters ===

public fun set_enabled(config: &mut ProtocolSubsidyConfig, enabled: bool) {
    config.enabled = enabled;
}

public fun set_subsidy_per_outcome_per_crank(config: &mut ProtocolSubsidyConfig, amount: u64) {
    config.subsidy_per_outcome_per_crank = amount;
}

public fun set_crank_steps(config: &mut ProtocolSubsidyConfig, steps: u64) {
    assert!(steps > 0, EInvalidConfig);
    config.crank_steps = steps;
}

public fun set_keeper_fee_per_crank(config: &mut ProtocolSubsidyConfig, fee: u64) {
    config.keeper_fee_per_crank = fee;
}

public fun set_min_crank_interval_ms(config: &mut ProtocolSubsidyConfig, interval: u64) {
    config.min_crank_interval_ms = interval;
}
