#[test_only]
module futarchy::unique_key_tests;

use futarchy::unique_key;
use std::string;
use sui::test_scenario::{Self as test, ctx};

const ADMIN: address = @0xA;

#[test]
fun test_new_unique_key() {
    let mut scenario = test::begin(ADMIN);

    test::next_tx(&mut scenario, ADMIN);
    {
        // Generate multiple keys
        let key1 = unique_key::new(ctx(&mut scenario));
        let key2 = unique_key::new(ctx(&mut scenario));
        let key3 = unique_key::new(ctx(&mut scenario));

        // All keys should be unique
        assert!(key1 != key2, 0);
        assert!(key2 != key3, 1);
        assert!(key1 != key3, 2);

        // Keys should be valid hex strings (64 chars for addresses)
        assert!(key1.length() == 64, 3);
        assert!(key2.length() == 64, 4);
        assert!(key3.length() == 64, 5);
    };

    test::end(scenario);
}

#[test]
fun test_with_prefix() {
    let mut scenario = test::begin(ADMIN);

    test::next_tx(&mut scenario, ADMIN);
    {
        let prefix = b"proposal".to_string();
        let key1 = unique_key::with_prefix(prefix, ctx(&mut scenario));
        let key2 = unique_key::with_prefix(prefix, ctx(&mut scenario));

        // Full keys should still be unique
        assert!(key1 != key2, 0);

        // Should have prefix + underscore + 64 char address
        assert!(key1.length() == 73, 1); // "proposal" (8) + "_" (1) + address (64)
        assert!(key2.length() == 73, 2);
    };

    test::end(scenario);
}

#[test]
fun test_different_prefixes() {
    let mut scenario = test::begin(ADMIN);

    test::next_tx(&mut scenario, ADMIN);
    {
        let intent_key = unique_key::with_prefix(b"intent".to_string(), ctx(&mut scenario));
        let proposal_key = unique_key::with_prefix(b"proposal".to_string(), ctx(&mut scenario));
        let action_key = unique_key::with_prefix(b"action".to_string(), ctx(&mut scenario));

        // All unique
        assert!(intent_key != proposal_key, 0);
        assert!(proposal_key != action_key, 1);
        assert!(intent_key != action_key, 2);

        // Check lengths are correct
        assert!(intent_key.length() == 71, 3); // "intent" (6) + "_" (1) + address (64)
        assert!(proposal_key.length() == 73, 4); // "proposal" (8) + "_" (1) + address (64)
        assert!(action_key.length() == 71, 5); // "action" (6) + "_" (1) + address (64)
    };

    test::end(scenario);
}

#[test]
fun test_empty_prefix() {
    let mut scenario = test::begin(ADMIN);

    test::next_tx(&mut scenario, ADMIN);
    {
        let empty_prefix = b"".to_string();
        let key = unique_key::with_prefix(empty_prefix, ctx(&mut scenario));

        // Should be underscore + address
        assert!(key.length() == 65, 0); // "_" (1) + address (64)
    };

    test::end(scenario);
}

#[test]
fun test_long_prefix() {
    let mut scenario = test::begin(ADMIN);

    test::next_tx(&mut scenario, ADMIN);
    {
        let long_prefix = b"this_is_a_very_long_prefix_for_testing_purposes".to_string();
        let key = unique_key::with_prefix(long_prefix, ctx(&mut scenario));

        // Should handle long prefixes
        let prefix_len = b"this_is_a_very_long_prefix_for_testing_purposes".to_string().length();
        assert!(prefix_len == 47, 0);
        // Verify the key starts with the prefix and underscore
        assert!(key.length() == 112, 1); // prefix (47) + "_" (1) + address (64)
    };

    test::end(scenario);
}

#[test]
fun test_consistency_within_transaction() {
    let mut scenario = test::begin(ADMIN);

    test::next_tx(&mut scenario, ADMIN);
    {
        // Generate multiple keys in same transaction
        let keys = vector[
            unique_key::new(ctx(&mut scenario)),
            unique_key::new(ctx(&mut scenario)),
            unique_key::new(ctx(&mut scenario)),
            unique_key::new(ctx(&mut scenario)),
            unique_key::new(ctx(&mut scenario)),
        ];

        // All should be unique even within same transaction
        let mut i = 0;
        while (i < keys.length()) {
            let mut j = i + 1;
            while (j < keys.length()) {
                assert!(keys[i] != keys[j], 0);
                j = j + 1;
            };
            i = i + 1;
        };
    };

    test::end(scenario);
}

#[test]
fun test_special_characters_in_prefix() {
    let mut scenario = test::begin(ADMIN);

    test::next_tx(&mut scenario, ADMIN);
    {
        // Test with numbers
        let key1 = unique_key::with_prefix(b"test123".to_string(), ctx(&mut scenario));
        assert!(key1.length() == 72, 0); // "test123" (7) + "_" (1) + address (64)

        // Test with underscores in prefix
        let key2 = unique_key::with_prefix(b"test_prefix".to_string(), ctx(&mut scenario));
        assert!(key2.length() == 76, 1); // "test_prefix" (11) + "_" (1) + address (64)

        // Test with hyphens
        let key3 = unique_key::with_prefix(b"test-prefix".to_string(), ctx(&mut scenario));
        assert!(key3.length() == 76, 2); // "test-prefix" (11) + "_" (1) + address (64)
    };

    test::end(scenario);
}
