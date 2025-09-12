/// Defines the standard interface for all init action handlers.
/// This allows for a fully dynamic, registry-based dispatcher where the central
/// executor does not need to know about any concrete action types at compile time.
module futarchy_actions::action_handler_interface;

use std::string::String;
use sui::object::{Self, UID, ID};
use sui::tx_context::TxContext;
use sui::clock::Clock;
use account_protocol::account::Account;
use futarchy_core::futarchy_config::FutarchyConfig;
use futarchy_markets::account_spot_pool::AccountSpotPool;
use futarchy_core::priority_queue::ProposalQueue;

/// A generic capability object that proves ownership of an execution function.
/// Each action type will have its own unique handler instance.
public struct ActionHandler has key, store {
    id: UID,
    /// A human-readable description for debugging and introspection.
    description: String,
}

/// The standard execution interface that all handlers must implement.
/// This function is intentionally left empty; it serves as a trait-like placeholder.
/// The actual implementation will be in each action module.
public fun execute<AssetType, StableType>(
    _handler: &mut ActionHandler,
    _action_data: &vector<u8>,
    _account: &mut Account<FutarchyConfig>,
    _queue: &mut ProposalQueue<StableType>,
    _spot_pool: &mut AccountSpotPool<AssetType, StableType>,
    _clock: &Clock,
    _ctx: &mut TxContext,
) {
    // This is an interface function; the real logic is in the handler modules.
    // We abort here to ensure it's never called directly.
    abort(EInterfaceViolation)
}

const EInterfaceViolation: u64 = 0;