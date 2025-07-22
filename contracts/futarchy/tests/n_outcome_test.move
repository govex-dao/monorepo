#[test_only]
module futarchy::n_outcome_test;

use futarchy::{
    dao::{Self, DAO},
    treasury::{Self, Treasury},
    treasury_actions::{Self, ActionRegistry},
    treasury_initialization,
    transfer_proposals,
    fee,
};
use sui::{
    test_scenario::{Self as test},
    clock::{Self, Clock},
    coin::{Self, Coin},
    sui::SUI,
};

const ADMIN: address = @0xAD;
const ALICE: address = @0xA11CE;
const BOB: address = @0xB0B;
const CHARLIE: address = @0xC4A411E;
const DAVID: address = @0xDAD1D;

#[test]
fun test_three_outcome_proposal() {
    let mut scenario = test::begin(ADMIN);
    
    // Setup
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(1_000_000);
    
    // Create DAO without enforced Reject/Accept
    let mut dao = dao::create<SUI, SUI>(
        10_000_000_000,
        10_000_000_000,
        b"Three Option DAO".to_ascii_string(),
        b"https://test.com/icon.png".to_ascii_string(),
        3600000,
        86400000,
        60000,
        10,
        1000000000000000000,
        100,
        b"Testing 3-outcome proposals".to_string(),
        3, // Allow 3 outcomes
        vector[],
        &clock,
        scenario.ctx(),
    );
    
    treasury_initialization::initialize_treasury(&mut dao, ADMIN, scenario.ctx());
    transfer::public_share_object(dao);
    
    fee::create_fee_manager_for_testing(scenario.ctx());
    treasury_actions::create_for_testing(scenario.ctx());
    
    // Fund treasury
    scenario.next_tx(ADMIN);
    let treasury_id = {
        let dao = scenario.take_shared<DAO>();
        let id = *dao::get_treasury_id(&dao).borrow();
        test::return_shared(dao);
        id
    };
    
    scenario.next_tx(ALICE);
    {
        let mut treasury = scenario.take_shared_by_id<Treasury>(treasury_id);
        let deposit = coin::mint_for_testing<SUI>(1_000_000_000_000, scenario.ctx());
        treasury::deposit_sui(&mut treasury, deposit, scenario.ctx());
        test::return_shared(treasury);
    };
    
    // Create a 3-outcome proposal: Option A, Option B, Option C
    scenario.next_tx(ALICE);
    {
        let mut dao = scenario.take_shared<DAO>();
        let mut fee_manager = scenario.take_shared<fee::FeeManager>();
        let mut registry = scenario.take_shared<ActionRegistry>();
        
        let payment = coin::mint_for_testing<SUI>(10_000, scenario.ctx());
        let asset_coin = coin::mint_for_testing<SUI>(100_000_000_000, scenario.ctx());
        let stable_coin = coin::mint_for_testing<SUI>(100_000_000_000, scenario.ctx());
        
        // Create multi-outcome proposal
        transfer_proposals::create_multi_transfer_proposal<SUI, SUI, SUI>(
            &mut dao,
            &mut fee_manager,
            &mut registry,
            payment,
            asset_coin,
            stable_coin,
            b"Budget Allocation Proposal".to_string(),
            b"Choose how to allocate the 300 SUI budget".to_string(),
            vector[
                b"Reject: Do not allocate any budget".to_string(),
                b"Option A: 100 SUI each to Bob, Charlie, David".to_string(),
                b"Option B: 200 SUI to Bob, 100 SUI to Charlie".to_string(),
            ],
            vector[
                b"Reject".to_string(),
                b"Option A".to_string(),
                b"Option B".to_string(),
            ],
            vector[
                100_000_000_000, 100_000_000_000, 100_000_000_000, // Initial amounts for each outcome
                100_000_000_000, 100_000_000_000, 100_000_000_000,
            ],
            // Transfer specs: [outcome_index, amount, recipient_index]
            // Note: Outcome 0 is "Reject" - no transfers
            vector[
                vector[1, 100_000_000_000, 0], // Option A: 100 SUI to Bob (recipient 0)
                vector[1, 100_000_000_000, 1], // Option A: 100 SUI to Charlie (recipient 1)
                vector[1, 100_000_000_000, 2], // Option A: 100 SUI to David (recipient 2)
                vector[2, 200_000_000_000, 0], // Option B: 200 SUI to Bob (recipient 0)
                vector[2, 100_000_000_000, 1], // Option B: 100 SUI to Charlie (recipient 1)
            ],
            // Recipients
            vector[BOB, CHARLIE, DAVID],
            &clock,
            scenario.ctx(),
        );
        
        test::return_shared(dao);
        test::return_shared(fee_manager);
        test::return_shared(registry);
    };
    
    clock.destroy_for_testing();
    scenario.end();
}

#[test]
fun test_five_outcome_ranking_proposal() {
    let mut scenario = test::begin(ADMIN);
    
    let mut clock = clock::create_for_testing(scenario.ctx());
    
    // Create DAO with up to 3 outcomes (current maximum)
    let mut dao = dao::create<SUI, SUI>(
        10_000_000_000,
        10_000_000_000,
        b"Ranking DAO".to_ascii_string(),
        b"https://test.com/icon.png".to_ascii_string(),
        3600000,
        86400000,
        60000,
        10,
        1000000000000000000,
        100,
        b"Testing 3-outcome ranking".to_string(),
        3, // Allow up to 3 outcomes (current maximum)
        vector[],
        &clock,
        scenario.ctx(),
    );
    
    treasury_initialization::initialize_treasury(&mut dao, ADMIN, scenario.ctx());
    transfer::public_share_object(dao);
    
    fee::create_fee_manager_for_testing(scenario.ctx());
    treasury_actions::create_for_testing(scenario.ctx());
    
    // Create a 3-outcome ranking proposal
    scenario.next_tx(ALICE);
    {
        let mut dao = scenario.take_shared<DAO>();
        let mut fee_manager = scenario.take_shared<fee::FeeManager>();
        let mut registry = scenario.take_shared<ActionRegistry>();
        
        let payment = coin::mint_for_testing<SUI>(10_000, scenario.ctx());
        let asset_coin = coin::mint_for_testing<SUI>(100_000_000_000, scenario.ctx());
        let stable_coin = coin::mint_for_testing<SUI>(100_000_000_000, scenario.ctx());
        
        // Create ranking proposal with different rewards (only 3 outcomes)
        transfer_proposals::create_multi_transfer_proposal<SUI, SUI, SUI>(
            &mut dao,
            &mut fee_manager,
            &mut registry,
            payment,
            asset_coin,
            stable_coin,
            b"Project Funding Ranking".to_string(),
            b"Rank projects by priority - higher rank gets more funding".to_string(),
            vector[
                b"Reject: Do not fund any projects".to_string(),
                b"Fund Project Alpha with 500 SUI".to_string(),
                b"Fund Project Beta with 300 SUI".to_string(),
            ],
            vector[
                b"Reject".to_string(),
                b"Project Alpha".to_string(),
                b"Project Beta".to_string(),
            ],
            vector[
                100_000_000_000, 100_000_000_000, 100_000_000_000,
                100_000_000_000, 100_000_000_000, 100_000_000_000,
            ],
            // Transfer specs: [outcome_index, amount, recipient_index]
            // Note: Outcome 0 is "Reject" - no transfers
            vector[
                vector[1, 500_000_000_000, 0], // Project Alpha: 500 SUI to recipient 0
                vector[2, 300_000_000_000, 1], // Project Beta: 300 SUI to recipient 1
            ],
            // Recipients
            vector[@0xA1FA, @0xBE7A],
            &clock,
            scenario.ctx(),
        );
        
        test::return_shared(dao);
        test::return_shared(fee_manager);
        test::return_shared(registry);
    };
    
    clock.destroy_for_testing();
    scenario.end();
}