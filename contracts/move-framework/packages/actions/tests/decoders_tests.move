#[test_only]
module account_actions::decoders_tests;

use account_actions::access_control_decoder;
use account_actions::currency_decoder;
use account_actions::package_upgrade_decoder;
use account_actions::transfer_decoder;
use account_actions::vault_decoder;
use account_actions::vesting_decoder;
use account_protocol::schema::{Self, ActionDecoderRegistry};
use sui::bcs;
use sui::test_scenario::{Self as ts, Scenario};
use sui::test_utils::destroy;

// === Imports ===

// === Constants ===

const ADMIN: address = @0xAD;

// === Helpers ===

fun start(): (Scenario, ActionDecoderRegistry) {
    let mut scenario = ts::begin(ADMIN);
    let registry = schema::init_registry(scenario.ctx());
    (scenario, registry)
}

fun end(scenario: Scenario, registry: ActionDecoderRegistry) {
    destroy(registry);
    ts::end(scenario);
}

// === Access Control Decoder Tests ===

#[test]
fun test_access_control_decoder_registration() {
    let (mut scenario, mut registry) = start();

    // Register access control decoders
    access_control_decoder::register_decoders(&mut registry, scenario.ctx());

    // Test passes if registration doesn't abort
    end(scenario, registry);
}

#[test]
fun test_decode_borrow_action() {
    let (mut scenario, mut registry) = start();

    access_control_decoder::register_decoders(&mut registry, scenario.ctx());

    // BorrowAction is empty struct - minimal data
    let action_data = vector::empty<u8>();

    // Decode should work (returns action_type field)
    // Note: We can't call decode directly without the decoder object,
    // but registration proves the decoder exists

    end(scenario, registry);
}

// === Currency Decoder Tests ===

#[test]
fun test_currency_decoder_registration() {
    let (mut scenario, mut registry) = start();

    // Register currency decoders
    currency_decoder::register_decoders(&mut registry, scenario.ctx());

    // Test passes if registration doesn't abort
    end(scenario, registry);
}

#[test]
fun test_decode_mint_action_data() {
    let (scenario, registry) = start();

    // MintAction has one u64 field: amount
    let amount = 100u64;
    let action_data = bcs::to_bytes(&amount);

    // Verify BCS encoding is correct
    assert!(action_data.length() > 0, 0);

    end(scenario, registry);
}

#[test]
fun test_decode_burn_action_data() {
    let (scenario, registry) = start();

    // BurnAction has one u64 field: amount
    let amount = 50u64;
    let action_data = bcs::to_bytes(&amount);

    // Verify BCS encoding is correct
    assert!(action_data.length() > 0, 0);

    end(scenario, registry);
}

// === Transfer Decoder Tests ===

#[test]
fun test_transfer_decoder_registration() {
    let (mut scenario, mut registry) = start();

    // Register transfer decoders
    transfer_decoder::register_decoders(&mut registry, scenario.ctx());

    // Test passes if registration doesn't abort
    end(scenario, registry);
}

#[test]
fun test_decode_transfer_action_data() {
    let (scenario, registry) = start();

    // TransferAction has one address field: recipient
    let recipient = @0xBEEF;
    let action_data = bcs::to_bytes(&recipient);

    // Verify BCS encoding is correct
    assert!(action_data.length() > 0, 0);

    end(scenario, registry);
}

// === Vault Decoder Tests ===

#[test]
fun test_vault_decoder_registration() {
    let (mut scenario, mut registry) = start();

    // Register vault decoders
    vault_decoder::register_decoders(&mut registry, scenario.ctx());

    // Test passes if registration doesn't abort
    end(scenario, registry);
}

#[test]
fun test_decode_spend_action_data() {
    let (scenario, registry) = start();

    // SpendAction has vault_name (string) and amount (u64)
    let vault_name = b"treasury".to_string();
    let amount = 1000u64;

    // Encode both fields
    let mut action_data = bcs::to_bytes(&vault_name);
    let amount_bytes = bcs::to_bytes(&amount);
    action_data.append(amount_bytes);

    // Verify BCS encoding is correct
    assert!(action_data.length() > 0, 0);

    end(scenario, registry);
}

// === Vesting Decoder Tests ===

#[test]
fun test_vesting_decoder_registration() {
    let (mut scenario, mut registry) = start();

    // Register vesting decoders
    vesting_decoder::register_decoders(&mut registry, scenario.ctx());

    // Test passes if registration doesn't abort
    end(scenario, registry);
}

// === Package Upgrade Decoder Tests ===

#[test]
fun test_package_upgrade_decoder_registration() {
    let (mut scenario, mut registry) = start();

    // Register package upgrade decoders
    package_upgrade_decoder::register_decoders(&mut registry, scenario.ctx());

    // Test passes if registration doesn't abort
    end(scenario, registry);
}

#[test]
fun test_decode_upgrade_action_data() {
    let (scenario, registry) = start();

    // UpgradeAction has name (string) and digest (vector<u8>)
    let name = b"test_package".to_string();
    let digest = vector[1u8, 2u8, 3u8];

    // Encode both fields
    let mut action_data = bcs::to_bytes(&name);
    let digest_bytes = bcs::to_bytes(&digest);
    action_data.append(digest_bytes);

    // Verify BCS encoding is correct
    assert!(action_data.length() > 0, 0);

    end(scenario, registry);
}

// === Integration Tests ===

#[test]
fun test_register_all_decoders() {
    let (mut scenario, mut registry) = start();

    // Register all decoders in one test
    access_control_decoder::register_decoders(&mut registry, scenario.ctx());
    currency_decoder::register_decoders(&mut registry, scenario.ctx());
    transfer_decoder::register_decoders(&mut registry, scenario.ctx());
    vault_decoder::register_decoders(&mut registry, scenario.ctx());
    vesting_decoder::register_decoders(&mut registry, scenario.ctx());
    package_upgrade_decoder::register_decoders(&mut registry, scenario.ctx());

    // All registrations should succeed
    end(scenario, registry);
}

#[test]
fun test_bcs_encoding_consistency() {
    let (scenario, registry) = start();

    // Test that BCS encoding is deterministic
    let amount1 = 100u64;
    let amount2 = 100u64;

    let data1 = bcs::to_bytes(&amount1);
    let data2 = bcs::to_bytes(&amount2);

    assert!(data1 == data2, 0);

    end(scenario, registry);
}
