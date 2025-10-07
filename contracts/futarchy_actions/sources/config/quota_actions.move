/// Quota management action - set recurring proposal quotas for addresses
module futarchy_actions::quota_actions;

use std::vector;
use sui::{clock::Clock, bcs, object};
use account_protocol::{
    account::{Self, Account},
    executable::{Self, Executable},
    version_witness::VersionWitness,
    intents as protocol_intents,
    bcs_validation,
};
use futarchy_core::{
    futarchy_config::FutarchyConfig,
    proposal_quota_registry::ProposalQuotaRegistry,
    action_validation,
    action_types,
};

// === Errors ===
const EUnsupportedActionVersion: u64 = 0;

// === Structs ===

/// Action to set quotas for multiple addresses (batch operation)
/// Set quota_amount to 0 to remove quotas
public struct SetQuotasAction has store, drop {
    /// Addresses to set quota for
    users: vector<address>,
    /// N proposals per period (0 to remove)
    quota_amount: u64,
    /// Period in milliseconds (e.g., 30 days = 2_592_000_000)
    quota_period_ms: u64,
    /// Reduced fee (0 for free, ignored if removing)
    reduced_fee: u64,
}

// === Public Functions ===

/// Execute set quotas action
public fun do_set_quotas<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    registry: &mut ProposalQuotaRegistry,
    version: VersionWitness,
    intent_witness: IW,
    clock: &Clock,
    _ctx: &mut TxContext,
) {
    // Get action spec
    let specs = executable::intent(executable).action_specs();
    let spec = specs.borrow(executable::action_idx(executable));

    // CRITICAL - Type check BEFORE deserialization
    action_validation::assert_action_type<action_types::SetQuotas>(spec);

    // Get action data
    let action_data = protocol_intents::action_spec_data(spec);

    // Check version before deserialization
    let spec_version = protocol_intents::action_spec_version(spec);
    assert!(spec_version == 1, EUnsupportedActionVersion);

    // Deserialize action manually
    let mut reader = bcs::new(*action_data);

    // Deserialize vector<address>
    let users_count = reader.peel_vec_length();
    let mut users = vector::empty<address>();
    let mut i = 0;
    while (i < users_count) {
        users.push_back(reader.peel_address());
        i = i + 1;
    };

    // Deserialize quota parameters
    let quota_amount = reader.peel_u64();
    let quota_period_ms = reader.peel_u64();
    let reduced_fee = reader.peel_u64();

    // Validate all bytes consumed
    bcs_validation::validate_all_bytes_consumed(reader);

    // Create action struct
    let action = SetQuotasAction {
        users,
        quota_amount,
        quota_period_ms,
        reduced_fee,
    };

    // Execute internal logic
    do_set_quotas_internal(account, registry, action, version, clock, _ctx);

    // Increment action index
    executable::increment_action_idx(executable);
}

/// Internal version for actual execution
fun do_set_quotas_internal(
    account: &mut Account<FutarchyConfig>,
    registry: &mut ProposalQuotaRegistry,
    action: SetQuotasAction,
    _version: VersionWitness,
    clock: &Clock,
    _ctx: &mut TxContext,
) {
    // Destructure to consume the action
    let SetQuotasAction { users, quota_amount, quota_period_ms, reduced_fee } = action;

    // Set quotas with DAO ID check
    futarchy_core::proposal_quota_registry::set_quotas(
        registry,
        object::id(account),
        users,
        quota_amount,
        quota_period_ms,
        reduced_fee,
        clock,
    );
}

// === Constructor Functions ===

/// Create a set quotas action
public fun new_set_quotas(
    users: vector<address>,
    quota_amount: u64,
    quota_period_ms: u64,
    reduced_fee: u64,
): SetQuotasAction {
    SetQuotasAction {
        users,
        quota_amount,
        quota_period_ms,
        reduced_fee,
    }
}

// === Garbage Collection ===

/// Delete a set quotas action from an expired intent
public fun delete_set_quotas(expired: &mut account_protocol::intents::Expired) {
    let action_spec = account_protocol::intents::remove_action_spec(expired);
    // Action spec has drop, so it's automatically cleaned up
    let _ = action_spec;
}

// === Getter Functions ===

public fun users(action: &SetQuotasAction): &vector<address> { &action.users }
public fun quota_amount(action: &SetQuotasAction): u64 { action.quota_amount }
public fun quota_period_ms(action: &SetQuotasAction): u64 { action.quota_period_ms }
public fun reduced_fee(action: &SetQuotasAction): u64 { action.reduced_fee }
