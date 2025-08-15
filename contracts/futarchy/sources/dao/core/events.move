module futarchy::events;

use std::string::String;
use sui::event;

public struct IntentCreated has copy, drop { 
    key: String, 
    role: String, 
    when_ms: u64 
}

public struct IntentExecuted has copy, drop { 
    key: String, 
    role: String, 
    when_ms: u64 
}

public struct IntentCleaned has copy, drop { 
    key: String, 
    role: String, 
    when_ms: u64 
}

public fun emit_created(key: String, role: String, when_ms: u64) {
    event::emit(IntentCreated { key, role, when_ms })
}

public fun emit_executed(key: String, role: String, when_ms: u64) {
    event::emit(IntentExecuted { key, role, when_ms })
}

public fun emit_cleaned(key: String, role: String, when_ms: u64) {
    event::emit(IntentCleaned { key, role, when_ms })
}