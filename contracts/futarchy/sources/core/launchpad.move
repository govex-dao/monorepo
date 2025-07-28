module futarchy::launchpad;

use std::ascii;
use std::string::{Self, String};
use std::option::{Self, Option};
use std::type_name;
use sui::balance::{Self, Balance};
use sui::coin::{Self, Coin, TreasuryCap};
use sui::clock::{Clock};
use sui::event;
use sui::object::{Self, ID, UID};
use sui::dynamic_field as df;
use sui::transfer;
use sui::tx_context::TxContext;

use futarchy::dao;
use futarchy::factory;
use futarchy::fee;
use futarchy::math;

// === Errors ===
const ERaiseStillActive: u64 = 0;
const ERaiseNotActive: u64 = 1;
const EDeadlineNotReached: u64 = 2;
const EMinRaiseNotMet: u64 = 3;
const EMinRaiseAlreadyMet: u64 = 4;
const ENotAContributor: u64 = 6;
const EInvalidStateForAction: u64 = 7;
const EWrongTotalSupply: u64 = 9;
const EReentrancy: u64 = 10;
const EArithmeticOverflow: u64 = 11;
const ENotUSDC: u64 = 12;
const EBelowMinimumRaise: u64 = 13;

// === Constants ===
/// The duration for every raise is fixed. 14 days in milliseconds.
const LAUNCHPAD_DURATION_MS: u64 = 1_209_600_000;

const STATE_FUNDING: u8 = 0;
const STATE_SUCCESSFUL: u8 = 1;
const STATE_FAILED: u8 = 2;

// === Structs ===

/// A one-time witness for module initialization
public struct LAUNCHPAD has drop {}

// === IMPORTANT: Stable Coin Integration ===
// This module supports any stable coin that has been allowed by the factory.
// Each stable coin type has its own minimum raise amount configured at the factory level.
// 
// Common stable coins and their addresses:
// - USDC Mainnet: 0xdba34672e30cb065b1f93e3ab55318768fd6fef66c15942c9f7cb846e2f900e7::usdc::USDC
// - USDC Testnet: 0xa1ec7fc00a6f40db9693ad1415d0c193ad3906494428cf252621037bd7117e29::usdc::USDC
// 
// To add a new stable coin, use factory::add_allowed_stable_type with the desired minimum raise amount.

// === Scalability Design ===
// This launchpad uses dynamic fields instead of tables for contributor storage.
// Benefits:
// - No hard limits on number of contributors (can handle 100,000+ easily)
// - Each contributor's data is stored separately, improving gas efficiency
// - Supports large raises ($10M+) with many small contributors
// - Only the accessed contributor data is loaded during operations

/// Key type for storing contributor data as dynamic fields
/// This approach allows unlimited contributors without table size constraints
public struct ContributorKey has copy, drop, store {
    contributor: address,
}


/// Main object for a DAO fundraising launchpad.
/// RaiseToken is the governance token being sold.
/// StableCoin is the currency used for contributions (must be allowed by factory).
public struct Raise<phantom RaiseToken, phantom StableCoin> has key, store {
    id: UID,
    creator: address,
    state: u8,
    total_raised: u64,
    min_raise_amount: u64,
    deadline_ms: u64,
    /// Balance of the token being sold to contributors.
    raise_token_vault: Balance<RaiseToken>,
    /// Amount of tokens being sold.
    tokens_for_sale_amount: u64,
    /// Vault for the stable coins contributed by users.
    stable_coin_vault: Balance<StableCoin>,
    /// Number of unique contributors (contributions stored as dynamic fields)
    contributor_count: u64,
    description: String,
    // All parameters required to create the DAO are stored here.
    dao_params: DAOParameters,
    /// TreasuryCap stored until DAO creation
    treasury_cap: Option<TreasuryCap<RaiseToken>>,
    /// Reentrancy guard flag
    claiming: bool,
}

/// Stores all parameters needed for DAO creation to keep the Raise object clean.
public struct DAOParameters has store, drop, copy {
    dao_name: ascii::String,
    icon_url_string: ascii::String,
    review_period_ms: u64,
    trading_period_ms: u64,
    amm_twap_start_delay: u64,
    amm_twap_step_max: u64,
    amm_twap_initial_observation: u128,
    twap_threshold: u64,
    max_outcomes: u64,
    metadata: vector<String>,
    agreement_lines: vector<String>,
    agreement_difficulties: vector<u64>,
}

// === Events ===

public struct RaiseCreated has copy, drop {
    raise_id: ID,
    creator: address,
    raise_token_type: String,
    stable_coin_type: String,
    min_raise_amount: u64,
    tokens_for_sale: u64,
    deadline_ms: u64,
    description: String,
}

public struct ContributionAdded has copy, drop {
    raise_id: ID,
    contributor: address,
    amount: u64,
    new_total_raised: u64,
}

public struct RaiseSuccessful has copy, drop {
    raise_id: ID,
    total_raised: u64,
}

public struct RaiseFailed has copy, drop {
    raise_id: ID,
    total_raised: u64,
    min_raise_amount: u64,
}

public struct TokensClaimed has copy, drop {
    raise_id: ID,
    contributor: address,
    contribution_amount: u64,
    tokens_claimed: u64,
}

public struct RefundClaimed has copy, drop {
    raise_id: ID,
    contributor: address,
    refund_amount: u64,
}

// === Init ===

fun init(_witness: LAUNCHPAD, _ctx: &mut TxContext) {
    // No initialization needed for simplified version
}

// === Public Functions ===

/// Create a raise that sells 100% of the token supply.
/// StableCoin must be an allowed type in the factory with a configured minimum raise amount.
public entry fun create_raise<RaiseToken: drop, StableCoin: drop>(
    factory: &factory::Factory,
    treasury_cap: TreasuryCap<RaiseToken>,
    tokens_for_raise: Coin<RaiseToken>,
    min_raise_amount: u64,
    description: String,
    // DAOParameters passed as individual fields for entry function compatibility
    dao_name: ascii::String,
    icon_url_string: ascii::String,
    review_period_ms: u64,
    trading_period_ms: u64,
    amm_twap_start_delay: u64,
    amm_twap_step_max: u64,
    amm_twap_initial_observation: u128,
    twap_threshold: u64,
    max_outcomes: u64,
    metadata: vector<String>,
    agreement_lines: vector<String>,
    agreement_difficulties: vector<u64>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // CRITICAL: Ensure we're selling 100% of the total supply
    assert!(tokens_for_raise.value() == treasury_cap.total_supply(), EWrongTotalSupply);
    
    // Check that StableCoin is allowed and get minimum raise amount
    assert!(factory::is_stable_type_allowed<StableCoin>(factory), 0);
    let factory_min_raise = factory::get_min_raise_amount<StableCoin>(factory);
    
    // Enforce factory's minimum raise amount for this stable coin type
    assert!(min_raise_amount >= factory_min_raise, EBelowMinimumRaise);
    
    let dao_params = DAOParameters {
        dao_name, icon_url_string, review_period_ms, trading_period_ms,
        amm_twap_start_delay, amm_twap_step_max, amm_twap_initial_observation,
        twap_threshold, max_outcomes, metadata, agreement_lines, agreement_difficulties,
    };
    
    init_raise<RaiseToken, StableCoin>(
        treasury_cap, tokens_for_raise, min_raise_amount, description, dao_params, clock, ctx
    );
}

/// Contribute to an active raise.
public entry fun contribute<RaiseToken, StableCoin>(
    raise: &mut Raise<RaiseToken, StableCoin>,
    contribution: Coin<StableCoin>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(raise.state == STATE_FUNDING, ERaiseNotActive);
    assert!(clock.timestamp_ms() < raise.deadline_ms, ERaiseStillActive);

    let contributor = ctx.sender();
    let amount = contribution.value();

    raise.stable_coin_vault.join(contribution.into_balance());
    
    // Use safe arithmetic to prevent overflow
    let new_total = raise.total_raised + amount;
    assert!(new_total >= raise.total_raised, EArithmeticOverflow);
    raise.total_raised = new_total;

    let contributor_key = ContributorKey { contributor };
    
    // Check if contributor exists using dynamic fields
    if (df::exists_(&raise.id, contributor_key)) {
        let current_contribution: &mut u64 = df::borrow_mut(&mut raise.id, contributor_key);
        *current_contribution = *current_contribution + amount;
    } else {
        df::add(&mut raise.id, contributor_key, amount);
        raise.contributor_count = raise.contributor_count + 1;
    };

    event::emit(ContributionAdded {
        raise_id: object::id(raise),
        contributor,
        amount,
        new_total_raised: raise.total_raised,
    });
}

/// If the raise was successful, this function creates the DAO and transfers funds to the creator.
/// This must be called before contributors can claim their tokens.
public entry fun claim_success_and_create_dao<RaiseToken: drop, StableCoin: drop>(
    raise: &mut Raise<RaiseToken, StableCoin>,
    factory: &mut factory::Factory,
    fee_manager: &mut fee::FeeManager,
    payment: Coin<sui::sui::SUI>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(raise.state == STATE_FUNDING, EInvalidStateForAction);
    assert!(clock.timestamp_ms() >= raise.deadline_ms, EDeadlineNotReached);
    assert!(raise.total_raised >= raise.min_raise_amount, EMinRaiseNotMet);

    raise.state = STATE_SUCCESSFUL;

    // Extract the TreasuryCap if available
    let treasury_cap = if (raise.treasury_cap.is_some()) {
        option::some(raise.treasury_cap.extract())
    } else {
        option::none()
    };

    // Create the DAO using the stored parameters. The DAO's Asset is the new governance
    // token, and its Stable is the coin used in the raise.
    let params = &raise.dao_params;
    factory::create_dao_internal<RaiseToken, StableCoin>(
        factory,
        fee_manager,
        payment,
        0, // min_asset_amount is not relevant for launchpad DAOs
        0, // min_stable_amount is not relevant for launchpad DAOs
        params.dao_name,
        params.icon_url_string,
        params.review_period_ms,
        params.trading_period_ms,
        params.amm_twap_start_delay,
        params.amm_twap_step_max,
        params.amm_twap_initial_observation,
        params.twap_threshold,
        b"Created via Futarchy Launchpad".to_string(), // DAO description
        params.max_outcomes,
        params.metadata,
        params.agreement_lines,
        params.agreement_difficulties,
        treasury_cap,
        clock,
        ctx
    );

    // Transfer the raised funds to the creator
    let raised_funds = coin::from_balance(raise.stable_coin_vault.split(raise.total_raised), ctx);
    transfer::public_transfer(raised_funds, raise.creator);

    event::emit(RaiseSuccessful {
        raise_id: object::id(raise),
        total_raised: raise.total_raised,
    });
}

/// If successful, contributors can call this to claim their share of the governance tokens.
public entry fun claim_tokens<RaiseToken, StableCoin>(
    raise: &mut Raise<RaiseToken, StableCoin>,
    ctx: &mut TxContext,
) {
    assert!(raise.state == STATE_SUCCESSFUL, EInvalidStateForAction);
    
    // Reentrancy guard
    assert!(!raise.claiming, EReentrancy);
    raise.claiming = true;
    
    let contributor = ctx.sender();
    let contributor_key = ContributorKey { contributor };
    
    // Check contributor exists
    assert!(df::exists_(&raise.id, contributor_key), ENotAContributor);
    
    // Remove and get contribution amount
    let contribution: u64 = df::remove(&mut raise.id, contributor_key);

    // Calculate proportional share of tokens
    let tokens_to_claim = math::mul_div_to_64(
        contribution,
        raise.tokens_for_sale_amount,
        raise.total_raised
    );

    let tokens = coin::from_balance(raise.raise_token_vault.split(tokens_to_claim), ctx);
    transfer::public_transfer(tokens, contributor);

    event::emit(TokensClaimed {
        raise_id: object::id(raise),
        contributor,
        contribution_amount: contribution,
        tokens_claimed: tokens_to_claim,
    });
    
    // Reset reentrancy guard
    raise.claiming = false;
}

/// If failed, contributors can call this to get a refund.
public entry fun claim_refund<RaiseToken, StableCoin>(
    raise: &mut Raise<RaiseToken, StableCoin>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(clock.timestamp_ms() >= raise.deadline_ms, EDeadlineNotReached);
    assert!(raise.total_raised < raise.min_raise_amount, EMinRaiseAlreadyMet);

    if (raise.state == STATE_FUNDING) {
        raise.state = STATE_FAILED;
        event::emit(RaiseFailed {
            raise_id: object::id(raise),
            total_raised: raise.total_raised,
            min_raise_amount: raise.min_raise_amount,
        });
    };

    assert!(raise.state == STATE_FAILED, EInvalidStateForAction);
    let contributor = ctx.sender();
    let contributor_key = ContributorKey { contributor };
    
    // Check contributor exists
    assert!(df::exists_(&raise.id, contributor_key), ENotAContributor);
    
    // Remove and get refund amount
    let refund_amount: u64 = df::remove(&mut raise.id, contributor_key);
    let refund_coin = coin::from_balance(raise.stable_coin_vault.split(refund_amount), ctx);
    transfer::public_transfer(refund_coin, contributor);

    event::emit(RefundClaimed {
        raise_id: object::id(raise),
        contributor,
        refund_amount,
    });
}

/// Internal function to initialize a raise.
/// Assumes tokens_for_raise has already been validated to equal total supply
fun init_raise<RaiseToken: drop, StableCoin: drop>(
    treasury_cap: TreasuryCap<RaiseToken>,
    tokens_for_raise: Coin<RaiseToken>,
    min_raise_amount: u64,
    description: String,
    dao_params: DAOParameters,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let tokens_for_sale = tokens_for_raise.value();
    let raise = Raise<RaiseToken, StableCoin> {
        id: object::new(ctx),
        creator: ctx.sender(),
        state: STATE_FUNDING,
        total_raised: 0,
        min_raise_amount,
        deadline_ms: clock.timestamp_ms() + LAUNCHPAD_DURATION_MS,
        raise_token_vault: tokens_for_raise.into_balance(),
        tokens_for_sale_amount: tokens_for_sale,
        stable_coin_vault: balance::zero(),
        contributor_count: 0,
        description,
        dao_params,
        treasury_cap: option::some(treasury_cap),
        claiming: false,
    };

    event::emit(RaiseCreated {
        raise_id: object::id(&raise),
        creator: raise.creator,
        raise_token_type: type_name::get<RaiseToken>().into_string().to_string(),
        stable_coin_type: type_name::get<StableCoin>().into_string().to_string(),
        min_raise_amount,
        tokens_for_sale,
        deadline_ms: raise.deadline_ms,
        description: raise.description,
    });

    transfer::public_share_object(raise);
}

// === View Functions ===

public fun total_raised<RT, SC>(r: &Raise<RT, SC>): u64 { r.total_raised }
public fun state<RT, SC>(r: &Raise<RT, SC>): u8 { r.state }
public fun deadline<RT, SC>(r: &Raise<RT, SC>): u64 { r.deadline_ms }
public fun description<RT, SC>(r: &Raise<RT, SC>): &String { &r.description }
public fun contribution_of<RT, SC>(r: &Raise<RT, SC>, addr: address): u64 {
    let contributor_key = ContributorKey { contributor: addr };
    if (df::exists_(&r.id, contributor_key)) {
        *df::borrow(&r.id, contributor_key)
    } else {
        0
    }
}

public fun contributor_count<RT, SC>(r: &Raise<RT, SC>): u64 { r.contributor_count }