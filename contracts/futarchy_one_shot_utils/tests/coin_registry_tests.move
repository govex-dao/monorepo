#[test_only]
module futarchy_one_shot_utils::coin_registry_tests;

use futarchy_one_shot_utils::coin_registry;
use futarchy_one_shot_utils::test_coin_a::TEST_COIN_A;
use futarchy_one_shot_utils::test_coin_b::TEST_COIN_B;
use sui::clock;
use sui::coin::{Self, TreasuryCap, CoinMetadata};
use sui::sui::SUI;
use sui::test_scenario as ts;

// === Basic Tests ===

#[test]
fun test_create_empty_registry() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    // Create registry
    let registry = coin_registry::create_registry(ctx);

    // Verify it's empty
    assert!(coin_registry::total_sets(&registry) == 0, 0);

    // Destroy empty registry
    coin_registry::destroy_empty_registry(registry);

    ts::end(scenario);
}

#[test]
fun test_share_registry() {
    let mut scenario = ts::begin(@0x1);

    // Create and share registry
    let registry = coin_registry::create_registry(ts::ctx(&mut scenario));
    coin_registry::share_registry(registry);

    ts::next_tx(&mut scenario, @0x1);

    // Registry should be shared now
    let registry = ts::take_shared<coin_registry::CoinRegistry>(&scenario);
    assert!(coin_registry::total_sets(&registry) == 0, 0);

    ts::return_shared(registry);
    ts::end(scenario);
}

// === Deposit Tests ===

#[test]
fun test_deposit_single_coin_set() {
    let mut scenario = ts::begin(@0x1);

    // Initialize test coin
    futarchy_one_shot_utils::test_coin_a::init_for_testing(ts::ctx(&mut scenario));
    ts::next_tx(&mut scenario, @0x1);

    // Get the created treasury cap and metadata
    let treasury_cap = ts::take_from_sender<TreasuryCap<TEST_COIN_A>>(&scenario);
    let metadata = ts::take_from_sender<CoinMetadata<TEST_COIN_A>>(&scenario);

    let cap_id = object::id(&treasury_cap);
    let clock = clock::create_for_testing(ts::ctx(&mut scenario));
    let mut registry = coin_registry::create_registry(ts::ctx(&mut scenario));

    // Deposit coin set with fee
    coin_registry::deposit_coin_set(
        &mut registry,
        treasury_cap,
        metadata,
        1_000_000, // 1 SUI fee
        &clock,
        ts::ctx(&mut scenario),
    );

    // Verify registry state
    assert!(coin_registry::total_sets(&registry) == 1, 0);
    assert!(coin_registry::has_coin_set(&registry, cap_id), 1);
    assert!(coin_registry::get_fee<TEST_COIN_A>(&registry, cap_id) == 1_000_000, 2);
    assert!(coin_registry::get_owner<TEST_COIN_A>(&registry, cap_id) == @0x1, 3);

    sui::test_utils::destroy(registry);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
fun test_deposit_multiple_coin_sets() {
    let mut scenario = ts::begin(@0x1);

    // Initialize test coins
    futarchy_one_shot_utils::test_coin_a::init_for_testing(ts::ctx(&mut scenario));
    futarchy_one_shot_utils::test_coin_b::init_for_testing(ts::ctx(&mut scenario));
    ts::next_tx(&mut scenario, @0x1);

    let treasury_cap_a = ts::take_from_sender<TreasuryCap<TEST_COIN_A>>(&scenario);
    let metadata_a = ts::take_from_sender<CoinMetadata<TEST_COIN_A>>(&scenario);
    let treasury_cap_b = ts::take_from_sender<TreasuryCap<TEST_COIN_B>>(&scenario);
    let metadata_b = ts::take_from_sender<CoinMetadata<TEST_COIN_B>>(&scenario);

    let clock = clock::create_for_testing(ts::ctx(&mut scenario));
    let mut registry = coin_registry::create_registry(ts::ctx(&mut scenario));

    // Deposit first coin set
    coin_registry::deposit_coin_set(
        &mut registry,
        treasury_cap_a,
        metadata_a,
        1_000_000,
        &clock,
        ts::ctx(&mut scenario),
    );

    // Deposit second coin set
    coin_registry::deposit_coin_set(
        &mut registry,
        treasury_cap_b,
        metadata_b,
        2_000_000,
        &clock,
        ts::ctx(&mut scenario),
    );

    // Verify registry state
    assert!(coin_registry::total_sets(&registry) == 2, 0);

    sui::test_utils::destroy(registry);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

// === Take Tests ===

#[test]
fun test_take_coin_set() {
    let mut scenario = ts::begin(@0x1);

    // Initialize test coin
    futarchy_one_shot_utils::test_coin_a::init_for_testing(ts::ctx(&mut scenario));
    ts::next_tx(&mut scenario, @0x1);

    let treasury_cap = ts::take_from_sender<TreasuryCap<TEST_COIN_A>>(&scenario);
    let metadata = ts::take_from_sender<CoinMetadata<TEST_COIN_A>>(&scenario);
    let cap_id = object::id(&treasury_cap);

    let clock = clock::create_for_testing(ts::ctx(&mut scenario));
    let mut registry = coin_registry::create_registry(ts::ctx(&mut scenario));

    // Deposit coin set
    coin_registry::deposit_coin_set(
        &mut registry,
        treasury_cap,
        metadata,
        1_000_000,
        &clock,
        ts::ctx(&mut scenario),
    );

    ts::next_tx(&mut scenario, @0x2);

    // Take coin set
    let payment = coin::mint_for_testing<SUI>(2_000_000, ts::ctx(&mut scenario));
    let remaining = coin_registry::take_coin_set<TEST_COIN_A>(
        &mut registry,
        cap_id,
        payment,
        &clock,
        ts::ctx(&mut scenario),
    );

    // Verify registry updated
    assert!(coin_registry::total_sets(&registry) == 0, 0);
    assert!(!coin_registry::has_coin_set(&registry, cap_id), 1);
    assert!(coin::value(&remaining) == 1_000_000, 2); // Got 1 SUI change

    coin::burn_for_testing(remaining);
    coin_registry::destroy_empty_registry(registry);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
fun test_take_multiple_coin_sets_in_sequence() {
    let mut scenario = ts::begin(@0x1);

    // Initialize test coins
    futarchy_one_shot_utils::test_coin_a::init_for_testing(ts::ctx(&mut scenario));
    futarchy_one_shot_utils::test_coin_b::init_for_testing(ts::ctx(&mut scenario));
    ts::next_tx(&mut scenario, @0x1);

    let treasury_cap_a = ts::take_from_sender<TreasuryCap<TEST_COIN_A>>(&scenario);
    let metadata_a = ts::take_from_sender<CoinMetadata<TEST_COIN_A>>(&scenario);
    let cap_id_a = object::id(&treasury_cap_a);

    let treasury_cap_b = ts::take_from_sender<TreasuryCap<TEST_COIN_B>>(&scenario);
    let metadata_b = ts::take_from_sender<CoinMetadata<TEST_COIN_B>>(&scenario);
    let cap_id_b = object::id(&treasury_cap_b);

    let clock = clock::create_for_testing(ts::ctx(&mut scenario));
    let mut registry = coin_registry::create_registry(ts::ctx(&mut scenario));

    // Deposit two coin sets
    coin_registry::deposit_coin_set(
        &mut registry,
        treasury_cap_a,
        metadata_a,
        500_000,
        &clock,
        ts::ctx(&mut scenario),
    );
    coin_registry::deposit_coin_set(
        &mut registry,
        treasury_cap_b,
        metadata_b,
        300_000,
        &clock,
        ts::ctx(&mut scenario),
    );

    ts::next_tx(&mut scenario, @0x2);

    // Take both in sequence (simulating PTB)
    let mut payment = coin::mint_for_testing<SUI>(1_000_000, ts::ctx(&mut scenario));

    payment =
        coin_registry::take_coin_set<TEST_COIN_A>(
            &mut registry,
            cap_id_a,
            payment,
            &clock,
            ts::ctx(&mut scenario),
        );
    assert!(coin::value(&payment) == 500_000, 0);

    payment =
        coin_registry::take_coin_set<TEST_COIN_B>(
            &mut registry,
            cap_id_b,
            payment,
            &clock,
            ts::ctx(&mut scenario),
        );
    assert!(coin::value(&payment) == 200_000, 1);

    // Registry should be empty
    assert!(coin_registry::total_sets(&registry) == 0, 2);

    coin::burn_for_testing(payment);
    coin_registry::destroy_empty_registry(registry);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
fun test_take_exact_fee_amount() {
    let mut scenario = ts::begin(@0x1);

    // Initialize test coin
    futarchy_one_shot_utils::test_coin_a::init_for_testing(ts::ctx(&mut scenario));
    ts::next_tx(&mut scenario, @0x1);

    let treasury_cap = ts::take_from_sender<TreasuryCap<TEST_COIN_A>>(&scenario);
    let metadata = ts::take_from_sender<CoinMetadata<TEST_COIN_A>>(&scenario);
    let cap_id = object::id(&treasury_cap);

    let clock = clock::create_for_testing(ts::ctx(&mut scenario));
    let mut registry = coin_registry::create_registry(ts::ctx(&mut scenario));

    coin_registry::deposit_coin_set(
        &mut registry,
        treasury_cap,
        metadata,
        1_000_000,
        &clock,
        ts::ctx(&mut scenario),
    );

    ts::next_tx(&mut scenario, @0x2);

    // Pay exact fee
    let payment = coin::mint_for_testing<SUI>(1_000_000, ts::ctx(&mut scenario));
    let remaining = coin_registry::take_coin_set<TEST_COIN_A>(
        &mut registry,
        cap_id,
        payment,
        &clock,
        ts::ctx(&mut scenario),
    );

    // Should have zero remaining
    assert!(coin::value(&remaining) == 0, 0);

    coin::burn_for_testing(remaining);
    coin_registry::destroy_empty_registry(registry);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

// === View Functions Tests ===

#[test]
fun test_view_functions() {
    let mut scenario = ts::begin(@0x1);

    // Initialize test coin
    futarchy_one_shot_utils::test_coin_a::init_for_testing(ts::ctx(&mut scenario));
    ts::next_tx(&mut scenario, @0x1);

    let treasury_cap = ts::take_from_sender<TreasuryCap<TEST_COIN_A>>(&scenario);
    let metadata = ts::take_from_sender<CoinMetadata<TEST_COIN_A>>(&scenario);
    let cap_id = object::id(&treasury_cap);

    let clock = clock::create_for_testing(ts::ctx(&mut scenario));
    let mut registry = coin_registry::create_registry(ts::ctx(&mut scenario));

    // Initially empty
    assert!(coin_registry::total_sets(&registry) == 0, 0);

    let fee = 1_500_000;
    let owner = @0x1;

    coin_registry::deposit_coin_set(
        &mut registry,
        treasury_cap,
        metadata,
        fee,
        &clock,
        ts::ctx(&mut scenario),
    );

    // Test view functions
    assert!(coin_registry::total_sets(&registry) == 1, 1);
    assert!(coin_registry::has_coin_set(&registry, cap_id), 2);
    assert!(coin_registry::get_fee<TEST_COIN_A>(&registry, cap_id) == fee, 3);
    assert!(coin_registry::get_owner<TEST_COIN_A>(&registry, cap_id) == owner, 4);
    assert!(coin_registry::validate_coin_set_in_registry(&registry, cap_id), 5);

    sui::test_utils::destroy(registry);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

// === Error Case Tests ===

#[test]
#[expected_failure(abort_code = 2)] // ERegistryNotEmpty
fun test_cannot_destroy_non_empty_registry() {
    let mut scenario = ts::begin(@0x1);

    // Initialize test coin
    futarchy_one_shot_utils::test_coin_a::init_for_testing(ts::ctx(&mut scenario));
    ts::next_tx(&mut scenario, @0x1);

    let treasury_cap = ts::take_from_sender<TreasuryCap<TEST_COIN_A>>(&scenario);
    let metadata = ts::take_from_sender<CoinMetadata<TEST_COIN_A>>(&scenario);

    let clock = clock::create_for_testing(ts::ctx(&mut scenario));
    let mut registry = coin_registry::create_registry(ts::ctx(&mut scenario));

    // Deposit coin set
    coin_registry::deposit_coin_set(
        &mut registry,
        treasury_cap,
        metadata,
        1_000_000,
        &clock,
        ts::ctx(&mut scenario),
    );

    // Try to destroy non-empty registry (should fail)
    coin_registry::destroy_empty_registry(registry);

    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = 1)] // EInsufficientFee
fun test_insufficient_fee() {
    let mut scenario = ts::begin(@0x1);

    // Initialize test coin
    futarchy_one_shot_utils::test_coin_a::init_for_testing(ts::ctx(&mut scenario));
    ts::next_tx(&mut scenario, @0x1);

    let treasury_cap = ts::take_from_sender<TreasuryCap<TEST_COIN_A>>(&scenario);
    let metadata = ts::take_from_sender<CoinMetadata<TEST_COIN_A>>(&scenario);
    let cap_id = object::id(&treasury_cap);

    let clock = clock::create_for_testing(ts::ctx(&mut scenario));
    let mut registry = coin_registry::create_registry(ts::ctx(&mut scenario));

    coin_registry::deposit_coin_set(
        &mut registry,
        treasury_cap,
        metadata,
        1_000_000,
        &clock,
        ts::ctx(&mut scenario),
    );

    ts::next_tx(&mut scenario, @0x2);

    // Try to take with insufficient payment (should fail)
    let payment = coin::mint_for_testing<SUI>(500_000, ts::ctx(&mut scenario));
    let remaining = coin_registry::take_coin_set<TEST_COIN_A>(
        &mut registry,
        cap_id,
        payment,
        &clock,
        ts::ctx(&mut scenario),
    );

    coin::burn_for_testing(remaining);
    sui::test_utils::destroy(registry);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = 0)] // ENoCoinSetsAvailable
fun test_take_nonexistent_coin_set() {
    let mut scenario = ts::begin(@0x1);
    let clock = clock::create_for_testing(ts::ctx(&mut scenario));

    let mut registry = coin_registry::create_registry(ts::ctx(&mut scenario));

    ts::next_tx(&mut scenario, @0x2);

    // Try to take nonexistent coin set (should fail)
    let payment = coin::mint_for_testing<SUI>(1_000_000, ts::ctx(&mut scenario));
    let fake_id = object::id_from_address(@0x999);
    let remaining = coin_registry::take_coin_set<TEST_COIN_A>(
        &mut registry,
        fake_id,
        payment,
        &clock,
        ts::ctx(&mut scenario),
    );

    coin::burn_for_testing(remaining);
    coin_registry::destroy_empty_registry(registry);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

// === Validation Tests ===

#[test]
#[expected_failure(abort_code = 0)] // ESupplyNotZero
fun test_deposit_coin_with_nonzero_supply() {
    let mut scenario = ts::begin(@0x1);

    // Initialize test coin
    futarchy_one_shot_utils::test_coin_a::init_for_testing(ts::ctx(&mut scenario));
    ts::next_tx(&mut scenario, @0x1);

    let mut treasury_cap = ts::take_from_sender<TreasuryCap<TEST_COIN_A>>(&scenario);
    let metadata = ts::take_from_sender<CoinMetadata<TEST_COIN_A>>(&scenario);

    // Mint some supply (violates zero supply requirement)
    let minted = coin::mint(&mut treasury_cap, 1000, ts::ctx(&mut scenario));
    coin::burn_for_testing(minted);

    let clock = clock::create_for_testing(ts::ctx(&mut scenario));
    let mut registry = coin_registry::create_registry(ts::ctx(&mut scenario));

    // Try to deposit with non-zero supply (should fail)
    coin_registry::deposit_coin_set(
        &mut registry,
        treasury_cap,
        metadata,
        1_000_000,
        &clock,
        ts::ctx(&mut scenario),
    );

    sui::test_utils::destroy(registry);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

// === Metadata Validation Tests ===

#[test]
#[expected_failure(abort_code = 3)] // ENameNotEmpty
fun test_reject_coin_with_name() {
    let mut scenario = ts::begin(@0x1);

    // Create coin with name set
    futarchy_one_shot_utils::test_coin_b::create_with_name(ts::ctx(&mut scenario));
    ts::next_tx(&mut scenario, @0x1);

    let treasury_cap = ts::take_from_sender<TreasuryCap<TEST_COIN_B>>(&scenario);
    let metadata = ts::take_from_sender<CoinMetadata<TEST_COIN_B>>(&scenario);

    let clock = clock::create_for_testing(ts::ctx(&mut scenario));
    let mut registry = coin_registry::create_registry(ts::ctx(&mut scenario));

    // Try to deposit coin with name (should fail)
    coin_registry::deposit_coin_set(
        &mut registry,
        treasury_cap,
        metadata,
        1_000_000,
        &clock,
        ts::ctx(&mut scenario),
    );

    sui::test_utils::destroy(registry);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = 4)] // EDescriptionNotEmpty
fun test_reject_coin_with_description() {
    let mut scenario = ts::begin(@0x1);

    // Create coin with description set
    futarchy_one_shot_utils::test_coin_b::create_with_description(ts::ctx(&mut scenario));
    ts::next_tx(&mut scenario, @0x1);

    let treasury_cap = ts::take_from_sender<TreasuryCap<TEST_COIN_B>>(&scenario);
    let metadata = ts::take_from_sender<CoinMetadata<TEST_COIN_B>>(&scenario);

    let clock = clock::create_for_testing(ts::ctx(&mut scenario));
    let mut registry = coin_registry::create_registry(ts::ctx(&mut scenario));

    // Try to deposit coin with description (should fail)
    coin_registry::deposit_coin_set(
        &mut registry,
        treasury_cap,
        metadata,
        1_000_000,
        &clock,
        ts::ctx(&mut scenario),
    );

    sui::test_utils::destroy(registry);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = 5)] // ESymbolNotEmpty
fun test_reject_coin_with_symbol() {
    let mut scenario = ts::begin(@0x1);

    // Create coin with symbol set
    futarchy_one_shot_utils::test_coin_b::create_with_symbol(ts::ctx(&mut scenario));
    ts::next_tx(&mut scenario, @0x1);

    let treasury_cap = ts::take_from_sender<TreasuryCap<TEST_COIN_B>>(&scenario);
    let metadata = ts::take_from_sender<CoinMetadata<TEST_COIN_B>>(&scenario);

    let clock = clock::create_for_testing(ts::ctx(&mut scenario));
    let mut registry = coin_registry::create_registry(ts::ctx(&mut scenario));

    // Try to deposit coin with symbol (should fail)
    coin_registry::deposit_coin_set(
        &mut registry,
        treasury_cap,
        metadata,
        1_000_000,
        &clock,
        ts::ctx(&mut scenario),
    );

    sui::test_utils::destroy(registry);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = 6)] // EIconUrlNotEmpty
fun test_reject_coin_with_icon() {
    let mut scenario = ts::begin(@0x1);

    // Create coin with icon URL set
    futarchy_one_shot_utils::test_coin_b::create_with_icon(ts::ctx(&mut scenario));
    ts::next_tx(&mut scenario, @0x1);

    let treasury_cap = ts::take_from_sender<TreasuryCap<TEST_COIN_B>>(&scenario);
    let metadata = ts::take_from_sender<CoinMetadata<TEST_COIN_B>>(&scenario);

    let clock = clock::create_for_testing(ts::ctx(&mut scenario));
    let mut registry = coin_registry::create_registry(ts::ctx(&mut scenario));

    // Try to deposit coin with icon (should fail)
    coin_registry::deposit_coin_set(
        &mut registry,
        treasury_cap,
        metadata,
        1_000_000,
        &clock,
        ts::ctx(&mut scenario),
    );

    sui::test_utils::destroy(registry);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = 3)] // ENameNotEmpty (first check that fails)
fun test_reject_coin_with_all_metadata() {
    let mut scenario = ts::begin(@0x1);

    // Create coin with all metadata set
    futarchy_one_shot_utils::test_coin_b::create_with_all_metadata(ts::ctx(&mut scenario));
    ts::next_tx(&mut scenario, @0x1);

    let treasury_cap = ts::take_from_sender<TreasuryCap<TEST_COIN_B>>(&scenario);
    let metadata = ts::take_from_sender<CoinMetadata<TEST_COIN_B>>(&scenario);

    let clock = clock::create_for_testing(ts::ctx(&mut scenario));
    let mut registry = coin_registry::create_registry(ts::ctx(&mut scenario));

    // Try to deposit coin with all metadata (should fail on first check - name)
    coin_registry::deposit_coin_set(
        &mut registry,
        treasury_cap,
        metadata,
        1_000_000,
        &clock,
        ts::ctx(&mut scenario),
    );

    sui::test_utils::destroy(registry);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

// === Coverage Tests for Uncovered Lines ===

#[test]
#[expected_failure(abort_code = 4)] // EFeeExceedsMaximum  
fun test_deposit_fee_exceeds_maximum() {
    let mut scenario = ts::begin(@0x1);
    
    // Initialize test coins
    futarchy_one_shot_utils::test_coin_b::init_for_testing(ts::ctx(&mut scenario));
    ts::next_tx(&mut scenario, @0x1);
    
    let treasury_cap = ts::take_from_sender<TreasuryCap<TEST_COIN_B>>(&scenario);
    let metadata = ts::take_from_sender<CoinMetadata<TEST_COIN_B>>(&scenario);
    
    let clock = clock::create_for_testing(ts::ctx(&mut scenario));
    let mut registry = coin_registry::create_registry(ts::ctx(&mut scenario));

    // Try to deposit with fee > MAX_FEE (10 SUI = 10_000_000_000 MIST)
    // This should hit line 111: assert!(fee <= MAX_FEE, EFeeExceedsMaximum);
    coin_registry::deposit_coin_set(
        &mut registry,
        treasury_cap,
        metadata,
        10_000_000_001, // Just over 10 SUI
        &clock,
        ts::ctx(&mut scenario),
    );

    sui::test_utils::destroy(registry);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
fun test_deposit_coin_set_entry() {
    let mut scenario = ts::begin(@0x1);
    
    // Initialize test coins
    futarchy_one_shot_utils::test_coin_b::init_for_testing(ts::ctx(&mut scenario));
    
    // Create and share registry
    let registry = coin_registry::create_registry(ts::ctx(&mut scenario));
    coin_registry::share_registry(registry);

    ts::next_tx(&mut scenario, @0x1);
    
    let treasury_cap = ts::take_from_sender<TreasuryCap<TEST_COIN_B>>(&scenario);
    let metadata = ts::take_from_sender<CoinMetadata<TEST_COIN_B>>(&scenario);
    let clock = clock::create_for_testing(ts::ctx(&mut scenario));

    // Get shared registry
    let mut registry = ts::take_shared<coin_registry::CoinRegistry>(&scenario);

    // Test the entry function (lines 142-150)
    coin_registry::deposit_coin_set_entry(
        &mut registry,
        treasury_cap,
        metadata,
        1_000_000, // 0.001 SUI
        &clock,
        ts::ctx(&mut scenario),
    );

    // Verify deposit succeeded
    assert!(coin_registry::total_sets(&registry) == 1, 0);

    ts::return_shared(registry);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}
