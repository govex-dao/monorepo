/// Simple unique key generation for intents
module futarchy_one_shot_utils::unique_key;

use std::string::String;
use sui::{object, tx_context::TxContext};

/// Generate a guaranteed unique key using Sui's object ID
public fun new(ctx: &mut TxContext): String {
    // Object IDs are globally unique in Sui
    let uid = object::new(ctx);
    let id = object::uid_to_inner(&uid);
    let addr = object::id_to_address(&id);
    object::delete(uid);
    
    // Convert address to hex string (built-in Sui function)
    addr.to_string()
}

/// Generate with a prefix for readability
public fun with_prefix(prefix: String, ctx: &mut TxContext): String {
    let mut key = prefix;
    key.append_utf8(b"_");
    key.append(new(ctx));
    key
}