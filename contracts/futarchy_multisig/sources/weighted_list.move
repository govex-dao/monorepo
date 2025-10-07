/// A generic, reusable module for managing weighted lists of addresses.
/// This eliminates duplication between weighted multisig governance and payment beneficiaries.
module futarchy_multisig::weighted_list;

use std::vector;
use sui::vec_map::{Self, VecMap};

// === Errors ===
const EInvalidArguments: u64 = 1;
const EDuplicateMember: u64 = 2;
const EEmptyMemberList: u64 = 3;
const EWeightTooLarge: u64 = 4;
const EWeightOverflow: u64 = 5;
const ENotMember: u64 = 6;
const EListIsImmutable: u64 = 7;
const EInvariantViolation: u64 = 8;
const EInvariantTotalWeightMismatch: u64 = 9;
const EInvariantZeroWeight: u64 = 10;
const EInvariantWeightTooLarge: u64 = 11;
const EInvariantEmptyList: u64 = 12;

// === Constants ===
const MAX_MEMBER_WEIGHT: u64 = 1_000_000;      // 1 million max weight per member
const MAX_TOTAL_WEIGHT: u64 = 1_000_000_000;   // 1 billion max total

/// A generic, reusable struct for managing a list of addresses and their weights.
public struct WeightedList has store, copy, drop {
    /// Maps member addresses to their assigned weight.
    members: VecMap<address, u64>,
    /// The sum of all members' weights.
    total_weight: u64,
    /// Whether this list can be modified after creation.
    is_immutable: bool,
}

/// Creates a new mutable WeightedList from parallel vectors of addresses and weights.
/// Enforces validation rules for consistency and security.
public fun new(
    addresses: vector<address>,
    weights: vector<u64>
): WeightedList {
    new_with_immutability(addresses, weights, false)
}

/// Creates a new immutable WeightedList that cannot be modified after creation.
public fun new_immutable(
    addresses: vector<address>,
    weights: vector<u64>
): WeightedList {
    new_with_immutability(addresses, weights, true)
}

/// Creates a new WeightedList with specified mutability.
/// Enforces validation rules for consistency and security.
public fun new_with_immutability(
    addresses: vector<address>,
    weights: vector<u64>,
    is_immutable: bool
): WeightedList {
    assert!(addresses.length() == weights.length(), EInvalidArguments);
    assert!(addresses.length() > 0, EEmptyMemberList);

    let mut member_map = vec_map::empty();
    let mut total_weight = 0u64;

    let mut i = 0;
    while (i < addresses.length()) {
        let member = *vector::borrow(&addresses, i);
        let weight = *vector::borrow(&weights, i);

        assert!(!member_map.contains(&member), EDuplicateMember);
        assert!(weight > 0, EInvalidArguments);
        assert!(weight <= MAX_MEMBER_WEIGHT, EWeightTooLarge);
        assert!(total_weight <= MAX_TOTAL_WEIGHT - weight, EWeightOverflow);

        member_map.insert(member, weight);
        total_weight = total_weight + weight;
        i = i + 1;
    };

    let list = WeightedList {
        members: member_map,
        total_weight,
        is_immutable,
    };
    
    // Verify invariants before returning
    check_invariants(&list);
    list
}

/// Creates a mutable WeightedList from a single address with weight 1.
/// Useful for simple single-recipient cases.
public fun singleton(addr: address): WeightedList {
    singleton_with_immutability(addr, false)
}

/// Creates an immutable WeightedList from a single address with weight 1.
public fun singleton_immutable(addr: address): WeightedList {
    singleton_with_immutability(addr, true)
}

/// Creates a WeightedList from a single address with specified mutability.
fun singleton_with_immutability(addr: address, is_immutable: bool): WeightedList {
    let mut member_map = vec_map::empty();
    member_map.insert(addr, 1);
    
    let list = WeightedList {
        members: member_map,
        total_weight: 1,
        is_immutable,
    };
    
    // Verify invariants before returning
    check_invariants(&list);
    list
}

// === Public Accessor Functions ===

/// Returns the total weight of all members in the list.
public fun total_weight(list: &WeightedList): u64 {
    list.total_weight
}

/// Checks if a given address is a member of the list.
public fun contains(list: &WeightedList, addr: &address): bool {
    list.members.contains(addr)
}

/// Gets the weight of a specific member. Aborts if the address is not a member.
public fun get_weight(list: &WeightedList, addr: &address): u64 {
    assert!(contains(list, addr), ENotMember);
    *list.members.get(addr)
}

/// Gets the weight of a specific member, returning 0 if not a member.
public fun get_weight_or_zero(list: &WeightedList, addr: &address): u64 {
    if (contains(list, addr)) {
        *list.members.get(addr)
    } else {
        0
    }
}

/// Returns an immutable reference to the underlying VecMap of members.
public fun members(list: &WeightedList): &VecMap<address, u64> {
    &list.members
}

/// Returns the number of members in the list.
public fun size(list: &WeightedList): u64 {
    list.members.size()
}

/// Returns true if the list is empty.
public fun is_empty(list: &WeightedList): bool {
    list.members.is_empty()
}

/// Returns true if the list is immutable (cannot be modified).
public fun is_immutable(list: &WeightedList): bool {
    list.is_immutable
}

/// Calculates the proportional share for a given weight.
/// Returns the amount that should be allocated based on weight/total_weight ratio.
/// Useful for payment distributions.
public fun calculate_share(list: &WeightedList, member_weight: u64, total_amount: u64): u64 {
    assert!(member_weight <= list.total_weight, EInvalidArguments);
    
    // Prevent division by zero
    if (list.total_weight == 0) {
        return 0
    };
    
    // Calculate proportional share: (member_weight * total_amount) / total_weight
    // Use u128 to prevent overflow during multiplication
    let share_u128 = ((member_weight as u128) * (total_amount as u128)) / (list.total_weight as u128);
    (share_u128 as u64)
}

/// Calculates the share for a specific member address.
public fun calculate_member_share(list: &WeightedList, addr: &address, total_amount: u64): u64 {
    let weight = get_weight(list, addr);
    calculate_share(list, weight, total_amount)
}

/// Get all members as parallel vectors of addresses and weights.
/// Useful for iteration or transformation operations.
public fun get_members_and_weights(list: &WeightedList): (vector<address>, vector<u64>) {
    list.members.into_keys_values()
}

/// Check if two weighted lists are equal (same members with same weights).
public fun equals(list1: &WeightedList, list2: &WeightedList): bool {
    if (list1.total_weight != list2.total_weight) {
        return false
    };
    
    if (list1.members.size() != list2.members.size()) {
        return false
    };
    
    let (keys1, _) = list1.members.into_keys_values();
    let mut i = 0;
    while (i < keys1.length()) {
        let addr = vector::borrow(&keys1, i);
        if (!list2.members.contains(addr)) {
            return false
        };
        if (list1.members.get(addr) != list2.members.get(addr)) {
            return false
        };
        i = i + 1;
    };
    
    true
}

// === Mutation Functions (for mutable lists) ===

/// Update the entire weighted list with new members and weights.
/// This replaces the entire list atomically.
/// Aborts if the list is immutable.
public fun update(
    list: &mut WeightedList,
    addresses: vector<address>,
    weights: vector<u64>
) {
    assert!(!list.is_immutable, EListIsImmutable);
    
    // Create a new list with validation
    let new_list = new(addresses, weights);
    
    // Replace the old list with the new one
    list.members = new_list.members;
    list.total_weight = new_list.total_weight;
    
    // Verify invariants after modification
    check_invariants(list);
}

/// Add or update a single member's weight.
/// If the member exists, their weight is updated. Otherwise, they are added.
/// Aborts if the list is immutable.
public fun set_member_weight(
    list: &mut WeightedList,
    addr: address,
    new_weight: u64
) {
    assert!(!list.is_immutable, EListIsImmutable);
    assert!(new_weight > 0, EInvalidArguments);
    assert!(new_weight <= MAX_MEMBER_WEIGHT, EWeightTooLarge);
    
    // Get the old weight if member exists
    let old_weight = if (list.members.contains(&addr)) {
        let weight = *list.members.get(&addr);
        list.members.remove(&addr);
        weight
    } else {
        0
    };
    
    // Calculate new total weight
    let new_total = list.total_weight - old_weight + new_weight;
    assert!(new_total <= MAX_TOTAL_WEIGHT, EWeightOverflow);
    
    // Update member and total
    list.members.insert(addr, new_weight);
    list.total_weight = new_total;
    
    // Verify invariants after modification
    check_invariants(list);
}

/// Remove a member from the list.
/// Aborts if the member doesn't exist, if removing would empty the list, or if the list is immutable.
public fun remove_member(
    list: &mut WeightedList,
    addr: address
) {
    assert!(!list.is_immutable, EListIsImmutable);
    assert!(list.members.contains(&addr), ENotMember);
    assert!(list.members.size() > 1, EEmptyMemberList); // Don't allow empty list
    
    let (_, weight) = list.members.remove(&addr);
    list.total_weight = list.total_weight - weight;
    
    // Verify invariants after modification
    check_invariants(list);
}

// === Invariant Checking ===

/// Check all invariants for a WeightedList.
/// This function is called after any modification to ensure data consistency.
/// Invariants:
/// 1. The list must not be empty
/// 2. All weights must be > 0 and <= MAX_MEMBER_WEIGHT
/// 3. The sum of all weights must equal total_weight
/// 4. The total_weight must be <= MAX_TOTAL_WEIGHT
/// 5. No duplicate members (guaranteed by VecMap structure)
public fun check_invariants(list: &WeightedList) {
    // Invariant 1: List must not be empty
    assert!(!list.members.is_empty(), EInvariantEmptyList);
    
    // Calculate actual total weight and verify individual weights
    let mut calculated_total = 0u64;
    let (addresses, weights) = list.members.into_keys_values();
    
    let mut i = 0;
    while (i < weights.length()) {
        let weight = *vector::borrow(&weights, i);
        
        // Invariant 2a: Each weight must be > 0
        assert!(weight > 0, EInvariantZeroWeight);
        
        // Invariant 2b: Each weight must be <= MAX_MEMBER_WEIGHT
        assert!(weight <= MAX_MEMBER_WEIGHT, EInvariantWeightTooLarge);
        
        // Sum up for total weight check
        calculated_total = calculated_total + weight;
        i = i + 1;
    };
    
    // Invariant 3: Sum of weights must equal stored total_weight
    assert!(calculated_total == list.total_weight, EInvariantTotalWeightMismatch);
    
    // Invariant 4: Total weight must be within bounds
    assert!(list.total_weight <= MAX_TOTAL_WEIGHT, EInvariantViolation);
    
    // Invariant 5: No duplicate members is guaranteed by VecMap structure
    // VecMap inherently prevents duplicate keys
}

/// Verify invariants without aborting - useful for debugging.
/// Returns true if all invariants hold, false otherwise.
#[test_only]
public fun verify_invariants(list: &WeightedList): bool {
    // Check if empty
    if (list.members.is_empty()) {
        return false
    };
    
    // Calculate and verify weights
    let mut calculated_total = 0u64;
    let (_, weights) = list.members.into_keys_values();
    
    let mut i = 0;
    while (i < weights.length()) {
        let weight = *vector::borrow(&weights, i);
        
        if (weight == 0 || weight > MAX_MEMBER_WEIGHT) {
            return false
        };
        
        calculated_total = calculated_total + weight;
        i = i + 1;
    };
    
    // Check totals match and are within bounds
    calculated_total == list.total_weight && list.total_weight <= MAX_TOTAL_WEIGHT
}

// === Test Helpers ===

#[test_only]
/// Create a test weighted list with two members for testing.
public fun test_list(): WeightedList {
    new(
        vector[@0x1, @0x2],
        vector[30, 70]
    )
}

#[test_only]
/// Create an immutable test weighted list.
public fun test_list_immutable(): WeightedList {
    new_immutable(
        vector[@0x1, @0x2],
        vector[30, 70]
    )
}

#[test_only]
/// Get the maximum member weight constant for testing.
public fun max_member_weight(): u64 {
    MAX_MEMBER_WEIGHT
}

#[test_only]
/// Get the maximum total weight constant for testing.
public fun max_total_weight(): u64 {
    MAX_TOTAL_WEIGHT
}