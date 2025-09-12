/// Initialize all default policies for a DAO
/// This module re-exports type-based policy initialization functions
module futarchy_multisig::policy_initializer;

use std::option::Option;
use sui::object::ID;
use futarchy_multisig::policy_registry::PolicyRegistry;
use futarchy_multisig::type_policy_initializer;

// === Re-export Functions ===

/// Initialize default policies for treasury actions
public fun init_treasury_policies(
    registry: &mut PolicyRegistry,
    dao_id: ID,
    treasury_council: ID,
) {
    type_policy_initializer::init_treasury_policies(registry, dao_id, treasury_council)
}

/// Initialize default policies for governance actions
public fun init_governance_policies(
    registry: &mut PolicyRegistry,
    dao_id: ID,
) {
    type_policy_initializer::init_governance_policies(registry, dao_id)
}

/// Initialize critical security policies
public fun init_security_policies(
    registry: &mut PolicyRegistry,
    dao_id: ID,
    security_council: ID,
) {
    type_policy_initializer::init_security_policies(registry, dao_id, security_council)
}

/// Initialize protocol admin policies
public fun init_protocol_admin_policies(
    registry: &mut PolicyRegistry,
    dao_id: ID,
    admin_council: ID,
) {
    type_policy_initializer::init_protocol_admin_policies(registry, dao_id, admin_council)
}

/// Initialize liquidity management policies
public fun init_liquidity_policies(
    registry: &mut PolicyRegistry,
    dao_id: ID,
    treasury_council: ID,
) {
    type_policy_initializer::init_liquidity_policies(registry, dao_id, treasury_council)
}

/// Initialize all default policies for a new DAO
public fun init_all_default_policies(
    registry: &mut PolicyRegistry,
    dao_id: ID,
    treasury_council: ID,
    security_council: ID,
    admin_council: Option<ID>,
) {
    type_policy_initializer::init_all_default_policies(
        registry,
        dao_id,
        treasury_council,
        security_council,
        admin_council
    )
}