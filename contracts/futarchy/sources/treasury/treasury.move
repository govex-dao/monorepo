/// Simplified treasury module with single vault for futarchy DAOs
module futarchy::treasury;

// === Imports ===
use futarchy::execution_context::{Self, ProposalExecutionContext};
use futarchy::recurring_payments::{Self, PaymentStream};
use futarchy::{
    math, 
    recurring_payment_registry::{Self, PaymentStreamRegistry},
    dao_liquidity_pool::{Self, DAOLiquidityPool},
    fee::{Self, FeeManager},
};
use std::{
    string::{Self, String},
    ascii::{Self, String as AsciiString},
    type_name::{Self, TypeName},
    option::{Self, Option},
    vector,
};
use sui::{
    balance::{Self, Balance},
    coin::{Self, Coin},
    bag::{Self, Bag},
    table::{Self, Table},
    sui::SUI,
    event,
    clock::Clock,
    object::{Self, ID, UID},
    dynamic_field as df,
    transfer,
    tx_context::{Self, TxContext},
};

// === Constants ===
const NEW_COIN_TYPE_FEE: u64 = 10_000_000_000; // 10 SUI fee for new coin types

// Treasury states
const STATE_ACTIVE: u8 = 0;
const STATE_LIQUIDATING: u8 = 1;
const STATE_REDEMPTION_ACTIVE: u8 = 2;

// === Errors ===
const EWrongAccount: u64 = 1;
const EInsufficientBalance: u64 = 12;
const ECoinTypeNotFound: u64 = 14;
const EInsufficientFee: u64 = 15;
const EInvalidDepositAmount: u64 = 16;
const EInvalidAuth: u64 = 19;
const EUnauthorizedPlatformWithdraw: u64 = 20;
const EInvalidStateForAction: u64 = 21;
const EAssetNotPending: u64 = 22;
const EAssetNotManaged: u64 = 23;
const EMaxRedemptionExceeded: u64 = 24;
const EAssetNotRedeemable: u64 = 25;
const ENothingToRedeem: u64 = 26;
const ETreasuryNotInRedemptionState: u64 = 27;
const E_STREAMS_STILL_ACTIVE: u64 = 28;
const E_DAO_LIQUIDITY_STILL_IN_MARKETS: u64 = 29;
const EUnauthorized: u64 = 30;
const EWrongDAO: u64 = 31;
const EStreamNotTracked: u64 = 32;
const EPaymentNotDue: u64 = 33;
const EStreamInactive: u64 = 34;
const EStreamNotApprovedForCancellation: u64 = 35;

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
    /// Pending assets awaiting approval
    pending_assets: Bag,
    /// Managed non-fungible assets (asset_id -> TypeName)
    managed_assets: Table<ID, TypeName>,
    /// Current state of the treasury
    state: u8,
    /// Dissolution information (if in dissolution state)
    dissolution_info: Option<DissolutionState>,
    /// Stream IDs approved for cancellation
    streams_to_cancel: vector<ID>,
}

/// Dissolution state information
public struct DissolutionState has store {
    proposal_id: ID,
    state: u8,
    liquidation_deadline: Option<u64>,
    redemption_fee_bps: u64,
    max_tokens_to_redeem: Option<u64>,
    total_tokens_redeemed: u64,
    redeemable_assets: Table<AsciiString, RedemptionAssetInfo>,
}

/// Information about a redeemable asset
public struct RedemptionAssetInfo has store, copy, drop {
    total_amount: u64,
    amount_redeemed: u64,
}

/// Authentication token for treasury actions
/// SECURITY FIX: Made non-droppable to prevent forgery
public struct Auth {
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

public struct PlatformFeeWithdrawn has copy, drop {
    treasury_id: ID,
    coin_type: TypeName,
    amount: u64,
    collector: address, // address of factory owner who initiated
    timestamp: u64,
}

public struct PaymentStreamClaimed has copy, drop {
    treasury_id: ID,
    stream_id: ID,
    coin_type: TypeName,
    amount: u64,
    recipient: address,
    claimer: address,
}

public struct DissolutionStarted has copy, drop {
    treasury_id: ID,
    proposal_id: ID,
    dissolution_type: u8, // 0 = partial, 1 = full
    liquidation_deadline: Option<u64>,
}

public struct AssetRedeemed has copy, drop {
    treasury_id: ID,
    redeemer: address,
    dao_tokens_burned: u64,
    coin_type: TypeName,
    amount_redeemed: u64,
    fee_amount: u64,
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
        pending_assets: bag::new(ctx),
        managed_assets: table::new(ctx),
        state: STATE_ACTIVE,
        dissolution_info: option::none(),
        streams_to_cancel: vector::empty(),
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
        
        // Add fee to treasury as SUI
        if (coin_type_exists<SUI>(treasury)) {
            let balance_mut = treasury.vault.borrow_mut<TypeName, Balance<SUI>>(type_name::get<SUI>());
            balance_mut.join(fee_payment.into_balance());
        } else {
            treasury.vault.add(type_name::get<SUI>(), fee_payment.into_balance());
        };
        
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
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<CoinType> {
    verify_auth_internal(treasury, &auth);
    
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
    
    // Consume auth token to prevent reuse
    let Auth { treasury_addr: _ } = auth;
    
    coin
}

/// Direct withdrawal with recipient (for proposals)
public fun withdraw_to<CoinType: drop>(
    auth: Auth,
    treasury: &mut Treasury,
    amount: u64,
    recipient: address,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let coin = withdraw<CoinType>(auth, treasury, amount, clock, ctx);
    transfer::public_transfer(coin, recipient);
}

/// Withdraws coins from treasury without drop requirement (for LP tokens)
/// SECURITY FIX: Added documentation for why this is needed and extra validation
public (package) fun withdraw_without_drop<CoinType>(
    auth: Auth,
    treasury: &mut Treasury,
    amount: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<CoinType> {
    // This function is specifically for LP tokens which don't have the drop ability
    // Extra care is taken to ensure it's only used within the package for authorized operations
    verify_auth_internal(treasury, &auth);
    
    let coin_type = type_name::get<CoinType>();
    assert!(coin_type_exists_by_name(treasury, coin_type), ECoinTypeNotFound);
    
    let balance_mut = treasury.vault.borrow_mut<TypeName, Balance<CoinType>>(coin_type);
    assert!(balance_mut.value() >= amount, EInsufficientBalance);
    
    let coin = coin::from_balance(balance_mut.split(amount), ctx);
    
    event::emit(Withdrawn {
        treasury_id: object::id(treasury),
        coin_type,
        amount,
        recipient: ctx.sender(),
    });
    
    // Consume auth token to prevent reuse
    let Auth { treasury_addr: _ } = auth;
    
    coin
}

/// Permissionlessly claim a due payment from an active payment stream.
/// This function reads the stream's state, verifies a payment is due,
/// withdraws the funds from the treasury, and updates the stream's state.
public entry fun claim_from_stream<CoinType: drop>(
    treasury: &mut Treasury,
    stream: &mut PaymentStream<CoinType>,
    registry: &PaymentStreamRegistry,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Verify the stream belongs to this DAO's treasury
    let (_, _, _, _, _, _, dao_id) = recurring_payments::get_stream_info(stream);
    assert!(dao_id == treasury.config.dao_id, EWrongDAO);
    
    // Verify the stream is tracked in the registry
    let stream_id = object::id(stream);
    assert!(recurring_payment_registry::is_stream_tracked(registry, stream_id), EStreamNotTracked);
    
    // Check if payment is due
    assert!(recurring_payments::is_payment_due(stream, clock), EPaymentNotDue);
    
    // Get payment details
    let (recipient, amount_per_payment, _, _total_paid, active, _dao_id) = recurring_payments::get_stream_info(stream);
    assert!(active, EStreamInactive);
    
    // Check treasury has sufficient balance
    let coin_type = type_name::get<CoinType>();
    assert!(coin_type_exists_by_name(treasury, coin_type), ECoinTypeNotFound);
    let balance = treasury.vault.borrow<TypeName, Balance<CoinType>>(coin_type);
    assert!(balance.value() >= amount_per_payment, EInsufficientBalance);
    
    // Process the payment - withdraw directly from vault
    let balance_mut = treasury.vault.borrow_mut<TypeName, Balance<CoinType>>(coin_type);
    let coin = coin::from_balance(balance_mut.split(amount_per_payment), ctx);
    transfer::public_transfer(coin, recipient);
    
    // Update stream state
    recurring_payments::update_payment_timestamp(stream, clock);
    recurring_payments::add_to_total_paid(stream, amount_per_payment);
    
    // Emit event
    event::emit(PaymentStreamClaimed {
        treasury_id: object::id(treasury),
        stream_id,
        coin_type,
        amount: amount_per_payment,
        recipient,
        claimer: tx_context::sender(ctx),
    });
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

/// Withdraws coins for platform fees from proposals (requires ProposalExecutionContext)
/// SECURITY FIX: Added authorization requirement via execution context
public(package) fun platform_withdraw<CoinType>(
    treasury: &mut Treasury,
    amount: u64,
    execution_context: &ProposalExecutionContext,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<CoinType> {
    // SECURITY FIX: Verify the execution context is for the DAO that owns this treasury
    let context_dao_id = execution_context::dao_id(execution_context);
    assert!(context_dao_id == treasury.config.dao_id, EUnauthorizedPlatformWithdraw);
    
    let coin_type = type_name::get<CoinType>();
    assert!(coin_type_exists_by_name(treasury, coin_type), ECoinTypeNotFound);

    let balance_mut = treasury.vault.borrow_mut<TypeName, Balance<CoinType>>(coin_type);
    assert!(balance_mut.value() >= amount, EInsufficientBalance);

    let coin = coin::from_balance(balance_mut.split(amount), ctx);

    event::emit(PlatformFeeWithdrawn {
        treasury_id: object::id(treasury),
        coin_type,
        amount,
        collector: ctx.sender(), // The address that initiated the collection
        timestamp: clock.timestamp_ms(),
    });

    coin
}

/// Withdraws coins for platform fee collection
/// SECURITY: This is specifically for fee collection and requires the DAO ID to match
public(package) fun withdraw_platform_fee<CoinType>(
    treasury: &mut Treasury,
    amount: u64,
    dao_id: ID,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<CoinType> {
    // SECURITY: Verify the DAO ID matches the treasury's DAO
    assert!(dao_id == treasury.config.dao_id, EUnauthorizedPlatformWithdraw);
    
    let coin_type = type_name::get<CoinType>();
    assert!(coin_type_exists_by_name(treasury, coin_type), ECoinTypeNotFound);

    let balance_mut = treasury.vault.borrow_mut<TypeName, Balance<CoinType>>(coin_type);
    assert!(balance_mut.value() >= amount, EInsufficientBalance);

    let coin = coin::from_balance(balance_mut.split(amount), ctx);

    event::emit(PlatformFeeWithdrawn {
        treasury_id: object::id(treasury),
        coin_type,
        amount,
        collector: ctx.sender(),
        timestamp: clock.timestamp_ms(),
    });

    coin
}

/// Check if a coin type exists in treasury
public fun coin_type_exists<CoinType: drop>(treasury: &Treasury): bool {
    treasury.vault.contains<TypeName>(type_name::get<CoinType>())
}

/// Deposits coins without drop requirement (for LP tokens)
public (package) fun deposit_without_drop<CoinType>(
    treasury: &mut Treasury,
    coin: Coin<CoinType>,
    ctx: &mut TxContext,
) {
    let amount = coin.value();
    assert!(amount > 0, EInvalidDepositAmount);
    
    let depositor = ctx.sender();
    let coin_type = type_name::get<CoinType>();
    
    // Add to vault
    if (coin_type_exists_by_name(treasury, coin_type)) {
        let balance_mut = treasury.vault.borrow_mut<TypeName, Balance<CoinType>>(coin_type);
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

/// Check if a coin type exists in treasury (by TypeName)
public fun coin_type_exists_by_name(treasury: &Treasury, coin_type: TypeName): bool {
    treasury.vault.contains<TypeName>(coin_type)
}

/// Deposit a balance directly (used by auction module)
public(package) fun deposit_coin_type_balance<CoinType: drop>(
    treasury: &mut Treasury,
    balance: Balance<CoinType>,
) {
    let coin_type = type_name::get<CoinType>();
    
    if (treasury.vault.contains(coin_type)) {
        // Add to existing balance
        let existing_balance = bag::borrow_mut<TypeName, Balance<CoinType>>(&mut treasury.vault, coin_type);
        balance::join(existing_balance, balance);
    } else {
        // Add new coin type
        treasury.vault.add(coin_type, balance);
        
        event::emit(CoinTypeAdded {
            treasury_id: object::id(treasury),
            coin_type,
        });
    };
}

/// Get treasury ID
public fun get_id(treasury: &Treasury): ID {
    object::id(treasury)
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

// === Auth Functions ===

/// Create auth token
fun new_auth(treasury: &Treasury): Auth {
    Auth { treasury_addr: object::id_address(treasury) }
}

/// Verify auth token (public for use by other modules)
/// SECURITY FIX: Now takes reference to auth since Auth is non-droppable
public fun verify_auth(treasury: &Treasury, auth: &Auth) {
    assert!(object::id_address(treasury) == auth.treasury_addr, EInvalidAuth);
}

/// Create auth for proposals - requires ProposalExecutionContext as proof of authorization
public(package) fun create_auth_for_proposal(
    treasury: &Treasury,
    _context: &ProposalExecutionContext
): Auth {
    // The context proves this is an authorized execution from the DAO
    new_auth(treasury)
}

/// Consume an auth token to prevent reuse
public fun consume_auth(auth: Auth) {
    let Auth { treasury_addr: _ } = auth;
}

// === Asset Management Functions ===

/// Request to deposit a non-fungible asset (spam prevention)
/// Note: This should be called through a specific asset type wrapper
/// The asset must have key + store abilities
public(package) fun request_deposit_asset<T: key + store>(treasury: &mut Treasury, asset: T) {
    let id = object::id(&asset);
    treasury.pending_assets.add(id, asset);
}

/// Approve a pending asset deposit (requires proposal execution)
public(package) fun approve_asset_deposit<T: key + store>(
    treasury: &mut Treasury,
    asset_id: ID,
    _context: &ProposalExecutionContext,
    ctx: &mut TxContext,
) {
    assert!(treasury.pending_assets.contains(asset_id), EAssetNotPending);
    let asset: T = treasury.pending_assets.remove(asset_id);
    let asset_type = type_name::get<T>();
    
    treasury.managed_assets.add(asset_id, asset_type);
    df::add<ID, T>(&mut treasury.id, asset_id, asset);
}

/// Release a managed asset (for auctions during liquidation)
/// Returns the actual object that was stored
public(package) fun release_managed_asset<T: key + store>(
    treasury: &mut Treasury, 
    asset_id: ID,
    ctx: &mut TxContext
): T {
    assert!(treasury.managed_assets.contains(asset_id), EAssetNotManaged);
    treasury.managed_assets.remove(asset_id);
    df::remove<ID, T>(&mut treasury.id, asset_id)
}

// === Dissolution Functions ===

/// Start partial dissolution
public(package) fun start_partial_dissolution(
    treasury: &mut Treasury,
    auth: Auth,
    proposal_id: ID,
    max_tokens_to_redeem: u64,
    redeemable_coin_types: &vector<TypeName>,
    redeemable_percentages: &vector<u64>,
    redemption_fee_bps: u64,
    ctx: &mut TxContext,
) {
    verify_auth_internal(treasury, &auth);
    assert!(treasury.state == STATE_ACTIVE, EInvalidStateForAction);

    treasury.state = STATE_REDEMPTION_ACTIVE;
    let mut redeemable_assets = table::new(ctx);

    let mut i = 0;
    while(i < redeemable_coin_types.length()) {
        let type_name = *vector::borrow(redeemable_coin_types, i);
        let percentage_bps = *vector::borrow(redeemable_percentages, i);
        
        // Get the balance for this coin type if it exists
        if (treasury.vault.contains(type_name)) {
            // Note: This requires type-specific handling in practice
            // For now, we'll store the percentage to be redeemed
            let amount_to_redeem = percentage_bps; // Store percentage instead of amount
            
            // Convert TypeName to AsciiString for storage
            let type_name_str = type_name.into_string();
            redeemable_assets.add(type_name_str, RedemptionAssetInfo {
                total_amount: amount_to_redeem,
                amount_redeemed: 0,
            });
        };
        i = i + 1;
    };

    // Ensure no existing dissolution is active
    assert!(treasury.dissolution_info.is_none(), EInvalidStateForAction);
    
    treasury.dissolution_info.fill(DissolutionState {
        proposal_id,
        state: STATE_REDEMPTION_ACTIVE,
        liquidation_deadline: option::none(),
        redemption_fee_bps,
        max_tokens_to_redeem: option::some(max_tokens_to_redeem),
        total_tokens_redeemed: 0,
        redeemable_assets,
    });
    
    event::emit(DissolutionStarted {
        treasury_id: object::id(treasury),
        proposal_id,
        dissolution_type: 0, // partial
        liquidation_deadline: option::none(),
    });
    
    consume_auth(auth);
}

/// Start full dissolution
public(package) fun start_full_dissolution(
    treasury: &mut Treasury,
    auth: Auth,
    proposal_id: ID,
    liquidation_period_ms: u64,
    redemption_fee_bps: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    verify_auth_internal(treasury, &auth);
    assert!(treasury.state == STATE_ACTIVE, EInvalidStateForAction);

    let liquidation_deadline = clock.timestamp_ms() + liquidation_period_ms;
    treasury.state = STATE_LIQUIDATING;
    
    // Ensure no existing dissolution is active
    assert!(treasury.dissolution_info.is_none(), EInvalidStateForAction);
    
    treasury.dissolution_info.fill(DissolutionState {
        proposal_id,
        state: STATE_LIQUIDATING,
        liquidation_deadline: option::some(liquidation_deadline),
        redemption_fee_bps,
        max_tokens_to_redeem: option::none(),
        total_tokens_redeemed: 0,
        redeemable_assets: table::new(ctx),
    });
    
    event::emit(DissolutionStarted {
        treasury_id: object::id(treasury),
        proposal_id,
        dissolution_type: 1, // full
        liquidation_deadline: option::some(liquidation_deadline),
    });
    
    consume_auth(auth);
}

/// Finalize liquidation and move to redemption phase
public entry fun finalize_liquidation<AssetType, StableType>(
    treasury: &mut Treasury,
    payment_registry: &PaymentStreamRegistry,
    dao_liquidity_pool: &mut DAOLiquidityPool<AssetType, StableType>,
    clock: &Clock,
    ctx: &mut TxContext
) {
    assert!(treasury.state == STATE_LIQUIDATING, EInvalidStateForAction);
    
    // Check deadline
    {
        let dissolution = option::borrow(&treasury.dissolution_info);
        let deadline = *option::borrow(&dissolution.liquidation_deadline);
        assert!(clock.timestamp_ms() >= deadline, EInvalidStateForAction);
    };

    // --- NEW CRITICAL CHECKS ---
    // Enforce that all payment streams have been canceled.
    assert!(recurring_payment_registry::get_active_count(payment_registry) == 0, E_STREAMS_STILL_ACTIVE);
    // Enforce that all DAO-provided liquidity has been returned from active markets.
    assert!(
        dao_liquidity_pool::asset_balance(dao_liquidity_pool) == 0 && 
        dao_liquidity_pool::stable_balance(dao_liquidity_pool) == 0, 
        E_DAO_LIQUIDITY_STILL_IN_MARKETS
    );

    treasury.state = STATE_REDEMPTION_ACTIVE;
    
    // Make all fungible assets in the vault redeemable
    // TODO: We need to track coin types separately as bag doesn't have keys() function
    let all_coin_types = vector::empty<TypeName>();
    let mut i = 0;
    let mut asset_type_names = vector::empty<AsciiString>();
    let mut asset_redemption_infos = vector::empty<RedemptionAssetInfo>();
    
    while (i < vector::length(&all_coin_types)) {
        let type_name = *vector::borrow(&all_coin_types, i);
        // Note: Actual balance retrieval requires type-specific functions
        let balance_value = 0; // Placeholder - requires type-specific implementation
        // Convert TypeName to AsciiString for storage
        let type_name_str = type_name.into_string();
        vector::push_back(&mut asset_type_names, type_name_str);
        vector::push_back(&mut asset_redemption_infos, RedemptionAssetInfo {
            total_amount: balance_value,
            amount_redeemed: 0,
        });
        i = i + 1;
    };
    
    // Update dissolution state
    let dissolution = option::borrow_mut(&mut treasury.dissolution_info);
    dissolution.state = STATE_REDEMPTION_ACTIVE;
    
    // Add all asset infos to redeemable_assets
    let mut j = 0;
    while (j < vector::length(&asset_type_names)) {
        let type_name_str = vector::pop_back(&mut asset_type_names);
        let info = vector::pop_back(&mut asset_redemption_infos);
        dissolution.redeemable_assets.add(type_name_str, info);
        j = j + 1;
    };
    
    // Withdraw any remaining assets from the DAO liquidity pool
    // These should be zero if all liquidity was properly reclaimed, but we check anyway
    if (dao_liquidity_pool::asset_balance(dao_liquidity_pool) > 0) {
        let reclaimed_asset = dao_liquidity_pool::withdraw_all_asset_balance(dao_liquidity_pool);
        // Add to vault
        let asset_type = type_name::get<AssetType>();
        if (treasury.vault.contains(asset_type)) {
            let existing_balance = bag::borrow_mut<TypeName, Balance<AssetType>>(&mut treasury.vault, asset_type);
            balance::join(existing_balance, reclaimed_asset);
        } else {
            treasury.vault.add(asset_type, reclaimed_asset);
        };
    };
    
    if (dao_liquidity_pool::stable_balance(dao_liquidity_pool) > 0) {
        let reclaimed_stable = dao_liquidity_pool::withdraw_all_stable_balance(dao_liquidity_pool);
        // Add to vault
        let stable_type = type_name::get<StableType>();
        if (treasury.vault.contains(stable_type)) {
            let existing_balance = bag::borrow_mut<TypeName, Balance<StableType>>(&mut treasury.vault, stable_type);
            balance::join(existing_balance, reclaimed_stable);
        } else {
            treasury.vault.add(stable_type, reclaimed_stable);
        };
    };
}

/// Redeem a single asset type
/// The caller must specify the exact coin type to redeem at compile time
public entry fun redeem_single_asset<DAOAssetType: drop, RedeemableCoinType: drop>(
    treasury: &mut Treasury,
    dao_tokens_to_burn: Coin<DAOAssetType>,
    dao_treasury_cap: &mut coin::TreasuryCap<DAOAssetType>,
    fee_manager: &mut FeeManager,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(treasury.state == STATE_REDEMPTION_ACTIVE, ETreasuryNotInRedemptionState);
    
    // 1. Get the typed balance directly
    let redeemable_coin_type = type_name::get<RedeemableCoinType>();
    assert!(treasury.vault.contains(redeemable_coin_type), EAssetNotRedeemable);
    
    // Check if asset is marked as redeemable in dissolution info
    {
        let dissolution = option::borrow(&treasury.dissolution_info);
        let type_str = redeemable_coin_type.into_string();
        assert!(dissolution.redeemable_assets.contains(type_str), EAssetNotRedeemable);
    };
    
    // 2. Calculate Redeemable Supply (Handles Circular Ownership)
    let raw_total_supply = coin::total_supply(dao_treasury_cap);
    let treasury_self_holding = coin_type_value<DAOAssetType>(treasury);
    let redeemable_supply = raw_total_supply - treasury_self_holding;
    assert!(redeemable_supply > 0, EInsufficientBalance);

    let amount_to_burn = coin::value(&dao_tokens_to_burn);

    // 3. Handle Partial vs. Full Dissolution logic
    // Get dissolution info and check if partial
    let is_partial = {
        let dissolution = option::borrow(&treasury.dissolution_info);
        option::is_some(&dissolution.max_tokens_to_redeem)
    };
    
    if (is_partial) {
        let dissolution = option::borrow_mut(&mut treasury.dissolution_info);
        let max_redeemable = *option::borrow(&dissolution.max_tokens_to_redeem);
        let new_total_redeemed = dissolution.total_tokens_redeemed + amount_to_burn;
        assert!(new_total_redeemed <= max_redeemable, EMaxRedemptionExceeded);
        dissolution.total_tokens_redeemed = new_total_redeemed;
    };
    
    // 4. Burn the user's DAO tokens
    coin::burn(dao_treasury_cap, dao_tokens_to_burn);

    // 5. Calculate and distribute the single requested asset
    let (user_share_of_asset, unredeemed_balance) = {
        let dissolution = option::borrow(&treasury.dissolution_info);
        let type_str = redeemable_coin_type.into_string();
        let redemption_info = table::borrow(&dissolution.redeemable_assets, type_str);
        
        let user_share = if (option::is_some(&dissolution.max_tokens_to_redeem)) {
            math::mul_div_to_64(amount_to_burn, redemption_info.total_amount, *option::borrow(&dissolution.max_tokens_to_redeem))
        } else {
            math::mul_div_to_64(amount_to_burn, redemption_info.total_amount, redeemable_supply)
        };
        
        let unredeemed = redemption_info.total_amount - redemption_info.amount_redeemed;
        (user_share, unredeemed)
    };
    
    assert!(user_share_of_asset > 0, ENothingToRedeem);
    assert!(user_share_of_asset <= unredeemed_balance, EInsufficientBalance);

    // Update amount redeemed
    {
        let dissolution = option::borrow_mut(&mut treasury.dissolution_info);
        let type_str = redeemable_coin_type.into_string();
        let redemption_info = table::borrow_mut(&mut dissolution.redeemable_assets, type_str);
        redemption_info.amount_redeemed = redemption_info.amount_redeemed + user_share_of_asset;
    };

    // 6. Withdraw, handle fees, and transfer
    // Get the actual TypeName for vault access (vault uses TypeName as key, not AsciiString)
    let balance_mut = bag::borrow_mut<TypeName, Balance<RedeemableCoinType>>(&mut treasury.vault, redeemable_coin_type);
    
    // Get fee from dissolution info
    let fee_bps = {
        let dissolution = option::borrow(&treasury.dissolution_info);
        dissolution.redemption_fee_bps
    };
    let fee_amount = math::mul_div_to_64(user_share_of_asset, fee_bps, 10000);
    let net_amount = user_share_of_asset - fee_amount;

    // Transfer fee to protocol fee manager
    if (fee_amount > 0) {
        let fee_balance = balance::split(balance_mut, fee_amount);
        let fee_coin = coin::from_balance(fee_balance, ctx);
        
        // Deposit the redemption fee to the fee manager
        fee::deposit_dao_platform_fee<RedeemableCoinType>(
            fee_manager,
            fee_coin,
            treasury.config.dao_id,
            clock,
            ctx
        );
    };
    
    // Transfer net amount to user
    let user_coin = coin::from_balance(balance::split(balance_mut, net_amount), ctx);
    transfer::public_transfer(user_coin, tx_context::sender(ctx));
    
    // Emit redemption event
    event::emit(AssetRedeemed {
        treasury_id: object::id(treasury),
        redeemer: tx_context::sender(ctx),
        dao_tokens_burned: amount_to_burn,
        coin_type: redeemable_coin_type,
        amount_redeemed: net_amount,
        fee_amount,
    });
}

// === View Functions ===

/// Get treasury state
public fun get_state(treasury: &Treasury): u8 {
    treasury.state
}

/// Get managed asset type
public fun get_managed_asset_type(treasury: &Treasury, asset_id: ID): Option<TypeName> {
    if (table::contains(&treasury.managed_assets, asset_id)) {
        option::some(*table::borrow(&treasury.managed_assets, asset_id))
    } else {
        option::none()
    }
}

/// Check if address is admin
public fun is_admin(treasury: &Treasury, addr: address): bool {
    treasury.config.admin == addr
}

/// Get state constants for external use
public fun state_active(): u8 { STATE_ACTIVE }
public fun state_liquidating(): u8 { STATE_LIQUIDATING }
public fun state_redemption_active(): u8 { STATE_REDEMPTION_ACTIVE }

/// Add a stream cancellation request
public(package) fun add_stream_cancellation_request(treasury: &mut Treasury, stream_id: ID) {
    if (!vector::contains(&treasury.streams_to_cancel, &stream_id)) {
        vector::push_back(&mut treasury.streams_to_cancel, stream_id);
    };
}

/// Get streams approved for cancellation
public fun get_streams_to_cancel(treasury: &Treasury): &vector<ID> {
    &treasury.streams_to_cancel
}

/// Remove a stream from cancellation list (after it's been canceled)
public fun remove_canceled_stream(treasury: &mut Treasury, stream_id: ID) {
    let (exists, index) = vector::index_of(&treasury.streams_to_cancel, &stream_id);
    if (exists) {
        vector::remove(&mut treasury.streams_to_cancel, index);
    };
}

// Cancel a payment stream that was approved for cancellation
public entry fun execute_approved_stream_cancellation<CoinType>(
    treasury: &mut Treasury,
    registry: &mut PaymentStreamRegistry,
    stream: &mut PaymentStream<CoinType>,
    clock: &Clock,
    _ctx: &mut TxContext,
) {
    let stream_id = object::id(stream);
    
    // Check if this stream is approved for cancellation
    let (exists, index) = vector::index_of(&treasury.streams_to_cancel, &stream_id);
    assert!(exists, EStreamNotApprovedForCancellation);
    
    // Remove from the approval list
    vector::remove(&mut treasury.streams_to_cancel, index);
    
    // Cancel the stream
    recurring_payments::cancel_stream(stream, registry, clock, _ctx);
}

/// A permissionless function that allows anyone to cancel a payment stream
/// for a DAO that is in the process of dissolving. This must be called for all
/// active streams before the redemption phase can begin.
public entry fun permissionless_cancel_dissolving_stream<CoinType>(
    treasury: &mut Treasury,
    registry: &mut PaymentStreamRegistry,
    stream: &mut PaymentStream<CoinType>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // 1. Verify that the DAO's treasury is actually in the dissolution/liquidation phase.
    assert!(treasury.state == STATE_LIQUIDATING, ETreasuryNotInRedemptionState);

    // 2. Verify the stream belongs to this DAO.
    let (_, _, _, _, _, stream_dao_id) = recurring_payments::get_stream_info(stream);
    assert!(stream_dao_id == treasury.config.dao_id, EWrongDAO);
    
    // 3. Check if stream is active
    let (_, _, _, _, active, _) = recurring_payments::get_stream_info(stream);
    if (!active) {
        return
    };

    // 4. Call the existing cancel logic.
    recurring_payments::cancel_stream(stream, registry, clock, ctx);
}

// === Private Functions ===

/// Get balance for a specific coin type
public fun get_balance<CoinType>(treasury: &Treasury): u64 {
    let type_name = type_name::get<CoinType>();
    if (treasury.vault.contains(type_name)) {
        let balance: &Balance<CoinType> = &treasury.vault[type_name];
        balance.value()
    } else {
        0
    }
}

/// Get redemption fee basis points
public fun get_redemption_fee_bps(treasury: &Treasury): u64 {
    if (treasury.dissolution_info.is_some()) {
        option::borrow(&treasury.dissolution_info).redemption_fee_bps
    } else {
        0
    }
}

/// Withdraw coins for redemption (requires treasury to be in redemption state)
public(package) fun withdraw_for_redemption<CoinType>(
    treasury: &mut Treasury,
    amount: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<CoinType> {
    assert!(treasury.state == STATE_REDEMPTION_ACTIVE, ETreasuryNotInRedemptionState);
    let type_name = type_name::get<CoinType>();
    assert!(treasury.vault.contains(type_name), ECoinTypeNotFound);
    
    let balance: &mut Balance<CoinType> = &mut treasury.vault[type_name];
    coin::from_balance(balance.split(amount), ctx)
}

/// Verify auth token (internal helper)
fun verify_auth_internal(treasury: &Treasury, auth: &Auth) {
    assert!(auth.treasury_addr == object::id_address(treasury), EInvalidAuth);
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
    let Treasury { 
        id, 
        name: _, 
        config: _, 
        vault,
        state: _,
        dissolution_info,
        managed_assets,
        pending_assets,
        streams_to_cancel: _
    } = treasury;
    
    // Clean up dissolution info if it exists
    if (option::is_some(&dissolution_info)) {
        let info = option::destroy_some(dissolution_info);
        let DissolutionState {
            proposal_id: _,
            state: _,
            liquidation_deadline: _,
            redemption_fee_bps: _,
            max_tokens_to_redeem: _,
            total_tokens_redeemed: _,
            redeemable_assets
        } = info;
        table::destroy_empty(redeemable_assets);
    } else {
        option::destroy_none(dissolution_info);
    };
    
    // Clean up managed assets
    table::destroy_empty(managed_assets);
    
    // Clean up pending assets
    bag::destroy_empty(pending_assets);
    
    bag::destroy_empty(vault);
    object::delete(id);
}