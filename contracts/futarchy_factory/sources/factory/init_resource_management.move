// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

/// Resource Management Pattern for Init Actions
/// This module provides a clear pattern for actions that need external resources during initialization
///
/// ## Pattern Guidelines:
///
/// Use ResourceRequest when action needs:
/// 1. Shared objects that can't be stored in Account (AMM pools, ProposalQueues)
/// 2. External coins from users (not from DAO vault)
/// 3. Special capabilities like TreasuryCap for minting
///
/// Don't use ResourceRequest for:
/// - Config updates (modify Account directly)
/// - Vault operations (coins already in Account)
/// - Stream management (streams stored in Account)
/// - Dissolution actions (use Account's resources)
module futarchy_factory::init_resource_management;

use futarchy_types::init_action_specs::ActionSpec;
use std::type_name::{Self, TypeName};
use sui::bcs;

// === Resource Request Pattern ===
// Clear resource request pattern for actions needing external resources

/// Generic resource request that specifies what resources an action needs
public struct InitResourceRequest<T> has drop {
    spec: ActionSpec,
    resource_type: TypeName,
    required_amount: u64, // For coins
    additional_info: vector<u8>, // For complex requirements
}

/// Resource receipt confirming resources were provided
public struct ResourceReceipt<T> has drop {
    action_type: TypeName,
    resources_provided: bool,
    execution_status: u8, // 0=pending, 1=success, 2=failed
}

// === Constants for Execution Status ===
const STATUS_PENDING: u8 = 0;
const STATUS_SUCCESS: u8 = 1;
const STATUS_FAILED: u8 = 2;

// === Resource Type Identifiers ===
const RESOURCE_COIN: u8 = 0;
const RESOURCE_SHARED_OBJECT: u8 = 1;
const RESOURCE_CAPABILITY: u8 = 2;
const RESOURCE_LP_TOKEN: u8 = 3;

// === Constructor Functions ===

/// Create a resource request for coins
public fun request_coin_resources<ActionType: drop, CoinType>(
    spec: ActionSpec,
    amount: u64,
): InitResourceRequest<ActionType> {
    InitResourceRequest {
        spec,
        resource_type: type_name::get<CoinType>(),
        required_amount: amount,
        additional_info: vector::empty(),
    }
}

/// Create a resource request for liquidity provision
public fun request_liquidity_resources<ActionType: drop, AssetType, StableType>(
    spec: ActionSpec,
    asset_amount: u64,
    stable_amount: u64,
): InitResourceRequest<ActionType> {
    let mut info = vector::empty<u8>();
    vector::append(&mut info, bcs::to_bytes(&asset_amount));
    vector::append(&mut info, bcs::to_bytes(&stable_amount));

    InitResourceRequest {
        spec,
        resource_type: type_name::get<ActionType>(),
        required_amount: 0, // Using additional_info for amounts
        additional_info: info,
    }
}

/// Create a resource request for shared objects (like ProposalQueue)
public fun request_shared_object<ActionType: drop, ObjectType>(
    spec: ActionSpec,
): InitResourceRequest<ActionType> {
    InitResourceRequest {
        spec,
        resource_type: type_name::get<ObjectType>(),
        required_amount: 0,
        additional_info: vector::empty(),
    }
}

/// Create a resource request for capabilities (like TreasuryCap)
public fun request_capability<ActionType: drop, CapType>(
    spec: ActionSpec,
): InitResourceRequest<ActionType> {
    InitResourceRequest {
        spec,
        resource_type: type_name::get<CapType>(),
        required_amount: 0,
        additional_info: vector::empty(),
    }
}

// === Receipt Functions ===

/// Create a success receipt
public fun success_receipt<T>(): ResourceReceipt<T> {
    ResourceReceipt {
        action_type: type_name::get<T>(),
        resources_provided: true,
        execution_status: STATUS_SUCCESS,
    }
}

/// Create a failure receipt
public fun failure_receipt<T>(): ResourceReceipt<T> {
    ResourceReceipt {
        action_type: type_name::get<T>(),
        resources_provided: false,
        execution_status: STATUS_FAILED,
    }
}

/// Create a pending receipt (resources provided but not yet executed)
public fun pending_receipt<T>(): ResourceReceipt<T> {
    ResourceReceipt {
        action_type: type_name::get<T>(),
        resources_provided: true,
        execution_status: STATUS_PENDING,
    }
}

// === Getters ===

public fun request_spec<T>(request: &InitResourceRequest<T>): &ActionSpec {
    &request
    ERROR
}

public fun request_resource_type<T>(request: &InitResourceRequest<T>): TypeName {
    request.resource_type
}

public fun request_amount<T>(request: &InitResourceRequest<T>): u64 {
    request.required_amount
}

public fun request_info<T>(request: &InitResourceRequest<T>): &vector<u8> {
    &request.additional_info
}

public fun receipt_status<T>(receipt: &ResourceReceipt<T>): u8 {
    receipt.execution_status
}

public fun receipt_is_success<T>(receipt: &ResourceReceipt<T>): bool {
    receipt.execution_status == STATUS_SUCCESS
}

public fun receipt_is_failed<T>(receipt: &ResourceReceipt<T>): bool {
    receipt.execution_status == STATUS_FAILED
}
