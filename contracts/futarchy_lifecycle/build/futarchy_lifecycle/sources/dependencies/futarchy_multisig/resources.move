/// Resource and Role Key System for Policy Engine
/// Provides standardized, type-safe keys for granular governance control
/// 
/// This module defines a hierarchical namespace for resources that can be
/// governed by policies in the DAO platform. Keys follow the pattern:
/// resource:/[category]/[action]/[specific_resource]
///
/// Categories:
/// - package: Package upgrades and code management
/// - vault: Treasury and asset management
/// - governance: Proposal and voting mechanisms
/// - operations: Operating agreement and administrative functions
/// - liquidity: AMM and liquidity pool management
/// - security: Security council and emergency actions
module futarchy_multisig::resources;

use std::{
    string::{Self, String},
    type_name::{Self, TypeName},
    ascii,
};

// === Constants for Resource Categories ===
const RESOURCE_PREFIX: vector<u8> = b"resource:/";
const RESOURCE_PREFIX_LEN: u64 = 10; // len("resource:/")
const PACKAGE_CATEGORY: vector<u8> = b"package/";
const VAULT_CATEGORY: vector<u8> = b"vault/";
const GOVERNANCE_CATEGORY: vector<u8> = b"governance/";
const OPERATIONS_CATEGORY: vector<u8> = b"operations/";
const LIQUIDITY_CATEGORY: vector<u8> = b"liquidity/";
const SECURITY_CATEGORY: vector<u8> = b"security/";
const STREAMS_CATEGORY: vector<u8> = b"streams/";
const EXT_CATEGORY: vector<u8> = b"ext/";
const OTHER_CATEGORY: vector<u8> = b"other/";

// === Errors ===
const EBadResourceKey: u64 = 1;

// === Helper Functions ===
fun prefix_str(): String { string::utf8(RESOURCE_PREFIX) }

public fun is_valid(key: &String): bool {
    key.index_of(&prefix_str()) == 0
}

fun strip_prefix_or_abort(key: &String): String {
    assert!(is_valid(key), EBadResourceKey);
    key.substring(RESOURCE_PREFIX_LEN, key.length())
}

// === Package Management Resources ===

/// Key for package upgrade permissions
/// Example: "resource:/package/upgrade/0x123::my_package"
public fun package_upgrade(package_addr: address, package_name: String): String {
    let mut key = string::utf8(RESOURCE_PREFIX);
    key.append(string::utf8(PACKAGE_CATEGORY));
    key.append(string::utf8(b"upgrade/"));
    key.append(package_addr.to_string());
    key.append(string::utf8(b"::"));
    key.append(package_name);
    key
}

/// Key for restricting package upgrades (making immutable)
/// Example: "resource:/package/restrict/0x123::my_package"
public fun package_restrict(package_addr: address, package_name: String): String {
    let mut key = string::utf8(RESOURCE_PREFIX);
    key.append(string::utf8(PACKAGE_CATEGORY));
    key.append(string::utf8(b"restrict/"));
    key.append(package_addr.to_string());
    key.append(string::utf8(b"::"));
    key.append(package_name);
    key
}

/// Key for package publication permissions
public fun package_publish(): String {
    let mut key = string::utf8(RESOURCE_PREFIX);
    key.append(string::utf8(PACKAGE_CATEGORY));
    key.append(string::utf8(b"publish"));
    key
}

// === Vault/Treasury Resources ===

/// Key for spending from a specific coin type
/// Example: "resource:/vault/spend/0x2::sui::SUI"
public fun vault_spend<CoinType>(): String {
    vault_spend_by_type(type_name::get<CoinType>())
}

public fun vault_spend_by_type(coin_type: TypeName): String {
    let mut key = string::utf8(RESOURCE_PREFIX);
    key.append(string::utf8(VAULT_CATEGORY));
    key.append(string::utf8(b"spend/"));
    let type_str = type_name::into_string(coin_type);
    key.append(string::from_ascii(type_str));
    key
}

/// Key for minting new coins (if TreasuryCap is held)
/// Example: "resource:/vault/mint/0x123::my_coin::MyCoin"
public fun vault_mint<CoinType>(): String {
    vault_mint_by_type(type_name::get<CoinType>())
}

public fun vault_mint_by_type(coin_type: TypeName): String {
    let mut key = string::utf8(RESOURCE_PREFIX);
    key.append(string::utf8(VAULT_CATEGORY));
    key.append(string::utf8(b"mint/"));
    let type_str = type_name::into_string(coin_type);
    key.append(string::from_ascii(type_str));
    key
}

/// Key for burning coins
public fun vault_burn<CoinType>(): String {
    let mut key = string::utf8(RESOURCE_PREFIX);
    key.append(string::utf8(VAULT_CATEGORY));
    key.append(string::utf8(b"burn/"));
    let type_str = type_name::into_string(type_name::get<CoinType>());
    key.append(string::from_ascii(type_str));
    key
}

/// Key for vault configuration changes
public fun vault_config(): String {
    let mut key = string::utf8(RESOURCE_PREFIX);
    key.append(string::utf8(VAULT_CATEGORY));
    key.append(string::utf8(b"config"));
    key
}

// === Governance Resources ===

/// Key for creating new proposals
public fun governance_propose(): String {
    let mut key = string::utf8(RESOURCE_PREFIX);
    key.append(string::utf8(GOVERNANCE_CATEGORY));
    key.append(string::utf8(b"propose"));
    key
}

/// Key for emergency proposal cancellation
public fun governance_cancel(): String {
    let mut key = string::utf8(RESOURCE_PREFIX);
    key.append(string::utf8(GOVERNANCE_CATEGORY));
    key.append(string::utf8(b"cancel"));
    key
}

/// Key for modifying governance parameters
public fun governance_params(): String {
    let mut key = string::utf8(RESOURCE_PREFIX);
    key.append(string::utf8(GOVERNANCE_CATEGORY));
    key.append(string::utf8(b"params"));
    key
}

/// Key for fast-track/emergency proposals
public fun governance_emergency(): String {
    let mut key = string::utf8(RESOURCE_PREFIX);
    key.append(string::utf8(GOVERNANCE_CATEGORY));
    key.append(string::utf8(b"emergency"));
    key
}

// === Operations Resources ===

/// Key for operating agreement modifications
public fun operations_agreement(): String {
    let mut key = string::utf8(RESOURCE_PREFIX);
    key.append(string::utf8(OPERATIONS_CATEGORY));
    key.append(string::utf8(b"agreement"));
    key
}

/// Key for member management (add/remove)
public fun operations_membership(): String {
    let mut key = string::utf8(RESOURCE_PREFIX);
    key.append(string::utf8(OPERATIONS_CATEGORY));
    key.append(string::utf8(b"membership"));
    key
}

/// Key for role assignments
public fun operations_roles(): String {
    let mut key = string::utf8(RESOURCE_PREFIX);
    key.append(string::utf8(OPERATIONS_CATEGORY));
    key.append(string::utf8(b"roles"));
    key
}

// === Liquidity Management Resources ===

/// Key for creating new liquidity pools
public fun liquidity_create_pool<AssetType, StableType>(): String {
    let mut key = string::utf8(RESOURCE_PREFIX);
    key.append(string::utf8(LIQUIDITY_CATEGORY));
    key.append(string::utf8(b"create/"));
    let asset_str = type_name::into_string(type_name::get<AssetType>());
    key.append(string::from_ascii(asset_str));
    key.append(string::utf8(b"/"));
    let stable_str = type_name::into_string(type_name::get<StableType>());
    key.append(string::from_ascii(stable_str));
    key
}

/// Key for adding liquidity
public fun liquidity_add<AssetType, StableType>(): String {
    let mut key = string::utf8(RESOURCE_PREFIX);
    key.append(string::utf8(LIQUIDITY_CATEGORY));
    key.append(string::utf8(b"add/"));
    let asset_str = type_name::into_string(type_name::get<AssetType>());
    key.append(string::from_ascii(asset_str));
    key.append(string::utf8(b"/"));
    let stable_str = type_name::into_string(type_name::get<StableType>());
    key.append(string::from_ascii(stable_str));
    key
}

/// Key for removing liquidity
public fun liquidity_remove<AssetType, StableType>(): String {
    let mut key = string::utf8(RESOURCE_PREFIX);
    key.append(string::utf8(LIQUIDITY_CATEGORY));
    key.append(string::utf8(b"remove/"));
    let asset_str = type_name::into_string(type_name::get<AssetType>());
    key.append(string::from_ascii(asset_str));
    key.append(string::utf8(b"/"));
    let stable_str = type_name::into_string(type_name::get<StableType>());
    key.append(string::from_ascii(stable_str));
    key
}

/// Key for modifying pool parameters
public fun liquidity_params(): String {
    let mut key = string::utf8(RESOURCE_PREFIX);
    key.append(string::utf8(LIQUIDITY_CATEGORY));
    key.append(string::utf8(b"params"));
    key
}

// === Security Council Resources ===

/// Key for security council emergency actions
public fun security_emergency_action(): String {
    let mut key = string::utf8(RESOURCE_PREFIX);
    key.append(string::utf8(SECURITY_CATEGORY));
    key.append(string::utf8(b"emergency"));
    key
}

/// Key for security council membership changes
public fun security_council_membership(): String {
    let mut key = string::utf8(RESOURCE_PREFIX);
    key.append(string::utf8(SECURITY_CATEGORY));
    key.append(string::utf8(b"membership"));
    key
}

/// Key for security council veto power
public fun security_veto(): String {
    let mut key = string::utf8(RESOURCE_PREFIX);
    key.append(string::utf8(SECURITY_CATEGORY));
    key.append(string::utf8(b"veto"));
    key
}

// === Payment Streams Resources ===

/// Key for creating payment streams
public fun streams_create<CoinType>(): String {
    let mut key = string::utf8(RESOURCE_PREFIX);
    key.append(string::utf8(STREAMS_CATEGORY));
    key.append(string::utf8(b"create/"));
    let type_str = type_name::into_string(type_name::get<CoinType>());
    key.append(string::from_ascii(type_str));
    key
}

/// Key for canceling payment streams
public fun streams_cancel(): String {
    let mut key = string::utf8(RESOURCE_PREFIX);
    key.append(string::utf8(STREAMS_CATEGORY));
    key.append(string::utf8(b"cancel"));
    key
}

// === Open Extension & Catch-All ===

/// Publisher-scoped extension key for arbitrary resources.
/// Example: "resource:/ext/0xabc/streams/create"
public fun ext(publisher: address, module_name: String, name: String): String {
    let mut key = string::utf8(RESOURCE_PREFIX);
    key.append(string::utf8(EXT_CATEGORY));
    key.append(publisher.to_string());
    key.append(string::utf8(b"/"));
    key.append(module_name);
    key.append(string::utf8(b"/"));
    key.append(name);
    key
}

/// A generic "other" bucket when you don't want publisher scoping.
/// Example: "resource:/other/my/custom/path"
public fun other(path: String): String {
    let mut key = string::utf8(RESOURCE_PREFIX);
    key.append(string::utf8(OTHER_CATEGORY));
    key.append(path);
    key
}

/// Catch-all wildcard that matches any resource key.
/// Returns "resource:/*"
public fun any(): String {
    let mut key = string::utf8(RESOURCE_PREFIX);
    key.append(string::utf8(b"*"));
    key
}

/// Prefix wildcard helper. Given a concrete resource key, produce a pattern
/// that matches "this key as a prefix". E.g. input "resource:/vault/spend/0x2::sui::SUI"
/// returns "resource:/vault/spend/0x2::sui::SUI*".
public fun wildcard_prefix(resource_key: String): String {
    assert!(is_valid(&resource_key), EBadResourceKey);
    let mut pattern = resource_key;
    pattern.append(string::utf8(b"*"));
    pattern
}

/// Simple wildcard matching:
/// - Exact match (no '*') → equality
/// - Trailing '*' only → prefix match (before the '*')
/// Any other placement of '*' is rejected (returns false).
public fun matches(pattern: &String, key: &String): bool {
    let star = pattern.index_of(&string::utf8(b"*"));
    if (star == pattern.length()) {
        // no '*': exact match
        *pattern == *key
    } else if (star + 1 == pattern.length()) {
        // trailing '*': prefix match
        let pfx = pattern.substring(0, star);
        key.index_of(&pfx) == 0
    } else {
        // embedded '*' not supported
        false
    }
}

/// Scope a resource key under a proposal. Useful to ensure one proposal
/// cannot affect another's resources unintentionally.
/// Produces: "resource:/proposal/<proposal_key>/<resource-part>"
public fun for_proposal(proposal_key: String, resource_key: String): String {
    let mut key = string::utf8(RESOURCE_PREFIX);
    key.append(string::utf8(b"proposal/"));
    key.append(proposal_key);
    key.append(string::utf8(b"/"));
    let resource_part = strip_prefix_or_abort(&resource_key);
    key.append(resource_part);
    key
}

// === Role-Based Keys ===

/// Generate a role-specific resource key
/// Example: "resource:/role/admin/vault/spend/0x2::sui::SUI"
public fun for_role(role: String, resource_key: String): String {
    let mut key = string::utf8(RESOURCE_PREFIX);
    key.append(string::utf8(b"role/"));
    key.append(role);
    key.append(string::utf8(b"/"));
    let resource_part = strip_prefix_or_abort(&resource_key);
    key.append(resource_part);
    key
}

/// Generate a time-bounded resource key
/// Example: "resource:/timelock/86400/package/upgrade/0x123::pkg"
public fun with_timelock(delay_ms: u64, resource_key: String): String {
    let mut key = string::utf8(RESOURCE_PREFIX);
    key.append(string::utf8(b"timelock/"));
    key.append(delay_ms.to_string());
    key.append(string::utf8(b"/"));
    let resource_part = strip_prefix_or_abort(&resource_key);
    key.append(resource_part);
    key
}

/// Generate a threshold-based resource key
/// Example: "resource:/threshold/3of5/vault/spend/0x2::sui::SUI"
public fun with_threshold(required: u64, total: u64, resource_key: String): String {
    let mut key = string::utf8(RESOURCE_PREFIX);
    key.append(string::utf8(b"threshold/"));
    key.append(required.to_string());
    key.append(string::utf8(b"of"));
    key.append(total.to_string());
    key.append(string::utf8(b"/"));
    let resource_part = strip_prefix_or_abort(&resource_key);
    key.append(resource_part);
    key
}

// === Utility Functions ===

/// Check if a key represents a critical resource
public fun is_critical_resource(key: &String): bool {
    key.index_of(&string::utf8(b"emergency")) != key.length() ||
    key.index_of(&string::utf8(b"restrict")) != key.length() ||
    key.index_of(&string::utf8(b"mint")) != key.length() ||
    key.index_of(&string::utf8(b"security")) != key.length()
}

/// Extract the category from a resource key
public fun get_category(key: &String): String {
    // Assumes valid "resource:/..."
    if (!is_valid(key)) return string::utf8(b"unknown");
    let start = RESOURCE_PREFIX_LEN;
    // Search for the next "/" after the prefix
    let tail = key.substring(start, key.length());
    let next = tail.index_of(&string::utf8(b"/"));
    if (next == tail.length()) {
        // no more slashes → whole tail is the category
        tail
    } else {
        // category is the substring up to the slash
        key.substring(start, start + next)
    }
}

// === Tests ===

#[test]
fun test_resource_keys() {
    use sui::test_utils::assert_eq;
    
    // Test package keys
    let pkg_key = package_upgrade(@0x123, b"my_package".to_string());
    assert_eq(pkg_key, b"resource:/package/upgrade/0000000000000000000000000000000000000000000000000000000000000123::my_package".to_string());
    
    // Test vault keys
    let vault_key = vault_spend_by_type(type_name::get<sui::sui::SUI>());
    assert!(vault_key.length() > 0);
    
    // Test role-based keys
    let admin_vault = for_role(
        b"admin".to_string(),
        b"resource:/vault/spend/0x2::sui::SUI".to_string()
    );
    assert_eq(admin_vault, b"resource:/role/admin/vault/spend/0x2::sui::SUI".to_string());
    
    // Test critical resource detection
    let emergency_key = governance_emergency();
    assert!(is_critical_resource(&emergency_key));
}

#[test]
fun test_category_extraction() {
    use sui::test_utils::assert_eq;
    
    let pkg_key = package_upgrade(@0x123, b"test".to_string());
    let category = get_category(&pkg_key);
    assert_eq(category, b"package".to_string());
    
    let vault_key = vault_config();
    let vault_cat = get_category(&vault_key);
    assert_eq(vault_cat, b"vault".to_string());
}

#[test]
fun test_wildcard_and_matches() {
    let k = vault_config();
    let all = any();
    assert!(matches(&all, &k));

    let p = wildcard_prefix(vault_config());
    assert!(matches(&p, &k));
    assert!(!matches(&p, &package_publish()));
}

#[test]
fun test_ext_and_other() {
    let k1 = ext(@0x123, b"m".to_string(), b"a".to_string());
    let k2 = other(b"my/custom/path".to_string());
    assert!(is_valid(&k1));
    assert!(is_valid(&k2));
}