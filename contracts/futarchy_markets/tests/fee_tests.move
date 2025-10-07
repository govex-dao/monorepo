#[test_only]
module futarchy_markets::fee_tests;

use futarchy_markets::fee::{Self, FeeManager, FeeAdminCap};
use sui::test_scenario::{Self as ts, Scenario};
use sui::clock::{Self, Clock};
use sui::coin::{Self, Coin};
use sui::sui::SUI;

// === Test Helpers ===

fun setup_test(sender: address): (Scenario, Clock) {
    let mut scenario = ts::begin(sender);
    let ctx = ts::ctx(&mut scenario);
    let clock = clock::create_for_testing(ctx);
    (scenario, clock)
}

fun mint_sui(scenario: &mut Scenario, amount: u64, recipient: address) {
    ts::next_tx(scenario, recipient);
    let ctx = ts::ctx(scenario);
    let sui_coin = coin::mint_for_testing<SUI>(amount, ctx);
    transfer::public_transfer(sui_coin, recipient);
}

// === Basic Initialization Test ===

#[test]
fun test_fee_manager_init() {
    let sender = @0xA;
    let (mut scenario, clock) = setup_test(sender);

    // Create fee manager
    ts::next_tx(&mut scenario, sender);
    {
        let ctx = ts::ctx(&mut scenario);
        fee::create_fee_manager_for_testing(ctx);
    };

    // Verify fee manager was created and shared
    ts::next_tx(&mut scenario, sender);
    {
        let fee_manager = ts::take_shared<FeeManager>(&scenario);

        // Check default values
        assert!(fee::get_dao_creation_fee(&fee_manager) == 10_000, 0);
        assert!(fee::get_proposal_creation_fee_per_outcome(&fee_manager) == 1000, 1);
        assert!(fee::get_dao_monthly_fee(&fee_manager) == 10_000_000, 2);
        assert!(fee::get_sui_balance(&fee_manager) == 0, 3);
        assert!(fee::get_recovery_fee(&fee_manager) == 5_000_000_000, 4);
        assert!(fee::get_launchpad_creation_fee(&fee_manager) == 10_000_000_000, 5);

        ts::return_shared(fee_manager);
    };

    clock.destroy_for_testing();
    ts::end(scenario);
}

// === DAO Creation Fee Tests ===

#[test]
fun test_deposit_dao_creation_payment_success() {
    let sender = @0xA;
    let (mut scenario, mut clock) = setup_test(sender);

    // Create fee manager
    ts::next_tx(&mut scenario, sender);
    {
        let ctx = ts::ctx(&mut scenario);
        fee::create_fee_manager_for_testing(ctx);
    };

    // Mint SUI for payment
    mint_sui(&mut scenario, 10_000, sender);

    // Pay DAO creation fee
    ts::next_tx(&mut scenario, sender);
    {
        let mut fee_manager = ts::take_shared<FeeManager>(&scenario);
        let payment = ts::take_from_sender<Coin<SUI>>(&scenario);
        let ctx = ts::ctx(&mut scenario);

        fee::deposit_dao_creation_payment(&mut fee_manager, payment, &clock, ctx);

        // Verify balance increased
        assert!(fee::get_sui_balance(&fee_manager) == 10_000, 0);

        ts::return_shared(fee_manager);
    };

    clock.destroy_for_testing();
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = fee::EInvalidPayment)]
fun test_deposit_dao_creation_payment_wrong_amount() {
    let sender = @0xA;
    let (mut scenario, mut clock) = setup_test(sender);

    // Create fee manager
    ts::next_tx(&mut scenario, sender);
    {
        let ctx = ts::ctx(&mut scenario);
        fee::create_fee_manager_for_testing(ctx);
    };

    // Mint wrong amount
    mint_sui(&mut scenario, 5_000, sender); // Too little

    // Try to pay - should fail
    ts::next_tx(&mut scenario, sender);
    {
        let mut fee_manager = ts::take_shared<FeeManager>(&scenario);
        let payment = ts::take_from_sender<Coin<SUI>>(&scenario);
        let ctx = ts::ctx(&mut scenario);

        fee::deposit_dao_creation_payment(&mut fee_manager, payment, &clock, ctx);

        ts::return_shared(fee_manager);
    };

    clock.destroy_for_testing();
    ts::end(scenario);
}

// === Proposal Creation Fee Tests ===

#[test]
fun test_deposit_proposal_creation_payment_single_outcome() {
    let sender = @0xA;
    let (mut scenario, mut clock) = setup_test(sender);

    // Create fee manager
    ts::next_tx(&mut scenario, sender);
    {
        let ctx = ts::ctx(&mut scenario);
        fee::create_fee_manager_for_testing(ctx);
    };

    // Mint SUI for payment (1000 per outcome * 1 = 1000)
    mint_sui(&mut scenario, 1000, sender);

    // Pay proposal creation fee
    ts::next_tx(&mut scenario, sender);
    {
        let mut fee_manager = ts::take_shared<FeeManager>(&scenario);
        let payment = ts::take_from_sender<Coin<SUI>>(&scenario);
        let ctx = ts::ctx(&mut scenario);

        fee::deposit_proposal_creation_payment(&mut fee_manager, payment, 1, &clock, ctx);

        assert!(fee::get_sui_balance(&fee_manager) == 1000, 0);

        ts::return_shared(fee_manager);
    };

    clock.destroy_for_testing();
    ts::end(scenario);
}

#[test]
fun test_deposit_proposal_creation_payment_multiple_outcomes() {
    let sender = @0xA;
    let (mut scenario, mut clock) = setup_test(sender);

    // Create fee manager
    ts::next_tx(&mut scenario, sender);
    {
        let ctx = ts::ctx(&mut scenario);
        fee::create_fee_manager_for_testing(ctx);
    };

    // Mint SUI for payment (1000 per outcome * 5 = 5000)
    mint_sui(&mut scenario, 5000, sender);

    // Pay proposal creation fee for 5 outcomes
    ts::next_tx(&mut scenario, sender);
    {
        let mut fee_manager = ts::take_shared<FeeManager>(&scenario);
        let payment = ts::take_from_sender<Coin<SUI>>(&scenario);
        let ctx = ts::ctx(&mut scenario);

        fee::deposit_proposal_creation_payment(&mut fee_manager, payment, 5, &clock, ctx);

        assert!(fee::get_sui_balance(&fee_manager) == 5000, 0);

        ts::return_shared(fee_manager);
    };

    clock.destroy_for_testing();
    ts::end(scenario);
}

// === Verification Fee Tests ===

#[test]
fun test_deposit_verification_payment_level_1() {
    let sender = @0xA;
    let (mut scenario, mut clock) = setup_test(sender);

    // Create fee manager
    ts::next_tx(&mut scenario, sender);
    {
        let ctx = ts::ctx(&mut scenario);
        fee::create_fee_manager_for_testing(ctx);
    };

    // Mint SUI for verification fee
    mint_sui(&mut scenario, 10_000, sender);

    // Pay verification fee
    ts::next_tx(&mut scenario, sender);
    {
        let mut fee_manager = ts::take_shared<FeeManager>(&scenario);
        let payment = ts::take_from_sender<Coin<SUI>>(&scenario);
        let ctx = ts::ctx(&mut scenario);

        fee::deposit_verification_payment(&mut fee_manager, payment, 1, &clock, ctx);

        assert!(fee::get_sui_balance(&fee_manager) == 10_000, 0);

        ts::return_shared(fee_manager);
    };

    clock.destroy_for_testing();
    ts::end(scenario);
}

// === Admin Functions Tests ===

#[test]
fun test_update_dao_creation_fee() {
    let admin = @0xA;
    let (mut scenario, mut clock) = setup_test(admin);

    // Create fee manager
    ts::next_tx(&mut scenario, admin);
    {
        let ctx = ts::ctx(&mut scenario);
        fee::create_fee_manager_for_testing(ctx);
    };

    // Update fee
    ts::next_tx(&mut scenario, admin);
    {
        let mut fee_manager = ts::take_shared<FeeManager>(&scenario);
        let admin_cap = ts::take_from_sender<FeeAdminCap>(&scenario);
        let ctx = ts::ctx(&mut scenario);

        fee::update_dao_creation_fee(&mut fee_manager, &admin_cap, 20_000, &clock, ctx);

        assert!(fee::get_dao_creation_fee(&fee_manager) == 20_000, 0);

        ts::return_to_sender(&scenario, admin_cap);
        ts::return_shared(fee_manager);
    };

    clock.destroy_for_testing();
    ts::end(scenario);
}

#[test]
fun test_update_proposal_creation_fee() {
    let admin = @0xA;
    let (mut scenario, mut clock) = setup_test(admin);

    // Create fee manager
    ts::next_tx(&mut scenario, admin);
    {
        let ctx = ts::ctx(&mut scenario);
        fee::create_fee_manager_for_testing(ctx);
    };

    // Update fee
    ts::next_tx(&mut scenario, admin);
    {
        let mut fee_manager = ts::take_shared<FeeManager>(&scenario);
        let admin_cap = ts::take_from_sender<FeeAdminCap>(&scenario);
        let ctx = ts::ctx(&mut scenario);

        fee::update_proposal_creation_fee(&mut fee_manager, &admin_cap, 2000, &clock, ctx);

        assert!(fee::get_proposal_creation_fee_per_outcome(&fee_manager) == 2000, 0);

        ts::return_to_sender(&scenario, admin_cap);
        ts::return_shared(fee_manager);
    };

    clock.destroy_for_testing();
    ts::end(scenario);
}

#[test]
fun test_add_verification_level() {
    let admin = @0xA;
    let (mut scenario, mut clock) = setup_test(admin);

    // Create fee manager
    ts::next_tx(&mut scenario, admin);
    {
        let ctx = ts::ctx(&mut scenario);
        fee::create_fee_manager_for_testing(ctx);
    };

    // Add new verification level
    ts::next_tx(&mut scenario, admin);
    {
        let mut fee_manager = ts::take_shared<FeeManager>(&scenario);
        let admin_cap = ts::take_from_sender<FeeAdminCap>(&scenario);
        let ctx = ts::ctx(&mut scenario);

        fee::add_verification_level(&mut fee_manager, &admin_cap, 2, 50_000, &clock, ctx);

        assert!(fee::has_verification_level(&fee_manager, 2), 0);
        assert!(fee::get_verification_fee_for_level(&fee_manager, 2) == 50_000, 1);

        ts::return_to_sender(&scenario, admin_cap);
        ts::return_shared(fee_manager);
    };

    clock.destroy_for_testing();
    ts::end(scenario);
}

#[test]
fun test_update_verification_fee() {
    let admin = @0xA;
    let (mut scenario, mut clock) = setup_test(admin);

    // Create fee manager
    ts::next_tx(&mut scenario, admin);
    {
        let ctx = ts::ctx(&mut scenario);
        fee::create_fee_manager_for_testing(ctx);
    };

    // Update existing verification fee
    ts::next_tx(&mut scenario, admin);
    {
        let mut fee_manager = ts::take_shared<FeeManager>(&scenario);
        let admin_cap = ts::take_from_sender<FeeAdminCap>(&scenario);
        let ctx = ts::ctx(&mut scenario);

        fee::update_verification_fee(&mut fee_manager, &admin_cap, 1, 15_000, &clock, ctx);

        assert!(fee::get_verification_fee_for_level(&fee_manager, 1) == 15_000, 0);

        ts::return_to_sender(&scenario, admin_cap);
        ts::return_shared(fee_manager);
    };

    clock.destroy_for_testing();
    ts::end(scenario);
}

#[test]
fun test_remove_verification_level() {
    let admin = @0xA;
    let (mut scenario, mut clock) = setup_test(admin);

    // Create fee manager
    ts::next_tx(&mut scenario, admin);
    {
        let ctx = ts::ctx(&mut scenario);
        fee::create_fee_manager_for_testing(ctx);
    };

    // Add a new level first
    ts::next_tx(&mut scenario, admin);
    {
        let mut fee_manager = ts::take_shared<FeeManager>(&scenario);
        let admin_cap = ts::take_from_sender<FeeAdminCap>(&scenario);
        let ctx = ts::ctx(&mut scenario);

        fee::add_verification_level(&mut fee_manager, &admin_cap, 2, 50_000, &clock, ctx);

        ts::return_to_sender(&scenario, admin_cap);
        ts::return_shared(fee_manager);
    };

    // Now remove it
    ts::next_tx(&mut scenario, admin);
    {
        let mut fee_manager = ts::take_shared<FeeManager>(&scenario);
        let admin_cap = ts::take_from_sender<FeeAdminCap>(&scenario);
        let ctx = ts::ctx(&mut scenario);

        fee::remove_verification_level(&mut fee_manager, &admin_cap, 2, &clock, ctx);

        assert!(!fee::has_verification_level(&fee_manager, 2), 0);

        ts::return_to_sender(&scenario, admin_cap);
        ts::return_shared(fee_manager);
    };

    clock.destroy_for_testing();
    ts::end(scenario);
}

#[test]
fun test_withdraw_all_fees() {
    let admin = @0xA;
    let (mut scenario, mut clock) = setup_test(admin);

    // Create fee manager
    ts::next_tx(&mut scenario, admin);
    {
        let ctx = ts::ctx(&mut scenario);
        fee::create_fee_manager_for_testing(ctx);
    };

    // Collect some fees
    mint_sui(&mut scenario, 10_000, admin);
    ts::next_tx(&mut scenario, admin);
    {
        let mut fee_manager = ts::take_shared<FeeManager>(&scenario);
        let payment = ts::take_from_sender<Coin<SUI>>(&scenario);
        let ctx = ts::ctx(&mut scenario);

        fee::deposit_dao_creation_payment(&mut fee_manager, payment, &clock, ctx);

        ts::return_shared(fee_manager);
    };

    // Withdraw fees
    ts::next_tx(&mut scenario, admin);
    {
        let mut fee_manager = ts::take_shared<FeeManager>(&scenario);
        let admin_cap = ts::take_from_sender<FeeAdminCap>(&scenario);
        let ctx = ts::ctx(&mut scenario);

        fee::withdraw_all_fees(&mut fee_manager, &admin_cap, &clock, ctx);

        // Balance should be zero after withdrawal
        assert!(fee::get_sui_balance(&fee_manager) == 0, 0);

        ts::return_to_sender(&scenario, admin_cap);
        ts::return_shared(fee_manager);
    };

    // Verify admin received the fees
    ts::next_tx(&mut scenario, admin);
    {
        let withdrawn = ts::take_from_sender<Coin<SUI>>(&scenario);
        assert!(withdrawn.value() == 10_000, 0);
        ts::return_to_sender(&scenario, withdrawn);
    };

    clock.destroy_for_testing();
    ts::end(scenario);
}

// === Monthly Fee Tests ===

#[test]
fun test_update_dao_monthly_fee_with_delay() {
    let admin = @0xA;
    let (mut scenario, mut clock) = setup_test(admin);

    // Create fee manager
    ts::next_tx(&mut scenario, admin);
    {
        let ctx = ts::ctx(&mut scenario);
        fee::create_fee_manager_for_testing(ctx);
    };

    // Update monthly fee (should be pending)
    ts::next_tx(&mut scenario, admin);
    {
        let mut fee_manager = ts::take_shared<FeeManager>(&scenario);
        let admin_cap = ts::take_from_sender<FeeAdminCap>(&scenario);
        let ctx = ts::ctx(&mut scenario);

        fee::update_dao_monthly_fee(&mut fee_manager, &admin_cap, 20_000_000, &clock, ctx);

        // Fee should still be old value
        assert!(fee::get_dao_monthly_fee(&fee_manager) == 10_000_000, 0);

        // But pending should be set
        let pending = fee::get_pending_dao_monthly_fee(&fee_manager);
        assert!(pending.is_some(), 1);
        assert!(*pending.borrow() == 20_000_000, 2);

        ts::return_to_sender(&scenario, admin_cap);
        ts::return_shared(fee_manager);
    };

    // Apply pending fee after 6 months
    clock.increment_for_testing(15_552_000_000); // 6 months
    ts::next_tx(&mut scenario, admin);
    {
        let mut fee_manager = ts::take_shared<FeeManager>(&scenario);

        fee::apply_pending_fee_if_due(&mut fee_manager, &clock);

        // Fee should now be updated
        assert!(fee::get_dao_monthly_fee(&fee_manager) == 20_000_000, 0);

        // Pending should be cleared
        assert!(fee::get_pending_dao_monthly_fee(&fee_manager).is_none(), 1);

        ts::return_shared(fee_manager);
    };

    clock.destroy_for_testing();
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = fee::EFeeExceedsHardCap)]
fun test_update_dao_monthly_fee_exceeds_hard_cap() {
    let admin = @0xA;
    let (mut scenario, mut clock) = setup_test(admin);

    // Create fee manager
    ts::next_tx(&mut scenario, admin);
    {
        let ctx = ts::ctx(&mut scenario);
        fee::create_fee_manager_for_testing(ctx);
    };

    // Try to set fee above hard cap
    ts::next_tx(&mut scenario, admin);
    {
        let mut fee_manager = ts::take_shared<FeeManager>(&scenario);
        let admin_cap = ts::take_from_sender<FeeAdminCap>(&scenario);
        let ctx = ts::ctx(&mut scenario);

        fee::update_dao_monthly_fee(&mut fee_manager, &admin_cap, 10_000_000_001, &clock, ctx); // Over 10B

        ts::return_to_sender(&scenario, admin_cap);
        ts::return_shared(fee_manager);
    };

    clock.destroy_for_testing();
    ts::end(scenario);
}

// === Recovery Fee Tests ===

#[test]
fun test_update_recovery_fee() {
    let admin = @0xA;
    let (mut scenario, mut clock) = setup_test(admin);

    // Create fee manager
    ts::next_tx(&mut scenario, admin);
    {
        let ctx = ts::ctx(&mut scenario);
        fee::create_fee_manager_for_testing(ctx);
    };

    // Update recovery fee
    ts::next_tx(&mut scenario, admin);
    {
        let mut fee_manager = ts::take_shared<FeeManager>(&scenario);
        let admin_cap = ts::take_from_sender<FeeAdminCap>(&scenario);
        let ctx = ts::ctx(&mut scenario);

        fee::update_recovery_fee(&mut fee_manager, &admin_cap, 10_000_000_000, &clock, ctx);

        assert!(fee::get_recovery_fee(&fee_manager) == 10_000_000_000, 0);

        ts::return_to_sender(&scenario, admin_cap);
        ts::return_shared(fee_manager);
    };

    clock.destroy_for_testing();
    ts::end(scenario);
}

#[test]
fun test_deposit_recovery_payment() {
    let sender = @0xA;
    let (mut scenario, mut clock) = setup_test(sender);

    // Create fee manager
    ts::next_tx(&mut scenario, sender);
    {
        let ctx = ts::ctx(&mut scenario);
        fee::create_fee_manager_for_testing(ctx);
    };

    // Mint SUI for recovery fee
    mint_sui(&mut scenario, 5_000_000_000, sender);

    // Pay recovery fee
    ts::next_tx(&mut scenario, sender);
    {
        let mut fee_manager = ts::take_shared<FeeManager>(&scenario);
        let payment = ts::take_from_sender<Coin<SUI>>(&scenario);
        let ctx = ts::ctx(&mut scenario);

        let dao_id = object::id_from_address(@0xDAD);
        let council_id = object::id_from_address(@0xC0C);

        fee::deposit_recovery_payment(&mut fee_manager, dao_id, council_id, payment, &clock, ctx);

        assert!(fee::get_sui_balance(&fee_manager) == 5_000_000_000, 0);

        ts::return_shared(fee_manager);
    };

    clock.destroy_for_testing();
    ts::end(scenario);
}

