/// Comprehensive tests for events module
#[test_only]
module futarchy_core::events_tests;

use futarchy_core::events;
use std::string;

#[test]
fun test_emit_created_basic() {
    let key = string::utf8(b"test_key");
    let proposal = @0xABCD;
    let outcome_index = 0;
    let when_ms = 1000;

    // Should not abort - just emits event
    events::emit_created(key, proposal, outcome_index, when_ms);
}

#[test]
fun test_emit_executed_basic() {
    let key = string::utf8(b"test_key");
    let proposal = @0xABCD;
    let outcome_index = 1;
    let when_ms = 2000;

    events::emit_executed(key, proposal, outcome_index, when_ms);
}

#[test]
fun test_emit_cancelled_basic() {
    let proposal = @0xABCD;
    let outcome_index = 0;
    let key_hash = b"hash123";
    let reason = 0; // CANCEL_EXPIRED
    let when_ms = 3000;

    events::emit_cancelled(proposal, outcome_index, key_hash, reason, when_ms);
}

#[test]
fun test_emit_created_with_empty_key() {
    let key = string::utf8(b"");
    let proposal = @0x0;
    let outcome_index = 0;
    let when_ms = 0;

    events::emit_created(key, proposal, outcome_index, when_ms);
}

#[test]
fun test_emit_executed_with_large_outcome_index() {
    let key = string::utf8(b"outcome_999");
    let proposal = @0xFFFF;
    let outcome_index = 999;
    let when_ms = 99999999;

    events::emit_executed(key, proposal, outcome_index, when_ms);
}

#[test]
fun test_emit_cancelled_reason_expired() {
    let proposal = @0x1234;
    let outcome_index = 0;
    let key_hash = b"expired_hash";
    let reason = 0; // CANCEL_EXPIRED
    let when_ms = 1000;

    events::emit_cancelled(proposal, outcome_index, key_hash, reason, when_ms);
}

#[test]
fun test_emit_cancelled_reason_losing_outcome() {
    let proposal = @0x1234;
    let outcome_index = 1;
    let key_hash = b"losing_hash";
    let reason = 1; // CANCEL_LOSING_OUTCOME
    let when_ms = 2000;

    events::emit_cancelled(proposal, outcome_index, key_hash, reason, when_ms);
}

#[test]
fun test_emit_cancelled_reason_admin() {
    let proposal = @0x1234;
    let outcome_index = 2;
    let key_hash = b"admin_hash";
    let reason = 2; // CANCEL_ADMIN
    let when_ms = 3000;

    events::emit_cancelled(proposal, outcome_index, key_hash, reason, when_ms);
}

#[test]
fun test_emit_cancelled_reason_superseded() {
    let proposal = @0x1234;
    let outcome_index = 3;
    let key_hash = b"superseded_hash";
    let reason = 3; // CANCEL_SUPERSEDED
    let when_ms = 4000;

    events::emit_cancelled(proposal, outcome_index, key_hash, reason, when_ms);
}

#[test]
fun test_emit_cancelled_empty_key_hash() {
    let proposal = @0x5678;
    let outcome_index = 0;
    let key_hash = vector::empty<u8>();
    let reason = 0;
    let when_ms = 5000;

    events::emit_cancelled(proposal, outcome_index, key_hash, reason, when_ms);
}

#[test]
fun test_emit_cancelled_large_key_hash() {
    let proposal = @0x9ABC;
    let outcome_index = 0;
    // Create a large hash
    let mut key_hash = vector::empty<u8>();
    let mut i = 0;
    while (i < 100) {
        vector::push_back(&mut key_hash, (i as u8));
        i = i + 1;
    };
    let reason = 1;
    let when_ms = 6000;

    events::emit_cancelled(proposal, outcome_index, key_hash, reason, when_ms);
}

#[test]
fun test_emit_multiple_events_sequence() {
    // Simulate a complete lifecycle
    let key = string::utf8(b"lifecycle_test");
    let proposal = @0xDEAD;
    let outcome_index = 0;

    // Created
    events::emit_created(key, proposal, outcome_index, 1000);

    // Executed
    events::emit_executed(key, proposal, outcome_index, 2000);

    // Later cancelled (different outcome)
    events::emit_cancelled(proposal, 1, b"cancelled", 1, 3000);
}

#[test]
fun test_emit_created_long_key() {
    let key = string::utf8(
        b"this_is_a_very_long_key_name_that_might_be_used_in_production_environments_to_identify_complex_actions",
    );
    let proposal = @0xBEEF;
    let outcome_index = 42;
    let when_ms = 123456789;

    events::emit_created(key, proposal, outcome_index, when_ms);
}

#[test]
fun test_emit_events_with_special_addresses() {
    let key = string::utf8(b"special");

    // All zeros
    events::emit_created(key, @0x0, 0, 1000);

    // All FFs
    events::emit_executed(
        key,
        @0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF,
        0,
        2000,
    );
}

#[test]
fun test_emit_cancelled_all_reason_codes() {
    let proposal = @0xCAFE;
    let outcome_index = 0;
    let key_hash = b"test";
    let when_ms = 1000;

    // Test all reason codes 0-3
    events::emit_cancelled(proposal, outcome_index, key_hash, 0, when_ms);
    events::emit_cancelled(proposal, outcome_index, key_hash, 1, when_ms);
    events::emit_cancelled(proposal, outcome_index, key_hash, 2, when_ms);
    events::emit_cancelled(proposal, outcome_index, key_hash, 3, when_ms);
}
