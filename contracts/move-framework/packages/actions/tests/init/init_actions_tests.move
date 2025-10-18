#[test_only]
module account_actions::init_actions_tests;

use account_actions::currency;
use account_actions::init_actions;
use account_actions::vault;
use account_actions::version;
use account_extensions::extensions::{Self, Extensions, AdminCap};
use account_protocol::account::{Self, Account};
use account_protocol::deps;
use sui::clock::{Self, Clock};
use sui::coin::{Self, Coin};
use sui::object::{Self, UID};
use sui::package;
use sui::sui::SUI;
use sui::test_scenario::{Self as ts, Scenario};
use sui::test_utils::destroy;

// === Imports ===

// === Constants ===

const OWNER: address = @0xCAFE;
const RECIPIENT: address = @0xBEEF;

// === Structs ===

public struct Witness() has drop;
public struct Config has copy, drop, store {}

// OTW for creating TreasuryCap
public struct INIT_ACTIONS_TESTS has drop {}

// Test object for transfer tests
public struct TestObject has key, store {
    id: UID,
    data: u64,
}

// Test capability for capability locking tests
public struct TestCap has key, store {
    id: UID,
    value: u64,
}

// === Helpers ===

fun start(): (Scenario, Extensions, Clock) {
    let mut scenario = ts::begin(OWNER);
    // publish package
    extensions::init_for_testing(scenario.ctx());
    // retrieve objects
    scenario.next_tx(OWNER);
    let mut extensions = scenario.take_shared<Extensions>();
    let cap = scenario.take_from_sender<AdminCap>();
    // add core deps
    extensions.add(&cap, b"AccountProtocol".to_string(), @account_protocol, 1);
    extensions.add(&cap, b"AccountActions".to_string(), @account_actions, 1);

    let clock = clock::create_for_testing(scenario.ctx());
    // create world
    destroy(cap);
    (scenario, extensions, clock)
}

fun end(scenario: Scenario, extensions: Extensions, clock: Clock) {
    destroy(extensions);
    destroy(clock);
    ts::end(scenario);
}

fun create_unshared_account(extensions: &Extensions, scenario: &mut Scenario): Account<Config> {
    let deps = deps::new_latest_extensions(
        extensions,
        vector[b"AccountProtocol".to_string(), b"AccountActions".to_string()],
    );
    account::new(Config {}, deps, version::current(), Witness(), scenario.ctx())
}

// === Vault Init Tests ===

#[test]
fun test_init_vault_deposit() {
    let (mut scenario, extensions, clock) = start();

    // Create unshared account
    let mut account = create_unshared_account(&extensions, &mut scenario);

    // Create coin
    let coin = coin::mint_for_testing<SUI>(1000, scenario.ctx());

    // Deposit during init
    init_actions::init_vault_deposit<Config, SUI>(
        &mut account,
        coin,
        b"treasury",
        scenario.ctx(),
    );

    // Verify vault was created
    assert!(vault::has_vault(&account, b"treasury".to_string()), 0);

    destroy(account);
    end(scenario, extensions, clock);
}

#[test]
fun test_init_vault_deposit_default() {
    let (mut scenario, extensions, clock) = start();

    let mut account = create_unshared_account(&extensions, &mut scenario);
    let coin = coin::mint_for_testing<SUI>(500, scenario.ctx());

    // Deposit with default vault name
    init_actions::init_vault_deposit_default<Config, SUI>(
        &mut account,
        coin,
        scenario.ctx(),
    );

    // Verify default vault exists
    assert!(vault::has_vault(&account, vault::default_vault_name()), 0);

    destroy(account);
    end(scenario, extensions, clock);
}

// === Currency Init Tests ===

#[test]
fun test_init_lock_treasury_cap() {
    let (mut scenario, extensions, clock) = start();

    let mut account = create_unshared_account(&extensions, &mut scenario);

    // Create treasury cap
    let treasury_cap = coin::create_treasury_cap_for_testing<INIT_ACTIONS_TESTS>(scenario.ctx());

    // Lock it during init
    init_actions::init_lock_treasury_cap<Config, INIT_ACTIONS_TESTS>(
        &mut account,
        treasury_cap,
    );

    // Verify cap is locked
    assert!(currency::has_cap<Config, INIT_ACTIONS_TESTS>(&account), 0);

    destroy(account);
    end(scenario, extensions, clock);
}

#[test]
fun test_init_mint() {
    let (mut scenario, extensions, clock) = start();

    let mut account = create_unshared_account(&extensions, &mut scenario);

    // Lock treasury cap first
    let treasury_cap = coin::create_treasury_cap_for_testing<INIT_ACTIONS_TESTS>(scenario.ctx());
    init_actions::init_lock_treasury_cap<Config, INIT_ACTIONS_TESTS>(
        &mut account,
        treasury_cap,
    );

    // Mint during init
    init_actions::init_mint<Config, INIT_ACTIONS_TESTS>(
        &mut account,
        500,
        RECIPIENT,
        scenario.ctx(),
    );

    // Verify mint occurred (coin would be transferred to RECIPIENT)
    scenario.next_tx(RECIPIENT);
    let coin = scenario.take_from_address<Coin<INIT_ACTIONS_TESTS>>(RECIPIENT);
    assert!(coin.value() == 500, 0);

    destroy(coin);
    destroy(account);
    end(scenario, extensions, clock);
}

#[test]
fun test_init_mint_and_deposit() {
    let (mut scenario, extensions, clock) = start();

    let mut account = create_unshared_account(&extensions, &mut scenario);

    // Lock treasury cap first
    let treasury_cap = coin::create_treasury_cap_for_testing<INIT_ACTIONS_TESTS>(scenario.ctx());
    init_actions::init_lock_treasury_cap<Config, INIT_ACTIONS_TESTS>(
        &mut account,
        treasury_cap,
    );

    // Mint and deposit in one step
    init_actions::init_mint_and_deposit<Config, INIT_ACTIONS_TESTS>(
        &mut account,
        1000,
        b"treasury",
        scenario.ctx(),
    );

    // Verify vault exists
    assert!(vault::has_vault(&account, b"treasury".to_string()), 0);

    destroy(account);
    end(scenario, extensions, clock);
}

// === Vesting Init Tests ===

#[test]
fun test_init_create_vesting() {
    let (mut scenario, extensions, mut clock) = start();

    let mut account = create_unshared_account(&extensions, &mut scenario);

    // Create coin for vesting
    let coin = coin::mint_for_testing<SUI>(5000, scenario.ctx());

    let start_time = clock.timestamp_ms();
    let duration_ms = 365 * 24 * 60 * 60 * 1000; // 1 year
    let cliff_ms = 90 * 24 * 60 * 60 * 1000; // 90 days

    // Create vesting during init
    let vesting_id = init_actions::init_create_vesting<Config, SUI>(
        &mut account,
        coin,
        RECIPIENT,
        start_time,
        duration_ms,
        cliff_ms,
        &clock,
        scenario.ctx(),
    );

    // Verify vesting was created (vesting ID returned)
    assert!(object::id_to_address(&vesting_id) != @0x0, 0);

    destroy(account);
    end(scenario, extensions, clock);
}

#[test]
fun test_init_create_founder_vesting() {
    let (mut scenario, extensions, mut clock) = start();

    let mut account = create_unshared_account(&extensions, &mut scenario);

    let coin = coin::mint_for_testing<SUI>(10000, scenario.ctx());
    let cliff_ms = 365 * 24 * 60 * 60 * 1000; // 1 year cliff

    // Create founder vesting (4-year standard)
    let vesting_id = init_actions::init_create_founder_vesting<Config, SUI>(
        &mut account,
        coin,
        RECIPIENT,
        cliff_ms,
        &clock,
        scenario.ctx(),
    );

    assert!(object::id_to_address(&vesting_id) != @0x0, 0);

    destroy(account);
    end(scenario, extensions, clock);
}

#[test]
fun test_init_create_team_vesting() {
    let (mut scenario, extensions, mut clock) = start();

    let mut account = create_unshared_account(&extensions, &mut scenario);

    let coin = coin::mint_for_testing<SUI>(3000, scenario.ctx());
    let duration_ms = 2 * 365 * 24 * 60 * 60 * 1000; // 2 years
    let cliff_ms = 180 * 24 * 60 * 60 * 1000; // 6 months

    // Create team vesting
    let vesting_id = init_actions::init_create_team_vesting<Config, SUI>(
        &mut account,
        coin,
        RECIPIENT,
        duration_ms,
        cliff_ms,
        &clock,
        scenario.ctx(),
    );

    assert!(object::id_to_address(&vesting_id) != @0x0, 0);

    destroy(account);
    end(scenario, extensions, clock);
}

// === Package Upgrade Init Tests ===

#[test]
fun test_init_lock_upgrade_cap() {
    let (mut scenario, extensions, clock) = start();

    let mut account = create_unshared_account(&extensions, &mut scenario);

    // Create upgrade cap
    let publisher = package::test_claim(INIT_ACTIONS_TESTS {}, scenario.ctx());
    let upgrade_cap = package::test_publish(object::id(&publisher), scenario.ctx());
    destroy(publisher);

    let delay_ms = 7 * 24 * 60 * 60 * 1000; // 7 days
    let reclaim_delay_ms = 15552000000; // 6 months

    // Lock upgrade cap during init
    init_actions::init_lock_upgrade_cap<Config>(
        &mut account,
        upgrade_cap,
        b"test_package",
        delay_ms,
        reclaim_delay_ms,
    );

    // Verify cap is locked
    assert!(account_actions::package_upgrade::has_cap(&account, b"test_package".to_string()), 0);
    assert!(
        account_actions::package_upgrade::get_time_delay(&account, b"test_package".to_string()) == delay_ms,
        1,
    );

    destroy(account);
    end(scenario, extensions, clock);
}

// === Access Control Init Tests ===

#[test]
fun test_init_lock_capability() {
    let (mut scenario, extensions, clock) = start();

    let mut account = create_unshared_account(&extensions, &mut scenario);

    // Create a test capability
    let cap = TestCap {
        id: object::new(scenario.ctx()),
        value: 42,
    };

    // Lock it during init
    init_actions::init_lock_capability<Config, TestCap>(
        &mut account,
        cap,
    );

    // Verify cap is locked
    assert!(account_actions::access_control::has_lock<Config, TestCap>(&account), 0);

    destroy(account);
    end(scenario, extensions, clock);
}

// === Transfer Init Tests ===

#[test]
fun test_init_transfer_object() {
    let (mut scenario, extensions, clock) = start();

    let _account = create_unshared_account(&extensions, &mut scenario);

    // Create test object
    let obj = TestObject {
        id: object::new(scenario.ctx()),
        data: 100,
    };

    // Transfer during init
    init_actions::init_transfer_object(obj, RECIPIENT);

    // Verify transfer occurred
    scenario.next_tx(RECIPIENT);
    let received = scenario.take_from_address<TestObject>(RECIPIENT);
    assert!(received.data == 100, 0);

    destroy(received);
    destroy(_account);
    end(scenario, extensions, clock);
}

#[test]
fun test_init_transfer_objects_multiple() {
    let (mut scenario, extensions, clock) = start();

    let _account = create_unshared_account(&extensions, &mut scenario);

    // Create multiple objects
    let mut objects = vector[];
    let mut recipients = vector[];

    vector::push_back(&mut objects, TestObject { id: object::new(scenario.ctx()), data: 1 });
    vector::push_back(&mut objects, TestObject { id: object::new(scenario.ctx()), data: 2 });
    vector::push_back(&mut objects, TestObject { id: object::new(scenario.ctx()), data: 3 });

    vector::push_back(&mut recipients, RECIPIENT);
    vector::push_back(&mut recipients, @0xABC);
    vector::push_back(&mut recipients, @0xDEF);

    // Transfer all during init
    init_actions::init_transfer_objects(objects, recipients);

    // Verify transfers - both vectors pop_back, so order is reversed
    // objects [1,2,3] and recipients [RECIPIENT, ABC, DEF]
    // pop gives: (3, DEF), (2, ABC), (1, RECIPIENT)
    scenario.next_tx(RECIPIENT);
    let obj1 = scenario.take_from_address<TestObject>(RECIPIENT);
    assert!(obj1.data == 1, 0);

    scenario.next_tx(@0xABC);
    let obj2 = scenario.take_from_address<TestObject>(@0xABC);
    assert!(obj2.data == 2, 1);

    scenario.next_tx(@0xDEF);
    let obj3 = scenario.take_from_address<TestObject>(@0xDEF);
    assert!(obj3.data == 3, 2);

    destroy(obj1);
    destroy(obj2);
    destroy(obj3);
    destroy(_account);
    end(scenario, extensions, clock);
}

// === Stream Init Tests ===

#[test]
fun test_init_create_vault_stream() {
    let (mut scenario, extensions, mut clock) = start();

    let mut account = create_unshared_account(&extensions, &mut scenario);

    // First deposit funds into vault
    let coin = coin::mint_for_testing<SUI>(5000, scenario.ctx());
    init_actions::init_vault_deposit<Config, SUI>(
        &mut account,
        coin,
        b"treasury",
        scenario.ctx(),
    );

    let current_time = clock.timestamp_ms();
    let start_time = current_time;
    let end_time = current_time + (365 * 24 * 60 * 60 * 1000); // 1 year
    let cliff_time = option::some(current_time + (90 * 24 * 60 * 60 * 1000)); // 90 days

    // Create stream during init
    let stream_id = init_actions::init_create_vault_stream<Config, SUI>(
        &mut account,
        b"treasury",
        RECIPIENT,
        5000,
        start_time,
        end_time,
        cliff_time,
        500, // max per withdrawal
        30 * 24 * 60 * 60 * 1000, // monthly interval
        &clock,
        scenario.ctx(),
    );

    // Verify stream was created
    assert!(object::id_to_address(&stream_id) != @0x0, 0);

    destroy(account);
    end(scenario, extensions, clock);
}

#[test]
fun test_init_create_salary_stream() {
    let (mut scenario, extensions, mut clock) = start();

    let mut account = create_unshared_account(&extensions, &mut scenario);

    // First deposit funds
    let coin = coin::mint_for_testing<SUI>(12000, scenario.ctx());
    init_actions::init_vault_deposit_default<Config, SUI>(
        &mut account,
        coin,
        scenario.ctx(),
    );

    // Create 12-month salary stream
    let stream_id = init_actions::init_create_salary_stream<Config, SUI>(
        &mut account,
        RECIPIENT,
        1000, // monthly amount
        12, // num months
        &clock,
        scenario.ctx(),
    );

    // Verify stream was created
    assert!(object::id_to_address(&stream_id) != @0x0, 0);

    destroy(account);
    end(scenario, extensions, clock);
}

// === Error Tests ===

#[test]
#[expected_failure(abort_code = init_actions::ELengthMismatch)]
fun test_init_transfer_objects_length_mismatch() {
    let (mut scenario, extensions, _clock) = start();

    let mut account = create_unshared_account(&extensions, &mut scenario);

    let mut objects = vector[];
    let mut recipients = vector[];

    let obj1 = TestObject { id: object::new(scenario.ctx()), data: 1 };
    let obj2 = TestObject { id: object::new(scenario.ctx()), data: 2 };

    vector::push_back(&mut objects, obj1);
    vector::push_back(&mut objects, obj2);

    vector::push_back(&mut recipients, RECIPIENT);
    // Only 1 recipient for 2 objects - should fail

    init_actions::init_transfer_objects(objects, recipients);

    destroy(account);
    end(scenario, extensions, _clock);
}

// === Integration Test ===

#[test]
fun test_complete_dao_initialization() {
    let (mut scenario, extensions, mut clock) = start();

    // Create unshared account
    let mut account = create_unshared_account(&extensions, &mut scenario);

    // 1. Lock treasury cap
    let treasury_cap = coin::create_treasury_cap_for_testing<INIT_ACTIONS_TESTS>(scenario.ctx());
    init_actions::init_lock_treasury_cap<Config, INIT_ACTIONS_TESTS>(&mut account, treasury_cap);

    // 2. Mint and deposit into vault
    init_actions::init_mint_and_deposit<Config, INIT_ACTIONS_TESTS>(
        &mut account,
        10000,
        b"treasury",
        scenario.ctx(),
    );

    // 3. Create SUI vault for salary stream (uses default "Main Vault")
    let sui_coin = coin::mint_for_testing<SUI>(60000, scenario.ctx());
    init_actions::init_vault_deposit_default<Config, SUI>(
        &mut account,
        sui_coin,
        scenario.ctx(),
    );

    // 4. Create founder vesting
    let founder_coin = coin::mint_for_testing<SUI>(50000, scenario.ctx());
    let _vesting_id = init_actions::init_create_founder_vesting<Config, SUI>(
        &mut account,
        founder_coin,
        @0x123,
        365 * 24 * 60 * 60 * 1000, // 1 year cliff
        &clock,
        scenario.ctx(),
    );

    // 5. Create salary stream
    let _stream_id = init_actions::init_create_salary_stream<Config, SUI>(
        &mut account,
        @0x456,
        5000,
        12,
        &clock,
        scenario.ctx(),
    );

    // Verify everything was set up
    assert!(currency::has_cap<Config, INIT_ACTIONS_TESTS>(&account), 0);
    assert!(vault::has_vault(&account, b"treasury".to_string()), 1);
    assert!(vault::has_vault(&account, b"Main Vault".to_string()), 2);

    destroy(account);
    end(scenario, extensions, clock);
}
