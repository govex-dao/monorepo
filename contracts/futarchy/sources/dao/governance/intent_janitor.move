/// Public cleanup functions for expired intents
/// Sui's storage rebate system naturally incentivizes cleanup - 
/// cleaners get the storage deposit back when deleting objects
module futarchy::intent_janitor;

use std::string::String;
use sui::{
    clock::Clock,
    event,
};
use account_protocol::{
    account::{Self, Account},
    intents::{Self, Expired},
};
use futarchy::{
    futarchy_config::{Self, FutarchyConfig, FutarchyOutcome},
    config_actions,
    version,
};

// === Constants ===

/// Maximum intents that can be cleaned in one call to prevent gas exhaustion
const MAX_CLEANUP_PER_CALL: u64 = 20;

// === Errors ===

const ENoExpiredIntents: u64 = 1;
const ECleanupLimitExceeded: u64 = 2;

// === Events ===

/// Emitted when intents are cleaned
public struct IntentsCleaned has copy, drop {
    dao_id: ID,
    cleaner: address,
    count: u64,
    timestamp: u64,
}

/// Emitted when maintenance is needed
public struct MaintenanceNeeded has copy, drop {
    dao_id: ID,
    expired_count: u64,
    timestamp: u64,
}

// === Public Functions ===

/// Clean up expired FutarchyOutcome intents
/// Sui's storage rebate naturally rewards cleaners
public fun cleanup_expired_futarchy_intents(
    account: &mut Account<FutarchyConfig>,
    max_to_clean: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(max_to_clean <= MAX_CLEANUP_PER_CALL, ECleanupLimitExceeded);
    
    let mut cleaned = 0u64;
    let dao_id = object::id(account);
    let cleaner = ctx.sender();
    
    // Try to clean up to max_to_clean intents
    while (cleaned < max_to_clean) {
        // Find next expired intent
        let mut intent_key_opt = find_next_expired_intent(account, clock);
        if (intent_key_opt.is_none()) {
            break // No more expired intents
        };
        
        let intent_key = intent_key_opt.extract();
        
        // Try to delete it as FutarchyOutcome type
        if (try_delete_expired_futarchy_intent(account, intent_key, clock)) {
            cleaned = cleaned + 1;
        } else {
            // Could not delete this intent (wrong type or not expired)
            // Continue to next one
        };
    };
    
    assert!(cleaned > 0, ENoExpiredIntents);
    
    // Emit event
    event::emit(IntentsCleaned {
        dao_id,
        cleaner,
        count: cleaned,
        timestamp: clock.timestamp_ms(),
    });
}

/// Clean up ALL expired intents during normal operations (no reward)
/// Called automatically during proposal finalization and execution
public(package) fun cleanup_all_expired_intents(
    account: &mut Account<FutarchyConfig>,
    clock: &Clock,
) {
    // Keep cleaning until no more expired intents are found
    loop {
        let mut intent_key_opt = find_next_expired_intent(account, clock);
        if (intent_key_opt.is_none()) {
            break
        };
        
        let intent_key = intent_key_opt.extract();
        
        // Try to delete it - continue even if this specific one fails
        // (might be wrong type or other issue)
        try_delete_expired_futarchy_intent(account, intent_key, clock);
    };
}

/// Clean up expired intents with a limit (for bounded operations)
/// Called automatically during proposal finalization and execution
public(package) fun cleanup_expired_intents_automatic(
    account: &mut Account<FutarchyConfig>,
    max_to_clean: u64,
    clock: &Clock,
) {
    let mut cleaned = 0u64;
    
    while (cleaned < max_to_clean) {
        let mut intent_key_opt = find_next_expired_intent(account, clock);
        if (intent_key_opt.is_none()) {
            break
        };
        
        let intent_key = intent_key_opt.extract();
        
        if (try_delete_expired_futarchy_intent(account, intent_key, clock)) {
            cleaned = cleaned + 1;
        };
    };
}

/// Check if maintenance is needed and emit event if so
public fun check_maintenance_needed(
    account: &Account<FutarchyConfig>,
    clock: &Clock,
) {
    let expired_count = count_expired_intents(account, clock);
    
    if (expired_count > 10) {
        event::emit(MaintenanceNeeded {
            dao_id: object::id(account),
            expired_count,
            timestamp: clock.timestamp_ms(),
        });
    }
}

// === Internal Functions ===

/// Find the next expired intent key
fun find_next_expired_intent(
    account: &Account<FutarchyConfig>,
    clock: &Clock,
): Option<String> {
    // This is a simplified version - in reality we'd need to iterate through intents
    // For now, return none to indicate no implementation
    option::none()
}

/// Try to delete an expired FutarchyOutcome intent
fun try_delete_expired_futarchy_intent(
    account: &mut Account<FutarchyConfig>,
    key: String,
    clock: &Clock,
): bool {
    // Check if intent exists and is expired
    let intents_store = account::intents(account);
    if (!intents::contains(intents_store, key)) {
        return false
    };
    
    // Try to delete as FutarchyOutcome type
    // This will fail if the intent has a different outcome type
    let can_delete = {
        let intent = intents::get<FutarchyOutcome>(intents_store, key);
        clock.timestamp_ms() >= intents::expiration_time(intent)
    };
    
    if (can_delete) {
        let expired = account::delete_expired_intent<FutarchyConfig, FutarchyOutcome>(
            account,
            key,
            clock
        );
        destroy_expired(expired);
        true
    } else {
        false
    }
}

/// Destroy an expired intent after removing all actions
fun destroy_expired(expired: Expired) {
    // For now, we can't generically remove actions from Expired
    // This would require knowing all possible action types
    // Instead, we'll just destroy it if it's already empty
    // or abort if it has actions (shouldn't happen with FutarchyOutcome)
    
    // Destroy the expired intent (will abort if not empty)
    intents::destroy_empty_expired(expired);
}

/// Count expired intents (simplified version)
fun count_expired_intents(
    account: &Account<FutarchyConfig>,
    clock: &Clock,
): u64 {
    // This would need to iterate through all intents and count expired ones
    // For now, return 0 as placeholder
    0
}