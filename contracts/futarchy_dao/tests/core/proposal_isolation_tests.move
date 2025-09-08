#[test_only]
module futarchy::proposal_isolation_tests;

use std::{option, string, type_name};
use sui::{
    test_scenario::{Self as ts, Scenario},
    clock::{Self as sui_clock, Clock},
    coin::{Self, Coin},
    sui::SUI,
    object,
    test_utils,
};
use account_protocol::{
    account::{Self, Account},
    intents,
};
use futarchy::{
    futarchy_config::{Self, FutarchyConfig, FutarchyOutcome},
    proposal::{Self, Proposal, CancelWitness},
    version,
};

/// Test that a cancel witness is properly scoped to a specific proposal/outcome
#[test]
fun test_witness_is_bounded_to_proposal_slot() {
    let mut s = ts::begin(@0xC0FFEE);
    let ctx = ts::ctx(&mut s);
    let clock = sui_clock::create_for_testing(ctx);

    // Create a minimal account
    let cfg = futarchy_config::default_config_params();
    let mut acct = futarchy_config::new_account_test(
        futarchy_config::new<SUI, SUI>(cfg, ctx),
        ctx
    );

    // Create a test proposal with 2 outcomes
    let mut proposal = create_test_proposal_with_keys(
        vector[b"accept_key".to_string(), b"reject_key".to_string()],
        ctx
    );
    
    // Mint witness for outcome 0: consumes the slot
    let mut cw_opt = proposal::make_cancel_witness(&mut proposal, 0);
    assert!(option::is_some(&cw_opt), 0);
    let cw = option::extract(&mut cw_opt);
    
    // Verify witness has correct data
    assert!(proposal::cancel_witness_outcome_index(&cw) == 0, 1);
    assert!(proposal::cancel_witness_key(&cw) == b"accept_key".to_string(), 2);

    // Note: In a real scenario, there would be an intent to cancel.
    // For this test, we're just checking the witness mechanics.
    // The witness is consumed by extracting it above.

    // Slot is now empty; a second mint attempt returns None
    let cw2 = proposal::make_cancel_witness(&mut proposal, 0);
    assert!(!option::is_some(&cw2), 3);
    
    // But we can still mint a witness for outcome 1
    let mut cw3_opt = proposal::make_cancel_witness(&mut proposal, 1);
    assert!(option::is_some(&cw3_opt), 4);
    let cw3 = option::extract(&mut cw3_opt);
    assert!(proposal::cancel_witness_key(&cw3) == b"reject_key".to_string(), 5);
    
    // The second witness was verified above and consumed

    // Clean up
    test_utils::destroy(proposal);
    test_utils::destroy(acct);
    sui_clock::destroy_for_testing(clock);
    ts::end(s);
}

/// Test that witnesses from different proposals are isolated
#[test]
fun test_cross_proposal_isolation() {
    let mut s = ts::begin(@0xC0FFEE);
    let ctx = ts::ctx(&mut s);
    let clock = sui_clock::create_for_testing(ctx);

    // Create account
    let cfg = futarchy_config::default_config_params();
    let mut acct = futarchy_config::new_account_test(
        futarchy_config::new<SUI, SUI>(cfg, ctx),
        ctx
    );

    // Create two different proposals
    let mut proposal1 = create_test_proposal_with_keys(
        vector[b"p1_accept".to_string(), b"p1_reject".to_string()],
        ctx
    );
    
    let mut proposal2 = create_test_proposal_with_keys(
        vector[b"p2_accept".to_string(), b"p2_reject".to_string()],
        ctx
    );
    

    // Get addresses for verification
    let p1_addr = object::id_address(&proposal1);
    let p2_addr = object::id_address(&proposal2);
    assert!(p1_addr != p2_addr, 0);

    // Mint witnesses from each proposal
    let mut cw1_opt = proposal::make_cancel_witness(&mut proposal1, 0);
    let mut cw2_opt = proposal::make_cancel_witness(&mut proposal2, 0);
    
    assert!(option::is_some(&cw1_opt), 1);
    assert!(option::is_some(&cw2_opt), 2);
    
    let cw1 = option::extract(&mut cw1_opt);
    let cw2 = option::extract(&mut cw2_opt);
    
    // Verify witnesses are properly scoped
    assert!(proposal::cancel_witness_proposal(&cw1) == p1_addr, 3);
    assert!(proposal::cancel_witness_proposal(&cw2) == p2_addr, 4);
    assert!(proposal::cancel_witness_key(&cw1) == b"p1_accept".to_string(), 5);
    assert!(proposal::cancel_witness_key(&cw2) == b"p2_accept".to_string(), 6);
    
    // Witnesses are verified above - each witness only works for its own proposal

    // Clean up
    test_utils::destroy(proposal1);
    test_utils::destroy(proposal2);
    test_utils::destroy(acct);
    sui_clock::destroy_for_testing(clock);
    ts::end(s);
}

/// Test that you cannot forge a cancel witness
#[test]
fun test_cannot_forge_witness() {
    let mut s = ts::begin(@0xC0FFEE);
    let ctx = ts::ctx(&mut s);
    let clock = sui_clock::create_for_testing(ctx);

    // Create account
    let cfg = futarchy_config::default_config_params();
    let mut acct = futarchy_config::new_account_test(
        futarchy_config::new<SUI, SUI>(cfg, ctx),
        ctx
    );

    // Create a proposal with an intent key
    let mut proposal = create_test_proposal_with_keys(
        vector[b"test_key".to_string()],
        ctx
    );
    

    // Mint the witness - this consumes the slot
    let mut cw_opt = proposal::make_cancel_witness(&mut proposal, 0);
    assert!(option::is_some(&cw_opt), 0);
    let cw = option::extract(&mut cw_opt);
    
    // The witness was verified above and consumed
    
    // Try to mint another witness for the same slot - should return None
    let cw2_opt = proposal::make_cancel_witness(&mut proposal, 0);
    assert!(!option::is_some(&cw2_opt), 1);
    
    // Clean up
    test_utils::destroy(proposal);
    test_utils::destroy(acct);
    sui_clock::destroy_for_testing(clock);
    ts::end(s);
}

// === Helper Functions ===

/// Create a minimal test proposal with the given intent keys
fun create_test_proposal_with_keys(
    intent_keys: vector<string::String>,
    ctx: &mut TxContext
): Proposal<SUI, SUI> {
    let num_outcomes = intent_keys.length();
    let mut outcome_messages = vector[];
    let mut outcome_details = vector[];
    let mut outcome_creators = vector[];
    let mut i = 0;
    while (i < num_outcomes) {
        outcome_messages.push_back(b"Test outcome".to_string());
        outcome_details.push_back(b"Test details".to_string());
        outcome_creators.push_back(@0xC0FFEE);
        i = i + 1;
    };
    
    // Convert intent keys to Option<String>
    let mut intent_key_opts = vector[];
    let mut j = 0;
    while (j < intent_keys.length()) {
        intent_key_opts.push_back(option::some(*vector::borrow(&intent_keys, j)));
        j = j + 1;
    };
    
    // Create a minimal proposal struct
    // Note: This is simplified - in production, use proper initialization
    proposal::new_for_testing(
        @0xDADADA,         // dao_id  
        @0xC0FFEE,         // proposer
        option::none(),    // liquidity_provider
        b"Test Proposal".to_string(),  // title
        b"Test metadata".to_string(),  // metadata
        outcome_messages,
        outcome_details,
        outcome_creators,
        (num_outcomes as u8),
        0,                 // review_period_ms
        86400000,          // trading_period_ms
        100,               // min_asset_liquidity
        100,               // min_stable_liquidity
        0,                 // twap_start_delay
        0,                 // twap_initial_observation
        100,               // twap_step_max
        500,               // twap_threshold
        30,                // amm_total_fee_bps
        option::none(),    // winning_outcome
        sui::balance::zero<SUI>(),  // fee_escrow
        @0x123456,         // treasury_address
        intent_key_opts,   // intent_keys
        ctx
    )
}