module futarchy_multisig::descriptor_analyzer {
    use std::vector;
    use std::option::{Self, Option};
    use sui::object::ID;
    use account_extensions::action_descriptor::{Self, ActionDescriptor};
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
        let descriptors = intents::action_descriptors(intent);
        
        let mut needs_dao = false;
        let mut needs_council = false;
        let mut council_id: Option<ID> = option::none();
        let mut mode = 0u8; // Default DAO_ONLY
        
        // Check each action descriptor
        let mut i = 0;
        while (i < vector::length(descriptors)) {
            let desc = vector::borrow(descriptors, i);
            let pattern = action_descriptor::make_pattern(desc);
            
            // Check if this pattern has a policy
            if (policy_registry::pattern_needs_council(registry, pattern)) {
                let pattern_mode = policy_registry::get_pattern_mode(registry, pattern);
                let pattern_council = policy_registry::get_pattern_council(registry, pattern);
                
                // Update requirements based on this pattern's policy
                if (pattern_mode != 0) { // Not DAO_ONLY
                    needs_council = true;
                    if (option::is_some(&pattern_council)) {
                        council_id = pattern_council;
                    };
                    mode = pattern_mode;
                }
            };
            
            // Check if target object has a policy
            let target = action_descriptor::target_object(desc);
            if (option::is_some(target)) {
                let object_id = *option::borrow(target);
                if (policy_registry::object_needs_council(registry, object_id)) {
                    let object_mode = policy_registry::get_object_mode(registry, object_id);
                    let object_council = policy_registry::get_object_council(registry, object_id);
                    
                    // Object policies override pattern policies
                    if (object_mode != 0) { // Not DAO_ONLY
                        needs_council = true;
                        if (option::is_some(&object_council)) {
                            council_id = object_council;
                        };
                        mode = object_mode;
                    }
                }
            };
            
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