/// Initialize all default policies for a DAO
/// This module provides helper functions to set policies for all actions at once
module futarchy_multisig::policy_initializer;

use std::option::{Self, Option};
use std::vector;
use sui::object::ID;
use futarchy_multisig::policy_registry::{Self, PolicyRegistry};
use futarchy_multisig::action_resource_mapping;

// === Structs ===

/// Configuration for initializing policies
public struct PolicyConfig has drop {
    treasury_council_id: Option<ID>,
    technical_council_id: Option<ID>,
    legal_council_id: Option<ID>,
    emergency_council_id: Option<ID>,
}

// === Public Functions ===

/// Create a new policy configuration
public fun new_config(
    treasury_council_id: Option<ID>,
    technical_council_id: Option<ID>,
    legal_council_id: Option<ID>,
    emergency_council_id: Option<ID>,
): PolicyConfig {
    PolicyConfig {
        treasury_council_id,
        technical_council_id,
        legal_council_id,
        emergency_council_id,
    }
}

/// Initialize conservative policies (most actions require DAO + Council)
public fun init_conservative_policies(
    registry: &mut PolicyRegistry,
    config: PolicyConfig,
) {
    // Treasury actions - require DAO + Treasury Council
    if (option::is_some(&config.treasury_council_id)) {
        let patterns = action_resource_mapping::treasury_patterns();
        let mut i = 0;
        while (i < vector::length(&patterns)) {
            policy_registry::set_pattern_policy(
                registry,
                *vector::borrow(&patterns, i),
                config.treasury_council_id,
                policy_registry::MODE_DAO_AND_COUNCIL()
            );
            i = i + 1;
        };
    };
    
    // Technical actions - require DAO + Technical Council
    if (option::is_some(&config.technical_council_id)) {
        let patterns = action_resource_mapping::technical_patterns();
        let mut i = 0;
        while (i < vector::length(&patterns)) {
            policy_registry::set_pattern_policy(
                registry,
                *vector::borrow(&patterns, i),
                config.technical_council_id,
                policy_registry::MODE_DAO_AND_COUNCIL()
            );
            i = i + 1;
        };
    };
    
    // Legal actions - Legal Council only (no DAO vote needed)
    if (option::is_some(&config.legal_council_id)) {
        let patterns = action_resource_mapping::legal_patterns();
        let mut i = 0;
        while (i < vector::length(&patterns)) {
            policy_registry::set_pattern_policy(
                registry,
                *vector::borrow(&patterns, i),
                config.legal_council_id,
                policy_registry::MODE_COUNCIL_ONLY()
            );
            i = i + 1;
        };
    };
    
    // Emergency actions - Emergency Council only
    if (option::is_some(&config.emergency_council_id)) {
        policy_registry::set_pattern_policy(
            registry,
            b"security/emergency_pause",
            config.emergency_council_id,
            policy_registry::MODE_COUNCIL_ONLY()
        );
    };
}

/// Initialize moderate policies (some actions allow DAO OR Council)
public fun init_moderate_policies(
    registry: &mut PolicyRegistry,
    config: PolicyConfig,
) {
    // Treasury spending - DAO OR Treasury Council
    if (option::is_some(&config.treasury_council_id)) {
        policy_registry::set_pattern_policy(
            registry,
            b"treasury/spend",
            config.treasury_council_id,
            policy_registry::MODE_DAO_OR_COUNCIL()
        );
        // But minting still requires both
        policy_registry::set_pattern_policy(
            registry,
            b"treasury/mint",
            config.treasury_council_id,
            policy_registry::MODE_DAO_AND_COUNCIL()
        );
    };
    
    // Technical actions - DAO OR Technical Council
    if (option::is_some(&config.technical_council_id)) {
        policy_registry::set_pattern_policy(
            registry,
            b"liquidity/update_parameters",
            config.technical_council_id,
            policy_registry::MODE_DAO_OR_COUNCIL()
        );
        // But upgrades still require both
        policy_registry::set_pattern_policy(
            registry,
            b"upgrade/package",
            config.technical_council_id,
            policy_registry::MODE_DAO_AND_COUNCIL()
        );
    };
}

/// Initialize minimal policies (most actions require only DAO)
public fun init_minimal_policies(
    registry: &mut PolicyRegistry,
    config: PolicyConfig,
) {
    // Only critical actions require councils
    
    // Package upgrades - require DAO + Technical Council
    if (option::is_some(&config.technical_council_id)) {
        policy_registry::set_pattern_policy(
            registry,
            b"upgrade/package",
            config.technical_council_id,
            policy_registry::MODE_DAO_AND_COUNCIL()
        );
    };
    
    // Minting - require DAO + Treasury Council
    if (option::is_some(&config.treasury_council_id)) {
        policy_registry::set_pattern_policy(
            registry,
            b"treasury/mint",
            config.treasury_council_id,
            policy_registry::MODE_DAO_AND_COUNCIL()
        );
    };
    
    // Emergency only
    if (option::is_some(&config.emergency_council_id)) {
        policy_registry::set_pattern_policy(
            registry,
            b"security/emergency_pause",
            config.emergency_council_id,
            policy_registry::MODE_COUNCIL_ONLY()
        );
    };
    
    // Everything else is DAO only (default)
}

/// Set all patterns to a specific mode and council
/// Useful for testing or specific governance models
public fun set_all_patterns(
    registry: &mut PolicyRegistry,
    council_id: Option<ID>,
    mode: u8,
) {
    let patterns = action_resource_mapping::all_patterns();
    let mut i = 0;
    while (i < vector::length(&patterns)) {
        policy_registry::set_pattern_policy(
            registry,
            *vector::borrow(&patterns, i),
            council_id,
            mode
        );
        i = i + 1;
    };
}

/// Set critical patterns to require additional approval
public fun set_critical_patterns(
    registry: &mut PolicyRegistry,
    council_id: Option<ID>,
) {
    let patterns = action_resource_mapping::critical_patterns();
    let mut i = 0;
    while (i < vector::length(&patterns)) {
        policy_registry::set_pattern_policy(
            registry,
            *vector::borrow(&patterns, i),
            council_id,
            policy_registry::MODE_DAO_AND_COUNCIL()
        );
        i = i + 1;
    };
}

/// Clear all policies (set everything to DAO_ONLY)
public fun clear_all_policies(registry: &mut PolicyRegistry) {
    set_all_patterns(registry, option::none(), policy_registry::MODE_DAO_ONLY());
}