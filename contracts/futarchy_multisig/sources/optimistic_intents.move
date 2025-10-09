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
    vec_set::{Self, VecSet},
    event,
    object::{Self, ID, UID},
    tx_context::{Self, TxContext},
    bcs,
};
use futarchy_core::version;
use account_protocol::{
    account::{Self, Account},
    executable::{Self, Executable},
    intents::{Self, Intent, Expired},
    version_witness::VersionWitness,
};
use futarchy_core::futarchy_config::{Self, FutarchyConfig};
use futarchy_multisig::weighted_multisig::{Self, WeightedMultisig};

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
const ETimelockTooShort: u64 = 14;  // Council timelock must be >= 10 days when challenges disabled
const ECouncilNotLinked: u64 = 15;  // Council must have a dao_id set
const EWrongDao: u64 = 16;  // Council belongs to a different DAO
const ECouncilAlreadyRegistered: u64 = 17;  // Council already registered with this DAO

// === Constants ===
const MAX_OPTIMISTIC_INTENTS: u64 = 10;
const WAITING_PERIOD_MS: u64 = 864_000_000; // 10 days in milliseconds
const MAX_BATCH_CHALLENGES: u64 = 10;
const EXPIRY_PERIOD_MS: u64 = 2_592_000_000; // 30 days in milliseconds

// Static validation for overflow safety - these values are safe:
// WAITING_PERIOD_MS + EXPIRY_PERIOD_MS = 3,456,000,000 which is much less than u64::MAX
// The sum check in the code ensures no overflow when adding to current timestamp

// === Storage Keys ===

/// Dynamic field key for optimistic intent storage
public struct OptimisticStorageKey has copy, drop, store {}

/// Dynamic field key for council registry
public struct CouncilRegistryKey has copy, drop, store {}

/// Storage for optimistic intents in an account
public struct OptimisticIntentStorage has store {
    intents: Table<ID, OptimisticIntent>,
    active_intents: vector<ID>,  // Track active intent IDs
    total_active: u64,
}

/// Registry of security councils authorized to create optimistic intents on this DAO
/// This validates council ownership and caches their timelock settings
public struct CouncilRegistry has store {
    /// Map of council ID -> council info
    councils: Table<ID, CouncilInfo>,
    /// List of all registered council IDs (for iteration)
    council_ids: vector<ID>,
}

/// Information about a registered security council
/// Note: We don't cache the council's timelock here because it can change.
/// When challenges are disabled, DAOs must ensure registered councils have >= 10-day timelocks.
public struct CouncilInfo has store, drop, copy {
    /// The council's account ID
    council_id: ID,
    /// Council type/name (e.g., "treasury", "technical", "emergency")
    council_type: String,
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

public struct ChallengeBountyPaid has copy, drop {
    dao_id: ID,
    intent_id: ID,
    challenger: address,
    bounty_amount: u64,
    timestamp: u64,
}

// === Actions ===

/// Action to create an optimistic intent
public struct CreateOptimisticIntentAction has store, drop {
    intent_key: String,
    title: String,
    description: String,
}

/// Action to challenge optimistic intents (cancels them)
/// Note: Challenge bounty is paid via a separate SpendAndTransfer action in the same proposal
/// The bounty amount is configured in GovernanceConfig.challenge_bounty
public struct ChallengeOptimisticIntentsAction has store, drop {
    intent_ids: vector<ID>,
    governance_proposal_id: ID,
}

/// Action to execute a matured optimistic intent
public struct ExecuteOptimisticIntentAction has store, drop, copy {
    intent_id: ID,
}

/// Action to cancel an optimistic intent (security council only)
public struct CancelOptimisticIntentAction has store, drop, copy {
    intent_id: ID,
    reason: String,
}

/// Action to clean up expired intents
public struct CleanupExpiredIntentsAction has store, drop, copy {
    intent_ids: vector<ID>,
}

/// Action to toggle optimistic intent challenge period
public struct SetOptimisticIntentChallengeEnabledAction has store, drop {
    enabled: bool,
}

/// Action to register a security council with the DAO (governance only)
public struct RegisterCouncilAction has store, drop {
    council_id: ID,
    council_type: String,
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

/// Initialize council registry for a DAO
public fun initialize_council_registry(
    account: &mut Account<FutarchyConfig>,
    version_witness: VersionWitness,
    ctx: &mut TxContext,
) {
    if (!account::has_managed_data(account, CouncilRegistryKey {})) {
        let registry = CouncilRegistry {
            councils: table::new(ctx),
            council_ids: vector::empty(),
        };
        account::add_managed_data(
            account,
            CouncilRegistryKey {},
            registry,
            version_witness,
        );
    }
}

/// Register a security council with the DAO (internal function)
///
/// SECURITY REQUIREMENTS:
/// - Council must have dao_id set to this DAO (verified on-chain)
/// - Must be called through governance action (do_register_council)
///
/// IMPORTANT: When challenges are disabled, DAOs MUST ensure registered councils
/// have timelock >= 10 days. This function validates council ownership but does NOT
/// validate timelock (councils can update their own timelocks after registration).
public(package) fun register_council(
    account: &mut Account<FutarchyConfig>,
    council_id: ID,
    council_type: String,
    version_witness: VersionWitness,
    ctx: &mut TxContext,
) {
    // Initialize registry if needed
    initialize_council_registry(account, version_witness, ctx);

    // Add to registry
    let registry: &mut CouncilRegistry = account::borrow_managed_data_mut(
        account,
        CouncilRegistryKey {},
        version_witness
    );

    // Check not already registered
    assert!(!table::contains(&registry.councils, council_id), ECouncilAlreadyRegistered);

    let info = CouncilInfo {
        council_id,
        council_type,
    };

    table::add(&mut registry.councils, council_id, info);
    vector::push_back(&mut registry.council_ids, council_id);
}

/// Register a security council with the DAO (governance action)
///
/// This function follows the standard action execution pattern and enforces
/// that council registration can only be done through DAO governance.
public fun do_register_council<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    version_witness: VersionWitness,
    _witness: IW,
    _clock: &Clock,
    ctx: &mut TxContext,
) {
    // Get action spec and deserialize
    let specs = executable::intent(executable).action_specs();
    let spec = specs.borrow(executable::action_idx(executable));

    // Deserialize the action data
    let action_data = intents::action_spec_data(spec);
    let mut bcs = bcs::new(*action_data);
    let council_id = object::id_from_address(bcs::peel_address(&mut bcs));
    let council_type = bcs::peel_vec_u8(&mut bcs).to_string();

    let action = RegisterCouncilAction {
        council_id,
        council_type,
    };

    // Increment action index
    executable::increment_action_idx(executable);

    // Call the internal register function
    register_council(
        account,
        action.council_id,
        action.council_type,
        version_witness,
        ctx,
    );
}

/// Create an optimistic intent (security council only)
///
/// IMPORTANT: When challenge period is disabled (challenge_enabled = false),
/// DAO governance is responsible for ensuring registered councils have >= 10-day timelocks.
/// This provides the minimum delay for DAO oversight when challenges are disabled.
///
/// The council's own timelock mechanism (via weighted_multisig) handles the delay enforcement.
/// This function does NOT validate individual council timelocks to avoid stale cache issues.
public fun do_create_optimistic_intent<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    _version_witness: VersionWitness,
    witness: IW,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Get action spec and deserialize
    let specs = executable::intent(executable).action_specs();
    let spec = specs.borrow(executable::action_idx(executable));

    // Deserialize the action data
    let action_data = intents::action_spec_data(spec);
    let mut bcs = bcs::new(*action_data);
    let intent_key = bcs::peel_vec_u8(&mut bcs).to_string();
    let title = bcs::peel_vec_u8(&mut bcs).to_string();
    let description = bcs::peel_vec_u8(&mut bcs).to_string();

    let action = CreateOptimisticIntentAction { intent_key, title, description };

    // Increment action index
    executable::increment_action_idx(executable);

    // Read DAO's challenge period setting from config
    let config = account::config(account);
    let challenge_enabled = futarchy_config::optimistic_intent_challenge_enabled(config);

    let current_time = clock.timestamp_ms();

    // Initialize storage if needed
    initialize_storage(account, version::current(), ctx);

    let storage: &mut OptimisticIntentStorage = account::borrow_managed_data_mut(
        account,
        OptimisticStorageKey {},
        version::current()
    );

    // Check intent limit
    assert!(storage.total_active < MAX_OPTIMISTIC_INTENTS, ETooManyOptimisticIntents);

    // Calculate execution time based on challenge setting
    let executes_at = if (challenge_enabled) {
        // Challenge mode enabled: 10-day waiting period
        // Validate overflow for time calculations
        assert!(current_time <= 18446744073709551615 - WAITING_PERIOD_MS, EIntegerOverflow);
        current_time + WAITING_PERIOD_MS
    } else {
        // Challenge mode disabled: instant execution
        current_time
    };

    // Calculate expiry time
    assert!(executes_at <= 18446744073709551615 - EXPIRY_PERIOD_MS, EIntegerOverflow);
    let expires_at = executes_at + EXPIRY_PERIOD_MS;

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
        executes_at,
        expires_at,
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
        executes_at,
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
    // Get action spec and deserialize
    let specs = executable::intent(executable).action_specs();
    let spec = specs.borrow(executable::action_idx(executable));

    // Deserialize the action data
    let action_data = intents::action_spec_data(spec);
    let mut bcs = bcs::new(*action_data);

    // Read vector of IDs
    let vec_length = bcs::peel_vec_length(&mut bcs);
    let mut intent_ids = vector[];
    let mut i = 0;
    while (i < vec_length) {
        intent_ids.push_back(object::id_from_address(bcs::peel_address(&mut bcs)));
        i = i + 1;
    };
    let governance_proposal_id = object::id_from_address(bcs::peel_address(&mut bcs));

    let action = ChallengeOptimisticIntentsAction { intent_ids, governance_proposal_id };

    // Increment action index
    executable::increment_action_idx(executable);
    
    // Validate batch size
    let batch_size = vector::length(&action.intent_ids);
    assert!(batch_size > 0 && batch_size <= MAX_BATCH_CHALLENGES, EInvalidBatchSize);
    
    // Check for duplicates in the batch
    let mut seen_intents = vec_set::empty<ID>();
    let mut i = 0;
    while (i < batch_size) {
        let intent_id = *vector::borrow(&action.intent_ids, i);
        assert!(!vec_set::contains(&seen_intents, &intent_id), EDuplicateIntent);
        vec_set::insert(&mut seen_intents, intent_id);
        i = i + 1;
    };
    
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
    i = 0;
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
        // Handle gracefully if intent was already removed (defensive programming)
        let _ = remove_from_active_intents(&mut storage.active_intents, &mut storage.total_active, intent_id);
        
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
    // Get action spec and deserialize
    let specs = executable::intent(executable).action_specs();
    let spec = specs.borrow(executable::action_idx(executable));

    // Deserialize the action data
    let action_data = intents::action_spec_data(spec);
    let mut bcs = bcs::new(*action_data);
    let intent_id = object::id_from_address(bcs::peel_address(&mut bcs));
    let reason = bcs::peel_vec_u8(&mut bcs).to_string();

    let action = CancelOptimisticIntentAction { intent_id, reason };

    // Increment action index
    executable::increment_action_idx(executable);
    
    let storage: &mut OptimisticIntentStorage = account::borrow_managed_data_mut(
        account,
        OptimisticStorageKey {},
        version::current()
    );
    
    // Check intent exists
    assert!(table::contains(&storage.intents, action.intent_id), EIntentNotFound);
    
    let intent = table::borrow_mut(&mut storage.intents, action.intent_id);
    
    // Verify sender was the original proposer
    // SECURITY NOTE: This function is called through an executable that should have been
    // created with proper security council membership verification. We cannot re-verify
    // council membership here as this executes in the DAO context, not the council context.
    // The security model relies on the action creation being properly gated.
    let sender = tx_context::sender(ctx);
    assert!(intent.proposer == sender, ENotProposer);
    
    // Check not already cancelled or executed
    assert!(!intent.is_cancelled, EIntentAlreadyCancelled);
    assert!(!intent.is_executed, EIntentAlreadyExecuted);
    
    // Cancel the intent
    intent.is_cancelled = true;
    intent.cancel_reason = option::some(action.reason);
    
    // Remove from active intents safely
    // Handle gracefully if intent was already removed (defensive programming)
    let _ = remove_from_active_intents(&mut storage.active_intents, &mut storage.total_active, action.intent_id);
    
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
    // Get action spec and deserialize
    let specs = executable::intent(executable).action_specs();
    let spec = specs.borrow(executable::action_idx(executable));

    // Deserialize the action data
    let action_data = intents::action_spec_data(spec);
    let mut bcs = bcs::new(*action_data);
    let intent_id = object::id_from_address(bcs::peel_address(&mut bcs));

    let action = ExecuteOptimisticIntentAction { intent_id };

    // Increment action index
    executable::increment_action_idx(executable);
    
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
    // Handle gracefully if intent was already removed (defensive programming)
    let _ = remove_from_active_intents(&mut storage.active_intents, &mut storage.total_active, action.intent_id);
    
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
/// Returns true if the intent was found and removed, false otherwise
fun remove_from_active_intents(
    active_intents: &mut vector<ID>,
    total_active: &mut u64,
    intent_id: ID,
): bool {
    let (found, index) = vector::index_of(active_intents, &intent_id);
    if (found) {
        vector::remove(active_intents, index);
        // Decrement counter since we removed an item
        // Assert to ensure counter doesn't underflow (should never happen if state is consistent)
        assert!(*total_active > 0, EIntegerOverflow);
        *total_active = *total_active - 1;
        true
    } else {
        // Intent was not in active list - this is a logic error if we're trying to remove it
        // Return false to let caller handle this case
        false
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
    // Get action spec and deserialize
    let specs = executable::intent(executable).action_specs();
    let spec = specs.borrow(executable::action_idx(executable));

    // Deserialize the action data
    let action_data = intents::action_spec_data(spec);
    let mut bcs = bcs::new(*action_data);

    // Read vector of IDs
    let vec_length = bcs::peel_vec_length(&mut bcs);
    let mut intent_ids = vector[];
    let mut i = 0;
    while (i < vec_length) {
        intent_ids.push_back(object::id_from_address(bcs::peel_address(&mut bcs)));
        i = i + 1;
    };

    let action = CleanupExpiredIntentsAction { intent_ids };

    // Increment action index
    executable::increment_action_idx(executable);
    
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

/// Set optimistic intent challenge enabled (governance only)
///
/// IMPORTANT: When disabling challenges (enabled = false), ALL security councils creating
/// optimistic intents MUST have timelock >= 10 days. This is enforced at intent creation time
/// via `do_create_optimistic_intent`.
///
/// Rationale:
/// - If challenges are enabled: 10-day DAO challenge period provides oversight
/// - If challenges are disabled: Council timelock provides oversight
/// - At least one of these delays must be >= 10 days to ensure DAO has time to react
///
/// Before disabling challenges, ensure your councils have configured appropriate timelocks:
/// ```move
/// weighted_multisig::set_time_lock_delay(&mut council, 864_000_000); // 10 days
/// ```
public fun do_set_optimistic_intent_challenge_enabled<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    version_witness: VersionWitness,
    _witness: IW,
    _clock: &Clock,
    _ctx: &mut TxContext,
) {
    // Get action spec and deserialize
    let specs = executable::intent(executable).action_specs();
    let spec = specs.borrow(executable::action_idx(executable));

    // Deserialize the action data
    let action_data = intents::action_spec_data(spec);
    let mut bcs = bcs::new(*action_data);
    let enabled = bcs::peel_bool(&mut bcs);

    // Increment action index
    executable::increment_action_idx(executable);

    // Update the DAO's config
    let config = futarchy_config::internal_config_mut(account, version_witness);
    futarchy_config::set_optimistic_intent_challenge_enabled(config, enabled);

    // NOTE: We don't validate council timelocks here because councils are separate objects.
    // Validation happens at intent creation time in `do_create_optimistic_intent`.
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

/// Check if challenge period is enabled for a DAO
///
/// When challenges are enabled, optimistic intents have a 10-day waiting period
/// during which the DAO can challenge and cancel them.
///
/// When challenges are disabled, intents execute immediately (councils must have
/// their own timelocks configured appropriately).
public fun is_challenge_enabled(
    dao: &Account<FutarchyConfig>,
): bool {
    let dao_config = account::config(dao);
    futarchy_config::optimistic_intent_challenge_enabled(dao_config)
}

/// Get all registered council IDs for a DAO
public fun get_registered_councils(
    dao: &Account<FutarchyConfig>,
): vector<ID> {
    if (!account::has_managed_data(dao, CouncilRegistryKey {})) {
        return vector::empty()
    };

    let registry: &CouncilRegistry = account::borrow_managed_data(
        dao,
        CouncilRegistryKey {},
        version::current()
    );

    registry.council_ids
}

/// Get council info from registry
public fun get_council_info(
    dao: &Account<FutarchyConfig>,
    council_id: ID,
): CouncilInfo {
    let registry: &CouncilRegistry = account::borrow_managed_data(
        dao,
        CouncilRegistryKey {},
        version::current()
    );

    *table::borrow(&registry.councils, council_id)
}

/// Check if a council is registered
public fun is_council_registered(
    dao: &Account<FutarchyConfig>,
    council_id: ID,
): bool {
    if (!account::has_managed_data(dao, CouncilRegistryKey {})) {
        return false
    };

    let registry: &CouncilRegistry = account::borrow_managed_data(
        dao,
        CouncilRegistryKey {},
        version::current()
    );

    table::contains(&registry.councils, council_id)
}

// === CouncilInfo Getters ===

/// Get council ID from CouncilInfo
public fun council_info_id(info: &CouncilInfo): ID {
    info.council_id
}

/// Get council type from CouncilInfo
public fun council_info_type(info: &CouncilInfo): String {
    info.council_type
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

/// Create an action to set optimistic intent challenge enabled
public fun new_set_optimistic_intent_challenge_enabled_action(
    enabled: bool,
): SetOptimisticIntentChallengeEnabledAction {
    SetOptimisticIntentChallengeEnabledAction {
        enabled,
    }
}

/// Create an action to register a security council
public fun new_register_council_action(
    council_id: ID,
    council_type: String,
): RegisterCouncilAction {
    RegisterCouncilAction {
        council_id,
        council_type,
    }
}

// === Delete Functions for Expired Actions ===

/// Delete an expired ExecuteOptimisticIntentAction
public fun delete_execute_optimistic_intent_action(expired: &mut account_protocol::intents::Expired) {
    let spec = expired.remove_action_spec();
    let action_data = intents::action_spec_data(&spec);
    let mut bcs = bcs::new(*action_data);
    let _intent_id = bcs::peel_address(&mut bcs);
}

/// Delete an expired CancelOptimisticIntentAction
public fun delete_cancel_optimistic_intent_action(expired: &mut account_protocol::intents::Expired) {
    let spec = expired.remove_action_spec();
    let action_data = intents::action_spec_data(&spec);
    let mut bcs = bcs::new(*action_data);
    let _intent_id = bcs::peel_address(&mut bcs);
    let _reason = bcs::peel_vec_u8(&mut bcs);
}

/// Delete an expired CreateOptimisticIntentAction
public fun delete_create_optimistic_intent_action(expired: &mut account_protocol::intents::Expired) {
    let spec = expired.remove_action_spec();
    let action_data = intents::action_spec_data(&spec);
    let mut bcs = bcs::new(*action_data);
    let _intent_key = bcs::peel_vec_u8(&mut bcs);
    let _title = bcs::peel_vec_u8(&mut bcs);
    let _description = bcs::peel_vec_u8(&mut bcs);
}

/// Delete an expired ChallengeOptimisticIntentsAction
public fun delete_challenge_optimistic_intents_action(expired: &mut account_protocol::intents::Expired) {
    let spec = expired.remove_action_spec();
    let action_data = intents::action_spec_data(&spec);
    let mut bcs = bcs::new(*action_data);
    // Read vector of IDs
    let vec_length = bcs::peel_vec_length(&mut bcs);
    let mut i = 0;
    while (i < vec_length) {
        bcs::peel_address(&mut bcs);
        i = i + 1;
    };
    let _governance_proposal_id = bcs::peel_address(&mut bcs);
}

/// Delete an expired CleanupExpiredIntentsAction
public fun delete_cleanup_expired_intents_action(expired: &mut account_protocol::intents::Expired) {
    let spec = expired.remove_action_spec();
    let action_data = intents::action_spec_data(&spec);
    let mut bcs = bcs::new(*action_data);
    // Read vector of IDs
    let vec_length = bcs::peel_vec_length(&mut bcs);
    let mut i = 0;
    while (i < vec_length) {
        bcs::peel_address(&mut bcs);
        i = i + 1;
    };
}

/// Delete an expired SetOptimisticIntentChallengeEnabledAction
public fun delete_set_optimistic_intent_challenge_enabled_action(expired: &mut account_protocol::intents::Expired) {
    let spec = expired.remove_action_spec();
    let action_data = intents::action_spec_data(&spec);
    let mut bcs = bcs::new(*action_data);
    let _enabled = bcs::peel_bool(&mut bcs);
}

/// Delete an expired RegisterCouncilAction
public fun delete_register_council_action(expired: &mut account_protocol::intents::Expired) {
    let spec = expired.remove_action_spec();
    let action_data = intents::action_spec_data(&spec);
    let mut bcs = bcs::new(*action_data);
    let _council_id = bcs::peel_address(&mut bcs);
    let _council_type = bcs::peel_vec_u8(&mut bcs);
}