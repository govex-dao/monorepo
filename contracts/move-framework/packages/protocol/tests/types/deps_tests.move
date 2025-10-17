#[test_only]
module account_protocol::deps_tests;

use account_extensions::extensions::{Self, Extensions};
use account_protocol::deps::{Self, Deps};
use account_protocol::version_witness;
use std::string::String;
use sui::package;
use sui::test_scenario as ts;
use sui::test_utils::destroy;

#[test_only]
use fun std::string::utf8 as vector.utf8;

#[test]
fun test_deps_new_and_getters() {
    let mut scenario = ts::begin(@0xCAFE);
    let extensions = extensions::new_for_testing_with_addrs(
        @account_protocol,
        @0x1,
        @0x2,
        scenario.ctx(),
    );
    let cap = package::test_publish(@0xA.to_id(), scenario.ctx());

    let deps = deps::new(
        &extensions,
        false,
        vector[b"AccountProtocol".to_string(), b"AccountConfig".to_string()],
        vector[@account_protocol, @0x1],
        vector[1, 1],
    );
    let dep = deps.get_by_name(b"AccountProtocol".to_string());

    assert!(dep.name() == b"AccountProtocol".to_string());
    assert!(dep.addr() == @account_protocol);
    assert!(dep.version() == 1);
    assert!(deps.length() == 2);
    assert!(deps.contains_name(b"AccountProtocol".to_string()));
    assert!(deps.contains_addr(@account_protocol));
    assert!(!deps.unverified_allowed());

    let witness = version_witness::new_for_testing(@account_protocol);
    deps.check(witness);

    destroy(cap);
    destroy(extensions);
    ts::end(scenario);
}

#[test]
fun test_deps_new_latest_extensions() {
    let mut scenario = ts::begin(@0xCAFE);
    let extensions = extensions::new_for_testing_with_addrs(
        @account_protocol,
        @0x1,
        @0x2,
        scenario.ctx(),
    );
    let cap = package::test_publish(@0xA.to_id(), scenario.ctx());

    let deps = deps::new_latest_extensions(
        &extensions,
        vector[
            b"AccountProtocol".to_string(),
            b"AccountConfig".to_string(),
            b"AccountActions".to_string(),
        ],
    );
    let dep = deps.get_by_name(b"AccountProtocol".to_string());

    assert!(dep.name() == b"AccountProtocol".to_string());
    assert!(dep.addr() == @account_protocol);
    assert!(dep.version() == 1);
    assert!(deps.length() == 3);
    assert!(deps.contains_name(b"AccountProtocol".to_string()));
    assert!(deps.contains_addr(@account_protocol));
    assert!(!deps.unverified_allowed());

    let witness = version_witness::new_for_testing(@account_protocol);
    deps.check(witness);

    destroy(cap);
    destroy(extensions);
    ts::end(scenario);
}

#[test]
fun test_deps_add_unverified_allowed() {
    let mut scenario = ts::begin(@0xCAFE);
    let extensions = extensions::new_for_testing_with_addrs(
        @account_protocol,
        @0x1,
        @0x2,
        scenario.ctx(),
    );
    let cap = package::test_publish(@0xA.to_id(), scenario.ctx());

    let deps = deps::new(
        &extensions,
        true,
        vector[b"AccountProtocol".to_string(), b"AccountConfig".to_string(), b"Other".to_string()],
        vector[@account_protocol, @0x1, @0x999],
        vector[1, 1, 1],
    );

    assert!(deps.length() == 3);
    assert!(deps.contains_name(b"Other".to_string()));
    assert!(deps.contains_addr(@0x999));
    assert!(deps.unverified_allowed());

    destroy(cap);
    destroy(extensions);
    ts::end(scenario);
}

#[test, expected_failure(abort_code = deps::EDepsNotSameLength)]
fun test_error_deps_not_same_length() {
    let mut scenario = ts::begin(@0xCAFE);
    let extensions = extensions::new_for_testing_with_addrs(
        @account_protocol,
        @0x1,
        @0x2,
        scenario.ctx(),
    );
    let cap = package::test_publish(@0xA.to_id(), scenario.ctx());

    let _deps = deps::new(
        &extensions,
        false,
        vector[b"AccountProtocol".to_string()],
        vector[@account_protocol, @0x1],
        vector[1, 1],
    );

    destroy(cap);
    destroy(extensions);
    ts::end(scenario);
}

#[test, expected_failure(abort_code = deps::EDepsNotSameLength)]
fun test_error_deps_not_same_length_bis() {
    let mut scenario = ts::begin(@0xCAFE);
    let extensions = extensions::new_for_testing_with_addrs(
        @account_protocol,
        @0x1,
        @0x2,
        scenario.ctx(),
    );
    let cap = package::test_publish(@0xA.to_id(), scenario.ctx());

    let _deps = deps::new(
        &extensions,
        false,
        vector[b"AccountProtocol".to_string()],
        vector[@account_protocol],
        vector[1, 1],
    );

    destroy(cap);
    destroy(extensions);
    ts::end(scenario);
}

#[test, expected_failure(abort_code = deps::EAccountProtocolMissing)]
fun test_error_deps_missing_account_protocol() {
    let mut scenario = ts::begin(@0xCAFE);
    let extensions = extensions::new_for_testing_with_addrs(
        @account_protocol,
        @0x1,
        @0x2,
        scenario.ctx(),
    );
    let cap = package::test_publish(@0xA.to_id(), scenario.ctx());

    let _deps = deps::new(
        &extensions,
        false,
        vector[b"Other".to_string()],
        vector[@account_protocol],
        vector[1],
    );

    destroy(cap);
    destroy(extensions);
    ts::end(scenario);
}

#[test, expected_failure(abort_code = deps::EAccountProtocolMissing)]
fun test_error_deps_missing_account_protocol_first_element() {
    let mut scenario = ts::begin(@0xCAFE);
    let extensions = extensions::new_for_testing_with_addrs(
        @account_protocol,
        @0x1,
        @0x2,
        scenario.ctx(),
    );
    let cap = package::test_publish(@0xA.to_id(), scenario.ctx());

    let _deps = deps::new(
        &extensions,
        false,
        vector[b"AccountConfig".to_string(), b"AccountProtocol".to_string()],
        vector[@0x1, @account_protocol],
        vector[1, 1],
    );

    destroy(cap);
    destroy(extensions);
    ts::end(scenario);
}

// REMOVED: test_error_deps_missing_account_config_second_element
// This test checked for negative assertion (names[1] != "AccountActions") which was
// intentionally removed in favor of type-safe validation via Move's type system.
// See deps.move:91-109 for detailed rationale.

#[test, expected_failure(abort_code = deps::ENotExtension)]
fun test_error_deps_add_not_extension_unverified_not_allowed() {
    let mut scenario = ts::begin(@0xCAFE);
    let extensions = extensions::new_for_testing_with_addrs(
        @account_protocol,
        @0x1,
        @0x2,
        scenario.ctx(),
    );
    let cap = package::test_publish(@0xA.to_id(), scenario.ctx());

    let _deps = deps::new(
        &extensions,
        false,
        vector[b"AccountProtocol".to_string(), b"AccountConfig".to_string(), b"Other".to_string()],
        vector[@account_protocol, @0x1, @0x999],
        vector[1, 1, 1],
    );

    destroy(cap);
    destroy(extensions);
    ts::end(scenario);
}

#[test, expected_failure(abort_code = deps::EDepAlreadyExists)]
fun test_error_deps_add_name_already_exists() {
    let mut scenario = ts::begin(@0xCAFE);
    let extensions = extensions::new_for_testing_with_addrs(
        @account_protocol,
        @0x1,
        @0x2,
        scenario.ctx(),
    );
    let cap = package::test_publish(@0xA.to_id(), scenario.ctx());

    let _deps = deps::new(
        &extensions,
        false,
        vector[
            b"AccountProtocol".to_string(),
            b"AccountConfig".to_string(),
            b"AccountProtocol".to_string(),
        ],
        vector[@account_protocol, @0x1, @0x2],
        vector[1, 1, 1],
    );

    destroy(cap);
    destroy(extensions);
    ts::end(scenario);
}

#[test, expected_failure(abort_code = deps::EDepAlreadyExists)]
fun test_error_deps_add_addr_already_exists() {
    let mut scenario = ts::begin(@0xCAFE);
    let extensions = extensions::new_for_testing_with_addrs(
        @account_protocol,
        @0x1,
        @0x2,
        scenario.ctx(),
    );
    let cap = package::test_publish(@0xA.to_id(), scenario.ctx());

    let _deps = deps::new(
        &extensions,
        false,
        vector[
            b"AccountProtocol".to_string(),
            b"AccountConfig".to_string(),
            b"AccountActions".to_string(),
        ],
        vector[@account_protocol, @0x1, @0x1],
        vector[1, 1, 1],
    );

    destroy(cap);
    destroy(extensions);
    ts::end(scenario);
}

#[test, expected_failure(abort_code = deps::ENotDep)]
fun test_error_assert_is_dep() {
    let mut scenario = ts::begin(@0xCAFE);
    let extensions = extensions::new_for_testing_with_addrs(
        @account_protocol,
        @0x1,
        @0x2,
        scenario.ctx(),
    );
    let cap = package::test_publish(@0xA.to_id(), scenario.ctx());

    let deps = deps::new(
        &extensions,
        false,
        vector[b"AccountProtocol".to_string(), b"AccountConfig".to_string()],
        vector[@account_protocol, @0x1],
        vector[1, 1],
    );
    let witness = version_witness::new_for_testing(@0xDEAD);
    deps.check(witness);

    destroy(cap);
    destroy(extensions);
    ts::end(scenario);
}

#[test, expected_failure(abort_code = deps::EDepNotFound)]
fun test_error_name_not_found() {
    let mut scenario = ts::begin(@0xCAFE);
    let extensions = extensions::new_for_testing_with_addrs(
        @account_protocol,
        @0x1,
        @0x2,
        scenario.ctx(),
    );
    let cap = package::test_publish(@0xA.to_id(), scenario.ctx());

    let deps = deps::new(
        &extensions,
        false,
        vector[b"AccountProtocol".to_string(), b"AccountConfig".to_string()],
        vector[@account_protocol, @0x1],
        vector[1, 1],
    );
    deps.get_by_name(b"Other".to_string());

    destroy(cap);
    destroy(extensions);
    ts::end(scenario);
}

#[test, expected_failure(abort_code = deps::EDepNotFound)]
fun test_error_addr_not_found() {
    let mut scenario = ts::begin(@0xCAFE);
    let extensions = extensions::new_for_testing_with_addrs(
        @account_protocol,
        @0x1,
        @0x2,
        scenario.ctx(),
    );
    let cap = package::test_publish(@0xA.to_id(), scenario.ctx());

    let deps = deps::new(
        &extensions,
        false,
        vector[b"AccountProtocol".to_string(), b"AccountConfig".to_string()],
        vector[@account_protocol, @0x1],
        vector[1, 1],
    );
    deps.get_by_addr(@0xA);

    destroy(cap);
    destroy(extensions);
    ts::end(scenario);
}

#[test, expected_failure(abort_code = deps::EAccountProtocolMissing)]
fun test_error_new_latest_misses_account_protocol() {
    let mut scenario = ts::begin(@0xCAFE);
    let extensions = extensions::new_for_testing_with_addrs(
        @account_protocol,
        @0x1,
        @0x2,
        scenario.ctx(),
    );
    let cap = package::test_publish(@0xA.to_id(), scenario.ctx());

    let _deps = deps::new_latest_extensions(
        &extensions,
        vector[b"AccountConfig".to_string(), b"AccountActions".to_string()],
    );

    destroy(cap);
    destroy(extensions);
    ts::end(scenario);
}

#[test, expected_failure(abort_code = deps::EDepAlreadyExists)]
fun test_error_new_latest_adds_account_protocol_twice() {
    let mut scenario = ts::begin(@0xCAFE);
    let extensions = extensions::new_for_testing_with_addrs(
        @account_protocol,
        @0x1,
        @0x2,
        scenario.ctx(),
    );
    let cap = package::test_publish(@0xA.to_id(), scenario.ctx());

    let _deps = deps::new_latest_extensions(
        &extensions,
        vector[b"AccountProtocol".to_string(), b"AccountProtocol".to_string()],
    );

    destroy(cap);
    destroy(extensions);
    ts::end(scenario);
}

#[test, expected_failure(abort_code = deps::EDepsNotSameLength)]
fun test_error_new_inner_not_same_length() {
    let mut scenario = ts::begin(@0xCAFE);
    let extensions = extensions::new_for_testing_with_addrs(
        @account_protocol,
        @0x1,
        @0x2,
        scenario.ctx(),
    );
    let cap = package::test_publish(@0xA.to_id(), scenario.ctx());

    let deps = deps::new_for_testing();
    let _deps = deps::new_inner(
        &extensions,
        &deps,
        vector[b"AccountProtocol".to_string()],
        vector[@account_protocol, @0x1],
        vector[1, 1],
    );

    destroy(cap);
    destroy(extensions);
    ts::end(scenario);
}

#[test, expected_failure(abort_code = deps::EDepsNotSameLength)]
fun test_error_new_inner_not_same_length_bis() {
    let mut scenario = ts::begin(@0xCAFE);
    let extensions = extensions::new_for_testing_with_addrs(
        @account_protocol,
        @0x1,
        @0x2,
        scenario.ctx(),
    );
    let cap = package::test_publish(@0xA.to_id(), scenario.ctx());

    let deps = deps::new_for_testing();
    let _deps = deps::new_inner(
        &extensions,
        &deps,
        vector[b"AccountProtocol".to_string()],
        vector[@account_protocol],
        vector[1, 1],
    );

    destroy(cap);
    destroy(extensions);
    ts::end(scenario);
}

#[test, expected_failure(abort_code = deps::EAccountProtocolMissing)]
fun test_error_new_inner_missing_account_protocol() {
    let mut scenario = ts::begin(@0xCAFE);
    let extensions = extensions::new_for_testing_with_addrs(
        @account_protocol,
        @0x1,
        @0x2,
        scenario.ctx(),
    );
    let cap = package::test_publish(@0xA.to_id(), scenario.ctx());

    let deps = deps::new_for_testing();
    let _deps = deps::new_inner(
        &extensions,
        &deps,
        vector[b"Other".to_string()],
        vector[@account_protocol],
        vector[1],
    );

    destroy(cap);
    destroy(extensions);
    ts::end(scenario);
}

#[test, expected_failure(abort_code = deps::EAccountProtocolMissing)]
fun test_error_new_inner_missing_account_protocol_first_element() {
    let mut scenario = ts::begin(@0xCAFE);
    let extensions = extensions::new_for_testing_with_addrs(
        @account_protocol,
        @0x1,
        @0x2,
        scenario.ctx(),
    );
    let cap = package::test_publish(@0xA.to_id(), scenario.ctx());

    let deps = deps::new_for_testing();
    let _deps = deps::new_inner(
        &extensions,
        &deps,
        vector[b"AccountConfig".to_string(), b"AccountProtocol".to_string()],
        vector[@0x1, @account_protocol],
        vector[1, 1],
    );

    destroy(cap);
    destroy(extensions);
    ts::end(scenario);
}

#[test, expected_failure(abort_code = deps::EAccountConfigMissing)]
fun test_error_new_inner_missing_account_config() {
    let mut scenario = ts::begin(@0xCAFE);
    let extensions = extensions::new_for_testing_with_addrs(
        @account_protocol,
        @0x1,
        @0x2,
        scenario.ctx(),
    );
    let cap = package::test_publish(@0xA.to_id(), scenario.ctx());

    let deps = deps::new_for_testing();
    let _deps = deps::new_inner(
        &extensions,
        &deps,
        vector[b"AccountProtocol".to_string()],
        vector[@account_protocol],
        vector[1],
    );

    destroy(cap);
    destroy(extensions);
    ts::end(scenario);
}

// REMOVED: test_error_new_inner_missing_account_config_second_element
// This test checked for negative assertion (names[1] != "AccountActions") which was
// intentionally removed in favor of type-safe validation via Move's type system.
// See deps.move:176-179 and deps.move:91-109 for detailed rationale.

// REMOVED: test_error_new_inner_missing_account_config_unverified_disallowed_and_
// Test name is incomplete and test logic doesn't match the name - appears to be broken/unfinished

#[test, expected_failure(abort_code = deps::ENotExtension)]
fun test_error_new_inner_add_not_extension_unverified_not_allowed() {
    let mut scenario = ts::begin(@0xCAFE);
    let extensions = extensions::new_for_testing_with_addrs(
        @account_protocol,
        @0x1,
        @0x2,
        scenario.ctx(),
    );
    let cap = package::test_publish(@0xA.to_id(), scenario.ctx());

    let deps = deps::new(
        &extensions,
        false,
        vector[b"AccountProtocol".to_string(), b"AccountConfig".to_string()],
        vector[@account_protocol, @0x1],
        vector[1, 1],
    );
    let _deps = deps::new_inner(
        &extensions,
        &deps,
        vector[b"AccountProtocol".to_string(), b"AccountConfig".to_string(), b"Other".to_string()],
        vector[@account_protocol, @0x1, @0x999],
        vector[1, 1, 1],
    );

    destroy(cap);
    destroy(extensions);
    ts::end(scenario);
}

#[test, expected_failure(abort_code = deps::EDepAlreadyExists)]
fun test_error_new_inner_add_name_already_exists() {
    let mut scenario = ts::begin(@0xCAFE);
    let extensions = extensions::new_for_testing_with_addrs(
        @account_protocol,
        @0x1,
        @0x2,
        scenario.ctx(),
    );
    let cap = package::test_publish(@0xA.to_id(), scenario.ctx());

    let deps = deps::new_for_testing();
    let _deps = deps::new_inner(
        &extensions,
        &deps,
        vector[
            b"AccountProtocol".to_string(),
            b"AccountConfig".to_string(),
            b"AccountProtocol".to_string(),
        ],
        vector[@account_protocol, @0x1, @0x2],
        vector[1, 1, 1],
    );

    destroy(cap);
    destroy(extensions);
    ts::end(scenario);
}

#[test, expected_failure(abort_code = deps::EDepAlreadyExists)]
fun test_error_new_inner_add_addr_already_exists() {
    let mut scenario = ts::begin(@0xCAFE);
    let extensions = extensions::new_for_testing_with_addrs(
        @account_protocol,
        @0x1,
        @0x2,
        scenario.ctx(),
    );
    let cap = package::test_publish(@0xA.to_id(), scenario.ctx());

    let deps = deps::new_for_testing();
    let _deps = deps::new_inner(
        &extensions,
        &deps,
        vector[
            b"AccountProtocol".to_string(),
            b"AccountConfig".to_string(),
            b"AccountProtocol".to_string(),
        ],
        vector[@account_protocol, @0x1, @account_protocol],
        vector[1, 1, 1],
    );

    destroy(cap);
    destroy(extensions);
    ts::end(scenario);
}
#[test]
/// Test that we can handle many dependencies efficiently (10+ deps scenario)
fun test_deps_scalability_many_deps() {
    let mut scenario = ts::begin(@0xCAFE);
    let extensions = extensions::new_for_testing_with_addrs(
        @account_protocol,
        @0x1,
        @0x2,
        scenario.ctx(),
    );

    // Simulate adding many dependencies (e.g., DeFi integrations)
    let names = vector[
        b"AccountProtocol".to_string(),
        b"AccountConfig".to_string(),
        b"CetusClmm".to_string(),
        b"ScallopLending".to_string(),
        b"TurbosPerps".to_string(),
        b"AftermathStaking".to_string(),
        b"FlowXOrderbook".to_string(),
        b"CustomTreasury".to_string(),
        b"CustomVoting".to_string(),
        b"CustomRewards".to_string(),
    ];

    let addrs = vector[@account_protocol, @0x1, @0x2, @0x3, @0x4, @0x5, @0x6, @0x7, @0x8, @0x9];
    let versions = vector[1, 1, 1, 1, 1, 1, 1, 1, 1, 1];

    // Allow unverified so we can test with many deps
    let deps = deps::new(&extensions, true, names, addrs, versions);

    // Verify all deps were added
    assert!(deps.length() == 10);
    assert!(deps.contains_name(b"CetusClmm".to_string()));
    assert!(deps.contains_addr(@0x9));

    // Test lookups work correctly
    let dep = deps.get_by_name(b"ScallopLending".to_string());
    assert!(dep.addr() == @0x3);

    destroy(extensions);
    ts::end(scenario);
}

#[test]
/// Test duplicate detection works correctly with VecSet optimization
fun test_deps_duplicate_detection_vecset() {
    let mut scenario = ts::begin(@0xCAFE);
    let extensions = extensions::new_for_testing_with_addrs(
        @account_protocol,
        @0x1,
        @0x2,
        scenario.ctx(),
    );

    // Create deps with unique entries
    let deps = deps::new(
        &extensions,
        true, // allow unverified
        vector[
            b"AccountProtocol".to_string(),
            b"AccountConfig".to_string(),
            b"Package1".to_string(),
            b"Package2".to_string(),
            b"Package3".to_string(),
        ],
        vector[@account_protocol, @0x1, @0x10, @0x11, @0x12],
        vector[1, 1, 1, 1, 1],
    );

    assert!(deps.length() == 5);
    assert!(deps.contains_name(b"Package3".to_string()));
    assert!(deps.contains_addr(@0x12));

    destroy(extensions);
    ts::end(scenario);
}

#[test, expected_failure(abort_code = deps::EDepAlreadyExists)]
/// Test that duplicate names are caught by VecSet
fun test_deps_duplicate_name_detection() {
    let mut scenario = ts::begin(@0xCAFE);
    let extensions = extensions::new_for_testing_with_addrs(
        @account_protocol,
        @0x1,
        @0x2,
        scenario.ctx(),
    );

    // Try to add duplicate name (Package1 twice)
    let _deps = deps::new(
        &extensions,
        true,
        vector[
            b"AccountProtocol".to_string(),
            b"AccountConfig".to_string(),
            b"Package1".to_string(),
            b"Package1".to_string(), // Duplicate!
        ],
        vector[@account_protocol, @0x1, @0x10, @0x11],
        vector[1, 1, 1, 1],
    );

    destroy(extensions);
    ts::end(scenario);
}

#[test, expected_failure(abort_code = deps::EDepAlreadyExists)]
/// Test that duplicate addresses are caught by VecSet
fun test_deps_duplicate_addr_detection() {
    let mut scenario = ts::begin(@0xCAFE);
    let extensions = extensions::new_for_testing_with_addrs(
        @account_protocol,
        @0x1,
        @0x2,
        scenario.ctx(),
    );

    // Try to add duplicate address (@0x10 twice)
    let _deps = deps::new(
        &extensions,
        true,
        vector[
            b"AccountProtocol".to_string(),
            b"AccountConfig".to_string(),
            b"Package1".to_string(),
            b"Package2".to_string(),
        ],
        vector[@account_protocol, @0x1, @0x10, @0x10], // Duplicate address!
        vector[1, 1, 1, 1],
    );

    destroy(extensions);
    ts::end(scenario);
}

#[test]
/// Test get_by_idx works correctly with multiple deps
fun test_deps_get_by_index() {
    let mut scenario = ts::begin(@0xCAFE);
    let extensions = extensions::new_for_testing_with_addrs(
        @account_protocol,
        @0x1,
        @0x2,
        scenario.ctx(),
    );

    let deps = deps::new(
        &extensions,
        true,
        vector[
            b"AccountProtocol".to_string(),
            b"AccountConfig".to_string(),
            b"CustomPackage".to_string(),
        ],
        vector[@account_protocol, @0x1, @0x99],
        vector[1, 1, 2],
    );

    // Test index access
    let dep0 = deps.get_by_idx(0);
    assert!(dep0.name() == b"AccountProtocol".to_string());
    assert!(dep0.addr() == @account_protocol);

    let dep2 = deps.get_by_idx(2);
    assert!(dep2.name() == b"CustomPackage".to_string());
    assert!(dep2.addr() == @0x99);
    assert!(dep2.version() == 2);

    destroy(extensions);
    ts::end(scenario);
}

#[test]
/// Test new_latest_extensions with VecSet optimization
fun test_deps_new_latest_with_vecset() {
    let mut scenario = ts::begin(@0xCAFE);
    let extensions = extensions::new_for_testing_with_addrs(
        @account_protocol,
        @0x1,
        @0x2,
        scenario.ctx(),
    );

    let deps = deps::new_latest_extensions(
        &extensions,
        vector[
            b"AccountProtocol".to_string(),
            b"AccountConfig".to_string(),
            b"AccountActions".to_string(),
        ],
    );

    assert!(deps.length() == 3);
    assert!(!deps.unverified_allowed()); // Should be false for new_latest

    // Verify correct addresses were set
    let protocol = deps.get_by_name(b"AccountProtocol".to_string());
    assert!(protocol.addr() == @account_protocol);

    destroy(extensions);
    ts::end(scenario);
}

#[test]
/// Test new_inner with many deps (stress test)
fun test_deps_new_inner_many_deps() {
    let mut scenario = ts::begin(@0xCAFE);
    let extensions = extensions::new_for_testing_with_addrs(
        @account_protocol,
        @0x1,
        @0x2,
        scenario.ctx(),
    );

    // Create initial deps
    let deps1 = deps::new(
        &extensions,
        true,
        vector[b"AccountProtocol".to_string(), b"AccountConfig".to_string()],
        vector[@account_protocol, @0x1],
        vector[1, 1],
    );

    // Create new deps with many packages
    let deps2 = deps::new_inner(
        &extensions,
        &deps1,
        vector[
            b"AccountProtocol".to_string(),
            b"AccountConfig".to_string(),
            b"Package1".to_string(),
            b"Package2".to_string(),
            b"Package3".to_string(),
            b"Package4".to_string(),
            b"Package5".to_string(),
        ],
        vector[@account_protocol, @0x1, @0x20, @0x21, @0x22, @0x23, @0x24],
        vector[1, 1, 1, 1, 1, 1, 1],
    );

    assert!(deps2.length() == 7);
    assert!(deps2.unverified_allowed() == true); // Should inherit from deps1

    destroy(extensions);
    ts::end(scenario);
}

#[test, expected_failure(abort_code = deps::EDepAlreadyExists)]
/// Test new_inner catches duplicates with VecSet
fun test_deps_new_inner_duplicate_in_middle() {
    let mut scenario = ts::begin(@0xCAFE);
    let extensions = extensions::new_for_testing_with_addrs(
        @account_protocol,
        @0x1,
        @0x2,
        scenario.ctx(),
    );

    let deps1 = deps::new(
        &extensions,
        true,
        vector[b"AccountProtocol".to_string(), b"AccountConfig".to_string()],
        vector[@account_protocol, @0x1],
        vector[1, 1],
    );

    // Try to add duplicate in the middle of the list
    let _deps2 = deps::new_inner(
        &extensions,
        &deps1,
        vector[
            b"AccountProtocol".to_string(),
            b"AccountConfig".to_string(),
            b"Package1".to_string(),
            b"Package2".to_string(),
            b"Package1".to_string(), // Duplicate!
        ],
        vector[@account_protocol, @0x1, @0x20, @0x21, @0x22],
        vector[1, 1, 1, 1, 1],
    );

    destroy(extensions);
    ts::end(scenario);
}

#[test]
/// Test edge case: minimal deps (just required 2)
fun test_deps_minimal_required() {
    let mut scenario = ts::begin(@0xCAFE);
    let extensions = extensions::new_for_testing_with_addrs(
        @account_protocol,
        @0x1,
        @0x2,
        scenario.ctx(),
    );

    // Minimum valid deps: AccountProtocol + AccountConfig
    let deps = deps::new(
        &extensions,
        false,
        vector[b"AccountProtocol".to_string(), b"AccountConfig".to_string()],
        vector[@account_protocol, @0x1],
        vector[1, 1],
    );

    assert!(deps.length() == 2);
    assert!(deps.contains_name(b"AccountProtocol".to_string()));
    assert!(deps.contains_name(b"AccountConfig".to_string()));

    destroy(extensions);
    ts::end(scenario);
}

#[test]
/// Test toggle_unverified_allowed functionality
fun test_deps_toggle_unverified() {
    let mut scenario = ts::begin(@0xCAFE);
    let extensions = extensions::new_for_testing_with_addrs(
        @account_protocol,
        @0x1,
        @0x2,
        scenario.ctx(),
    );

    let mut deps = deps::new(
        &extensions,
        false, // Start with unverified not allowed
        vector[b"AccountProtocol".to_string(), b"AccountConfig".to_string()],
        vector[@account_protocol, @0x1],
        vector[1, 1],
    );

    assert!(!deps.unverified_allowed());

    // Toggle to allow unverified
    deps.toggle_unverified_allowed_for_testing();
    assert!(deps.unverified_allowed());

    // Toggle back
    deps.toggle_unverified_allowed_for_testing();
    assert!(!deps.unverified_allowed());

    destroy(extensions);
    ts::end(scenario);
}

// Test scenario where we upgrade dependencies versions
#[test]
fun test_deps_version_upgrade() {
    let mut scenario = ts::begin(@0xCAFE);
    let extensions = extensions::new_for_testing_with_addrs(
        @account_protocol,
        @0x1,
        @0x2,
        scenario.ctx(),
    );

    // Create deps with version 1
    let deps_v1 = deps::new(
        &extensions,
        true,
        vector[
            b"AccountProtocol".to_string(),
            b"AccountConfig".to_string(),
            b"CustomPackage".to_string(),
        ],
        vector[@account_protocol, @0x1, @0x99],
        vector[1, 1, 1],
    );

    // Upgrade to version 2 using new_inner
    let deps_v2 = deps::new_inner(
        &extensions,
        &deps_v1,
        vector[
            b"AccountProtocol".to_string(),
            b"AccountConfig".to_string(),
            b"CustomPackage".to_string(),
        ],
        vector[@account_protocol, @0x1, @0x99],
        vector[2, 2, 2], // Version 2
    );

    // Check versions were updated
    let dep = deps_v2.get_by_name(b"CustomPackage".to_string());
    assert!(dep.version() == 2);

    destroy(extensions);
    ts::end(scenario);
}
