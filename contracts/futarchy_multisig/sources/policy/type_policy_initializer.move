// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

/// Initialize type-based policies for a DAO
module futarchy_multisig::type_policy_initializer;

use account_extensions::framework_action_types;
use futarchy_core::action_type_markers;
use futarchy_multisig::policy_registry::{Self, PolicyRegistry};
use std::option::{Self, Option};
use sui::object::ID;

// === Constants ===
// Note: These are functions, not constants, so we'll call them directly

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
    // Treasury spend requires council approval
    // Changing this policy requires DAO approval
    policy_registry::set_type_policy<framework_action_types::VaultSpend>(
        registry,
        dao_id,
        option::some(treasury_council),
        policy_registry::MODE_COUNCIL_ONLY(),
        option::none(), // DAO controls policy changes
        policy_registry::MODE_DAO_ONLY(),
        vault_spend_delay_ms,
    );

    // Treasury deposits are DAO-only
    policy_registry::set_type_policy<framework_action_types::VaultDeposit>(
        registry,
        dao_id,
        option::none(),
        policy_registry::MODE_DAO_ONLY(),
        option::none(),
        policy_registry::MODE_DAO_ONLY(),
        vault_deposit_delay_ms,
    );

    // Currency operations require both DAO and council
    policy_registry::set_type_policy<framework_action_types::CurrencyMint>(
        registry,
        dao_id,
        option::some(treasury_council),
        policy_registry::MODE_DAO_AND_COUNCIL(),
        option::none(),
        policy_registry::MODE_DAO_ONLY(),
        currency_mint_delay_ms,
    );

    policy_registry::set_type_policy<framework_action_types::CurrencyBurn>(
        registry,
        dao_id,
        option::some(treasury_council),
        policy_registry::MODE_DAO_AND_COUNCIL(),
        option::none(),
        policy_registry::MODE_DAO_ONLY(),
        currency_burn_delay_ms,
    );
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
    // Most governance changes are DAO-only
    policy_registry::set_type_policy<action_types::UpdateName>(
        registry,
        dao_id,
        option::none(),
        policy_registry::MODE_DAO_ONLY(),
        option::none(),
        policy_registry::MODE_DAO_ONLY(),
        update_name_delay_ms,
    );

    policy_registry::set_type_policy<action_types::MetadataUpdate>(
        registry,
        dao_id,
        option::none(),
        policy_registry::MODE_DAO_ONLY(),
        option::none(),
        policy_registry::MODE_DAO_ONLY(),
        metadata_update_delay_ms,
    );

    policy_registry::set_type_policy<action_types::TradingParamsUpdate>(
        registry,
        dao_id,
        option::none(),
        policy_registry::MODE_DAO_ONLY(),
        option::none(),
        policy_registry::MODE_DAO_ONLY(),
        trading_params_delay_ms,
    );

    policy_registry::set_type_policy<action_types::GovernanceUpdate>(
        registry,
        dao_id,
        option::none(),
        policy_registry::MODE_DAO_ONLY(),
        option::none(),
        policy_registry::MODE_DAO_ONLY(),
        governance_update_delay_ms,
    );

    // Proposal creation is DAO-only
    policy_registry::set_type_policy<action_types::CreateProposal>(
        registry,
        dao_id,
        option::none(),
        policy_registry::MODE_DAO_ONLY(),
        option::none(),
        policy_registry::MODE_DAO_ONLY(),
        create_proposal_delay_ms,
    );
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
    // NOTE: The DAO should decide through governance whether to allow
    // the security council to set policies on objects. This would be done by:
    // policy_registry::set_type_policy<action_types::SetObjectPolicy>(
    //     registry, option::some(security_council), policy_registry::MODE_DAO_OR_COUNCIL()
    // );

    // Package upgrades require both DAO and security council
    // Changing this policy requires both DAO and security council (high security)
    policy_registry::set_type_policy<framework_action_types::PackageUpgrade>(
        registry,
        dao_id,
        option::some(security_council),
        policy_registry::MODE_DAO_AND_COUNCIL(),
        option::some(security_council), // Both needed to change policy
        policy_registry::MODE_DAO_AND_COUNCIL(),
        package_upgrade_delay_ms,
    );

    policy_registry::set_type_policy<framework_action_types::PackageCommit>(
        registry,
        dao_id,
        option::some(security_council),
        policy_registry::MODE_DAO_AND_COUNCIL(),
        option::some(security_council),
        policy_registry::MODE_DAO_AND_COUNCIL(),
        package_commit_delay_ms,
    );

    policy_registry::set_type_policy<framework_action_types::PackageRestrict>(
        registry,
        dao_id,
        option::some(security_council),
        policy_registry::MODE_DAO_AND_COUNCIL(),
        option::some(security_council),
        policy_registry::MODE_DAO_AND_COUNCIL(),
        package_restrict_delay_ms,
    );

    // Emergency dissolution requires both
    policy_registry::set_type_policy<action_types::InitiateDissolution>(
        registry,
        dao_id,
        option::some(security_council),
        policy_registry::MODE_DAO_AND_COUNCIL(),
        option::some(security_council),
        policy_registry::MODE_DAO_AND_COUNCIL(),
        dissolution_delay_ms,
    );
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
    // Factory management requires admin council
    policy_registry::set_type_policy<action_types::SetFactoryPaused>(
        registry,
        dao_id,
        option::some(admin_council),
        policy_registry::MODE_DAO_AND_COUNCIL(),
        option::none(),
        policy_registry::MODE_DAO_ONLY(),
        factory_paused_delay_ms,
    );

    // Fee updates require both DAO and admin
    policy_registry::set_type_policy<action_types::UpdateDaoCreationFee>(
        registry,
        dao_id,
        option::some(admin_council),
        policy_registry::MODE_DAO_AND_COUNCIL(),
        option::none(),
        policy_registry::MODE_DAO_ONLY(),
        dao_creation_fee_delay_ms,
    );

    policy_registry::set_type_policy<action_types::UpdateProposalFee>(
        registry,
        dao_id,
        option::some(admin_council),
        policy_registry::MODE_DAO_AND_COUNCIL(),
        option::none(),
        policy_registry::MODE_DAO_ONLY(),
        proposal_fee_delay_ms,
    );
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
    // Pool creation requires treasury council
    policy_registry::set_type_policy<action_types::CreatePool>(
        registry,
        dao_id,
        option::some(treasury_council),
        policy_registry::MODE_COUNCIL_ONLY(),
        option::none(),
        policy_registry::MODE_DAO_ONLY(),
        create_pool_delay_ms,
    );

    // Adding/removing liquidity requires treasury council
    policy_registry::set_type_policy<action_types::AddLiquidity>(
        registry,
        dao_id,
        option::some(treasury_council),
        policy_registry::MODE_COUNCIL_ONLY(),
        option::none(),
        policy_registry::MODE_DAO_ONLY(),
        add_liquidity_delay_ms,
    );

    policy_registry::set_type_policy<action_types::RemoveLiquidity>(
        registry,
        dao_id,
        option::some(treasury_council),
        policy_registry::MODE_COUNCIL_ONLY(),
        option::none(),
        policy_registry::MODE_DAO_ONLY(),
        remove_liquidity_delay_ms,
    );
}

/// Initialize all default policies for a new DAO
public fun init_all_default_policies(
    registry: &mut PolicyRegistry,
    dao_id: ID,
    treasury_council: ID,
    security_council: ID,
    admin_council: Option<ID>,
    vault_spend_delay_ms: u64,
    vault_deposit_delay_ms: u64,
    currency_mint_delay_ms: u64,
    currency_burn_delay_ms: u64,
    update_name_delay_ms: u64,
    metadata_update_delay_ms: u64,
    trading_params_delay_ms: u64,
    governance_update_delay_ms: u64,
    create_proposal_delay_ms: u64,
    package_upgrade_delay_ms: u64,
    package_commit_delay_ms: u64,
    package_restrict_delay_ms: u64,
    dissolution_delay_ms: u64,
    factory_paused_delay_ms: u64,
    dao_creation_fee_delay_ms: u64,
    proposal_fee_delay_ms: u64,
    monthly_dao_fee_delay_ms: u64,
    create_pool_delay_ms: u64,
    add_liquidity_delay_ms: u64,
    remove_liquidity_delay_ms: u64,
    vesting_create_delay_ms: u64,
    vesting_cancel_delay_ms: u64,
    toggle_vesting_pause_delay_ms: u64,
    toggle_vesting_freeze_delay_ms: u64,
    toggle_stream_pause_delay_ms: u64,
    toggle_stream_freeze_delay_ms: u64,
) {
    init_treasury_policies(
        registry,
        dao_id,
        treasury_council,
        vault_spend_delay_ms,
        vault_deposit_delay_ms,
        currency_mint_delay_ms,
        currency_burn_delay_ms,
    );

    init_governance_policies(
        registry,
        dao_id,
        update_name_delay_ms,
        metadata_update_delay_ms,
        trading_params_delay_ms,
        governance_update_delay_ms,
        create_proposal_delay_ms,
    );

    init_security_policies(
        registry,
        dao_id,
        security_council,
        package_upgrade_delay_ms,
        package_commit_delay_ms,
        package_restrict_delay_ms,
        dissolution_delay_ms,
    );

    if (option::is_some(&admin_council)) {
        init_protocol_admin_policies(
            registry,
            dao_id,
            *option::borrow(&admin_council),
            factory_paused_delay_ms,
            dao_creation_fee_delay_ms,
            proposal_fee_delay_ms,
            monthly_dao_fee_delay_ms,
        );
    };

    init_liquidity_policies(
        registry,
        dao_id,
        treasury_council,
        create_pool_delay_ms,
        add_liquidity_delay_ms,
        remove_liquidity_delay_ms,
    );

    init_vesting_stream_policies(
        registry,
        dao_id,
        treasury_council,
        vesting_create_delay_ms,
        vesting_cancel_delay_ms,
        toggle_vesting_pause_delay_ms,
        toggle_vesting_freeze_delay_ms,
        toggle_stream_pause_delay_ms,
        toggle_stream_freeze_delay_ms,
    );
}

/// Initialize vesting and stream control policies
public fun init_vesting_stream_policies(
    registry: &mut PolicyRegistry,
    dao_id: ID,
    treasury_council: ID,
    vesting_create_delay_ms: u64,
    vesting_cancel_delay_ms: u64,
    toggle_vesting_pause_delay_ms: u64,
    toggle_vesting_freeze_delay_ms: u64,
    toggle_stream_pause_delay_ms: u64,
    toggle_stream_freeze_delay_ms: u64,
) {
    // Creating vesting schedules requires treasury council
    policy_registry::set_type_policy<framework_action_types::VestingCreate>(
        registry,
        dao_id,
        option::some(treasury_council),
        policy_registry::MODE_COUNCIL_ONLY(),
        option::none(),
        policy_registry::MODE_DAO_ONLY(),
        vesting_create_delay_ms,
    );

    // Canceling vesting requires treasury council
    policy_registry::set_type_policy<framework_action_types::VestingCancel>(
        registry,
        dao_id,
        option::some(treasury_council),
        policy_registry::MODE_COUNCIL_ONLY(),
        option::none(),
        policy_registry::MODE_DAO_ONLY(),
        vesting_cancel_delay_ms,
    );

    // Pausing/resuming vesting requires treasury council
    policy_registry::set_type_policy<framework_action_types::ToggleVestingPause>(
        registry,
        dao_id,
        option::some(treasury_council),
        policy_registry::MODE_COUNCIL_ONLY(),
        option::none(),
        policy_registry::MODE_DAO_ONLY(),
        toggle_vesting_pause_delay_ms,
    );

    // Emergency freeze/unfreeze requires treasury council
    policy_registry::set_type_policy<framework_action_types::ToggleVestingFreeze>(
        registry,
        dao_id,
        option::some(treasury_council),
        policy_registry::MODE_COUNCIL_ONLY(),
        option::none(),
        policy_registry::MODE_DAO_ONLY(),
        toggle_vesting_freeze_delay_ms,
    );

    // Pausing/resuming streams requires treasury council
    policy_registry::set_type_policy<framework_action_types::ToggleStreamPause>(
        registry,
        dao_id,
        option::some(treasury_council),
        policy_registry::MODE_COUNCIL_ONLY(),
        option::none(),
        policy_registry::MODE_DAO_ONLY(),
        toggle_stream_pause_delay_ms,
    );

    // Emergency freeze/unfreeze streams requires treasury council
    policy_registry::set_type_policy<framework_action_types::ToggleStreamFreeze>(
        registry,
        dao_id,
        option::some(treasury_council),
        policy_registry::MODE_COUNCIL_ONLY(),
        option::none(),
        policy_registry::MODE_DAO_ONLY(),
        toggle_stream_freeze_delay_ms,
    );
}
