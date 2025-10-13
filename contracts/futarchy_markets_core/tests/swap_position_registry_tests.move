#[test_only]
module futarchy_markets_core::swap_position_registry_tests;

use sui::test_scenario::{Self as ts};
use sui::clock::{Self, Clock};
use sui::coin::{Self, Coin};
use futarchy_markets_core::swap_position_registry::{Self, SwapPositionRegistry, CrankProgress};
use futarchy_markets_core::proposal::{Self, Proposal};
use futarchy_markets_primitives::coin_escrow::{Self, TokenEscrow};
use futarchy_one_shot_utils::test_coin_a::TEST_COIN_A;
use futarchy_one_shot_utils::test_coin_b::TEST_COIN_B;

// === Test Helpers ===

/// Create a test registry
#[test_only]
fun create_test_registry<AssetType, StableType>(
    ctx: &mut TxContext,
): SwapPositionRegistry<AssetType, StableType> {
    swap_position_registry::new<AssetType, StableType>(ctx)
}

/// Create a test proposal (simplified mock)
#[test_only]
fun create_test_proposal<AssetType, StableType>(
    outcome_count: u8,
    winning_outcome: u64,
    is_finalized: bool,
    ctx: &mut TxContext,
): Proposal<AssetType, StableType> {
    proposal::create_test_proposal(outcome_count, winning_outcome, is_finalized, ctx)
}

/// Create test escrow
#[test_only]
fun create_test_escrow<AssetType, StableType>(
    outcome_count: u8,
    ctx: &mut TxContext,
): TokenEscrow<AssetType, StableType> {
    coin_escrow::create_test_escrow((outcome_count as u64), ctx)
}

/// Cleanup registry
#[test_only]
fun destroy_registry<AssetType, StableType>(registry: SwapPositionRegistry<AssetType, StableType>) {
    swap_position_registry::destroy_for_testing(registry);
}

// === Registry Creation Tests ===

#[test]
fun test_create_registry_success() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    let registry = create_test_registry<TEST_COIN_A, TEST_COIN_B>(ctx);

    // Verify initial state
    assert!(swap_position_registry::total_positions(&registry) == 0, 0);
    assert!(swap_position_registry::total_cranked(&registry) == 0, 1);

    destroy_registry(registry);
    ts::end(scenario);
}

// === Store Position Tests ===

#[test]
fun test_store_conditional_asset_creates_new_position() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    let mut registry = create_test_registry<TEST_COIN_A, TEST_COIN_B>(ctx);
    let mut clock = clock::create_for_testing(ctx);
    clock::set_for_testing(&mut clock, 1000000);

    let owner = @0xAAA;
    let mut proposal = create_test_proposal<TEST_COIN_A, TEST_COIN_B>(2, 1, true, ctx);
    let proposal_id = object::id(&proposal);
    let outcome_index = 0;
    let amount = 1_000_000;

    // Create conditional coin (using TEST_COIN_A as mock conditional type)
    let conditional_coin = coin::mint_for_testing<TEST_COIN_A>(amount, ctx);

    // Store asset coin
    let created = swap_position_registry::store_conditional_asset(
        &mut registry,
        owner,
        proposal_id,
        outcome_index,
        conditional_coin,
        &clock,
        ctx,
    );

    // Verify new position created
    assert!(created, 0);
    assert!(swap_position_registry::total_positions(&registry) == 1, 1);
    assert!(swap_position_registry::has_position(&registry, owner, proposal_id), 2);

    // Cleanup: crank position before destroying
    let progress = swap_position_registry::start_crank(&mut registry, owner, &proposal);
    swap_position_registry::finish_crank(progress, &mut registry, &clock, ctx);

    proposal::destroy_for_testing(proposal);
    destroy_registry(registry);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
fun test_store_conditional_asset_merges_existing_position() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    let mut registry = create_test_registry<TEST_COIN_A, TEST_COIN_B>(ctx);
    let mut clock = clock::create_for_testing(ctx);
    clock::set_for_testing(&mut clock, 1000000);

    let owner = @0xAAA;
    let mut proposal = create_test_proposal<TEST_COIN_A, TEST_COIN_B>(2, 1, true, ctx);
    let proposal_id = object::id(&proposal);
    let outcome_index = 0;

    // Store first coin
    let coin1 = coin::mint_for_testing<TEST_COIN_A>(500_000, ctx);
    let created1 = swap_position_registry::store_conditional_asset(
        &mut registry,
        owner,
        proposal_id,
        outcome_index,
        coin1,
        &clock,
        ctx,
    );
    assert!(created1, 0);

    // Store second coin (should merge)
    let coin2 = coin::mint_for_testing<TEST_COIN_A>(500_000, ctx);
    let created2 = swap_position_registry::store_conditional_asset(
        &mut registry,
        owner,
        proposal_id,
        outcome_index,
        coin2,
        &clock,
        ctx,
    );

    // Verify merge (not new creation)
    assert!(!created2, 1);
    assert!(swap_position_registry::total_positions(&registry) == 1, 2);

    // Cleanup: crank position before destroying
    let progress = swap_position_registry::start_crank(&mut registry, owner, &proposal);
    swap_position_registry::finish_crank(progress, &mut registry, &clock, ctx);

    proposal::destroy_for_testing(proposal);
    destroy_registry(registry);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
fun test_store_conditional_stable_creates_new_position() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    let mut registry = create_test_registry<TEST_COIN_A, TEST_COIN_B>(ctx);
    let mut clock = clock::create_for_testing(ctx);
    clock::set_for_testing(&mut clock, 1000000);

    let owner = @0xBBB;
    let mut proposal = create_test_proposal<TEST_COIN_A, TEST_COIN_B>(2, 1, true, ctx);
    let proposal_id = object::id(&proposal);
    let outcome_index = 1;
    let amount = 2_000_000;

    let conditional_coin = coin::mint_for_testing<TEST_COIN_B>(amount, ctx);

    let created = swap_position_registry::store_conditional_stable(
        &mut registry,
        owner,
        proposal_id,
        outcome_index,
        conditional_coin,
        &clock,
        ctx,
    );

    assert!(created, 0);
    assert!(swap_position_registry::has_position(&registry, owner, proposal_id), 1);

    // Cleanup: crank position before destroying
    let progress = swap_position_registry::start_crank(&mut registry, owner, &proposal);
    swap_position_registry::finish_crank(progress, &mut registry, &clock, ctx);

    proposal::destroy_for_testing(proposal);
    destroy_registry(registry);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = 4)] // EZeroAmount
fun test_store_zero_amount_asset_fails() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    let mut registry = create_test_registry<TEST_COIN_A, TEST_COIN_B>(ctx);
    let mut clock = clock::create_for_testing(ctx);
    clock::set_for_testing(&mut clock, 1000000);

    let owner = @0xAAA;
    let proposal_id = object::id_from_address(@0x100);
    let zero_coin = coin::zero<TEST_COIN_A>(ctx);

    let _created = swap_position_registry::store_conditional_asset(
        &mut registry,
        owner,
        proposal_id,
        0,
        zero_coin,
        &clock,
        ctx,
    );

    destroy_registry(registry);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = 4)] // EZeroAmount
fun test_store_zero_amount_stable_fails() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    let mut registry = create_test_registry<TEST_COIN_A, TEST_COIN_B>(ctx);
    let mut clock = clock::create_for_testing(ctx);
    clock::set_for_testing(&mut clock, 1000000);

    let owner = @0xBBB;
    let proposal_id = object::id_from_address(@0x200);
    let zero_coin = coin::zero<TEST_COIN_B>(ctx);

    let _created = swap_position_registry::store_conditional_stable(
        &mut registry,
        owner,
        proposal_id,
        1,
        zero_coin,
        &clock,
        ctx,
    );

    destroy_registry(registry);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
fun test_store_multiple_outcomes_same_position() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    let mut registry = create_test_registry<TEST_COIN_A, TEST_COIN_B>(ctx);
    let mut clock = clock::create_for_testing(ctx);
    clock::set_for_testing(&mut clock, 1000000);

    let owner = @0xAAA;
    let mut proposal = create_test_proposal<TEST_COIN_A, TEST_COIN_B>(2, 1, true, ctx);
    let proposal_id = object::id(&proposal);

    // Store outcome 0 asset
    let coin0_asset = coin::mint_for_testing<TEST_COIN_A>(100_000, ctx);
    let created1 = swap_position_registry::store_conditional_asset(
        &mut registry, owner, proposal_id, 0, coin0_asset, &clock, ctx
    );
    assert!(created1, 0);

    // Store outcome 1 asset (should merge into same position)
    let coin1_asset = coin::mint_for_testing<TEST_COIN_A>(200_000, ctx);
    let created2 = swap_position_registry::store_conditional_asset(
        &mut registry, owner, proposal_id, 1, coin1_asset, &clock, ctx
    );
    assert!(!created2, 1);

    // Store outcome 0 stable (should merge)
    let coin0_stable = coin::mint_for_testing<TEST_COIN_B>(300_000, ctx);
    let created3 = swap_position_registry::store_conditional_stable(
        &mut registry, owner, proposal_id, 0, coin0_stable, &clock, ctx
    );
    assert!(!created3, 2);

    // Verify only one position created
    assert!(swap_position_registry::total_positions(&registry) == 1, 3);

    // Cleanup: crank position before destroying
    let progress = swap_position_registry::start_crank(&mut registry, owner, &proposal);
    swap_position_registry::finish_crank(progress, &mut registry, &clock, ctx);

    proposal::destroy_for_testing(proposal);
    destroy_registry(registry);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

// === Cranking Tests (PTB + Hot Potato Pattern) ===

#[test]
fun test_start_crank_success() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    let mut registry = create_test_registry<TEST_COIN_A, TEST_COIN_B>(ctx);
    let mut clock = clock::create_for_testing(ctx);
    clock::set_for_testing(&mut clock, 1000000);

    let owner = @0xAAA;
    let outcome_count = 2u8;
    let winning_outcome = 1u64;
    let mut proposal = create_test_proposal<TEST_COIN_A, TEST_COIN_B>(
        outcome_count, winning_outcome, true, ctx
    );
    let proposal_id = object::id(&proposal);

    // Store position
    let coin = coin::mint_for_testing<TEST_COIN_A>(1_000_000, ctx);
    swap_position_registry::store_conditional_asset(
        &mut registry, owner, proposal_id, 0, coin, &clock, ctx
    );

    // Start crank
    let progress = swap_position_registry::start_crank(&mut registry, owner, &proposal);

    // Verify position removed from registry
    assert!(swap_position_registry::total_positions(&registry) == 0, 0);
    assert!(!swap_position_registry::has_position(&registry, owner, proposal_id), 1);

    // Must consume hot potato
    swap_position_registry::destroy_crank_progress_for_testing(progress);
    proposal::destroy_for_testing(proposal);
    destroy_registry(registry);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = 0)] // EPositionNotFound
fun test_start_crank_position_not_found() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    let mut registry = create_test_registry<TEST_COIN_A, TEST_COIN_B>(ctx);
    let owner = @0xAAA;
    let mut proposal = create_test_proposal<TEST_COIN_A, TEST_COIN_B>(2, 1, true, ctx);

    // Try to crank non-existent position (will abort before returning progress)
    let _progress = swap_position_registry::start_crank(&mut registry, owner, &proposal);

    // Unreachable cleanup (test aborts above)
    abort 0
}

#[test]
#[expected_failure(abort_code = 1)] // EProposalNotFinalized
fun test_start_crank_proposal_not_finalized() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    let mut registry = create_test_registry<TEST_COIN_A, TEST_COIN_B>(ctx);
    let mut clock = clock::create_for_testing(ctx);
    clock::set_for_testing(&mut clock, 1000000);

    let owner = @0xAAA;
    let mut proposal = create_test_proposal<TEST_COIN_A, TEST_COIN_B>(2, 1, false, ctx); // Not finalized
    let proposal_id = object::id(&proposal);

    // Store position
    let coin = coin::mint_for_testing<TEST_COIN_A>(1_000_000, ctx);
    swap_position_registry::store_conditional_asset(
        &mut registry, owner, proposal_id, 0, coin, &clock, ctx
    );

    // Try to crank before finalization (will abort before returning progress)
    let _progress = swap_position_registry::start_crank(&mut registry, owner, &proposal);

    // Unreachable cleanup (test aborts above)
    abort 0
}

#[test]
fun test_complete_crank_flow_with_winning_outcome() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    let mut registry = create_test_registry<TEST_COIN_A, TEST_COIN_B>(ctx);
    let mut clock = clock::create_for_testing(ctx);
    clock::set_for_testing(&mut clock, 1000000);
    let mut escrow = create_test_escrow<TEST_COIN_A, TEST_COIN_B>(2, ctx);

    let owner = @0xAAA;
    let winning_outcome = 1u64;
    let mut proposal = create_test_proposal<TEST_COIN_A, TEST_COIN_B>(2, winning_outcome, true, ctx);
    let proposal_id = object::id(&proposal);

    // Store winning outcome coins
    let asset_coin = coin::mint_for_testing<TEST_COIN_A>(1_000_000, ctx);
    swap_position_registry::store_conditional_asset(
        &mut registry, owner, proposal_id, winning_outcome, asset_coin, &clock, ctx
    );

    // Crank: start → unwrap → finish
    let progress = swap_position_registry::start_crank(&mut registry, owner, &proposal);

    // In real scenario, would call unwrap_one for each outcome
    // For testing, skip unwrap and go straight to finish
    swap_position_registry::finish_crank(progress, &mut registry, &clock, ctx);

    // Verify cranking completed
    assert!(swap_position_registry::total_cranked(&registry) == 1, 0);

    proposal::destroy_for_testing(proposal);
    coin_escrow::destroy_for_testing(escrow);
    destroy_registry(registry);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

// === View Function Tests ===

#[test]
fun test_has_position() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    let mut registry = create_test_registry<TEST_COIN_A, TEST_COIN_B>(ctx);
    let mut clock = clock::create_for_testing(ctx);
    clock::set_for_testing(&mut clock, 1000000);

    let owner1 = @0xAAA;
    let owner2 = @0xBBB;
    let mut proposal = create_test_proposal<TEST_COIN_A, TEST_COIN_B>(2, 1, true, ctx);
    let proposal_id = object::id(&proposal);

    // No position initially
    assert!(!swap_position_registry::has_position(&registry, owner1, proposal_id), 0);

    // Store position for owner1
    let coin = coin::mint_for_testing<TEST_COIN_A>(1_000_000, ctx);
    swap_position_registry::store_conditional_asset(
        &mut registry, owner1, proposal_id, 0, coin, &clock, ctx
    );

    // Verify owner1 has position, owner2 doesn't
    assert!(swap_position_registry::has_position(&registry, owner1, proposal_id), 1);
    assert!(!swap_position_registry::has_position(&registry, owner2, proposal_id), 2);

    // Cleanup: crank the position before destroying registry
    let progress = swap_position_registry::start_crank(&mut registry, owner1, &proposal);
    swap_position_registry::finish_crank(progress, &mut registry, &clock, ctx);

    proposal::destroy_for_testing(proposal);
    destroy_registry(registry);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
fun test_total_positions_tracking() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    let mut registry = create_test_registry<TEST_COIN_A, TEST_COIN_B>(ctx);
    let mut clock = clock::create_for_testing(ctx);
    clock::set_for_testing(&mut clock, 1000000);

    assert!(swap_position_registry::total_positions(&registry) == 0, 0);

    // Create proposals
    let mut proposal1 = create_test_proposal<TEST_COIN_A, TEST_COIN_B>(2, 1, true, ctx);
    let proposal_id1 = object::id(&proposal1);
    let mut proposal2 = create_test_proposal<TEST_COIN_A, TEST_COIN_B>(2, 0, true, ctx);
    let proposal_id2 = object::id(&proposal2);

    // Add position 1
    let coin1 = coin::mint_for_testing<TEST_COIN_A>(100_000, ctx);
    swap_position_registry::store_conditional_asset(
        &mut registry, @0xAAA, proposal_id1, 0, coin1, &clock, ctx
    );
    assert!(swap_position_registry::total_positions(&registry) == 1, 1);

    // Add position 2
    let coin2 = coin::mint_for_testing<TEST_COIN_A>(200_000, ctx);
    swap_position_registry::store_conditional_asset(
        &mut registry, @0xBBB, proposal_id2, 0, coin2, &clock, ctx
    );
    assert!(swap_position_registry::total_positions(&registry) == 2, 2);

    // Merge into position 1 (shouldn't increase count)
    let coin3 = coin::mint_for_testing<TEST_COIN_A>(300_000, ctx);
    swap_position_registry::store_conditional_asset(
        &mut registry, @0xAAA, proposal_id1, 1, coin3, &clock, ctx
    );
    assert!(swap_position_registry::total_positions(&registry) == 2, 3);

    // Cleanup: crank both positions
    let progress1 = swap_position_registry::start_crank(&mut registry, @0xAAA, &proposal1);
    swap_position_registry::finish_crank(progress1, &mut registry, &clock, ctx);
    let progress2 = swap_position_registry::start_crank(&mut registry, @0xBBB, &proposal2);
    swap_position_registry::finish_crank(progress2, &mut registry, &clock, ctx);

    proposal::destroy_for_testing(proposal1);
    proposal::destroy_for_testing(proposal2);
    destroy_registry(registry);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
fun test_total_cranked_tracking() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    let mut registry = create_test_registry<TEST_COIN_A, TEST_COIN_B>(ctx);
    let mut clock = clock::create_for_testing(ctx);
    clock::set_for_testing(&mut clock, 1000000);

    assert!(swap_position_registry::total_cranked(&registry) == 0, 0);

    // Create and crank position 1
    let mut proposal1 = create_test_proposal<TEST_COIN_A, TEST_COIN_B>(2, 1, true, ctx);
    let proposal_id1 = object::id(&proposal1);
    let coin1 = coin::mint_for_testing<TEST_COIN_A>(100_000, ctx);
    swap_position_registry::store_conditional_asset(
        &mut registry, @0xAAA, proposal_id1, 0, coin1, &clock, ctx
    );
    let progress1 = swap_position_registry::start_crank(&mut registry, @0xAAA, &proposal1);
    swap_position_registry::finish_crank(progress1, &mut registry, &clock, ctx);
    assert!(swap_position_registry::total_cranked(&registry) == 1, 1);

    // Create and crank position 2
    let mut proposal2 = create_test_proposal<TEST_COIN_A, TEST_COIN_B>(2, 0, true, ctx);
    let proposal_id2 = object::id(&proposal2);
    let coin2 = coin::mint_for_testing<TEST_COIN_A>(200_000, ctx);
    swap_position_registry::store_conditional_asset(
        &mut registry, @0xBBB, proposal_id2, 0, coin2, &clock, ctx
    );
    let progress2 = swap_position_registry::start_crank(&mut registry, @0xBBB, &proposal2);
    swap_position_registry::finish_crank(progress2, &mut registry, &clock, ctx);
    assert!(swap_position_registry::total_cranked(&registry) == 2, 2);

    proposal::destroy_for_testing(proposal1);
    proposal::destroy_for_testing(proposal2);
    destroy_registry(registry);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
fun test_get_cranking_metrics() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    let mut registry = create_test_registry<TEST_COIN_A, TEST_COIN_B>(ctx);
    let mut clock = clock::create_for_testing(ctx);
    clock::set_for_testing(&mut clock, 1000000);

    // Initial metrics
    let (active, cranked, success_rate) = swap_position_registry::get_cranking_metrics(&registry);
    assert!(active == 0, 0);
    assert!(cranked == 0, 1);
    assert!(success_rate == 0, 2);

    // Add position
    let mut proposal = create_test_proposal<TEST_COIN_A, TEST_COIN_B>(2, 1, true, ctx);
    let proposal_id = object::id(&proposal);
    let coin = coin::mint_for_testing<TEST_COIN_A>(100_000, ctx);
    swap_position_registry::store_conditional_asset(
        &mut registry, @0xAAA, proposal_id, 0, coin, &clock, ctx
    );

    // Metrics with active position
    let (active2, cranked2, success_rate2) = swap_position_registry::get_cranking_metrics(&registry);
    assert!(active2 == 1, 3);
    assert!(cranked2 == 0, 4);
    assert!(success_rate2 == 0, 5); // No cranks yet

    // Cleanup: crank the position before destroying registry
    let progress = swap_position_registry::start_crank(&mut registry, @0xAAA, &proposal);
    swap_position_registry::finish_crank(progress, &mut registry, &clock, ctx);

    proposal::destroy_for_testing(proposal);
    destroy_registry(registry);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
fun test_can_crank_position() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    let mut registry = create_test_registry<TEST_COIN_A, TEST_COIN_B>(ctx);
    let mut clock = clock::create_for_testing(ctx);
    clock::set_for_testing(&mut clock, 1000000);

    let owner = @0xAAA;
    let mut proposal_not_finalized = create_test_proposal<TEST_COIN_A, TEST_COIN_B>(2, 1, false, ctx);
    let mut proposal_finalized = create_test_proposal<TEST_COIN_A, TEST_COIN_B>(2, 1, true, ctx);
    let proposal_id_finalized = object::id(&proposal_finalized);

    // No position yet
    assert!(!swap_position_registry::can_crank_position(&registry, owner, &proposal_finalized), 0);

    // Add position
    let coin = coin::mint_for_testing<TEST_COIN_A>(100_000, ctx);
    swap_position_registry::store_conditional_asset(
        &mut registry, owner, proposal_id_finalized, 0, coin, &clock, ctx
    );

    // Can crank when finalized
    assert!(swap_position_registry::can_crank_position(&registry, owner, &proposal_finalized), 1);

    // Cannot crank when not finalized
    assert!(!swap_position_registry::can_crank_position(&registry, owner, &proposal_not_finalized), 2);

    // Cleanup: crank the position before destroying registry
    let progress = swap_position_registry::start_crank(&mut registry, owner, &proposal_finalized);
    swap_position_registry::finish_crank(progress, &mut registry, &clock, ctx);

    proposal::destroy_for_testing(proposal_not_finalized);
    proposal::destroy_for_testing(proposal_finalized);
    destroy_registry(registry);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
fun test_get_outcome_count_for_position() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    let mut registry = create_test_registry<TEST_COIN_A, TEST_COIN_B>(ctx);
    let mut clock = clock::create_for_testing(ctx);
    clock::set_for_testing(&mut clock, 1000000);

    let owner = @0xAAA;
    let outcome_count = 3u8;
    let mut proposal = create_test_proposal<TEST_COIN_A, TEST_COIN_B>(outcome_count, 1, true, ctx);
    let proposal_id = object::id(&proposal);

    // Store position
    let coin = coin::mint_for_testing<TEST_COIN_A>(100_000, ctx);
    swap_position_registry::store_conditional_asset(
        &mut registry, owner, proposal_id, 0, coin, &clock, ctx
    );

    // Get outcome count
    let count = swap_position_registry::get_outcome_count_for_position(&registry, owner, &proposal);
    assert!(count == (outcome_count as u64), 0);

    // Cleanup: crank the position before destroying registry
    let progress = swap_position_registry::start_crank(&mut registry, owner, &proposal);
    swap_position_registry::finish_crank(progress, &mut registry, &clock, ctx);

    proposal::destroy_for_testing(proposal);
    destroy_registry(registry);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = 0)] // EPositionNotFound
fun test_get_outcome_count_for_nonexistent_position() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    let registry = create_test_registry<TEST_COIN_A, TEST_COIN_B>(ctx);
    let mut proposal = create_test_proposal<TEST_COIN_A, TEST_COIN_B>(2, 1, true, ctx);

    // Try to get outcome count for non-existent position
    let _count = swap_position_registry::get_outcome_count_for_position(&registry, @0xAAA, &proposal);

    proposal::destroy_for_testing(proposal);
    destroy_registry(registry);
    ts::end(scenario);
}

// === Economic Helper Tests ===

#[test]
fun test_estimate_batch_cranking_profit() {
    let position_count = 10;
    let avg_value = 1_000_000_000; // $1000 in 6 decimals
    let fee_bps = 10; // 0.1%
    let gas_price = 1_000; // 1000 nanoSUI

    let (profit, batch_size) = swap_position_registry::estimate_batch_cranking_profit(
        position_count,
        avg_value,
        fee_bps,
        gas_price,
    );

    // Should return some profit and reasonable batch size
    assert!(batch_size <= 100, 0);
    assert!(batch_size <= position_count, 1);
}

#[test]
fun test_minimum_profitable_position_value() {
    let gas_cost_usd = 10_000; // $0.01 in 6 decimals
    let fee_bps = 10; // 0.1%

    let min_value = swap_position_registry::minimum_profitable_position_value(
        gas_cost_usd,
        fee_bps,
    );

    // Minimum should be: gas_cost * 10000 / fee_bps = 10_000 * 10000 / 10 = 10_000_000 ($10)
    assert!(min_value == 10_000_000, 0);
}

#[test]
fun test_minimum_profitable_position_value_zero_fee() {
    let gas_cost_usd = 10_000;
    let fee_bps = 0;

    let min_value = swap_position_registry::minimum_profitable_position_value(
        gas_cost_usd,
        fee_bps,
    );

    assert!(min_value == 0, 0);
}

#[test]
fun test_is_position_profitable_to_crank() {
    let position_value = 1_000_000_000; // $1000
    let fee_bps = 10; // 0.1%
    let gas_cost = 50_000; // $0.05

    // Fee earned: $1000 * 0.001 = $1 >> $0.05 gas cost
    let profitable = swap_position_registry::is_position_profitable_to_crank(
        position_value,
        fee_bps,
        gas_cost,
    );

    assert!(profitable, 0);
}

#[test]
fun test_is_position_not_profitable_to_crank() {
    let position_value = 10_000_000; // $10
    let fee_bps = 10; // 0.1%
    let gas_cost = 50_000; // $0.05

    // Fee earned: $10 * 0.001 = $0.01 < $0.05 gas cost
    let profitable = swap_position_registry::is_position_profitable_to_crank(
        position_value,
        fee_bps,
        gas_cost,
    );

    assert!(!profitable, 0);
}

#[test]
fun test_recommend_cranker_fee_bps() {
    let position_value = 1_000_000_000; // $1000
    let gas_cost = 10_000; // $0.01

    let recommended_fee = swap_position_registry::recommend_cranker_fee_bps(
        position_value,
        gas_cost,
    );

    // Should return a fee between 5 and 100 bps
    assert!(recommended_fee >= 5, 0);
    assert!(recommended_fee <= 100, 1);
}

#[test]
fun test_recommend_cranker_fee_bps_small_position() {
    let position_value = 100_000; // $0.10
    let gas_cost = 10_000; // $0.01

    let recommended_fee = swap_position_registry::recommend_cranker_fee_bps(
        position_value,
        gas_cost,
    );

    // Small position should get capped at max 100 bps
    assert!(recommended_fee == 100, 0);
}

#[test]
fun test_recommend_cranker_fee_bps_large_position() {
    let position_value = 100_000_000_000; // $100,000
    let gas_cost = 10_000; // $0.01

    let recommended_fee = swap_position_registry::recommend_cranker_fee_bps(
        position_value,
        gas_cost,
    );

    // Large position should get minimum fee (5 bps)
    assert!(recommended_fee == 5, 0);
}

// === Edge Case Tests ===

#[test]
fun test_multiple_users_same_proposal() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    let mut registry = create_test_registry<TEST_COIN_A, TEST_COIN_B>(ctx);
    let mut clock = clock::create_for_testing(ctx);
    clock::set_for_testing(&mut clock, 1000000);

    let mut proposal = create_test_proposal<TEST_COIN_A, TEST_COIN_B>(2, 1, true, ctx);
    let proposal_id = object::id(&proposal);
    let user1 = @0xAAA;
    let user2 = @0xBBB;
    let user3 = @0xCCC;

    // Each user stores position for same proposal
    let coin1 = coin::mint_for_testing<TEST_COIN_A>(100_000, ctx);
    swap_position_registry::store_conditional_asset(&mut registry, user1, proposal_id, 0, coin1, &clock, ctx);

    let coin2 = coin::mint_for_testing<TEST_COIN_A>(200_000, ctx);
    swap_position_registry::store_conditional_asset(&mut registry, user2, proposal_id, 0, coin2, &clock, ctx);

    let coin3 = coin::mint_for_testing<TEST_COIN_A>(300_000, ctx);
    swap_position_registry::store_conditional_asset(&mut registry, user3, proposal_id, 0, coin3, &clock, ctx);

    // Should have 3 separate positions
    assert!(swap_position_registry::total_positions(&registry) == 3, 0);
    assert!(swap_position_registry::has_position(&registry, user1, proposal_id), 1);
    assert!(swap_position_registry::has_position(&registry, user2, proposal_id), 2);
    assert!(swap_position_registry::has_position(&registry, user3, proposal_id), 3);

    // Cleanup: crank all 3 positions before destroying registry
    let progress1 = swap_position_registry::start_crank(&mut registry, user1, &proposal);
    swap_position_registry::finish_crank(progress1, &mut registry, &clock, ctx);
    let progress2 = swap_position_registry::start_crank(&mut registry, user2, &proposal);
    swap_position_registry::finish_crank(progress2, &mut registry, &clock, ctx);
    let progress3 = swap_position_registry::start_crank(&mut registry, user3, &proposal);
    swap_position_registry::finish_crank(progress3, &mut registry, &clock, ctx);

    proposal::destroy_for_testing(proposal);
    destroy_registry(registry);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
fun test_same_user_multiple_proposals() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    let mut registry = create_test_registry<TEST_COIN_A, TEST_COIN_B>(ctx);
    let mut clock = clock::create_for_testing(ctx);
    clock::set_for_testing(&mut clock, 1000000);

    let owner = @0xAAA;
    let mut proposal1 = create_test_proposal<TEST_COIN_A, TEST_COIN_B>(2, 1, true, ctx);
    let proposal_id1 = object::id(&proposal1);
    let mut proposal2 = create_test_proposal<TEST_COIN_A, TEST_COIN_B>(2, 0, true, ctx);
    let proposal_id2 = object::id(&proposal2);
    let mut proposal3 = create_test_proposal<TEST_COIN_A, TEST_COIN_B>(2, 1, true, ctx);
    let proposal_id3 = object::id(&proposal3);

    // User stores positions for 3 different proposals
    let coin1 = coin::mint_for_testing<TEST_COIN_A>(100_000, ctx);
    swap_position_registry::store_conditional_asset(&mut registry, owner, proposal_id1, 0, coin1, &clock, ctx);

    let coin2 = coin::mint_for_testing<TEST_COIN_A>(200_000, ctx);
    swap_position_registry::store_conditional_asset(&mut registry, owner, proposal_id2, 0, coin2, &clock, ctx);

    let coin3 = coin::mint_for_testing<TEST_COIN_A>(300_000, ctx);
    swap_position_registry::store_conditional_asset(&mut registry, owner, proposal_id3, 0, coin3, &clock, ctx);

    // Should have 3 separate positions
    assert!(swap_position_registry::total_positions(&registry) == 3, 0);
    assert!(swap_position_registry::has_position(&registry, owner, proposal_id1), 1);
    assert!(swap_position_registry::has_position(&registry, owner, proposal_id2), 2);
    assert!(swap_position_registry::has_position(&registry, owner, proposal_id3), 3);

    // Cleanup: crank all 3 positions before destroying registry
    let progress1 = swap_position_registry::start_crank(&mut registry, owner, &proposal1);
    swap_position_registry::finish_crank(progress1, &mut registry, &clock, ctx);
    let progress2 = swap_position_registry::start_crank(&mut registry, owner, &proposal2);
    swap_position_registry::finish_crank(progress2, &mut registry, &clock, ctx);
    let progress3 = swap_position_registry::start_crank(&mut registry, owner, &proposal3);
    swap_position_registry::finish_crank(progress3, &mut registry, &clock, ctx);

    proposal::destroy_for_testing(proposal1);
    proposal::destroy_for_testing(proposal2);
    proposal::destroy_for_testing(proposal3);
    destroy_registry(registry);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
fun test_crank_removes_position_from_registry() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    let mut registry = create_test_registry<TEST_COIN_A, TEST_COIN_B>(ctx);
    let mut clock = clock::create_for_testing(ctx);
    clock::set_for_testing(&mut clock, 1000000);

    let owner = @0xAAA;
    let mut proposal = create_test_proposal<TEST_COIN_A, TEST_COIN_B>(2, 1, true, ctx);
    let proposal_id = object::id(&proposal);

    // Store position
    let coin = coin::mint_for_testing<TEST_COIN_A>(100_000, ctx);
    swap_position_registry::store_conditional_asset(&mut registry, owner, proposal_id, 0, coin, &clock, ctx);
    assert!(swap_position_registry::total_positions(&registry) == 1, 0);

    // Start crank (removes from registry)
    let progress = swap_position_registry::start_crank(&mut registry, owner, &proposal);
    assert!(swap_position_registry::total_positions(&registry) == 0, 1);
    assert!(!swap_position_registry::has_position(&registry, owner, proposal_id), 2);

    // Finish crank
    swap_position_registry::finish_crank(progress, &mut registry, &clock, ctx);
    assert!(swap_position_registry::total_cranked(&registry) == 1, 3);

    proposal::destroy_for_testing(proposal);
    destroy_registry(registry);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}
