/// Manages TreasuryCap storage and permissions for futarchy DAOs
module futarchy::capability_manager;

// === Imports ===
use futarchy::execution_context::{Self, ProposalExecutionContext};
use std::{
    type_name::{Self, TypeName},
};
use sui::{
    dynamic_field as df,
    coin::TreasuryCap,
    table::{Self, Table},
    event,
};

// === Errors ===
const ECapabilityNotFound: u64 = 0;
const ECapabilityAlreadyExists: u64 = 1;
const EInvalidRules: u64 = 2;
const EMintDisabled: u64 = 3;
const EBurnDisabled: u64 = 4;
const EExceedsMaxSupply: u64 = 5;
const EExceedsMaxMintPerProposal: u64 = 6;
const EMintCooldownNotMet: u64 = 7;
const EActionAlreadyExecuted: u64 = 8;
const EExternalBurnNotSupported: u64 = 9;
const EInvalidAdminCap: u64 = 10;
const ECapabilityLocked: u64 = 11;

// === Structs ===

/// Manages treasury capabilities for a DAO
public struct CapabilityManager has key {
    id: UID,
    /// Maps TypeName to stored capabilities
    capabilities: Table<TypeName, CapabilityInfo>,
    /// SECURITY FIX: Enhanced tracking with execution count to prevent replay attacks
    /// Tracks (ProposalID, TypeName) -> execution count
    executed_mints: Table<ID, Table<TypeName, u64>>,
    /// Tracks (ProposalID, TypeName) -> execution count for burn actions
    executed_burns: Table<ID, Table<TypeName, u64>>,
}

/// Information about a stored capability
public struct CapabilityInfo has store, copy, drop {
    /// Whether the capability is currently stored
    exists: bool,
    /// Timestamp when capability was deposited
    deposited_at: u64,
    /// Address that deposited the capability
    depositor: address,
}

/// Storage wrapper for TreasuryCap with access control
public struct CapabilityStorage<phantom T> has store {
    cap: TreasuryCap<T>,
    locked: bool,
    lock_until: Option<u64>,
    /// Track capability deposit time for cooldown calculations
    deposited_at: u64,
}

/// Key for storing rules in dynamic fields
public struct RulesKey<phantom T> has copy, drop, store {
    coin_type: TypeName,
}

/// Rules for minting and burning operations
/// Complex rules are necessary for safe token management
public struct MintBurnRules has store, copy, drop {
    /// Maximum supply that can ever be minted (None = unlimited)
    max_supply: Option<u64>,
    /// Total amount minted so far
    total_minted: u64,
    /// Total amount burned so far
    total_burned: u64,
    /// Whether minting is enabled
    can_mint: bool,
    /// Whether burning is enabled
    can_burn: bool,
    /// Maximum amount that can be minted per proposal
    max_mint_per_proposal: Option<u64>,
    /// Cooldown period between mints in milliseconds
    mint_cooldown_ms: u64,
    /// Last mint timestamp
    last_mint_timestamp: u64,
}

// === Events ===

public struct CapabilityDeposited has copy, drop {
    manager_id: ID,
    coin_type: TypeName,
    depositor: address,
    max_supply: Option<u64>,
}

public struct CapabilityRemoved has copy, drop {
    manager_id: ID,
    coin_type: TypeName,
    remover: address,
}

public struct RulesUpdated has copy, drop {
    manager_id: ID,
    coin_type: TypeName,
    can_mint: bool,
    can_burn: bool,
}

public struct TokensMinted has copy, drop {
    manager_id: ID,
    coin_type: TypeName,
    amount: u64,
    total_minted: u64,
    recipient: address,
    proposal_id: ID,
}

public struct TokensBurned has copy, drop {
    manager_id: ID,
    coin_type: TypeName,
    amount: u64,
    total_burned: u64,
    proposal_id: ID,
}

// === Public Functions ===

/// Create a new capability manager
public fun new(ctx: &mut TxContext): CapabilityManager {
    CapabilityManager {
        id: object::new(ctx),
        capabilities: table::new(ctx),
        executed_mints: table::new(ctx),
        executed_burns: table::new(ctx),
    }
}

/// Initialize capability manager (shares it)
public fun initialize(ctx: &mut TxContext): ID {
    let manager = new(ctx);
    let manager_id = object::id(&manager);
    transfer::share_object(manager);
    manager_id
}

/// Initialize capability manager with a TreasuryCap in one atomic transaction
public fun initialize_with_cap<T: drop>(
    cap: TreasuryCap<T>,
    rules: MintBurnRules,
    clock: &sui::clock::Clock,
    ctx: &mut TxContext,
): ID {
    let mut manager = new(ctx);
    let manager_id = object::id(&manager);
    
    // Deposit the capability before sharing
    let coin_type = type_name::get<T>();
    
    // Store capability info
    let info = CapabilityInfo {
        exists: true,
        deposited_at: clock.timestamp_ms(),
        depositor: ctx.sender(),
    };
    manager.capabilities.add(coin_type, info);
    
    // Store the capability using dynamic fields
    let storage = CapabilityStorage {
        cap,
        locked: true,
        lock_until: option::none(),
        deposited_at: clock.timestamp_ms(),
    };
    df::add(&mut manager.id, coin_type, storage);
    
    // Store the rules using a compound key
    let rules_key = RulesKey<T> { coin_type };
    df::add(&mut manager.id, rules_key, rules);
    
    event::emit(CapabilityDeposited {
        manager_id,
        coin_type,
        depositor: ctx.sender(),
        max_supply: rules.max_supply,
    });
    
    // Now share the manager
    transfer::share_object(manager);
    manager_id
}

/// Deposit a TreasuryCap into the manager
public fun deposit_capability<T: drop>(
    manager: &mut CapabilityManager,
    cap: TreasuryCap<T>,
    rules: MintBurnRules,
    clock: &sui::clock::Clock,
    ctx: &mut TxContext,
) {
    let coin_type = type_name::get<T>();
    
    // Check if capability already exists
    assert!(!has_capability<T>(manager), ECapabilityAlreadyExists);
    
    // Store capability info
    let info = CapabilityInfo {
        exists: true,
        deposited_at: clock.timestamp_ms(),
        depositor: ctx.sender(),
    };
    manager.capabilities.add(coin_type, info);
    
    // Store the capability using dynamic fields
    let storage = CapabilityStorage {
        cap,
        locked: true,
        lock_until: option::none(),
        deposited_at: clock.timestamp_ms(),
    };
    df::add(&mut manager.id, coin_type, storage);
    
    // Store the rules using a compound key
    let rules_key = RulesKey<T> { coin_type };
    df::add(&mut manager.id, rules_key, rules);
    
    event::emit(CapabilityDeposited {
        manager_id: object::id(manager),
        coin_type,
        depositor: ctx.sender(),
        max_supply: rules.max_supply,
    });
}

/// Get a mutable reference to a capability for minting
public fun borrow_capability_mut<T: drop>(
    manager: &mut CapabilityManager,
    clock: &sui::clock::Clock,
): &mut TreasuryCap<T> {
    let coin_type = type_name::get<T>();
    assert!(has_capability<T>(manager), ECapabilityNotFound);
    
    let storage: &mut CapabilityStorage<T> = df::borrow_mut(&mut manager.id, coin_type);
    
    // SECURITY FIX: Check if capability is locked
    if (storage.locked && storage.lock_until.is_some()) {
        let lock_until = *storage.lock_until.borrow();
        assert!(clock.timestamp_ms() >= lock_until, ECapabilityLocked);
        // Unlock if time has passed
        storage.locked = false;
        storage.lock_until = option::none();
    };
    
    &mut storage.cap
}

/// Get rules for a coin type
public fun get_rules<T: drop>(manager: &CapabilityManager): &MintBurnRules {
    let coin_type = type_name::get<T>();
    let rules_key = RulesKey<T> { coin_type };
    df::borrow(&manager.id, rules_key)
}

/// Get mutable rules for updating
public fun get_rules_mut<T: drop>(manager: &mut CapabilityManager): &mut MintBurnRules {
    let coin_type = type_name::get<T>();
    let rules_key = RulesKey<T> { coin_type };
    df::borrow_mut(&mut manager.id, rules_key)
}

/// Update mint/burn permissions (admin only)
public fun update_permissions<T: drop>(
    manager: &mut CapabilityManager,
    can_mint: bool,
    can_burn: bool,
    admin_cap: &AdminCap,
) {
    // SECURITY FIX: Verify admin cap is for this manager
    assert!(admin_cap.manager_id == object::id(manager), EInvalidAdminCap);
    
    let rules = get_rules_mut<T>(manager);
    rules.can_mint = can_mint;
    rules.can_burn = can_burn;
    
    event::emit(RulesUpdated {
        manager_id: object::id(manager),
        coin_type: type_name::get<T>(),
        can_mint,
        can_burn,
    });
}

/// Check if a capability exists
public fun has_capability<T: drop>(manager: &CapabilityManager): bool {
    let coin_type = type_name::get<T>();
    manager.capabilities.contains(coin_type) && 
    df::exists_(&manager.id, coin_type)
}

/// Get capability info
public fun get_capability_info<T: drop>(manager: &CapabilityManager): &CapabilityInfo {
    let coin_type = type_name::get<T>();
    manager.capabilities.borrow(coin_type)
}

/// Get supply information
public fun get_supply_info<T: drop>(manager: &CapabilityManager): (u64, u64, Option<u64>) {
    if (has_capability<T>(manager)) {
        let rules = get_rules<T>(manager);
        (rules.total_minted, rules.total_burned, rules.max_supply)
    } else {
        (0, 0, option::none())
    }
}

/// Create new MintBurnRules
public fun new_mint_burn_rules(
    max_supply: Option<u64>,
    can_mint: bool,
    can_burn: bool,
    max_mint_per_proposal: Option<u64>,
    mint_cooldown_ms: u64,
): MintBurnRules {
    MintBurnRules {
        max_supply,
        total_minted: 0,
        total_burned: 0,
        can_mint,
        can_burn,
        max_mint_per_proposal,
        mint_cooldown_ms,
        last_mint_timestamp: 0,
    }
}

// === Admin Functions ===

/// Admin capability for emergency operations
public struct AdminCap has key, store {
    id: UID,
    manager_id: ID,
}

/// Create admin cap (called during initialization)
public fun create_admin_cap(manager: &CapabilityManager, ctx: &mut TxContext): AdminCap {
    AdminCap {
        id: object::new(ctx),
        manager_id: object::id(manager),
    }
}

// === Mint/Burn Functions ===

/// Mint new tokens following all rules and restrictions
public fun mint_tokens<T: drop>(
    manager: &mut CapabilityManager,
    context: &ProposalExecutionContext,
    amount: u64,
    recipient: address,
    clock: &sui::clock::Clock,
    ctx: &mut TxContext,
) {
    let coin_type = type_name::get<T>();
    let proposal_id = execution_context::proposal_id(context);
    
    // Check for replay attack
    if (!manager.executed_mints.contains(proposal_id)) {
        manager.executed_mints.add(proposal_id, table::new(ctx));
    };
    
    // SECURITY FIX: Enhanced replay attack prevention with execution count
    let execution_count = {
        let proposal_mints = &manager.executed_mints[proposal_id];
        if (proposal_mints.contains(coin_type)) {
            *proposal_mints.borrow(coin_type)
        } else {
            0
        }
    };
    
    // For now, only allow one execution per proposal-coin combination
    assert!(execution_count == 0, EActionAlreadyExecuted);
    
    // Check capability exists
    assert!(has_capability<T>(manager), ECapabilityNotFound);
    
    // Get and validate rules
    let rules = get_rules<T>(manager);
    
    // Validate mint is allowed
    assert!(rules.can_mint, EMintDisabled);
    
    // Check max mint per proposal
    if (rules.max_mint_per_proposal.is_some()) {
        assert!(amount <= *rules.max_mint_per_proposal.borrow(), EExceedsMaxMintPerProposal);
    };
    
    // SECURITY FIX: Check cooldown from deposit time, not just last mint
    let current_time = clock.timestamp_ms();
    let storage: &CapabilityStorage<T> = df::borrow(&manager.id, coin_type);
    
    // Ensure cooldown is met from both deposit time and last mint
    if (rules.mint_cooldown_ms > 0) {
        // Check cooldown from deposit
        assert!(
            current_time >= storage.deposited_at + rules.mint_cooldown_ms,
            EMintCooldownNotMet
        );
        
        // Check cooldown from last mint if applicable
        if (rules.last_mint_timestamp > 0) {
            assert!(
                current_time >= rules.last_mint_timestamp + rules.mint_cooldown_ms,
                EMintCooldownNotMet
            );
        };
    };
    
    // Check max supply
    if (rules.max_supply.is_some()) {
        let new_total = rules.total_minted + amount;
        assert!(new_total <= *rules.max_supply.borrow(), EExceedsMaxSupply);
    };
    
    // Mint tokens
    let cap = borrow_capability_mut<T>(manager, clock);
    let minted_coin = sui::coin::mint(cap, amount, ctx);
    
    // Update rules
    let rules_mut = get_rules_mut<T>(manager);
    rules_mut.total_minted = rules_mut.total_minted + amount;
    rules_mut.last_mint_timestamp = current_time;
    let new_total_minted = rules_mut.total_minted;
    
    // Transfer to recipient
    sui::transfer::public_transfer(minted_coin, recipient);
    
    // SECURITY FIX: Mark this proposal-coin combination as executed with count
    let proposal_mints_mut = &mut manager.executed_mints[proposal_id];
    if (proposal_mints_mut.contains(coin_type)) {
        let count = proposal_mints_mut.borrow_mut(coin_type);
        *count = *count + 1;
    } else {
        proposal_mints_mut.add(coin_type, 1);
    };
    
    // Emit event
    event::emit(TokensMinted {
        manager_id: object::id(manager),
        coin_type,
        amount,
        total_minted: new_total_minted,
        recipient,
        proposal_id,
    });
}

/// Burn tokens
public fun burn_tokens<T: drop>(
    manager: &mut CapabilityManager,
    context: &ProposalExecutionContext,
    coin: sui::coin::Coin<T>,
    clock: &sui::clock::Clock,
    ctx: &mut TxContext,
) {
    let coin_type = type_name::get<T>();
    let amount = coin.value();
    let proposal_id = execution_context::proposal_id(context);
    
    // Check for replay attack
    if (!manager.executed_burns.contains(proposal_id)) {
        manager.executed_burns.add(proposal_id, table::new(ctx));
    };
    
    // SECURITY FIX: Enhanced replay attack prevention with execution count
    let execution_count = {
        let proposal_burns = &manager.executed_burns[proposal_id];
        if (proposal_burns.contains(coin_type)) {
            *proposal_burns.borrow(coin_type)
        } else {
            0
        }
    };
    
    // For now, only allow one execution per proposal-coin combination
    assert!(execution_count == 0, EActionAlreadyExecuted);
    
    // Check capability exists and burning is allowed
    assert!(has_capability<T>(manager), ECapabilityNotFound);
    let rules = get_rules<T>(manager);
    assert!(rules.can_burn, EBurnDisabled);
    
    // Burn the coins
    let cap = borrow_capability_mut<T>(manager, clock);
    sui::coin::burn(cap, coin);
    
    // Update rules
    let rules_mut = get_rules_mut<T>(manager);
    rules_mut.total_burned = rules_mut.total_burned + amount;
    let new_total_burned = rules_mut.total_burned;
    
    // SECURITY FIX: Mark this proposal-coin combination as executed with count
    let proposal_burns_mut = &mut manager.executed_burns[proposal_id];
    if (proposal_burns_mut.contains(coin_type)) {
        let count = proposal_burns_mut.borrow_mut(coin_type);
        *count = *count + 1;
    } else {
        proposal_burns_mut.add(coin_type, 1);
    };
    
    // Emit event
    event::emit(TokensBurned {
        manager_id: object::id(manager),
        coin_type,
        amount,
        total_burned: new_total_burned,
        proposal_id,
    });
}

// === Test Functions ===

#[test_only]
public fun destroy_for_testing(manager: CapabilityManager) {
    // For testing purposes, transfer ownership to a black hole address
    // This avoids the need to properly clean up nested tables and dynamic fields
    transfer::transfer(manager, @0x0);
}

#[test_only]
public fun create_for_testing(ctx: &mut TxContext): CapabilityManager {
    new(ctx)
}