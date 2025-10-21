#[test_only]
module futarchy_one_shot_utils::metadata_tests;

use futarchy_one_shot_utils::metadata;
use std::string::{Self, String};
use sui::test_scenario;

// === Basic Functionality Tests ===

#[test]
fun test_new_from_vectors_basic() {
    let mut scenario = test_scenario::begin(@0x1);
    let ctx = test_scenario::ctx(&mut scenario);

    let keys = vector[string::utf8(b"name"), string::utf8(b"description")];
    let values = vector[string::utf8(b"Test DAO"), string::utf8(b"A test DAO")];

    let table = metadata::new_from_vectors(keys, values, ctx);

    assert!(metadata::length(&table) == 2, 0);
    assert!(metadata::contains_key(&table, &string::utf8(b"name")), 1);
    assert!(metadata::contains_key(&table, &string::utf8(b"description")), 2);

    let name = metadata::get_value(&table, &string::utf8(b"name"));
    assert!(name == &string::utf8(b"Test DAO"), 3);

    sui::table::drop(table);
    test_scenario::end(scenario);
}

#[test]
fun test_new_from_vectors_empty() {
    let mut scenario = test_scenario::begin(@0x1);
    let ctx = test_scenario::ctx(&mut scenario);

    let keys = vector<String>[];
    let values = vector<String>[];

    let table = metadata::new_from_vectors(keys, values, ctx);
    assert!(metadata::length(&table) == 0, 0);

    sui::table::drop(table);
    test_scenario::end(scenario);
}

#[test]
#[expected_failure(abort_code = 0)] // EInvalidMetadataLength
fun test_new_from_vectors_mismatched_length() {
    let mut scenario = test_scenario::begin(@0x1);
    let ctx = test_scenario::ctx(&mut scenario);

    let keys = vector[string::utf8(b"key1"), string::utf8(b"key2")];
    let values = vector[string::utf8(b"value1")]; // Mismatched

    let table = metadata::new_from_vectors(keys, values, ctx);
    sui::table::drop(table);
    test_scenario::end(scenario);
}

#[test]
#[expected_failure(abort_code = 0)] // EInvalidMetadataLength
fun test_new_from_vectors_too_many_entries() {
    let mut scenario = test_scenario::begin(@0x1);
    let ctx = test_scenario::ctx(&mut scenario);

    // Create 51 entries (MAX_ENTRIES is 50)
    let mut keys = vector<String>[];
    let mut values = vector<String>[];
    let mut i = 0;
    while (i < 51) {
        keys.push_back(string::utf8(b"key"));
        values.push_back(string::utf8(b"value"));
        i = i + 1;
    };

    let table = metadata::new_from_vectors(keys, values, ctx);
    sui::table::drop(table);
    test_scenario::end(scenario);
}

#[test]
#[expected_failure(abort_code = 1)] // EEmptyKey
fun test_new_from_vectors_empty_key() {
    let mut scenario = test_scenario::begin(@0x1);
    let ctx = test_scenario::ctx(&mut scenario);

    let keys = vector[string::utf8(b"")]; // Empty key
    let values = vector[string::utf8(b"value")];

    let table = metadata::new_from_vectors(keys, values, ctx);
    sui::table::drop(table);
    test_scenario::end(scenario);
}

#[test]
#[expected_failure(abort_code = 2)] // EKeyTooLong
fun test_new_from_vectors_key_too_long() {
    let mut scenario = test_scenario::begin(@0x1);
    let ctx = test_scenario::ctx(&mut scenario);

    // Create a key longer than MAX_KEY_LENGTH (64)
    let long_key = string::utf8(
        b"xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx",
    ); // 75 chars
    let keys = vector[long_key];
    let values = vector[string::utf8(b"value")];

    let table = metadata::new_from_vectors(keys, values, ctx);
    sui::table::drop(table);
    test_scenario::end(scenario);
}

#[test]
#[expected_failure(abort_code = 3)] // EValueTooLong
fun test_new_from_vectors_value_too_long() {
    let mut scenario = test_scenario::begin(@0x1);
    let ctx = test_scenario::ctx(&mut scenario);

    let keys = vector[string::utf8(b"key")];
    // Create a value longer than MAX_VALUE_LENGTH (256)
    let mut long_value_bytes = vector<u8>[];
    let mut i = 0;
    while (i < 300) {
        long_value_bytes.push_back(97); // 'a'
        i = i + 1;
    };
    let long_value = string::utf8(long_value_bytes);
    let values = vector[long_value];

    let table = metadata::new_from_vectors(keys, values, ctx);
    sui::table::drop(table);
    test_scenario::end(scenario);
}

#[test]
#[expected_failure(abort_code = 4)] // EDuplicateKey
fun test_new_from_vectors_duplicate_key() {
    let mut scenario = test_scenario::begin(@0x1);
    let ctx = test_scenario::ctx(&mut scenario);

    let keys = vector[string::utf8(b"key"), string::utf8(b"key")]; // Duplicate
    let values = vector[string::utf8(b"value1"), string::utf8(b"value2")];

    let table = metadata::new_from_vectors(keys, values, ctx);
    sui::table::drop(table);
    test_scenario::end(scenario);
}

#[test]
fun test_new_from_vectors_max_entries() {
    let mut scenario = test_scenario::begin(@0x1);
    let ctx = test_scenario::ctx(&mut scenario);

    // Create 10 entries to test multiple entries
    let keys = vector[
        string::utf8(b"key1"),
        string::utf8(b"key2"),
        string::utf8(b"key3"),
        string::utf8(b"key4"),
        string::utf8(b"key5"),
        string::utf8(b"key6"),
        string::utf8(b"key7"),
        string::utf8(b"key8"),
        string::utf8(b"key9"),
        string::utf8(b"key10"),
    ];
    let values = vector[
        string::utf8(b"val1"),
        string::utf8(b"val2"),
        string::utf8(b"val3"),
        string::utf8(b"val4"),
        string::utf8(b"val5"),
        string::utf8(b"val6"),
        string::utf8(b"val7"),
        string::utf8(b"val8"),
        string::utf8(b"val9"),
        string::utf8(b"val10"),
    ];

    let table = metadata::new_from_vectors(keys, values, ctx);
    assert!(metadata::length(&table) == 10, 0);

    sui::table::drop(table);
    test_scenario::end(scenario);
}

// === add_entry Tests ===

#[test]
fun test_add_entry_new() {
    let mut scenario = test_scenario::begin(@0x1);
    let ctx = test_scenario::ctx(&mut scenario);

    let keys = vector[string::utf8(b"name")];
    let values = vector[string::utf8(b"Initial")];
    let mut table = metadata::new_from_vectors(keys, values, ctx);

    metadata::add_entry(&mut table, string::utf8(b"twitter"), string::utf8(b"@test"));
    assert!(metadata::length(&table) == 2, 0);
    assert!(metadata::contains_key(&table, &string::utf8(b"twitter")), 1);

    sui::table::drop(table);
    test_scenario::end(scenario);
}

#[test]
fun test_add_entry_overwrites_existing() {
    let mut scenario = test_scenario::begin(@0x1);
    let ctx = test_scenario::ctx(&mut scenario);

    let keys = vector[string::utf8(b"name")];
    let values = vector[string::utf8(b"Old")];
    let mut table = metadata::new_from_vectors(keys, values, ctx);

    // add_entry should overwrite
    metadata::add_entry(&mut table, string::utf8(b"name"), string::utf8(b"New"));
    assert!(metadata::length(&table) == 1, 0);
    assert!(metadata::get_value(&table, &string::utf8(b"name")) == &string::utf8(b"New"), 1);

    sui::table::drop(table);
    test_scenario::end(scenario);
}

// === update_entry Tests ===

#[test]
fun test_update_entry_existing() {
    let mut scenario = test_scenario::begin(@0x1);
    let ctx = test_scenario::ctx(&mut scenario);

    let keys = vector[string::utf8(b"name")];
    let values = vector[string::utf8(b"Initial")];
    let mut table = metadata::new_from_vectors(keys, values, ctx);

    metadata::update_entry(&mut table, string::utf8(b"name"), string::utf8(b"Updated"));
    let name = metadata::get_value(&table, &string::utf8(b"name"));
    assert!(name == &string::utf8(b"Updated"), 0);

    sui::table::drop(table);
    test_scenario::end(scenario);
}

#[test]
fun test_update_entry_creates_if_not_exists() {
    let mut scenario = test_scenario::begin(@0x1);
    let ctx = test_scenario::ctx(&mut scenario);

    let keys = vector<String>[];
    let values = vector<String>[];
    let mut table = metadata::new_from_vectors(keys, values, ctx);

    // update_entry should add if doesn't exist
    metadata::update_entry(&mut table, string::utf8(b"new_key"), string::utf8(b"new_value"));
    assert!(metadata::length(&table) == 1, 0);
    assert!(metadata::contains_key(&table, &string::utf8(b"new_key")), 1);

    sui::table::drop(table);
    test_scenario::end(scenario);
}

// === remove_entry Tests ===

#[test]
fun test_remove_entry() {
    let mut scenario = test_scenario::begin(@0x1);
    let ctx = test_scenario::ctx(&mut scenario);

    let keys = vector[string::utf8(b"name"), string::utf8(b"twitter")];
    let values = vector[string::utf8(b"DAO"), string::utf8(b"@dao")];
    let mut table = metadata::new_from_vectors(keys, values, ctx);

    let removed = metadata::remove_entry(&mut table, string::utf8(b"twitter"));
    assert!(removed == string::utf8(b"@dao"), 0);
    assert!(metadata::length(&table) == 1, 1);
    assert!(!metadata::contains_key(&table, &string::utf8(b"twitter")), 2);

    sui::table::drop(table);
    test_scenario::end(scenario);
}

// === Common Metadata Keys Tests ===

#[test]
fun test_all_common_metadata_keys() {
    assert!(metadata::key_website() == string::utf8(b"website"), 0);
    assert!(metadata::key_twitter() == string::utf8(b"twitter"), 1);
    assert!(metadata::key_discord() == string::utf8(b"discord"), 2);
    assert!(metadata::key_github() == string::utf8(b"github"), 3);
    assert!(metadata::key_telegram() == string::utf8(b"telegram"), 4);
    assert!(metadata::key_docs() == string::utf8(b"docs"), 5);
    assert!(metadata::key_whitepaper() == string::utf8(b"whitepaper"), 6);
    assert!(metadata::key_token_address() == string::utf8(b"token_address"), 7);
    assert!(metadata::key_token_supply() == string::utf8(b"token_supply"), 8);
    assert!(metadata::key_token_distribution() == string::utf8(b"token_distribution"), 9);
    assert!(metadata::key_team() == string::utf8(b"team"), 10);
    assert!(metadata::key_roadmap() == string::utf8(b"roadmap"), 11);
    assert!(metadata::key_legal_entity() == string::utf8(b"legal_entity"), 12);
    assert!(metadata::key_terms() == string::utf8(b"terms"), 13);
    assert!(metadata::key_privacy() == string::utf8(b"privacy"), 14);
}

// === Validation Tests ===

#[test]
fun test_validate_metadata_vectors_valid() {
    let keys = vector[string::utf8(b"name")];
    let values = vector[string::utf8(b"value")];

    metadata::validate_metadata_vectors(&keys, &values);
}

// === Error Case Tests ===

#[test]
#[expected_failure(abort_code = 0)] // EInvalidMetadataLength
fun test_mismatched_vectors_length() {
    let mut scenario = test_scenario::begin(@0x1);
    let ctx = test_scenario::ctx(&mut scenario);

    let keys = vector[string::utf8(b"key1"), string::utf8(b"key2")];
    let values = vector[string::utf8(b"value1")];

    let table = metadata::new_from_vectors(keys, values, ctx);
    sui::table::drop(table);
    test_scenario::end(scenario);
}

#[test]
#[expected_failure(abort_code = 1)] // EEmptyKey
fun test_empty_key_rejected() {
    let mut scenario = test_scenario::begin(@0x1);
    let ctx = test_scenario::ctx(&mut scenario);

    let keys = vector[string::utf8(b"")];
    let values = vector[string::utf8(b"value")];

    let table = metadata::new_from_vectors(keys, values, ctx);
    sui::table::drop(table);
    test_scenario::end(scenario);
}

#[test]
#[expected_failure(abort_code = 2)] // EKeyTooLong
fun test_key_too_long() {
    let mut scenario = test_scenario::begin(@0x1);
    let ctx = test_scenario::ctx(&mut scenario);

    // Create key longer than MAX_KEY_LENGTH (64)
    let mut long_key = string::utf8(b"");
    let mut i = 0;
    while (i < 65) {
        long_key.append(string::utf8(b"a"));
        i = i + 1;
    };

    let keys = vector[long_key];
    let values = vector[string::utf8(b"value")];

    let table = metadata::new_from_vectors(keys, values, ctx);
    sui::table::drop(table);
    test_scenario::end(scenario);
}

#[test]
#[expected_failure(abort_code = 3)] // EValueTooLong
fun test_value_too_long() {
    let mut scenario = test_scenario::begin(@0x1);
    let ctx = test_scenario::ctx(&mut scenario);

    // Create value longer than MAX_VALUE_LENGTH (256)
    let mut long_value = string::utf8(b"");
    let mut i = 0;
    while (i < 257) {
        long_value.append(string::utf8(b"a"));
        i = i + 1;
    };

    let keys = vector[string::utf8(b"key")];
    let values = vector[long_value];

    let table = metadata::new_from_vectors(keys, values, ctx);
    sui::table::drop(table);
    test_scenario::end(scenario);
}

#[test]
#[expected_failure(abort_code = 4)] // EDuplicateKey
fun test_duplicate_key_rejected() {
    let mut scenario = test_scenario::begin(@0x1);
    let ctx = test_scenario::ctx(&mut scenario);

    let keys = vector[
        string::utf8(b"name"),
        string::utf8(b"name"), // Duplicate!
    ];
    let values = vector[string::utf8(b"value1"), string::utf8(b"value2")];

    let table = metadata::new_from_vectors(keys, values, ctx);
    sui::table::drop(table);
    test_scenario::end(scenario);
}

// === Coverage Tests for Uncovered Lines ===

#[test]
#[expected_failure(abort_code = 2)] // EInvalidMetadataLength
fun test_mismatched_key_value_lengths() {
    let mut scenario = test_scenario::begin(@0x1);
    let ctx = test_scenario::ctx(&mut scenario);
    
    // Create vectors with mismatched lengths
    // This should hit line 35: assert!(keys_len == values_len, EInvalidMetadataLength);
    let keys = vector[string::utf8(b"key1"), string::utf8(b"key2"), string::utf8(b"key3")];
    let values = vector[string::utf8(b"value1"), string::utf8(b"value2")]; // Only 2 values for 3 keys
    
    let table = metadata::new_from_vectors(keys, values, ctx);
    sui::table::drop(table);
    test_scenario::end(scenario);
}

#[test]
#[expected_failure(abort_code = 2)] // EInvalidMetadataLength
fun test_too_many_entries() {
    let mut scenario = test_scenario::begin(@0x1);
    let ctx = test_scenario::ctx(&mut scenario);
    
    // Create more than MAX_ENTRIES (100)
    // This should hit line 36: assert!(keys_len <= MAX_ENTRIES, EInvalidMetadataLength);
    let mut keys = vector[];
    let mut values = vector[];
    let mut i = 0;
    while (i < 101) {  // MAX_ENTRIES is 100
        keys.push_back(string::utf8(b"key"));
        values.push_back(string::utf8(b"value"));
        i = i + 1;
    };
    
    let table = metadata::new_from_vectors(keys, values, ctx);
    sui::table::drop(table);
    test_scenario::end(scenario);
}

#[test]
#[expected_failure(abort_code = 0)] // EEmptyKey
fun test_empty_key() {
    let mut scenario = test_scenario::begin(@0x1);
    let ctx = test_scenario::ctx(&mut scenario);
    
    // This should hit line 46: assert!(key.length() > 0, EEmptyKey);
    let keys = vector[string::utf8(b"")]; // Empty key
    let values = vector[string::utf8(b"value")];
    
    let table = metadata::new_from_vectors(keys, values, ctx);
    sui::table::drop(table);
    test_scenario::end(scenario);
}

#[test]
#[expected_failure(abort_code = 1)] // EKeyTooLong
fun test_key_too_long() {
    let mut scenario = test_scenario::begin(@0x1);
    let ctx = test_scenario::ctx(&mut scenario);
    
    // Create key longer than MAX_KEY_LENGTH (256)
    // This should hit line 47: assert!(key.length() <= MAX_KEY_LENGTH, EKeyTooLong);
    let mut long_key_bytes = vector[];
    let mut i = 0;
    while (i < 257) {  // MAX_KEY_LENGTH is 256
        long_key_bytes.push_back(65); // 'A'
        i = i + 1;
    };
    let keys = vector[string::utf8(long_key_bytes)];
    let values = vector[string::utf8(b"value")];
    
    let table = metadata::new_from_vectors(keys, values, ctx);
    sui::table::drop(table);
    test_scenario::end(scenario);
}

#[test]
#[expected_failure(abort_code = 3)] // EValueTooLong
fun test_value_too_long() {
    let mut scenario = test_scenario::begin(@0x1);
    let ctx = test_scenario::ctx(&mut scenario);
    
    // Create value longer than MAX_VALUE_LENGTH (2048)
    // This should hit line 48: assert!(value.length() <= MAX_VALUE_LENGTH, EValueTooLong);
    let mut long_value_bytes = vector[];
    let mut i = 0;
    while (i < 2049) {  // MAX_VALUE_LENGTH is 2048
        long_value_bytes.push_back(65); // 'A'
        i = i + 1;
    };
    let keys = vector[string::utf8(b"key")];
    let values = vector[string::utf8(long_value_bytes)];
    
    let table = metadata::new_from_vectors(keys, values, ctx);
    sui::table::drop(table);
    test_scenario::end(scenario);
}

#[test]
#[expected_failure(abort_code = 4)] // EDuplicateKey
fun test_duplicate_key_in_vector() {
    let mut scenario = test_scenario::begin(@0x1);
    let ctx = test_scenario::ctx(&mut scenario);
    
    // This should hit line 51 (duplicate check in new_from_vectors)
    // OR line 141 if using validate_metadata_vectors
    let keys = vector[string::utf8(b"key1"), string::utf8(b"key1")]; // Duplicate!
    let values = vector[string::utf8(b"value1"), string::utf8(b"value2")];
    
    let table = metadata::new_from_vectors(keys, values, ctx);
    sui::table::drop(table);
    test_scenario::end(scenario);
}

#[test]
#[expected_failure(abort_code = 2)] // EInvalidMetadataLength
fun test_add_entry_max_entries_exceeded() {
    let mut scenario = test_scenario::begin(@0x1);
    let ctx = test_scenario::ctx(&mut scenario);
    
    // Create table with MAX_ENTRIES (100) entries
    let mut keys = vector[];
    let mut values = vector[];
    let mut i = 0;
    while (i < 100) {
        let key_str = string::utf8(b"key");
        keys.push_back(key_str);
        values.push_back(string::utf8(b"value"));
        i = i + 1;
    };
    
    let mut table = metadata::new_from_vectors(keys, values, ctx);
    
    // Try to add one more entry
    // This should hit line 66: assert!(table::length(metadata) < MAX_ENTRIES, EInvalidMetadataLength);
    metadata::add_entry(&mut table, string::utf8(b"extra_key"), string::utf8(b"extra_value"));
    
    sui::table::drop(table);
    test_scenario::end(scenario);
}
