/// DAO Management module - handles configuration, treasury, and liquidity operations
/// Includes: parameter updates, treasury bridge, liquidity pool management
module futarchy::dao_management;

use futarchy::dao_state::{Self, DAO};
use futarchy::dao_liquidity_pool::{Self, DAOLiquidityPool};
use futarchy::treasury::{Self, Treasury};
use futarchy::operating_agreement;
use futarchy::execution_context::{Self, ProposalExecutionContext};
use std::string::String;
use std::ascii::String as AsciiString;
use sui::url::{Self, Url};
use sui::coin::{Self, Coin};
use sui::clock::Clock;
use sui::event;

// === Errors ===

// Configuration errors
const EUnauthorized: u64 = 2;
const EInvalidMinAmounts: u64 = 5;
const EInvalidOutcomeCount: u64 = 3;
const EMetadataTooLong: u64 = 14;
const EInvalidTwapDelay: u64 = 20;
const EInvalidValue: u64 = 24;
const EDaoDescriptionTooLong: u64 = 21;
const EProposalCreationAlreadyDisabled: u64 = 34;
const EProposalCreationAlreadyEnabled: u64 = 35;
const EInvalidMaxConcurrent: u64 = 36;

// Treasury errors
const EInvalidExecutionContext: u64 = 40;
const ETreasuryNotInitialized: u64 = 38;
const ETreasuryMismatch: u64 = 39;
const EInvalidAmount: u64 = 0;
const EInvalidAssetType: u64 = 8;
const EInvalidStableType: u64 = 9;
const EInsufficientLiquidity: u64 = 36;

// Liquidity errors
const ELiquidityPoolAlreadyInitialized: u64 = 27;
const ELiquidityPoolNotInitialized: u64 = 28;

// === Constants ===

const MIN_AMM_SAFE_AMOUNT: u64 = 1000;
const MIN_OUTCOMES: u64 = 2;
const MAX_OUTCOMES: u64 = 3;
const DAO_DESCRIPTION_MAX_LENGTH: u64 = 1024;
const MAX_METADATA_LENGTH: u64 = 4096;
const MIN_MAX_CONCURRENT: u64 = 1;
const MAX_MAX_CONCURRENT: u64 = 100;

// === Events ===

public struct TradingParamsUpdated has copy, drop {
    dao_id: ID,
    min_asset_amount: u64,
    min_stable_amount: u64,
    review_period_ms: u64,
    trading_period_ms: u64,
}

public struct MetadataUpdated has copy, drop {
    dao_id: ID,
    dao_name: AsciiString,
    icon_url: Url,
    description: String,
}

public struct TwapConfigUpdated has copy, drop {
    dao_id: ID,
    amm_twap_start_delay: u64,
    amm_twap_step_max: u64,
    amm_twap_initial_observation: u128,
    twap_threshold: u64,
}

public struct GovernanceUpdated has copy, drop {
    dao_id: ID,
    max_outcomes: u64,
    proposal_fee_per_outcome: u64,
    max_concurrent_proposals: u64,
    required_bond_amount: u64,
}

public struct ProposalCreationToggled has copy, drop {
    dao_id: ID,
    enabled: bool,
}

public struct VerificationUpdated has copy, drop {
    dao_id: ID,
    attestation_url: String,
    verification_pending: bool,
    verified: bool,
}

public struct LiquidityPoolInitialized has copy, drop {
    dao_id: ID,
    pool_id: ID,
    initial_asset: u64,
    initial_stable: u64,
}

// === Configuration Management ===

/// Update trading parameters for the DAO
public(package) fun update_trading_params<AssetType, StableType>(
    dao: &mut DAO<AssetType, StableType>,
    min_asset_amount: u64,
    min_stable_amount: u64,
    review_period_ms: u64,
    trading_period_ms: u64,
) {
    // Validate minimum amounts
    assert!(
        min_asset_amount > MIN_AMM_SAFE_AMOUNT && min_stable_amount > MIN_AMM_SAFE_AMOUNT,
        EInvalidMinAmounts
    );
    
    // Update the parameters
    dao_state::set_min_asset_amount(dao, min_asset_amount);
    dao_state::set_min_stable_amount(dao, min_stable_amount);
    dao_state::set_review_period_ms(dao, review_period_ms);
    dao_state::set_trading_period_ms(dao, trading_period_ms);
    
    event::emit(TradingParamsUpdated {
        dao_id: object::id(dao),
        min_asset_amount,
        min_stable_amount,
        review_period_ms,
        trading_period_ms,
    });
}

/// Update DAO metadata (name, icon, description)
public(package) fun update_metadata<AssetType, StableType>(
    dao: &mut DAO<AssetType, StableType>,
    dao_name: AsciiString,
    icon_url_string: AsciiString,
    description: String,
) {
    assert!(description.length() <= DAO_DESCRIPTION_MAX_LENGTH, EDaoDescriptionTooLong);
    
    let icon_url = url::new_unsafe(icon_url_string);
    
    dao_state::set_dao_name(dao, dao_name);
    dao_state::set_icon_url(dao, icon_url);
    dao_state::set_description(dao, description);
    
    event::emit(MetadataUpdated {
        dao_id: object::id(dao),
        dao_name,
        icon_url,
        description,
    });
}

/// Update TWAP configuration
public(package) fun update_twap_config<AssetType, StableType>(
    dao: &mut DAO<AssetType, StableType>,
    amm_twap_start_delay: u64,
    amm_twap_step_max: u64,
    amm_twap_initial_observation: u128,
    twap_threshold: u64,
) {
    // Validate TWAP delay is a multiple of 60 seconds
    assert!((amm_twap_start_delay % 60_000) == 0, EInvalidTwapDelay);
    
    dao_state::set_amm_twap_start_delay(dao, amm_twap_start_delay);
    dao_state::set_amm_twap_step_max(dao, amm_twap_step_max);
    dao_state::set_amm_twap_initial_observation(dao, amm_twap_initial_observation);
    dao_state::set_twap_threshold(dao, twap_threshold);
    
    event::emit(TwapConfigUpdated {
        dao_id: object::id(dao),
        amm_twap_start_delay,
        amm_twap_step_max,
        amm_twap_initial_observation,
        twap_threshold,
    });
}

/// Update governance parameters
public(package) fun update_governance<AssetType, StableType>(
    dao: &mut DAO<AssetType, StableType>,
    max_outcomes: u64,
    proposal_fee_per_outcome: u64,
    max_concurrent_proposals: u64,
    required_bond_amount: u64,
) {
    // Validate max outcomes
    assert!(max_outcomes >= MIN_OUTCOMES && max_outcomes <= MAX_OUTCOMES, EInvalidOutcomeCount);
    
    // Validate max concurrent proposals
    assert!(
        max_concurrent_proposals >= MIN_MAX_CONCURRENT && 
        max_concurrent_proposals <= MAX_MAX_CONCURRENT, 
        EInvalidMaxConcurrent
    );
    
    dao_state::set_max_outcomes(dao, max_outcomes);
    dao_state::set_proposal_fee_per_outcome(dao, proposal_fee_per_outcome);
    dao_state::set_max_concurrent_proposals(dao, max_concurrent_proposals);
    dao_state::set_required_bond_amount(dao, required_bond_amount);
    
    event::emit(GovernanceUpdated {
        dao_id: object::id(dao),
        max_outcomes,
        proposal_fee_per_outcome,
        max_concurrent_proposals,
        required_bond_amount,
    });
}

/// Disable proposal creation
public(package) fun disable_proposals<AssetType, StableType>(
    dao: &mut DAO<AssetType, StableType>,
) {
    assert!(dao_state::operational_state(dao) == dao_state::state_active(), EProposalCreationAlreadyDisabled);
    dao_state::set_operational_state(dao, dao_state::state_paused());
    
    event::emit(ProposalCreationToggled {
        dao_id: object::id(dao),
        enabled: false,
    });
}

/// Enable proposal creation
public(package) fun enable_proposals<AssetType, StableType>(
    dao: &mut DAO<AssetType, StableType>,
) {
    assert!(dao_state::operational_state(dao) != dao_state::state_active(), EProposalCreationAlreadyEnabled);
    dao_state::set_operational_state(dao, dao_state::state_active());
    
    event::emit(ProposalCreationToggled {
        dao_id: object::id(dao),
        enabled: true,
    });
}

/// Update verification status
public(package) fun update_verification<AssetType, StableType>(
    dao: &mut DAO<AssetType, StableType>,
    attestation_url: String,
    verification_pending: bool,
    verified: bool,
) {
    dao_state::set_attestation_url(dao, attestation_url);
    dao_state::set_verification_pending(dao, verification_pending);
    dao_state::set_verified(dao, verified);
    
    event::emit(VerificationUpdated {
        dao_id: object::id(dao),
        attestation_url,
        verification_pending,
        verified,
    });
}

// === Metadata Management ===

/// Add a metadata entry
public(package) fun add_metadata_entry<AssetType, StableType>(
    dao: &mut DAO<AssetType, StableType>,
    key: String,
    value: String,
) {
    assert!(key.length() > 0 && key.length() <= 256, EInvalidValue);
    assert!(value.length() <= MAX_METADATA_LENGTH, EMetadataTooLong);
    
    let metadata = dao_state::metadata_mut(dao);
    metadata.add(key, value);
}

/// Update a metadata entry
public(package) fun update_metadata_entry<AssetType, StableType>(
    dao: &mut DAO<AssetType, StableType>,
    key: String,
    value: String,
) {
    assert!(value.length() <= MAX_METADATA_LENGTH, EMetadataTooLong);
    
    let metadata = dao_state::metadata_mut(dao);
    assert!(metadata.contains(key), EInvalidValue);
    *&mut metadata[key] = value;
}

/// Remove a metadata entry
public(package) fun remove_metadata_entry<AssetType, StableType>(
    dao: &mut DAO<AssetType, StableType>,
    key: String,
) {
    let metadata = dao_state::metadata_mut(dao);
    assert!(metadata.contains(key), EInvalidValue);
    metadata.remove(key);
}

// === Operating Agreement Management ===

/// Initialize operating agreement for the DAO
public(package) fun init_operating_agreement_internal<AssetType, StableType>(
    dao: &mut DAO<AssetType, StableType>,
    initial_lines: vector<String>,
    initial_difficulties: vector<u64>,
    ctx: &mut TxContext,
): ID {
    // Ensure an agreement hasn't already been initialized
    assert!(dao_state::operating_agreement_id(dao).is_none(), EUnauthorized);

    let agreement = operating_agreement::new(
        object::id(dao),
        initial_lines,
        initial_difficulties,
        ctx,
    );
    let agreement_id = object::id(&agreement);
    dao_state::set_operating_agreement_id(dao, option::some(agreement_id));
    transfer::public_share_object(agreement);
    
    agreement_id
}

// === Treasury Management ===

/// Withdraw LP tokens from treasury
public(package) fun withdraw_lp_from_treasury<AssetType, StableType, LPType>(
    dao: &DAO<AssetType, StableType>,
    treasury: &mut Treasury,
    execution_context: &ProposalExecutionContext,
    amount: u64,
    _recipient: address,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<LPType> {
    // Validate execution context
    assert!(
        execution_context::dao_id(execution_context) == object::id(dao),
        EInvalidExecutionContext
    );
    
    // Validate treasury
    assert!(dao_state::treasury_id(dao).is_some(), ETreasuryNotInitialized);
    assert!(object::id(treasury) == *dao_state::treasury_id(dao).borrow(), ETreasuryMismatch);
    
    // Create auth and withdraw from treasury
    let auth = treasury::create_auth_for_proposal(treasury, execution_context);
    treasury::withdraw_without_drop<LPType>(
        auth,
        treasury,
        amount,
        clock,
        ctx
    )
}

/// Withdraw asset coins from treasury
public(package) fun withdraw_asset_from_treasury<AssetType: drop, StableType>(
    dao: &DAO<AssetType, StableType>,
    treasury: &mut Treasury,
    execution_context: &ProposalExecutionContext,
    amount: u64,
    _recipient: address,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<AssetType> {
    // Validate execution context
    assert!(
        execution_context::dao_id(execution_context) == object::id(dao),
        EInvalidExecutionContext
    );
    
    // Validate treasury
    assert!(dao_state::treasury_id(dao).is_some(), ETreasuryNotInitialized);
    assert!(object::id(treasury) == *dao_state::treasury_id(dao).borrow(), ETreasuryMismatch);
    
    // Validate type
    let expected_type = type_name::get<AssetType>().into_string().to_string();
    assert!(&expected_type == dao_state::asset_type(dao), EInvalidAssetType);
    
    // Create auth and withdraw from treasury
    let auth = treasury::create_auth_for_proposal(treasury, execution_context);
    treasury::withdraw<AssetType>(
        auth,
        treasury,
        amount,
        clock,
        ctx
    )
}

/// Withdraw stable coins from treasury
public(package) fun withdraw_stable_from_treasury<AssetType, StableType: drop>(
    dao: &DAO<AssetType, StableType>,
    treasury: &mut Treasury,
    execution_context: &ProposalExecutionContext,
    amount: u64,
    _recipient: address,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<StableType> {
    // Validate execution context
    assert!(
        execution_context::dao_id(execution_context) == object::id(dao),
        EInvalidExecutionContext
    );
    
    // Validate treasury
    assert!(dao_state::treasury_id(dao).is_some(), ETreasuryNotInitialized);
    assert!(object::id(treasury) == *dao_state::treasury_id(dao).borrow(), ETreasuryMismatch);
    
    // Validate type
    let expected_type = type_name::get<StableType>().into_string().to_string();
    assert!(&expected_type == dao_state::stable_type(dao), EInvalidStableType);
    
    // Create auth and withdraw from treasury
    let auth = treasury::create_auth_for_proposal(treasury, execution_context);
    treasury::withdraw<StableType>(
        auth,
        treasury,
        amount,
        clock,
        ctx
    )
}

/// Mint new tokens using treasury capability
public(package) fun mint_tokens<AssetType: drop, StableType>(
    dao: &mut DAO<AssetType, StableType>,
    treasury: &mut Treasury,
    execution_context: &ProposalExecutionContext,
    amount: u64,
    _recipient: address,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Validate execution context
    assert!(
        execution_context::dao_id(execution_context) == object::id(dao),
        EInvalidExecutionContext
    );
    
    // Validate treasury
    assert!(dao_state::treasury_id(dao).is_some(), ETreasuryNotInitialized);
    assert!(object::id(treasury) == *dao_state::treasury_id(dao).borrow(), ETreasuryMismatch);
    
    // Validate DAO has treasury cap
    assert!(dao_state::treasury_cap(dao).is_some(), EUnauthorized);
    
    // Use safe treasury cap operation
    let minted = dao_state::mint_with_treasury_cap(dao, amount, ctx);
    
    // Deposit to treasury
    treasury::deposit_without_drop(treasury, minted, ctx);
    
    // Withdraw for recipient
    let auth = treasury::create_auth_for_proposal(treasury, execution_context);
    let coin = treasury::withdraw<AssetType>(
        auth,
        treasury,
        amount,
        clock,
        ctx
    );
    
    transfer::public_transfer(coin, _recipient);
}

/// Burn tokens using treasury capability
public(package) fun burn_tokens<AssetType: drop, StableType>(
    dao: &mut DAO<AssetType, StableType>,
    _treasury: &mut Treasury,
    coin_to_burn: Coin<AssetType>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Validate DAO has treasury cap
    assert!(dao_state::treasury_cap(dao).is_some(), EUnauthorized);
    
    // Use safe treasury cap operation
    dao_state::burn_with_treasury_cap(dao, coin_to_burn);
}

// === Liquidity Pool Management ===

/// Initialize the DAO's liquidity pool
public entry fun init_liquidity_pool<AssetType, StableType>(
    dao: &mut DAO<AssetType, StableType>,
    initial_asset_coin: Coin<AssetType>,
    initial_stable_coin: Coin<StableType>,
    ctx: &mut TxContext,
) {
    // Ensure pool not already initialized
    assert!(dao_state::liquidity_pool_id(dao).is_none(), ELiquidityPoolAlreadyInitialized);
    
    // Get values before moving coins
    let initial_asset_val = initial_asset_coin.value();
    let initial_stable_val = initial_stable_coin.value();
    
    // Validate initial amounts
    assert!(
        initial_asset_val >= dao_state::min_asset_amount(dao),
        EInvalidAmount
    );
    assert!(
        initial_stable_val >= dao_state::min_stable_amount(dao),
        EInvalidAmount
    );
    
    // Create the pool
    let mut pool = dao_liquidity_pool::new(
        object::id(dao),
        ctx
    );
    
    // Add initial liquidity
    dao_liquidity_pool::deposit_asset(&mut pool, initial_asset_coin);
    dao_liquidity_pool::deposit_stable(&mut pool, initial_stable_coin);
    
    let pool_id = object::id(&pool);
    dao_state::set_liquidity_pool_id(dao, option::some(pool_id));
    
    event::emit(LiquidityPoolInitialized {
        dao_id: object::id(dao),
        pool_id,
        initial_asset: initial_asset_val,
        initial_stable: initial_stable_val,
    });
    
    transfer::public_share_object(pool);
}

/// Deposit to the DAO's liquidity pool
public entry fun deposit_to_liquidity_pool<AssetType, StableType>(
    dao: &DAO<AssetType, StableType>,
    pool: &mut DAOLiquidityPool<AssetType, StableType>,
    asset_coin: Coin<AssetType>,
    stable_coin: Coin<StableType>,
    ctx: &mut TxContext,
) {
    // Validate pool belongs to this DAO
    assert!(dao_state::liquidity_pool_id(dao).is_some(), ELiquidityPoolNotInitialized);
    assert!(
        object::id(pool) == *dao_state::liquidity_pool_id(dao).borrow(),
        EUnauthorized
    );
    
    // Validate deposit amounts
    assert!(asset_coin.value() > 0 && stable_coin.value() > 0, EInvalidAmount);
    
    // Deposit to pool
    dao_liquidity_pool::deposit_asset(pool, asset_coin);
    dao_liquidity_pool::deposit_stable(pool, stable_coin);
}

/// Withdraw from the DAO's liquidity pool (requires execution context)
public(package) fun withdraw_from_liquidity_pool<AssetType, StableType>(
    dao: &DAO<AssetType, StableType>,
    pool: &mut DAOLiquidityPool<AssetType, StableType>,
    execution_context: &ProposalExecutionContext,
    asset_amount: u64,
    stable_amount: u64,
    recipient: address,
    ctx: &mut TxContext,
) {
    // Validate execution context
    assert!(
        execution_context::dao_id(execution_context) == object::id(dao),
        EInvalidExecutionContext
    );
    
    // Validate pool
    assert!(dao_state::liquidity_pool_id(dao).is_some(), ELiquidityPoolNotInitialized);
    assert!(
        object::id(pool) == *dao_state::liquidity_pool_id(dao).borrow(),
        EUnauthorized
    );
    
    // Validate amounts
    assert!(asset_amount > 0 || stable_amount > 0, EInvalidAmount);
    
    // Check liquidity available
    let available_asset = dao_liquidity_pool::asset_balance(pool);
    let available_stable = dao_liquidity_pool::stable_balance(pool);
    assert!(available_asset >= asset_amount, EInsufficientLiquidity);
    assert!(available_stable >= stable_amount, EInsufficientLiquidity);
    
    // Withdraw
    if (asset_amount > 0) {
        let asset_coin = dao_liquidity_pool::withdraw_asset(pool, asset_amount, ctx);
        transfer::public_transfer(asset_coin, recipient);
    };
    
    if (stable_amount > 0) {
        let stable_coin = dao_liquidity_pool::withdraw_stable(pool, stable_amount, ctx);
        transfer::public_transfer(stable_coin, recipient);
    };
}

// === Getter Functions ===

/// Check if proposal creation is enabled
public fun are_proposals_enabled<AssetType, StableType>(dao: &DAO<AssetType, StableType>): bool {
    dao_state::operational_state(dao) == dao_state::state_active()
}

/// Get market parameters
public fun get_market_params<AssetType, StableType>(
    dao: &DAO<AssetType, StableType>
): (u64, u64, u64, u64) {
    (
        dao_state::min_asset_amount(dao),
        dao_state::min_stable_amount(dao),
        dao_state::review_period_ms(dao),
        dao_state::trading_period_ms(dao)
    )
}

/// Get governance parameters
public fun get_governance_params<AssetType, StableType>(
    dao: &DAO<AssetType, StableType>
): (u64, u64, u64, u64) {
    (
        dao_state::max_outcomes(dao),
        dao_state::proposal_fee_per_outcome(dao),
        dao_state::max_concurrent_proposals(dao),
        dao_state::required_bond_amount(dao)
    )
}

/// Get verification status
public fun get_verification_status<AssetType, StableType>(
    dao: &DAO<AssetType, StableType>
): (&String, bool, bool) {
    (
        dao_state::attestation_url(dao),
        dao_state::verification_pending(dao),
        dao_state::verified(dao)
    )
}

/// Get maximum outcomes allowed
public fun get_max_outcomes<AssetType, StableType>(dao: &DAO<AssetType, StableType>): u64 {
    dao_state::max_outcomes(dao)
}

/// Check if DAO has treasury
public fun has_treasury<AssetType, StableType>(dao: &DAO<AssetType, StableType>): bool {
    dao_state::treasury_id(dao).is_some()
}

/// Check if DAO has liquidity pool
public fun has_liquidity_pool<AssetType, StableType>(dao: &DAO<AssetType, StableType>): bool {
    dao_state::liquidity_pool_id(dao).is_some()
}

use std::type_name;
use futarchy::recurring_payments::{Self, PaymentStream};
use futarchy::recurring_payment_registry::PaymentStreamRegistry;

// === Payment Stream Management ===

/// Cancel a payment stream and return remaining funds to the DAO treasury
/// Only the treasury admin can cancel payment streams
public entry fun cancel_and_refund_payment_stream<CoinType: drop>(
    treasury: &mut Treasury,
    payment_stream_registry: &mut PaymentStreamRegistry,
    stream: &mut PaymentStream<CoinType>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Verify caller is the treasury admin
    assert!(treasury::get_admin(treasury) == ctx.sender(), EUnauthorized);
    
    // Cancel the stream (no refund in new model as funds stay in treasury)
    recurring_payments::cancel_stream<CoinType>(
        stream,
        payment_stream_registry,
        clock,
        ctx
    );
}