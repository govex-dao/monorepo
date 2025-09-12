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
    execute_specs_with_resources<AssetType, StableType>(
        account, specs, queue, spot_pool, clock, ctx
    );
}

/// The main dispatcher. Iterates through specs and calls handlers via the simplified pattern.
fun execute_specs_with_resources<AssetType: drop + store, StableType: drop + store>(
    account: &mut Account<FutarchyConfig>,
    specs: InitActionSpecs,
    queue: &mut ProposalQueue<StableType>,
    spot_pool: &mut AccountSpotPool<AssetType, StableType>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let dao_id = object::id_address(account);
    let actions = action_specs::actions(&specs);
    let mut i = 0;
    let mut successful = 0;
    let mut failed = 0;
    
    while (i < vector::length(actions)) {
        let spec = vector::borrow(actions, i);
        let action_type = action_specs::action_type(spec);
        let action_data = action_specs::action_data(spec);

        // The dispatcher chain. Each module returns true if it handled the action.
        let handled = try_execute_with_all_dispatchers(
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
            // In the simplified pattern, we always abort on failure
            abort EInitActionFailed
        };

        event::emit(InitActionAttempted {
            dao_id,
            action_type: b"action".to_string(), // TypeName cannot be converted to string
            action_index: i,
            success: handled,
        });

        i = i + 1;
    };

    event::emit(InitBatchCompleted {
        dao_id,
        total_actions: i,
        successful_actions: successful,
        failed_actions: failed,
    });
}

/// Try all dispatchers with the simplified pattern
fun try_execute_with_all_dispatchers<AssetType: drop + store, StableType: drop + store>(
    action_type: &TypeName,
    action_data: &vector<u8>,
    account: &mut Account<FutarchyConfig>,
    queue: &mut ProposalQueue<StableType>,
    spot_pool: &mut AccountSpotPool<AssetType, StableType>,
    clock: &Clock,
    ctx: &mut TxContext,
): bool {
    use futarchy_actions::config_dispatcher;
    use futarchy_actions::liquidity_dispatcher;
    
    // The dispatcher chain. Each module returns (bool, String) for (success, description).
    // This is the simplified pattern - no complex child objects or registry
    let (success, _) = config_dispatcher::execute_init_config_action(
        action_type, action_data, account, clock, ctx
    );
    if (success) {
        return true
    };
    
    let (success, _) = liquidity_dispatcher::try_execute_init_action<AssetType, StableType>(
        action_type, action_data, account, spot_pool, clock, ctx
    );
    if (success) {
        return true
    };
    
    // Add other dispatchers here as needed:
    // if (commitment_dispatcher::try_execute_init_action(...)) { return true };
    // if (vault_governance_dispatcher::try_execute_init_action(...)) { return true };
    
    false // Action not handled by any dispatcher
}


// === Constants ===
const MAX_INIT_ACTIONS: u64 = 50; // Reasonable limit to prevent gas issues

// === Errors ===
const EUnhandledAction: u64 = 1;
const EActionNotAllowedAtInit: u64 = 2;
const EInitActionFailed: u64 = 3;
const ETooManyInitActions: u64 = 4;