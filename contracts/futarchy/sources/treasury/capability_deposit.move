/// Handles permissionless deposits of TreasuryCap after proposal approval
module futarchy::capability_deposit;

// === Imports ===
use sui::{
    coin::TreasuryCap,
    clock::Clock,
};
use futarchy::{
    treasury_actions::{Self, ActionRegistry},
    capability_manager::{Self, CapabilityManager},
};

// === Errors ===
const EProposalNotExecuted: u64 = 0;
const EInvalidOutcome: u64 = 1;

// === Public Functions ===

/// Permissionless deposit of TreasuryCap after a proposal approves it
/// Anyone can call this if the proposal passed and contains a capability deposit action
public entry fun deposit_treasury_cap<T: drop>(
    manager: &mut CapabilityManager,
    registry: &ActionRegistry,
    proposal_id: ID,
    outcome: u64,
    cap: TreasuryCap<T>,
    max_supply: Option<u64>,
    max_mint_per_proposal: Option<u64>,
    mint_cooldown_ms: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Verify the proposal has executed
    assert!(
        treasury_actions::is_executed(registry, proposal_id, outcome),
        EProposalNotExecuted
    );
    
    // Create rules based on parameters
    let rules = capability_manager::new_mint_burn_rules(
        max_supply,
        true, // can_mint
        true, // can_burn
        max_mint_per_proposal,
        mint_cooldown_ms
    );
    
    // Deposit the capability
    capability_manager::deposit_capability(manager, cap, rules, clock, ctx);
}

/// Simple version with default rules
public entry fun deposit_treasury_cap_simple<T: drop>(
    manager: &mut CapabilityManager,
    registry: &ActionRegistry,
    proposal_id: ID,
    outcome: u64,
    cap: TreasuryCap<T>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    deposit_treasury_cap(
        manager,
        registry,
        proposal_id,
        outcome,
        cap,
        option::none(), // max_supply
        option::none(), // max_mint_per_proposal
        0, // mint_cooldown_ms
        clock,
        ctx
    );
}