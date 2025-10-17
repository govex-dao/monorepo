// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

module futarchy_multisig::descriptor_analyzer {
    use std::vector;
    use std::option::{Self, Option};
    use std::type_name::TypeName;
    use sui::object::ID;
    use account_protocol::intents::{Self, Intent};
    use futarchy_multisig::policy_registry::{Self, PolicyRegistry};

    /// Approval requirement result
    public struct ApprovalRequirement has copy, drop, store {
        needs_dao: bool,
        needs_council: bool,
        council_id: Option<ID>,
        mode: u8, // 0=DAO_ONLY, 1=COUNCIL_ONLY, 2=DAO_OR_COUNCIL, 3=DAO_AND_COUNCIL
    }

    /// Analyze all actions in an intent to determine approval requirements
    public fun analyze_requirements<Outcome>(
        intent: &Intent<Outcome>,
        registry: &PolicyRegistry,
    ): ApprovalRequirement {
        let action_specs = intents::action_specs(intent);

        let mut needs_dao = false;
        let mut needs_council = false;
        let mut council_id: Option<ID> = option::none();
        let mut mode = 0u8; // Default DAO_ONLY

        // Check each action type
        let mut i = 0;
        while (i < vector::length(action_specs)) {
            let spec = vector::borrow(action_specs, i);
            let action_type = intents::action_spec_type(spec);
            
            // Check if this type has a policy
            if (policy_registry::type_needs_council(registry, action_type)) {
                let type_mode = policy_registry::get_type_mode(registry, action_type);
                let type_council = policy_registry::get_type_council(registry, action_type);
                
                // Update requirements based on this type's policy
                if (type_mode != 0) { // Not DAO_ONLY
                    needs_council = true;
                    if (option::is_some(&type_council)) {
                        council_id = type_council;
                    };
                    mode = type_mode;
                }
            };
            
            // Note: Object-specific policies would need to be checked separately
            // This would require accessing the actual action data, which we can't do generically
            // For now, type-based policies are the primary mechanism
            
            i = i + 1;
        };
        
        // Determine if DAO approval is needed based on mode
        // Mode 0 (DAO_ONLY) or 2 (DAO_OR) or 3 (DAO_AND) need DAO
        // Mode 1 (COUNCIL_ONLY) doesn't need DAO
        needs_dao = (mode == 0 || mode == 2 || mode == 3);
        
        ApprovalRequirement {
            needs_dao,
            needs_council,
            council_id,
            mode,
        }
    }
    
    /// Check if approvals are satisfied
    public fun check_approvals(
        requirement: &ApprovalRequirement,
        dao_approved: bool,
        council_approved: bool,
    ): bool {
        let mode = requirement.mode;
        
        if (mode == 0) { // DAO_ONLY
            dao_approved
        } else if (mode == 1) { // COUNCIL_ONLY (specific council, no DAO)
            council_approved
        } else if (mode == 2) { // DAO_OR_COUNCIL
            dao_approved || council_approved
        } else if (mode == 3) { // DAO_AND_COUNCIL
            dao_approved && council_approved
        } else {
            false
        }
    }
    
    // Getters
    public fun needs_dao(req: &ApprovalRequirement): bool { req.needs_dao }
    public fun needs_council(req: &ApprovalRequirement): bool { req.needs_council }
    public fun council_id(req: &ApprovalRequirement): &Option<ID> { &req.council_id }
    public fun mode(req: &ApprovalRequirement): u8 { req.mode }
}