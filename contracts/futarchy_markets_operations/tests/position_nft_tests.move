// Copyright 2024 FutarchyDAO
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module futarchy_markets_operations::position_nft_tests;

use std::string::{Self};
use std::option::{Self};
use sui::test_scenario::{Self as ts, Scenario};
use sui::clock::{Self, Clock};
use sui::object::{Self, ID};
use sui::test_utils;
use sui::tx_context::{Self};

use futarchy_markets_operations::position_nft::{Self, SpotLPPosition, ConditionalLPPosition};

// Test coin types
public struct TEST_ASSET has drop {}
public struct TEST_STABLE has drop {}

// Helper to create a test clock
fun create_clock(scenario: &mut Scenario): Clock {
    clock::create_for_testing(ts::ctx(scenario))
}

// Helper to advance clock
fun advance_clock(clock: &mut Clock, ms: u64) {
    clock::increment_for_testing(clock, ms);
}

// ===========================
// Spot Position Basic Tests
// ===========================

#[test]
fun test_mint_spot_position_basic() {
    let mut scenario = ts::begin(@0xA);
    let clock = create_clock(&mut scenario);

    ts::next_tx(&mut scenario, @0xA);
    {
        let pool_id = object::id_from_address(@0xBEEF);
        let lp_amount = 1000u64;
        let fee_bps = 30u64;

        let position = position_nft::mint_spot_position<TEST_ASSET, TEST_STABLE>(
            pool_id,
            lp_amount,
            fee_bps,
            &clock,
            ts::ctx(&mut scenario)
        );

        // Verify position data
        let (pos_pool_id, pos_lp_amount, _asset_type, _stable_type, pos_fee_bps) =
            position_nft::get_spot_position_info(&position);

        assert!(pos_pool_id == pool_id, 0);
        assert!(pos_lp_amount == lp_amount, 1);
        assert!(pos_fee_bps == fee_bps, 2);

        // Verify LP amount getter
        assert!(position_nft::get_spot_lp_amount(&position) == lp_amount, 3);

        position_nft::destroy_spot_position_for_testing(position);
    };

    test_utils::destroy(clock);
    ts::end(scenario);
}

#[test]
fun test_burn_spot_position() {
    let mut scenario = ts::begin(@0xA);
    let clock = create_clock(&mut scenario);

    ts::next_tx(&mut scenario, @0xA);
    {
        let pool_id = object::id_from_address(@0xBEEF);
        let lp_amount = 1000u64;
        let fee_bps = 30u64;

        let position = position_nft::mint_spot_position<TEST_ASSET, TEST_STABLE>(
            pool_id,
            lp_amount,
            fee_bps,
            &clock,
            ts::ctx(&mut scenario)
        );

        // Burn the position
        position_nft::burn_spot_position(position, &clock, ts::ctx(&mut scenario));
        // If no abort, test passes
    };

    test_utils::destroy(clock);
    ts::end(scenario);
}

#[test]
fun test_spot_position_info_getters() {
    let mut scenario = ts::begin(@0xA);
    let clock = create_clock(&mut scenario);

    ts::next_tx(&mut scenario, @0xA);
    {
        let pool_id = object::id_from_address(@0xCAFE);
        let lp_amount = 5000u64;
        let fee_bps = 50u64;

        let position = position_nft::mint_spot_position<TEST_ASSET, TEST_STABLE>(
            pool_id,
            lp_amount,
            fee_bps,
            &clock,
            ts::ctx(&mut scenario)
        );

        // Test get_spot_position_info
        let (pos_pool_id, pos_lp_amount, pos_asset_type, pos_stable_type, pos_fee_bps) =
            position_nft::get_spot_position_info(&position);

        assert!(pos_pool_id == pool_id, 0);
        assert!(pos_lp_amount == lp_amount, 1);
        assert!(pos_fee_bps == fee_bps, 2);
        // Type names are opaque, just verify they're returned without error

        // Test get_spot_lp_amount
        let lp_amt = position_nft::get_spot_lp_amount(&position);
        assert!(lp_amt == lp_amount, 3);

        position_nft::destroy_spot_position_for_testing(position);
    };

    test_utils::destroy(clock);
    ts::end(scenario);
}

// ===============================================
// Spot Position Increase/Decrease Tests
// ===============================================

#[test]
fun test_increase_spot_position() {
    let mut scenario = ts::begin(@0xA);
    let mut clock = create_clock(&mut scenario);

    ts::next_tx(&mut scenario, @0xA);
    {
        let pool_id = object::id_from_address(@0xBEEF);
        let initial_lp = 1000u64;
        let additional_lp = 500u64;
        let fee_bps = 30u64;

        let mut position = position_nft::mint_spot_position<TEST_ASSET, TEST_STABLE>(
            pool_id,
            initial_lp,
            fee_bps,
            &clock,
            ts::ctx(&mut scenario)
        );

        // Increase position
        position_nft::increase_spot_position(
            &mut position,
            pool_id,
            additional_lp,
            &clock
        );

        // Verify LP amount increased
        assert!(position_nft::get_spot_lp_amount(&position) == initial_lp + additional_lp, 0);

        position_nft::destroy_spot_position_for_testing(position);
    };

    test_utils::destroy(clock);
    ts::end(scenario);
}

#[test]
fun test_decrease_spot_position_partial() {
    let mut scenario = ts::begin(@0xA);
    let mut clock = create_clock(&mut scenario);

    ts::next_tx(&mut scenario, @0xA);
    {
        let pool_id = object::id_from_address(@0xBEEF);
        let initial_lp = 1000u64;
        let remove_lp = 300u64;
        let fee_bps = 30u64;

        let mut position = position_nft::mint_spot_position<TEST_ASSET, TEST_STABLE>(
            pool_id,
            initial_lp,
            fee_bps,
            &clock,
            ts::ctx(&mut scenario)
        );

        // Decrease position
        let remaining = position_nft::decrease_spot_position(
            &mut position,
            pool_id,
            remove_lp,
            &clock
        );

        // Verify remaining amount
        assert!(remaining == initial_lp - remove_lp, 0);
        assert!(position_nft::get_spot_lp_amount(&position) == remaining, 1);

        position_nft::destroy_spot_position_for_testing(position);
    };

    test_utils::destroy(clock);
    ts::end(scenario);
}

#[test]
fun test_decrease_spot_position_complete() {
    let mut scenario = ts::begin(@0xA);
    let mut clock = create_clock(&mut scenario);

    ts::next_tx(&mut scenario, @0xA);
    {
        let pool_id = object::id_from_address(@0xBEEF);
        let initial_lp = 1000u64;
        let fee_bps = 30u64;

        let mut position = position_nft::mint_spot_position<TEST_ASSET, TEST_STABLE>(
            pool_id,
            initial_lp,
            fee_bps,
            &clock,
            ts::ctx(&mut scenario)
        );

        // Remove all LP
        let remaining = position_nft::decrease_spot_position(
            &mut position,
            pool_id,
            initial_lp,
            &clock
        );

        // Verify zero remaining
        assert!(remaining == 0, 0);
        assert!(position_nft::get_spot_lp_amount(&position) == 0, 1);

        position_nft::destroy_spot_position_for_testing(position);
    };

    test_utils::destroy(clock);
    ts::end(scenario);
}

#[test]
fun test_multiple_increases() {
    let mut scenario = ts::begin(@0xA);
    let mut clock = create_clock(&mut scenario);

    ts::next_tx(&mut scenario, @0xA);
    {
        let pool_id = object::id_from_address(@0xBEEF);
        let fee_bps = 30u64;

        let mut position = position_nft::mint_spot_position<TEST_ASSET, TEST_STABLE>(
            pool_id,
            100u64,
            fee_bps,
            &clock,
            ts::ctx(&mut scenario)
        );

        // Multiple increases
        position_nft::increase_spot_position(&mut position, pool_id, 200u64, &clock);
        position_nft::increase_spot_position(&mut position, pool_id, 300u64, &clock);
        position_nft::increase_spot_position(&mut position, pool_id, 400u64, &clock);

        // Verify total
        assert!(position_nft::get_spot_lp_amount(&position) == 1000u64, 0);

        position_nft::destroy_spot_position_for_testing(position);
    };

    test_utils::destroy(clock);
    ts::end(scenario);
}

// ===============================================
// Spot Position Metadata Tests
// ===============================================

#[test]
fun test_set_and_get_spot_metadata() {
    let mut scenario = ts::begin(@0xA);
    let clock = create_clock(&mut scenario);

    ts::next_tx(&mut scenario, @0xA);
    {
        let pool_id = object::id_from_address(@0xBEEF);
        let mut position = position_nft::mint_spot_position<TEST_ASSET, TEST_STABLE>(
            pool_id,
            1000u64,
            30u64,
            &clock,
            ts::ctx(&mut scenario)
        );

        // Set metadata
        let key = string::utf8(b"tier");
        let value = string::utf8(b"gold");
        position_nft::set_spot_metadata(&mut position, key, value);

        // Get metadata
        let retrieved = position_nft::get_spot_metadata(&position, &key);
        assert!(option::is_some(&retrieved), 0);
        assert!(*option::borrow(&retrieved) == string::utf8(b"gold"), 1);

        position_nft::destroy_spot_position_for_testing(position);
    };

    test_utils::destroy(clock);
    ts::end(scenario);
}

#[test]
fun test_update_spot_metadata() {
    let mut scenario = ts::begin(@0xA);
    let clock = create_clock(&mut scenario);

    ts::next_tx(&mut scenario, @0xA);
    {
        let pool_id = object::id_from_address(@0xBEEF);
        let mut position = position_nft::mint_spot_position<TEST_ASSET, TEST_STABLE>(
            pool_id,
            1000u64,
            30u64,
            &clock,
            ts::ctx(&mut scenario)
        );

        let key = string::utf8(b"status");

        // Set initial value
        position_nft::set_spot_metadata(&mut position, key, string::utf8(b"active"));

        // Update value
        position_nft::set_spot_metadata(&mut position, key, string::utf8(b"inactive"));

        // Verify updated value
        let retrieved = position_nft::get_spot_metadata(&position, &key);
        assert!(option::is_some(&retrieved), 0);
        assert!(*option::borrow(&retrieved) == string::utf8(b"inactive"), 1);

        position_nft::destroy_spot_position_for_testing(position);
    };

    test_utils::destroy(clock);
    ts::end(scenario);
}

#[test]
fun test_get_nonexistent_spot_metadata() {
    let mut scenario = ts::begin(@0xA);
    let clock = create_clock(&mut scenario);

    ts::next_tx(&mut scenario, @0xA);
    {
        let pool_id = object::id_from_address(@0xBEEF);
        let position = position_nft::mint_spot_position<TEST_ASSET, TEST_STABLE>(
            pool_id,
            1000u64,
            30u64,
            &clock,
            ts::ctx(&mut scenario)
        );

        // Try to get nonexistent key
        let key = string::utf8(b"nonexistent");
        let retrieved = position_nft::get_spot_metadata(&position, &key);
        assert!(option::is_none(&retrieved), 0);

        position_nft::destroy_spot_position_for_testing(position);
    };

    test_utils::destroy(clock);
    ts::end(scenario);
}

#[test]
fun test_multiple_spot_metadata_keys() {
    let mut scenario = ts::begin(@0xA);
    let clock = create_clock(&mut scenario);

    ts::next_tx(&mut scenario, @0xA);
    {
        let pool_id = object::id_from_address(@0xBEEF);
        let mut position = position_nft::mint_spot_position<TEST_ASSET, TEST_STABLE>(
            pool_id,
            1000u64,
            30u64,
            &clock,
            ts::ctx(&mut scenario)
        );

        // Set multiple metadata keys
        position_nft::set_spot_metadata(&mut position, string::utf8(b"tier"), string::utf8(b"platinum"));
        position_nft::set_spot_metadata(&mut position, string::utf8(b"bonus"), string::utf8(b"10"));
        position_nft::set_spot_metadata(&mut position, string::utf8(b"locked"), string::utf8(b"false"));

        // Verify all keys
        let tier = position_nft::get_spot_metadata(&position, &string::utf8(b"tier"));
        let bonus = position_nft::get_spot_metadata(&position, &string::utf8(b"bonus"));
        let locked = position_nft::get_spot_metadata(&position, &string::utf8(b"locked"));

        assert!(option::is_some(&tier), 0);
        assert!(option::is_some(&bonus), 1);
        assert!(option::is_some(&locked), 2);
        assert!(*option::borrow(&tier) == string::utf8(b"platinum"), 3);
        assert!(*option::borrow(&bonus) == string::utf8(b"10"), 4);
        assert!(*option::borrow(&locked) == string::utf8(b"false"), 5);

        position_nft::destroy_spot_position_for_testing(position);
    };

    test_utils::destroy(clock);
    ts::end(scenario);
}

// ===============================================
// Conditional Position Basic Tests
// ===============================================

#[test]
fun test_mint_conditional_position_basic() {
    let mut scenario = ts::begin(@0xA);
    let clock = create_clock(&mut scenario);

    ts::next_tx(&mut scenario, @0xA);
    {
        let pool_id = object::id_from_address(@0xBEEF);
        let market_id = object::id_from_address(@0xCAFE);
        let proposal_id = object::id_from_address(@0xDEAD);
        let outcome_index = 1u8;
        let lp_amount = 2000u64;
        let fee_bps = 50u64;

        let position = position_nft::mint_conditional_position<TEST_ASSET, TEST_STABLE>(
            pool_id,
            market_id,
            proposal_id,
            outcome_index,
            lp_amount,
            fee_bps,
            &clock,
            ts::ctx(&mut scenario)
        );

        // Verify position data
        let (pos_pool_id, pos_market_id, pos_outcome_idx, pos_lp_amount, _asset_type, _stable_type, pos_fee_bps, is_winner) =
            position_nft::get_conditional_position_info(&position);

        assert!(pos_pool_id == pool_id, 0);
        assert!(pos_market_id == market_id, 1);
        assert!(pos_outcome_idx == outcome_index, 2);
        assert!(pos_lp_amount == lp_amount, 3);
        assert!(pos_fee_bps == fee_bps, 4);
        assert!(is_winner == false, 5); // Initially false

        // Verify LP amount getter
        assert!(position_nft::get_conditional_lp_amount(&position) == lp_amount, 6);

        position_nft::destroy_conditional_position_for_testing(position);
    };

    test_utils::destroy(clock);
    ts::end(scenario);
}

#[test]
fun test_burn_conditional_position() {
    let mut scenario = ts::begin(@0xA);
    let clock = create_clock(&mut scenario);

    ts::next_tx(&mut scenario, @0xA);
    {
        let pool_id = object::id_from_address(@0xBEEF);
        let market_id = object::id_from_address(@0xCAFE);
        let proposal_id = object::id_from_address(@0xDEAD);

        let position = position_nft::mint_conditional_position<TEST_ASSET, TEST_STABLE>(
            pool_id,
            market_id,
            proposal_id,
            0u8,
            1500u64,
            30u64,
            &clock,
            ts::ctx(&mut scenario)
        );

        // Burn the position
        position_nft::burn_conditional_position(position, &clock, ts::ctx(&mut scenario));
        // If no abort, test passes
    };

    test_utils::destroy(clock);
    ts::end(scenario);
}

#[test]
fun test_mark_outcome_result() {
    let mut scenario = ts::begin(@0xA);
    let clock = create_clock(&mut scenario);

    ts::next_tx(&mut scenario, @0xA);
    {
        let pool_id = object::id_from_address(@0xBEEF);
        let market_id = object::id_from_address(@0xCAFE);
        let proposal_id = object::id_from_address(@0xDEAD);

        let mut position = position_nft::mint_conditional_position<TEST_ASSET, TEST_STABLE>(
            pool_id,
            market_id,
            proposal_id,
            1u8,
            1000u64,
            30u64,
            &clock,
            ts::ctx(&mut scenario)
        );

        // Mark as winning outcome
        position_nft::mark_outcome_result(&mut position, true);

        // Verify is_winning_outcome field
        let (_, _, _, _, _, _, _, is_winner) = position_nft::get_conditional_position_info(&position);
        assert!(is_winner == true, 0);

        // Mark as losing outcome
        position_nft::mark_outcome_result(&mut position, false);
        let (_, _, _, _, _, _, _, is_winner2) = position_nft::get_conditional_position_info(&position);
        assert!(is_winner2 == false, 1);

        position_nft::destroy_conditional_position_for_testing(position);
    };

    test_utils::destroy(clock);
    ts::end(scenario);
}

#[test]
fun test_conditional_position_different_outcomes() {
    let mut scenario = ts::begin(@0xA);
    let clock = create_clock(&mut scenario);

    ts::next_tx(&mut scenario, @0xA);
    {
        let pool_id = object::id_from_address(@0xBEEF);
        let market_id = object::id_from_address(@0xCAFE);
        let proposal_id = object::id_from_address(@0xDEAD);

        // Create positions for different outcomes
        let pos0 = position_nft::mint_conditional_position<TEST_ASSET, TEST_STABLE>(
            pool_id, market_id, proposal_id, 0u8, 1000u64, 30u64, &clock, ts::ctx(&mut scenario)
        );
        let pos1 = position_nft::mint_conditional_position<TEST_ASSET, TEST_STABLE>(
            pool_id, market_id, proposal_id, 1u8, 2000u64, 30u64, &clock, ts::ctx(&mut scenario)
        );
        let pos2 = position_nft::mint_conditional_position<TEST_ASSET, TEST_STABLE>(
            pool_id, market_id, proposal_id, 2u8, 3000u64, 30u64, &clock, ts::ctx(&mut scenario)
        );

        // Verify outcome indices
        let (_, _, idx0, _, _, _, _, _) = position_nft::get_conditional_position_info(&pos0);
        let (_, _, idx1, _, _, _, _, _) = position_nft::get_conditional_position_info(&pos1);
        let (_, _, idx2, _, _, _, _, _) = position_nft::get_conditional_position_info(&pos2);

        assert!(idx0 == 0, 0);
        assert!(idx1 == 1, 1);
        assert!(idx2 == 2, 2);

        position_nft::destroy_conditional_position_for_testing(pos0);
        position_nft::destroy_conditional_position_for_testing(pos1);
        position_nft::destroy_conditional_position_for_testing(pos2);
    };

    test_utils::destroy(clock);
    ts::end(scenario);
}

// ===============================================
// Conditional Position Increase/Decrease Tests
// ===============================================

#[test]
fun test_increase_conditional_position() {
    let mut scenario = ts::begin(@0xA);
    let mut clock = create_clock(&mut scenario);

    ts::next_tx(&mut scenario, @0xA);
    {
        let pool_id = object::id_from_address(@0xBEEF);
        let market_id = object::id_from_address(@0xCAFE);
        let proposal_id = object::id_from_address(@0xDEAD);
        let initial_lp = 1500u64;
        let additional_lp = 750u64;

        let mut position = position_nft::mint_conditional_position<TEST_ASSET, TEST_STABLE>(
            pool_id, market_id, proposal_id, 1u8, initial_lp, 30u64, &clock, ts::ctx(&mut scenario)
        );

        // Increase position
        position_nft::increase_conditional_position(&mut position, pool_id, additional_lp, &clock);

        // Verify LP amount increased
        assert!(position_nft::get_conditional_lp_amount(&position) == initial_lp + additional_lp, 0);

        position_nft::destroy_conditional_position_for_testing(position);
    };

    test_utils::destroy(clock);
    ts::end(scenario);
}

#[test]
fun test_decrease_conditional_position_partial() {
    let mut scenario = ts::begin(@0xA);
    let mut clock = create_clock(&mut scenario);

    ts::next_tx(&mut scenario, @0xA);
    {
        let pool_id = object::id_from_address(@0xBEEF);
        let market_id = object::id_from_address(@0xCAFE);
        let proposal_id = object::id_from_address(@0xDEAD);
        let initial_lp = 2000u64;
        let remove_lp = 800u64;

        let mut position = position_nft::mint_conditional_position<TEST_ASSET, TEST_STABLE>(
            pool_id, market_id, proposal_id, 0u8, initial_lp, 30u64, &clock, ts::ctx(&mut scenario)
        );

        // Decrease position
        let remaining = position_nft::decrease_conditional_position(&mut position, pool_id, remove_lp, &clock);

        // Verify remaining amount
        assert!(remaining == initial_lp - remove_lp, 0);
        assert!(position_nft::get_conditional_lp_amount(&position) == remaining, 1);

        position_nft::destroy_conditional_position_for_testing(position);
    };

    test_utils::destroy(clock);
    ts::end(scenario);
}

#[test]
fun test_decrease_conditional_position_complete() {
    let mut scenario = ts::begin(@0xA);
    let mut clock = create_clock(&mut scenario);

    ts::next_tx(&mut scenario, @0xA);
    {
        let pool_id = object::id_from_address(@0xBEEF);
        let market_id = object::id_from_address(@0xCAFE);
        let proposal_id = object::id_from_address(@0xDEAD);
        let initial_lp = 1000u64;

        let mut position = position_nft::mint_conditional_position<TEST_ASSET, TEST_STABLE>(
            pool_id, market_id, proposal_id, 2u8, initial_lp, 30u64, &clock, ts::ctx(&mut scenario)
        );

        // Remove all LP
        let remaining = position_nft::decrease_conditional_position(&mut position, pool_id, initial_lp, &clock);

        // Verify zero remaining
        assert!(remaining == 0, 0);
        assert!(position_nft::get_conditional_lp_amount(&position) == 0, 1);

        position_nft::destroy_conditional_position_for_testing(position);
    };

    test_utils::destroy(clock);
    ts::end(scenario);
}

// ===============================================
// Conditional Position Metadata Tests
// ===============================================

#[test]
fun test_set_and_get_conditional_metadata() {
    let mut scenario = ts::begin(@0xA);
    let clock = create_clock(&mut scenario);

    ts::next_tx(&mut scenario, @0xA);
    {
        let pool_id = object::id_from_address(@0xBEEF);
        let market_id = object::id_from_address(@0xCAFE);
        let proposal_id = object::id_from_address(@0xDEAD);

        let mut position = position_nft::mint_conditional_position<TEST_ASSET, TEST_STABLE>(
            pool_id, market_id, proposal_id, 1u8, 1000u64, 30u64, &clock, ts::ctx(&mut scenario)
        );

        // Set metadata
        let key = string::utf8(b"strategy");
        let value = string::utf8(b"long");
        position_nft::set_conditional_metadata(&mut position, key, value);

        // Get metadata
        let retrieved = position_nft::get_conditional_metadata(&position, &key);
        assert!(option::is_some(&retrieved), 0);
        assert!(*option::borrow(&retrieved) == string::utf8(b"long"), 1);

        position_nft::destroy_conditional_position_for_testing(position);
    };

    test_utils::destroy(clock);
    ts::end(scenario);
}

#[test]
fun test_update_conditional_metadata() {
    let mut scenario = ts::begin(@0xA);
    let clock = create_clock(&mut scenario);

    ts::next_tx(&mut scenario, @0xA);
    {
        let pool_id = object::id_from_address(@0xBEEF);
        let market_id = object::id_from_address(@0xCAFE);
        let proposal_id = object::id_from_address(@0xDEAD);

        let mut position = position_nft::mint_conditional_position<TEST_ASSET, TEST_STABLE>(
            pool_id, market_id, proposal_id, 0u8, 1000u64, 30u64, &clock, ts::ctx(&mut scenario)
        );

        let key = string::utf8(b"risk");

        // Set initial value
        position_nft::set_conditional_metadata(&mut position, key, string::utf8(b"low"));

        // Update value
        position_nft::set_conditional_metadata(&mut position, key, string::utf8(b"high"));

        // Verify updated value
        let retrieved = position_nft::get_conditional_metadata(&position, &key);
        assert!(option::is_some(&retrieved), 0);
        assert!(*option::borrow(&retrieved) == string::utf8(b"high"), 1);

        position_nft::destroy_conditional_position_for_testing(position);
    };

    test_utils::destroy(clock);
    ts::end(scenario);
}

// ===============================================
// Error Case Tests
// ===============================================

#[test]
#[expected_failure(abort_code = 0)] // EZeroAmount
fun test_mint_spot_position_zero_amount() {
    let mut scenario = ts::begin(@0xA);
    let clock = create_clock(&mut scenario);

    ts::next_tx(&mut scenario, @0xA);
    {
        let pool_id = object::id_from_address(@0xBEEF);
        let position = position_nft::mint_spot_position<TEST_ASSET, TEST_STABLE>(
            pool_id,
            0u64, // Zero amount should fail
            30u64,
            &clock,
            ts::ctx(&mut scenario)
        );
        position_nft::destroy_spot_position_for_testing(position);
    };

    test_utils::destroy(clock);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = 0)] // EZeroAmount
fun test_mint_conditional_position_zero_amount() {
    let mut scenario = ts::begin(@0xA);
    let clock = create_clock(&mut scenario);

    ts::next_tx(&mut scenario, @0xA);
    {
        let pool_id = object::id_from_address(@0xBEEF);
        let market_id = object::id_from_address(@0xCAFE);
        let proposal_id = object::id_from_address(@0xDEAD);

        let position = position_nft::mint_conditional_position<TEST_ASSET, TEST_STABLE>(
            pool_id,
            market_id,
            proposal_id,
            1u8,
            0u64, // Zero amount should fail
            30u64,
            &clock,
            ts::ctx(&mut scenario)
        );
        position_nft::destroy_conditional_position_for_testing(position);
    };

    test_utils::destroy(clock);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = 1)] // EPositionMismatch
fun test_increase_spot_position_wrong_pool() {
    let mut scenario = ts::begin(@0xA);
    let mut clock = create_clock(&mut scenario);

    ts::next_tx(&mut scenario, @0xA);
    {
        let pool_id = object::id_from_address(@0xBEEF);
        let wrong_pool_id = object::id_from_address(@0xDEAD);

        let mut position = position_nft::mint_spot_position<TEST_ASSET, TEST_STABLE>(
            pool_id,
            1000u64,
            30u64,
            &clock,
            ts::ctx(&mut scenario)
        );

        // Try to increase with wrong pool ID
        position_nft::increase_spot_position(&mut position, wrong_pool_id, 500u64, &clock);

        position_nft::destroy_spot_position_for_testing(position);
    };

    test_utils::destroy(clock);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = 2)] // EInsufficientLiquidity
fun test_decrease_spot_position_insufficient() {
    let mut scenario = ts::begin(@0xA);
    let mut clock = create_clock(&mut scenario);

    ts::next_tx(&mut scenario, @0xA);
    {
        let pool_id = object::id_from_address(@0xBEEF);

        let mut position = position_nft::mint_spot_position<TEST_ASSET, TEST_STABLE>(
            pool_id,
            1000u64,
            30u64,
            &clock,
            ts::ctx(&mut scenario)
        );

        // Try to remove more than available
        position_nft::decrease_spot_position(&mut position, pool_id, 2000u64, &clock);

        position_nft::destroy_spot_position_for_testing(position);
    };

    test_utils::destroy(clock);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = 0)] // EZeroAmount
fun test_increase_spot_position_zero() {
    let mut scenario = ts::begin(@0xA);
    let mut clock = create_clock(&mut scenario);

    ts::next_tx(&mut scenario, @0xA);
    {
        let pool_id = object::id_from_address(@0xBEEF);

        let mut position = position_nft::mint_spot_position<TEST_ASSET, TEST_STABLE>(
            pool_id,
            1000u64,
            30u64,
            &clock,
            ts::ctx(&mut scenario)
        );

        // Try to increase by zero
        position_nft::increase_spot_position(&mut position, pool_id, 0u64, &clock);

        position_nft::destroy_spot_position_for_testing(position);
    };

    test_utils::destroy(clock);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = 0)] // EZeroAmount
fun test_decrease_spot_position_zero() {
    let mut scenario = ts::begin(@0xA);
    let mut clock = create_clock(&mut scenario);

    ts::next_tx(&mut scenario, @0xA);
    {
        let pool_id = object::id_from_address(@0xBEEF);

        let mut position = position_nft::mint_spot_position<TEST_ASSET, TEST_STABLE>(
            pool_id,
            1000u64,
            30u64,
            &clock,
            ts::ctx(&mut scenario)
        );

        // Try to decrease by zero
        position_nft::decrease_spot_position(&mut position, pool_id, 0u64, &clock);

        position_nft::destroy_spot_position_for_testing(position);
    };

    test_utils::destroy(clock);
    ts::end(scenario);
}

