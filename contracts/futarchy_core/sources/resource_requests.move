// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

module futarchy_core::resource_requests;

use std::string::{Self, String};
use std::type_name::{Self, TypeName};
use std::vector;
use sui::dynamic_field;
use sui::event;
use sui::object::{Self, ID, UID};
use sui::tx_context::TxContext;

// === Errors ===
const ERequestNotFulfilled: u64 = 1;
const EInvalidRequestID: u64 = 2;
const EResourceTypeMismatch: u64 = 3;
const EAlreadyFulfilled: u64 = 4;
const EInvalidContext: u64 = 5;

// === Events ===

public struct ResourceRequested has copy, drop {
    request_id: ID,
    action_type: TypeName,
    resource_count: u64,
}

public struct ResourceFulfilled has copy, drop {
    request_id: ID,
    action_type: TypeName,
}

// === Core Types ===

/// Generic hot potato for requesting resources - MUST be fulfilled in same transaction
/// The phantom type T represents the action type requesting resources
/// Has no abilities, forcing immediate consumption
#[allow(lint(missing_key))]
public struct ResourceRequest<phantom T> {
    id: UID,
    /// Store any action-specific data needed for fulfillment
    /// Using dynamic fields allows complete flexibility
    context: UID,
}

/// Generic receipt confirming resources were provided
/// Has drop to allow easy cleanup
public struct ResourceReceipt<phantom T> has drop {
    request_id: ID,
}

// === Generic Request Creation ===

/// Create a new resource request with context
/// The phantom type T ensures type safety between request and fulfillment
public fun new_request<T>(ctx: &mut TxContext): ResourceRequest<T> {
    let id = object::new(ctx);
    let context = object::new(ctx);
    let request_id = object::uid_to_inner(&id);

    event::emit(ResourceRequested {
        request_id,
        action_type: type_name::with_defining_ids<T>(),
        resource_count: 0, // Will be determined by what's added to context
    });

    ResourceRequest<T> {
        id,
        context,
    }
}

/// Add context data to a request (can be called multiple times)
/// This allows actions to store any data they need for fulfillment
public fun add_context<T, V: store>(request: &mut ResourceRequest<T>, key: String, value: V) {
    dynamic_field::add(&mut request.context, key, value);
}

/// Get context data from a request
public fun get_context<T, V: store + copy>(request: &ResourceRequest<T>, key: String): V {
    *dynamic_field::borrow(&request.context, key)
}

/// Check if context exists
public fun has_context<T>(request: &ResourceRequest<T>, key: String): bool {
    dynamic_field::exists_(&request.context, key)
}

// === Generic Fulfillment ===

/// Consume a request and return a receipt
/// The actual resource provision happens in the action-specific fulfill function
public fun fulfill<T>(request: ResourceRequest<T>): ResourceReceipt<T> {
    let ResourceRequest { id, context } = request;
    let request_id = object::uid_to_inner(&id);

    event::emit(ResourceFulfilled {
        request_id,
        action_type: type_name::with_defining_ids<T>(),
    });

    // Clean up
    object::delete(id);
    object::delete(context);

    ResourceReceipt<T> {
        request_id,
    }
}

// === Getters ===

public fun request_id<T>(request: &ResourceRequest<T>): ID {
    object::uid_to_inner(&request.id)
}

public fun receipt_id<T>(receipt: &ResourceReceipt<T>): ID {
    receipt.request_id
}

// === Mutable Context Access ===

/// Take context data from a request (for fulfillment)
public fun take_context<T, V: store>(request: &mut ResourceRequest<T>, key: String): V {
    dynamic_field::remove(&mut request.context, key)
}

/// Get mutable context access
public fun context_mut<T>(request: &mut ResourceRequest<T>): &mut UID {
    &mut request.context
}

// === Action-Specific Helpers ===

/// Create a new resource request with an action stored as context
public fun new_resource_request<T: store>(action: T, ctx: &mut TxContext): ResourceRequest<T> {
    let mut request = new_request<T>(ctx);
    add_context(&mut request, string::utf8(b"action"), action);
    request
}

/// Extract the action from a resource request
public fun extract_action<T: store>(mut request: ResourceRequest<T>): T {
    let action = take_context<T, T>(&mut request, string::utf8(b"action"));
    // Clean up the request
    let ResourceRequest { id, context } = request;
    object::delete(id);
    object::delete(context);
    action
}

/// Create a receipt after fulfilling a request with an action
public fun create_receipt<T: drop>(action: T): ResourceReceipt<T> {
    // Drop the action since it's been processed
    let _ = action;

    // Create a dummy receipt (ID doesn't matter since action is dropped)
    ResourceReceipt<T> {
        request_id: object::id_from_address(@0x0),
    }
}
