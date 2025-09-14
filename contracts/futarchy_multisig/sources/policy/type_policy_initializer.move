/// Initialize type-based policies for a DAO
module futarchy_multisig::type_policy_initializer;

use std::option::{Self, Option};
use sui::object::ID;
use futarchy_multisig::policy_registry::{Self, PolicyRegistry};

// Import action types
use futarchy_core::action_types;
use account_extensions::framework_action_types;

// === Constants ===
// Note: These are functions, not constants, so we'll call them directly

/// Initialize default policies for treasury actions
public fun init_treasury_policies(
    registry: &mut PolicyRegistry,
    dao_id: ID,
    treasury_council: ID,
) {
    // Treasury spend requires council approval
    policy_registry::set_type_policy<framework_action_types::VaultSpend>(
        registry,
        dao_id,
        option::some(treasury_council),
        policy_registry::MODE_COUNCIL_ONLY()
    );
    
    // Treasury deposits are DAO-only
    policy_registry::set_type_policy<framework_action_types::VaultDeposit>(
        registry,
        dao_id,
        option::none(),
        policy_registry::MODE_DAO_ONLY()
    );
    
    // Currency operations require both DAO and council
    policy_registry::set_type_policy<framework_action_types::CurrencyMint>(
        registry,
        dao_id,
        option::some(treasury_council),
        policy_registry::MODE_DAO_AND_COUNCIL()
    );
    
    policy_registry::set_type_policy<framework_action_types::CurrencyBurn>(
        registry,
        dao_id,
        option::some(treasury_council),
        policy_registry::MODE_DAO_AND_COUNCIL()
    );
}

/// Initialize default policies for governance actions
public fun init_governance_policies(
    registry: &mut PolicyRegistry,
    dao_id: ID,
) {
    // Most governance changes are DAO-only
    policy_registry::set_type_policy<action_types::UpdateName>(
        registry,
        dao_id,
        option::none(),
        policy_registry::MODE_DAO_ONLY()
    );
    
    policy_registry::set_type_policy<action_types::MetadataUpdate>(
        registry,
        dao_id,
        option::none(),
        policy_registry::MODE_DAO_ONLY()
    );
    
    policy_registry::set_type_policy<action_types::TradingParamsUpdate>(
        registry,
        dao_id,
        option::none(),
        policy_registry::MODE_DAO_ONLY()
    );
    
    policy_registry::set_type_policy<action_types::GovernanceUpdate>(
        registry,
        dao_id,
        option::none(),
        policy_registry::MODE_DAO_ONLY()
    );
    
    // Proposal creation is DAO-only
    policy_registry::set_type_policy<action_types::CreateProposal>(
        registry,
        dao_id,
        option::none(),
        policy_registry::MODE_DAO_ONLY()
    );
}

/// Initialize critical security policies
public fun init_security_policies(
    registry: &mut PolicyRegistry,
    dao_id: ID,
    security_council: ID,
) {
    // NOTE: The DAO should decide through governance whether to allow
    // the security council to set policies on objects. This would be done by:
    // policy_registry::set_type_policy<action_types::SetObjectPolicy>(
    //     registry, option::some(security_council), policy_registry::MODE_DAO_OR_COUNCIL()
    // );
    
    // Package upgrades require both DAO and security council
    policy_registry::set_type_policy<framework_action_types::PackageUpgrade>(
        registry,
        dao_id,
        option::some(security_council),
        policy_registry::MODE_DAO_AND_COUNCIL()
    );
    
    policy_registry::set_type_policy<framework_action_types::PackageCommit>(
        registry,
        dao_id,
        option::some(security_council),
        policy_registry::MODE_DAO_AND_COUNCIL()
    );
    
    policy_registry::set_type_policy<framework_action_types::PackageRestrict>(
        registry,
        dao_id,
        option::some(security_council),
        policy_registry::MODE_DAO_AND_COUNCIL()
    );
    
    // Emergency dissolution requires both
    policy_registry::set_type_policy<action_types::InitiateDissolution>(
        registry,
        dao_id,
        option::some(security_council),
        policy_registry::MODE_DAO_AND_COUNCIL()
    );
}

/// Initialize protocol admin policies
public fun init_protocol_admin_policies(
    registry: &mut PolicyRegistry,
    dao_id: ID,
    admin_council: ID,
) {
    // Factory management requires admin council
    policy_registry::set_type_policy<action_types::SetFactoryPaused>(
        registry,
        dao_id,
        option::some(admin_council),
        policy_registry::MODE_DAO_AND_COUNCIL()
    );
    
    // Fee updates require both DAO and admin
    policy_registry::set_type_policy<action_types::UpdateDaoCreationFee>(
        registry,
        dao_id,
        option::some(admin_council),
        policy_registry::MODE_DAO_AND_COUNCIL()
    );
    
    policy_registry::set_type_policy<action_types::UpdateProposalFee>(
        registry,
        dao_id,
        option::some(admin_council),
        policy_registry::MODE_DAO_AND_COUNCIL()
    );
    
    policy_registry::set_type_policy<action_types::UpdateMonthlyDaoFee>(
        registry,
        dao_id,
        option::some(admin_council),
        policy_registry::MODE_DAO_AND_COUNCIL()
    );
}

/// Initialize liquidity management policies
public fun init_liquidity_policies(
    registry: &mut PolicyRegistry,
    dao_id: ID,
    treasury_council: ID,
) {
    // Pool creation requires treasury council
    policy_registry::set_type_policy<action_types::CreatePool>(
        registry,
        dao_id,
        option::some(treasury_council),
        policy_registry::MODE_COUNCIL_ONLY()
    );
    
    // Adding/removing liquidity requires treasury council
    policy_registry::set_type_policy<action_types::AddLiquidity>(
        registry,
        dao_id,
        option::some(treasury_council),
        policy_registry::MODE_COUNCIL_ONLY()
    );
    
    policy_registry::set_type_policy<action_types::RemoveLiquidity>(
        registry,
        dao_id,
        option::some(treasury_council),
        policy_registry::MODE_COUNCIL_ONLY()
    );
}

/// Initialize all default policies for a new DAO
public fun init_all_default_policies(
    registry: &mut PolicyRegistry,
    dao_id: ID,
    treasury_council: ID,
    security_council: ID,
    admin_council: Option<ID>,
) {
    init_treasury_policies(registry, dao_id, treasury_council);
    init_governance_policies(registry, dao_id);
    init_security_policies(registry, dao_id, security_council);
    
    if (option::is_some(&admin_council)) {
        init_protocol_admin_policies(registry, dao_id, *option::borrow(&admin_council));
    };
    
    init_liquidity_policies(registry, dao_id, treasury_council);
}