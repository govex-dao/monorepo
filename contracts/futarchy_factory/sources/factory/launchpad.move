// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

module futarchy_factory::launchpad;

use account_actions::init_actions as account_init_actions;
use account_extensions::extensions::Extensions;
use account_protocol::account::{Self, Account};
use futarchy_core::futarchy_config::{Self, FutarchyConfig};
use futarchy_core::priority_queue::ProposalQueue;
use futarchy_core::version;
use futarchy_factory::factory;
use futarchy_factory::init_actions;
use futarchy_markets_core::fee;
use futarchy_markets_core::unified_spot_pool::{Self, UnifiedSpotPool};
use futarchy_one_shot_utils::constants;
use futarchy_one_shot_utils::math;
use futarchy_types::init_action_specs::{Self as action_specs, InitActionSpecs};
use std::option::{Self, Option};
use std::string::{Self, String};
use std::type_name;
use std::vector;
use sui::balance::{Self, Balance};
use sui::clock::Clock;
use sui::coin::{Self, Coin, CoinMetadata, TreasuryCap};
use sui::display::{Self, Display};
use sui::dynamic_field as df;
use sui::event;
use sui::object::{Self, UID, ID};
use sui::package::{Self, Publisher};
use sui::transfer as sui_transfer;
use sui::tx_context::TxContext;

// === Witnesses ===
public struct LaunchpadWitness has drop {}

// === Capabilities ===

/// Capability proving ownership/control of a raise
/// Transferable - allows selling/delegating raise control
public struct CreatorCap has key, store {
    id: UID,
    raise_id: ID,
}

// === Errors ===
const ERaiseStillActive: u64 = 0;
const ERaiseNotActive: u64 = 1;
const EDeadlineNotReached: u64 = 2;
const EMinRaiseNotMet: u64 = 3;
const EMinRaiseAlreadyMet: u64 = 4;
const ENotAContributor: u64 = 6;
const EInvalidStateForAction: u64 = 7;
const EArithmeticOverflow: u64 = 11;
const ENotUSDC: u64 = 12;
const EZeroContribution: u64 = 13;
const EStableTypeNotAllowed: u64 = 14;
const ENotTheCreator: u64 = 15;
const EInvalidActionData: u64 = 16;
const ESettlementNotStarted: u64 = 101;
const ESettlementInProgress: u64 = 102;
const ESettlementAlreadyDone: u64 = 103;
const ECapChangeAfterDeadline: u64 = 105;
const ECapHeapInvariant: u64 = 106;
const ESettlementAlreadyStarted: u64 = 107;
const EInvalidSettlementState: u64 = 108;
const ETooManyUniqueCaps: u64 = 109;
const ETooManyInitActions: u64 = 110;
const EDaoNotPreCreated: u64 = 111;
const EDaoAlreadyPreCreated: u64 = 112;
const EIntentsAlreadyLocked: u64 = 113;
const EResourcesNotFound: u64 = 114;
const EInvalidMaxRaise: u64 = 116;
const EInvalidCapValue: u64 = 120;
const EAllowedCapsNotSorted: u64 = 121;
const EAllowedCapsEmpty: u64 = 122;
const EFinalRaiseAmountZero: u64 = 123;
const EInvalidMinFillPct: u64 = 126; // min_fill_pct must be 0-100
const ECompletionRestricted: u64 = 127; // Completion still restricted to creator
const ETreasuryCapMissing: u64 = 128; // Treasury cap must be pre-locked in DAO
const EMetadataMissing: u64 = 129; // Coin metadata must be supplied before completion
const ESupplyNotZero: u64 = 130; // Treasury cap supply must be zero at raise creation
const EInvalidClaimNFT: u64 = 131; // Claim NFT doesn't match this raise
const EInvalidCreatorCap: u64 = 132; // Creator cap doesn't match this raise
const EEarlyCompletionNotAllowed: u64 = 133; // Early completion not allowed for this raise

// === Constants ===
// Note: Most constants moved to futarchy_one_shot_utils::constants for centralized management

const STATE_FUNDING: u8 = 0;
const STATE_SUCCESSFUL: u8 = 1;
const STATE_FAILED: u8 = 2;

const PERMISSIONLESS_COMPLETION_DELAY_MS: u64 = 24 * 60 * 60 * 1000; // 24 hours

// Max u64 value (used for "no upper limit" in 2D auctions)
const MAX_U64: u64 = 18446744073709551615;

// === Structs ===

/// A one-time witness for module initialization
public struct LAUNCHPAD has drop {}

// === IMPORTANT: Stable Coin Integration ===
// This module supports any stable coin that has been allowed by the factory.
// The creator of a raise sets the minimum raise amount for that specific launchpad.
//
// Common stable coins and their addresses:
// - USDC Mainnet: 0xdba34672e30cb065b1f93e3ab55318768fd6fef66c15942c9f7cb846e2f900e7::usdc::USDC
// - USDC Testnet: 0xa1ec7fc00a6f40db9693ad1415d0c193ad3906494428cf252621037bd7117e29::usdc::USDC
//
// To add a new stable coin type that can be used in launchpads, use factory::add_allowed_stable_type.

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

/// Key types for storing unshared DAO components
public struct DaoAccountKey has copy, drop, store {}
public struct DaoQueueKey has copy, drop, store {}
public struct DaoPoolKey has copy, drop, store {}
public struct DaoMetadataKey has copy, drop, store {}
public struct CoinMetadataKey has copy, drop, store {}

// Key for tracking pending intent specs removed - using staged_init_specs field instead

/// 2D Auction Bid: price cap + quantity FOK + raise interval
/// This is the NEW recommended bid type for variable-supply auctions
///
/// Semantics:
/// - price_cap: "I'll pay at most P per token"
/// - min_tokens: "Give me Q tokens or nothing" (fill-or-kill)
/// - min_total_raise: "Only participate if total raise ≥ L" (liquidity requirement)
/// - max_total_raise: "Only participate if total raise ≤ U" (dilution protection)
///
/// Escrow: Bidder locks `price_cap × min_tokens` upfront
/// At clearing price P* ≤ price_cap:
///   - Winner pays: P* × min_tokens
///   - Refund: (price_cap - P*) × min_tokens
/// If not a winner: Full refund
public struct Bid2D has copy, drop, store {
    price_cap: u64, // p_i^max (with decimals: constants::price_multiplier_scale())
    min_tokens: u64, // q_i^min (FOK - fill or kill)
    min_total_raise: u64, // L_i (lower bound on acceptable T*)
    max_total_raise: u64, // U_i (upper bound on acceptable T*; u64::MAX = no limit)
    timestamp_ms: u64, // Bid time - used for FCFS ordering at settlement
    tokens_allocated: u64, // Set during settlement: 0=loser, min_tokens=winner (determined by bid timestamp FCFS)
    allow_cranking: bool, // If true, anyone can claim on behalf of bidder
}

/// Key type for storing refunds separately from bids
public struct RefundKey has copy, drop, store {
    contributor: address,
}

/// Record for tracking refunds due to supply exhaustion or bid rejection
public struct RefundRecord has drop, store {
    amount: u64,
}

/// === 2D Auction Indexing Structures ===

/// Price-level key for 2D auction bids
public struct PriceKey has copy, drop, store {
    price: u64, // Price tick (p_i^max)
}

/// Interval delta events for T-sweep at a given price level
/// Tracks where bids' [L_i, U_i] intervals start (+) and end (-)
public struct IntervalDeltaKey has copy, drop, store {
    price: u64, // Price level
    t_point: u64, // T value where delta occurs
}

/// Delta record: net change in S(T) at this T-point for this price
/// Tracks bidders in FCFS order for tie-breaking at marginal clearing
public struct IntervalDelta has drop, store {
    delta: u64, // +q_i^min at start, stored separately for add/remove
    is_start: bool, // true = start of interval, false = end
    bidders: vector<address>, // Bidders at this point, in insertion order (FCFS)
}

/// 2D Settlement State: Price-then-T sweep
///
/// Algorithm: For each price p (highest first), sweep T to find fixed point T = p × S(T)
/// where S(T) = Σ q_i^min over bids with p_i^max ≥ p and L_i ≤ T ≤ U_i
///
/// State machine:
/// 1. current_p = 0: Pop next price from heap, load T-events
/// 2. current_p > 0: Sweep T-events, check for fixed point
/// 3. If found: done = true, record (P*, Q*, T*)
/// 4. If exhausted T-events: reset current_p = 0, try next price
public struct CapSettlement2D has key, store {
    id: UID,
    raise_id: ID,
    // Price dimension (outer loop)
    price_heap: vector<u64>, // max-heap of price ticks (sorted high → low)
    price_heap_size: u64,
    current_p: u64, // Current price being processed (0 = need next)
    // T dimension (inner loop per price)
    t_events: vector<u64>, // Sorted T-points where intervals start/end
    t_cursor: u64, // Index into t_events
    s_active: u64, // Running sum S over current [t_k, t_{k+1})
    // Solution
    final_p: u64, // P* (clearing price per token)
    final_q: u64, // Q* (tokens sold = Σ q_i^min of winners)
    final_t: u64, // T* (total raise = P* × Q*)
    done: bool,
    // Rewards (same as 1D)
    initiator: address,
    finalizer: address,
}

/// Mutable configuration for launchpad claim NFT images
/// Allows protocol to update image URL via governance without redeployment
public struct LaunchpadImageConfig has key {
    id: UID,
    /// Image URL for all launchpad claim NFTs
    image_url: String,
}

/// Default protocol image (used if no LaunchpadImageConfig exists)
const DEFAULT_CLAIM_NFT_IMAGE: vector<u8> = b"https://futarchy.app/images/launchpad-claim-nft.png";

/// Claim NFT: Owned object containing pre-calculated claim amounts
/// Enables FULLY PARALLEL claiming without reentrancy guards!
/// All calculations done at mint time, claim just burns NFT and extracts coins.
public struct ClaimNFT<phantom RaiseToken, phantom StableCoin> has key, store {
    id: UID,
    raise_id: ID,
    contributor: address,
    tokens_claimable: u64,
    stable_refund: u64,
    // Display metadata
    name: String,
    description: String,
    image_url: String,
    raise_name: String,
}

/// Main object for a DAO fundraising launchpad.
/// RaiseToken is the governance token being sold.
/// StableCoin is the currency used for contributions (must be allowed by factory).
///
/// Supports TWO auction modes:
/// 1. LEGACY (1D): Fixed supply, variable price via max_total caps
/// 2. NEW (2D): Variable supply, price discovery via Bid2D
public struct Raise<phantom RaiseToken, phantom StableCoin> has key, store {
    id: UID,
    creator: address,
    affiliate_id: String, // Partner identifier (UUID, domain, etc.) - set by creator
    state: u8,
    // OPTIMIZATION: total_raised removed for 10x parallelization
    // Off-chain indexers aggregate from ContributionAddedCapped events
    min_raise_amount: u64,
    max_raise_amount: Option<u64>, // The new creator-defined hard cap (protocol U_0)
    deadline_ms: u64,
    /// Whether the founder can end the raise early if minimum raise amount is met.
    /// Set yes to if you want decntralized holder base and less gaming. Set no to prioirtise instituionals managing large sums of money
    allow_early_completion: bool,
    /// Balance of the token being sold to contributors.
    raise_token_vault: Balance<RaiseToken>,
    /// Amount of tokens being sold (LEGACY: fixed upfront; 2D: set at settlement to Q*)
    tokens_for_sale_amount: u64,
    /// Vault for the stable coins contributed by users.
    stable_coin_vault: Balance<StableCoin>,
    /// Crank pool funded by contributor fees (in SUI)
    /// Split: 50% to finalizer, 50% to crankers (0.05 SUI per cap processed)
    crank_pool: Balance<sui::sui::SUI>,
    /// Number of unique contributors (contributions stored as dynamic fields)
    contributor_count: u64,
    description: String,
    /// Staged init action specifications for DAO configuration (ordered)
    staged_init_specs: vector<InitActionSpecs>,
    /// TreasuryCap stored until DAO creation (used to mint Q* at settlement)
    treasury_cap: Option<TreasuryCap<RaiseToken>>,
    /// === Auction Parameters ===
    /// Price-aware accounting
    allowed_prices: vector<u64>, // Creator-defined allowed price ticks (sorted ascending, ≤128)
    price_thresholds: vector<u64>, // Subset of allowed_prices actually used
    allowed_total_raises: vector<u64>, // Creator-defined allowed T-grid for [L_i, U_i] (≤128, DoS protection)
    max_tokens_for_sale: Option<u64>, // Optional supply ceiling (Q_bar)
    /// === Settlement ===
    settlement_done: bool,
    settlement_in_progress: bool, // Track if settlement has started
    final_total_eligible: u64, // T* from 2D clearing
    final_raise_amount: u64, // Final amount raised (may differ from T* due to supply caps)
    /// === Settlement Results ===
    final_price: u64, // P* (price per token at clearing)
    final_quantity: u64, // Q* (tokens sold at clearing)
    remaining_tokens_2d: u64, // Tokens still available for claiming (FCFS tracker)
    /// Pre-created DAO ID (if DAO was created before raise)
    dao_id: Option<ID>,
    /// Whether init actions can still be added
    intents_locked: bool,
    /// Admin trust score and review (set by protocol DAO validators)
    admin_trust_score: Option<u64>,
    admin_review_text: Option<String>,
    /// Auction type: true = 2D auction (variable supply), false = 1D auction (deprecated)
    is_2d_auction: bool,
    /// 1D DEPRECATED FIELDS (kept for backward compatibility, not used in 2D)
    allowed_caps: vector<u64>,
    thresholds: vector<u64>,
}

// DAOParameters removed - all DAO config is done via init actions
// Use stage_init_actions() to configure the DAO before raise completes

public struct InitIntentStaged has copy, drop {
    raise_id: ID,
    staged_index: u64,
    action_count: u64,
}

public struct InitIntentRemoved has copy, drop {
    raise_id: ID,
    staged_index: u64,
}

public struct FailedRaiseCleanup has copy, drop {
    raise_id: ID,
    dao_id: ID,
    timestamp: u64,
}

public struct RaiseCreated has copy, drop {
    raise_id: ID,
    creator: address,
    affiliate_id: String,
    raise_token_type: String,
    stable_coin_type: String,
    min_raise_amount: u64,
    tokens_for_sale: u64,
    deadline_ms: u64,
    description: String,
}

public struct ContributionAddedCapped has copy, drop {
    raise_id: ID,
    contributor: address,
    amount: u64,
    cap: u64, // max_total specified
    new_naive_total: u64, // naive running sum (pre-cap settlement)
}

public struct SettlementStarted has copy, drop {
    raise_id: ID,
    caps_count: u64,
}

public struct SettlementStep has copy, drop {
    raise_id: ID,
    processed_cap: u64,
    added_amount: u64,
    running_sum: u64,
    next_cap: u64,
}

public struct SettlementFinalized has copy, drop {
    raise_id: ID,
    final_total: u64,
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

public struct RaiseEndedEarly has copy, drop {
    raise_id: ID,
    total_raised: u64,
    original_deadline: u64,
    ended_at: u64,
}

public struct CapBinsSwept has copy, drop {
    raise_id: ID,
    bins_removed: u64,
    sweeper: address,
    timestamp: u64,
}

public struct DustSwept has copy, drop {
    raise_id: ID,
    token_dust_amount: u64,
    stable_dust_amount: u64,
    token_recipient: address,
    stable_recipient: ID, // DAO account ID
    timestamp: u64,
}

public struct TreasuryCapReturned has copy, drop {
    raise_id: ID,
    tokens_burned: u64,
    recipient: address,
    timestamp: u64,
}

public struct SettlementAbandoned has copy, drop {
    raise_id: ID,
    caps_processed: u64,
    caps_remaining: u64,
    final_total: u64,
    timestamp: u64,
}

public struct ClaimNFTMinted has copy, drop {
    nft_id: ID,
    raise_id: ID,
    contributor: address,
    tokens_claimable: u64,
    stable_refund: u64,
}

// === Init ===

/// Initialize module - creates shared LaunchpadImageConfig and publisher
fun init(otw: LAUNCHPAD, ctx: &mut TxContext) {
    // Create shared image config with default image
    let config = LaunchpadImageConfig {
        id: object::new(ctx),
        image_url: string::utf8(DEFAULT_CLAIM_NFT_IMAGE),
    };
    sui_transfer::share_object(config);

    // Create and transfer publisher for Display setup
    let publisher = package::claim(otw, ctx);
    sui_transfer::public_transfer(publisher, ctx.sender());
}

// === Public Functions ===

/// Pre-create a DAO for a raise but keep it unshared
/// This allows adding init intents before the raise starts
/// Treasury cap and metadata remain in Raise until completion
public fun pre_create_dao_for_raise<RaiseToken: drop + store, StableCoin: drop + store>(
    raise: &mut Raise<RaiseToken, StableCoin>,
    creator_cap: &CreatorCap,
    factory: &mut factory::Factory,
    extensions: &Extensions,
    fee_manager: &mut fee::FeeManager,
    payment: Coin<sui::sui::SUI>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Verify creator cap matches this raise
    assert!(creator_cap.raise_id == object::id(raise), EInvalidCreatorCap);
    // Can only pre-create before raise starts
    assert!(raise.state == STATE_FUNDING, EInvalidStateForAction);
    // Can't pre-create if already created
    assert!(raise.dao_id.is_none(), EInvalidStateForAction);

    // Create DAO WITHOUT treasury cap (will be deposited on completion)
    // All config params will be set via init actions
    let (account, queue, spot_pool) = factory::create_dao_unshared<RaiseToken, StableCoin>(
        factory,
        extensions,
        fee_manager,
        payment,
        option::none(), // Use default (true - 10-day challenge period)
        option::none(), // Treasury cap deposited on completion
        clock,
        ctx,
    );

    // Store DAO ID
    raise.dao_id = option::some(object::id(&account));

    // Store unshared components in dynamic fields
    df::add(&mut raise.id, DaoAccountKey {}, account);
    df::add(&mut raise.id, DaoQueueKey {}, queue);
    df::add(&mut raise.id, DaoPoolKey {}, spot_pool);

    // Launchpad init intents will be staged via raise.staged_init_specs
}

/// Stage initialization actions that will run when the raise activates the DAO.
/// Multiple calls append specs until intents are locked.
public fun stage_launchpad_init_intent<RaiseToken, StableCoin>(
    raise: &mut Raise<RaiseToken, StableCoin>,
    creator_cap: &CreatorCap,
    spec: InitActionSpecs,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(creator_cap.raise_id == object::id(raise), EInvalidCreatorCap);
    assert!(raise.state == STATE_FUNDING, EInvalidStateForAction);
    assert!(!raise.intents_locked, EIntentsAlreadyLocked);
    assert!(raise.dao_id.is_some(), EDaoNotPreCreated);
    assert!(df::exists_(&raise.id, DaoAccountKey {}), EResourcesNotFound);

    let action_count = action_specs::action_count(&spec);
    assert!(action_count > 0, EInvalidActionData);

    let mut total = 0u64;
    let staged = &raise.staged_init_specs;
    let staged_len = vector::length(staged);
    let mut i = 0;
    while (i < staged_len) {
        total = total + action_specs::action_count(vector::borrow(staged, i));
        i = i + 1;
    };
    assert!(
        total + action_count <= constants::launchpad_max_init_actions(),
        ETooManyInitActions
    );

    let staged_index = staged_len;
    let raise_id = object::id(raise);

    {
        let account_ref: &mut Account<FutarchyConfig> = df::borrow_mut(&mut raise.id, DaoAccountKey {});
        init_actions::stage_init_intent(
            account_ref,
            &raise_id,
            staged_index,
            &spec,
            clock,
            ctx,
        );
    };

    vector::push_back(&mut raise.staged_init_specs, spec);

    event::emit(InitIntentStaged {
        raise_id,
        staged_index,
        action_count,
    });
}

/// Remove the most recently staged init intent (before intents are locked).
public entry fun unstage_last_launchpad_init_intent<RaiseToken, StableCoin>(
    raise: &mut Raise<RaiseToken, StableCoin>,
    creator_cap: &CreatorCap,
    ctx: &mut TxContext,
) {
    assert!(creator_cap.raise_id == object::id(raise), EInvalidCreatorCap);
    assert!(raise.state == STATE_FUNDING, EInvalidStateForAction);
    assert!(!raise.intents_locked, EIntentsAlreadyLocked);
    assert!(df::exists_(&raise.id, DaoAccountKey {}), EResourcesNotFound);

    let staged_len = vector::length(&raise.staged_init_specs);
    assert!(staged_len > 0, EInvalidStateForAction);
    let staged_index = staged_len - 1;
    let raise_id = object::id(raise);

    {
        let account_ref: &mut Account<FutarchyConfig> = df::borrow_mut(&mut raise.id, DaoAccountKey {});
        init_actions::cancel_init_intent(
            account_ref,
            &raise_id,
            staged_index,
            ctx,
        );
    };

    let _removed = vector::pop_back(&mut raise.staged_init_specs);

    event::emit(InitIntentRemoved {
        raise_id,
        staged_index,
    });
}

/// Lock intents - no more can be added after this
public entry fun lock_intents_and_start_raise<RaiseToken, StableCoin>(
    raise: &mut Raise<RaiseToken, StableCoin>,
    creator_cap: &CreatorCap,
    _ctx: &mut TxContext,
) {
    // Verify creator cap matches this raise
    assert!(creator_cap.raise_id == object::id(raise), EInvalidCreatorCap);
    // Can only lock once
    assert!(!raise.intents_locked, EInvalidStateForAction);

    raise.intents_locked = true;
    // Raise can now begin accepting contributions
}

/// Create a raise that sells tokens to bootstrap a DAO.
/// `StableCoin` must be an allowed type in the factory.
/// DAO configuration is done via init actions - use stage_init_actions() after pre_create_dao_for_raise.

/// Create a 2D auction raise: variable supply, price discovery
/// This is the NEW recommended auction type with better founder incentives
///
/// Key differences from 1D (create_raise):
/// - NO upfront minting: Tokens minted only after settlement determines Q*
/// - Price ticks instead of caps: Investors bid max price per token
/// - Variable supply: Less demand → fewer tokens sold → less dilution
/// - Founder alignment: High price = less dilution + more valuable grants
///
/// Parameters:
/// - affiliate_id: Partner identifier (UUID from subclient, empty string if none)
/// - max_tokens_for_sale: Optional supply ceiling (Q_bar)
/// - min_raise_amount: Protocol minimum (L_0)
/// - max_raise_amount: Optional protocol maximum (U_0)
/// - allowed_prices: Sorted price ticks (≤128 for on-chain feasibility)
public entry fun create_raise_2d<RaiseToken: drop + store, StableCoin: drop + store>(
    factory: &factory::Factory,
    fee_manager: &mut fee::FeeManager,
    treasury_cap: TreasuryCap<RaiseToken>,
    coin_metadata: CoinMetadata<RaiseToken>,
    affiliate_id: String, // Partner identifier (e.g., UUID, domain)
    max_tokens_for_sale: Option<u64>, // Q_bar (optional supply ceiling)
    min_raise_amount: u64, // L_0 (protocol min)
    max_raise_amount: Option<u64>, // U_0 (protocol max)
    allowed_prices: vector<u64>, // Sorted price ticks (bounded to 128)
    allowed_total_raises: vector<u64>, // Sorted T-grid for [L_i, U_i] intervals (bounded to 128)
    allow_early_completion: bool, // Whether founder can end raise early if min met
    description: String,
    launchpad_fee: Coin<sui::sui::SUI>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Collect launchpad creation fee
    fee::deposit_launchpad_creation_payment(fee_manager, launchpad_fee, clock, ctx);

    // CRITICAL: Validate parameters
    assert!(min_raise_amount > 0, EInvalidStateForAction);

    // DoS protection: limit affiliate_id length (UUID is 36 chars, leave room for custom IDs)
    assert!(affiliate_id.length() <= 64, EInvalidStateForAction);

    // CRITICAL: Validate treasury cap and metadata
    assert!(coin::total_supply(&treasury_cap) == 0, ESupplyNotZero);

    // Check that StableCoin is allowed
    assert!(factory::is_stable_type_allowed<StableCoin>(factory), EStableTypeNotAllowed);

    // Validate max_raise_amount
    if (option::is_some(&max_raise_amount)) {
        assert!(*option::borrow(&max_raise_amount) >= min_raise_amount, EInvalidMaxRaise);
    };

    // Validate allowed_prices (P dimension - bounded for DoS protection)
    assert!(!vector::is_empty(&allowed_prices), EAllowedCapsEmpty);
    assert!(is_sorted_ascending(&allowed_prices), EAllowedCapsNotSorted);
    assert!(vector::length(&allowed_prices) <= 128, ETooManyUniqueCaps);

    // Validate allowed_total_raises (T dimension - bounded for DoS protection)
    assert!(!vector::is_empty(&allowed_total_raises), EAllowedCapsEmpty);
    assert!(is_sorted_ascending(&allowed_total_raises), EAllowedCapsNotSorted);
    assert!(vector::length(&allowed_total_raises) <= 128, ETooManyUniqueCaps);

    init_raise_2d<RaiseToken, StableCoin>(
        treasury_cap,
        coin_metadata,
        affiliate_id,
        max_tokens_for_sale,
        min_raise_amount,
        max_raise_amount,
        allowed_prices,
        allowed_total_raises,
        allow_early_completion,
        description,
        clock,
        ctx,
    );
}

/// OPTIMIZATION: Split Read/Write Pattern - Phase 1: Validate (Parallel) (2x parallelization)
///
/// Validates contribution parameters without modifying shared state.
/// Multiple users can call this function in parallel since it's read-only on Raise.
/// Returns ContributionReceipt hot potato that must be consumed by finalize_contribution.
///
/// Benefits:
/// - Parallel validation: 100 validators can run simultaneously
/// - Sequential finalization: Only finalize_contribution touches shared state
/// - 2x throughput improvement via Amdahl's Law (50% parallel validation phase)

/// Enable cranking: allow anyone to claim tokens on your behalf
/// This is useful if you want helpful bots to process your claim automatically
/// For 2D auctions only
public entry fun enable_cranking<RaiseToken, StableCoin>(
    raise: &mut Raise<RaiseToken, StableCoin>,
    ctx: &mut TxContext,
) {
    let contributor = ctx.sender();
    let key = ContributorKey { contributor };
    assert!(df::exists_(&raise.id, key), ENotAContributor);

    let bid: &mut Bid2D = df::borrow_mut(&mut raise.id, key);
    bid.allow_cranking = true;
}

/// Disable cranking: only you can claim your tokens
/// For 2D auctions only
public entry fun disable_cranking<RaiseToken, StableCoin>(
    raise: &mut Raise<RaiseToken, StableCoin>,
    ctx: &mut TxContext,
) {
    let contributor = ctx.sender();
    let key = ContributorKey { contributor };
    assert!(df::exists_(&raise.id, key), ENotAContributor);

    let bid: &mut Bid2D = df::borrow_mut(&mut raise.id, key);
    bid.allow_cranking = false;
}

// === 2D Auction Bidding ===

/// Place a 2D auction bid with full escrow and FOK semantics
///
/// Bid parameters:
/// - price_cap: Maximum price per token (with decimals: constants::price_multiplier_scale())
/// - min_tokens: Minimum tokens (fill-or-kill) - get this exact amount or nothing
/// - min_total_raise: Only participate if total raise ≥ this (liquidity requirement)
/// - max_total_raise: Only participate if total raise ≤ this (dilution protection)
///
/// Escrow: Bidder must provide exactly `price_cap × min_tokens` stablecoins upfront
/// At clearing:
///   - Winner: Pays P* × min_tokens, refunded (price_cap - P*) × min_tokens
///   - Loser: Full refund of escrow
///
/// DoS Protection: Requires crank fee (0.1 SUI)
public entry fun place_bid_2d<RaiseToken, StableCoin>(
    raise: &mut Raise<RaiseToken, StableCoin>,
    escrow: Coin<StableCoin>,
    price_cap: u64,
    min_tokens: u64,
    min_total_raise: u64,
    max_total_raise: u64,
    crank_fee: Coin<sui::sui::SUI>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // SECURITY: Verify this is a 2D auction
    assert!(raise.is_2d_auction, EInvalidStateForAction);

    // Validate state
    assert!(raise.state == STATE_FUNDING, ERaiseNotActive);
    assert!(clock.timestamp_ms() < raise.deadline_ms, ERaiseStillActive);

    let bidder = ctx.sender();

    // SECURITY: Validate bid parameters
    assert!(min_tokens > 0, EZeroContribution);
    assert!(price_cap > 0, EInvalidStateForAction);
    assert!(min_total_raise <= max_total_raise, EInvalidStateForAction);
    assert!(min_total_raise >= raise.min_raise_amount, EInvalidStateForAction);

    // SECURITY: Price cap must be on allowed grid (P dimension DoS protection)
    assert!(is_cap_allowed(price_cap, &raise.allowed_prices), EInvalidCapValue);

    // SECURITY: T-values must be on allowed grid (T dimension DoS protection)
    assert!(is_cap_allowed(min_total_raise, &raise.allowed_total_raises), EInvalidCapValue);
    assert!(
        max_total_raise == MAX_U64 || is_cap_allowed(max_total_raise, &raise.allowed_total_raises),
        EInvalidCapValue,
    );

    // SECURITY: DoS protection - collect crank fee
    assert!(
        crank_fee.value() == constants::launchpad_crank_fee_per_contribution(),
        EInvalidStateForAction,
    );
    raise.crank_pool.join(crank_fee.into_balance());

    // CRITICAL: Validate escrow = price_cap × min_tokens
    // Use safe math to prevent overflow
    let required_escrow = math::mul_div_to_64(price_cap, min_tokens, 1);
    assert!(escrow.value() == required_escrow, EInvalidStateForAction);

    // Deposit escrow
    raise.stable_coin_vault.join(escrow.into_balance());

    // Store bid in dynamic fields
    let key = ContributorKey { contributor: bidder };

    // SECURITY: For 2D auctions, bids are immutable once placed (no updating)
    assert!(!df::exists_(&raise.id, key), EInvalidStateForAction);

    df::add(
        &mut raise.id,
        key,
        Bid2D {
            price_cap,
            min_tokens,
            min_total_raise,
            max_total_raise,
            timestamp_ms: clock.timestamp_ms(), // Record bid time for FCFS ordering
            tokens_allocated: 0, // Will be set during post-settlement allocation
            allow_cranking: false, // Default: only self can claim
        },
    );
    raise.contributor_count = raise.contributor_count + 1;

    // Index price level (if first bid at this price)
    let price_key = PriceKey { price: price_cap };
    if (!df::exists_(&raise.id, price_key)) {
        assert!(vector::length(&raise.price_thresholds) < 128, ETooManyUniqueCaps);
        // Store empty vector of T-points for this price level
        df::add(&mut raise.id, price_key, vector::empty<u64>());
        vector::push_back(&mut raise.price_thresholds, price_cap);
    };

    // Index interval events for T-sweep

    // Start event: at T = min_total_raise, add +min_tokens to S(T)
    let start_key = IntervalDeltaKey { price: price_cap, t_point: min_total_raise };
    let need_start_t_event = if (!df::exists_(&raise.id, start_key)) {
        let mut bidders = vector::empty<address>();
        vector::push_back(&mut bidders, bidder); // First bidder at this point
        df::add(
            &mut raise.id,
            start_key,
            IntervalDelta {
                delta: min_tokens,
                is_start: true,
                bidders, // FCFS order preserved
            },
        );
        true // Need to add to t_events
    } else {
        let delta: &mut IntervalDelta = df::borrow_mut(&mut raise.id, start_key);
        delta.delta = delta.delta + min_tokens;
        vector::push_back(&mut delta.bidders, bidder); // Append = FCFS!
        false // Already in t_events
    };

    // End event: at T = max_total_raise + 1, subtract min_tokens from S(T)
    // (Using +1 for right-exclusive interval semantics)
    let end_t = if (max_total_raise == MAX_U64) {
        max_total_raise // Don't overflow
    } else {
        max_total_raise + 1
    };

    let end_key = IntervalDeltaKey { price: price_cap, t_point: end_t };
    let need_end_t_event = if (!df::exists_(&raise.id, end_key)) {
        let mut bidders = vector::empty<address>();
        vector::push_back(&mut bidders, bidder); // First bidder at this point
        df::add(
            &mut raise.id,
            end_key,
            IntervalDelta {
                delta: min_tokens,
                is_start: false,
                bidders, // FCFS order preserved
            },
        );
        true // Need to add to t_events
    } else {
        let delta: &mut IntervalDelta = df::borrow_mut(&mut raise.id, end_key);
        delta.delta = delta.delta + min_tokens;
        vector::push_back(&mut delta.bidders, bidder); // Append = FCFS!
        false // Already in t_events
    };

    // Now update t_events with new time points (borrow happens last, after all other borrows are done)
    {
        let t_events: &mut vector<u64> = df::borrow_mut(&mut raise.id, price_key);
        if (need_start_t_event) {
            insert_sorted(t_events, min_total_raise);
        };
        if (need_end_t_event) {
            insert_sorted(t_events, end_t);
        };
    };

    // Emit event (reuse ContributionAddedCapped event for now)
    event::emit(ContributionAddedCapped {
        raise_id: object::id(raise),
        contributor: bidder,
        amount: required_escrow,
        cap: price_cap, // In 2D, this is price cap
        new_naive_total: 0,
    });
}

// === Max-heap helpers over vector<u64> ===
fun parent(i: u64): u64 { if (i == 0) 0 else (i - 1) / 2 }

fun left(i: u64): u64 { 2 * i + 1 }

fun right(i: u64): u64 { 2 * i + 2 }

fun heapify_down(v: &mut vector<u64>, mut i: u64, size: u64) {
    loop {
        let l = left(i);
        let r = right(i);
        let mut largest = i;

        if (l < size && *vector::borrow(v, l) > *vector::borrow(v, largest)) {
            largest = l;
        };
        if (r < size && *vector::borrow(v, r) > *vector::borrow(v, largest)) {
            largest = r;
        };
        if (largest == i) break;
        vector::swap(v, i, largest);
        i = largest;
    }
}

fun build_max_heap(v: &mut vector<u64>) {
    let sz = vector::length(v);
    let mut i = if (sz == 0) { 0 } else { (sz - 1) / 2 };
    loop {
        heapify_down(v, i, sz);
        if (i == 0) break;
        i = i - 1;
    };
}

fun heap_peek(v: &vector<u64>, size: u64): u64 {
    if (size == 0) 0 else *vector::borrow(v, 0)
}

fun heap_pop(v: &mut vector<u64>, size_ref: &mut u64): u64 {
    assert!(*size_ref > 0, ECapHeapInvariant);
    let last = *size_ref - 1;
    let top = *vector::borrow(v, 0);
    if (last != 0) {
        vector::swap(v, 0, last);
    };
    let _ = vector::pop_back(v);
    *size_ref = last;
    if (last > 0) {
        heapify_down(v, 0, last);
    };
    top
}

/// Insert value into max-heap, maintaining heap property
fun heap_insert(v: &mut vector<u64>, value: u64) {
    vector::push_back(v, value);
    let mut i = vector::length(v) - 1;

    // Bubble up
    while (i > 0) {
        let p = parent(i);
        if (*vector::borrow(v, i) <= *vector::borrow(v, p)) break;
        vector::swap(v, i, p);
        i = p;
    };
}

/// Insert value into sorted vector (ascending order) using binary search
fun insert_sorted(v: &mut vector<u64>, value: u64) {
    let len = vector::length(v);

    // Empty vector - just push
    if (len == 0) {
        vector::push_back(v, value);
        return
    };

    // Find insertion point using binary search
    let mut left = 0;
    let mut right = len;

    while (left < right) {
        let mid = left + (right - left) / 2;
        let mid_val = *vector::borrow(v, mid);

        if (mid_val < value) {
            left = mid + 1;
        } else if (mid_val > value) {
            right = mid;
        } else {
            // Value already exists - don't insert duplicate
            return
        };
    };

    // Insert at position 'left'
    vector::push_back(v, value);
    let mut i = len;
    while (i > left) {
        vector::swap(v, i, i - 1);
        i = i - 1;
    };
}

/// Start settlement: snapshot caps into a heap

// ============================================================================
// 2D AUCTION SETTLEMENT (Price-Then-T Sweep Algorithm)
// ============================================================================

/// Begin 2D settlement: snapshot price ticks into max-heap, initialize T-sweep state
/// For 2D auctions only (variable supply: discover P*, Q*, T* where T* = P* × Q*)
/// Algorithm: O(n log n) with price-first sweep, then T-sweep per price level
public fun begin_settlement_2d<RT, SC>(
    raise: &mut Raise<RT, SC>,
    clock: &Clock,
    ctx: &mut TxContext,
): CapSettlement2D {
    // Validate this is a 2D auction
    assert!(raise.is_2d_auction, EInvalidStateForAction);
    assert!(raise.state == STATE_FUNDING, EInvalidStateForAction);
    assert!(clock.timestamp_ms() >= raise.deadline_ms, EDeadlineNotReached);
    assert!(!raise.settlement_in_progress, ESettlementInProgress);
    assert!(!raise.settlement_done, ESettlementAlreadyDone);

    // Mark settlement as in progress
    raise.settlement_in_progress = true;

    // Build max-heap of price ticks (descending order)
    let price_count = vector::length(&raise.price_thresholds);
    let mut heap = vector::empty<u64>();
    let mut i = 0;
    while (i < price_count) {
        let price = *vector::borrow(&raise.price_thresholds, i);
        heap_insert(&mut heap, price);
        i = i + 1;
    };

    // Create settlement state machine
    let s = CapSettlement2D {
        id: object::new(ctx),
        raise_id: object::id(raise),
        // Price dimension (outer loop)
        price_heap: heap,
        price_heap_size: price_count,
        current_p: 0, // 0 = need to pop next price
        // T dimension (inner loop per price)
        t_events: vector::empty<u64>(),
        t_cursor: 0,
        s_active: 0,
        // Solution
        final_p: 0,
        final_q: 0,
        final_t: 0,
        done: false,
        initiator: ctx.sender(),
        finalizer: @0x0,
    };

    event::emit(SettlementStarted { raise_id: object::id(raise), caps_count: price_count });
    s
}

/// Crank 2D settlement: process up to `steps` price levels or T-events
/// Finds fixed point where T* = P* × S_p(T*) for step function S_p(T)
/// Pays cranker 0.05 SUI per price level processed
public entry fun crank_settlement_2d<RT, SC>(
    raise: &mut Raise<RT, SC>,
    s: &mut CapSettlement2D,
    steps: u64,
    ctx: &mut TxContext,
) {
    assert!(object::id(raise) == s.raise_id, EInvalidStateForAction);
    assert!(!s.done, ESettlementAlreadyDone);
    assert!(raise.state == STATE_FUNDING, EInvalidStateForAction);
    assert!(raise.settlement_in_progress, EInvalidSettlementState);
    assert!(raise.is_2d_auction, EInvalidStateForAction);

    // SECURITY: Limit steps to prevent DOS
    let actual_steps = if (steps > 100) { 100 } else { steps };

    let mut prices_processed = 0;
    let mut step_count = 0;

    while (step_count < actual_steps && !s.done) {
        // ========== OUTER LOOP: Price Dimension ==========
        // If current_p == 0, pop next price from heap
        if (s.current_p == 0) {
            if (s.price_heap_size == 0) {
                // No more prices to process
                // If we haven't found a solution yet, no fixed point exists
                s.done = true;
                break
            };

            // Pop highest remaining price
            s.current_p = heap_pop(&mut s.price_heap, &mut s.price_heap_size);
            prices_processed = prices_processed + 1;

            // Collect all T-events for this price level
            // Scan all bids at this price, extract [L_i, U_i] intervals
            s.t_events = vector::empty<u64>();
            s.t_cursor = 0;
            s.s_active = 0;

            // Extract interval deltas for this price from dynamic fields
            // IntervalDeltaKey { price: s.current_p, t_point: T }
            // This is simplified - actual implementation needs to iterate bids
            // For now, we'll handle this in the T-sweep below
        };

        // ========== INNER LOOP: T Dimension (Sweep) ==========
        // Build T-events list for current price level if not already built
        if (s.t_cursor == 0 && vector::length(&s.t_events) == 0) {
            // Get sorted T-events for this price level
            let price_key = PriceKey { price: s.current_p };

            // Read the T-events vector we built during bidding
            if (!df::exists_(&raise.id, price_key)) {
                // No bids at this price level - skip to next price
                s.current_p = 0;
                step_count = step_count + 1;
                continue
            };

            let t_points: &vector<u64> = df::borrow(&raise.id, price_key);
            s.t_events = *t_points; // Copy into settlement state

            // Skip to next price if no T-events
            if (vector::length(&s.t_events) == 0) {
                s.current_p = 0;
                step_count = step_count + 1;
                continue
            };

            // Reset T-sweep state for this price level
            s.t_cursor = 0;
            s.s_active = 0;
        };

        // Process T-events for current price
        if (s.t_cursor < vector::length(&s.t_events)) {
            let t = *vector::borrow(&s.t_events, s.t_cursor);

            // Update s_active based on delta at this T-point
            let delta_key = IntervalDeltaKey { price: s.current_p, t_point: t };
            if (df::exists_(&raise.id, delta_key)) {
                let delta: &IntervalDelta = df::borrow(&raise.id, delta_key);

                // Apply delta: add for start events, subtract for end events
                if (delta.is_start) {
                    s.s_active = s.s_active + delta.delta;
                } else {
                    // End event - subtract delta
                    assert!(s.s_active >= delta.delta, EArithmeticOverflow);
                    s.s_active = s.s_active - delta.delta;
                };
            };

            // Check fixed point condition: T = P × S(T)
            // For interval [t_k, t_{k+1}), check if T* exists in this interval
            let next_t = if (s.t_cursor + 1 < vector::length(&s.t_events)) {
                *vector::borrow(&s.t_events, s.t_cursor + 1)
            } else {
                MAX_U64
            };

            // Fixed point check: t_k ≤ P × S_active < t_{k+1}
            let p_times_s = math::mul_div_to_64(s.current_p, s.s_active, 1);

            if (p_times_s >= t && p_times_s < next_t) {
                // Found fixed point!
                s.final_p = s.current_p;
                s.final_q = s.s_active;
                s.final_t = p_times_s;
                s.done = true;
                break
            };

            s.t_cursor = s.t_cursor + 1;
            step_count = step_count + 1;
        } else {
            // Finished T-sweep for this price, move to next price
            s.current_p = 0;
            step_count = step_count + 1;
        };
    };

    // If all prices exhausted and no fixed point, settlement fails (T* = 0)
    if (s.price_heap_size == 0 && s.current_p == 0 && !s.done) {
        s.final_p = 0;
        s.final_q = 0;
        s.final_t = 0;
        s.done = true;
    };

    // CRANK REWARD: Pay 0.05 SUI per price level processed
    if (prices_processed > 0) {
        let per_price_reward = constants::launchpad_reward_per_cap_processed();
        assert!(prices_processed <= MAX_U64 / per_price_reward, EArithmeticOverflow);

        let reward_amount = prices_processed * per_price_reward;
        let pool_balance = raise.crank_pool.value();

        let actual_reward = if (reward_amount > pool_balance) {
            pool_balance
        } else {
            reward_amount
        };

        if (actual_reward > 0) {
            let reward = coin::from_balance(raise.crank_pool.split(actual_reward), ctx);
            sui_transfer::public_transfer(reward, ctx.sender());
        };
    };

    event::emit(SettlementStep {
        raise_id: s.raise_id,
        processed_cap: s.current_p,
        added_amount: s.s_active,
        running_sum: s.final_t,
        next_cap: if (s.price_heap_size > 0) { heap_peek(&s.price_heap, s.price_heap_size) } else {
            0
        },
    });
}

/// Finalize 2D settlement: record (P*, Q*, T*), mint Q* tokens, pay rewards
/// For 2D auctions, this mints the discovered quantity Q* rather than fixed supply
/// Pays finalizer 75% of remaining crank pool, initiator gets 25%
public fun finalize_settlement_2d<RaiseToken: drop + store, StableCoin: drop + store>(
    raise: &mut Raise<RaiseToken, StableCoin>,
    s: &mut CapSettlement2D,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(object::id(raise) == s.raise_id, EInvalidStateForAction);
    assert!(s.done, ESettlementNotStarted);
    assert!(!raise.settlement_done, ESettlementAlreadyDone);
    assert!(raise.settlement_in_progress, EInvalidSettlementState);
    assert!(raise.state == STATE_FUNDING, EInvalidStateForAction);
    assert!(raise.is_2d_auction, EInvalidStateForAction);

    // Record settlement results (P*, Q*, T*)
    raise.final_price = s.final_p;
    raise.final_quantity = s.final_q;
    raise.final_total_eligible = s.final_t;
    raise.remaining_tokens_2d = s.final_q; // Initialize FCFS tracker

    // Sanity check: If no raise amount, vault should be empty
    assert!(
        raise.final_total_eligible > 0 || raise.stable_coin_vault.value() == 0,
        EInvalidSettlementState,
    );

    // CRITICAL: Mint Q* tokens now (variable supply)
    // 2D auctions don't mint upfront - they discover the quantity at settlement
    if (s.final_q > 0) {
        // Borrow treasury cap (stored in raise for 2D auctions)
        assert!(option::is_some(&raise.treasury_cap), EInvalidStateForAction);
        let treasury_cap = option::borrow_mut(&mut raise.treasury_cap);

        // Mint exactly Q* tokens discovered by auction
        let minted = coin::mint<RaiseToken>(treasury_cap, s.final_q, ctx);

        // Deposit into raise vault for distribution to winners
        raise.raise_token_vault.join(minted.into_balance());
        raise.tokens_for_sale_amount = s.final_q;
    };

    raise.settlement_done = true;
    raise.settlement_in_progress = false;

    // Record finalizer
    s.finalizer = ctx.sender();

    // CRANK REWARD: Split remaining pool between initiator (25%) and finalizer (75%)
    let remaining_pool = raise.crank_pool.value();
    if (remaining_pool > 0) {
        let initiator_share = remaining_pool / 4;
        if (initiator_share > 0) {
            let initiator_reward = coin::from_balance(
                raise.crank_pool.split(initiator_share),
                ctx,
            );
            sui_transfer::public_transfer(initiator_reward, s.initiator);
        };

        let finalizer_share = raise.crank_pool.value();
        if (finalizer_share > 0) {
            let finalizer_reward = coin::from_balance(
                raise.crank_pool.split(finalizer_share),
                ctx,
            );
            sui_transfer::public_transfer(finalizer_reward, s.finalizer);
        };
    };

    event::emit(SettlementFinalized {
        raise_id: object::id(raise),
        final_total: s.final_t,
    });
}

/// Entry function to start 2D settlement and share the settlement object
public entry fun start_settlement_2d<RT, SC>(
    raise: &mut Raise<RT, SC>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let settlement = begin_settlement_2d(raise, clock, ctx);
    sui_transfer::public_share_object(settlement);
}

/// Entry function to finalize 2D settlement
public entry fun complete_settlement_2d<RaiseToken: drop + store, StableCoin: drop + store>(
    raise: &mut Raise<RaiseToken, StableCoin>,
    s: &mut CapSettlement2D,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    finalize_settlement_2d(raise, s, clock, ctx);
}

/// Allocate tokens to winning bidders in FCFS order (post-settlement step)
/// Must be called after settlement completes, can be cranked in batches
/// Iterates through bidders at clearing price in insertion order
public entry fun allocate_tokens_fcfs_2d<RaiseToken, StableCoin>(
    raise: &mut Raise<RaiseToken, StableCoin>,
    batch_size: u64, // Number of bids to process per crank
) {
    assert!(raise.is_2d_auction, EInvalidStateForAction);
    assert!(raise.settlement_done, ESettlementNotStarted);

    // Get clearing price and remaining supply
    let final_p = raise.final_price;
    let final_t = raise.final_total_eligible;
    let mut remaining = raise.remaining_tokens_2d;

    // Find the IntervalDelta at the clearing point
    // This contains all bidders who are eligible at (P*, T*)
    let clearing_key = IntervalDeltaKey { price: final_p, t_point: final_t };

    if (!df::exists_(&raise.id, clearing_key)) {
        // No marginal bids at exact clearing point
        return
    };

    // Copy the bidders vector to avoid holding a borrow during the loop
    let bidders = {
        let delta: &IntervalDelta = df::borrow(&raise.id, clearing_key);
        *&delta.bidders // Copy the vector
    };
    let len = vector::length(&bidders);

    // Process bidders in FCFS order (vector order = insertion order)
    let mut i = 0;
    let mut processed = 0;
    while (i < len && processed < batch_size) {
        let bidder = *vector::borrow(&bidders, i);
        let key = ContributorKey { contributor: bidder };

        if (df::exists_(&raise.id, key)) {
            let bid: &mut Bid2D = df::borrow_mut(&mut raise.id, key);

            // Skip if already allocated
            if (bid.tokens_allocated == 0) {
                // Check if this bidder wins (FOK)
                if (remaining >= bid.min_tokens) {
                    bid.tokens_allocated = bid.min_tokens; // WINNER!
                    remaining = remaining - bid.min_tokens;
                } else {
                    bid.tokens_allocated = 0; // LOSER (stays 0)
                };
            };
        };

        i = i + 1;
        processed = processed + 1;
    };

    // Update remaining supply
    raise.remaining_tokens_2d = remaining;
}

// ============================================================================
// END 2D AUCTION SETTLEMENT
// ============================================================================

/// Sweep unused cap-bins after settlement completes early
/// If settlement finds T* before processing all caps, remaining bins are never removed
/// This function cleans up that storage to prevent permanent bloat

/// Allow creator to end raise early
/// OPTIMIZATION: Removed minimum raise check (requires total_raised counter)
/// Creator can end early if allowed by configuration
///
/// Requirements:
/// - Creator cap required
/// - Before deadline
/// - Early completion must be allowed for this raise
public entry fun end_raise_early<RT, SC>(
    raise: &mut Raise<RT, SC>,
    creator_cap: &CreatorCap,
    clock: &Clock,
    _ctx: &mut TxContext,
) {
    // Verify creator cap matches this raise
    assert!(creator_cap.raise_id == object::id(raise), EInvalidCreatorCap);

    // Must still be in funding state
    assert!(raise.state == STATE_FUNDING, EInvalidStateForAction);

    // Must not have already passed deadline
    assert!(clock.timestamp_ms() < raise.deadline_ms, EDeadlineNotReached);

    // Check if early completion is allowed for this raise
    assert!(raise.allow_early_completion, EEarlyCompletionNotAllowed);

    // Save original deadline before modifying
    let original_deadline = raise.deadline_ms;

    // Set deadline to now, effectively ending the raise
    raise.deadline_ms = clock.timestamp_ms();

    event::emit(RaiseEndedEarly {
        raise_id: object::id(raise),
        total_raised: 0, // OPTIMIZATION: Off-chain indexer calculates from events
        original_deadline,
        ended_at: clock.timestamp_ms(),
    });
}

/// Creator-only fast path to finalize a raise once settlement is complete.
/// Allows founders to close as soon as the market has cleared, before the permissionless window.
public entry fun close_raise_early<RaiseToken: drop + store, StableCoin: drop + store>(
    raise: &mut Raise<RaiseToken, StableCoin>,
    creator_cap: &CreatorCap,
    factory: &mut factory::Factory,
    extensions: &Extensions,
    fee_manager: &mut fee::FeeManager,
    payment: Coin<sui::sui::SUI>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Verify creator cap matches this raise
    assert!(creator_cap.raise_id == object::id(raise), EInvalidCreatorCap);
    assert!(raise.state == STATE_FUNDING, EInvalidStateForAction);
    assert!(clock.timestamp_ms() >= raise.deadline_ms, EDeadlineNotReached);
    assert!(raise.settlement_done, ESettlementNotStarted);

    complete_raise_internal(
        raise,
        factory,
        extensions,
        fee_manager,
        payment,
        clock,
        ctx,
    );
}

/// Activates pre-created DAO and executes pending intents
/// If init actions fail and init_actions_must_succeed is true, the raise fails
/// This ensures atomic execution - either all init actions succeed or the raise fails
public entry fun claim_success_and_activate_dao<RaiseToken: drop + store, StableCoin: drop + store>(
    raise: &mut Raise<RaiseToken, StableCoin>,
    factory: &mut factory::Factory,
    extensions: &Extensions,
    fee_manager: &mut fee::FeeManager,
    payment: Coin<sui::sui::SUI>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(raise.state == STATE_FUNDING, EInvalidStateForAction);
    assert!(clock.timestamp_ms() >= raise.deadline_ms, EDeadlineNotReached);
    assert!(raise.settlement_done, ESettlementNotStarted);

    let permissionless_open = raise.deadline_ms + PERMISSIONLESS_COMPLETION_DELAY_MS;
    if (clock.timestamp_ms() < permissionless_open) {
        assert!(ctx.sender() == raise.creator, ECompletionRestricted);
    };

    complete_raise_internal(
        raise,
        factory,
        extensions,
        fee_manager,
        payment,
        clock,
        ctx,
    );
}

fun complete_raise_internal<RaiseToken: drop + store, StableCoin: drop + store>(
    raise: &mut Raise<RaiseToken, StableCoin>,
    _factory: &mut factory::Factory,
    _extensions: &Extensions,
    fee_manager: &mut fee::FeeManager,
    payment: Coin<sui::sui::SUI>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(raise.state == STATE_FUNDING, EInvalidStateForAction);
    assert!(raise.settlement_done, ESettlementNotStarted);
    assert!(raise.dao_id.is_some(), EDaoNotPreCreated);

    // CRITICAL: Verify treasury cap and metadata exist and match
    assert!(raise.treasury_cap.is_some(), ETreasuryCapMissing);
    assert!(df::exists_(&raise.id, CoinMetadataKey {}), EMetadataMissing);

    // Process payment
    fee::deposit_dao_creation_payment(fee_manager, payment, clock, ctx);

    // Use T* from the settlement algorithm
    let consensual_total = raise.final_total_eligible;
    assert!(consensual_total >= raise.min_raise_amount, EMinRaiseNotMet);
    assert!(consensual_total > 0, EMinRaiseNotMet);

    // --- The final raise is the lesser of the market consensus and the creator's hard cap. ---
    let final_total = if (option::is_some(&raise.max_raise_amount)) {
        math::min(consensual_total, *option::borrow(&raise.max_raise_amount))
    } else {
        consensual_total
    };

    // Store this final capped amount for claims and refunds
    raise.final_raise_amount = final_total;

    // SECURITY: Verify invariants
    assert!(raise.final_raise_amount <= raise.final_total_eligible, EInvalidSettlementState);
    assert!(raise.final_raise_amount <= raise.stable_coin_vault.value(), EInvalidSettlementState);

    // Extract the unshared DAO components
    let mut account: Account<FutarchyConfig> = df::remove(&mut raise.id, DaoAccountKey {});
    let mut queue: ProposalQueue<StableCoin> = df::remove(&mut raise.id, DaoQueueKey {});
    let mut spot_pool: UnifiedSpotPool<RaiseToken, StableCoin> = df::remove(
        &mut raise.id,
        DaoPoolKey {},
    );

    // Extract and deposit treasury cap into DAO account
    let treasury_cap = raise.treasury_cap.extract();
    account_init_actions::init_lock_treasury_cap<FutarchyConfig, RaiseToken>(
        &mut account,
        treasury_cap,
    );

    // Extract and deposit metadata into DAO account
    let metadata: CoinMetadata<RaiseToken> = df::remove(&mut raise.id, CoinMetadataKey {});
    account_init_actions::init_store_object<
        FutarchyConfig,
        DaoMetadataKey,
        CoinMetadata<RaiseToken>,
    >(
        &mut account,
        DaoMetadataKey {},
        metadata,
        ctx,
    );

    // CRITICAL: Set the launchpad initial price (write-once, immutable)
    // This is the canonical raise price: tokens_for_sale / final_raise_amount
    // Used to enforce: 1) AMM initialization ratio, 2) founder reward minimum price

    // Validate non-zero amounts
    assert!(raise.tokens_for_sale_amount > 0, EInvalidStateForAction);
    assert!(raise.final_raise_amount > 0, EInvalidStateForAction);

    let raise_price = {
        // Use safe math to calculate: (stable * price_multiplier_scale) / tokens
        // MUST match AMM spot price precision (1e9) to ensure consistency
        math::mul_div_mixed(
            (raise.final_raise_amount as u128),
            constants::price_multiplier_scale(),
            (raise.tokens_for_sale_amount as u128),
        )
    };

    futarchy_config::set_launchpad_initial_price(
        futarchy_config::internal_config_mut(&mut account, version::current()),
        raise_price,
    );

    // NOTE: Init actions are now executed via PTB after raise completes.
    // Frontend reads staged_init_specs from chain and constructs deterministic PTB.
    // See INIT_ACTIONS_GUIDE.md for details.
    //
    // The staged_init_specs remain stored for PTB construction reference.

    // Deposit the capped raise amount into the DAO treasury vault.
    let raised_funds = coin::from_balance(
        raise.stable_coin_vault.split(raise.final_raise_amount),
        ctx,
    );
    account_init_actions::init_vault_deposit_default<FutarchyConfig, StableCoin>(
        &mut account,
        raised_funds,
        ctx,
    );

    // Mark successful only if we reach here (init actions succeeded)
    raise.state = STATE_SUCCESSFUL;

    // Share all objects now that everything succeeded
    sui_transfer::public_share_object(account);
    sui_transfer::public_share_object(queue);
    unified_spot_pool::share(spot_pool);

    event::emit(RaiseSuccessful {
        raise_id: object::id(raise),
        total_raised: raise.final_raise_amount,
    });
}

/// If successful, claim tokens for a contributor.
/// Only the contributor themselves can claim, unless they've enabled cranking via enable_cranking().
/// This allows helpful bots to crank token distribution in chunks for opted-in users.

/// Claim tokens for 2D auction winners (FOK semantics)
/// In 2D auctions, bidders either get EXACTLY their min_tokens or get a full refund
/// Winner criteria: price_cap >= P* AND [L_i, U_i] contains T*
public entry fun claim_tokens_2d<RaiseToken: drop + store, StableCoin: drop + store>(
    raise: &mut Raise<RaiseToken, StableCoin>,
    recipient: address,
    ctx: &mut TxContext,
) {
    // SECURITY: Verify this is a 2D auction
    assert!(raise.is_2d_auction, EInvalidStateForAction);
    assert!(raise.state == STATE_SUCCESSFUL, EInvalidStateForAction);
    assert!(raise.settlement_done, ESettlementNotStarted);

    let caller = ctx.sender();
    let key = ContributorKey { contributor: recipient };
    assert!(df::exists_(&raise.id, key), ENotAContributor);

    // Read bid to check permissions
    let bid_check: &Bid2D = df::borrow(&raise.id, key);
    assert!(caller == recipient || bid_check.allow_cranking, ENotTheCreator);

    // SECURITY: Remove bid to prevent double-claim
    let bid: Bid2D = df::remove(&mut raise.id, key);
    raise.contributor_count = raise.contributor_count - 1;

    // Get settlement results (P*, Q*, T*)
    let final_p = raise.final_price;
    let final_t = raise.final_total_eligible;

    // FOK WINNER CHECK:
    // 1. Price condition: bid.price_cap >= P*
    // 2. Interval condition: L_i <= T* <= U_i
    let price_ok = bid.price_cap >= final_p;
    let interval_ok = (bid.min_total_raise <= final_t) && (final_t <= bid.max_total_raise);

    if (!price_ok || !interval_ok) {
        // LOSER: Full refund
        let escrow_amount = math::mul_div_to_64(bid.price_cap, bid.min_tokens, 1);
        let refund_coin = coin::from_balance(raise.stable_coin_vault.split(escrow_amount), ctx);
        sui_transfer::public_transfer(refund_coin, recipient);

        event::emit(RefundClaimed {
            raise_id: object::id(raise),
            contributor: recipient,
            refund_amount: escrow_amount,
        });

        return
    };

    // Check allocation (set during post-settlement FCFS allocation)
    if (bid.tokens_allocated == 0) {
        // LOSER: Didn't get allocation (marginal loser or lost on price/interval)
        let escrow_amount = math::mul_div_to_64(bid.price_cap, bid.min_tokens, 1);
        let refund_coin = coin::from_balance(raise.stable_coin_vault.split(escrow_amount), ctx);
        sui_transfer::public_transfer(refund_coin, recipient);

        event::emit(RefundClaimed {
            raise_id: object::id(raise),
            contributor: recipient,
            refund_amount: escrow_amount,
        });

        return
    };

    // WINNER: Got allocation - proceed with token distribution
    let payment_amount = math::mul_div_to_64(final_p, bid.tokens_allocated, 1);
    let escrow_amount = math::mul_div_to_64(bid.price_cap, bid.min_tokens, 1);

    // Transfer tokens (exactly tokens_allocated - FOK semantics enforced at allocation time)
    let tokens = coin::from_balance(raise.raise_token_vault.split(bid.tokens_allocated), ctx);
    sui_transfer::public_transfer(tokens, recipient);

    event::emit(TokensClaimed {
        raise_id: object::id(raise),
        contributor: recipient,
        contribution_amount: payment_amount,
        tokens_claimed: bid.min_tokens,
    });

    // Refund the difference: escrow - payment
    // Bidder locked (price_cap × min_tokens) but only pays (P* × min_tokens)
    let refund_due = escrow_amount - payment_amount;
    if (refund_due > 0) {
        let refund_key = RefundKey { contributor: recipient };
        if (!df::exists_(&raise.id, refund_key)) {
            df::add(&mut raise.id, refund_key, RefundRecord { amount: refund_due });
        } else {
            let existing: &mut RefundRecord = df::borrow_mut(&mut raise.id, refund_key);
            existing.amount = existing.amount + refund_due;
        };
    };
}

/// Mint claim NFTs for 2D auction bidders (FULLY PARALLEL!)
/// This is the recommended claiming pattern for high-throughput 2D auctions.
///
/// Process:
/// 1. After settlement and FCFS allocation, anyone can mint NFTs for bidders (batched)
/// 2. All calculations done here (winner check, FOK allocation, refund math)
/// 3. Bidders get owned ClaimNFT objects
/// 4. Claiming with NFTs is FULLY PARALLEL (no reentrancy guard needed!)
///
/// SECURITY: Removes bid record when minting NFT to prevent double-claiming
/// After NFT is minted, bidder can ONLY claim via NFT (not via claim_tokens_2d)
///
/// Benefits vs claim_tokens_2d():
/// - 100x parallelization (no global claiming lock)
/// - Simpler code (no reentrancy guard)
/// - Better UX (visible owned NFTs)
/// - Transferable claims (optional feature)
public entry fun mint_claim_nfts_2d<RaiseToken, StableCoin>(
    raise: &mut Raise<RaiseToken, StableCoin>,
    image_config: &LaunchpadImageConfig,
    contributors: vector<address>,
    ctx: &mut TxContext,
) {
    assert!(raise.is_2d_auction, EInvalidStateForAction);
    assert!(raise.state == STATE_SUCCESSFUL, EInvalidStateForAction);
    assert!(raise.settlement_done, ESettlementNotStarted);

    let final_p = raise.final_price;
    let final_t = raise.final_total_eligible;

    let len = vector::length(&contributors);
    let mut i = 0;

    while (i < len) {
        let addr = *vector::borrow(&contributors, i);
        let key = ContributorKey { contributor: addr };

        // Skip if bidder doesn't exist (already claimed or never bid)
        if (df::exists_(&raise.id, key)) {
            // SECURITY: Remove bid record to prevent double-claiming
            let bid: Bid2D = df::remove(&mut raise.id, key);
            raise.contributor_count = raise.contributor_count - 1;

            // Calculate tokens and refunds (FOK semantics for 2D)
            let escrow_amount = math::mul_div_to_64(bid.price_cap, bid.min_tokens, 1);

            // Winner check: price_cap >= P* AND L_i <= T* <= U_i AND tokens_allocated > 0
            let price_ok = bid.price_cap >= final_p;
            let interval_ok = (bid.min_total_raise <= final_t) && (final_t <= bid.max_total_raise);

            let (tokens_claimable, stable_refund) = if (
                price_ok && interval_ok && bid.tokens_allocated > 0
            ) {
                // WINNER: Got allocation
                let payment_amount = math::mul_div_to_64(final_p, bid.tokens_allocated, 1);
                let refund_due = escrow_amount - payment_amount;
                (bid.tokens_allocated, refund_due)
            } else {
                // LOSER: Full refund, no tokens
                (0, escrow_amount)
            };

            // Mint ClaimNFT (owned object = no conflicts!)
            // Build display metadata
            let name = string::utf8(b"Launchpad Claim NFT");
            let description = format_claim_description(
                tokens_claimable,
                stable_refund,
                &raise.description,
            );
            let image_url = get_claim_image_url(image_config);

            let nft = ClaimNFT<RaiseToken, StableCoin> {
                id: object::new(ctx),
                raise_id: object::id(raise),
                contributor: addr,
                tokens_claimable,
                stable_refund,
                name,
                description,
                image_url,
                raise_name: raise.description,
            };

            let nft_id = object::id(&nft);

            // Transfer NFT to bidder
            sui_transfer::public_transfer(nft, addr);

            // Emit event
            event::emit(ClaimNFTMinted {
                nft_id,
                raise_id: object::id(raise),
                contributor: addr,
                tokens_claimable,
                stable_refund,
            });
        };

        i = i + 1;
    };
}

/// Claim tokens and refunds with ClaimNFT for 2D auctions (FULLY PARALLEL!)
/// This function has NO reentrancy guard because each NFT is an owned object.
/// Multiple bidders can claim simultaneously without any conflicts!
///
/// Security: NFT is hot potato - must be consumed (destroyed) in this function.
public entry fun claim_with_nft_2d<RaiseToken: drop + store, StableCoin: drop + store>(
    raise: &mut Raise<RaiseToken, StableCoin>,
    nft: ClaimNFT<RaiseToken, StableCoin>,
    ctx: &mut TxContext,
) {
    // Verify NFT matches this raise
    assert!(nft.raise_id == object::id(raise), EInvalidClaimNFT);
    assert!(raise.is_2d_auction, EInvalidStateForAction);
    assert!(raise.state == STATE_SUCCESSFUL, EInvalidStateForAction);

    // Destructure NFT (hot potato pattern)
    let ClaimNFT {
        id,
        raise_id: _,
        contributor,
        tokens_claimable,
        stable_refund,
        name: _,
        description: _,
        image_url: _,
        raise_name: _,
    } = nft;

    // Extract tokens if any
    if (tokens_claimable > 0) {
        let tokens = coin::from_balance(
            raise.raise_token_vault.split(tokens_claimable),
            ctx,
        );
        sui_transfer::public_transfer(tokens, contributor);

        event::emit(TokensClaimed {
            raise_id: object::id(raise),
            contributor,
            contribution_amount: 0, // Not tracked in NFT (kept simple)
            tokens_claimed: tokens_claimable,
        });
    };

    // Extract refund if any
    if (stable_refund > 0) {
        let refund = coin::from_balance(
            raise.stable_coin_vault.split(stable_refund),
            ctx,
        );
        sui_transfer::public_transfer(refund, contributor);

        event::emit(RefundClaimed {
            raise_id: object::id(raise),
            contributor,
            refund_amount: stable_refund,
        });
    };

    // Delete NFT (consumed hot potato)
    object::delete(id);

    // NOTE: No reentrancy guard needed! NFTs are owned objects.
    // Multiple claims can execute in parallel with zero conflicts! ✨
}

/// Cleanup resources for a failed raise
/// This properly handles pre-created DAO components that couldn't be shared
/// Objects with UID need special handling - they can't just be dropped
public entry fun cleanup_failed_raise<RaiseToken: drop + store, StableCoin: drop + store>(
    raise: &mut Raise<RaiseToken, StableCoin>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Only callable after deadline
    assert!(clock.timestamp_ms() >= raise.deadline_ms, EDeadlineNotReached);

    // Only for failed raises
    // OPTIMIZATION: Check settlement or vault balance (no total_raised counter)
    if (raise.settlement_done) {
        assert!(raise.final_total_eligible < raise.min_raise_amount, EMinRaiseAlreadyMet);
    } else {
        // No settlement done - check vault balance
        assert!(raise.stable_coin_vault.value() < raise.min_raise_amount, EMinRaiseAlreadyMet);
    };

    // Mark as failed if not already
    if (raise.state != STATE_FAILED) {
        raise.state = STATE_FAILED;
    };

    // CRITICAL FIX: Clean up treasury cap and minted tokens
    // Failed raises must return treasury cap to creator and burn unsold tokens
    if (raise.treasury_cap.is_some()) {
        let mut cap = raise.treasury_cap.extract();
        let bal = raise.raise_token_vault.value();
        if (bal > 0) {
            // Burn all unsold tokens back into the treasury cap
            let tokens_to_burn = coin::from_balance(raise.raise_token_vault.split(bal), ctx);
            coin::burn(&mut cap, tokens_to_burn);
        };
        // Return treasury cap to creator so they can reuse it
        sui_transfer::public_transfer(cap, raise.creator);

        // Emit event for tracking
        event::emit(TreasuryCapReturned {
            raise_id: object::id(raise),
            tokens_burned: bal,
            recipient: raise.creator,
            timestamp: clock.timestamp_ms(),
        });
    };

    // Clean up pre-created DAO if it exists
    if (raise.dao_id.is_some()) {
        // Note: When init actions fail, the transaction reverts atomically
        // so these unshared components won't exist in dynamic fields.
        // This cleanup is only needed if DAO was pre-created but raise failed
        // for other reasons (e.g., didn't meet min raise amount)

        if (
            !vector::is_empty(&raise.staged_init_specs) &&
            df::exists_(&raise.id, DaoAccountKey {})
        ) {
            let raise_id = object::id(raise);
            {
                let account_ref: &mut Account<FutarchyConfig> = df::borrow_mut(&mut raise.id, DaoAccountKey {});
                init_actions::cleanup_init_intents(
                    account_ref,
                    &raise_id,
                    &raise.staged_init_specs,
                    ctx,
                );
            };
            raise.staged_init_specs = vector::empty();
        };

        // Properly handle objects with UID - they need to be shared or transferred
        if (df::exists_(&raise.id, DaoAccountKey {})) {
            let account: Account<FutarchyConfig> = df::remove(&mut raise.id, DaoAccountKey {});
            // Share the account so it can be cleaned up later by admin
            // This is safe because the raise failed and DAO won't be used
            sui_transfer::public_share_object(account);
        };

        if (df::exists_(&raise.id, DaoQueueKey {})) {
            let queue: ProposalQueue<StableCoin> = df::remove(&mut raise.id, DaoQueueKey {});
            // Share the queue for cleanup
            sui_transfer::public_share_object(queue);
        };

        if (df::exists_(&raise.id, DaoPoolKey {})) {
            let pool: UnifiedSpotPool<RaiseToken, StableCoin> = df::remove(
                &mut raise.id,
                DaoPoolKey {},
            );
            // Use the module's share function for proper handling
            unified_spot_pool::share(pool);
        };

        // Save DAO ID before clearing
        let dao_id = if (raise.dao_id.is_some()) {
            *raise.dao_id.borrow()
        } else {
            object::id_from_address(@0x0)
        };

        // Clear DAO ID
        raise.dao_id = option::none();

        // Emit event for tracking cleanup
        event::emit(FailedRaiseCleanup {
            raise_id: object::id(raise),
            dao_id,
            timestamp: clock.timestamp_ms(),
        });
    };

    if (df::exists_(&raise.id, CoinMetadataKey {})) {
        let metadata: CoinMetadata<RaiseToken> = df::remove(&mut raise.id, CoinMetadataKey {});
        sui_transfer::public_transfer(metadata, raise.creator);
    };
}

/// Refund for eligible contributors who were partially refunded due to hard cap
public entry fun claim_hard_cap_refund<RaiseToken: drop + store, StableCoin: drop + store>(
    raise: &mut Raise<RaiseToken, StableCoin>,
    ctx: &mut TxContext,
) {
    assert!(raise.state == STATE_SUCCESSFUL, EInvalidStateForAction);
    assert!(raise.settlement_done, ESettlementNotStarted);

    let who = ctx.sender();
    let refund_key = RefundKey { contributor: who };

    // Check if user has a refund due to hard cap
    assert!(df::exists_(&raise.id, refund_key), ENotAContributor);

    // Remove and get refund record
    let refund_rec: RefundRecord = df::remove(&mut raise.id, refund_key);

    // Create refund coin
    let refund_coin = coin::from_balance(raise.stable_coin_vault.split(refund_rec.amount), ctx);
    sui_transfer::public_transfer(refund_coin, who);

    event::emit(RefundClaimed {
        raise_id: object::id(raise),
        contributor: who,
        refund_amount: refund_rec.amount,
    });
}

/// Refund for failed raises only
/// Note: For successful raises, use claim_tokens() which auto-refunds ineligible contributors
public entry fun claim_refund<RaiseToken: drop + store, StableCoin: drop + store>(
    raise: &mut Raise<RaiseToken, StableCoin>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(clock.timestamp_ms() >= raise.deadline_ms, EDeadlineNotReached);

    // For failed raises, check if settlement is done to determine if it failed
    // OPTIMIZATION: Use settlement or vault balance (no total_raised counter)
    if (raise.settlement_done) {
        // Settlement done, check if final total met minimum
        if (raise.final_total_eligible >= raise.min_raise_amount) {
            // Successful raise - use claim_tokens() instead (it auto-refunds ineligible)
            abort EInvalidStateForAction
        };
    } else {
        // No settlement done, check vault balance
        assert!(raise.stable_coin_vault.value() < raise.min_raise_amount, EMinRaiseAlreadyMet);
    };

    if (raise.state == STATE_FUNDING) {
        raise.state = STATE_FAILED;
        event::emit(RaiseFailed {
            raise_id: object::id(raise),
            total_raised: 0, // OPTIMIZATION: Off-chain indexer calculates from events
            min_raise_amount: raise.min_raise_amount,
        });
    };

    assert!(raise.state == STATE_FAILED, EInvalidStateForAction);
    let contributor = ctx.sender();
    let contributor_key = ContributorKey { contributor };

    // Check contributor exists
    assert!(df::exists_(&raise.id, contributor_key), ENotAContributor);

    // For 2D auctions, refund the full escrow amount
    let bid: Bid2D = df::remove(&mut raise.id, contributor_key);
    raise.contributor_count = raise.contributor_count - 1;

    // Calculate escrow amount (price_cap × min_tokens)
    let escrow_amount = math::mul_div_to_64(bid.price_cap, bid.min_tokens, 1);
    let refund_coin = coin::from_balance(raise.stable_coin_vault.split(escrow_amount), ctx);
    sui_transfer::public_transfer(refund_coin, contributor);

    event::emit(RefundClaimed {
        raise_id: object::id(raise),
        contributor,
        refund_amount: escrow_amount,
    });
}

/// After a successful raise and a claim period, sweep any remaining "dust" tokens or stablecoins.
/// - Raise tokens: Go to creator (unsold governance tokens from rounding)
/// - Stablecoins: Go to DAO treasury (contributor funds from rounding)
public entry fun sweep_dust<RaiseToken: drop + store, StableCoin: drop + store>(
    raise: &mut Raise<RaiseToken, StableCoin>,
    creator_cap: &CreatorCap,
    dao_account: &mut Account<FutarchyConfig>, // DAO Account to receive stablecoin dust
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(raise.state == STATE_SUCCESSFUL, EInvalidStateForAction);
    // Verify creator cap matches this raise
    assert!(creator_cap.raise_id == object::id(raise), EInvalidCreatorCap);

    // Verify this is the correct DAO for this raise
    assert!(raise.dao_id.is_some(), EDaoNotPreCreated);
    assert!(object::id(dao_account) == *raise.dao_id.borrow(), EInvalidStateForAction);

    // Ensure the claim period has passed. The claim period starts after the raise deadline.
    assert!(
        clock.timestamp_ms() >= raise.deadline_ms + constants::launchpad_claim_period_ms(),
        EDeadlineNotReached, // Reusing error, implies "claim deadline not reached"
    );

    // Sweep remaining raise tokens (from token distribution rounding)
    // These go to creator since they're unsold governance tokens
    let remaining_token_balance = raise.raise_token_vault.value();
    if (remaining_token_balance > 0) {
        let dust_tokens = coin::from_balance(
            raise.raise_token_vault.split(remaining_token_balance),
            ctx,
        );
        sui_transfer::public_transfer(dust_tokens, raise.creator);
    };

    // Sweep remaining stablecoins (from refund/hard-cap rounding)
    // These go to DAO treasury since they're contributor funds
    let remaining_stable_balance = raise.stable_coin_vault.value();
    if (remaining_stable_balance > 0) {
        let dust_stable = coin::from_balance(
            raise.stable_coin_vault.split(remaining_stable_balance),
            ctx,
        );
        account_init_actions::init_vault_deposit_default<FutarchyConfig, StableCoin>(
            dao_account,
            dust_stable,
            ctx,
        );
    };

    // Emit event for transparency
    event::emit(DustSwept {
        raise_id: object::id(raise),
        token_dust_amount: remaining_token_balance,
        stable_dust_amount: remaining_stable_balance,
        token_recipient: raise.creator,
        stable_recipient: object::id(dao_account),
        timestamp: clock.timestamp_ms(),
    });
}

/// Internal function to initialize a raise.

/// Internal function to initialize a 2D auction raise (variable supply)
///
/// Key difference from init_raise_internal:
/// - Does NOT mint tokens upfront (will mint Q* at settlement)
/// - Uses allowed_prices instead of allowed_caps
/// - Sets is_2d_auction = true
fun init_raise_2d<RaiseToken: drop + store, StableCoin: drop + store>(
    treasury_cap: TreasuryCap<RaiseToken>,
    coin_metadata: CoinMetadata<RaiseToken>,
    affiliate_id: String,
    max_tokens_for_sale: Option<u64>,
    min_raise_amount: u64,
    max_raise_amount: Option<u64>,
    allowed_prices: vector<u64>,
    allowed_total_raises: vector<u64>,
    allow_early_completion: bool,
    description: String,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Validate allowed_prices (already done in entry function, but double-check)
    assert!(!vector::is_empty(&allowed_prices), EAllowedCapsEmpty);
    assert!(is_sorted_ascending(&allowed_prices), EAllowedCapsNotSorted);

    // Validate allowed_total_raises
    assert!(!vector::is_empty(&allowed_total_raises), EAllowedCapsEmpty);
    assert!(is_sorted_ascending(&allowed_total_raises), EAllowedCapsNotSorted);

    // CRITICAL: Validate treasury cap
    let treasury_cap = treasury_cap;
    assert!(coin::total_supply(&treasury_cap) == 0, ESupplyNotZero);

    if (option::is_some(&max_raise_amount)) {
        assert!(*option::borrow(&max_raise_amount) >= min_raise_amount, EInvalidMaxRaise);
    };

    // NO upfront minting - tokens will be minted at settlement based on Q*
    let deadline = clock.timestamp_ms() + constants::launchpad_duration_ms();

    let mut raise = Raise<RaiseToken, StableCoin> {
        id: object::new(ctx),
        creator: ctx.sender(),
        affiliate_id,
        state: STATE_FUNDING,
        min_raise_amount,
        max_raise_amount,
        deadline_ms: deadline,
        allow_early_completion,
        raise_token_vault: balance::zero(), // Empty - will mint Q* at settlement
        tokens_for_sale_amount: 0, // Will be set to Q* at settlement
        stable_coin_vault: balance::zero(),
        crank_pool: balance::zero(),
        contributor_count: 0,
        description,
        staged_init_specs: vector::empty(),
        treasury_cap: option::some(treasury_cap), // Held until settlement
        // 1D AUCTION (not used)
        allowed_caps: vector::empty<u64>(),
        thresholds: vector::empty<u64>(),
        // 2D AUCTION (active)
        allowed_prices,
        price_thresholds: vector::empty<u64>(), // Filled as bids come in
        allowed_total_raises, // T-grid for DoS protection
        max_tokens_for_sale,
        // Settlement
        settlement_done: false,
        settlement_in_progress: false,
        final_total_eligible: 0,
        final_raise_amount: 0,
        // 2D Settlement Results
        final_price: 0, // P* (set at settlement)
        final_quantity: 0, // Q* (set at settlement)
        remaining_tokens_2d: 0, // Initialized at finalize_settlement_2d
        dao_id: option::none(),
        intents_locked: false,
        admin_trust_score: option::none(),
        admin_review_text: option::none(),
        is_2d_auction: true, // This is a 2D auction!
    };

    df::add(&mut raise.id, CoinMetadataKey {}, coin_metadata);

    let raise_id = object::id(&raise);

    event::emit(RaiseCreated {
        raise_id,
        creator: raise.creator,
        affiliate_id: raise.affiliate_id,
        raise_token_type: string::from_ascii(type_name::get<RaiseToken>().into_string()),
        stable_coin_type: string::from_ascii(type_name::get<StableCoin>().into_string()),
        min_raise_amount,
        tokens_for_sale: 0, // Variable supply - will be determined at settlement
        deadline_ms: raise.deadline_ms,
        description: raise.description,
    });

    // Mint and transfer CreatorCap to creator
    let creator_cap = CreatorCap {
        id: object::new(ctx),
        raise_id,
    };
    sui_transfer::public_transfer(creator_cap, raise.creator);

    sui_transfer::public_share_object(raise);
}

// === Helper Functions ===

/// Check if a vector of u64 is sorted in ascending order
fun is_sorted_ascending(v: &vector<u64>): bool {
    let len = vector::length(v);
    if (len <= 1) return true;

    let mut i = 0;
    while (i < len - 1) {
        if (*vector::borrow(v, i) >= *vector::borrow(v, i + 1)) {
            return false
        };
        i = i + 1;
    };
    true
}

/// Check if a cap is in the allowed caps list (binary search since sorted)
fun is_cap_allowed(cap: u64, allowed_caps: &vector<u64>): bool {
    let len = vector::length(allowed_caps);
    let mut left = 0;
    let mut right = len;

    while (left < right) {
        let mid = left + (right - left) / 2;
        let mid_val = *vector::borrow(allowed_caps, mid);

        if (mid_val == cap) {
            return true
        } else if (mid_val < cap) {
            left = mid + 1;
        } else {
            right = mid;
        };
    };
    false
}

// === View Functions ===

/// OPTIMIZATION: Returns vault balance instead of counter (10x parallelization)
/// Off-chain indexers should aggregate from ContributionAddedCapped events for real-time totals
public fun total_raised<RT, SC>(r: &Raise<RT, SC>): u64 {
    r.stable_coin_vault.value()
}

public fun state<RT, SC>(r: &Raise<RT, SC>): u8 { r.state }

public fun deadline<RT, SC>(r: &Raise<RT, SC>): u64 { r.deadline_ms }

public fun description<RT, SC>(r: &Raise<RT, SC>): &String { &r.description }

public fun contribution_of<RT, SC>(r: &Raise<RT, SC>, addr: address): u64 {
    let key = ContributorKey { contributor: addr };
    if (df::exists_(&r.id, key)) {
        // For 2D auctions, return the escrow amount (price_cap × min_tokens)
        let bid: &Bid2D = df::borrow(&r.id, key);
        math::mul_div_to_64(bid.price_cap, bid.min_tokens, 1)
    } else {
        0
    }
}

public fun final_total_eligible<RT, SC>(r: &Raise<RT, SC>): u64 { r.final_total_eligible }

public fun settlement_done<RT, SC>(r: &Raise<RT, SC>): bool { r.settlement_done }

public fun settlement_in_progress<RT, SC>(r: &Raise<RT, SC>): bool { r.settlement_in_progress }

public fun contributor_count<RT, SC>(r: &Raise<RT, SC>): u64 { r.contributor_count }

/// Check if a contributor has enabled cranking (allows others to claim on their behalf)
/// For 2D auctions only
public fun is_cranking_enabled<RT, SC>(r: &Raise<RT, SC>, addr: address): bool {
    let key = ContributorKey { contributor: addr };
    if (df::exists_(&r.id, key)) {
        let bid: &Bid2D = df::borrow(&r.id, key);
        bid.allow_cranking
    } else {
        false
    }
}

/// Get admin trust score if set
public fun admin_trust_score<RT, SC>(r: &Raise<RT, SC>): &Option<u64> {
    &r.admin_trust_score
}

/// Get admin review text if set
public fun admin_review_text<RT, SC>(r: &Raise<RT, SC>): &Option<String> {
    &r.admin_review_text
}

// === Admin Functions ===

/// Set admin trust score and review (called by protocol admin actions)
public fun set_admin_trust_score<RT, SC>(
    raise: &mut Raise<RT, SC>,
    _validator_cap: &factory::ValidatorAdminCap,
    trust_score: u64,
    review_text: String,
) {
    raise.admin_trust_score = option::some(trust_score);
    raise.admin_review_text = option::some(review_text);
}

// === Image Configuration Functions ===

/// Update the image URL for all future launchpad claim NFTs
/// Package-private so it can only be called through governance actions
public(package) fun update_claim_image(config: &mut LaunchpadImageConfig, new_url: String) {
    config.image_url = new_url;
}

/// Get the current image URL from config
public fun get_claim_image_url(config: &LaunchpadImageConfig): String {
    config.image_url
}

// === Helper Functions for ClaimNFT Display ===

/// Format description for claim NFT (optimized byte vector building)
fun format_claim_description(tokens: u64, refund: u64, raise_name: &String): String {
    // Pre-allocate buffer with estimated capacity to minimize reallocations
    // "Claim " + tokens + " tokens + " + refund + " stablecoin refund from " + raise_name
    // Approximate: 50 bytes + raise_name length
    let mut buffer = vector::empty<u8>();
    let raise_name_bytes = string::bytes(raise_name);

    // Build message directly in bytes (avoids intermediate String allocations)
    vector::append(&mut buffer, b"Claim ");

    if (tokens > 0) {
        append_u64_bytes(&mut buffer, tokens);
        vector::append(&mut buffer, b" tokens");
        if (refund > 0) {
            vector::append(&mut buffer, b" + ");
        };
    };

    if (refund > 0) {
        append_u64_bytes(&mut buffer, refund);
        vector::append(&mut buffer, b" stablecoin refund");
    };

    vector::append(&mut buffer, b" from ");
    vector::append(&mut buffer, *raise_name_bytes);

    // Convert to string once at the end
    string::utf8(buffer)
}

/// Append u64 as ASCII bytes to vector (avoids intermediate String allocation)
fun append_u64_bytes(buffer: &mut vector<u8>, value: u64) {
    if (value == 0) {
        vector::push_back(buffer, 48); // ASCII '0'
        return
    };

    // Calculate digits in reverse
    let mut digits = vector::empty<u8>();
    let mut n = value;

    while (n > 0) {
        let digit = ((n % 10) as u8) + 48; // ASCII '0' = 48
        vector::push_back(&mut digits, digit);
        n = n / 10;
    };

    // Append in correct order (reverse of calculated)
    let len = vector::length(&digits);
    let mut i = 0;
    while (i < len) {
        let digit = *vector::borrow(&digits, len - 1 - i);
        vector::push_back(buffer, digit);
        i = i + 1;
    };
}

// === Display Setup (one-time publisher call) ===

/// Initialize display for claim NFTs
public fun create_claim_display<RaiseToken, StableCoin>(
    publisher: &Publisher,
    ctx: &mut TxContext,
): Display<ClaimNFT<RaiseToken, StableCoin>> {
    let keys = vector[
        string::utf8(b"name"),
        string::utf8(b"description"),
        string::utf8(b"image_url"),
        string::utf8(b"raise_id"),
        string::utf8(b"raise_name"),
        string::utf8(b"contributor"),
        string::utf8(b"tokens_claimable"),
        string::utf8(b"stable_refund"),
    ];

    let values = vector[
        string::utf8(b"{name}"),
        string::utf8(b"{description}"),
        string::utf8(b"{image_url}"),
        string::utf8(b"{raise_id}"),
        string::utf8(b"{raise_name}"),
        string::utf8(b"{contributor}"),
        string::utf8(b"{tokens_claimable}"),
        string::utf8(b"{stable_refund}"),
    ];

    let mut display = display::new_with_fields<ClaimNFT<RaiseToken, StableCoin>>(
        publisher,
        keys,
        values,
        ctx,
    );

    display::update_version(&mut display);
    display
}
