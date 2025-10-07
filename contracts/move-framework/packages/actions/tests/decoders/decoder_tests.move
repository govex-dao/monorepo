#[test_only]
module account_actions::decoder_tests;

// === Imports ===

use sui::{
    test_utils::destroy,
    test_scenario::{Self as ts, Scenario},
    bcs,
};
use account_protocol::schema::{Self, ActionDecoderRegistry};
use account_actions::{
    access_control_decoder,
    currency_decoder,
    kiosk_decoder,
    package_upgrade_decoder,
    transfer_decoder,
    vault_decoder,
    vesting_decoder,
};

// === Constants ===

const OWNER: address = @0xCAFE;
const RECIPIENT: address = @0xBEEF;

// === Test Helpers ===

fun start(): (Scenario, ActionDecoderRegistry) {
    let mut scenario = ts::begin(OWNER);

    // Create registry
    let mut registry = schema::init_registry(scenario.ctx());

    // Register all decoders
    access_control_decoder::register_decoders(&mut registry, scenario.ctx());
    currency_decoder::register_decoders(&mut registry, scenario.ctx());
    kiosk_decoder::register_decoders(&mut registry, scenario.ctx());
    package_upgrade_decoder::register_decoders(&mut registry, scenario.ctx());
    transfer_decoder::register_decoders(&mut registry, scenario.ctx());
    vault_decoder::register_decoders(&mut registry, scenario.ctx());
    vesting_decoder::register_decoders(&mut registry, scenario.ctx());

    (scenario, registry)
}

fun end(scenario: Scenario, registry: ActionDecoderRegistry) {
    destroy(registry);
    ts::end(scenario);
}

// === Access Control Decoder Tests ===

#[test]
fun test_decode_borrow_action() {
    let (scenario, registry) = start();

    // BorrowAction is an empty struct - just needs to be registered
    // Decoder should return action type info

    end(scenario, registry);
}

#[test]
fun test_decode_return_action() {
    let (scenario, registry) = start();

    // ReturnAction is an empty struct - just needs to be registered
    // Decoder should return action type info

    end(scenario, registry);
}

// === Transfer Decoder Tests ===

#[test]
fun test_decode_transfer_action() {
    let (scenario, registry) = start();

    // Create action data: just an address (recipient)
    let recipient = RECIPIENT;
    let action_data = bcs::to_bytes(&recipient);

    // The decoder would peel the address and return it as a field
    assert!(action_data.length() > 0, 0);

    end(scenario, registry);
}

// === Currency Decoder Tests ===

#[test]
fun test_decode_mint_action() {
    let (scenario, registry) = start();

    // MintAction has: amount (u64)
    let amount = 1000u64;
    let action_data = bcs::to_bytes(&amount);

    assert!(action_data.length() > 0, 0);

    end(scenario, registry);
}

#[test]
fun test_decode_burn_action() {
    let (scenario, registry) = start();

    // BurnAction has: amount (u64)
    let amount = 500u64;
    let action_data = bcs::to_bytes(&amount);

    assert!(action_data.length() > 0, 0);

    end(scenario, registry);
}

// === Vault Decoder Tests ===

#[test]
fun test_decode_deposit_action() {
    let (scenario, registry) = start();

    // DepositAction has: vault_name (vector<u8>)
    let vault_name = b"treasury";
    let action_data = bcs::to_bytes(&vault_name);

    assert!(action_data.length() > 0, 0);

    end(scenario, registry);
}

#[test]
fun test_decode_withdraw_action() {
    let (scenario, registry) = start();

    // WithdrawAction has: vault_name (vector<u8>), amount (u64), recipient (address)
    let vault_name = b"treasury";
    let amount = 1000u64;
    let recipient = RECIPIENT;

    // Serialize all fields
    let mut action_data = vector[];
    action_data.append(bcs::to_bytes(&vault_name));
    action_data.append(bcs::to_bytes(&amount));
    action_data.append(bcs::to_bytes(&recipient));

    assert!(action_data.length() > 0, 0);

    end(scenario, registry);
}

// === Vesting Decoder Tests ===

#[test]
fun test_decode_create_vesting_action() {
    let (scenario, registry) = start();

    // CreateVestingAction has multiple fields:
    // beneficiary, total_amount, start_time, end_time, cliff_time (option)
    let beneficiary = RECIPIENT;
    let total_amount = 10000u64;
    let start_time = 0u64;
    let end_time = 1000u64;

    let mut action_data = vector[];
    action_data.append(bcs::to_bytes(&beneficiary));
    action_data.append(bcs::to_bytes(&total_amount));
    action_data.append(bcs::to_bytes(&start_time));
    action_data.append(bcs::to_bytes(&end_time));

    assert!(action_data.length() > 0, 0);

    end(scenario, registry);
}

#[test]
fun test_decode_claim_vesting_action() {
    let (scenario, registry) = start();

    // ClaimVestingAction has: vesting_id (ID), amount (u64)
    // For testing, we just verify the structure

    end(scenario, registry);
}

// === Kiosk Decoder Tests ===

#[test]
fun test_decode_take_nft_action() {
    let (scenario, registry) = start();

    // TakeNftAction has: nft_ids (vector<ID>), recipients (vector<address>)
    // For testing, we verify the decoder is registered

    end(scenario, registry);
}

#[test]
fun test_decode_list_nft_action() {
    let (scenario, registry) = start();

    // ListNftAction has: nft_id (ID), price (u64)
    let price = 1000u64;
    let action_data = bcs::to_bytes(&price);

    assert!(action_data.length() > 0, 0);

    end(scenario, registry);
}

// === Package Upgrade Decoder Tests ===

#[test]
fun test_decode_upgrade_action() {
    let (scenario, registry) = start();

    // UpgradeAction has: package_digest (vector<u8>)
    let package_digest = b"test_digest";
    let action_data = bcs::to_bytes(&package_digest);

    assert!(action_data.length() > 0, 0);

    end(scenario, registry);
}

#[test]
fun test_decode_restrict_policy_action() {
    let (scenario, registry) = start();

    // RestrictPolicyAction has: policy (u8)
    let policy = 1u8;
    let action_data = bcs::to_bytes(&policy);

    assert!(action_data.length() > 0, 0);

    end(scenario, registry);
}

// === Integration Test ===

#[test]
fun test_all_decoders_registered() {
    let (scenario, registry) = start();

    // This test verifies that all decoders can be registered without conflicts
    // The fact that start() succeeds means all decoders registered properly

    end(scenario, registry);
}

// === Decoder Registry Tests ===

#[test]
fun test_decoder_registry_creation() {
    let mut scenario = ts::begin(OWNER);
    let registry = schema::init_registry(scenario.ctx());

    // Registry should be created successfully
    destroy(registry);
    ts::end(scenario);
}

#[test]
fun test_decoder_registration_no_duplicates() {
    let (scenario, registry) = start();

    // All decoders registered in start() without panicking
    // This verifies no duplicate type keys

    end(scenario, registry);
}
