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
    vault_spend_delay_ms: u64,
    vault_deposit_delay_ms: u64,
    currency_mint_delay_ms: u64,
    currency_burn_delay_ms: u64,
) {
    type_policy_initializer::init_treasury_policies(
        registry,
        dao_id,
        treasury_council,
        vault_spend_delay_ms,
        vault_deposit_delay_ms,
        currency_mint_delay_ms,
        currency_burn_delay_ms
    )
}

/// Initialize default policies for governance actions
public fun init_governance_policies(
    registry: &mut PolicyRegistry,
    dao_id: ID,
    update_name_delay_ms: u64,
    metadata_update_delay_ms: u64,
    trading_params_delay_ms: u64,
    governance_update_delay_ms: u64,
    create_proposal_delay_ms: u64,
) {
    type_policy_initializer::init_governance_policies(
        registry,
        dao_id,
        update_name_delay_ms,
        metadata_update_delay_ms,
        trading_params_delay_ms,
        governance_update_delay_ms,
        create_proposal_delay_ms
    )
}

/// Initialize critical security policies
public fun init_security_policies(
    registry: &mut PolicyRegistry,
    dao_id: ID,
    security_council: ID,
    package_upgrade_delay_ms: u64,
    package_commit_delay_ms: u64,
    package_restrict_delay_ms: u64,
    dissolution_delay_ms: u64,
) {
    type_policy_initializer::init_security_policies(
        registry,
        dao_id,
        security_council,
        package_upgrade_delay_ms,
        package_commit_delay_ms,
        package_restrict_delay_ms,
        dissolution_delay_ms
    )
}

/// Initialize protocol admin policies
public fun init_protocol_admin_policies(
    registry: &mut PolicyRegistry,
    dao_id: ID,
    admin_council: ID,
    factory_paused_delay_ms: u64,
    dao_creation_fee_delay_ms: u64,
    proposal_fee_delay_ms: u64,
    monthly_dao_fee_delay_ms: u64,
) {
    type_policy_initializer::init_protocol_admin_policies(
        registry,
        dao_id,
        admin_council,
        factory_paused_delay_ms,
        dao_creation_fee_delay_ms,
        proposal_fee_delay_ms,
        monthly_dao_fee_delay_ms
    )
}

/// Initialize liquidity management policies
public fun init_liquidity_policies(
    registry: &mut PolicyRegistry,
    dao_id: ID,
    treasury_council: ID,
    create_pool_delay_ms: u64,
    add_liquidity_delay_ms: u64,
    remove_liquidity_delay_ms: u64,
) {
    type_policy_initializer::init_liquidity_policies(
        registry,
        dao_id,
        treasury_council,
        create_pool_delay_ms,
        add_liquidity_delay_ms,
        remove_liquidity_delay_ms
    )
}

/// Initialize all default policies for a new DAO
public fun init_all_default_policies(
    registry: &mut PolicyRegistry,
    dao_id: ID,
    treasury_council: ID,
    security_council: ID,
    admin_council: Option<ID>,
    // Treasury delays
    vault_spend_delay_ms: u64,
    vault_deposit_delay_ms: u64,
    currency_mint_delay_ms: u64,
    currency_burn_delay_ms: u64,
    // Governance delays
    update_name_delay_ms: u64,
    metadata_update_delay_ms: u64,
    trading_params_delay_ms: u64,
    governance_update_delay_ms: u64,
    create_proposal_delay_ms: u64,
    // Security delays
    package_upgrade_delay_ms: u64,
    package_commit_delay_ms: u64,
    package_restrict_delay_ms: u64,
    dissolution_delay_ms: u64,
    // Admin delays
    factory_paused_delay_ms: u64,
    dao_creation_fee_delay_ms: u64,
    proposal_fee_delay_ms: u64,
    monthly_dao_fee_delay_ms: u64,
    // Liquidity delays
    create_pool_delay_ms: u64,
    add_liquidity_delay_ms: u64,
    remove_liquidity_delay_ms: u64,
) {
    type_policy_initializer::init_all_default_policies(
        registry,
        dao_id,
        treasury_council,
        security_council,
        admin_council,
        vault_spend_delay_ms,
        vault_deposit_delay_ms,
        currency_mint_delay_ms,
        currency_burn_delay_ms,
        update_name_delay_ms,
        metadata_update_delay_ms,
        trading_params_delay_ms,
        governance_update_delay_ms,
        create_proposal_delay_ms,
        package_upgrade_delay_ms,
        package_commit_delay_ms,
        package_restrict_delay_ms,
        dissolution_delay_ms,
        factory_paused_delay_ms,
        dao_creation_fee_delay_ms,
        proposal_fee_delay_ms,
        monthly_dao_fee_delay_ms,
        create_pool_delay_ms,
        add_liquidity_delay_ms,
        remove_liquidity_delay_ms,
    )
}