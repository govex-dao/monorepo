/// Module registry for efficient action routing
/// Uses numeric IDs instead of string comparison for gas efficiency
module futarchy_actions::module_registry;

// === Constants ===

// Module IDs for routing
public fun CONFIG_MODULE(): u8 { 1 }
public fun LIQUIDITY_MODULE(): u8 { 2 }
public fun VAULT_MODULE(): u8 { 3 }
public fun COUNCIL_MODULE(): u8 { 4 }
public fun AGREEMENT_MODULE(): u8 { 5 }
public fun DISSOLUTION_MODULE(): u8 { 6 }
public fun ORACLE_MODULE(): u8 { 7 }
public fun STREAM_MODULE(): u8 { 8 }
public fun COMMITMENT_MODULE(): u8 { 9 }
public fun POLICY_MODULE(): u8 { 10 }

// Action type IDs within modules
// Config actions
public fun SET_PROPOSALS_ENABLED(): u8 { 1 }
public fun UPDATE_NAME(): u8 { 2 }
public fun UPDATE_METADATA(): u8 { 3 }
public fun UPDATE_TRADING_PARAMS(): u8 { 4 }
public fun UPDATE_TWAP_CONFIG(): u8 { 5 }
public fun UPDATE_GOVERNANCE(): u8 { 6 }

// Liquidity actions
public fun ADD_LIQUIDITY(): u8 { 1 }
public fun REMOVE_LIQUIDITY(): u8 { 2 }
public fun CREATE_POOL(): u8 { 3 }

// Council actions
public fun CREATE_COUNCIL(): u8 { 1 }
public fun UPDATE_MEMBERSHIP(): u8 { 2 }
public fun APPROVE_GENERIC(): u8 { 3 }

// Helper function to pack module and action into single u16
public fun pack_action_id(module_id: u8, action_id: u8): u16 {
    ((module_id as u16) << 8) | (action_id as u16)
}

// Helper to unpack
public fun unpack_action_id(packed: u16): (u8, u8) {
    let module_id = ((packed >> 8) as u8);
    let action_id = ((packed & 0xFF) as u8);
    (module_id, action_id)
}