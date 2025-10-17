// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

/// Public cleanup functions for expired intents
/// Sui's storage rebate system naturally incentivizes cleanup -
/// cleaners get the storage deposit back when deleting objects
module futarchy_governance::intent_janitor;

use account_protocol::account::{Self, Account};
use account_protocol::intents::{Self, Expired};
use futarchy_actions::config_actions;
use futarchy_core::futarchy_config::{Self, FutarchyConfig};
use futarchy_core::version;
use std::string::{Self as string, String};
use sui::clock::Clock;
use sui::event;
use sui::table::{Self, Table};

// === Constants ===

/// Maximum intents that can be cleaned in one call to prevent gas exhaustion
const MAX_CLEANUP_PER_CALL: u64 = 20;

// === Errors ===

const ENoExpiredIntents: u64 = 1;
const ECleanupLimitExceeded: u64 = 2;

// === Types ===

/// Index for tracking created intents to enable cleanup
public struct IntentIndex has store {
    /// Vector of all intent keys that have been created
    keys: vector<String>,
    /// Map from intent key to expiration time for quick lookup
    expiration_times: Table<String, u64>,
    /// Current scan position for round-robin cleanup
    scan_position: u64,
}

/// Key for storing the intent index in managed data
public struct IntentIndexKey has copy, drop, store {}

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
        let mut intent_key_opt = find_next_expired_intent(account, clock, ctx);
        if (intent_key_opt.is_none()) {
            break // No more expired intents
        };

        let intent_key = intent_key_opt.extract();

        // Try to delete it as FutarchyOutcome type
        if (try_delete_expired_futarchy_intent(account, intent_key, clock, ctx)) {
            cleaned = cleaned + 1;
        } else {};
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
public fun cleanup_all_expired_intents(
    account: &mut Account<FutarchyConfig>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Keep cleaning until no more expired intents are found
    loop {
        let mut intent_key_opt = find_next_expired_intent(account, clock, ctx);
        if (intent_key_opt.is_none()) {
            break
        };

        let intent_key = intent_key_opt.extract();

        // Try to delete it - continue even if this specific one fails
        // (might be wrong type or other issue)
        try_delete_expired_futarchy_intent(account, intent_key, clock, ctx);
    };
}

/// Clean up expired intents with a limit (for bounded operations)
/// Called automatically during proposal finalization and execution
public(package) fun cleanup_expired_intents_automatic(
    account: &mut Account<FutarchyConfig>,
    max_to_clean: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let mut cleaned = 0u64;

    while (cleaned < max_to_clean) {
        let mut intent_key_opt = find_next_expired_intent(account, clock, ctx);
        if (intent_key_opt.is_none()) {
            break
        };

        let intent_key = intent_key_opt.extract();

        if (try_delete_expired_futarchy_intent(account, intent_key, clock, ctx)) {
            cleaned = cleaned + 1;
        };
    };
}

/// Check if maintenance is needed and emit event if so
public fun check_maintenance_needed(account: &Account<FutarchyConfig>, clock: &Clock) {
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

/// Get or initialize the intent index
fun get_or_init_intent_index(
    account: &mut Account<FutarchyConfig>,
    ctx: &mut TxContext,
): &mut IntentIndex {
    // Initialize if doesn't exist
    if (!account::has_managed_data(account, IntentIndexKey {})) {
        let index = IntentIndex {
            keys: vector::empty(),
            expiration_times: table::new(ctx),
            scan_position: 0,
        };
        account::add_managed_data(
            account,
            IntentIndexKey {},
            index,
            version::current(),
        );
    };

    account::borrow_managed_data_mut(
        account,
        IntentIndexKey {},
        version::current(),
    )
}

/// Add an intent to the index when it's created
public(package) fun register_intent(
    account: &mut Account<FutarchyConfig>,
    key: String,
    expiration_time: u64,
    ctx: &mut TxContext,
) {
    let index = get_or_init_intent_index(account, ctx);
    vector::push_back(&mut index.keys, key);
    table::add(&mut index.expiration_times, key, expiration_time);
}

/// Find the next expired intent key
fun find_next_expired_intent(
    account: &mut Account<FutarchyConfig>,
    clock: &Clock,
    ctx: &mut TxContext,
): Option<String> {
    // Get the index
    let index = get_or_init_intent_index(account, ctx);

    let current_time = clock.timestamp_ms();
    let keys = &index.keys;
    let expiration_times = &index.expiration_times;
    let len = vector::length(keys);

    if (len == 0) {
        return option::none()
    };

    // Start from last scan position for round-robin
    let mut checked = 0;
    let mut pos = index.scan_position;

    while (checked < len) {
        if (pos >= len) {
            pos = 0; // Wrap around
        };

        let key = vector::borrow(keys, pos);

        // Check if this intent is expired
        if (table::contains(expiration_times, *key)) {
            let expiry = *table::borrow(expiration_times, *key);
            if (current_time >= expiry) {
                // Update scan position for next call
                index.scan_position = pos + 1;
                return option::some(*key)
            }
        };

        pos = pos + 1;
        checked = checked + 1;
    };

    option::none()
}

/// Try to delete an expired FutarchyOutcome intent
fun try_delete_expired_futarchy_intent(
    account: &mut Account<FutarchyConfig>,
    key: String,
    clock: &Clock,
    ctx: &mut TxContext,
): bool {
    // Check if intent exists and is expired
    let intents_store = account::intents(account);
    if (!intents::contains(intents_store, key)) {
        return false
    };

    let key_for_index = string::clone(&key);
    let expired = account::delete_expired_intent<FutarchyConfig, FutarchyOutcome>(
        account,
        key,
        clock,
    );
    destroy_expired(expired);
    
    remove_from_index(account, key_for_index, ctx);
    
    true
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

/// Count expired intents
fun count_expired_intents(account: &Account<FutarchyConfig>, clock: &Clock): u64 {
    // Check if index exists
    if (!account::has_managed_data(account, IntentIndexKey {})) {
        return 0
    };

    let index: &IntentIndex = account::borrow_managed_data(
        account,
        IntentIndexKey {},
        version::current(),
    );

    let current_time = clock.timestamp_ms();
    let mut count = 0u64;
    let keys = &index.keys;
    let expiration_times = &index.expiration_times;
    let len = vector::length(keys);

    let mut i = 0;
    while (i < len && i < 100) {
        // Limit scan to prevent gas exhaustion
        let key = vector::borrow(keys, i);
        if (table::contains(expiration_times, *key)) {
            let expiry = *table::borrow(expiration_times, *key);
            if (current_time >= expiry) {
                count = count + 1;
            }
        };
        i = i + 1;
    };

    count
}

/// Remove an intent from the index after deletion
fun remove_from_index(account: &mut Account<FutarchyConfig>, key: String, ctx: &mut TxContext) {
    let index = get_or_init_intent_index(account, ctx);

    // Remove from expiration times table
    if (table::contains(&index.expiration_times, key)) {
        table::remove(&mut index.expiration_times, key);
    };

    // Remove from keys vector (expensive but necessary)
    let keys = &mut index.keys;
    let len = vector::length(keys);
    let mut i = 0;

    while (i < len) {
        if (*vector::borrow(keys, i) == key) {
            vector::swap_remove(keys, i);

            // Adjust scan position if needed
            if (index.scan_position > i) {
                index.scan_position = index.scan_position - 1;
            };
            break
        };
        i = i + 1;
    };
}
