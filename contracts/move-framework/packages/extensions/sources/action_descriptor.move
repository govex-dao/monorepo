module account_extensions::action_descriptor {
    use std::option::{Self, Option};
    use std::vector;
    use sui::object::{Self, ID};

    /// Simple descriptor for determining approval requirements
    public struct ActionDescriptor has copy, drop, store {
        /// Category as bytes (e.g., b"treasury", b"governance")
        category: vector<u8>,
        
        /// Action type as bytes (e.g., b"spend", b"mint")
        action_type: vector<u8>,
        
        /// Target object if applicable (for object-specific policies)
        target_object: Option<ID>,
    }
    
    /// Constructor
    public fun new(
        category: vector<u8>,
        action_type: vector<u8>,
    ): ActionDescriptor {
        ActionDescriptor {
            category,
            action_type,
            target_object: option::none(),
        }
    }
    
    /// Builder: add target object
    public fun with_target(mut self: ActionDescriptor, target: ID): ActionDescriptor {
        self.target_object = option::some(target);
        self
    }
    
    /// Add target object (mutating)
    public fun add_target(self: &mut ActionDescriptor, target: ID) {
        self.target_object = option::some(target);
    }
    
    /// Add target address (converts to ID)
    public fun add_target_address(self: &mut ActionDescriptor, addr: address) {
        self.target_object = option::some(object::id_from_address(addr));
    }
    
    /// Create with target
    public fun new_with_target(
        category: vector<u8>,
        action_type: vector<u8>,
        target: ID,
    ): ActionDescriptor {
        ActionDescriptor {
            category,
            action_type,
            target_object: option::some(target),
        }
    }
    
    /// Create with target address
    public fun new_with_target_address(
        category: vector<u8>,
        action_type: vector<u8>,
        addr: address,
    ): ActionDescriptor {
        ActionDescriptor {
            category,
            action_type,
            target_object: option::some(object::id_from_address(addr)),
        }
    }
    
    /// Getters
    public fun category(self: &ActionDescriptor): vector<u8> { 
        self.category 
    }
    
    public fun action_type(self: &ActionDescriptor): vector<u8> { 
        self.action_type 
    }
    
    public fun target_object(self: &ActionDescriptor): &Option<ID> { 
        &self.target_object 
    }
    
    /// Create pattern for matching (category/action_type)
    public fun make_pattern(self: &ActionDescriptor): vector<u8> {
        let mut pattern = vector::empty();
        vector::append(&mut pattern, self.category);
        vector::push_back(&mut pattern, b"/"[0]);
        vector::append(&mut pattern, self.action_type);
        pattern
    }
}