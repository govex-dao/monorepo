/// Optimistic intent system for Security Council
/// Allows council to create intents that execute after a delay unless challenged
/// 
/// Features:
/// - 10-day waiting period before execution
/// - Challenge mechanism via governance proposals (cancels the intent)
/// - Batch challenge support
/// - Maximum 10 concurrent optimistic intents
/// - Council can cancel their own intents
module futarchy_multisig::optimistic_intents;

// === Imports ===
use std::{
    string::{Self, String},
    option::{Self, Option},
    vector,
};
use sui::{
    clock::Clock,
    table::{Self, Table},
    event,
    object::{Self, ID, UID},
    tx_context::{Self, TxContext},
};
use futarchy_core::version;
use account_protocol::{
    account::{Self, Account},
    executable::{Self, Executable},
    intents::{Intent},
    version_witness::VersionWitness,
};
use futarchy_core::futarchy_config::{Self, FutarchyConfig};

// === Errors ===
const ENotSecurityCouncil: u64 = 1;
const ETooManyOptimisticIntents: u64 = 2;
const EIntentNotFound: u64 = 3;
const EIntentAlreadyChallenged: u64 = 4;
const EIntentNotReady: u64 = 5;
const EIntentExpired: u64 = 6;
const EInvalidBatchSize: u64 = 7;
const EIntentAlreadyExecuted: u64 = 8;
const EDuplicateIntent: u64 = 9;
const EInvalidWaitingPeriod: u64 = 10;
const EIntentAlreadyCancelled: u64 = 11;
const ENotProposer: u64 = 12;
const EIntegerOverflow: u64 = 13;

// === Constants ===
const MAX_OPTIMISTIC_INTENTS: u64 = 10;
const WAITING_PERIOD_MS: u64 = 864_000_000; // 10 days in milliseconds
const MAX_BATCH_CHALLENGES: u64 = 10;
const EXPIRY_PERIOD_MS: u64 = 2_592_000_000; // 30 days in milliseconds

// === Storage Keys ===

/// Dynamic field key for optimistic intent storage
public struct OptimisticStorageKey has copy, drop, store {}

/// Storage for optimistic intents in an account
public struct OptimisticIntentStorage has store {
    intents: Table<ID, OptimisticIntent>,
    active_intents: vector<ID>,  // Track active intent IDs
    total_active: u64,
}

/// An optimistic intent pending execution
public struct OptimisticIntent has store {
    id: ID,
    intent_key: String,
    proposer: address,  // Security council member who proposed
    title: String,
    description: String,
    created_at: u64,
    executes_at: u64,  // created_at + WAITING_PERIOD_MS
    expires_at: u64,   // executes_at + EXPIRY_PERIOD_MS
    is_cancelled: bool,
    cancel_reason: Option<String>,
    is_executed: bool,
}

// === Events ===

public struct OptimisticIntentCreated has copy, drop {
    dao_id: ID,
    intent_id: ID,
    intent_key: String,
    proposer: address,
    title: String,
    executes_at: u64,
    timestamp: u64,
}

public struct OptimisticIntentCancelled has copy, drop {
    dao_id: ID,
    intent_id: ID,
    reason: String,
    cancelled_by_governance: bool,
    timestamp: u64,
}

public struct OptimisticIntentExecuted has copy, drop {
    dao_id: ID,
    intent_id: ID,
    intent_key: String,
    timestamp: u64,
}

public struct OptimisticIntentExpired has copy, drop {
    dao_id: ID,
    intent_id: ID,
    timestamp: u64,
}

// === Actions ===

/// Action to create an optimistic intent
public struct CreateOptimisticIntentAction has store {
    intent_key: String,
    title: String,
    description: String,
}

/// Action to challenge optimistic intents (cancels them)
public struct ChallengeOptimisticIntentsAction has store {
    intent_ids: vector<ID>,
    governance_proposal_id: ID,
}

/// Action to execute a matured optimistic intent
public struct ExecuteOptimisticIntentAction has store {
    intent_id: ID,
}

/// Action to cancel an optimistic intent (security council only)
public struct CancelOptimisticIntentAction has store {
    intent_id: ID,
    reason: String,
}

/// Action to clean up expired intents
public struct CleanupExpiredIntentsAction has store {
    intent_ids: vector<ID>,
}

// === Public Functions ===

/// Initialize optimistic intent storage for a DAO
public fun initialize_storage<Config>(
    account: &mut Account<Config>,
    version_witness: VersionWitness,
    ctx: &mut TxContext,
) {
    if (!account::has_managed_data(account, OptimisticStorageKey {})) {
        let storage = OptimisticIntentStorage {
            intents: table::new(ctx),
            active_intents: vector::empty(),
            total_active: 0,
        };
        account::add_managed_data(
            account,
            OptimisticStorageKey {},
            storage,
            version_witness,
        );
    }
}

/// Create an optimistic intent (security council only)
public fun do_create_optimistic_intent<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    _version_witness: VersionWitness,
    witness: IW,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let action = executable::next_action<Outcome, CreateOptimisticIntentAction, IW>(
        executable, witness
    );
    
    // Initialize storage if needed
    initialize_storage(account, version::current(), ctx);
    
    let storage: &mut OptimisticIntentStorage = account::borrow_managed_data_mut(
        account,
        OptimisticStorageKey {},
        version::current()
    );
    
    // Check intent limit
    assert!(storage.total_active < MAX_OPTIMISTIC_INTENTS, ETooManyOptimisticIntents);
    
    let current_time = clock.timestamp_ms();
    
    // Validate overflow for time calculations
    // u64 max is 18446744073709551615
    assert!(current_time <= 18446744073709551615 - WAITING_PERIOD_MS, EIntegerOverflow);
    assert!(current_time + WAITING_PERIOD_MS <= 18446744073709551615 - EXPIRY_PERIOD_MS, EIntegerOverflow);
    
    // Create UID after all validations
    let uid = object::new(ctx);
    let intent_id = object::uid_to_inner(&uid);
    object::delete(uid);
    
    // Create the intent
    let intent = OptimisticIntent {
        id: intent_id,
        intent_key: action.intent_key,
        proposer: tx_context::sender(ctx),
        title: action.title,
        description: action.description,
        created_at: current_time,
        executes_at: current_time + WAITING_PERIOD_MS,
        expires_at: current_time + WAITING_PERIOD_MS + EXPIRY_PERIOD_MS,
        is_cancelled: false,
        cancel_reason: option::none(),
        is_executed: false,
    };
    
    // Store the intent
    table::add(&mut storage.intents, intent_id, intent);
    vector::push_back(&mut storage.active_intents, intent_id);
    storage.total_active = storage.total_active + 1;
    
    // Emit event
    event::emit(OptimisticIntentCreated {
        dao_id: object::id(account),
        intent_id,
        intent_key: action.intent_key,
        proposer: tx_context::sender(ctx),
        title: action.title,
        executes_at: current_time + WAITING_PERIOD_MS,
        timestamp: current_time,
    });
}

/// Challenge optimistic intents (cancels them via governance proposal)
public fun do_challenge_optimistic_intents<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    _version_witness: VersionWitness,
    witness: IW,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let action = executable::next_action<Outcome, ChallengeOptimisticIntentsAction, IW>(
        executable, witness
    );
    
    // Validate batch size
    let batch_size = vector::length(&action.intent_ids);
    assert!(batch_size > 0 && batch_size <= MAX_BATCH_CHALLENGES, EInvalidBatchSize);
    
    // Initialize storage if needed
    initialize_storage(account, version::current(), ctx);
    
    let current_time = clock.timestamp_ms();
    let dao_id = object::id(account);
    
    let storage: &mut OptimisticIntentStorage = account::borrow_managed_data_mut(
        account,
        OptimisticStorageKey {},
        version::current()
    );
    
    // Process each intent in the batch
    let mut i = 0;
    while (i < batch_size) {
        let intent_id = *vector::borrow(&action.intent_ids, i);
        
        // Check intent exists
        assert!(table::contains(&storage.intents, intent_id), EIntentNotFound);
        
        let intent = table::borrow_mut(&mut storage.intents, intent_id);
        
        // Check not already cancelled
        assert!(!intent.is_cancelled, EIntentAlreadyCancelled);
        assert!(!intent.is_executed, EIntentAlreadyExecuted);
        
        // Cancel the intent
        intent.is_cancelled = true;
        intent.cancel_reason = option::some(
            b"Cancelled by governance proposal".to_string()
        );
        
        // Remove from active intents safely
        remove_from_active_intents(&mut storage.active_intents, &mut storage.total_active, intent_id);
        
        // Emit event
        event::emit(OptimisticIntentCancelled {
            dao_id,
            intent_id,
            reason: b"Challenged and cancelled by governance proposal".to_string(),
            cancelled_by_governance: true,
            timestamp: current_time,
        });
        
        i = i + 1;
    };
}

/// Cancel an optimistic intent (security council only)
public fun do_cancel_optimistic_intent<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    _version_witness: VersionWitness,
    witness: IW,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let action = executable::next_action<Outcome, CancelOptimisticIntentAction, IW>(
        executable, witness
    );
    
    let storage: &mut OptimisticIntentStorage = account::borrow_managed_data_mut(
        account,
        OptimisticStorageKey {},
        version::current()
    );
    
    // Check intent exists
    assert!(table::contains(&storage.intents, action.intent_id), EIntentNotFound);
    
    let intent = table::borrow_mut(&mut storage.intents, action.intent_id);
    
    // Only the original proposer can cancel
    assert!(intent.proposer == tx_context::sender(ctx), ENotProposer);
    
    // Check not already cancelled or executed
    assert!(!intent.is_cancelled, EIntentAlreadyCancelled);
    assert!(!intent.is_executed, EIntentAlreadyExecuted);
    
    // Cancel the intent
    intent.is_cancelled = true;
    intent.cancel_reason = option::some(action.reason);
    
    // Remove from active intents safely
    remove_from_active_intents(&mut storage.active_intents, &mut storage.total_active, action.intent_id);
    
    // Emit event
    event::emit(OptimisticIntentCancelled {
        dao_id: object::id(account),
        intent_id: action.intent_id,
        reason: action.reason,
        cancelled_by_governance: false,
        timestamp: clock.timestamp_ms(),
    });
}

/// Execute a matured optimistic intent
public fun do_execute_optimistic_intent<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    _version_witness: VersionWitness,
    witness: IW,
    clock: &Clock,
    _ctx: &mut TxContext,
): String {  // Returns intent_key for execution
    let action = executable::next_action<Outcome, ExecuteOptimisticIntentAction, IW>(
        executable, witness
    );
    
    let storage: &mut OptimisticIntentStorage = account::borrow_managed_data_mut(
        account,
        OptimisticStorageKey {},
        version::current()
    );
    
    // Check intent exists
    assert!(table::contains(&storage.intents, action.intent_id), EIntentNotFound);
    
    let intent = table::borrow_mut(&mut storage.intents, action.intent_id);
    let current_time = clock.timestamp_ms();
    
    // Validation checks
    assert!(!intent.is_executed, EIntentAlreadyExecuted);
    assert!(!intent.is_cancelled, EIntentAlreadyCancelled);
    assert!(current_time >= intent.executes_at, EIntentNotReady);
    assert!(current_time < intent.expires_at, EIntentExpired);
    
    // Mark as executed
    intent.is_executed = true;
    let intent_key = intent.intent_key;
    
    // Remove from active intents safely  
    remove_from_active_intents(&mut storage.active_intents, &mut storage.total_active, action.intent_id);
    
    // Emit event
    event::emit(OptimisticIntentExecuted {
        dao_id: object::id(account),
        intent_id: action.intent_id,
        intent_key,
        timestamp: current_time,
    });
    
    intent_key
}

// === Helper Functions ===

/// Safely remove an intent from the active intents vector
fun remove_from_active_intents(
    active_intents: &mut vector<ID>,
    total_active: &mut u64,
    intent_id: ID,
) {
    let (found, index) = vector::index_of(active_intents, &intent_id);
    if (found) {
        vector::remove(active_intents, index);
        // Only decrement if we actually removed something
        if (*total_active > 0) {
            *total_active = *total_active - 1;
        }
    }
}

/// Clean up expired intents
public fun do_cleanup_expired_intents<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    _version_witness: VersionWitness,
    witness: IW,
    clock: &Clock,
    _ctx: &mut TxContext,
) {
    let action = executable::next_action<Outcome, CleanupExpiredIntentsAction, IW>(
        executable, witness
    );
    
    // Validate batch size to prevent gas exhaustion
    let batch_size = vector::length(&action.intent_ids);
    assert!(batch_size > 0 && batch_size <= MAX_BATCH_CHALLENGES, EInvalidBatchSize);
    
    let current_time = clock.timestamp_ms();
    let dao_id = object::id(account);
    
    let storage: &mut OptimisticIntentStorage = account::borrow_managed_data_mut(
        account,
        OptimisticStorageKey {},
        version::current()
    );
    
    // Process each intent
    let mut i = 0;
    while (i < batch_size) {
        let intent_id = *vector::borrow(&action.intent_ids, i);
        
        if (table::contains(&storage.intents, intent_id)) {
            let intent = table::borrow(&storage.intents, intent_id);
            
            // Check if expired and not executed
            if (current_time >= intent.expires_at && !intent.is_executed) {
                // Remove from storage and destroy the intent
                let OptimisticIntent {
                    id: _,
                    intent_key: _,
                    proposer: _,
                    title: _,
                    description: _,
                    created_at: _,
                    executes_at: _,
                    expires_at: _,
                    is_cancelled: _,
                    cancel_reason: _,
                    is_executed: _,
                } = table::remove(&mut storage.intents, intent_id);
                
                // Remove from active intents
                let (found, index) = vector::index_of(&storage.active_intents, &intent_id);
                if (found) {
                    vector::remove(&mut storage.active_intents, index);
                    storage.total_active = storage.total_active - 1;
                };
                
                // Emit event
                event::emit(OptimisticIntentExpired {
                    dao_id,
                    intent_id,
                    timestamp: current_time,
                });
            };
        };
        
        i = i + 1;
    };
}

// === Helper Functions ===

/// Get active intent count
public fun get_active_intent_count(
    account: &Account<FutarchyConfig>
): u64 {
    if (!account::has_managed_data(account, OptimisticStorageKey {})) {
        return 0
    };
    
    let storage: &OptimisticIntentStorage = account::borrow_managed_data(
        account,
        OptimisticStorageKey {},
        version::current()
    );
    
    storage.total_active
}

/// Check if an intent can be executed
public fun can_execute_intent(
    account: &Account<FutarchyConfig>,
    intent_id: ID,
    clock: &Clock,
): bool {
    if (!account::has_managed_data(account, OptimisticStorageKey {})) {
        return false
    };
    
    let storage: &OptimisticIntentStorage = account::borrow_managed_data(
        account,
        OptimisticStorageKey {},
        version::current()
    );
    
    if (!table::contains(&storage.intents, intent_id)) {
        return false
    };
    
    let intent = table::borrow(&storage.intents, intent_id);
    let current_time = clock.timestamp_ms();
    
    !intent.is_executed && 
    !intent.is_cancelled && 
    current_time >= intent.executes_at && 
    current_time < intent.expires_at
}

// === Action Constructors ===

/// Create an action to create an optimistic intent
public fun new_create_optimistic_intent_action(
    intent_key: String,
    title: String,
    description: String,
): CreateOptimisticIntentAction {
    CreateOptimisticIntentAction {
        intent_key,
        title,
        description,
    }
}

/// Create an action to challenge optimistic intents
public fun new_challenge_optimistic_intents_action(
    intent_ids: vector<ID>,
    governance_proposal_id: ID,
): ChallengeOptimisticIntentsAction {
    ChallengeOptimisticIntentsAction {
        intent_ids,
        governance_proposal_id,
    }
}

/// Create an action to execute an optimistic intent
public fun new_execute_optimistic_intent_action(
    intent_id: ID,
): ExecuteOptimisticIntentAction {
    ExecuteOptimisticIntentAction {
        intent_id,
    }
}

/// Create an action to cancel an optimistic intent
public fun new_cancel_optimistic_intent_action(
    intent_id: ID,
    reason: String,
): CancelOptimisticIntentAction {
    CancelOptimisticIntentAction {
        intent_id,
        reason,
    }
}

/// Create an action to cleanup expired intents
public fun new_cleanup_expired_intents_action(
    intent_ids: vector<ID>,
): CleanupExpiredIntentsAction {
    CleanupExpiredIntentsAction {
        intent_ids,
    }
}

// === Delete Functions for Expired Actions ===

/// Delete an expired ExecuteOptimisticIntentAction
public fun delete_execute_optimistic_intent_action(expired: &mut account_protocol::intents::Expired) {
    let ExecuteOptimisticIntentAction { intent_id: _ } = expired.remove_action();
}

/// Delete an expired CancelOptimisticIntentAction
public fun delete_cancel_optimistic_intent_action(expired: &mut account_protocol::intents::Expired) {
    let CancelOptimisticIntentAction { intent_id: _, reason: _ } = expired.remove_action();
}

/// Delete an expired CreateOptimisticIntentAction
public fun delete_create_optimistic_intent_action(expired: &mut account_protocol::intents::Expired) {
    let CreateOptimisticIntentAction { intent_key: _, title: _, description: _ } = expired.remove_action();
}

/// Delete an expired ChallengeOptimisticIntentsAction
public fun delete_challenge_optimistic_intents_action(expired: &mut account_protocol::intents::Expired) {
    let ChallengeOptimisticIntentsAction { intent_ids: _, governance_proposal_id: _ } = expired.remove_action();
}

/// Delete an expired CleanupExpiredIntentsAction
public fun delete_cleanup_expired_intents_action(expired: &mut account_protocol::intents::Expired) {
    let CleanupExpiredIntentsAction { intent_ids: _ } = expired.remove_action();
}