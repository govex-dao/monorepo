module futarchy::events;

use std::string::String;
use std::vector;
use sui::event;

/// Reason codes for IntentCancelled
const CANCEL_EXPIRED: u8 = 0;
const CANCEL_LOSING_OUTCOME: u8 = 1;
const CANCEL_ADMIN: u8 = 2;
const CANCEL_SUPERSEDED: u8 = 3;

/// Emitted when an intent is registered (optional, but handy for analytics)
public struct IntentCreated has copy, drop {
    key: String,
    proposal: address,
    outcome_index: u64,
    when_ms: u64
}

/// Emitted when an intent's actions are executed
public struct IntentExecuted has copy, drop {
    key: String,
    proposal: address,
    outcome_index: u64,
    when_ms: u64
}

/// Emitted when an intent is cancelled/cleaned.
/// We emit key_hash instead of key to avoid on-chain leakage.
public struct IntentCancelled has copy, drop {
    proposal: address,
    outcome_index: u64,
    key_hash: vector<u8>,
    reason: u8,
    when_ms: u64
}

public fun emit_created(key: String, proposal: address, outcome_index: u64, when_ms: u64) {
    event::emit(IntentCreated { key, proposal, outcome_index, when_ms })
}

public fun emit_executed(key: String, proposal: address, outcome_index: u64, when_ms: u64) {
    event::emit(IntentExecuted { key, proposal, outcome_index, when_ms })
}

public fun emit_cancelled(
    proposal: address,
    outcome_index: u64,
    key_hash: vector<u8>,
    reason: u8,
    when_ms: u64
) {
    event::emit(IntentCancelled { proposal, outcome_index, key_hash, reason, when_ms })
}