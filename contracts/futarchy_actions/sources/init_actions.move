/// Init Actions - A fully dynamic, table-based dispatcher for DAO initialization.
/// This module reads an `IntentSpec` and uses a simplified dispatcher pattern to
/// execute the appropriate handler for each action. It is completely
/// decoupled from any specific action logic.
/// 
/// ## Hot Potato Pattern
/// Executes init actions with unshared "hot potato" resources before DAO is public:
/// - `&mut Account` - DAO account (exists but not shared)
/// - `&mut ProposalQueue` - Queue (exists but not shared)  
/// - `&mut AccountSpotPool` - AMM pool (exists but not shared)
/// 
/// This allows init actions to:
/// - Add initial liquidity before anyone can trade
/// - Create proposals before public access
/// - Configure settings atomically
/// 
/// If ANY action fails, entire DAO creation reverts (atomic guarantee)
module futarchy_actions::init_actions;

use std::option;
use std::type_name::{Self, TypeName};
use std::string::String;
use sui::{clock::Clock, event, object, bcs};
use account_protocol::{
    account::{Self, Account},
    intents::{Self, Intent},
    executable::{Self, Executable},
};
use futarchy_core::{
    futarchy_config::{FutarchyConfig, FutarchyOutcome},
    priority_queue::ProposalQueue,
};
use futarchy_markets::account_spot_pool::AccountSpotPool;
use futarchy_actions::action_specs::{Self, ActionSpec, InitActionSpecs};

/// Special witness for init actions that bypass voting
public struct InitWitness has drop {}

/// Result of init action execution with detailed error tracking
public struct InitResult has drop {
    total_actions: u64,
    succeeded: u64,
    failed: u64,
    first_error: Option<String>,
    failed_action_index: Option<u64>,
    partial_execution_allowed: bool,
}

/// Event emitted for each init action attempted (for launchpad tracking)
public struct InitActionAttempted has copy, drop {
    dao_id: address,
    action_type: String,  // TypeName as string
    action_index: u64,
    success: bool,
}

/// Event for init batch completion
public struct InitBatchCompleted has copy, drop {
    dao_id: address, 
    total_actions: u64,
    successful_actions: u64,
    failed_actions: u64,
}


// === Helper Functions for PTB ===

/// Create an init intent that bypasses voting
public fun create_init_intent(
    account: &Account<FutarchyConfig>,
    ctx: &mut TxContext,
): Intent<FutarchyOutcome> {
    // Temporarily disabled - needs redesign
    abort 0
}


/// Get witness for adding actions to init intent
public fun init_witness(): InitWitness {
    InitWitness {}
}


/// Execute init intent with hot potato resources using action specs
/// This version allows passing unshared objects that init actions need
public fun execute_init_intent_with_resources<AssetType: drop + store, StableType: drop + store>(
    account: &mut Account<FutarchyConfig>,
    specs: InitActionSpecs,
    // Hot potato resources - passed as mutable references
    queue: &mut ProposalQueue<StableType>,
    spot_pool: &mut AccountSpotPool<AssetType, StableType>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let result = execute_specs_with_resources<AssetType, StableType>(
        account, specs, queue, spot_pool, clock, ctx, false // partial_execution_allowed = false
    );

    // If any action failed and partial execution is not allowed, abort
    if (result.failed > 0 && !result.partial_execution_allowed) {
        abort EInitActionFailed
    }
}

/// Execute init actions with partial execution support
/// Returns InitResult with details about successes and failures
public fun execute_init_intent_with_partial_support<AssetType: drop + store, StableType: drop + store>(
    account: &mut Account<FutarchyConfig>,
    specs: InitActionSpecs,
    queue: &mut ProposalQueue<StableType>,
    spot_pool: &mut AccountSpotPool<AssetType, StableType>,
    clock: &Clock,
    ctx: &mut TxContext,
    allow_partial: bool,
): InitResult {
    execute_specs_with_resources<AssetType, StableType>(
        account, specs, queue, spot_pool, clock, ctx, allow_partial
    )
}

/// The main dispatcher with error recovery support
fun execute_specs_with_resources<AssetType: drop + store, StableType: drop + store>(
    account: &mut Account<FutarchyConfig>,
    specs: InitActionSpecs,
    queue: &mut ProposalQueue<StableType>,
    spot_pool: &mut AccountSpotPool<AssetType, StableType>,
    clock: &Clock,
    ctx: &mut TxContext,
    allow_partial: bool,
): InitResult {
    let dao_id = object::id_address(account);
    let actions = action_specs::actions(&specs);
    let total_actions = vector::length(actions);
    let mut i = 0;
    let mut successful = 0;
    let mut failed = 0;
    let mut first_error: Option<String> = option::none();
    let mut failed_action_index: Option<u64> = option::none();

    while (i < total_actions) {
        let spec = vector::borrow(actions, i);
        let action_type = action_specs::action_type(spec);
        let action_data = action_specs::action_data(spec);

        // Try to execute with all dispatchers
        let (handled, error_msg) = try_execute_with_all_dispatchers_safe(
            &action_type,
            action_data,
            account,
            queue,
            spot_pool,
            clock,
            ctx
        );

        if (handled) {
            successful = successful + 1;
        } else {
            failed = failed + 1;

            // Track first error
            if (first_error.is_none()) {
                first_error = option::some(error_msg);
                failed_action_index = option::some(i);
            };

            // If partial execution not allowed, stop immediately
            if (!allow_partial) {
                event::emit(InitActionAttempted {
                    dao_id,
                    action_type: b"action".to_string(),
                    action_index: i,
                    success: false,
                });
                break
            }
        };

        event::emit(InitActionAttempted {
            dao_id,
            action_type: b"action".to_string(),
            action_index: i,
            success: handled,
        });

        i = i + 1;
    };

    event::emit(InitBatchCompleted {
        dao_id,
        total_actions,
        successful_actions: successful,
        failed_actions: failed,
    });

    InitResult {
        total_actions,
        succeeded: successful,
        failed,
        first_error,
        failed_action_index,
        partial_execution_allowed: allow_partial,
    }
}

/// Try all dispatchers with error recovery
/// Returns (success, error_message)
fun try_execute_with_all_dispatchers_safe<AssetType: drop + store, StableType: drop + store>(
    action_type: &TypeName,
    action_data: &vector<u8>,
    account: &mut Account<FutarchyConfig>,
    queue: &mut ProposalQueue<StableType>,
    spot_pool: &mut AccountSpotPool<AssetType, StableType>,
    clock: &Clock,
    ctx: &mut TxContext,
): (bool, String) {
    // Try each dispatcher and capture errors
    let result = try_execute_with_all_dispatchers(
        action_type,
        action_data,
        account,
        queue,
        spot_pool,
        clock,
        ctx
    );

    if (result) {
        (true, string::utf8(b""))
    } else {
        (false, string::utf8(b"Action not handled by any dispatcher"))
    }
}

/// Original dispatcher chain (now complete with all dispatchers)
fun try_execute_with_all_dispatchers<AssetType: drop + store, StableType: drop + store>(
    action_type: &TypeName,
    action_data: &vector<u8>,
    account: &mut Account<FutarchyConfig>,
    queue: &mut ProposalQueue<StableType>,
    spot_pool: &mut AccountSpotPool<AssetType, StableType>,
    clock: &Clock,
    ctx: &mut TxContext,
): bool {
    // Import all dispatcher modules
    use futarchy_actions::config_dispatcher;
    use futarchy_actions::liquidity_dispatcher;

    // Note: Additional dispatchers would be imported here when they implement init support
    // Currently only config and liquidity dispatchers have init action support
    // The following would be added as they're implemented:
    // use futarchy_actions::governance_dispatcher;
    // use futarchy_actions::memo_dispatcher;
    // use futarchy_vault::custody_dispatcher;
    // use futarchy_lifecycle::stream_dispatcher;
    // use futarchy_lifecycle::dissolution_dispatcher;
    // use futarchy_lifecycle::oracle_dispatcher;
    // use futarchy_multisig::security_council_dispatcher;
    // use futarchy_multisig::policy_dispatcher;
    // use futarchy_specialized_actions::operating_agreement_dispatcher;

    // Try config actions first (most common for init)
    let (success, _) = config_dispatcher::execute_init_config_action(
        action_type, action_data, account, clock, ctx
    );
    if (success) {
        return true
    };

    // Try liquidity actions (common for bootstrapping AMM)
    let (success, _) = liquidity_dispatcher::try_execute_init_action<AssetType, StableType>(
        action_type, action_data, account, spot_pool, clock, ctx
    );
    if (success) {
        return true
    };

    // TODO: Add more dispatchers as they implement init action support
    // Each dispatcher module needs to implement a try_execute_init_action function
    // that can work with unshared objects during DAO initialization

    // Example of future dispatcher integration:
    // let (success, _) = stream_dispatcher::try_execute_init_action<AssetType>(
    //     action_type, action_data, account, clock, ctx
    // );
    // if (success) return true;

    false // Action not handled by any dispatcher
}


// === Constants ===
const MAX_INIT_ACTIONS: u64 = 50; // Reasonable limit to prevent gas issues

// === Public Getters for InitResult ===
public fun result_succeeded(result: &InitResult): u64 { result.succeeded }
public fun result_failed(result: &InitResult): u64 { result.failed }
public fun result_first_error(result: &InitResult): &Option<String> { &result.first_error }
public fun result_failed_index(result: &InitResult): &Option<u64> { &result.failed_action_index }
public fun result_is_complete_success(result: &InitResult): bool { result.failed == 0 }
public fun result_is_partial_success(result: &InitResult): bool {
    result.succeeded > 0 && result.failed > 0 && result.partial_execution_allowed
}

// === Errors ===
const EUnhandledAction: u64 = 1;
const EActionNotAllowedAtInit: u64 = 2;
const EInitActionFailed: u64 = 3;
const ETooManyInitActions: u64 = 4;