#[test_only]
module futarchy_core::resource_requests_tests;

use futarchy_core::resource_requests::{Self, ResourceRequest, ResourceReceipt};
use std::string;
use sui::object;
use sui::test_scenario as ts;

const ADMIN: address = @0xAD;

// Test action types
public struct CreatePoolAction has drop {}
public struct AddLiquidityAction has drop, store {}
public struct MintTokensAction has drop, store {}

// Complex action with fields
public struct ComplexAction has store, drop {
    amount: u64,
    recipient: address,
}

// === Basic Request Creation Tests ===

#[test]
fun test_new_request_basic() {
    let mut scenario = ts::begin(ADMIN);

    let request: ResourceRequest<CreatePoolAction> = resource_requests::new_request(ts::ctx(&mut scenario));

    let request_id = resource_requests::request_id(&request);
    assert!(object::id_to_address(&request_id) != @0x0, 0);

    resource_requests::fulfill(request);
    ts::end(scenario);
}

#[test]
fun test_new_request_different_types_have_different_ids() {
    let mut scenario = ts::begin(ADMIN);

    let request1: ResourceRequest<CreatePoolAction> = resource_requests::new_request(ts::ctx(&mut scenario));
    let request2: ResourceRequest<AddLiquidityAction> = resource_requests::new_request(ts::ctx(&mut scenario));

    let id1 = resource_requests::request_id(&request1);
    let id2 = resource_requests::request_id(&request2);

    assert!(id1 != id2, 0);

    resource_requests::fulfill(request1);
    resource_requests::fulfill(request2);
    ts::end(scenario);
}

// === Context Storage Tests ===

#[test]
fun test_add_and_get_context() {
    let mut scenario = ts::begin(ADMIN);

    let mut request: ResourceRequest<CreatePoolAction> = resource_requests::new_request(ts::ctx(&mut scenario));

    resource_requests::add_context(&mut request, string::utf8(b"amount"), 1000000u64);
    resource_requests::add_context(&mut request, string::utf8(b"recipient"), @0xCAFE);

    let amount: u64 = resource_requests::get_context(&request, string::utf8(b"amount"));
    let recipient: address = resource_requests::get_context(&request, string::utf8(b"recipient"));

    assert!(amount == 1000000, 0);
    assert!(recipient == @0xCAFE, 1);

    resource_requests::fulfill(request);
    ts::end(scenario);
}

#[test]
fun test_has_context() {
    let mut scenario = ts::begin(ADMIN);

    let mut request: ResourceRequest<CreatePoolAction> = resource_requests::new_request(ts::ctx(&mut scenario));

    assert!(!resource_requests::has_context(&request, string::utf8(b"amount")), 0);

    resource_requests::add_context(&mut request, string::utf8(b"amount"), 1000000u64);

    assert!(resource_requests::has_context(&request, string::utf8(b"amount")), 1);
    assert!(!resource_requests::has_context(&request, string::utf8(b"other")), 2);

    resource_requests::fulfill(request);
    ts::end(scenario);
}

#[test]
fun test_take_context() {
    let mut scenario = ts::begin(ADMIN);

    let mut request: ResourceRequest<CreatePoolAction> = resource_requests::new_request(ts::ctx(&mut scenario));

    resource_requests::add_context(&mut request, string::utf8(b"amount"), 1000000u64);

    // Take the value (removes from context)
    let amount: u64 = resource_requests::take_context(&mut request, string::utf8(b"amount"));
    assert!(amount == 1000000, 0);

    // Should no longer exist
    assert!(!resource_requests::has_context(&request, string::utf8(b"amount")), 1);

    resource_requests::fulfill(request);
    ts::end(scenario);
}

#[test]
fun test_multiple_context_values() {
    let mut scenario = ts::begin(ADMIN);

    let mut request: ResourceRequest<CreatePoolAction> = resource_requests::new_request(ts::ctx(&mut scenario));

    // Add multiple values of different types
    resource_requests::add_context(&mut request, string::utf8(b"amount"), 1000000u64);
    resource_requests::add_context(&mut request, string::utf8(b"recipient"), @0xCAFE);
    resource_requests::add_context(&mut request, string::utf8(b"description"), string::utf8(b"Test pool"));

    // Get all values
    let amount: u64 = resource_requests::get_context(&request, string::utf8(b"amount"));
    let recipient: address = resource_requests::get_context(&request, string::utf8(b"recipient"));
    let description: string::String = resource_requests::get_context(&request, string::utf8(b"description"));

    assert!(amount == 1000000, 0);
    assert!(recipient == @0xCAFE, 1);
    assert!(description == string::utf8(b"Test pool"), 2);

    resource_requests::fulfill(request);
    ts::end(scenario);
}

// === Fulfill and Receipt Tests ===

#[test]
fun test_fulfill_returns_receipt() {
    let mut scenario = ts::begin(ADMIN);

    let request: ResourceRequest<CreatePoolAction> = resource_requests::new_request(ts::ctx(&mut scenario));
    let request_id = resource_requests::request_id(&request);

    let receipt: ResourceReceipt<CreatePoolAction> = resource_requests::fulfill(request);
    let receipt_id = resource_requests::receipt_id(&receipt);

    assert!(receipt_id == request_id, 0);

    ts::end(scenario);
}

#[test]
fun test_fulfill_with_context() {
    let mut scenario = ts::begin(ADMIN);

    let mut request: ResourceRequest<CreatePoolAction> = resource_requests::new_request(ts::ctx(&mut scenario));

    resource_requests::add_context(&mut request, string::utf8(b"amount"), 1000000u64);

    // Can fulfill even with context still present
    let _receipt = resource_requests::fulfill(request);

    ts::end(scenario);
}

#[test]
fun test_receipt_drops_cleanly() {
    let mut scenario = ts::begin(ADMIN);

    let request: ResourceRequest<CreatePoolAction> = resource_requests::new_request(ts::ctx(&mut scenario));

    let receipt = resource_requests::fulfill(request);

    // Receipt has drop ability, can be ignored
    let _ = receipt;

    ts::end(scenario);
}

// === Action-Specific Helper Tests ===

#[test]
fun test_new_resource_request_with_action() {
    let mut scenario = ts::begin(ADMIN);

    let action = AddLiquidityAction {};

    let request = resource_requests::new_resource_request(action, ts::ctx(&mut scenario));

    // Action is stored in context
    assert!(resource_requests::has_context(&request, string::utf8(b"action")), 0);

    resource_requests::fulfill(request);
    ts::end(scenario);
}

#[test]
fun test_extract_action() {
    let mut scenario = ts::begin(ADMIN);

    let action = AddLiquidityAction {};

    let request = resource_requests::new_resource_request(action, ts::ctx(&mut scenario));

    // Extract the action back
    let extracted_action = resource_requests::extract_action(request);

    // Action extracted successfully (no way to verify content for empty struct, but no abort)
    let _ = extracted_action;

    ts::end(scenario);
}

#[test]
fun test_extract_complex_action() {
    let mut scenario = ts::begin(ADMIN);

    let action = ComplexAction {
        amount: 5000000,
        recipient: @0xBEEF,
    };

    let request = resource_requests::new_resource_request(action, ts::ctx(&mut scenario));

    // Extract the action
    let ComplexAction { amount, recipient } = resource_requests::extract_action(request);

    assert!(amount == 5000000, 0);
    assert!(recipient == @0xBEEF, 1);

    ts::end(scenario);
}

#[test]
fun test_create_receipt_from_action() {
    let action = MintTokensAction {};

    let receipt = resource_requests::create_receipt(action);

    // Receipt created successfully
    let _ = receipt;
}

// === Mutable Context Access Tests ===

#[test]
fun test_context_mut_direct_access() {
    use sui::dynamic_field;

    let mut scenario = ts::begin(ADMIN);

    let mut request: ResourceRequest<CreatePoolAction> = resource_requests::new_request(ts::ctx(&mut scenario));

    // Get mutable UID and add field directly
    let context = resource_requests::context_mut(&mut request);
    dynamic_field::add(context, string::utf8(b"custom"), 999u64);

    // Verify it's there
    assert!(resource_requests::has_context(&request, string::utf8(b"custom")), 0);
    let value: u64 = resource_requests::get_context(&request, string::utf8(b"custom"));
    assert!(value == 999, 1);

    resource_requests::fulfill(request);
    ts::end(scenario);
}

// === Hot Potato Pattern Enforcement ===

// Note: Can't test hot potato enforcement (inability to store/transfer) in Move tests
// The type system enforces this at compile time

// === Type Safety Tests ===

#[test]
fun test_different_action_types_are_distinct() {
    let mut scenario = ts::begin(ADMIN);

    // Create requests for different action types
    let request1: ResourceRequest<CreatePoolAction> = resource_requests::new_request(ts::ctx(&mut scenario));
    let request2: ResourceRequest<AddLiquidityAction> = resource_requests::new_request(ts::ctx(&mut scenario));

    let id1 = resource_requests::request_id(&request1);
    let id2 = resource_requests::request_id(&request2);

    // Different types, different IDs
    assert!(id1 != id2, 0);

    // Fulfilling one type returns that type's receipt
    let receipt1: ResourceReceipt<CreatePoolAction> = resource_requests::fulfill(request1);
    let receipt2: ResourceReceipt<AddLiquidityAction> = resource_requests::fulfill(request2);

    let _ = receipt1;
    let _ = receipt2;

    ts::end(scenario);
}

// === Practical Usage Pattern Tests ===

#[test]
fun test_request_fulfill_pattern() {
    let mut scenario = ts::begin(ADMIN);

    // 1. Action creates request with context
    let mut request: ResourceRequest<CreatePoolAction> = resource_requests::new_request(ts::ctx(&mut scenario));
    resource_requests::add_context(&mut request, string::utf8(b"pool_fee"), 30u64);
    resource_requests::add_context(&mut request, string::utf8(b"initial_price"), 1000000u128);

    // 2. Caller extracts context to fulfill request
    let pool_fee: u64 = resource_requests::take_context(&mut request, string::utf8(b"pool_fee"));
    let initial_price: u128 = resource_requests::take_context(&mut request, string::utf8(b"initial_price"));

    assert!(pool_fee == 30, 0);
    assert!(initial_price == 1000000, 1);

    // 3. After using context, fulfill request
    let _receipt = resource_requests::fulfill(request);

    ts::end(scenario);
}

#[test]
fun test_action_storage_and_extraction_pattern() {
    let mut scenario = ts::begin(ADMIN);

    // 1. Create action
    let action = ComplexAction {
        amount: 10_000_000,
        recipient: @0xDEAD,
    };

    // 2. Store in request
    let request = resource_requests::new_resource_request(action, ts::ctx(&mut scenario));

    // 3. Extract and process
    let ComplexAction { amount, recipient } = resource_requests::extract_action(request);

    assert!(amount == 10_000_000, 0);
    assert!(recipient == @0xDEAD, 1);

    ts::end(scenario);
}

#[test]
fun test_sequential_context_operations() {
    let mut scenario = ts::begin(ADMIN);

    let mut request: ResourceRequest<CreatePoolAction> = resource_requests::new_request(ts::ctx(&mut scenario));

    // Add
    resource_requests::add_context(&mut request, string::utf8(b"step1"), 100u64);

    // Check
    assert!(resource_requests::has_context(&request, string::utf8(b"step1")), 0);

    // Get (read-only)
    let value: u64 = resource_requests::get_context(&request, string::utf8(b"step1"));
    assert!(value == 100, 1);

    // Still there after get
    assert!(resource_requests::has_context(&request, string::utf8(b"step1")), 2);

    // Take (removes)
    let taken: u64 = resource_requests::take_context(&mut request, string::utf8(b"step1"));
    assert!(taken == 100, 3);

    // Gone after take
    assert!(!resource_requests::has_context(&request, string::utf8(b"step1")), 4);

    resource_requests::fulfill(request);
    ts::end(scenario);
}
