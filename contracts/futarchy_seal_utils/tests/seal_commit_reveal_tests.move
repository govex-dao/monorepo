#[test_only]
module futarchy_seal_utils::seal_commit_reveal_tests;

use futarchy_seal_utils::seal_commit_reveal;
use std::vector;
use sui::bcs;
use sui::hash;
use sui::clock;
use sui::test_scenario::{Self as ts, Scenario};

// === Test Helper Functions ===

fun create_test_salt(): vector<u8> {
    let mut salt = vector::empty<u8>();
    let mut i = 0;
    while (i < 32) {
        vector::push_back(&mut salt, (i as u8));
        i = i + 1;
    };
    salt
}

fun compute_commitment_hash(params: u64, salt: vector<u8>): vector<u8> {
    let mut data = bcs::to_bytes(&params);
    vector::append(&mut data, salt);
    hash::keccak256(&data)
}

fun setup_test(sender: address): Scenario {
    let mut scenario = ts::begin(sender);
    scenario
}

// === SealedParams Constructor Tests ===

#[test]
fun test_new_sealed_params() {
    let blob_id = b"test_blob_id_12345";
    let commitment_hash = b"commitment_hash_value";
    let reveal_time = 1000000;

    let sealed = seal_commit_reveal::new_sealed_params(
        blob_id,
        commitment_hash,
        reveal_time,
    );

    assert!(seal_commit_reveal::sealed_params_blob_id(&sealed) == &blob_id, 0);
    assert!(seal_commit_reveal::sealed_params_commitment_hash(&sealed) == &commitment_hash, 1);
    assert!(seal_commit_reveal::sealed_params_reveal_time(&sealed) == reveal_time, 2);
}

#[test]
fun test_new_sealed_params_empty_blob_id() {
    let blob_id = vector::empty<u8>();
    let commitment_hash = b"commitment";
    let reveal_time = 5000;

    let sealed = seal_commit_reveal::new_sealed_params(
        blob_id,
        commitment_hash,
        reveal_time,
    );

    assert!(vector::length(seal_commit_reveal::sealed_params_blob_id(&sealed)) == 0, 0);
}

#[test]
fun test_new_sealed_params_large_blob_id() {
    let mut blob_id = vector::empty<u8>();
    let mut i = 0;
    while (i < 1000) {
        vector::push_back(&mut blob_id, (i % 256) as u8);
        i = i + 1;
    };

    let commitment_hash = b"hash";
    let sealed = seal_commit_reveal::new_sealed_params(blob_id, commitment_hash, 1000);

    assert!(vector::length(seal_commit_reveal::sealed_params_blob_id(&sealed)) == 1000, 0);
}

// === SealContainer Constructor Tests ===

#[test]
fun test_new_sealed_only() {
    let sealed = seal_commit_reveal::new_sealed_params(
        b"blob_id",
        b"commitment",
        10000,
    );

    let container = seal_commit_reveal::new_sealed_only<u64>(sealed);

    assert!(seal_commit_reveal::get_mode(&container) == seal_commit_reveal::mode_sealed(), 0);
    assert!(!seal_commit_reveal::is_revealed(&container), 1);
    assert!(!seal_commit_reveal::has_params(&container), 2);
}

#[test]
fun test_new_sealed_container_from_options_both_some() {
    let blob_id = option::some(b"blob_id");
    let commitment = option::some(b"commitment_hash");
    let reveal_time = 50000;

    let container_opt = seal_commit_reveal::new_sealed_container_from_options<u64>(
        blob_id,
        commitment,
        reveal_time,
    );

    assert!(container_opt.is_some(), 0);

    let container = container_opt.destroy_some();
    assert!(seal_commit_reveal::get_mode(&container) == seal_commit_reveal::mode_sealed(), 1);
}

#[test]
fun test_new_sealed_container_from_options_blob_none() {
    let blob_id = option::none<vector<u8>>();
    let commitment = option::some(b"commitment");

    let container_opt = seal_commit_reveal::new_sealed_container_from_options<u64>(
        blob_id,
        commitment,
        10000,
    );

    assert!(container_opt.is_none(), 0);
}

#[test]
fun test_new_sealed_container_from_options_commitment_none() {
    let blob_id = option::some(b"blob");
    let commitment = option::none<vector<u8>>();

    let container_opt = seal_commit_reveal::new_sealed_container_from_options<u64>(
        blob_id,
        commitment,
        10000,
    );

    assert!(container_opt.is_none(), 0);
}

#[test]
fun test_new_sealed_container_from_options_both_none() {
    let blob_id = option::none<vector<u8>>();
    let commitment = option::none<vector<u8>>();

    let container_opt = seal_commit_reveal::new_sealed_container_from_options<u64>(
        blob_id,
        commitment,
        10000,
    );

    assert!(container_opt.is_none(), 0);
}

#[test]
fun test_new_sealed_with_fallback() {
    let sealed = seal_commit_reveal::new_sealed_params(
        b"blob",
        b"commitment",
        10000,
    );
    let fallback = 42u64;

    let container = seal_commit_reveal::new_sealed_with_fallback(sealed, fallback);

    assert!(seal_commit_reveal::get_mode(&container) == seal_commit_reveal::mode_sealed_safe(), 0);
    assert!(seal_commit_reveal::has_params(&container), 1);
    assert!(!seal_commit_reveal::is_revealed(&container), 2);
    assert!(seal_commit_reveal::is_using_fallback(&container), 3);
}

#[test]
fun test_new_public() {
    let params = 100u64;

    let container = seal_commit_reveal::new_public(params);

    assert!(seal_commit_reveal::get_mode(&container) == seal_commit_reveal::mode_public(), 0);
    assert!(seal_commit_reveal::has_params(&container), 1);
    assert!(!seal_commit_reveal::is_revealed(&container), 2);
    assert!(seal_commit_reveal::is_using_fallback(&container), 3);
}

// === Reveal Function Tests ===

#[test]
fun test_reveal_success() {
    let sender = @0xA;
    let mut scenario = setup_test(sender);

    ts::next_tx(&mut scenario, sender);
    {
        let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
        clock::set_for_testing(&mut clock, 10000);

        let params = 42u64;
        let salt = create_test_salt();
        let commitment = compute_commitment_hash(params, salt);

        let sealed = seal_commit_reveal::new_sealed_params(
            b"blob_id",
            commitment,
            10000, // reveal_time = current time
        );

        let mut container = seal_commit_reveal::new_sealed_only<u64>(sealed);

        seal_commit_reveal::reveal(
            &mut container,
            params,
            salt,
            &clock,
            ts::ctx(&mut scenario),
        );

        assert!(seal_commit_reveal::is_revealed(&container), 0);
        assert!(seal_commit_reveal::has_params(&container), 1);
        assert!(!seal_commit_reveal::is_using_fallback(&container), 2);

        let revealed_params = seal_commit_reveal::get_params(&container);
        assert!(*revealed_params == 42, 3);

        clock::destroy_for_testing(clock);
    };

    ts::end(scenario);
}

#[test]
fun test_reveal_after_grace_period() {
    let sender = @0xA;
    let mut scenario = setup_test(sender);

    ts::next_tx(&mut scenario, sender);
    {
        let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
        clock::set_for_testing(&mut clock, 20000); // Well after reveal time

        let params = 999u64;
        let salt = create_test_salt();
        let commitment = compute_commitment_hash(params, salt);

        let sealed = seal_commit_reveal::new_sealed_params(
            b"blob",
            commitment,
            10000, // reveal_time in the past
        );

        let mut container = seal_commit_reveal::new_sealed_only<u64>(sealed);

        seal_commit_reveal::reveal(
            &mut container,
            params,
            salt,
            &clock,
            ts::ctx(&mut scenario),
        );

        assert!(seal_commit_reveal::is_revealed(&container), 0);

        clock::destroy_for_testing(clock);
    };

    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = seal_commit_reveal::ETooEarlyToReveal)]
fun test_reveal_too_early() {
    let sender = @0xA;
    let mut scenario = setup_test(sender);

    ts::next_tx(&mut scenario, sender);
    {
        let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
        clock::set_for_testing(&mut clock, 5000);

        let params = 42u64;
        let salt = create_test_salt();
        let commitment = compute_commitment_hash(params, salt);

        let sealed = seal_commit_reveal::new_sealed_params(
            b"blob",
            commitment,
            10000, // reveal_time in the future
        );

        let mut container = seal_commit_reveal::new_sealed_only<u64>(sealed);

        // This should fail - current time (5000) < reveal_time (10000)
        seal_commit_reveal::reveal(
            &mut container,
            params,
            salt,
            &clock,
            ts::ctx(&mut scenario),
        );

        clock::destroy_for_testing(clock);
    };

    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = seal_commit_reveal::EHashMismatch)]
fun test_reveal_wrong_params() {
    let sender = @0xA;
    let mut scenario = setup_test(sender);

    ts::next_tx(&mut scenario, sender);
    {
        let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
        clock::set_for_testing(&mut clock, 10000);

        let correct_params = 42u64;
        let wrong_params = 99u64;
        let salt = create_test_salt();
        let commitment = compute_commitment_hash(correct_params, salt);

        let sealed = seal_commit_reveal::new_sealed_params(
            b"blob",
            commitment,
            10000,
        );

        let mut container = seal_commit_reveal::new_sealed_only<u64>(sealed);

        // This should fail - wrong params don't match commitment
        seal_commit_reveal::reveal(
            &mut container,
            wrong_params,
            salt,
            &clock,
            ts::ctx(&mut scenario),
        );

        clock::destroy_for_testing(clock);
    };

    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = seal_commit_reveal::EHashMismatch)]
fun test_reveal_wrong_salt() {
    let sender = @0xA;
    let mut scenario = setup_test(sender);

    ts::next_tx(&mut scenario, sender);
    {
        let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
        clock::set_for_testing(&mut clock, 10000);

        let params = 42u64;
        let correct_salt = create_test_salt();
        let mut wrong_salt = create_test_salt();
        *vector::borrow_mut(&mut wrong_salt, 0) = 255; // Change first byte

        let commitment = compute_commitment_hash(params, correct_salt);

        let sealed = seal_commit_reveal::new_sealed_params(
            b"blob",
            commitment,
            10000,
        );

        let mut container = seal_commit_reveal::new_sealed_only<u64>(sealed);

        // This should fail - wrong salt doesn't match commitment
        seal_commit_reveal::reveal(
            &mut container,
            params,
            wrong_salt,
            &clock,
            ts::ctx(&mut scenario),
        );

        clock::destroy_for_testing(clock);
    };

    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = seal_commit_reveal::EInvalidSaltLength)]
fun test_reveal_short_salt() {
    let sender = @0xA;
    let mut scenario = setup_test(sender);

    ts::next_tx(&mut scenario, sender);
    {
        let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
        clock::set_for_testing(&mut clock, 10000);

        let params = 42u64;
        let short_salt = b"only_16_bytes!!!"; // Only 16 bytes, need 32

        let sealed = seal_commit_reveal::new_sealed_params(
            b"blob",
            b"commitment",
            10000,
        );

        let mut container = seal_commit_reveal::new_sealed_only<u64>(sealed);

        seal_commit_reveal::reveal(
            &mut container,
            params,
            short_salt,
            &clock,
            ts::ctx(&mut scenario),
        );

        clock::destroy_for_testing(clock);
    };

    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = seal_commit_reveal::EInvalidSaltLength)]
fun test_reveal_long_salt() {
    let sender = @0xA;
    let mut scenario = setup_test(sender);

    ts::next_tx(&mut scenario, sender);
    {
        let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
        clock::set_for_testing(&mut clock, 10000);

        let params = 42u64;
        let mut long_salt = create_test_salt();
        vector::push_back(&mut long_salt, 99); // 33 bytes

        let sealed = seal_commit_reveal::new_sealed_params(
            b"blob",
            b"commitment",
            10000,
        );

        let mut container = seal_commit_reveal::new_sealed_only<u64>(sealed);

        seal_commit_reveal::reveal(
            &mut container,
            params,
            long_salt,
            &clock,
            ts::ctx(&mut scenario),
        );

        clock::destroy_for_testing(clock);
    };

    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = seal_commit_reveal::EAlreadyRevealed)]
fun test_reveal_already_revealed() {
    let sender = @0xA;
    let mut scenario = setup_test(sender);

    ts::next_tx(&mut scenario, sender);
    {
        let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
        clock::set_for_testing(&mut clock, 10000);

        let params = 42u64;
        let salt = create_test_salt();
        let commitment = compute_commitment_hash(params, salt);

        let sealed = seal_commit_reveal::new_sealed_params(
            b"blob",
            commitment,
            10000,
        );

        let mut container = seal_commit_reveal::new_sealed_only<u64>(sealed);

        // First reveal - should succeed
        seal_commit_reveal::reveal(
            &mut container,
            params,
            salt,
            &clock,
            ts::ctx(&mut scenario),
        );

        // Second reveal - should fail
        seal_commit_reveal::reveal(
            &mut container,
            params,
            salt,
            &clock,
            ts::ctx(&mut scenario),
        );

        clock::destroy_for_testing(clock);
    };

    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = seal_commit_reveal::EMissingCommitment)]
fun test_reveal_public_container() {
    let sender = @0xA;
    let mut scenario = setup_test(sender);

    ts::next_tx(&mut scenario, sender);
    {
        let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
        clock::set_for_testing(&mut clock, 10000);

        let mut container = seal_commit_reveal::new_public(42u64);

        // Can't reveal a public container - no sealed params
        seal_commit_reveal::reveal(
            &mut container,
            42u64,
            create_test_salt(),
            &clock,
            ts::ctx(&mut scenario),
        );

        clock::destroy_for_testing(clock);
    };

    ts::end(scenario);
}

// === get_params Tests ===

#[test]
fun test_get_params_from_revealed() {
    let sender = @0xA;
    let mut scenario = setup_test(sender);

    ts::next_tx(&mut scenario, sender);
    {
        let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
        clock::set_for_testing(&mut clock, 10000);

        let params = 777u64;
        let salt = create_test_salt();
        let commitment = compute_commitment_hash(params, salt);

        let sealed = seal_commit_reveal::new_sealed_params(b"blob", commitment, 10000);
        let mut container = seal_commit_reveal::new_sealed_only<u64>(sealed);

        seal_commit_reveal::reveal(&mut container, params, salt, &clock, ts::ctx(&mut scenario));

        let retrieved = seal_commit_reveal::get_params(&container);
        assert!(*retrieved == 777, 0);

        clock::destroy_for_testing(clock);
    };

    ts::end(scenario);
}

#[test]
fun test_get_params_from_fallback() {
    let container = seal_commit_reveal::new_public(123u64);

    let params = seal_commit_reveal::get_params(&container);
    assert!(*params == 123, 0);
}

#[test]
fun test_get_params_prefers_revealed_over_fallback() {
    let sender = @0xA;
    let mut scenario = setup_test(sender);

    ts::next_tx(&mut scenario, sender);
    {
        let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
        clock::set_for_testing(&mut clock, 10000);

        let revealed_value = 999u64;
        let fallback_value = 111u64;
        let salt = create_test_salt();
        let commitment = compute_commitment_hash(revealed_value, salt);

        let sealed = seal_commit_reveal::new_sealed_params(b"blob", commitment, 10000);
        let mut container = seal_commit_reveal::new_sealed_with_fallback(sealed, fallback_value);

        // Before reveal - should use fallback
        let before_reveal = seal_commit_reveal::get_params(&container);
        assert!(*before_reveal == 111, 0);

        // After reveal - should use revealed value
        seal_commit_reveal::reveal(&mut container, revealed_value, salt, &clock, ts::ctx(&mut scenario));

        let after_reveal = seal_commit_reveal::get_params(&container);
        assert!(*after_reveal == 999, 1);

        clock::destroy_for_testing(clock);
    };

    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = seal_commit_reveal::EMissingParams)]
fun test_get_params_no_params_available() {
    let sealed = seal_commit_reveal::new_sealed_params(b"blob", b"commitment", 10000);
    let container = seal_commit_reveal::new_sealed_only<u64>(sealed);

    // No revealed params, no fallback - should abort
    let _params = seal_commit_reveal::get_params(&container);
}

// === has_params Tests ===

#[test]
fun test_has_params_sealed_only_not_revealed() {
    let sealed = seal_commit_reveal::new_sealed_params(b"blob", b"commitment", 10000);
    let container = seal_commit_reveal::new_sealed_only<u64>(sealed);

    assert!(!seal_commit_reveal::has_params(&container), 0);
}

#[test]
fun test_has_params_with_fallback() {
    let sealed = seal_commit_reveal::new_sealed_params(b"blob", b"commitment", 10000);
    let container = seal_commit_reveal::new_sealed_with_fallback(sealed, 42u64);

    assert!(seal_commit_reveal::has_params(&container), 0);
}

#[test]
fun test_has_params_public() {
    let container = seal_commit_reveal::new_public(100u64);

    assert!(seal_commit_reveal::has_params(&container), 0);
}

#[test]
fun test_has_params_after_reveal() {
    let sender = @0xA;
    let mut scenario = setup_test(sender);

    ts::next_tx(&mut scenario, sender);
    {
        let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
        clock::set_for_testing(&mut clock, 10000);

        let params = 42u64;
        let salt = create_test_salt();
        let commitment = compute_commitment_hash(params, salt);

        let sealed = seal_commit_reveal::new_sealed_params(b"blob", commitment, 10000);
        let mut container = seal_commit_reveal::new_sealed_only<u64>(sealed);

        assert!(!seal_commit_reveal::has_params(&container), 0);

        seal_commit_reveal::reveal(&mut container, params, salt, &clock, ts::ctx(&mut scenario));

        assert!(seal_commit_reveal::has_params(&container), 1);

        clock::destroy_for_testing(clock);
    };

    ts::end(scenario);
}

// === Mode Detection Tests ===

#[test]
fun test_get_mode_sealed() {
    let sealed = seal_commit_reveal::new_sealed_params(b"blob", b"commitment", 10000);
    let container = seal_commit_reveal::new_sealed_only<u64>(sealed);

    assert!(seal_commit_reveal::get_mode(&container) == 0, 0);
    assert!(seal_commit_reveal::get_mode(&container) == seal_commit_reveal::mode_sealed(), 1);
}

#[test]
fun test_get_mode_sealed_safe() {
    let sealed = seal_commit_reveal::new_sealed_params(b"blob", b"commitment", 10000);
    let container = seal_commit_reveal::new_sealed_with_fallback(sealed, 42u64);

    assert!(seal_commit_reveal::get_mode(&container) == 1, 0);
    assert!(seal_commit_reveal::get_mode(&container) == seal_commit_reveal::mode_sealed_safe(), 1);
}

#[test]
fun test_get_mode_public() {
    let container = seal_commit_reveal::new_public(100u64);

    assert!(seal_commit_reveal::get_mode(&container) == 2, 0);
    assert!(seal_commit_reveal::get_mode(&container) == seal_commit_reveal::mode_public(), 1);
}

// === State Check Tests ===

#[test]
fun test_is_revealed_false_initially() {
    let sealed = seal_commit_reveal::new_sealed_params(b"blob", b"commitment", 10000);
    let container = seal_commit_reveal::new_sealed_only<u64>(sealed);

    assert!(!seal_commit_reveal::is_revealed(&container), 0);
}

#[test]
fun test_is_revealed_true_after_reveal() {
    let sender = @0xA;
    let mut scenario = setup_test(sender);

    ts::next_tx(&mut scenario, sender);
    {
        let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
        clock::set_for_testing(&mut clock, 10000);

        let params = 42u64;
        let salt = create_test_salt();
        let commitment = compute_commitment_hash(params, salt);

        let sealed = seal_commit_reveal::new_sealed_params(b"blob", commitment, 10000);
        let mut container = seal_commit_reveal::new_sealed_only<u64>(sealed);

        seal_commit_reveal::reveal(&mut container, params, salt, &clock, ts::ctx(&mut scenario));

        assert!(seal_commit_reveal::is_revealed(&container), 0);

        clock::destroy_for_testing(clock);
    };

    ts::end(scenario);
}

#[test]
fun test_is_using_fallback_sealed_safe_before_reveal() {
    let sealed = seal_commit_reveal::new_sealed_params(b"blob", b"commitment", 10000);
    let container = seal_commit_reveal::new_sealed_with_fallback(sealed, 42u64);

    assert!(seal_commit_reveal::is_using_fallback(&container), 0);
}

#[test]
fun test_is_using_fallback_public() {
    let container = seal_commit_reveal::new_public(100u64);

    assert!(seal_commit_reveal::is_using_fallback(&container), 0);
}

#[test]
fun test_is_using_fallback_false_after_reveal() {
    let sender = @0xA;
    let mut scenario = setup_test(sender);

    ts::next_tx(&mut scenario, sender);
    {
        let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
        clock::set_for_testing(&mut clock, 10000);

        let params = 42u64;
        let salt = create_test_salt();
        let commitment = compute_commitment_hash(params, salt);

        let sealed = seal_commit_reveal::new_sealed_params(b"blob", commitment, 10000);
        let mut container = seal_commit_reveal::new_sealed_with_fallback(sealed, 99u64);

        assert!(seal_commit_reveal::is_using_fallback(&container), 0);

        seal_commit_reveal::reveal(&mut container, params, salt, &clock, ts::ctx(&mut scenario));

        assert!(!seal_commit_reveal::is_using_fallback(&container), 1);

        clock::destroy_for_testing(clock);
    };

    ts::end(scenario);
}

// === Accessor Tests ===

#[test]
fun test_reveal_time_ms_sealed() {
    let sealed = seal_commit_reveal::new_sealed_params(b"blob", b"commitment", 123456);
    let container = seal_commit_reveal::new_sealed_only<u64>(sealed);

    let reveal_time_opt = seal_commit_reveal::reveal_time_ms(&container);
    assert!(reveal_time_opt.is_some(), 0);
    assert!(reveal_time_opt.destroy_some() == 123456, 1);
}

#[test]
fun test_reveal_time_ms_public() {
    let container = seal_commit_reveal::new_public(100u64);

    let reveal_time_opt = seal_commit_reveal::reveal_time_ms(&container);
    assert!(reveal_time_opt.is_none(), 0);
}

#[test]
fun test_blob_id_sealed() {
    let blob_id_value = b"my_blob_id_12345";
    let sealed = seal_commit_reveal::new_sealed_params(blob_id_value, b"commitment", 10000);
    let container = seal_commit_reveal::new_sealed_only<u64>(sealed);

    let blob_id_opt = seal_commit_reveal::blob_id(&container);
    assert!(blob_id_opt.is_some(), 0);
    assert!(blob_id_opt.destroy_some() == blob_id_value, 1);
}

#[test]
fun test_blob_id_public() {
    let container = seal_commit_reveal::new_public(100u64);

    let blob_id_opt = seal_commit_reveal::blob_id(&container);
    assert!(blob_id_opt.is_none(), 0);
}

// === Constants Tests ===

#[test]
fun test_mode_constants() {
    assert!(seal_commit_reveal::mode_sealed() == 0, 0);
    assert!(seal_commit_reveal::mode_sealed_safe() == 1, 1);
    assert!(seal_commit_reveal::mode_public() == 2, 2);
}

// === Integration Tests ===

#[test]
fun test_full_seal_workflow_mode_sealed() {
    let sender = @0xA;
    let mut scenario = setup_test(sender);

    ts::next_tx(&mut scenario, sender);
    {
        let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
        clock::set_for_testing(&mut clock, 5000);

        // Step 1: Create commitment
        let params = 12345u64;
        let salt = create_test_salt();
        let commitment = compute_commitment_hash(params, salt);

        // Step 2: Create sealed container
        let sealed = seal_commit_reveal::new_sealed_params(b"walrus_blob_123", commitment, 10000);
        let mut container = seal_commit_reveal::new_sealed_only<u64>(sealed);

        // Verify initial state
        assert!(seal_commit_reveal::get_mode(&container) == seal_commit_reveal::mode_sealed(), 0);
        assert!(!seal_commit_reveal::has_params(&container), 1);
        assert!(!seal_commit_reveal::is_revealed(&container), 2);

        // Step 3: Time passes, reveal time reached
        clock::set_for_testing(&mut clock, 10000);

        // Step 4: Reveal params
        seal_commit_reveal::reveal(&mut container, params, salt, &clock, ts::ctx(&mut scenario));

        // Verify final state
        assert!(seal_commit_reveal::is_revealed(&container), 3);
        assert!(seal_commit_reveal::has_params(&container), 4);

        let retrieved = seal_commit_reveal::get_params(&container);
        assert!(*retrieved == 12345, 5);

        clock::destroy_for_testing(clock);
    };

    ts::end(scenario);
}

#[test]
fun test_full_seal_workflow_mode_sealed_safe() {
    let sender = @0xA;
    let mut scenario = setup_test(sender);

    ts::next_tx(&mut scenario, sender);
    {
        let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
        clock::set_for_testing(&mut clock, 5000);

        let revealed_value = 999u64;
        let fallback_value = 555u64;
        let salt = create_test_salt();
        let commitment = compute_commitment_hash(revealed_value, salt);

        let sealed = seal_commit_reveal::new_sealed_params(b"blob", commitment, 10000);
        let mut container = seal_commit_reveal::new_sealed_with_fallback(sealed, fallback_value);

        // Verify mode
        assert!(seal_commit_reveal::get_mode(&container) == seal_commit_reveal::mode_sealed_safe(), 0);

        // Before reveal - uses fallback
        assert!(seal_commit_reveal::has_params(&container), 1);
        assert!(seal_commit_reveal::is_using_fallback(&container), 2);
        let before = seal_commit_reveal::get_params(&container);
        assert!(*before == 555, 3);

        // Reveal
        clock::set_for_testing(&mut clock, 10000);
        seal_commit_reveal::reveal(&mut container, revealed_value, salt, &clock, ts::ctx(&mut scenario));

        // After reveal - uses revealed value
        assert!(!seal_commit_reveal::is_using_fallback(&container), 4);
        let after = seal_commit_reveal::get_params(&container);
        assert!(*after == 999, 5);

        clock::destroy_for_testing(clock);
    };

    ts::end(scenario);
}

#[test]
fun test_full_seal_workflow_mode_public() {
    let params = 777u64;
    let container = seal_commit_reveal::new_public(params);

    // Verify mode
    assert!(seal_commit_reveal::get_mode(&container) == seal_commit_reveal::mode_public(), 0);

    // Always has params
    assert!(seal_commit_reveal::has_params(&container), 1);
    assert!(seal_commit_reveal::is_using_fallback(&container), 2);

    // Can get params immediately
    let retrieved = seal_commit_reveal::get_params(&container);
    assert!(*retrieved == 777, 3);

    // No sealed params
    assert!(seal_commit_reveal::blob_id(&container).is_none(), 4);
    assert!(seal_commit_reveal::reveal_time_ms(&container).is_none(), 5);
}
