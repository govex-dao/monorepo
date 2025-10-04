module futarchy_one_shot_utils::metadata;

use std::string::String;
use sui::table::{Self, Table};
use sui::bag::{Self, Bag};

// === Errors ===
const EInvalidMetadataLength: u64 = 0; // Keys and values vectors must have same length
const EEmptyKey: u64 = 1; // Metadata key cannot be empty
const EKeyTooLong: u64 = 2; // Metadata key exceeds maximum length
const EValueTooLong: u64 = 3; // Metadata value exceeds maximum length
const EDuplicateKey: u64 = 4; // Duplicate key in metadata

// === Constants ===
const MAX_KEY_LENGTH: u64 = 64; // Maximum length for metadata keys
const MAX_VALUE_LENGTH: u64 = 256; // Maximum length for metadata values
const MAX_ENTRIES: u64 = 50; // Maximum number of metadata entries

// === Public Functions ===

/// Create a new metadata table from parallel vectors of keys and values
/// This is useful for entry functions that can't accept Table parameters
public fun new_from_vectors(
    keys: vector<String>,
    values: vector<String>,
    ctx: &mut TxContext
): Table<String, String> {
    let keys_len = keys.length();
    let values_len = values.length();
    
    // Validate input
    assert!(keys_len == values_len, EInvalidMetadataLength);
    assert!(keys_len <= MAX_ENTRIES, EInvalidMetadataLength);
    
    let mut metadata = table::new<String, String>(ctx);
    let mut i = 0;
    
    while (i < keys_len) {
        let key = &keys[i];
        let value = &values[i];
        
        // Validate key and value
        assert!(key.length() > 0, EEmptyKey);
        assert!(key.length() <= MAX_KEY_LENGTH, EKeyTooLong);
        assert!(value.length() <= MAX_VALUE_LENGTH, EValueTooLong);
        
        // Check for duplicates
        assert!(!table::contains(&metadata, *key), EDuplicateKey);
        
        table::add(&mut metadata, *key, *value);
        i = i + 1;
    };
    
    metadata
}

/// Add a single key-value pair to an existing metadata table
public fun add_entry(
    metadata: &mut Table<String, String>,
    key: String,
    value: String
) {
    // Validate
    assert!(key.length() > 0, EEmptyKey);
    assert!(key.length() <= MAX_KEY_LENGTH, EKeyTooLong);
    assert!(value.length() <= MAX_VALUE_LENGTH, EValueTooLong);
    assert!(table::length(metadata) < MAX_ENTRIES, EInvalidMetadataLength);
    
    if (table::contains(metadata, key)) {
        // Update existing entry
        table::remove(metadata, key);
        table::add(metadata, key, value);
    } else {
        // Add new entry
        table::add(metadata, key, value);
    }
}

/// Update an existing entry in the metadata table
public fun update_entry(
    metadata: &mut Table<String, String>,
    key: String,
    value: String
) {
    assert!(value.length() <= MAX_VALUE_LENGTH, EValueTooLong);
    
    // Update existing entry
    if (table::contains(metadata, key)) {
        let val_ref = table::borrow_mut(metadata, key);
        *val_ref = value;
    } else {
        // Add new entry if it doesn't exist
        add_entry(metadata, key, value);
    }
}

/// Remove an entry from the metadata table
public fun remove_entry(
    metadata: &mut Table<String, String>,
    key: String
): String {
    table::remove(metadata, key)
}

/// Check if a key exists in the metadata
public fun contains_key(
    metadata: &Table<String, String>,
    key: &String
): bool {
    table::contains(metadata, *key)
}

/// Get a value from the metadata table
public fun get_value(
    metadata: &Table<String, String>,
    key: &String
): &String {
    table::borrow(metadata, *key)
}

/// Get the number of entries in the metadata table
public fun length(metadata: &Table<String, String>): u64 {
    table::length(metadata)
}

/// Validate metadata without creating a table (useful for pre-validation)
public fun validate_metadata_vectors(
    keys: &vector<String>,
    values: &vector<String>,
    ctx: &mut TxContext
) {
    let keys_len = keys.length();
    let values_len = values.length();

    assert!(keys_len == values_len, EInvalidMetadataLength);
    assert!(keys_len <= MAX_ENTRIES, EInvalidMetadataLength);

    let mut i = 0;
    let mut seen_keys = bag::new(ctx);

    while (i < keys_len) {
        let key = &keys[i];
        let value = &values[i];

        // Validate key and value
        assert!(key.length() > 0, EEmptyKey);
        assert!(key.length() <= MAX_KEY_LENGTH, EKeyTooLong);
        assert!(value.length() <= MAX_VALUE_LENGTH, EValueTooLong);

        // Check for duplicates
        assert!(!bag::contains(&seen_keys, *key), EDuplicateKey);
        bag::add(&mut seen_keys, *key, true);

        i = i + 1;
    };

    // Clean up: remove all items before destroying
    i = 0;
    while (i < keys_len) {
        let _: bool = bag::remove(&mut seen_keys, keys[i]);
        i = i + 1;
    };

    bag::destroy_empty(seen_keys);
}

// === Common Metadata Keys ===
// These constants define standard metadata keys used across the protocol

/// Website URL for the DAO or proposal
public fun key_website(): String { b"website".to_string() }

/// Twitter/X handle
public fun key_twitter(): String { b"twitter".to_string() }

/// Discord server invite link
public fun key_discord(): String { b"discord".to_string() }

/// GitHub organization or repository
public fun key_github(): String { b"github".to_string() }

/// Telegram group link
public fun key_telegram(): String { b"telegram".to_string() }

/// Documentation URL
public fun key_docs(): String { b"docs".to_string() }

/// Whitepaper or litepaper URL
public fun key_whitepaper(): String { b"whitepaper".to_string() }

/// Token contract address (for existing tokens)
public fun key_token_address(): String { b"token_address".to_string() }

/// Total token supply
public fun key_token_supply(): String { b"token_supply".to_string() }

/// Token distribution details
public fun key_token_distribution(): String { b"token_distribution".to_string() }

/// Team information
public fun key_team(): String { b"team".to_string() }

/// Roadmap URL or description
public fun key_roadmap(): String { b"roadmap".to_string() }

/// Legal entity information
public fun key_legal_entity(): String { b"legal_entity".to_string() }

/// Terms of service URL
public fun key_terms(): String { b"terms".to_string() }

/// Privacy policy URL
public fun key_privacy(): String { b"privacy".to_string() }