/// Common witness types for intents
/// This module provides reusable witness types for various intent operations
module futarchy::intent_witnesses;

// === Witness Types ===

/// Witness for governance-related intents
public struct GovernanceWitness has copy, drop {}

/// Witness for treasury operations
public struct TreasuryWitness has copy, drop {}

/// Witness for config changes
public struct ConfigWitness has copy, drop {}

/// Witness for liquidity operations
public struct LiquidityWitness has copy, drop {}

/// Witness for dissolution operations
public struct DissolutionWitness has copy, drop {}

/// Generic witness for proposals
public struct ProposalWitness has copy, drop {}

// === Constructor Functions ===

/// Create a governance witness
public fun governance(): GovernanceWitness {
    GovernanceWitness {}
}

/// Create a treasury witness
public fun treasury(): TreasuryWitness {
    TreasuryWitness {}
}

/// Create a config witness
public fun config(): ConfigWitness {
    ConfigWitness {}
}

/// Create a liquidity witness
public fun liquidity(): LiquidityWitness {
    LiquidityWitness {}
}

/// Create a dissolution witness
public fun dissolution(): DissolutionWitness {
    DissolutionWitness {}
}

/// Create a proposal witness
public fun proposal(): ProposalWitness {
    ProposalWitness {}
}