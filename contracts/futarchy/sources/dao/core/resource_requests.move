/// Hot potato pattern for actions requiring special resources
/// 
/// This module provides a type-safe, generalizable way to request resources that can't be 
/// stored in the Account or threaded through the call chain. Actions that need
/// special resources create a ResourceRequest that MUST be fulfilled in the same transaction.
///
/// The pattern is fully abstract - any action can request any type of resource,
/// and the fulfillment is handled by action-specific functions.
module futarchy::resource_requests;

use std::string::{Self, String};
use std::type_name::{Self, TypeName};
use std::vector;
use sui::object::{Self, ID, UID};
use sui::tx_context::TxContext;
use sui::event;
use sui::dynamic_field;

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
        action_type: type_name::get<T>(),
        resource_count: 0, // Will be determined by what's added to context
    });
    
    ResourceRequest<T> {
        id,
        context,
    }
}

/// Add context data to a request (can be called multiple times)
/// This allows actions to store any data they need for fulfillment
public fun add_context<T, V: store>(
    request: &mut ResourceRequest<T>,
    key: String,
    value: V,
) {
    dynamic_field::add(&mut request.context, key, value);
}

/// Get context data from a request
public fun get_context<T, V: store + copy>(
    request: &ResourceRequest<T>,
    key: String,
): V {
    *dynamic_field::borrow(&request.context, key)
}

/// Check if context exists
public fun has_context<T>(
    request: &ResourceRequest<T>,
    key: String,
): bool {
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
        action_type: type_name::get<T>(),
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