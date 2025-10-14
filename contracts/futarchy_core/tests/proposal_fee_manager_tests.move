#[test_only]
module futarchy_core::proposal_fee_manager_tests;

// === Imports ===

use sui::{
    test_utils::destroy,
    test_scenario::{Self as ts, Scenario},
    clock::{Self, Clock},
    coin::{Self, Coin},
    sui::SUI,
};
use futarchy_core::{
    proposal_fee_manager::{Self, ProposalFeeManager},
    futarchy_config::{Self, SlashDistribution},
    proposal_quota_registry::{Self, ProposalQuotaRegistry},
};

// === Constants ===

const OWNER: address = @0xCAFE;
const PROPOSER: address = @0xBEEF;
const SLASHER: address = @0xDEAD;

// === Helpers ===

fun start(): (Scenario, ProposalFeeManager, Clock) {
    let mut scenario = ts::begin(OWNER);
    let manager = proposal_fee_manager::new(scenario.ctx());
    let clock = clock::create_for_testing(scenario.ctx());
    (scenario, manager, clock)
}

fun end(scenario: Scenario, manager: ProposalFeeManager, clock: Clock) {
    destroy(manager);
    destroy(clock);
    ts::end(scenario);
}

fun create_test_coin(amount: u64, ctx: &mut TxContext): Coin<SUI> {
    coin::mint_for_testing<SUI>(amount, ctx)
}

// === Tests ===

#[test]
fun test_new_manager() {
    let (scenario, manager, clock) = start();

    // Verify initial state
    assert!(proposal_fee_manager::protocol_revenue(&manager) == 0, 0);

    end(scenario, manager, clock);
}

#[test]
fun test_deposit_proposal_fee() {
    let (mut scenario, mut manager, clock) = start();

    let proposal_id = object::id_from_address(@0x1);
    let fee_coin = create_test_coin(1000, scenario.ctx());

    // Deposit fee
    proposal_fee_manager::deposit_proposal_fee(&mut manager, proposal_id, fee_coin);

    // Verify fee was stored
    assert!(proposal_fee_manager::has_proposal_fee(&manager, proposal_id), 0);
    assert!(proposal_fee_manager::get_proposal_fee(&manager, proposal_id) == 1000, 1);

    end(scenario, manager, clock);
}

#[test]
#[expected_failure(abort_code = proposal_fee_manager::EInvalidFeeAmount)]
fun test_deposit_proposal_fee_zero_fails() {
    let (mut scenario, mut manager, clock) = start();

    let proposal_id = object::id_from_address(@0x1);
    let fee_coin = coin::zero<SUI>(scenario.ctx());

    // Should abort with EInvalidFeeAmount
    proposal_fee_manager::deposit_proposal_fee(&mut manager, proposal_id, fee_coin);

    end(scenario, manager, clock);
}

#[test]
fun test_deposit_queue_fee() {
    let (mut scenario, mut manager, clock) = start();

    let fee_coin = create_test_coin(1000, scenario.ctx());

    // Deposit queue fee (splits 80/20)
    proposal_fee_manager::deposit_queue_fee(&mut manager, fee_coin, &clock, scenario.ctx());

    // Protocol should get 20% = 200
    assert!(proposal_fee_manager::protocol_revenue(&manager) == 200, 0);

    end(scenario, manager, clock);
}

#[test]
fun test_deposit_queue_fee_zero() {
    let (mut scenario, mut manager, clock) = start();

    let fee_coin = coin::zero<SUI>(scenario.ctx());

    // Should handle zero gracefully
    proposal_fee_manager::deposit_queue_fee(&mut manager, fee_coin, &clock, scenario.ctx());

    assert!(proposal_fee_manager::protocol_revenue(&manager) == 0, 0);

    end(scenario, manager, clock);
}

#[test]
fun test_add_to_proposal_fee() {
    let (mut scenario, mut manager, clock) = start();

    let proposal_id = object::id_from_address(@0x1);
    let initial_fee = create_test_coin(1000, scenario.ctx());
    proposal_fee_manager::deposit_proposal_fee(&mut manager, proposal_id, initial_fee);

    // Add more to the fee
    let additional_fee = create_test_coin(500, scenario.ctx());
    proposal_fee_manager::add_to_proposal_fee(&mut manager, proposal_id, additional_fee, &clock);

    // Total should be 1500
    assert!(proposal_fee_manager::get_proposal_fee(&manager, proposal_id) == 1500, 0);

    end(scenario, manager, clock);
}

#[test]
#[expected_failure(abort_code = proposal_fee_manager::EProposalFeeNotFound)]
fun test_add_to_nonexistent_proposal_fee_fails() {
    let (mut scenario, mut manager, clock) = start();

    let proposal_id = object::id_from_address(@0x1);
    let additional_fee = create_test_coin(500, scenario.ctx());

    // Should abort - proposal doesn't exist
    proposal_fee_manager::add_to_proposal_fee(&mut manager, proposal_id, additional_fee, &clock);

    end(scenario, manager, clock);
}

#[test]
fun test_take_activator_reward_full_fee() {
    let (mut scenario, mut manager, clock) = start();

    let proposal_id = object::id_from_address(@0x1);
    // Fee is 2M (2x the fixed reward of 1M)
    let fee_coin = create_test_coin(2_000_000, scenario.ctx());
    proposal_fee_manager::deposit_proposal_fee(&mut manager, proposal_id, fee_coin);

    // Take activator reward
    let reward = proposal_fee_manager::take_activator_reward(&mut manager, proposal_id, scenario.ctx());

    // Should get fixed reward of 1M
    assert!(reward.value() == 1_000_000, 0);
    // Protocol should get the rest (1M)
    assert!(proposal_fee_manager::protocol_revenue(&manager) == 1_000_000, 1);

    destroy(reward);
    end(scenario, manager, clock);
}

#[test]
fun test_take_activator_reward_small_fee() {
    let (mut scenario, mut manager, clock) = start();

    let proposal_id = object::id_from_address(@0x1);
    // Fee is 500K (less than fixed reward)
    let fee_coin = create_test_coin(500_000, scenario.ctx());
    proposal_fee_manager::deposit_proposal_fee(&mut manager, proposal_id, fee_coin);

    // Take activator reward
    let reward = proposal_fee_manager::take_activator_reward(&mut manager, proposal_id, scenario.ctx());

    // Should get entire fee (500K)
    assert!(reward.value() == 500_000, 0);
    // Protocol gets nothing
    assert!(proposal_fee_manager::protocol_revenue(&manager) == 0, 1);

    destroy(reward);
    end(scenario, manager, clock);
}

#[test]
fun test_slash_proposal_fee_with_distribution() {
    let (mut scenario, mut manager, clock) = start();

    let proposal_id = object::id_from_address(@0x1);
    let fee_coin = create_test_coin(10000, scenario.ctx());
    proposal_fee_manager::deposit_proposal_fee(&mut manager, proposal_id, fee_coin);

    // Create slash distribution: 25% slasher, 25% dao, 25% protocol, 25% burn
    let slash_config = futarchy_config::new_slash_distribution(2500, 2500, 2500, 2500);

    // Slash the fee
    let (slasher_reward, dao_coin) = proposal_fee_manager::slash_proposal_fee_with_distribution(
        &mut manager,
        proposal_id,
        &slash_config,
        scenario.ctx()
    );

    // Verify distributions
    assert!(slasher_reward.value() == 2500, 0); // 25%
    assert!(dao_coin.value() == 2500, 1); // 25%
    // Protocol gets 25% + 25% burn = 5000
    assert!(proposal_fee_manager::protocol_revenue(&manager) == 5000, 2);

    destroy(slasher_reward);
    destroy(dao_coin);
    end(scenario, manager, clock);
}

#[test]
fun test_slash_proposal_fee_minimal_amount() {
    let (mut scenario, mut manager, clock) = start();

    let proposal_id = object::id_from_address(@0x1);
    // Use minimal fee of 1 to test rounding behavior
    let fee_coin = create_test_coin(1, scenario.ctx());
    proposal_fee_manager::deposit_proposal_fee(&mut manager, proposal_id, fee_coin);

    let slash_config = futarchy_config::new_slash_distribution(2500, 2500, 2500, 2500);

    // Slash minimal fee
    let (slasher_reward, dao_coin) = proposal_fee_manager::slash_proposal_fee_with_distribution(
        &mut manager,
        proposal_id,
        &slash_config,
        scenario.ctx()
    );

    // All should round to zero except protocol (gets the dust)
    assert!(slasher_reward.value() == 0, 0);
    assert!(dao_coin.value() == 0, 1);
    // Protocol gets all the dust from rounding
    assert!(proposal_fee_manager::protocol_revenue(&manager) == 1, 2);

    destroy(slasher_reward);
    destroy(dao_coin);
    end(scenario, manager, clock);
}

#[test]
fun test_refund_proposal_fee() {
    let (mut scenario, mut manager, clock) = start();

    let proposal_id = object::id_from_address(@0x1);
    let fee_coin = create_test_coin(1000, scenario.ctx());
    proposal_fee_manager::deposit_proposal_fee(&mut manager, proposal_id, fee_coin);

    // Refund the fee
    let refund = proposal_fee_manager::refund_proposal_fee(&mut manager, proposal_id, scenario.ctx());

    assert!(refund.value() == 1000, 0);
    assert!(!proposal_fee_manager::has_proposal_fee(&manager, proposal_id), 1);

    destroy(refund);
    end(scenario, manager, clock);
}

#[test]
#[expected_failure(abort_code = proposal_fee_manager::EProposalFeeNotFound)]
fun test_refund_nonexistent_proposal_fee_fails() {
    let (mut scenario, mut manager, clock) = start();

    let proposal_id = object::id_from_address(@0x1);

    // Should abort - proposal doesn't exist
    let refund = proposal_fee_manager::refund_proposal_fee(&mut manager, proposal_id, scenario.ctx());

    destroy(refund);
    end(scenario, manager, clock);
}

#[test]
fun test_withdraw_protocol_revenue() {
    let (mut scenario, mut manager, clock) = start();

    // Add some protocol revenue via queue fee
    let fee_coin = create_test_coin(1000, scenario.ctx());
    proposal_fee_manager::deposit_queue_fee(&mut manager, fee_coin, &clock, scenario.ctx());

    let initial_revenue = proposal_fee_manager::protocol_revenue(&manager);
    assert!(initial_revenue == 200, 0); // 20% of 1000

    // Withdraw half
    let withdrawal = proposal_fee_manager::withdraw_protocol_revenue(&mut manager, 100, scenario.ctx());

    assert!(withdrawal.value() == 100, 1);
    assert!(proposal_fee_manager::protocol_revenue(&manager) == 100, 2);

    destroy(withdrawal);
    end(scenario, manager, clock);
}

#[test]
fun test_pay_proposal_creator_reward() {
    let (mut scenario, mut manager, clock) = start();

    // Add protocol revenue
    let fee_coin = create_test_coin(5000, scenario.ctx());
    proposal_fee_manager::deposit_queue_fee(&mut manager, fee_coin, &clock, scenario.ctx());

    // Pay reward
    let reward = proposal_fee_manager::pay_proposal_creator_reward(&mut manager, 500, scenario.ctx());

    assert!(reward.value() == 500, 0);

    destroy(reward);
    end(scenario, manager, clock);
}

#[test]
fun test_pay_proposal_creator_reward_insufficient_funds() {
    let (mut scenario, mut manager, clock) = start();

    // Add only 100 to protocol revenue
    let fee_coin = create_test_coin(500, scenario.ctx());
    proposal_fee_manager::deposit_queue_fee(&mut manager, fee_coin, &clock, scenario.ctx());

    let available = proposal_fee_manager::protocol_revenue(&manager);

    // Try to pay 500 but only 100 available (20% of 500)
    let reward = proposal_fee_manager::pay_proposal_creator_reward(&mut manager, 500, scenario.ctx());

    // Should get whatever is available
    assert!(reward.value() == available, 0);
    assert!(proposal_fee_manager::protocol_revenue(&manager) == 0, 1);

    destroy(reward);
    end(scenario, manager, clock);
}

#[test]
fun test_pay_outcome_creator_reward() {
    let (mut scenario, mut manager, clock) = start();

    // Add protocol revenue
    let fee_coin = create_test_coin(5000, scenario.ctx());
    proposal_fee_manager::deposit_queue_fee(&mut manager, fee_coin, &clock, scenario.ctx());

    // Pay reward
    let reward = proposal_fee_manager::pay_outcome_creator_reward(&mut manager, 300, scenario.ctx());

    assert!(reward.value() == 300, 0);

    destroy(reward);
    end(scenario, manager, clock);
}

#[test]
fun test_collect_advancement_fee() {
    let (mut scenario, mut manager, clock) = start();

    let fee_coin = create_test_coin(1000, scenario.ctx());

    // Collect advancement fee
    proposal_fee_manager::collect_advancement_fee(&mut manager, fee_coin);

    assert!(proposal_fee_manager::protocol_revenue(&manager) == 1000, 0);

    end(scenario, manager, clock);
}

#[test]
fun test_deposit_revenue() {
    let (mut scenario, mut manager, clock) = start();

    let revenue_coin = create_test_coin(2000, scenario.ctx());

    // Deposit revenue
    proposal_fee_manager::deposit_revenue(&mut manager, revenue_coin);

    assert!(proposal_fee_manager::protocol_revenue(&manager) == 2000, 0);

    end(scenario, manager, clock);
}

// === Integration Tests with ProposalQuotaRegistry ===

#[test]
fun test_calculate_fee_with_quota_available() {
    let (mut scenario, manager, clock) = start();

    let dao_id = object::id_from_address(@0x1);
    let mut quota_registry = proposal_quota_registry::new(dao_id, scenario.ctx());

    // Set quota: 3 proposals per 30 days at reduced fee of 100
    let users = vector[@0xBEEF];
    proposal_quota_registry::set_quotas(
        &mut quota_registry,
        dao_id,
        users,
        3,                    // quota_amount
        2_592_000_000,        // 30 days in ms
        100,                  // reduced_fee
        &clock
    );

    // Calculate fee with quota
    let base_fee = 1000;
    let (actual_fee, used_quota) = proposal_fee_manager::calculate_fee_with_quota(
        &quota_registry,
        dao_id,
        @0xBEEF,
        base_fee,
        &clock
    );

    // Should use reduced fee
    assert!(used_quota == true, 0);
    assert!(actual_fee == 100, 1); // Reduced fee, not base fee

    destroy(quota_registry);
    end(scenario, manager, clock);
}

#[test]
fun test_calculate_fee_with_quota_unavailable() {
    let (mut scenario, manager, clock) = start();

    let dao_id = object::id_from_address(@0x1);
    let quota_registry = proposal_quota_registry::new(dao_id, scenario.ctx());

    // No quota set for this user

    // Calculate fee without quota
    let base_fee = 1000;
    let (actual_fee, used_quota) = proposal_fee_manager::calculate_fee_with_quota(
        &quota_registry,
        dao_id,
        @0xBEEF,
        base_fee,
        &clock
    );

    // Should use full base fee
    assert!(used_quota == false, 0);
    assert!(actual_fee == 1000, 1); // Base fee, not reduced

    destroy(quota_registry);
    end(scenario, manager, clock);
}

#[test]
fun test_use_quota_for_proposal() {
    let (mut scenario, manager, clock) = start();

    let dao_id = object::id_from_address(@0x1);
    let mut quota_registry = proposal_quota_registry::new(dao_id, scenario.ctx());

    // Set quota: 3 proposals per 30 days
    let users = vector[@0xBEEF];
    proposal_quota_registry::set_quotas(
        &mut quota_registry,
        dao_id,
        users,
        3,                    // quota_amount
        2_592_000_000,        // 30 days in ms
        100,                  // reduced_fee
        &clock
    );

    // Check initial quota status
    let (has_quota, remaining, _reduced_fee) = proposal_quota_registry::get_quota_status(
        &quota_registry,
        @0xBEEF,
        &clock
    );
    assert!(has_quota == true, 0);
    assert!(remaining == 3, 1);

    // Use one quota
    proposal_fee_manager::use_quota_for_proposal(&mut quota_registry, dao_id, @0xBEEF, &clock);

    // Check quota decreased
    let (has_quota2, remaining2, _) = proposal_quota_registry::get_quota_status(
        &quota_registry,
        @0xBEEF,
        &clock
    );
    assert!(has_quota2 == true, 2);
    assert!(remaining2 == 2, 3); // Down to 2

    // Use remaining quotas
    proposal_fee_manager::use_quota_for_proposal(&mut quota_registry, dao_id, @0xBEEF, &clock);
    proposal_fee_manager::use_quota_for_proposal(&mut quota_registry, dao_id, @0xBEEF, &clock);

    // Check quota exhausted
    let (has_quota3, remaining3, _) = proposal_quota_registry::get_quota_status(
        &quota_registry,
        @0xBEEF,
        &clock
    );
    assert!(has_quota3 == false, 4);
    assert!(remaining3 == 0, 5); // All used up

    destroy(quota_registry);
    end(scenario, manager, clock);
}
