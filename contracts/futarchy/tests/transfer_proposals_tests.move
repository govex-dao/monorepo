#[test_only]
module futarchy::transfer_proposals_tests;

use sui::{
    test_scenario::{Self as test, Scenario, next_tx, ctx},
    coin::{Self, Coin},
    clock::{Self, Clock},
    test_utils::assert_eq,
};
use futarchy::{
    transfer_proposals,
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

const ADMIN: address = @0xAD;
const USER1: address = @0x1;
const USER2: address = @0x2;
const TREASURY2: address = @0x3;
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
    
    // Get the caps that were transferred to ADMIN
    next_tx(scenario, ADMIN);
    let (factory_owner_cap, validator_cap) = {
        let factory_owner_cap = test::take_from_address<factory::FactoryOwnerCap>(scenario, ADMIN);
        let validator_cap = test::take_from_address<factory::ValidatorAdminCap>(scenario, ADMIN);
        let factory_owner_cap_id = object::id(&factory_owner_cap);
        let validator_cap_id = object::id(&validator_cap);
        
        // Return them to sender for later use
        test::return_to_address(ADMIN, factory_owner_cap);
        test::return_to_address(ADMIN, validator_cap);
        
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
        let factory_owner_cap = test::take_from_address<factory::FactoryOwnerCap>(scenario, ADMIN);
        factory::add_allowed_stable_type<TestStableCoin>(
            &mut factory,
            &factory_owner_cap,
            &clock,
            ctx(scenario)
        );
        test::return_to_address(ADMIN, factory_owner_cap);
        
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
            b"Test DAO for transfer proposals".to_string(),
            3, // max_outcomes
            vector[b"Test metadata".to_string()], // metadata
            &clock,
            ctx(scenario)
        );
        
        test::return_shared(factory);
        test::return_shared(fee_manager);
        test::return_shared(clock);
    };
    
    (factory_owner_cap, validator_cap)
}

#[test]
fun test_create_capability_deposit_proposal() {
    let mut scenario = test::begin(ADMIN);
    let (_factory_owner_cap_id, _validator_cap_id) = setup_dao_with_registry(&mut scenario);

    // Create capability deposit proposal
    next_tx(&mut scenario, USER1);
    {
        let mut dao = test::take_shared<DAO>(&scenario);
        let mut fee_manager = test::take_shared<FeeManager>(&scenario);
        let mut registry = test::take_shared<ActionRegistry>(&scenario);
        let clock = test::take_shared<Clock>(&scenario);
        
        let payment = coin::mint_for_testing<sui::sui::SUI>(2_000, ctx(&mut scenario)); // 2 outcomes * 1000 per outcome
        let dao_fee_payment = coin::mint_for_testing<TestStableCoin>(0, scenario.ctx()); // No DAO fee
        let asset_coin = coin::mint_for_testing<TestAssetCoin>(INITIAL_ASSET, ctx(&mut scenario));
        let stable_coin = coin::mint_for_testing<TestStableCoin>(INITIAL_STABLE, ctx(&mut scenario));
        
        transfer_proposals::create_capability_deposit_proposal<TestAssetCoin, TestStableCoin, TestAssetCoin>(
            &mut dao,
            &mut fee_manager,
            &mut registry,
            payment,
            dao_fee_payment,
            asset_coin,
            stable_coin,
            b"Accept TreasuryCap for TEST".to_string(),
            b"Proposal to accept minting capability for TEST tokens".to_string(),
            vector[
                b"Reject treasury capability deposit".to_string(),
                b"Accept treasury capability deposit".to_string()
            ],
            vector[b"Reject".to_string(), b"Accept".to_string()],
            vector[1_000_000_000, 1_000_000_000, 1_000_000_000, 1_000_000_000], // Initial amounts
            option::some(10_000_000), // max_supply: 10M
            option::some(500_000), // max_mint_per_proposal: 500k
            3600000, // mint_cooldown_ms: 1 hour
            &clock,
            ctx(&mut scenario)
        );
        
        // Verify proposal was created
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
fun test_create_cross_treasury_transfer_proposal() {
    let mut scenario = test::begin(ADMIN);
    let (_factory_owner_cap_id, _validator_cap_id) = setup_dao_with_registry(&mut scenario);

    // Create cross-treasury transfer proposal
    next_tx(&mut scenario, USER1);
    {
        let mut dao = test::take_shared<DAO>(&scenario);
        let mut fee_manager = test::take_shared<FeeManager>(&scenario);
        let mut registry = test::take_shared<ActionRegistry>(&scenario);
        let clock = test::take_shared<Clock>(&scenario);
        
        let payment = coin::mint_for_testing<sui::sui::SUI>(2_000, ctx(&mut scenario)); // 2 outcomes * 1000 per outcome
        let dao_fee_payment = coin::mint_for_testing<TestStableCoin>(0, scenario.ctx()); // No DAO fee
        let asset_coin = coin::mint_for_testing<TestAssetCoin>(INITIAL_ASSET, ctx(&mut scenario));
        let stable_coin = coin::mint_for_testing<TestStableCoin>(INITIAL_STABLE, ctx(&mut scenario));
        
        transfer_proposals::create_cross_treasury_transfer_proposal<TestAssetCoin, TestStableCoin, TestAssetCoin>(
            &mut dao,
            &mut fee_manager,
            &mut registry,
            payment,
            dao_fee_payment,
            asset_coin,
            stable_coin,
            b"Transfer 100k TEST to Partner DAO".to_string(),
            b"Transfer tokens to partner DAO treasury".to_string(),
            vector[
                b"Reject cross-treasury transfer".to_string(),
                b"Approve transfer to target treasury".to_string()
            ],
            vector[b"Reject".to_string(), b"Accept".to_string()],
            vector[1_000_000_000, 1_000_000_000, 1_000_000_000, 1_000_000_000], // Initial amounts
            100_000, // amount
            TREASURY2, // target treasury
            b"Partnership agreement".to_string(),
            &clock,
            ctx(&mut scenario)
        );
        
        // Verify proposal was created
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
fun test_create_multi_transfer_proposal() {
    let mut scenario = test::begin(ADMIN);
    let (_factory_owner_cap_id, _validator_cap_id) = setup_dao_with_registry(&mut scenario);

    // Create multi-transfer proposal
    next_tx(&mut scenario, USER1);
    {
        let mut dao = test::take_shared<DAO>(&scenario);
        let mut fee_manager = test::take_shared<FeeManager>(&scenario);
        let mut registry = test::take_shared<ActionRegistry>(&scenario);
        let clock = test::take_shared<Clock>(&scenario);
        
        let payment = coin::mint_for_testing<sui::sui::SUI>(3_000, ctx(&mut scenario)); // 3 outcomes * 1000 per outcome
        let dao_fee_payment = coin::mint_for_testing<TestStableCoin>(0, scenario.ctx()); // No DAO fee
        let asset_coin = coin::mint_for_testing<TestAssetCoin>(INITIAL_ASSET, ctx(&mut scenario));
        let stable_coin = coin::mint_for_testing<TestStableCoin>(INITIAL_STABLE, ctx(&mut scenario));
        
        // Define 3 outcomes with different transfer amounts
        let outcome_descriptions = vector[
            b"No transfers".to_string(),
            b"Transfer 50k to treasury 1".to_string(),
            b"Transfer 100k split between 2 treasuries".to_string(),
        ];
        let outcome_messages = vector[
            b"Reject".to_string(),
            b"Conservative transfer".to_string(),
            b"Split transfer".to_string(),
        ];
        
        // Transfer specs: [outcome_index, amount, recipient_index]
        let transfer_specs = vector[
            vector[1, 50_000, 0], // Outcome 1: transfer 50k to recipient 0
            vector[2, 60_000, 0], // Outcome 2: transfer 60k to recipient 0
            vector[2, 40_000, 1], // Outcome 2: transfer 40k to recipient 1
        ];
        
        let recipients = vector[TREASURY2, USER2];
        
        transfer_proposals::create_multi_transfer_proposal<TestAssetCoin, TestStableCoin, TestAssetCoin>(
            &mut dao,
            &mut fee_manager,
            &mut registry,
            payment,
            dao_fee_payment,
            asset_coin,
            stable_coin,
            b"Multi-recipient Transfer".to_string(),
            b"Vote on transfer amounts and recipients".to_string(),
            outcome_descriptions,
            outcome_messages,
            vector[1_000_000_000, 1_000_000_000, 1_000_000_000, 1_000_000_000, 1_000_000_000, 1_000_000_000], // Initial amounts for 3 outcomes
            transfer_specs,
            recipients,
            &clock,
            ctx(&mut scenario)
        );
        
        // Verify proposal was created
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
fun test_create_mint_and_transfer_proposal() {
    let mut scenario = test::begin(ADMIN);
    let (_factory_owner_cap_id, _validator_cap_id) = setup_dao_with_registry(&mut scenario);

    // Create mint and transfer proposal
    next_tx(&mut scenario, USER1);
    {
        let mut dao = test::take_shared<DAO>(&scenario);
        let mut fee_manager = test::take_shared<FeeManager>(&scenario);
        let mut registry = test::take_shared<ActionRegistry>(&scenario);
        let clock = test::take_shared<Clock>(&scenario);
        
        let payment = coin::mint_for_testing<sui::sui::SUI>(2_000, ctx(&mut scenario)); // 2 outcomes * 1000 per outcome
        let dao_fee_payment = coin::mint_for_testing<TestStableCoin>(0, scenario.ctx()); // No DAO fee
        let asset_coin = coin::mint_for_testing<TestAssetCoin>(INITIAL_ASSET, ctx(&mut scenario));
        let stable_coin = coin::mint_for_testing<TestStableCoin>(INITIAL_STABLE, ctx(&mut scenario));
        
        let recipients = vector[USER1, USER2, TREASURY2];
        let amounts = vector[500_000, 300_000, 200_000]; // Total: 1M
        let descriptions = vector[
            b"Team allocation".to_string(),
            b"Community rewards".to_string(),
            b"Partner treasury".to_string(),
        ];
        
        transfer_proposals::create_mint_and_transfer_proposal<TestAssetCoin, TestStableCoin, TestAssetCoin>(
            &mut dao,
            &mut fee_manager,
            &mut registry,
            payment,
            dao_fee_payment,
            asset_coin,
            stable_coin,
            b"Mint 1M and Distribute".to_string(),
            b"Mint new tokens and distribute to multiple recipients".to_string(),
            vector[
                b"Reject mint and transfer proposal".to_string(),
                b"Approve minting and distribution".to_string()
            ],
            vector[b"Reject".to_string(), b"Accept".to_string()],
            vector[1_000_000_000, 1_000_000_000, 1_000_000_000, 1_000_000_000], // Initial amounts
            1_000_000, // Total mint amount
            recipients,
            amounts,
            descriptions,
            &clock,
            ctx(&mut scenario)
        );
        
        // Verify proposal was created
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
#[expected_failure(abort_code = transfer_proposals::EInvalidParameters)]
fun test_create_cross_treasury_transfer_zero_amount() {
    let mut scenario = test::begin(ADMIN);
    let (_factory_owner_cap_id, _validator_cap_id) = setup_dao_with_registry(&mut scenario);

    next_tx(&mut scenario, USER1);
    {
        let mut dao = test::take_shared<DAO>(&scenario);
        let mut fee_manager = test::take_shared<FeeManager>(&scenario);
        let mut registry = test::take_shared<ActionRegistry>(&scenario);
        let clock = test::take_shared<Clock>(&scenario);
        
        let payment = coin::mint_for_testing<sui::sui::SUI>(2_000, ctx(&mut scenario)); // 2 outcomes * 1000 per outcome
        let dao_fee_payment = coin::mint_for_testing<TestStableCoin>(0, scenario.ctx()); // No DAO fee
        let asset_coin = coin::mint_for_testing<TestAssetCoin>(INITIAL_ASSET, ctx(&mut scenario));
        let stable_coin = coin::mint_for_testing<TestStableCoin>(INITIAL_STABLE, ctx(&mut scenario));
        
        // Should fail with zero amount
        transfer_proposals::create_cross_treasury_transfer_proposal<TestAssetCoin, TestStableCoin, TestAssetCoin>(
            &mut dao,
            &mut fee_manager,
            &mut registry,
            payment,
            dao_fee_payment,
            asset_coin,
            stable_coin,
            b"Invalid Transfer".to_string(),
            b"Zero amount transfer".to_string(),
            vector[
                b"Reject cross-treasury transfer".to_string(),
                b"Approve transfer to target treasury".to_string()
            ],
            vector[b"Reject".to_string(), b"Accept".to_string()],
            vector[1_000_000_000, 1_000_000_000, 1_000_000_000, 1_000_000_000], // Initial amounts
            0, // Zero amount - should fail
            TREASURY2,
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
#[expected_failure(abort_code = transfer_proposals::EInvalidParameters)]
fun test_mint_and_transfer_amount_mismatch() {
    let mut scenario = test::begin(ADMIN);
    let (_factory_owner_cap_id, _validator_cap_id) = setup_dao_with_registry(&mut scenario);

    next_tx(&mut scenario, USER1);
    {
        let mut dao = test::take_shared<DAO>(&scenario);
        let mut fee_manager = test::take_shared<FeeManager>(&scenario);
        let mut registry = test::take_shared<ActionRegistry>(&scenario);
        let clock = test::take_shared<Clock>(&scenario);
        
        let payment = coin::mint_for_testing<sui::sui::SUI>(2_000, ctx(&mut scenario)); // 2 outcomes * 1000 per outcome
        let dao_fee_payment = coin::mint_for_testing<TestStableCoin>(0, scenario.ctx()); // No DAO fee
        let asset_coin = coin::mint_for_testing<TestAssetCoin>(INITIAL_ASSET, ctx(&mut scenario));
        let stable_coin = coin::mint_for_testing<TestStableCoin>(INITIAL_STABLE, ctx(&mut scenario));
        
        let recipients = vector[USER1, USER2];
        let amounts = vector[600_000, 300_000]; // Total: 900k (doesn't match mint_amount)
        let descriptions = vector[
            b"Allocation 1".to_string(),
            b"Allocation 2".to_string(),
        ];
        
        // Should fail - amounts don't sum to mint_amount
        transfer_proposals::create_mint_and_transfer_proposal<TestAssetCoin, TestStableCoin, TestAssetCoin>(
            &mut dao,
            &mut fee_manager,
            &mut registry,
            payment,
            dao_fee_payment,
            asset_coin,
            stable_coin,
            b"Invalid Mint and Transfer".to_string(),
            b"Amounts don't match".to_string(),
            vector[
                b"Reject mint and transfer proposal".to_string(),
                b"Approve minting and distribution".to_string()
            ],
            vector[b"Reject".to_string(), b"Accept".to_string()],
            vector[1_000_000_000, 1_000_000_000, 1_000_000_000, 1_000_000_000], // Initial amounts
            1_000_000, // Total mint amount doesn't match sum of amounts
            recipients,
            amounts,
            descriptions,
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
#[expected_failure(abort_code = transfer_proposals::EInvalidParameters)]
fun test_mint_and_transfer_array_length_mismatch() {
    let mut scenario = test::begin(ADMIN);
    let (_factory_owner_cap_id, _validator_cap_id) = setup_dao_with_registry(&mut scenario);

    next_tx(&mut scenario, USER1);
    {
        let mut dao = test::take_shared<DAO>(&scenario);
        let mut fee_manager = test::take_shared<FeeManager>(&scenario);
        let mut registry = test::take_shared<ActionRegistry>(&scenario);
        let clock = test::take_shared<Clock>(&scenario);
        
        let payment = coin::mint_for_testing<sui::sui::SUI>(2_000, ctx(&mut scenario)); // 2 outcomes * 1000 per outcome
        let dao_fee_payment = coin::mint_for_testing<TestStableCoin>(0, scenario.ctx()); // No DAO fee
        let asset_coin = coin::mint_for_testing<TestAssetCoin>(INITIAL_ASSET, ctx(&mut scenario));
        let stable_coin = coin::mint_for_testing<TestStableCoin>(INITIAL_STABLE, ctx(&mut scenario));
        
        let recipients = vector[USER1, USER2];
        let amounts = vector[500_000, 500_000];
        let descriptions = vector[b"Only one description".to_string()]; // Wrong length
        
        // Should fail - array lengths don't match
        transfer_proposals::create_mint_and_transfer_proposal<TestAssetCoin, TestStableCoin, TestAssetCoin>(
            &mut dao,
            &mut fee_manager,
            &mut registry,
            payment,
            dao_fee_payment,
            asset_coin,
            stable_coin,
            b"Invalid Arrays".to_string(),
            b"Array length mismatch".to_string(),
            vector[
                b"Reject mint and transfer proposal".to_string(),
                b"Approve minting and distribution".to_string()
            ],
            vector[b"Reject".to_string(), b"Accept".to_string()],
            vector[1_000_000_000, 1_000_000_000, 1_000_000_000, 1_000_000_000], // Initial amounts
            1_000_000,
            recipients,
            amounts,
            descriptions,
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
fun test_capability_deposit_with_no_limits() {
    let mut scenario = test::begin(ADMIN);
    let (_factory_owner_cap_id, _validator_cap_id) = setup_dao_with_registry(&mut scenario);

    // Create capability deposit proposal with no limits
    next_tx(&mut scenario, USER1);
    {
        let mut dao = test::take_shared<DAO>(&scenario);
        let mut fee_manager = test::take_shared<FeeManager>(&scenario);
        let mut registry = test::take_shared<ActionRegistry>(&scenario);
        let clock = test::take_shared<Clock>(&scenario);
        
        let payment = coin::mint_for_testing<sui::sui::SUI>(2_000, ctx(&mut scenario)); // 2 outcomes * 1000 per outcome
        let dao_fee_payment = coin::mint_for_testing<TestStableCoin>(0, scenario.ctx()); // No DAO fee
        let asset_coin = coin::mint_for_testing<TestAssetCoin>(INITIAL_ASSET, ctx(&mut scenario));
        let stable_coin = coin::mint_for_testing<TestStableCoin>(INITIAL_STABLE, ctx(&mut scenario));
        
        transfer_proposals::create_capability_deposit_proposal<TestAssetCoin, TestStableCoin, TestAssetCoin>(
            &mut dao,
            &mut fee_manager,
            &mut registry,
            payment,
            dao_fee_payment,
            asset_coin,
            stable_coin,
            b"Accept Unlimited TreasuryCap".to_string(),
            b"No limits on minting".to_string(),
            vector[
                b"Reject treasury capability deposit".to_string(),
                b"Accept treasury capability deposit".to_string()
            ],
            vector[b"Reject".to_string(), b"Accept".to_string()],
            vector[1_000_000_000, 1_000_000_000, 1_000_000_000, 1_000_000_000], // Initial amounts
            option::none(), // No max supply
            option::none(), // No per-proposal limit
            0, // No cooldown
            &clock,
            ctx(&mut scenario)
        );
        
        // Verify proposal was created
        let (active, total, _) = dao::get_stats(&dao);
        assert_eq(total, 1);
        
        test::return_shared(dao);
        test::return_shared(fee_manager);
        test::return_shared(registry);
        test::return_shared(clock);
    };
    
    test::end(scenario);
}