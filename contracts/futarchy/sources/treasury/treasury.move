/// Simplified treasury module with single vault for futarchy DAOs
module futarchy::treasury;

// === Imports ===
use std::{
    string::String,
    type_name::{Self, TypeName},
};
use sui::{
    transfer::Receiving,
    dynamic_field as df,
    dynamic_object_field as dof,
    balance::Balance,
    coin::{Self, Coin},
    bag::{Self, Bag},
    sui::SUI,
    event,
};
// Deps module has been removed as it was unnecessary

// === Constants ===
const NEW_COIN_TYPE_FEE: u64 = 10_000_000_000; // 10 SUI fee for new coin types

// === Errors ===
const EWrongAccount: u64 = 1;
const EInsufficientBalance: u64 = 12;
const ECoinTypeNotFound: u64 = 14;
const EInsufficientFee: u64 = 15;
const EInvalidDepositAmount: u64 = 16;

// === Structs ===

/// Configuration for futarchy-based treasury management
public struct FutarchyConfig has store, drop {
    /// DAO ID this treasury belongs to
    dao_id: ID,
    /// Admin capabilities (for emergency actions)
    admin: address,
}

/// Treasury account that manages DAO funds with a single vault
public struct Treasury has key, store {
    id: UID,
    /// Human readable name and metadata
    name: String,
    /// Futarchy-specific configuration
    config: FutarchyConfig,
    /// Single vault holding all coin types (TypeName -> Balance<CoinType>)
    vault: Bag,
}

/// Authentication token for treasury actions
public struct Auth has drop {
    /// Address of the treasury that created the auth
    treasury_addr: address,
}

// === Events ===

public struct TreasuryCreated has copy, drop {
    treasury_id: ID,
    dao_id: ID,
    admin: address,
    name: String,
}

public struct Deposited has copy, drop {
    treasury_id: ID,
    coin_type: TypeName,
    amount: u64,
    depositor: address,
}

public struct Withdrawn has copy, drop {
    treasury_id: ID,
    coin_type: TypeName,
    amount: u64,
    recipient: address,
}

public struct CoinTypeAdded has copy, drop {
    treasury_id: ID,
    coin_type: TypeName,
}

// === Public Functions ===

/// Creates a new treasury for a futarchy DAO
public fun new(
    dao_id: ID,
    name: String,
    admin: address,
    ctx: &mut TxContext
): Treasury {
    let config = FutarchyConfig {
        dao_id,
        admin,
    };

    let treasury = Treasury {
        id: object::new(ctx),
        name,
        config,
        vault: bag::new(ctx),
    };

    event::emit(TreasuryCreated {
        treasury_id: object::id(&treasury),
        dao_id,
        admin,
        name,
    });

    treasury
}

/// Initializes treasury for a DAO
public fun initialize(
    dao_id: ID,
    admin: address,
    ctx: &mut TxContext
): ID {
    let treasury = new(
        dao_id,
        b"DAO Treasury".to_string(),
        admin,
        ctx
    );
    
    let treasury_id = object::id(&treasury);
    
    // Share the treasury
    transfer::share_object(treasury);
    
    treasury_id
}

// === Deposit Functions ===

/// Deposits SUI coins into the treasury (no fee required)
public entry fun deposit_sui(
    treasury: &mut Treasury,
    coin: Coin<SUI>,
    ctx: &mut TxContext,
) {
    let amount = coin.value();
    assert!(amount > 0, EInvalidDepositAmount);
    
    let depositor = ctx.sender();
    let coin_type = type_name::get<SUI>();
    
    // Add to vault
    if (coin_type_exists<SUI>(treasury)) {
        let balance_mut = treasury.vault.borrow_mut<TypeName, Balance<SUI>>(coin_type);
        balance_mut.join(coin.into_balance());
    } else {
        treasury.vault.add(coin_type, coin.into_balance());
        event::emit(CoinTypeAdded {
            treasury_id: object::id(treasury),
            coin_type,
        });
    };
    
    event::emit(Deposited {
        treasury_id: object::id(treasury),
        coin_type,
        amount,
        depositor,
    });
}

/// Deposits coins from admin without fee (for refunds and admin operations)
public fun admin_deposit<CoinType: drop>(
    treasury: &mut Treasury,
    coin: Coin<CoinType>,
    ctx: &mut TxContext,
) {
    // Verify caller is admin
    assert!(treasury.config.admin == ctx.sender(), EWrongAccount);
    
    let amount = coin.value();
    let depositor = ctx.sender();
    let coin_type = type_name::get<CoinType>();
    
    // Admin deposits bypass fee requirements
    if (!treasury.vault.contains<TypeName>(coin_type)) {
        treasury.vault.add(coin_type, coin.into_balance());
        
        event::emit(CoinTypeAdded {
            treasury_id: object::id(treasury),
            coin_type,
        });
    } else {
        let balance_mut = treasury.vault.borrow_mut<TypeName, Balance<CoinType>>(coin_type);
        balance_mut.join(coin.into_balance());
    };
    
    event::emit(Deposited {
        treasury_id: object::id(treasury),
        coin_type,
        amount,
        depositor,
    });
}

/// Deposits non-SUI coins with fee
public entry fun deposit_coin_with_fee<CoinType: drop>(
    treasury: &mut Treasury,
    coin: Coin<CoinType>,
    fee_payment: Coin<SUI>,
    ctx: &mut TxContext,
) {
    let amount = coin.value();
    assert!(amount > 0, EInvalidDepositAmount);
    
    let depositor = ctx.sender();
    let coin_type = type_name::get<CoinType>();
    
    // Check if this is a new coin type
    let is_new_type = !coin_type_exists<CoinType>(treasury);
    
    if (is_new_type) {
        // Charge fee for new coin type
        assert!(fee_payment.value() >= NEW_COIN_TYPE_FEE, EInsufficientFee);
        
        // Add the fee to treasury as SUI
        deposit_sui(treasury, fee_payment, ctx);
        
        // Add new coin type
        treasury.vault.add(coin_type, coin.into_balance());
        
        event::emit(CoinTypeAdded {
            treasury_id: object::id(treasury),
            coin_type,
        });
    } else {
        // Return fee if not needed
        transfer::public_transfer(fee_payment, depositor);
        
        // Add to existing balance
        let balance_mut = treasury.vault.borrow_mut<TypeName, Balance<CoinType>>(coin_type);
        balance_mut.join(coin.into_balance());
    };
    
    event::emit(Deposited {
        treasury_id: object::id(treasury),
        coin_type,
        amount,
        depositor,
    });
}

// === Withdrawal Functions ===

/// Withdraws coins from treasury (requires auth)
public fun withdraw<CoinType: drop>(
    auth: Auth,
    treasury: &mut Treasury,
    amount: u64,
    ctx: &mut TxContext,
): Coin<CoinType> {
    verify(treasury, auth);
    
    let coin_type = type_name::get<CoinType>();
    assert!(coin_type_exists<CoinType>(treasury), ECoinTypeNotFound);
    
    let balance_mut = treasury.vault.borrow_mut<TypeName, Balance<CoinType>>(coin_type);
    assert!(balance_mut.value() >= amount, EInsufficientBalance);
    
    let coin = coin::from_balance(balance_mut.split(amount), ctx);
    
    event::emit(Withdrawn {
        treasury_id: object::id(treasury),
        coin_type,
        amount,
        recipient: ctx.sender(),
    });
    
    coin
}

/// Direct withdrawal with recipient (for proposals)
public fun withdraw_to<CoinType: drop>(
    auth: Auth,
    treasury: &mut Treasury,
    amount: u64,
    recipient: address,
    ctx: &mut TxContext,
) {
    let coin = withdraw<CoinType>(auth, treasury, amount, ctx);
    transfer::public_transfer(coin, recipient);
}

// === View Functions ===

/// Get balance of a specific coin type
public fun coin_type_value<CoinType: drop>(treasury: &Treasury): u64 {
    let coin_type = type_name::get<CoinType>();
    if (coin_type_exists<CoinType>(treasury)) {
        treasury.vault.borrow<TypeName, Balance<CoinType>>(coin_type).value()
    } else {
        0
    }
}

/// Check if a coin type exists in treasury
public fun coin_type_exists<CoinType: drop>(treasury: &Treasury): bool {
    treasury.vault.contains<TypeName>(type_name::get<CoinType>())
}

/// Get DAO ID
public fun dao_id(treasury: &Treasury): ID {
    treasury.config.dao_id
}

/// Get admin address
public fun get_admin(treasury: &Treasury): address {
    treasury.config.admin
}

/// Get treasury name
public fun name(treasury: &Treasury): &String {
    &treasury.name
}

// === Internal Functions ===

/// Create auth token
fun new_auth(treasury: &Treasury): Auth {
    Auth { treasury_addr: object::id_address(treasury) }
}

/// Verify auth token
fun verify(treasury: &Treasury, auth: Auth) {
    assert!(object::id_address(treasury) == auth.treasury_addr, EWrongAccount);
}

/// Create auth for proposals
public fun create_auth_for_proposal(treasury: &Treasury): Auth {
    new_auth(treasury)
}

// === Test Functions ===

#[test_only]
public fun new_for_testing(dao_id: ID, ctx: &mut TxContext): Treasury {
    new(
        dao_id,
        b"Test Treasury".to_string(),
        ctx.sender(),
        ctx
    )
}

#[test_only]
public fun destroy_for_testing(treasury: Treasury) {
    let Treasury { id, name: _, config: _, vault } = treasury;
    bag::destroy_empty(vault);
    object::delete(id);
}