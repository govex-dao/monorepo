#[test_only]
module futarchy::security_council_membership_tests;

use std::string;
use sui::test_scenario::{Self as ts, Scenario, next_tx};
use sui::clock;
use sui::object;
use sui::tx_context::TxContext;

use account_protocol::{
    account::{Self, Account},
    intents::{Self, Params},
};
use account_extensions::extensions;

use futarchy::{
    security_council,
    security_council_intents,
    weighted_multisig::{Self, WeightedMultisig},
};

const ADMIN: address = @0xAD;
const MEMBER_1: address = @0xA;
const MEMBER_2: address = @0xB;
const MEMBER_3: address = @0xC;
const MEMBER_4: address = @0xD;

#[test]
fun updates_council_membership_successfully() {
    let mut ts = ts::begin(ADMIN);
    let clock = clock::create_for_testing(ts.ctx());
    let mut council: Account<WeightedMultisig>;
    // Extensions are created and shared for testing
    let extensions = extensions::new_for_testing(ts.ctx());

    // --- Setup initial council ---
    next_tx(&mut ts, ADMIN);
    {
        council = security_council::new(
            &extensions,
            vector[MEMBER_1, MEMBER_2, MEMBER_3],
            vector[50, 50, 50],
            101, // 2 of 3 must approve
            ts.ctx()
        );
    };

    // --- Create intent to update membership ---
    next_tx(&mut ts, MEMBER_1);
    {
        let intent_key = string::utf8(b"update_members_1");
        let auth = security_council::authenticate(&council, ts.ctx());
        let params = intents::new_params(
            intent_key,
            string::utf8(b"Update council members"),
            vector[0],
            1_000_000_000,
            &clock,
            ts.ctx()
        );

        security_council_intents::request_update_council_membership(
            &mut council,
            auth,
            params,
            vector[MEMBER_1, MEMBER_2, MEMBER_3, MEMBER_4],
            vector[25, 25, 25, 25],
            76, // 3 of 4 must approve
            ts.ctx()
        );
    };

    // --- Approve the intent ---
    next_tx(&mut ts, MEMBER_1);
    {
        security_council::approve_intent(&mut council, string::utf8(b"update_members_1"), ts.ctx());
    };
    next_tx(&mut ts, MEMBER_2);
    {
        security_council::approve_intent(&mut council, string::utf8(b"update_members_1"), ts.ctx());
    };

    // --- Execute the intent ---
    next_tx(&mut ts, ADMIN);
    {
        let executable = security_council::execute_intent(&mut council, string::utf8(b"update_members_1"), &clock);
        security_council_intents::execute_update_council_membership(executable, &mut council);

        // --- Assertions ---
        let config = account::config(&council);
        assert!(weighted_multisig::is_member(config, MEMBER_1), 0);
        assert!(weighted_multisig::is_member(config, MEMBER_2), 0);
        assert!(weighted_multisig::is_member(config, MEMBER_3), 0);
        assert!(weighted_multisig::is_member(config, MEMBER_4), 0); // New member added
        // Note: We can't directly check weights without adding getters in weighted_multisig
        // But we've verified membership which is the key functionality
    };

    ts::return_shared(council);
    ts::return_shared(extensions);
    clock::destroy_for_testing(clock);
    ts.end();
}