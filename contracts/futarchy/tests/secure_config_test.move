#[test_only]
module futarchy::secure_config_test;

use futarchy::{
    dao::{Self, DAO},
    config_proposals,
    config_actions::{Self, ConfigActionRegistry},
    fee,
    proposal::{Self, Proposal},
    coin_escrow::{Self, TokenEscrow},
    market_state,
};
use sui::{
    test_scenario::{Self as test},
    clock::{Self, Clock},
    coin::{Self, Coin},
    sui::SUI,
};
use std::ascii;

const ADMIN: address = @0xAD;
const ALICE: address = @0xA11CE;
const ATTACKER: address = @0xBAD;

#[test]
fun test_config_proposal_workflow() {
    let mut scenario = test::begin(ADMIN);
    
    let mut clock = clock::create_for_testing(scenario.ctx());
    
    // Create DAO
    let mut dao = dao::create<SUI, SUI>(
        10_000_000_000,
        10_000_000_000,
        b"Test DAO".to_ascii_string(),
        b"https://test.com/icon.png".to_ascii_string(),
        3600000,
        86400000,
        60000,
        10,
        1000000000000000000,
        100,
        b"Testing config workflow".to_string(),
        3,
        vector[],
        &clock,
        scenario.ctx(),
    );
    
    transfer::public_share_object(dao);
    fee::create_fee_manager_for_testing(scenario.ctx());
    config_actions::create_registry_for_testing(scenario.ctx());
    
    // Create a metadata update proposal
    scenario.next_tx(ALICE);
    {
        let mut dao = scenario.take_shared<DAO>();
        let mut fee_manager = scenario.take_shared<fee::FeeManager>();
        let mut config_registry = scenario.take_shared<ConfigActionRegistry>();
        
        let payment = coin::mint_for_testing<SUI>(10_000, scenario.ctx());
        let asset_coin = coin::mint_for_testing<SUI>(100_000_000_000, scenario.ctx());
        let stable_coin = coin::mint_for_testing<SUI>(100_000_000_000, scenario.ctx());
        
        config_proposals::create_metadata_proposal<SUI, SUI>(
            &mut dao,
            &mut fee_manager,
            &mut config_registry,
            payment,
            asset_coin,
            stable_coin,
            b"Update DAO name and description".to_string(),
            b"Change name to 'Awesome DAO' and update description".to_string(),
            vector[100_000_000_000, 100_000_000_000, 100_000_000_000, 100_000_000_000],
            b"Awesome DAO".to_ascii_string(),
            b"".to_ascii_string(), // No icon change
            b"This is an awesome DAO with secure config updates".to_string(),
            &clock,
            scenario.ctx(),
        );
        
        test::return_shared(dao);
        test::return_shared(fee_manager);
        test::return_shared(config_registry);
    };
    
    clock.destroy_for_testing();
    scenario.end();
}