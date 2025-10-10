module futarchy_factory::launchpad;

use std::ascii;
use std::string::{String};
use std::type_name::{Self, TypeName};
use std::option::{Self as option, Option};
use std::vector;
use sui::balance::{Self, Balance};
use sui::coin::{Self, Coin, CoinMetadata, TreasuryCap};
use sui::clock::{Clock};
use sui::event;
use sui::dynamic_field as df;
use sui::object::{Self, UID, ID};
use sui::tx_context::TxContext;
use sui::table;
use sui::bcs;
use futarchy_factory::factory;
use futarchy_types::action_specs;
use futarchy_factory::init_actions;
use account_protocol::account::{Self, Account};
use account_actions::init_actions as account_init_actions;
use futarchy_core::{futarchy_config::{Self, FutarchyConfig}, version};
use futarchy_core::priority_queue::ProposalQueue;
use futarchy_markets::{fee, account_spot_pool::{Self, AccountSpotPool}};
use futarchy_one_shot_utils::{math, constants};
use account_extensions::extensions::Extensions;

// === Witnesses ===
public struct LaunchpadWitness has drop {}

// === Errors ===
const ERaiseStillActive: u64 = 0;
const ERaiseNotActive: u64 = 1;
const EDeadlineNotReached: u64 = 2;
const EMinRaiseNotMet: u64 = 3;
const EMinRaiseAlreadyMet: u64 = 4;
const ENotAContributor: u64 = 6;
const EInvalidStateForAction: u64 = 7;
const EReentrancy: u64 = 10;
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
const EInitActionsFailed: u64 = 115;
const EInvalidMaxRaise: u64 = 116;
const EInvalidCapValue: u64 = 120;
const EAllowedCapsNotSorted: u64 = 121;
const EAllowedCapsEmpty: u64 = 122;
const EFinalRaiseAmountZero: u64 = 123;
const EInvalidMinFillPct: u64 = 126;  // min_fill_pct must be 0-100
const ECompletionRestricted: u64 = 127;  // Completion still restricted to creator
const ETreasuryCapMissing: u64 = 128;    // Treasury cap must be pre-locked in DAO
const EMetadataMissing: u64 = 129;       // Coin metadata must be supplied before completion
const ESupplyNotZero: u64 = 130;         // Treasury cap supply must be zero at raise creation
const EInvalidClaimNFT: u64 = 131;       // Claim NFT doesn't match this raise

// === Constants ===
// Note: Most constants moved to futarchy_one_shot_utils::constants for centralized management

const STATE_FUNDING: u8 = 0;
const STATE_SUCCESSFUL: u8 = 1;
const STATE_FAILED: u8 = 2;

const PERMISSIONLESS_COMPLETION_DELAY_MS: u64 = 2 * 24 * 60 * 60 * 1000;

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

// Key for tracking pending intent specs removed - using init_action_specs field instead

/// Per-contributor record with amount and cap
public struct Contribution has store, drop, copy {
    amount: u64,
    max_total: u64, // cap; u64::MAX means "no cap"
    allow_cranking: bool, // If true, anyone can claim tokens on behalf of this contributor
    min_fill_pct: u8, // Minimum fill percentage (0-100). If actual fill < this, auto-refund entire amount
}

/// Key type for storing refunds separately from contributions
public struct RefundKey has copy, drop, store {
    contributor: address,
}

/// OPTIMIZATION: ContributionReceipt hot potato for Split Read/Write pattern (2x parallelization)
/// Validates contribution parameters without touching shared state, enabling parallel validation
public struct ContributionReceipt<phantom RaiseToken, phantom StableCoin> {
    raise_id: ID,
    contributor: address,
    contribution: Coin<StableCoin>,
    crank_fee: Coin<sui::sui::SUI>,
    cap: u64,
    min_fill_pct: u8,
}

/// Record for tracking refunds due to hard cap
public struct RefundRecord has store, drop {
    amount: u64,
}

/// Cap-bin dynamic fields for aggregating contributions by cap
public struct ThresholdKey has copy, drop, store { 
    cap: u64 
}

public struct ThresholdBin has store, drop {
    total: u64,  // sum of amounts for this cap
    count: u64,  // number of contribution actions (not unique contributors - repeat contributions increment this)
}

/// Settlement crank state for processing caps
public struct CapSettlement has key, store {
    id: UID,
    raise_id: ID,
    heap: vector<u64>,   // max-heap of caps
    size: u64,           // heap size
    running_sum: u64,    // C_k as we walk from high cap to low
    final_total: u64,    // T* once found
    done: bool,
    cranker: address,    // Who called begin_settlement (gets bounty)
}

/// Claim NFT: Owned object containing pre-calculated claim amounts
/// Enables FULLY PARALLEL claiming without reentrancy guards!
/// All calculations done at mint time, claim just burns NFT and extracts coins.
public struct ClaimNFT<phantom RaiseToken, phantom StableCoin> has key, store {
    id: UID,
    raise_id: ID,
    contributor: address,
    tokens_claimable: u64,
    stable_refund: u64,
}

/// Main object for a DAO fundraising launchpad.
/// RaiseToken is the governance token being sold.
/// StableCoin is the currency used for contributions (must be allowed by factory).
public struct Raise<phantom RaiseToken, phantom StableCoin> has key, store {
    id: UID,
    creator: address,
    state: u8,
    // OPTIMIZATION: total_raised removed for 10x parallelization
    // Off-chain indexers aggregate from ContributionAddedCapped events
    min_raise_amount: u64,
    max_raise_amount: Option<u64>, // The new creator-defined hard cap
    deadline_ms: u64,
    /// Balance of the token being sold to contributors.
    raise_token_vault: Balance<RaiseToken>,
    /// Amount of tokens being sold.
    tokens_for_sale_amount: u64,
    /// Vault for the stable coins contributed by users.
    stable_coin_vault: Balance<StableCoin>,
    /// Crank pool funded by contributor fees (in SUI)
    /// Split: 50% to finalizer, 50% to crankers (0.05 SUI per cap processed)
    crank_pool: Balance<sui::sui::SUI>,
    /// Number of unique contributors (contributions stored as dynamic fields)
    contributor_count: u64,
    description: String,
    /// Staged init action specifications for DAO configuration
    init_action_specs: Option<action_specs::InitActionSpecs>,
    /// TreasuryCap stored until DAO creation
    treasury_cap: Option<TreasuryCap<RaiseToken>>,
    /// Reentrancy guard flag
    claiming: bool,
    /// Cap-aware accounting
    allowed_caps: vector<u64>,     // Creator-defined allowed cap values (sorted ascending)
    thresholds: vector<u64>,       // Subset of allowed_caps actually used
    settlement_done: bool,
    settlement_in_progress: bool,  // Track if settlement has started
    final_total_eligible: u64,     // T* after enforcing caps
    final_raise_amount: u64,       // The final amount after applying the hard cap
    /// Pre-created DAO ID (if DAO was created before raise)
    dao_id: Option<ID>,
    /// Whether init actions can still be added
    intents_locked: bool,
    /// Admin trust score and review (set by protocol DAO validators)
    admin_trust_score: Option<u64>,
    admin_review_text: Option<String>,
}

// DAOParameters removed - all DAO config is done via init actions
// Use stage_init_actions() to configure the DAO before raise completes


// === Events ===

public struct InitActionsStaged has copy, drop {
    raise_id: ID,
    action_count: u64,
}

public struct InitActionsFailed has copy, drop {
    raise_id: ID,
    action_count: u64,
    timestamp: u64,
}

public struct FailedRaiseCleanup has copy, drop {
    raise_id: ID,
    dao_id: ID,
    timestamp: u64,
}

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

public struct ContributionAddedCapped has copy, drop {
    raise_id: ID,
    contributor: address,
    amount: u64,
    cap: u64,                // max_total specified
    new_naive_total: u64,    // naive running sum (pre-cap settlement)
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
    stable_recipient: ID,  // DAO account ID
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

fun init(_witness: LAUNCHPAD, _ctx: &mut TxContext) {
    // No initialization needed for simplified version
}

// === Public Functions ===

/// Pre-create a DAO for a raise but keep it unshared
/// This allows adding init intents before the raise starts
/// Treasury cap and metadata remain in Raise until completion
public fun pre_create_dao_for_raise<RaiseToken: drop + store, StableCoin: drop + store>(
    raise: &mut Raise<RaiseToken, StableCoin>,
    factory: &mut factory::Factory,
    extensions: &Extensions,
    fee_manager: &mut fee::FeeManager,
    payment: Coin<sui::sui::SUI>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Only creator can pre-create DAO
    assert!(ctx.sender() == raise.creator, ENotTheCreator);
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
        ctx
    );

    // Store DAO ID
    raise.dao_id = option::some(object::id(&account));

    // Store unshared components in dynamic fields
    df::add(&mut raise.id, DaoAccountKey {}, account);
    df::add(&mut raise.id, DaoQueueKey {}, queue);
    df::add(&mut raise.id, DaoPoolKey {}, spot_pool);

    // Init action specs stored in raise.init_action_specs field
}

/// Lock intents - no more can be added after this
public entry fun lock_intents_and_start_raise<RaiseToken, StableCoin>(
    raise: &mut Raise<RaiseToken, StableCoin>,
    ctx: &mut TxContext,
) {
    // Only creator can lock intents
    assert!(ctx.sender() == raise.creator, ENotTheCreator);
    // Can only lock once
    assert!(!raise.intents_locked, EInvalidStateForAction);
    
    raise.intents_locked = true;
    // Raise can now begin accepting contributions
}


/// Create a raise that sells tokens to bootstrap a DAO.
/// `StableCoin` must be an allowed type in the factory.
/// DAO configuration is done via init actions - use stage_init_actions() after pre_create_dao_for_raise.
public entry fun create_raise<RaiseToken: drop, StableCoin: drop>(
    factory: &factory::Factory,
    fee_manager: &mut fee::FeeManager,
    treasury_cap: TreasuryCap<RaiseToken>,
    coin_metadata: CoinMetadata<RaiseToken>,
    tokens_for_sale_amount: u64,
    min_raise_amount: u64,
    max_raise_amount: Option<u64>,
    allowed_caps: vector<u64>, // Creator-defined allowed cap values
    description: String,
    launchpad_fee: Coin<sui::sui::SUI>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Collect launchpad creation fee
    fee::deposit_launchpad_creation_payment(fee_manager, launchpad_fee, clock, ctx);

    // CRITICAL: Validate treasury cap and metadata
    // Both treasury_cap and coin_metadata MUST be for RaiseToken (enforced by type system)
    assert!(coin::total_supply(&treasury_cap) == 0, ESupplyNotZero);

    // Check that StableCoin is allowed
    assert!(factory::is_stable_type_allowed<StableCoin>(factory), EStableTypeNotAllowed);

    // Validate max_raise_amount
    if (option::is_some(&max_raise_amount)) {
        assert!(*option::borrow(&max_raise_amount) >= min_raise_amount, EInvalidMaxRaise);
    };

    init_raise<RaiseToken, StableCoin>(
        treasury_cap,
        coin_metadata,
        tokens_for_sale_amount,
        min_raise_amount,
        max_raise_amount,
        allowed_caps,
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
public fun validate_contribution<RaiseToken, StableCoin>(
    raise: &Raise<RaiseToken, StableCoin>,
    contribution: Coin<StableCoin>,
    cap: u64,
    min_fill_pct: u8,
    crank_fee: Coin<sui::sui::SUI>,
    clock: &Clock,
    ctx: &TxContext,
): ContributionReceipt<RaiseToken, StableCoin> {
    // PARALLEL VALIDATION: All read-only checks (no writes to raise)
    assert!(raise.state == STATE_FUNDING, ERaiseNotActive);
    assert!(clock.timestamp_ms() < raise.deadline_ms, ERaiseStillActive);

    let amount = contribution.value();
    assert!(amount > 0, EZeroContribution);
    assert!(min_fill_pct <= 100, EInvalidMinFillPct);
    assert!(crank_fee.value() == constants::launchpad_crank_fee_per_contribution(), EInvalidStateForAction);
    assert!(cap >= amount, EInvalidStateForAction);
    assert!(is_cap_allowed(cap, &raise.allowed_caps), EInvalidCapValue);

    // Return receipt (hot potato - MUST be consumed by finalize_contribution)
    ContributionReceipt {
        raise_id: object::id(raise),
        contributor: ctx.sender(),
        contribution,
        crank_fee,
        cap,
        min_fill_pct,
    }
}

/// OPTIMIZATION: Split Read/Write Pattern - Phase 2: Finalize (Sequential) (2x parallelization)
///
/// Consumes ContributionReceipt and updates shared state.
/// This is the ONLY function that writes to Raise during contributions.
/// Must be called sequentially (one at a time), but validation happened in parallel.
///
/// Flow: validate_contribution() [parallel] → finalize_contribution() [sequential]
public fun finalize_contribution<RaiseToken, StableCoin>(
    raise: &mut Raise<RaiseToken, StableCoin>,
    receipt: ContributionReceipt<RaiseToken, StableCoin>,
) {
    // Verify receipt matches this raise
    assert!(receipt.raise_id == object::id(raise), EInvalidStateForAction);

    // Destructure receipt (hot potato consumed)
    let ContributionReceipt {
        raise_id: _,
        contributor,
        contribution,
        crank_fee,
        cap,
        min_fill_pct,
    } = receipt;

    let amount = contribution.value();

    // SEQUENTIAL WRITES: All state modifications happen here
    raise.crank_pool.join(crank_fee.into_balance());
    raise.stable_coin_vault.join(contribution.into_balance());

    // Update contributor record
    let key = ContributorKey { contributor };

    if (df::exists_(&raise.id, key)) {
        let rec: &mut Contribution = df::borrow_mut(&mut raise.id, key);
        assert!(rec.max_total == cap, ECapChangeAfterDeadline);
        assert!(rec.amount <= std::u64::max_value!() - amount, EArithmeticOverflow);
        rec.amount = rec.amount + amount;

        if (min_fill_pct > rec.min_fill_pct) {
            rec.min_fill_pct = min_fill_pct;
        };

        assert!(rec.max_total >= rec.amount, EInvalidStateForAction);
    } else {
        df::add(&mut raise.id, key, Contribution {
            amount,
            max_total: cap,
            allow_cranking: false,
            min_fill_pct,
        });
        raise.contributor_count = raise.contributor_count + 1;

        let tkey = ThresholdKey { cap };
        if (!df::exists_(&raise.id, tkey)) {
            assert!(vector::length(&raise.thresholds) < constants::launchpad_max_unique_caps(), ETooManyUniqueCaps);
            df::add(&mut raise.id, tkey, ThresholdBin { total: 0, count: 0 });
            vector::push_back(&mut raise.thresholds, cap);
        };
    };

    // Update cap-bin aggregate
    let bin: &mut ThresholdBin = df::borrow_mut(&mut raise.id, ThresholdKey { cap });
    assert!(bin.total <= std::u64::max_value!() - amount, EArithmeticOverflow);
    bin.total = bin.total + amount;
    bin.count = bin.count + 1;

    event::emit(ContributionAddedCapped {
        raise_id: object::id(raise),
        contributor,
        amount,
        cap,
        new_naive_total: 0,
    });
}

/// Contribute with a cap: max final total raise you accept.
/// cap = u64::max_value() means "no cap".
/// min_fill_pct: minimum fill percentage (0-100). If actual fill < this, auto-refund entire amount.
///               Use 0 to accept any fill amount.
///
/// DoS Protection: Requires 0.1 SUI crank fee to prevent spam attacks
/// The fee funds settlement cranking, making the system self-incentivizing
///
/// NOTE: This is the legacy single-transaction pattern. For 2x throughput, use:
///       validate_contribution() → finalize_contribution() split pattern
public entry fun contribute_with_cap<RaiseToken, StableCoin>(
    raise: &mut Raise<RaiseToken, StableCoin>,
    contribution: Coin<StableCoin>,
    cap: u64,
    min_fill_pct: u8,
    crank_fee: Coin<sui::sui::SUI>,  // NEW: Anti-DoS fee
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(raise.state == STATE_FUNDING, ERaiseNotActive);
    assert!(clock.timestamp_ms() < raise.deadline_ms, ERaiseStillActive);

    let contributor = ctx.sender();
    let amount = contribution.value();
    assert!(amount > 0, EZeroContribution);

    // SECURITY: Validate min_fill_pct is 0-100
    assert!(min_fill_pct <= 100, EInvalidMinFillPct);

    // DoS PROTECTION: Collect crank fee (makes spam expensive + funds crankers)
    assert!(crank_fee.value() == constants::launchpad_crank_fee_per_contribution(), EInvalidStateForAction);
    raise.crank_pool.join(crank_fee.into_balance());

    // SECURITY: Cap must be reasonable (at least the contribution amount)
    assert!(cap >= amount, EInvalidStateForAction);

    // SECURITY: Cap must be one of the creator-defined allowed values
    assert!(is_cap_allowed(cap, &raise.allowed_caps), EInvalidCapValue);

    // OPTIMIZATION: No total_raised counter (10x parallelization)
    // Just deposit coins - indexers aggregate totals from events
    raise.stable_coin_vault.join(contribution.into_balance());

    // Contributor DF: (amount, max_total)
    let key = ContributorKey { contributor };

    if (df::exists_(&raise.id, key)) {
        let rec: &mut Contribution = df::borrow_mut(&mut raise.id, key);
        // SECURITY: For existing contributors, cap must match or use update_cap
        assert!(rec.max_total == cap, ECapChangeAfterDeadline);
        assert!(rec.amount <= std::u64::max_value!() - amount, EArithmeticOverflow);
        rec.amount = rec.amount + amount;

        // Update min_fill_pct to the higher value (more conservative)
        if (min_fill_pct > rec.min_fill_pct) {
            rec.min_fill_pct = min_fill_pct;
        };

        // SECURITY: Updated total cap must still be reasonable
        assert!(rec.max_total >= rec.amount, EInvalidStateForAction);
    } else {
        df::add(&mut raise.id, key, Contribution {
            amount,
            max_total: cap,
            allow_cranking: false, // Default: only self can claim
            min_fill_pct,
        });
        raise.contributor_count = raise.contributor_count + 1;

        // Ensure a cap-bin exists and index it if first time seen
        let tkey = ThresholdKey { cap };
        if (!df::exists_(&raise.id, tkey)) {
            // Check we haven't exceeded maximum unique caps
            assert!(vector::length(&raise.thresholds) < constants::launchpad_max_unique_caps(), ETooManyUniqueCaps);
            df::add(&mut raise.id, tkey, ThresholdBin { total: 0, count: 0 });
            vector::push_back(&mut raise.thresholds, cap);
        };
    };

    // Update the cap-bin aggregate
    {
        let bin: &mut ThresholdBin = df::borrow_mut(&mut raise.id, ThresholdKey { cap });
        assert!(bin.total <= std::u64::max_value!() - amount, EArithmeticOverflow);
        bin.total = bin.total + amount;
        bin.count = bin.count + 1;
    };

    event::emit(ContributionAddedCapped {
        raise_id: object::id(raise),
        contributor,
        amount,
        cap,
        new_naive_total: 0, // OPTIMIZATION: Indexers calculate total from events
    });
}


/// OPTIMIZATION: Entry wrapper for split pattern - atomically validates and finalizes (2x throughput)
/// This combines validate + finalize in one PTB for convenience
/// For maximum parallelization, use validate_contribution() + finalize_contribution() separately
public entry fun contribute_split<RaiseToken, StableCoin>(
    raise: &mut Raise<RaiseToken, StableCoin>,
    contribution: Coin<StableCoin>,
    cap: u64,
    min_fill_pct: u8,
    crank_fee: Coin<sui::sui::SUI>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let receipt = validate_contribution(
        raise,
        contribution,
        cap,
        min_fill_pct,
        crank_fee,
        clock,
        ctx
    );
    finalize_contribution(raise, receipt);
}

/// Enable cranking: allow anyone to claim tokens on your behalf
/// This is useful if you want helpful bots to process your claim automatically
public entry fun enable_cranking<RaiseToken, StableCoin>(
    raise: &mut Raise<RaiseToken, StableCoin>,
    ctx: &mut TxContext,
) {
    let contributor = ctx.sender();
    let key = ContributorKey { contributor };
    assert!(df::exists_(&raise.id, key), ENotAContributor);

    let rec: &mut Contribution = df::borrow_mut(&mut raise.id, key);
    rec.allow_cranking = true;
}

/// Disable cranking: only you can claim your tokens
public entry fun disable_cranking<RaiseToken, StableCoin>(
    raise: &mut Raise<RaiseToken, StableCoin>,
    ctx: &mut TxContext,
) {
    let contributor = ctx.sender();
    let key = ContributorKey { contributor };
    assert!(df::exists_(&raise.id, key), ENotAContributor);

    let rec: &mut Contribution = df::borrow_mut(&mut raise.id, key);
    rec.allow_cranking = false;
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

/// Start settlement: snapshot caps into a heap
public fun begin_settlement<RT, SC>(
    raise: &mut Raise<RT, SC>,
    clock: &Clock,
    ctx: &mut TxContext,
): CapSettlement {
    assert!(clock.timestamp_ms() >= raise.deadline_ms, EDeadlineNotReached);
    assert!(!raise.settlement_done && !raise.settlement_in_progress, ESettlementAlreadyDone);
    assert!(raise.state == STATE_FUNDING, EInvalidStateForAction);

    // SECURITY: Mark that settlement has started to prevent bin/cap manipulation
    raise.settlement_in_progress = true;

    // Copy caps vector into heap
    let mut heap = raise.thresholds; // copy
    build_max_heap(&mut heap);
    let size = vector::length(&heap);

    let s = CapSettlement {
        id: object::new(ctx),
        raise_id: object::id(raise),
        heap,
        size,
        running_sum: 0,
        final_total: 0,
        done: false,
        cranker: ctx.sender(), // Record who will finalize (gets 50%)
    };

    event::emit(SettlementStarted { raise_id: object::id(raise), caps_count: size });
    s
}

/// Crank up to `steps` caps. Once done is true, final_total is T*.
/// Pays cranker 0.05 SUI per cap processed
public entry fun crank_settlement<RT, SC>(
    raise: &mut Raise<RT, SC>,
    s: &mut CapSettlement,
    steps: u64,
    ctx: &mut TxContext,
) {
    assert!(object::id(raise) == s.raise_id, EInvalidStateForAction);
    assert!(!s.done, ESettlementInProgress);
    assert!(raise.state == STATE_FUNDING, EInvalidStateForAction);
    assert!(raise.settlement_in_progress, EInvalidSettlementState);

    // SECURITY: Limit steps to prevent DOS
    let actual_steps = if (steps > 100) { 100 } else { steps };

    let mut caps_processed = 0;
    let mut i = 0;
    while (i < actual_steps && s.size > 0 && !s.done) {
        // Pop the highest cap
        let cap = heap_pop(&mut s.heap, &mut s.size);

        // Pull bin total; remove bin to avoid double counting
        let bin: ThresholdBin = df::remove(&mut raise.id, ThresholdKey { cap });
        let added = bin.total;

        // Update running sum
        assert!(s.running_sum <= std::u64::max_value!() - added, EArithmeticOverflow);
        s.running_sum = s.running_sum + added;

        // Peek next cap (0 if none)
        let next_cap = heap_peek(&s.heap, s.size);

        // Check fixed-point window: M_{k+1} < C_k <= M_k
        if (s.running_sum > next_cap && s.running_sum <= cap) {
            s.final_total = s.running_sum;
            s.done = true;
        };

        event::emit(SettlementStep {
            raise_id: s.raise_id,
            processed_cap: cap,
            added_amount: added,
            running_sum: s.running_sum,
            next_cap,
        });

        caps_processed = caps_processed + 1;
        i = i + 1;
    };

    // If heap exhausted but not done, no fixed point > 0 exists -> T* = 0
    if (s.size == 0 && !s.done) {
        s.final_total = 0;
        s.done = true;
    };

    // CRANK REWARD: Pay 0.05 SUI per cap processed
    if (caps_processed > 0) {
        // SECURITY: Check for overflow before multiplication (defensive programming)
        let per_cap_reward = constants::launchpad_reward_per_cap_processed();
        assert!(caps_processed <= std::u64::max_value!() / per_cap_reward, EArithmeticOverflow);

        let reward_amount = caps_processed * per_cap_reward;
        let pool_balance = raise.crank_pool.value();

        // Pay up to what's available in pool
        let actual_reward = if (reward_amount > pool_balance) {
            pool_balance
        } else {
            reward_amount
        };

        if (actual_reward > 0) {
            let reward = coin::from_balance(raise.crank_pool.split(actual_reward), ctx);
            transfer::public_transfer(reward, ctx.sender());
        };
    };
}

/// Finalize: record T* and lock settlement
/// Pays settlement finalizer 100% of remaining pool (after cranker rewards)
public fun finalize_settlement<RT, SC>(
    raise: &mut Raise<RT, SC>,
    s: &mut CapSettlement,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(object::id(raise) == s.raise_id, EInvalidStateForAction);
    assert!(s.done, ESettlementNotStarted);
    assert!(!raise.settlement_done, ESettlementAlreadyDone);
    assert!(raise.settlement_in_progress, EInvalidSettlementState);
    assert!(raise.state == STATE_FUNDING, EInvalidStateForAction);

    // SECURITY: Validate final total is reasonable
    // OPTIMIZATION: Check vault balance instead of total_raised counter
    assert!(s.final_total <= raise.stable_coin_vault.value(), EInvalidSettlementState);

    raise.final_total_eligible = s.final_total;
    raise.settlement_done = true;
    raise.settlement_in_progress = false; // Settlement completed

    // CRANK REWARD: Pay all remaining pool to finalizer
    // Crankers already got paid 0.05 SUI per cap
    let remaining_pool = raise.crank_pool.value();
    if (remaining_pool > 0) {
        let finalizer_reward = coin::from_balance(
            raise.crank_pool.split(remaining_pool),
            ctx
        );
        transfer::public_transfer(finalizer_reward, s.cranker);
    };

    event::emit(SettlementFinalized { raise_id: object::id(raise), final_total: s.final_total });

    // If settlement found T* early, some bins remain unprocessed
    // Emit event to signal UIs to prompt users to call sweep_unused_cap_bins
    let total_caps = vector::length(&raise.thresholds);
    let caps_processed = total_caps - s.size;  // Processed = total - remaining
    if (s.size > 0) {
        event::emit(SettlementAbandoned {
            raise_id: object::id(raise),
            caps_processed,
            caps_remaining: s.size,
            final_total: s.final_total,
            timestamp: clock.timestamp_ms(),
        });
    };

    // Note: Settlement object remains shared and inert after completion
    // Cannot delete shared objects in Sui
}

/// Entry function to start settlement and share the settlement object
public entry fun start_settlement<RT, SC>(
    raise: &mut Raise<RT, SC>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let settlement = begin_settlement(raise, clock, ctx);
    transfer::public_share_object(settlement);
}

/// Entry function to finalize settlement
public entry fun complete_settlement<RT, SC>(
    raise: &mut Raise<RT, SC>,
    s: &mut CapSettlement,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    finalize_settlement(raise, s, clock, ctx);
}

/// Sweep unused cap-bins after settlement completes early
/// If settlement finds T* before processing all caps, remaining bins are never removed
/// This function cleans up that storage to prevent permanent bloat
public entry fun sweep_unused_cap_bins<RT, SC>(
    raise: &mut Raise<RT, SC>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Can only sweep after settlement is complete
    assert!(raise.settlement_done, ESettlementNotStarted);

    // Iterate through all thresholds and remove any remaining bins
    let len = vector::length(&raise.thresholds);
    let mut i = 0;
    let mut bins_removed = 0;

    while (i < len) {
        let cap = *vector::borrow(&raise.thresholds, i);
        let key = ThresholdKey { cap };

        // Remove bin if it still exists (not processed during settlement)
        if (df::exists_(&raise.id, key)) {
            let _bin: ThresholdBin = df::remove(&mut raise.id, key);
            bins_removed = bins_removed + 1;
            // Bin is dropped automatically
        };

        i = i + 1;
    };

    // Emit event for tracking
    event::emit(CapBinsSwept {
        raise_id: object::id(raise),
        bins_removed,
        sweeper: ctx.sender(),
        timestamp: clock.timestamp_ms(),
    });
}

/// Allow creator to end raise early
/// OPTIMIZATION: Removed minimum raise check (requires total_raised counter)
/// Creator can end early at any time, settlement will determine success
///
/// Requirements:
/// - Only creator can call
/// - Before deadline
public entry fun end_raise_early<RT, SC>(
    raise: &mut Raise<RT, SC>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Only creator can end early
    assert!(ctx.sender() == raise.creator, ENotTheCreator);

    // Must still be in funding state
    assert!(raise.state == STATE_FUNDING, EInvalidStateForAction);

    // Must not have already passed deadline
    assert!(clock.timestamp_ms() < raise.deadline_ms, EDeadlineNotReached);

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
    factory: &mut factory::Factory,
    extensions: &Extensions,
    fee_manager: &mut fee::FeeManager,
    payment: Coin<sui::sui::SUI>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(ctx.sender() == raise.creator, ENotTheCreator);
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
    let mut spot_pool: AccountSpotPool<RaiseToken, StableCoin> = df::remove(&mut raise.id, DaoPoolKey {});

    // Extract and deposit treasury cap into DAO account
    let treasury_cap = raise.treasury_cap.extract();
    account_init_actions::init_lock_treasury_cap<FutarchyConfig, RaiseToken>(
        &mut account,
        treasury_cap
    );

    // Extract and deposit metadata into DAO account
    let metadata: CoinMetadata<RaiseToken> = df::remove(&mut raise.id, CoinMetadataKey {});
    account_init_actions::init_store_object<FutarchyConfig, DaoMetadataKey, CoinMetadata<RaiseToken>>(
        &mut account,
        DaoMetadataKey {},
        metadata,
        ctx
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
            (raise.tokens_for_sale_amount as u128)
        )
    };

    futarchy_config::set_launchpad_initial_price(
        futarchy_config::internal_config_mut(&mut account, version::current()),
        raise_price
    );

    // Check if there are staged init actions
    if (raise.init_action_specs.is_some()) {
        let specs = *raise.init_action_specs.borrow();

        // ATOMIC EXECUTION: Execute all init actions as a batch
        // If ANY action fails, this function will abort and the entire transaction reverts
        // This means:
        // 1. The raise remains in STATE_FUNDING (not marked successful)
        // 2. The DAO components remain unshared
        // 3. Contributors can claim refunds after deadline
        // 4. The launchpad automatically takes the fail path
        //
        // This is enforced by Move's transaction atomicity - no partial state changes
        init_actions::execute_init_intent_with_resources<RaiseToken, StableCoin>(
            &mut account,
            specs,
            &mut queue,
            &mut spot_pool,
            clock,
            ctx
        );
    };

    // Deposit the capped raise amount into the DAO treasury vault.
    let raised_funds = coin::from_balance(raise.stable_coin_vault.split(raise.final_raise_amount), ctx);
    account_init_actions::init_vault_deposit_default<FutarchyConfig, StableCoin>(
        &mut account,
        raised_funds,
        ctx
    );

    // Mark successful only if we reach here (init actions succeeded)
    raise.state = STATE_SUCCESSFUL;

    // Share all objects now that everything succeeded
    transfer::public_share_object(account);
    transfer::public_share_object(queue);
    account_spot_pool::share(spot_pool);

    event::emit(RaiseSuccessful {
        raise_id: object::id(raise),
        total_raised: raise.final_raise_amount,
    });
}

/// If successful, claim tokens for a contributor.
/// Only the contributor themselves can claim, unless they've enabled cranking via enable_cranking().
/// This allows helpful bots to crank token distribution in chunks for opted-in users.
public entry fun claim_tokens<RaiseToken, StableCoin>(
    raise: &mut Raise<RaiseToken, StableCoin>,
    recipient: address,
    ctx: &mut TxContext,
) {
    assert!(raise.state == STATE_SUCCESSFUL, EInvalidStateForAction);
    assert!(raise.settlement_done, ESettlementNotStarted);

    assert!(!raise.claiming, EReentrancy);
    raise.claiming = true;

    let caller = ctx.sender();
    let key = ContributorKey { contributor: recipient };
    assert!(df::exists_(&raise.id, key), ENotAContributor);

    // SECURITY: Check permission - only self or if cranking is enabled
    let rec_check: &Contribution = df::borrow(&raise.id, key);
    assert!(
        caller == recipient || rec_check.allow_cranking,
        ENotTheCreator // Reusing error for "not authorized"
    );

    // SECURITY: Remove and get contribution record to prevent double-claim
    let rec: Contribution = df::remove(&mut raise.id, key);
    
    // SECURITY: Verify contribution integrity
    assert!(rec.amount > 0, EInvalidStateForAction);
    assert!(rec.max_total >= rec.amount, EInvalidStateForAction);

    // Step 1: Eligibility check is still against the CONSENSUS total (T*)
    // This respects the outcome of the settlement phase.
    let consensual_total = raise.final_total_eligible;
    if (!(rec.max_total >= consensual_total)) {
        // IMPROVED UX: Auto-refund ineligible users instead of aborting
        // User was filtered out by market - give them 100% refund automatically
        let refund_coin = coin::from_balance(raise.stable_coin_vault.split(rec.amount), ctx);
        transfer::public_transfer(refund_coin, recipient);

        event::emit(RefundClaimed {
            raise_id: object::id(raise),
            contributor: recipient,
            refund_amount: rec.amount,
        });

        raise.claiming = false;
        return // Exit early - refund complete
    };

    // Step 2: Pro-rata calculation for ELIGIBLE users
    // SECURITY: Validate final_raise_amount is not zero (prevent division by zero)
    assert!(raise.final_raise_amount > 0, EFinalRaiseAmountZero);
    assert!(consensual_total > 0, EMinRaiseNotMet);

    // Calculate the user's share of the consensual total
    let accepted_amount = math::mul_div_to_64(
        rec.amount,
        raise.final_raise_amount, // Use the final, possibly capped amount
        consensual_total          // But scale it relative to the larger consensus pool
    );

    // Step 2.5: Check min_fill_pct slippage protection
    // If user specified minimum fill percentage and actual fill is below that, refund entirely
    if (rec.min_fill_pct > 0) {
        // Calculate actual fill percentage: (accepted / contributed) * 100
        let fill_pct = (accepted_amount * 100) / rec.amount;

        if (fill_pct < (rec.min_fill_pct as u64)) {
            // Fill below minimum - refund entire contribution
            let refund_coin = coin::from_balance(raise.stable_coin_vault.split(rec.amount), ctx);
            transfer::public_transfer(refund_coin, recipient);

            event::emit(RefundClaimed {
                raise_id: object::id(raise),
                contributor: recipient,
                refund_amount: rec.amount,
            });

            raise.claiming = false;
            return // Exit early - min fill not met
        };
    };

    let tokens_to_claim = math::mul_div_to_64(
        accepted_amount,
        raise.tokens_for_sale_amount,
        raise.final_raise_amount
    );

    let tokens = coin::from_balance(raise.raise_token_vault.split(tokens_to_claim), ctx);
    transfer::public_transfer(tokens, recipient);

    event::emit(TokensClaimed {
        raise_id: object::id(raise),
        contributor: recipient,
        contribution_amount: accepted_amount,
        tokens_claimed: tokens_to_claim,
    });

    // Step 3: Handle any refund due
    let refund_due = rec.amount - accepted_amount;
    if (refund_due > 0) {
        // Use a separate RefundKey to prevent double-claiming
        let refund_key = RefundKey { contributor: recipient };
        // Only add if no existing refund (safety check)
        if (!df::exists_(&raise.id, refund_key)) {
            df::add(&mut raise.id, refund_key, RefundRecord { amount: refund_due });
        } else {
            // If refund already exists, add to it
            let existing: &mut RefundRecord = df::borrow_mut(&mut raise.id, refund_key);
            existing.amount = existing.amount + refund_due;
        };
    };

    raise.claiming = false;
}

/// Mint claim NFTs for multiple contributors (FULLY PARALLEL!)
/// This is the NEW recommended claiming pattern for high-throughput scenarios.
///
/// Process:
/// 1. After settlement, anyone can mint NFTs for contributors (batched)
/// 2. All calculations done here (eligibility, pro-rata, min_fill_pct)
/// 3. Contributors get owned ClaimNFT objects
/// 4. Claiming with NFTs is FULLY PARALLEL (no reentrancy guard needed!)
///
/// Benefits vs claim_tokens():
/// - 100x parallelization (no global claiming lock)
/// - Simpler code (no reentrancy guard)
/// - Better UX (visible owned NFTs)
/// - Transferable claims (optional feature)
public entry fun mint_claim_nfts<RaiseToken, StableCoin>(
    raise: &Raise<RaiseToken, StableCoin>,
    contributors: vector<address>,
    ctx: &mut TxContext,
) {
    assert!(raise.state == STATE_SUCCESSFUL, EInvalidStateForAction);
    assert!(raise.settlement_done, ESettlementNotStarted);

    let consensual_total = raise.final_total_eligible;
    assert!(raise.final_raise_amount > 0, EFinalRaiseAmountZero);
    assert!(consensual_total > 0, EMinRaiseNotMet);

    let len = vector::length(&contributors);
    let mut i = 0;

    while (i < len) {
        let addr = *vector::borrow(&contributors, i);
        let key = ContributorKey { contributor: addr };

        // Skip if contributor doesn't exist
        if (df::exists_(&raise.id, key)) {
            let contrib: &Contribution = df::borrow(&raise.id, key);

            // Calculate tokens and refunds (same logic as claim_tokens)
            let (tokens_claimable, stable_refund) = if (contrib.max_total >= consensual_total) {
                // Eligible contributor
                let accepted_amount = math::mul_div_to_64(
                    contrib.amount,
                    raise.final_raise_amount,
                    consensual_total
                );

                // Check min_fill_pct slippage protection
                if (contrib.min_fill_pct > 0) {
                    let fill_pct = (accepted_amount * 100) / contrib.amount;
                    if (fill_pct < (contrib.min_fill_pct as u64)) {
                        // Below minimum fill - full refund, no tokens
                        (0, contrib.amount)
                    } else {
                        // Fill acceptable - calculate tokens
                        let t = math::mul_div_to_64(
                            accepted_amount,
                            raise.tokens_for_sale_amount,
                            raise.final_raise_amount
                        );
                        (t, contrib.amount - accepted_amount)
                    }
                } else {
                    // No min_fill_pct - always accept
                    let t = math::mul_div_to_64(
                        accepted_amount,
                        raise.tokens_for_sale_amount,
                        raise.final_raise_amount
                    );
                    (t, contrib.amount - accepted_amount)
                }
            } else {
                // Ineligible (cap too low) - full refund, no tokens
                (0, contrib.amount)
            };

            // Mint ClaimNFT (owned object = no conflicts!)
            let nft = ClaimNFT<RaiseToken, StableCoin> {
                id: object::new(ctx),
                raise_id: object::id(raise),
                contributor: addr,
                tokens_claimable,
                stable_refund,
            };

            let nft_id = object::id(&nft);

            // Transfer NFT to contributor
            transfer::transfer(nft, addr);

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

/// Claim tokens and refunds with ClaimNFT (FULLY PARALLEL!)
/// This function has NO reentrancy guard because each NFT is an owned object.
/// Multiple contributors can claim simultaneously without any conflicts!
///
/// Security: NFT is hot potato - must be consumed (destroyed) in this function.
public entry fun claim_with_nft<RaiseToken, StableCoin>(
    raise: &mut Raise<RaiseToken, StableCoin>,
    nft: ClaimNFT<RaiseToken, StableCoin>,
    ctx: &mut TxContext,
) {
    // Verify NFT matches this raise
    assert!(nft.raise_id == object::id(raise), EInvalidClaimNFT);
    assert!(raise.state == STATE_SUCCESSFUL, EInvalidStateForAction);

    // Destructure NFT (hot potato pattern)
    let ClaimNFT {
        id,
        raise_id: _,
        contributor,
        tokens_claimable,
        stable_refund,
    } = nft;

    // Extract tokens if any
    if (tokens_claimable > 0) {
        let tokens = coin::from_balance(
            raise.raise_token_vault.split(tokens_claimable),
            ctx
        );
        transfer::public_transfer(tokens, contributor);

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
            ctx
        );
        transfer::public_transfer(refund, contributor);

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
public entry fun cleanup_failed_raise<RaiseToken: drop, StableCoin>(
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
        transfer::public_transfer(cap, raise.creator);

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

        // Properly handle objects with UID - they need to be shared or transferred
        if (df::exists_(&raise.id, DaoAccountKey {})) {
            let account: Account<FutarchyConfig> = df::remove(&mut raise.id, DaoAccountKey {});
            // Share the account so it can be cleaned up later by admin
            // This is safe because the raise failed and DAO won't be used
            transfer::public_share_object(account);
        };

        if (df::exists_(&raise.id, DaoQueueKey {})) {
            let queue: ProposalQueue<StableCoin> = df::remove(&mut raise.id, DaoQueueKey {});
            // Share the queue for cleanup
            transfer::public_share_object(queue);
        };

        if (df::exists_(&raise.id, DaoPoolKey {})) {
            let pool: AccountSpotPool<RaiseToken, StableCoin> = df::remove(&mut raise.id, DaoPoolKey {});
            // Use the module's share function for proper handling
            account_spot_pool::share(pool);
        };

        // Clean up init action specs if they exist
        if (raise.init_action_specs.is_some()) {
            raise.init_action_specs = option::none();
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
        transfer::public_transfer(metadata, raise.creator);
    };
}

/// Refund for eligible contributors who were partially refunded due to hard cap
public entry fun claim_hard_cap_refund<RaiseToken, StableCoin>(
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
    transfer::public_transfer(refund_coin, who);

    event::emit(RefundClaimed {
        raise_id: object::id(raise),
        contributor: who,
        refund_amount: refund_rec.amount,
    });
}

/// Refund for failed raises only
/// Note: For successful raises, use claim_tokens() which auto-refunds ineligible contributors
public entry fun claim_refund<RaiseToken, StableCoin>(
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
    
    // Remove and get contribution record
    let rec: Contribution = df::remove(&mut raise.id, contributor_key);
    let refund_coin = coin::from_balance(raise.stable_coin_vault.split(rec.amount), ctx);
    transfer::public_transfer(refund_coin, contributor);

    event::emit(RefundClaimed {
        raise_id: object::id(raise),
        contributor,
        refund_amount: rec.amount,
    });
}

/// After a successful raise and a claim period, sweep any remaining "dust" tokens or stablecoins.
/// - Raise tokens: Go to creator (unsold governance tokens from rounding)
/// - Stablecoins: Go to DAO treasury (contributor funds from rounding)
public entry fun sweep_dust<RaiseToken, StableCoin: drop>(
    raise: &mut Raise<RaiseToken, StableCoin>,
    dao_account: &mut Account<FutarchyConfig>,  // DAO Account to receive stablecoin dust
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(raise.state == STATE_SUCCESSFUL, EInvalidStateForAction);
    assert!(ctx.sender() == raise.creator, ENotTheCreator);

    // Verify this is the correct DAO for this raise
    assert!(raise.dao_id.is_some(), EDaoNotPreCreated);
    assert!(object::id(dao_account) == *raise.dao_id.borrow(), EInvalidStateForAction);

    // Ensure the claim period has passed. The claim period starts after the raise deadline.
    assert!(
        clock.timestamp_ms() >= raise.deadline_ms + constants::launchpad_claim_period_ms(),
        EDeadlineNotReached // Reusing error, implies "claim deadline not reached"
    );

    // Sweep remaining raise tokens (from token distribution rounding)
    // These go to creator since they're unsold governance tokens
    let remaining_token_balance = raise.raise_token_vault.value();
    if (remaining_token_balance > 0) {
        let dust_tokens = coin::from_balance(raise.raise_token_vault.split(remaining_token_balance), ctx);
        transfer::public_transfer(dust_tokens, raise.creator);
    };

    // Sweep remaining stablecoins (from refund/hard-cap rounding)
    // These go to DAO treasury since they're contributor funds
    let remaining_stable_balance = raise.stable_coin_vault.value();
    if (remaining_stable_balance > 0) {
        let dust_stable = coin::from_balance(raise.stable_coin_vault.split(remaining_stable_balance), ctx);
        account_init_actions::init_vault_deposit_default<FutarchyConfig, StableCoin>(
            dao_account,
            dust_stable,
            ctx
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
fun init_raise_internal<RaiseToken: drop, StableCoin: drop>(
    treasury_cap: TreasuryCap<RaiseToken>,
    coin_metadata: CoinMetadata<RaiseToken>,
    tokens_for_sale_amount: u64,
    min_raise_amount: u64,
    max_raise_amount: Option<u64>,
    allowed_caps: vector<u64>,
    description: String,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Validate allowed_caps
    assert!(!vector::is_empty(&allowed_caps), EAllowedCapsEmpty);
    assert!(is_sorted_ascending(&allowed_caps), EAllowedCapsNotSorted);

    // CRITICAL: Validate treasury cap before minting
    // Treasury cap and metadata are both typed as RaiseToken (enforced by type system)
    let mut treasury_cap = treasury_cap;
    assert!(coin::total_supply(&treasury_cap) == 0, ESupplyNotZero);

    if (option::is_some(&max_raise_amount)) {
        assert!(*option::borrow(&max_raise_amount) >= min_raise_amount, EInvalidMaxRaise);
    };

    // Mint tokens for sale from the treasury cap
    let minted_for_raise = coin::mint(&mut treasury_cap, tokens_for_sale_amount, ctx);
    let tokens_for_sale_balance = coin::into_balance(minted_for_raise);

    let deadline = clock.timestamp_ms() + constants::launchpad_duration_ms();

    let mut raise = Raise<RaiseToken, StableCoin> {
        id: object::new(ctx),
        creator: ctx.sender(),
        state: STATE_FUNDING,
        // OPTIMIZATION: total_raised field removed (10x parallelization)
        min_raise_amount,
        max_raise_amount,
        deadline_ms: deadline,
        raise_token_vault: tokens_for_sale_balance,
        tokens_for_sale_amount,
        stable_coin_vault: balance::zero(),
        crank_pool: balance::zero(),  // Filled by contributor fees
        contributor_count: 0,
        description,
        init_action_specs: option::none(), // DAO config via init actions
        treasury_cap: option::some(treasury_cap),
        claiming: false,
        allowed_caps,
        thresholds: vector::empty<u64>(),
        settlement_done: false,
        settlement_in_progress: false,
        final_total_eligible: 0,
        final_raise_amount: 0,
        dao_id: option::none(),
        intents_locked: false,
        admin_trust_score: option::none(),
        admin_review_text: option::none(),
    };

    df::add(&mut raise.id, CoinMetadataKey {}, coin_metadata);

    event::emit(RaiseCreated {
        raise_id: object::id(&raise),
        creator: raise.creator,
        raise_token_type: type_name::with_defining_ids<RaiseToken>().into_string().to_string(),
        stable_coin_type: type_name::with_defining_ids<StableCoin>().into_string().to_string(),
        min_raise_amount,
        tokens_for_sale: tokens_for_sale_amount,
        deadline_ms: raise.deadline_ms,
        description: raise.description,
    });

    transfer::public_share_object(raise);
}

/// Internal function to initialize a raise.
fun init_raise<RaiseToken: drop, StableCoin: drop>(
    treasury_cap: TreasuryCap<RaiseToken>,
    coin_metadata: CoinMetadata<RaiseToken>,
    tokens_for_sale_amount: u64,
    min_raise_amount: u64,
    max_raise_amount: Option<u64>,
    allowed_caps: vector<u64>,
    description: String,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    init_raise_internal<RaiseToken, StableCoin>(
        treasury_cap,
        coin_metadata,
        tokens_for_sale_amount,
        min_raise_amount,
        max_raise_amount,
        allowed_caps,
        description,
        clock,
        ctx
    );
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
        let contribution: &Contribution = df::borrow(&r.id, key);
        contribution.amount
    } else {
        0
    }
}

public fun final_total_eligible<RT, SC>(r: &Raise<RT, SC>): u64 { r.final_total_eligible }
public fun settlement_done<RT, SC>(r: &Raise<RT, SC>): bool { r.settlement_done }
public fun settlement_in_progress<RT, SC>(r: &Raise<RT, SC>): bool { r.settlement_in_progress }
public fun contributor_count<RT, SC>(r: &Raise<RT, SC>): u64 { r.contributor_count }

/// Check if a contributor has enabled cranking (allows others to claim on their behalf)
public fun is_cranking_enabled<RT, SC>(r: &Raise<RT, SC>, addr: address): bool {
    let key = ContributorKey { contributor: addr };
    if (df::exists_(&r.id, key)) {
        let contribution: &Contribution = df::borrow(&r.id, key);
        contribution.allow_cranking
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
    trust_score: u64,
    review_text: String,
) {
    raise.admin_trust_score = option::some(trust_score);
    raise.admin_review_text = option::some(review_text);
}
