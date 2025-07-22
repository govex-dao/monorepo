#[test_only]
module futarchy::mint_burn_proposals_tests;

use sui::{
    test_scenario::{Self as test, Scenario, next_tx, ctx},
    coin::{Self, Coin},
    clock::{Self, Clock},
    test_utils::assert_eq,
};
use futarchy::{
    mint_burn_proposals,
    treasury_actions::{Self, ActionRegistry},
    dao::{Self, DAO},
    fee::{Self, FeeManager},
    factory,
};

// Test coin types
#[test_only]
public struct TestAssetCoin has drop {}

#[test_only]
public struct TestStableCoin has drop {}

// Test constants
const ADMIN: address = @0xAD;
const USER1: address = @0x1;
const USER2: address = @0x2;
const INITIAL_STABLE: u64 = 1_000_000_000;
const INITIAL_ASSET: u64 = 1_000_000_000;

fun setup_dao_with_registry(scenario: &mut Scenario): (ID, ID) {
    // Create clock
    next_tx(scenario, ADMIN);
    {
        let clock = clock::create_for_testing(ctx(scenario));
        clock::share_for_testing(clock);
    };

    // Create DAO factory and fee manager
    next_tx(scenario, ADMIN);
    {
        factory::create_factory(ctx(scenario));
        fee::create_fee_manager_for_testing(ctx(scenario));
    };
    
    // Get the caps in a new transaction
    next_tx(scenario, ADMIN);
    let (factory_owner_cap_id, validator_cap_id) = {
        let factory_owner_cap = test::take_from_sender<factory::FactoryOwnerCap>(scenario);
        let validator_cap = test::take_from_sender<factory::ValidatorAdminCap>(scenario);
        let factory_owner_cap_id = object::id(&factory_owner_cap);
        let validator_cap_id = object::id(&validator_cap);
        
        // Return them to sender for later use
        test::return_to_sender(scenario, factory_owner_cap);
        test::return_to_sender(scenario, validator_cap);
        
        (factory_owner_cap_id, validator_cap_id)
    };

    // Create action registry
    next_tx(scenario, ADMIN);
    {
        treasury_actions::create_for_testing(ctx(scenario));
    };

    // Create DAO
    next_tx(scenario, ADMIN);
    {
        let mut factory = test::take_shared<factory::Factory>(scenario);
        let mut fee_manager = test::take_shared<fee::FeeManager>(scenario);
        let payment = coin::mint_for_testing<sui::sui::SUI>(10_000, ctx(scenario)); // DAO creation fee
        let clock = test::take_shared<Clock>(scenario);
        
        // Add our test stable coin to allowed list
        let factory_owner_cap = test::take_from_sender<factory::FactoryOwnerCap>(scenario);
        factory::add_allowed_stable_type<TestStableCoin>(
            &mut factory,
            &factory_owner_cap,
            &clock,
            ctx(scenario)
        );
        test::return_to_sender(scenario, factory_owner_cap);
        
        factory::create_dao<TestAssetCoin, TestStableCoin>(
            &mut factory,
            &mut fee_manager,
            payment,
            1_000_000, // min_asset_amount
            1_000_000, // min_stable_amount
            std::ascii::string(b"Test DAO"),
            std::ascii::string(b"https://test.com/icon.png"),
            86400000, // review_period_ms
            604800000, // trading_period_ms (7 days)
            3600000, // amm_twap_start_delay (1 hour)
            10, // amm_twap_step_max
            1_000_000_000_000, // amm_twap_initial_observation
            100_000, // twap_threshold
            b"Test DAO for mint/burn proposals".to_string(),
            3, // max_outcomes
            vector[b"Test metadata".to_string()], // metadata
            vector::empty(), // agreement_lines
            vector::empty(), // agreement_difficulties
            &clock,
            ctx(scenario)
        );
        
        test::return_shared(factory);
        test::return_shared(fee_manager);
        test::return_shared(clock);
    };
    
    (factory_owner_cap_id, validator_cap_id)
}

#[test]
fun test_create_mint_proposal() {
    let mut scenario = test::begin(ADMIN);
    let (_factory_owner_cap_id, _validator_cap_id) = setup_dao_with_registry(&mut scenario);

    // Create mint proposal
    next_tx(&mut scenario, USER1);
    {
        let mut dao = test::take_shared<DAO>(&scenario);
        let mut fee_manager = test::take_shared<FeeManager>(&scenario);
        let mut registry = test::take_shared<ActionRegistry>(&scenario);
        let clock = test::take_shared<Clock>(&scenario);
        
        let payment = coin::mint_for_testing<sui::sui::SUI>(2_000, ctx(&mut scenario)); // 2 outcomes * 1000 per outcome
        let asset_coin = coin::mint_for_testing<TestAssetCoin>(INITIAL_ASSET, ctx(&mut scenario));
        let stable_coin = coin::mint_for_testing<TestStableCoin>(INITIAL_STABLE, ctx(&mut scenario));
        
        let dao_fee_payment = coin::mint_for_testing<TestStableCoin>(0, scenario.ctx()); // No DAO fee
        mint_burn_proposals::create_mint_proposal<TestAssetCoin, TestStableCoin, TestAssetCoin>(
            &mut dao,
            &mut fee_manager,
            &mut registry,
            payment,
            dao_fee_payment,
            asset_coin,
            stable_coin,
            b"Mint 1000 TEST tokens".to_string(),
            b"Proposal to mint new TEST tokens".to_string(),
            vector[
                b"Reject mint proposal".to_string(),
                b"Approve minting tokens".to_string()
            ],
            vector[b"Reject".to_string(), b"Accept".to_string()],
            vector[1_000_000_000, 1_000_000_000, 1_000_000_000, 1_000_000_000], // Initial outcome amounts (asset, stable for each outcome)
            1000, // Mint amount
            USER2, // Recipient
            b"Initial token distribution".to_string(),
            &clock,
            ctx(&mut scenario)
        );
        
        // Get the proposal count to verify creation
        let (active, total, _) = dao::get_stats(&dao);
        assert_eq(total, 1);
        
        test::return_shared(dao);
        test::return_shared(fee_manager);
        test::return_shared(registry);
        test::return_shared(clock);
    };
    
    test::end(scenario);
}

#[test]
fun test_create_burn_proposal() {
    let mut scenario = test::begin(ADMIN);
    let (_factory_owner_cap_id, _validator_cap_id) = setup_dao_with_registry(&mut scenario);

    // Create burn proposal
    next_tx(&mut scenario, USER1);
    {
        let mut dao = test::take_shared<DAO>(&scenario);
        let mut fee_manager = test::take_shared<FeeManager>(&scenario);
        let mut registry = test::take_shared<ActionRegistry>(&scenario);
        let clock = test::take_shared<Clock>(&scenario);
        
        let payment = coin::mint_for_testing<sui::sui::SUI>(2_000, ctx(&mut scenario)); // 2 outcomes * 1000 per outcome
        let asset_coin = coin::mint_for_testing<TestAssetCoin>(INITIAL_ASSET, ctx(&mut scenario));
        let stable_coin = coin::mint_for_testing<TestStableCoin>(INITIAL_STABLE, ctx(&mut scenario));
        
        let dao_fee_payment = coin::mint_for_testing<TestStableCoin>(0, scenario.ctx()); // No DAO fee
        mint_burn_proposals::create_burn_proposal<TestAssetCoin, TestStableCoin, TestAssetCoin>(
            &mut dao,
            &mut fee_manager,
            &mut registry,
            payment,
            dao_fee_payment,
            asset_coin,
            stable_coin,
            b"Burn 500 TEST tokens".to_string(),
            b"Proposal to burn TEST tokens from treasury".to_string(),
            vector[
                b"Reject burn proposal".to_string(),
                b"Approve burning tokens from treasury".to_string()
            ],
            vector[b"Reject".to_string(), b"Accept".to_string()],
            vector[1_000_000_000, 1_000_000_000, 1_000_000_000, 1_000_000_000], // Initial outcome amounts
            500, // Burn amount
            b"Reduce token supply".to_string(),
            &clock,
            ctx(&mut scenario)
);
        
        // Get the proposal count to verify creation
        let (active, total, _) = dao::get_stats(&dao);
        assert_eq(total, 1);
        
        test::return_shared(dao);
        test::return_shared(fee_manager);
        test::return_shared(registry);
        test::return_shared(clock);
    };
    
    test::end(scenario);
}

#[test]
fun test_create_mint_and_burn_proposal() {
    let mut scenario = test::begin(ADMIN);
    let (_factory_owner_cap_id, _validator_cap_id) = setup_dao_with_registry(&mut scenario);

    // Create combined mint and burn proposal
    next_tx(&mut scenario, USER1);
    {
        let mut dao = test::take_shared<DAO>(&scenario);
        let mut fee_manager = test::take_shared<FeeManager>(&scenario);
        let mut registry = test::take_shared<ActionRegistry>(&scenario);
        let clock = test::take_shared<Clock>(&scenario);
        
        let payment = coin::mint_for_testing<sui::sui::SUI>(2_000, ctx(&mut scenario)); // 2 outcomes * 1000 per outcome
        let asset_coin = coin::mint_for_testing<TestAssetCoin>(INITIAL_ASSET, ctx(&mut scenario));
        let stable_coin = coin::mint_for_testing<TestStableCoin>(INITIAL_STABLE, ctx(&mut scenario));
        
        let dao_fee_payment = coin::mint_for_testing<TestStableCoin>(0, scenario.ctx()); // No DAO fee
        mint_burn_proposals::create_mint_and_burn_proposal<TestAssetCoin, TestStableCoin, TestAssetCoin>(
            &mut dao,
            &mut fee_manager,
            &mut registry,
            payment,
            dao_fee_payment,
            asset_coin,
            stable_coin,
            b"Mint 1000 and Burn 500 TEST".to_string(),
            b"Proposal to mint new tokens and burn existing ones".to_string(),
            vector[
                b"Reject mint and burn proposal".to_string(),
                b"Approve minting and burning tokens".to_string()
            ],
            vector[b"Reject".to_string(), b"Accept".to_string()],
            vector[1_000_000_000, 1_000_000_000, 1_000_000_000, 1_000_000_000], // Initial outcome amounts
            1000, // Mint amount
            USER2, // Mint recipient
            500, // Burn amount
            &clock,
            ctx(&mut scenario)
);
        
        // Get the proposal count to verify creation
        let (active, total, _) = dao::get_stats(&dao);
        assert_eq(total, 1);
        
        test::return_shared(dao);
        test::return_shared(fee_manager);
        test::return_shared(registry);
        test::return_shared(clock);
    };
    
    test::end(scenario);
}

#[test]
fun test_multi_outcome_mint_proposal() {
    let mut scenario = test::begin(ADMIN);
    let (_factory_owner_cap_id, _validator_cap_id) = setup_dao_with_registry(&mut scenario);

    // Create multi-outcome mint proposal
    next_tx(&mut scenario, USER1);
    {
        let mut dao = test::take_shared<DAO>(&scenario);
        let mut fee_manager = test::take_shared<FeeManager>(&scenario);
        let mut registry = test::take_shared<ActionRegistry>(&scenario);
        let clock = test::take_shared<Clock>(&scenario);
        
        let payment = coin::mint_for_testing<sui::sui::SUI>(3_000, ctx(&mut scenario)); // 3 outcomes * 1000 per outcome
        let asset_coin = coin::mint_for_testing<TestAssetCoin>(INITIAL_ASSET, ctx(&mut scenario));
        let stable_coin = coin::mint_for_testing<TestStableCoin>(INITIAL_STABLE, ctx(&mut scenario));
        
        // Define 3 outcomes with different mint amounts
        let outcome_descriptions = vector[
            b"Reject minting".to_string(),
            b"Mint 500 tokens".to_string(),
            b"Mint 1000 tokens".to_string(),
        ];
        let outcome_messages = vector[
            b"Reject".to_string(),
            b"Conservative minting".to_string(),
            b"Aggressive minting".to_string(),
        ];
        
        // Mint actions: [outcome_index, amount, recipient_index]
        let mint_actions = vector[
            vector[1, 500, 0], // Outcome 1: mint 500 to recipient 0
            vector[2, 1000, 0], // Outcome 2: mint 1000 to recipient 0
        ];
        
        let recipients = vector[USER2];
        let descriptions = vector[
            b"Conservative mint".to_string(),
            b"Aggressive mint".to_string(),
        ];
        
        let dao_fee_payment = coin::mint_for_testing<TestStableCoin>(0, scenario.ctx()); // No DAO fee
        mint_burn_proposals::create_multi_outcome_mint_proposal<TestAssetCoin, TestStableCoin, TestAssetCoin>(
            &mut dao,
            &mut fee_manager,
            &mut registry,
            payment,
            dao_fee_payment,
            asset_coin,
            stable_coin,
            b"Multi-outcome Mint Proposal".to_string(),
            b"Vote on how many tokens to mint".to_string(),
            outcome_descriptions,
            outcome_messages,
            vector[1_000_000_000, 1_000_000_000, 1_000_000_000, 1_000_000_000, 1_000_000_000, 1_000_000_000], // Initial outcome amounts (asset, stable for each of 3 outcomes)
            mint_actions,
            recipients,
            descriptions,
            &clock,
            ctx(&mut scenario)
);
        
        // Get the proposal count to verify creation
        let (active, total, _) = dao::get_stats(&dao);
        assert_eq(total, 1);
        
        test::return_shared(dao);
        test::return_shared(fee_manager);
        test::return_shared(registry);
        test::return_shared(clock);
    };
    
    test::end(scenario);
}

#[test]
#[expected_failure(abort_code = mint_burn_proposals::EInvalidAmount)]
fun test_create_mint_proposal_zero_amount() {
    let mut scenario = test::begin(ADMIN);
    let (_factory_owner_cap_id, _validator_cap_id) = setup_dao_with_registry(&mut scenario);

    next_tx(&mut scenario, USER1);
    {
        let mut dao = test::take_shared<DAO>(&scenario);
        let mut fee_manager = test::take_shared<FeeManager>(&scenario);
        let mut registry = test::take_shared<ActionRegistry>(&scenario);
        let clock = test::take_shared<Clock>(&scenario);
        
        let payment = coin::mint_for_testing<sui::sui::SUI>(2_000, ctx(&mut scenario)); // 2 outcomes * 1000 per outcome
        let asset_coin = coin::mint_for_testing<TestAssetCoin>(INITIAL_ASSET, ctx(&mut scenario));
        let stable_coin = coin::mint_for_testing<TestStableCoin>(INITIAL_STABLE, ctx(&mut scenario));
        
        // Should fail with zero mint amount
        let dao_fee_payment = coin::mint_for_testing<TestStableCoin>(0, scenario.ctx()); // No DAO fee
        mint_burn_proposals::create_mint_proposal<TestAssetCoin, TestStableCoin, TestAssetCoin>(
            &mut dao,
            &mut fee_manager,
            &mut registry,
            payment,
            dao_fee_payment,
            asset_coin,
            stable_coin,
            b"Invalid Mint".to_string(),
            b"Zero amount mint".to_string(),
            vector[
                b"Reject mint proposal".to_string(),
                b"Approve minting tokens".to_string()
            ],
            vector[b"Reject".to_string(), b"Accept".to_string()],
            vector[1_000_000_000, 1_000_000_000, 1_000_000_000, 1_000_000_000], // Initial outcome amounts
            0, // Zero mint amount - should fail
            USER2,
            b"Invalid".to_string(),
            &clock,
            ctx(&mut scenario)
        );
        
        test::return_shared(dao);
        test::return_shared(fee_manager);
        test::return_shared(registry);
        test::return_shared(clock);
    };
    
    test::end(scenario);
}

#[test]
#[expected_failure(abort_code = mint_burn_proposals::EInvalidAmount)]
fun test_create_burn_proposal_zero_amount() {
    let mut scenario = test::begin(ADMIN);
    let (_factory_owner_cap_id, _validator_cap_id) = setup_dao_with_registry(&mut scenario);

    next_tx(&mut scenario, USER1);
    {
        let mut dao = test::take_shared<DAO>(&scenario);
        let mut fee_manager = test::take_shared<FeeManager>(&scenario);
        let mut registry = test::take_shared<ActionRegistry>(&scenario);
        let clock = test::take_shared<Clock>(&scenario);
        
        let payment = coin::mint_for_testing<sui::sui::SUI>(2_000, ctx(&mut scenario)); // 2 outcomes * 1000 per outcome
        let asset_coin = coin::mint_for_testing<TestAssetCoin>(INITIAL_ASSET, ctx(&mut scenario));
        let stable_coin = coin::mint_for_testing<TestStableCoin>(INITIAL_STABLE, ctx(&mut scenario));
        
        // Should fail with zero burn amount
        let dao_fee_payment = coin::mint_for_testing<TestStableCoin>(0, scenario.ctx()); // No DAO fee
        mint_burn_proposals::create_burn_proposal<TestAssetCoin, TestStableCoin, TestAssetCoin>(
            &mut dao,
            &mut fee_manager,
            &mut registry,
            payment,
            dao_fee_payment,
            asset_coin,
            stable_coin,
            b"Invalid Burn".to_string(),
            b"Zero amount burn".to_string(),
            vector[
                b"Reject burn proposal".to_string(),
                b"Approve burning tokens from treasury".to_string()
            ],
            vector[b"Reject".to_string(), b"Accept".to_string()],
            vector[1_000_000_000, 1_000_000_000, 1_000_000_000, 1_000_000_000], // Initial outcome amounts
            0, // Zero burn amount - should fail
            b"Invalid".to_string(),
            &clock,
            ctx(&mut scenario)
        );
        
        test::return_shared(dao);
        test::return_shared(fee_manager);
        test::return_shared(registry);
        test::return_shared(clock);
    };
    
    test::end(scenario);
}

#[test]
fun test_mint_and_burn_with_zero_burn() {
    let mut scenario = test::begin(ADMIN);
    let (_factory_owner_cap_id, _validator_cap_id) = setup_dao_with_registry(&mut scenario);

    // Test that mint_and_burn works with zero burn amount (only minting)
    next_tx(&mut scenario, USER1);
    {
        let mut dao = test::take_shared<DAO>(&scenario);
        let mut fee_manager = test::take_shared<FeeManager>(&scenario);
        let mut registry = test::take_shared<ActionRegistry>(&scenario);
        let clock = test::take_shared<Clock>(&scenario);
        
        let payment = coin::mint_for_testing<sui::sui::SUI>(2_000, ctx(&mut scenario)); // 2 outcomes * 1000 per outcome
        let asset_coin = coin::mint_for_testing<TestAssetCoin>(INITIAL_ASSET, ctx(&mut scenario));
        let stable_coin = coin::mint_for_testing<TestStableCoin>(INITIAL_STABLE, ctx(&mut scenario));
        
        let dao_fee_payment = coin::mint_for_testing<TestStableCoin>(0, scenario.ctx()); // No DAO fee
        mint_burn_proposals::create_mint_and_burn_proposal<TestAssetCoin, TestStableCoin, TestAssetCoin>(
            &mut dao,
            &mut fee_manager,
            &mut registry,
            payment,
            dao_fee_payment,
            asset_coin,
            stable_coin,
            b"Mint only".to_string(),
            b"Only minting, no burning".to_string(),
            vector[
                b"Reject mint and burn proposal".to_string(),
                b"Approve minting and burning tokens".to_string()
            ],
            vector[b"Reject".to_string(), b"Accept".to_string()],
            vector[1_000_000_000, 1_000_000_000, 1_000_000_000, 1_000_000_000], // Initial outcome amounts
            1000, // Mint amount
            USER2,
            0, // Zero burn amount - should be allowed
            &clock,
            ctx(&mut scenario)
);
        
        // Get the proposal count to verify creation
        let (active, total, _) = dao::get_stats(&dao);
        assert_eq(total, 1);
        
        test::return_shared(dao);
        test::return_shared(fee_manager);
        test::return_shared(registry);
        test::return_shared(clock);
    };
    
    test::end(scenario);
}