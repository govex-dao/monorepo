/// Maps all actions to their resource patterns for policy management
/// This provides a systematic way to configure policies for all actions
module futarchy_multisig::action_resource_mapping;

use std::vector;

// === Pattern Generation Functions ===

/// Get all Move Framework action patterns
public fun move_framework_patterns(): vector<vector<u8>> {
    vector[
        // Vault actions
        b"treasury/spend",
        b"treasury/deposit",
        b"treasury/transfer",
        
        // Currency actions
        b"treasury/mint",
        b"treasury/burn",
        
        // Owned actions
        b"ownership/transfer",
        b"ownership/withdraw",
        
        // Package upgrade actions
        b"upgrade/package",
        b"upgrade/restrict",
        b"upgrade/commit",
    ]
}

/// Get all Futarchy governance action patterns
public fun futarchy_governance_patterns(): vector<vector<u8>> {
    vector[
        // Core governance
        b"governance/create_proposal",
        b"governance/update_config",
        b"governance/set_pattern_policy",
        b"governance/set_object_policy",
        b"governance/register_council",
        b"governance/remove_pattern_policy",
        b"governance/remove_object_policy",
        
        // Platform fees
        b"governance/update_dao_fee",
        b"governance/update_proposal_fee",
        b"governance/update_verification_fee",
        b"governance/apply_fee_discount",
    ]
}

/// Get all Futarchy liquidity action patterns
public fun futarchy_liquidity_patterns(): vector<vector<u8>> {
    vector[
        b"liquidity/create_pool",
        b"liquidity/update_parameters",
        b"liquidity/withdraw_liquidity",
        b"liquidity/add_liquidity",
        b"liquidity/enable_trading",
        b"liquidity/disable_trading",
    ]
}

/// Get all Futarchy oracle action patterns
public fun futarchy_oracle_patterns(): vector<vector<u8>> {
    vector[
        b"oracle/conditional_mint",
        b"oracle/tiered_mint",
        b"oracle/read_price",
        b"oracle/update_oracle",
    ]
}

/// Get all Futarchy dissolution action patterns
public fun futarchy_dissolution_patterns(): vector<vector<u8>> {
    vector[
        b"dissolution/initiate",
        b"dissolution/finalize",
        b"dissolution/distribute",
        b"dissolution/claim",
    ]
}

/// Get all Futarchy stream action patterns
public fun futarchy_stream_patterns(): vector<vector<u8>> {
    vector[
        b"stream/create",
        b"stream/cancel",
        b"stream/withdraw",
        b"stream/update_recipient",
    ]
}

/// Get all Futarchy operating agreement patterns
public fun futarchy_legal_patterns(): vector<vector<u8>> {
    vector[
        b"legal/operating_agreement",
        b"legal/update_terms",
        b"legal/update_signatories",
    ]
}

/// Get all Futarchy commitment patterns
public fun futarchy_commitment_patterns(): vector<vector<u8>> {
    vector[
        b"commitment/create",
        b"commitment/execute",
        b"commitment/withdraw",
        b"commitment/update_recipient",
    ]
}

/// Get all Futarchy security patterns
public fun futarchy_security_patterns(): vector<vector<u8>> {
    vector[
        b"security/emergency_pause",
        b"security/emergency_resume",
        b"security/update_membership",
        b"security/rotate_keys",
    ]
}

/// Get ALL patterns (comprehensive list)
public fun all_patterns(): vector<vector<u8>> {
    let mut patterns = vector::empty();
    
    // Add all Move Framework patterns
    vector::append(&mut patterns, move_framework_patterns());
    
    // Add all Futarchy patterns
    vector::append(&mut patterns, futarchy_governance_patterns());
    vector::append(&mut patterns, futarchy_liquidity_patterns());
    vector::append(&mut patterns, futarchy_oracle_patterns());
    vector::append(&mut patterns, futarchy_dissolution_patterns());
    vector::append(&mut patterns, futarchy_stream_patterns());
    vector::append(&mut patterns, futarchy_legal_patterns());
    vector::append(&mut patterns, futarchy_commitment_patterns());
    vector::append(&mut patterns, futarchy_security_patterns());
    
    patterns
}

/// Get critical patterns that should always require additional approval
public fun critical_patterns(): vector<vector<u8>> {
    vector[
        // Most critical - changing the approval system itself
        b"governance/set_pattern_policy",
        b"governance/set_object_policy",
        b"governance/register_council",
        
        // Package upgrades
        b"upgrade/package",
        b"upgrade/restrict",
        
        // Treasury minting
        b"treasury/mint",
        
        // Security council membership
        b"security/update_membership",
        
        // Emergency actions
        b"security/emergency_pause",
        b"security/emergency_resume",
        
        // Dissolution
        b"dissolution/initiate",
        b"dissolution/finalize",
    ]
}

/// Get patterns that typically need Treasury Council approval
public fun treasury_patterns(): vector<vector<u8>> {
    vector[
        b"treasury/spend",
        b"treasury/mint",
        b"treasury/burn",
        b"treasury/transfer",
        b"stream/create",
        b"oracle/conditional_mint",
        b"oracle/tiered_mint",
    ]
}

/// Get patterns that typically need Technical Council approval
public fun technical_patterns(): vector<vector<u8>> {
    vector[
        b"upgrade/package",
        b"upgrade/restrict",
        b"upgrade/commit",
        b"liquidity/update_parameters",
        b"oracle/update_oracle",
    ]
}

/// Get patterns that typically need Legal Council approval
public fun legal_patterns(): vector<vector<u8>> {
    vector[
        b"legal/operating_agreement",
        b"legal/update_terms",
        b"legal/update_signatories",
    ]
}