#[test_only]
module futarchy_core::action_type_markers_tests;

use futarchy_core::action_type_markers;
use std::type_name;

// === Constructor Tests (Struct Instantiation) ===

#[test]
fun test_config_action_constructors() {
    // Test that constructor functions work
    let _set_meta = action_types::set_metadata();
    let _update_trading = action_types::update_trading_config();
    let _update_twap = action_types::update_twap_config();
    let _update_gov = action_types::update_governance();
    let _update_slash = action_types::update_slash_distribution();
    let _update_queue = action_types::update_queue_params();
}

#[test]
fun test_deposit_escrow_constructor() {
    let _accept = action_types::accept_deposit();
}

// === TypeName Accessor Tests ===

#[test]
fun test_config_action_typenames() {
    let set_proposals = action_types::set_proposals_enabled();
    let update_name = action_types::update_name();
    let trading_params = action_types::trading_params_update();
    let metadata = action_types::metadata_update();

    // Each should be a different TypeName
    assert!(set_proposals != update_name, 0);
    assert!(update_name != trading_params, 1);
    assert!(trading_params != metadata, 2);
    assert!(metadata != set_proposals, 3);
}

#[test]
fun test_liquidity_action_typenames() {
    let create_pool = action_types::create_pool();
    let update_pool = action_types::update_pool_params();
    let add_liq = action_types::add_liquidity();
    let remove_liq = action_types::remove_liquidity();
    let swap = action_types::swap();

    // All should be unique
    assert!(create_pool != update_pool, 0);
    assert!(update_pool != add_liq, 1);
    assert!(add_liq != remove_liq, 2);
    assert!(remove_liq != swap, 3);
    assert!(swap != create_pool, 4);
}

#[test]
fun test_governance_action_typenames() {
    let create_proposal = action_types::create_proposal();
    let reservation = action_types::proposal_reservation();
    let fee_update = action_types::platform_fee_update();
    let fee_withdraw = action_types::platform_fee_withdraw();

    assert!(create_proposal != reservation, 0);
    assert!(reservation != fee_update, 1);
    assert!(fee_update != fee_withdraw, 2);
}

#[test]
fun test_dissolution_action_typenames() {
    let initiate = action_types::initiate_dissolution();
    let cancel = action_types::cancel_dissolution();
    let distribute = action_types::distribute_asset();
    let finalize = action_types::finalize_dissolution();

    assert!(initiate != cancel, 0);
    assert!(cancel != distribute, 1);
    assert!(distribute != finalize, 2);
}

#[test]
fun test_stream_action_typenames() {
    let create = action_types::create_stream();
    let cancel = action_types::cancel_stream();
    let withdraw = action_types::withdraw_stream();
    let update = action_types::update_stream();
    let pause = action_types::pause_stream();
    let resume = action_types::resume_stream();

    assert!(create != cancel, 0);
    assert!(cancel != withdraw, 1);
    assert!(withdraw != update, 2);
    assert!(update != pause, 3);
    assert!(pause != resume, 4);
}

#[test]
fun test_oracle_action_typenames() {
    let create_grant = action_types::create_oracle_grant();
    let claim_tokens = action_types::claim_grant_tokens();
    let execute_tier = action_types::execute_milestone_tier();
    let cancel_grant = action_types::cancel_grant();
    let pause_grant = action_types::pause_grant();

    assert!(create_grant != claim_tokens, 0);
    assert!(claim_tokens != execute_tier, 1);
    assert!(execute_tier != cancel_grant, 2);
    assert!(cancel_grant != pause_grant, 3);
}

#[test]
fun test_security_council_action_typenames() {
    let create_council = action_types::create_council();
    let add_member = action_types::add_council_member();
    let remove_member = action_types::remove_council_member();
    let update_threshold = action_types::update_council_threshold();
    let approve_action = action_types::approve_council_action();

    assert!(create_council != add_member, 0);
    assert!(add_member != remove_member, 1);
    assert!(remove_member != update_threshold, 2);
    assert!(update_threshold != approve_action, 3);
}

#[test]
fun test_policy_action_typenames() {
    let create = action_types::create_policy();
    let update = action_types::update_policy();
    let remove = action_types::remove_policy();
    let set_type = action_types::set_type_policy();
    let set_object = action_types::set_object_policy();
    let register = action_types::register_council();

    assert!(create != update, 0);
    assert!(update != remove, 1);
    assert!(remove != set_type, 2);
    assert!(set_type != set_object, 3);
    assert!(set_object != register, 4);
}

#[test]
fun test_memo_action_typename() {
    let memo1 = action_types::memo();
    let memo2 = action_types::emit_memo();
    let memo3 = action_types::emit_decision();

    // All three should return the same TypeName (they all map to Memo)
    assert!(memo1 == memo2, 0);
    assert!(memo2 == memo3, 1);
    assert!(memo1 == memo3, 2);
}

#[test]
fun test_protocol_admin_action_typenames() {
    let set_paused = action_types::set_factory_paused();
    let add_stable = action_types::add_stable_type();
    let update_fee = action_types::update_dao_creation_fee();
    let withdraw = action_types::withdraw_protocol_fees();

    assert!(set_paused != add_stable, 0);
    assert!(add_stable != update_fee, 1);
    assert!(update_fee != withdraw, 2);
}

#[test]
fun test_verification_action_typenames() {
    let update_fee = action_types::update_verification_fee();
    let add_level = action_types::add_verification_level();
    let request = action_types::request_verification();
    let approve = action_types::approve_verification();
    let reject = action_types::reject_verification();

    assert!(update_fee != add_level, 0);
    assert!(add_level != request, 1);
    assert!(request != approve, 2);
    assert!(approve != reject, 3);
}

#[test]
fun test_file_registry_action_typenames() {
    let create_registry = action_types::create_dao_file_registry();
    let create_root = action_types::create_root_file();
    let create_child = action_types::create_child_file();
    let add_chunk = action_types::add_chunk();
    let set_immutable = action_types::set_chunk_immutable();

    assert!(create_registry != create_root, 0);
    assert!(create_root != create_child, 1);
    assert!(create_child != add_chunk, 2);
    assert!(add_chunk != set_immutable, 3);
}



// === TypeName Equality Tests ===

#[test]
fun test_typename_equality_same_action() {
    let name1 = action_types::set_proposals_enabled();
    let name2 = action_types::set_proposals_enabled();

    // Same action should produce identical TypeNames
    assert!(name1 == name2, 0);
}

#[test]
fun test_typename_inequality_different_actions() {
    let config = action_types::set_proposals_enabled();
    let liquidity = action_types::create_pool();
    let governance = action_types::create_proposal();
    let dissolution = action_types::initiate_dissolution();

    // Different categories should be different
    assert!(config != liquidity, 0);
    assert!(config != governance, 1);
    assert!(config != dissolution, 2);
    assert!(liquidity != governance, 3);
    assert!(liquidity != dissolution, 4);
    assert!(governance != dissolution, 5);
}

// === TypeName Copy Semantics Tests ===

#[test]
fun test_typename_has_copy() {
    let name1 = action_types::create_pool();
    let name2 = name1; // Copy

    // Both should be valid and equal
    assert!(name1 == name2, 0);
}

#[test]
fun test_typename_can_be_moved() {
    let name = action_types::create_pool();

    // Should be able to use it after creating
    let _ = name;
}

// === Struct Instance Tests ===

#[test]
fun test_struct_instances_have_drop() {
    // These structs should have drop ability
    let meta = action_types::set_metadata();
    let trading = action_types::update_trading_config();
    let twap = action_types::update_twap_config();

    // Should automatically drop at end of scope
    let _ = meta;
    let _ = trading;
    let _ = twap;
}

#[test]
fun test_struct_instances_have_copy() {
    let meta1 = action_types::set_metadata();
    let meta2 = meta1; // Copy

    // Both should be valid
    let _ = meta1;
    let _ = meta2;
}

// === Cross-Category Uniqueness Tests ===

#[test]
fun test_all_categories_unique() {
    // Sample one action from each major category
    let config = action_types::set_proposals_enabled();
    let liquidity = action_types::create_pool();
    let governance = action_types::create_proposal();
    let dissolution = action_types::initiate_dissolution();
    let stream = action_types::create_stream();
    let oracle = action_types::create_oracle_grant();
    let council = action_types::create_council();
    let policy = action_types::create_policy();
    let memo = action_types::memo();
    let admin = action_types::set_factory_paused();
    let verification = action_types::request_verification();
    let file = action_types::create_dao_file_registry();
    

    // All should be unique
    assert!(config != liquidity, 0);
    assert!(config != governance, 1);
    assert!(config != dissolution, 2);
    assert!(config != stream, 3);
    assert!(config != oracle, 4);
    assert!(config != council, 5);
    assert!(config != policy, 6);
    assert!(config != memo, 7);
    assert!(config != admin, 8);
    assert!(config != verification, 9);
    assert!(config != file, 10);
    

    // Sample a few more cross-category comparisons
    assert!(liquidity != governance, 12);
    assert!(stream != oracle, 13);
    assert!(council != policy, 14);
    assert!(admin != verification, 15);
}

// === TypeName String Representation Tests ===

#[test]
fun test_typename_to_string() {
    let typename = action_types::create_pool();

    // Should be able to convert to string
    let type_str = type_name::into_string(typename);

    // String should not be empty
    assert!(type_str.length() > 0, 0);
}

#[test]
fun test_different_actions_have_different_strings() {
    let create_pool = action_types::create_pool();
    let add_liq = action_types::add_liquidity();

    let str1 = type_name::into_string(create_pool);
    let str2 = type_name::into_string(add_liq);

    // Different actions should have different string representations
    assert!(str1 != str2, 0);
}
