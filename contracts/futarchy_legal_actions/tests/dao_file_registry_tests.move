#[test_only]
module futarchy_legal_actions::dao_file_registry_tests;

use account_extensions::extensions::{Self, Extensions, AdminCap};
use account_protocol::account::{Self, Account};
use account_protocol::deps;
use account_protocol::version_witness;
use futarchy_core::futarchy_config::FutarchyConfig;
use futarchy_core::version;
use futarchy_legal_actions::dao_file_registry::{Self, DaoFileRegistry};
use sui::clock::{Self, Clock};
use sui::test_scenario::{Self as ts, Scenario};
use sui::test_utils::destroy;

// === Imports ===

// === Constants ===

const OWNER: address = @0xCAFE;

// === Test Helpers ===

public struct Witness() has drop;

fun start(): (Scenario, Extensions, Clock, Account<FutarchyConfig>) {
    let mut scenario = ts::begin(OWNER);

    // Setup extensions
    extensions::init_for_testing(scenario.ctx());
    scenario.next_tx(OWNER);
    let mut extensions = scenario.take_shared<Extensions>();
    let cap = scenario.take_from_sender<AdminCap>();
    extensions.add(&cap, b"AccountProtocol".to_string(), @account_protocol, 1);
    extensions.add(&cap, b"AccountActions".to_string(), @account_actions, 1);
    extensions.add(&cap, b"FutarchyCore".to_string(), @futarchy_core, 1);
    destroy(cap);

    // Create clock
    let clock = clock::create_for_testing(scenario.ctx());

    // Create account
    let config = FutarchyConfig {};
    let deps = deps::new_latest_extensions(
        &extensions,
        vector[
            b"AccountProtocol".to_string(),
            b"AccountActions".to_string(),
            b"FutarchyCore".to_string(),
        ],
    );
    let account = account::new(config, deps, version::current(), Witness(), scenario.ctx());

    (scenario, extensions, clock, account)
}

fun end(
    scenario: Scenario,
    extensions: Extensions,
    clock: Clock,
    account: Account<FutarchyConfig>,
) {
    destroy(extensions);
    destroy(clock);
    destroy(account);
    ts::end(scenario);
}

// === Registry Creation Tests ===

#[test]
fun test_create_registry() {
    let (scenario, extensions, clock, mut account) = start();

    // Create registry
    let dao_id = object::id(&account);
    let registry = dao_file_registry::create_registry(dao_id, scenario.ctx());

    // Store in account
    dao_file_registry::store_in_account<FutarchyConfig>(&mut account, registry);

    // Verify registry exists
    assert!(dao_file_registry::has_registry<FutarchyConfig>(&account), 0);

    end(scenario, extensions, clock, account);
}

#[test]
fun test_create_root_document() {
    let (scenario, extensions, mut clock, mut account) = start();

    // Create registry
    let dao_id = object::id(&account);
    let registry = dao_file_registry::create_registry(dao_id, scenario.ctx());
    dao_file_registry::store_in_account<FutarchyConfig>(&mut account, registry);

    // Get mutable registry
    let registry = dao_file_registry::get_registry_mut<FutarchyConfig>(&mut account);

    // Create document
    let current_time = clock.timestamp_ms();
    let _doc_id = dao_file_registry::create_root_document(
        registry,
        b"bylaws".to_string(),
        current_time,
        &clock,
        scenario.ctx(),
    );

    end(scenario, extensions, clock, account);
}

// === Basic Chunk Tests ===

#[test]
fun test_add_text_chunk() {
    let (scenario, extensions, mut clock, mut account) = start();

    // Setup registry and document
    let dao_id = object::id(&account);
    let registry = dao_file_registry::create_registry(dao_id, scenario.ctx());
    dao_file_registry::store_in_account<FutarchyConfig>(&mut account, registry);

    let registry = dao_file_registry::get_registry_mut<FutarchyConfig>(&mut account);
    let current_time = clock.timestamp_ms();
    let doc_id = dao_file_registry::create_root_document(
        registry,
        b"bylaws".to_string(),
        current_time,
        &clock,
        scenario.ctx(),
    );

    // Add text chunk
    let _chunk_id = dao_file_registry::add_chunk_with_text(
        registry,
        doc_id,
        b"Article I: Purpose".to_string(),
        &clock,
        scenario.ctx(),
    );

    end(scenario, extensions, clock, account);
}

#[test]
fun test_add_multiple_chunks() {
    let (scenario, extensions, mut clock, mut account) = start();

    // Setup
    let dao_id = object::id(&account);
    let registry = dao_file_registry::create_registry(dao_id, scenario.ctx());
    dao_file_registry::store_in_account<FutarchyConfig>(&mut account, registry);

    let registry = dao_file_registry::get_registry_mut<FutarchyConfig>(&mut account);
    let current_time = clock.timestamp_ms();
    let doc_id = dao_file_registry::create_root_document(
        registry,
        b"bylaws".to_string(),
        current_time,
        &clock,
        scenario.ctx(),
    );

    // Add multiple chunks
    dao_file_registry::add_chunk_with_text(
        registry,
        doc_id,
        b"Article I".to_string(),
        &clock,
        scenario.ctx(),
    );

    dao_file_registry::add_chunk_with_text(
        registry,
        doc_id,
        b"Article II".to_string(),
        &clock,
        scenario.ctx(),
    );

    dao_file_registry::add_chunk_with_text(
        registry,
        doc_id,
        b"Article III".to_string(),
        &clock,
        scenario.ctx(),
    );

    end(scenario, extensions, clock, account);
}

// === Update Tests ===

#[test]
fun test_update_text_chunk() {
    let (scenario, extensions, mut clock, mut account) = start();

    // Setup with one chunk
    let dao_id = object::id(&account);
    let registry = dao_file_registry::create_registry(dao_id, scenario.ctx());
    dao_file_registry::store_in_account<FutarchyConfig>(&mut account, registry);

    let registry = dao_file_registry::get_registry_mut<FutarchyConfig>(&mut account);
    let current_time = clock.timestamp_ms();
    let doc_id = dao_file_registry::create_root_document(
        registry,
        b"bylaws".to_string(),
        current_time,
        &clock,
        scenario.ctx(),
    );

    let chunk_id = dao_file_registry::add_chunk_with_text(
        registry,
        doc_id,
        b"Original text".to_string(),
        &clock,
        scenario.ctx(),
    );

    // Update chunk
    dao_file_registry::update_text_chunk(
        registry,
        doc_id,
        chunk_id,
        b"Updated text".to_string(),
        &clock,
    );

    end(scenario, extensions, clock, account);
}

// === Remove Tests ===

#[test]
fun test_remove_text_chunk() {
    let (scenario, extensions, mut clock, mut account) = start();

    // Setup with one chunk
    let dao_id = object::id(&account);
    let registry = dao_file_registry::create_registry(dao_id, scenario.ctx());
    dao_file_registry::store_in_account<FutarchyConfig>(&mut account, registry);

    let registry = dao_file_registry::get_registry_mut<FutarchyConfig>(&mut account);
    let current_time = clock.timestamp_ms();
    let doc_id = dao_file_registry::create_root_document(
        registry,
        b"bylaws".to_string(),
        current_time,
        &clock,
        scenario.ctx(),
    );

    let chunk_id = dao_file_registry::add_chunk_with_text(
        registry,
        doc_id,
        b"To be removed".to_string(),
        &clock,
        scenario.ctx(),
    );

    // Remove chunk
    dao_file_registry::remove_text_chunk(
        registry,
        doc_id,
        chunk_id,
        &clock,
    );

    end(scenario, extensions, clock, account);
}

// === Immutability Tests ===

#[test]
fun test_set_chunk_immutable() {
    let (scenario, extensions, mut clock, mut account) = start();

    // Setup
    let dao_id = object::id(&account);
    let registry = dao_file_registry::create_registry(dao_id, scenario.ctx());
    dao_file_registry::store_in_account<FutarchyConfig>(&mut account, registry);

    let registry = dao_file_registry::get_registry_mut<FutarchyConfig>(&mut account);
    let current_time = clock.timestamp_ms();
    let doc_id = dao_file_registry::create_root_document(
        registry,
        b"bylaws".to_string(),
        current_time,
        &clock,
        scenario.ctx(),
    );

    let chunk_id = dao_file_registry::add_chunk_with_text(
        registry,
        doc_id,
        b"Immutable text".to_string(),
        &clock,
        scenario.ctx(),
    );

    // Set chunk immutable
    dao_file_registry::set_chunk_immutable(
        registry,
        doc_id,
        chunk_id,
        &clock,
    );

    end(scenario, extensions, clock, account);
}

#[test]
fun test_set_document_immutable() {
    let (scenario, extensions, mut clock, mut account) = start();

    // Setup
    let dao_id = object::id(&account);
    let registry = dao_file_registry::create_registry(dao_id, scenario.ctx());
    dao_file_registry::store_in_account<FutarchyConfig>(&mut account, registry);

    let registry = dao_file_registry::get_registry_mut<FutarchyConfig>(&mut account);
    let current_time = clock.timestamp_ms();
    let doc_id = dao_file_registry::create_root_document(
        registry,
        b"bylaws".to_string(),
        current_time,
        &clock,
        scenario.ctx(),
    );

    // Set document immutable
    dao_file_registry::set_document_immutable(registry, doc_id, &clock);

    end(scenario, extensions, clock, account);
}

#[test]
fun test_set_registry_immutable() {
    let (scenario, extensions, mut clock, mut account) = start();

    // Setup
    let dao_id = object::id(&account);
    let registry = dao_file_registry::create_registry(dao_id, scenario.ctx());
    dao_file_registry::store_in_account<FutarchyConfig>(&mut account, registry);

    let registry = dao_file_registry::get_registry_mut<FutarchyConfig>(&mut account);

    // Set registry immutable
    dao_file_registry::set_registry_immutable(registry, &clock);

    end(scenario, extensions, clock, account);
}

// === Permission Tests ===

#[test]
fun test_set_insert_allowed() {
    let (scenario, extensions, mut clock, mut account) = start();

    // Setup
    let dao_id = object::id(&account);
    let registry = dao_file_registry::create_registry(dao_id, scenario.ctx());
    dao_file_registry::store_in_account<FutarchyConfig>(&mut account, registry);

    let registry = dao_file_registry::get_registry_mut<FutarchyConfig>(&mut account);
    let current_time = clock.timestamp_ms();
    let doc_id = dao_file_registry::create_root_document(
        registry,
        b"bylaws".to_string(),
        current_time,
        &clock,
        scenario.ctx(),
    );

    // Disable insert
    dao_file_registry::set_insert_allowed(registry, doc_id, false, &clock);

    end(scenario, extensions, clock, account);
}

#[test]
fun test_set_remove_allowed() {
    let (scenario, extensions, mut clock, mut account) = start();

    // Setup
    let dao_id = object::id(&account);
    let registry = dao_file_registry::create_registry(dao_id, scenario.ctx());
    dao_file_registry::store_in_account<FutarchyConfig>(&mut account, registry);

    let registry = dao_file_registry::get_registry_mut<FutarchyConfig>(&mut account);
    let current_time = clock.timestamp_ms();
    let doc_id = dao_file_registry::create_root_document(
        registry,
        b"bylaws".to_string(),
        current_time,
        &clock,
        scenario.ctx(),
    );

    // Disable remove
    dao_file_registry::set_remove_allowed(registry, doc_id, false, &clock);

    end(scenario, extensions, clock, account);
}
