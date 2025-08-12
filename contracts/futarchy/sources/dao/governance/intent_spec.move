/// Intent specification for storing intent data in proposals
/// This allows proposals to store intent information without creating actual Account intents
/// until the winning outcome is determined
module futarchy::intent_spec;

use std::string::String;
use account_protocol::intents::Params;

/// Specification for creating an intent later
/// Stores all the data needed to create an AccountProtocol intent
public struct IntentSpec has store {
    /// Unique key for this intent
    key: String,
    /// Parameters for the intent (timing, expiry, etc.)
    params: Params,
    /// Module that will process this intent
    /// e.g. "config_actions", "liquidity_actions", "vault_actions"
    module_name: String,
    /// Serialized action data
    /// This will be deserialized and used to create the actual actions
    action_data: vector<u8>,
    /// Type name of the witness to use when creating the intent
    /// e.g. "ConfigIntent", "LiquidityIntent", "VaultIntent"
    witness_type: String,
}

/// Create a new intent specification
public fun new(
    key: String,
    params: Params,
    module_name: String,
    action_data: vector<u8>,
    witness_type: String,
): IntentSpec {
    IntentSpec {
        key,
        params,
        module_name,
        action_data,
        witness_type,
    }
}

/// Get the key
public fun key(spec: &IntentSpec): &String {
    &spec.key
}

/// Get the params
public fun params(spec: &IntentSpec): &Params {
    &spec.params
}

/// Get the module name
public fun module_name(spec: &IntentSpec): &String {
    &spec.module_name
}

/// Get the action data
public fun action_data(spec: &IntentSpec): &vector<u8> {
    &spec.action_data
}

/// Get the witness type
public fun witness_type(spec: &IntentSpec): &String {
    &spec.witness_type
}