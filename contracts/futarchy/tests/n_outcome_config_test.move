// REMOVED: This entire test module used create_multi_outcome_config_proposal which was an incomplete
// stub that created proposals without registering any config actions. The function has been removed
// to prevent misuse. Developers should create custom multi-outcome config proposals by properly
// registering actions for each outcome using the config_actions module directly.
/*
#[test_only]
module futarchy::n_outcome_config_test;

use futarchy::{
    dao::{Self, DAO},
    config_proposals,
    fee,
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

#[test]
fun test_three_outcome_config_proposal() {
    let mut scenario = test::begin(ADMIN);
    
    // Setup
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(1_000_000);
    
    // Create DAO
    let mut dao = dao::create<SUI, SUI>(
        10_000_000_000,
        10_000_000_000,
        b"Multi-Config DAO".to_ascii_string(),
        b"https://test.com/icon.png".to_ascii_string(),
        3600000, // 1 hour review
        86400000, // 24 hour trading
        60000,
        10,
        1000000000000000000,
        100,
        b"Testing multi-outcome config proposals".to_string(),
        3, // Allow 3 outcomes
        vector[],
        &clock,
        scenario.ctx(),
    );
    
    transfer::public_share_object(dao);
    fee::create_fee_manager_for_testing(scenario.ctx());
    
    // Create a 3-outcome config proposal
    scenario.next_tx(ALICE);
    {
        let mut dao = scenario.take_shared<DAO>();
        let mut fee_manager = scenario.take_shared<fee::FeeManager>();
        
        let payment = coin::mint_for_testing<SUI>(3_000, scenario.ctx()); // 3 outcomes * 1000 per outcome
        let asset_coin = coin::mint_for_testing<SUI>(100_000_000_000, scenario.ctx());
        let stable_coin = coin::mint_for_testing<SUI>(100_000_000_000, scenario.ctx());
        
        // Create multi-outcome config proposal
        config_proposals::create_multi_outcome_config_proposal<SUI, SUI>(
            &mut dao,
            &mut fee_manager,
            payment,
            asset_coin,
            stable_coin,
            b"Choose Trading Period Configuration".to_string(),
            b"Select the best trading period duration for our DAO".to_string(),
            vector[
                b"Conservative: Keep current settings (24h trading, 1h review)".to_string(),
                b"Moderate: 48h trading, 2h review - more time for price discovery".to_string(),
                b"Extended: 72h trading, 3h review - maximum deliberation time".to_string(),
            ],
            vector[
                b"Conservative".to_string(),
                b"Moderate".to_string(),
                b"Extended".to_string(),
            ],
            vector[
                100_000_000_000, 100_000_000_000, 100_000_000_000,
                100_000_000_000, 100_000_000_000, 100_000_000_000,
            ],
            // Config changes - only apply for non-conservative options
            option::none(), // min_asset_amount
            option::none(), // min_stable_amount
            option::some(7200000), // review_period_ms: 2h for moderate, will be overridden for extended
            option::some(172800000), // trading_period_ms: 48h for moderate, will be overridden for extended
            option::none(), // twap_start_delay
            option::none(), // twap_threshold
            option::none(), // dao_name
            option::none(), // icon_url
            option::none(), // description
            option::none(), // proposal_creation_enabled
            option::none(), // max_outcomes
            &clock,
            scenario.ctx(),
        );
        
        test::return_shared(dao);
        test::return_shared(fee_manager);
    };
    
    clock.destroy_for_testing();
    scenario.end();
}

#[test]
fun test_governance_ranking_proposal() {
    let mut scenario = test::begin(ADMIN);
    
    let mut clock = clock::create_for_testing(scenario.ctx());
    
    // Create DAO
    let mut dao = dao::create<SUI, SUI>(
        10_000_000_000,
        10_000_000_000,
        b"Governance DAO".to_ascii_string(),
        b"https://test.com/icon.png".to_ascii_string(),
        3600000,
        86400000,
        60000,
        10,
        1000000000000000000,
        100,
        b"Testing governance config".to_string(),
        4, // Allow 4 outcomes
        vector[],
        &clock,
        scenario.ctx(),
    );
    
    transfer::public_share_object(dao);
    fee::create_fee_manager_for_testing(scenario.ctx());
    
    // Create a 4-outcome governance settings proposal
    scenario.next_tx(ALICE);
    {
        let mut dao = scenario.take_shared<DAO>();
        let mut fee_manager = scenario.take_shared<fee::FeeManager>();
        
        let payment = coin::mint_for_testing<SUI>(4_000, scenario.ctx()); // 4 outcomes * 1000 per outcome
        let asset_coin = coin::mint_for_testing<SUI>(100_000_000_000, scenario.ctx());
        let stable_coin = coin::mint_for_testing<SUI>(100_000_000_000, scenario.ctx());
        
        // Create governance configuration proposal with different complexity levels
        config_proposals::create_multi_outcome_config_proposal<SUI, SUI>(
            &mut dao,
            &mut fee_manager,
            payment,
            asset_coin,
            stable_coin,
            b"Select Governance Complexity Level".to_string(),
            b"Choose how many outcomes future proposals should support".to_string(),
            vector[
                b"Simple: Binary proposals only (2 outcomes)".to_string(),
                b"Standard: Up to 3 outcomes for basic ranking".to_string(),
                b"Advanced: Up to 5 outcomes for complex decisions".to_string(),
                b"Maximum: Up to 10 outcomes for detailed choices".to_string(),
            ],
            vector[
                b"Simple".to_string(),
                b"Standard".to_string(),
                b"Advanced".to_string(),
                b"Maximum".to_string(),
            ],
            vector[
                100_000_000_000, 100_000_000_000, 100_000_000_000, 100_000_000_000,
                100_000_000_000, 100_000_000_000, 100_000_000_000, 100_000_000_000,
            ],
            // Config changes based on outcome
            option::none(), // min_asset_amount
            option::none(), // min_stable_amount
            option::none(), // review_period_ms
            option::none(), // trading_period_ms
            option::none(), // twap_start_delay
            option::none(), // twap_threshold
            option::none(), // dao_name
            option::none(), // icon_url
            option::none(), // description
            option::none(), // proposal_creation_enabled
            option::some(3), // Default to standard (3 outcomes), will be overridden based on winning option
            &clock,
            scenario.ctx(),
        );
        
        test::return_shared(dao);
        test::return_shared(fee_manager);
    };
    
    clock.destroy_for_testing();
    scenario.end();
}

#[test]
fun test_memo_proposal_n_outcomes() {
    let mut scenario = test::begin(ADMIN);
    
    let mut clock = clock::create_for_testing(scenario.ctx());
    
    // Create DAO
    let mut dao = dao::create<SUI, SUI>(
        10_000_000_000,
        10_000_000_000,
        b"Community DAO".to_ascii_string(),
        b"https://test.com/icon.png".to_ascii_string(),
        3600000,
        86400000,
        60000,
        10,
        1000000000000000000,
        100,
        b"Testing memo proposals with multiple outcomes".to_string(),
        6, // Allow up to 6 outcomes
        vector[],
        &clock,
        scenario.ctx(),
    );
    
    transfer::public_share_object(dao);
    fee::create_fee_manager_for_testing(scenario.ctx());
    
    // Create a 5-outcome memo proposal (no treasury or config actions)
    scenario.next_tx(ALICE);
    {
        let mut dao = scenario.take_shared<DAO>();
        let mut fee_manager = scenario.take_shared<fee::FeeManager>();
        
        let payment = coin::mint_for_testing<SUI>(5_000, scenario.ctx()); // 5 outcomes * 1000 per outcome
        let asset_coin = coin::mint_for_testing<SUI>(100_000_000_000, scenario.ctx());
        let stable_coin = coin::mint_for_testing<SUI>(100_000_000_000, scenario.ctx());
        
        // Create memo proposal for community decision
        let dao_fee_payment = coin::mint_for_testing<SUI>(0, scenario.ctx()); // No DAO fee
        dao::create_proposal<SUI, SUI>(
            &mut dao,
            &mut fee_manager,
            payment,
            dao_fee_payment,
            5, // 5 outcomes
            asset_coin,
            stable_coin,
            b"Choose Community Event Theme".to_string(),
            vector[
                b"DeFi Workshop: Focus on decentralized finance education".to_string(),
                b"NFT Gallery: Showcase community digital art".to_string(),
                b"Developer Hackathon: 48-hour coding competition".to_string(),
                b"DAO Governance Summit: Best practices and case studies".to_string(),
                b"Social Mixer: Casual networking and community building".to_string(),
            ],
            b"Vote on the theme for our next quarterly community event".to_string(),
            vector[
                b"DeFi".to_string(),
                b"NFT".to_string(),
                b"Hackathon".to_string(),
                b"Governance".to_string(),
                b"Social".to_string(),
            ],
            vector[
                100_000_000_000, 100_000_000_000, 100_000_000_000, 100_000_000_000, 100_000_000_000,
                100_000_000_000, 100_000_000_000, 100_000_000_000, 100_000_000_000, 100_000_000_000,
            ],
            &clock,
            scenario.ctx(),
        );
        
        test::return_shared(dao);
        test::return_shared(fee_manager);
    };
    
    clock.destroy_for_testing();
    scenario.end();
}*/
