/// Production-grade dissolution auction system
/// - Shared auction objects (no contention)
/// - Type-erased actions (no type parameter explosion)
/// - Hot potato object passing
/// - ONE-OFF bid extension (anti-snipe)
/// - 5% minimum bid increment
module futarchy_lifecycle::dissolution_auction;

use account_protocol::account::{Self, Account};
use account_protocol::version_witness::VersionWitness;
use futarchy_core::futarchy_config::FutarchyConfig;
use futarchy_core::version;
use std::option::Option;
use std::string::String;
use std::type_name::{Self, TypeName};
use sui::clock::Clock;
use sui::coin::{Self, Coin};
use sui::dynamic_field as df;
use sui::event;
use sui::object::{Self, UID, ID};
use sui::transfer;
use sui::tx_context::TxContext;

// === Errors ===
const EAuctionNotFound: u64 = 1;
const EAuctionEnded: u64 = 2;
const EAuctionNotEnded: u64 = 3;
const EBidTooLow: u64 = 4;
const ENotHighestBidder: u64 = 5;
const EAlreadyFinalized: u64 = 6;
const EInvalidDuration: u64 = 7;
const EWrongAccount: u64 = 8;
const EWrongType: u64 = 9;
const EWrongObject: u64 = 10;
const ECounterUnderflow: u64 = 11;
const EInvalidMinimumBid: u64 = 12;

// === Constants ===
const MIN_AUCTION_DURATION_MS: u64 = 86400000; // 1 day
const MAX_AUCTION_DURATION_MS: u64 = 7776000000; // 90 days
const BID_EXTENSION_WINDOW_MS: u64 = 600000; // 10 minutes
const MIN_BID_INCREMENT_BPS: u64 = 500; // 5%
const MIN_BID_INCREMENT_ABSOLUTE: u64 = 1000; // 0.001 in 6 decimals

// === Events ===

/// Emitted when a new auction is created
public struct AuctionCreated has copy, drop {
    auction_id: ID,
    dao_account_id: ID,
    object_type: TypeName,
    minimum_bid: u64,
    end_time: u64,
}

/// Emitted when a bid is placed
public struct BidPlaced has copy, drop {
    auction_id: ID,
    bidder: address,
    bid_amount: u64,
    time_remaining: u64,
    extended: bool,
}

/// Emitted when auction is finalized
public struct AuctionFinalized has copy, drop {
    auction_id: ID,
    winner: address,
    winning_bid: u64,
    had_bids: bool,
}

// === Counter Storage in Account ===

/// Key for auction counter in Account's dynamic fields
public struct AuctionCounterKey has copy, drop, store {}

/// Simple counter (no Bag needed)
public struct AuctionCounter has store {
    active_count: u64,
}

// === Typed Dynamic Field Keys ===

/// Key for storing the object being auctioned
public struct AuctionObjectKey has copy, drop, store {}

/// Key for storing the current highest bid
public struct AuctionBidKey has copy, drop, store {}

// === Shared Auction Object ===

/// Individual auction as shared object (no contention!)
/// Generic only over BidCoin to avoid type explosion
public struct DissolutionAuction<phantom BidCoin> has key {
    id: UID,
    /// DAO account that created this auction
    dao_account_id: ID,
    /// Type of object being auctioned (for validation)
    object_type: TypeName,
    /// Minimum bid amount in BidCoin
    minimum_bid: u64,
    /// Current highest bid
    highest_bid: u64,
    /// Current highest bidder
    highest_bidder: Option<address>,
    /// Auction end time (ms)
    end_time: u64,
    /// Whether auction has been extended (ONE-OFF)
    has_been_extended: bool,
    /// Whether auction has been finalized
    finalized: bool,
    /// Auction creator (for no-bid case)
    creator: address,
    // Object stored as dynamic field (AuctionObjectKey)
    // Bid stored as dynamic field (AuctionBidKey)
}

// === Hot Potato Structs ===

/// Request to create auction (hot potato)
/// Uses String for type names (can be BCS-deserialized)
/// Converted to TypeName at fulfillment for type-safe validation
public struct CreateAuctionRequest has drop, store {
    dao_account_id: ID,
    object_id: ID,
    object_type: String,
    bid_coin_type: String,
    minimum_bid: u64,
    duration_ms: u64,
    creator: address,
}

/// Receipt from bid placement
public struct BidReceipt {
    auction_id: ID,
    bidder: address,
    bid_amount: u64,
}

/// Receipt from auction finalization
public struct FinalizeReceipt<phantom BidCoin> {
    auction_id: ID,
    winner: address,
    winning_bid: u64,
}

// === Counter Management ===

/// Initialize counter in Account (called once during dissolution)
public fun init_auction_counter(account: &mut Account<FutarchyConfig>) {
    // Check if counter already exists using has_managed_data
    if (
        !account::has_managed_data<FutarchyConfig, AuctionCounterKey>(account, AuctionCounterKey {})
    ) {
        let counter = AuctionCounter { active_count: 0 };
        account::add_managed_data(account, AuctionCounterKey {}, counter, version::current());
    }
}

/// Get active auction count
public fun get_active_auction_count(account: &Account<FutarchyConfig>): u64 {
    if (
        !account::has_managed_data<FutarchyConfig, AuctionCounterKey>(account, AuctionCounterKey {})
    ) {
        return 0
    };

    let counter = account::borrow_managed_data<FutarchyConfig, AuctionCounterKey, AuctionCounter>(
        account,
        AuctionCounterKey {},
        version::current(),
    );
    counter.active_count
}

/// Check if all auctions complete
public fun all_auctions_complete(account: &Account<FutarchyConfig>): bool {
    get_active_auction_count(account) == 0
}

/// Increment counter (package-visible)
fun increment_auction_count(account: &mut Account<FutarchyConfig>) {
    let counter = account::borrow_managed_data_mut<
        FutarchyConfig,
        AuctionCounterKey,
        AuctionCounter,
    >(
        account,
        AuctionCounterKey {},
        version::current(),
    );
    counter.active_count = counter.active_count + 1;
}

/// Decrement counter (package-visible)
fun decrement_auction_count(account: &mut Account<FutarchyConfig>) {
    let counter = account::borrow_managed_data_mut<
        FutarchyConfig,
        AuctionCounterKey,
        AuctionCounter,
    >(
        account,
        AuctionCounterKey {},
        version::current(),
    );
    // ✅ Prevent underflow - critical for dissolution safety
    assert!(counter.active_count > 0, ECounterUnderflow);
    counter.active_count = counter.active_count - 1;
}

// === Auction Creation (Hot Potato Pattern) ===

/// Create auction request (called by dissolution action)
/// Returns hot potato that must be fulfilled with actual object
public fun create_auction_request(
    account: &Account<FutarchyConfig>,
    object_id: ID,
    object_type: String,
    bid_coin_type: String,
    minimum_bid: u64,
    duration_ms: u64,
    ctx: &mut TxContext,
): CreateAuctionRequest {
    // ✅ Validate minimum bid is non-zero to prevent spam
    assert!(minimum_bid > 0, EInvalidMinimumBid);

    // Validate duration
    assert!(duration_ms >= MIN_AUCTION_DURATION_MS, EInvalidDuration);
    assert!(duration_ms <= MAX_AUCTION_DURATION_MS, EInvalidDuration);

    CreateAuctionRequest {
        dao_account_id: object::id(account),
        object_id,
        object_type,
        bid_coin_type,
        minimum_bid,
        duration_ms,
        creator: ctx.sender(),
    }
}

/// Fulfill auction creation with actual object
/// Creates shared auction object and stores the object being auctioned
public fun fulfill_create_auction<T: key + store, BidCoin>(
    request: CreateAuctionRequest,
    account: &mut Account<FutarchyConfig>,
    object: T,
    clock: &Clock,
    ctx: &mut TxContext,
): ID {
    let CreateAuctionRequest {
        dao_account_id,
        object_id,
        object_type,
        bid_coin_type,
        minimum_bid,
        duration_ms,
        creator,
    } = request;

    // Validate account matches
    assert!(object::id(account) == dao_account_id, EWrongAccount);

    // ✅ Get TypeName from actual generic type (compile-time safety!)
    let actual_type = type_name::get<T>();
    // ✅ Compare TypeName against String from request (convert TypeName -> ascii::String -> String)
    assert!(type_name::into_string(actual_type).to_string() == object_type, EWrongType);

    // Validate object ID matches
    assert!(object::id(&object) == object_id, EWrongObject);

    // ✅ Get TypeName from actual bid coin type
    let actual_bid_type = type_name::get<BidCoin>();
    // ✅ Compare TypeName against String from request (convert TypeName -> ascii::String -> String)
    assert!(type_name::into_string(actual_bid_type).to_string() == bid_coin_type, EWrongType);

    // Create auction
    let end_time = clock.timestamp_ms() + duration_ms;
    let mut auction = DissolutionAuction<BidCoin> {
        id: object::new(ctx),
        dao_account_id,
        object_type: actual_type, // ✅ Store TypeName (not String)
        minimum_bid,
        highest_bid: 0,
        highest_bidder: option::none(),
        end_time,
        has_been_extended: false, // ← ONE-OFF extension flag
        finalized: false,
        creator,
    };

    let auction_id = object::id(&auction);

    // ✅ Store object using typed key (not raw bytes)
    df::add(&mut auction.id, AuctionObjectKey {}, object);

    // Increment counter
    increment_auction_count(account);

    // ✅ Emit event for indexing
    event::emit(AuctionCreated {
        auction_id,
        dao_account_id,
        object_type: actual_type,
        minimum_bid,
        end_time,
    });

    // Share auction (anyone can bid!)
    transfer::share_object(auction);

    auction_id
}

// === Bidding (Shared Object - No Contention!) ===

/// Place bid on auction
/// Works on shared auction object - no Account lock needed!
public fun place_bid<BidCoin>(
    auction: &mut DissolutionAuction<BidCoin>,
    bid_coin: Coin<BidCoin>,
    clock: &Clock,
    ctx: &mut TxContext,
): BidReceipt {
    assert!(!auction.finalized, EAlreadyFinalized);
    assert!(clock.timestamp_ms() < auction.end_time, EAuctionEnded);

    let bid_amount = coin::value(&bid_coin);

    // Calculate minimum required bid (5% increment or absolute minimum)
    let min_required = if (auction.highest_bid > 0) {
        let increment = (auction.highest_bid as u128) * (MIN_BID_INCREMENT_BPS as u128) / 10000;
        let increment_u64 = (increment as u64);
        auction.highest_bid + increment_u64.max(MIN_BID_INCREMENT_ABSOLUTE)
    } else {
        auction.minimum_bid
    };

    assert!(bid_amount >= min_required, EBidTooLow);

    // ✅ ONE-OFF BID EXTENSION (anti-snipe)
    // Only extend ONCE if bid placed in last 10 minutes
    let mut extended = false;
    if (!auction.has_been_extended) {
        let time_remaining = auction.end_time - clock.timestamp_ms();
        if (time_remaining < BID_EXTENSION_WINDOW_MS) {
            auction.end_time = clock.timestamp_ms() + BID_EXTENSION_WINDOW_MS;
            auction.has_been_extended = true; // ← Mark as extended
            extended = true;
        };
    };

    // Refund previous highest bidder (if exists)
    if (option::is_some(&auction.highest_bidder)) {
        let previous_bidder = *option::borrow(&auction.highest_bidder);
        // ✅ Use typed key for dynamic field access
        let refund_coin = df::remove<AuctionBidKey, Coin<BidCoin>>(
            &mut auction.id,
            AuctionBidKey {},
        );
        transfer::public_transfer(refund_coin, previous_bidder);
    };

    // ✅ Store new bid using typed key
    df::add(&mut auction.id, AuctionBidKey {}, bid_coin);
    auction.highest_bid = bid_amount;
    auction.highest_bidder = option::some(ctx.sender());

    // ✅ Emit event for indexing
    let time_remaining = auction.end_time - clock.timestamp_ms();
    event::emit(BidPlaced {
        auction_id: object::id(auction),
        bidder: ctx.sender(),
        bid_amount,
        time_remaining,
        extended,
    });

    BidReceipt {
        auction_id: object::id(auction),
        bidder: ctx.sender(),
        bid_amount,
    }
}

/// Confirm bid (consumes receipt)
public fun confirm_bid(receipt: BidReceipt) {
    let BidReceipt { auction_id: _, bidder: _, bid_amount: _ } = receipt;
}

// === Finalization ===

/// Finalize auction after end time
/// Returns object and bid proceeds, decrements counter
public fun finalize_auction<T: key + store, BidCoin>(
    auction: &mut DissolutionAuction<BidCoin>,
    account: &mut Account<FutarchyConfig>,
    clock: &Clock,
    ctx: &mut TxContext,
): (T, Coin<BidCoin>, FinalizeReceipt<BidCoin>) {
    assert!(clock.timestamp_ms() >= auction.end_time, EAuctionNotEnded);
    assert!(!auction.finalized, EAlreadyFinalized);
    assert!(object::id(account) == auction.dao_account_id, EWrongAccount);

    auction.finalized = true;

    // ✅ Extract object using typed key
    let object = df::remove<AuctionObjectKey, T>(&mut auction.id, AuctionObjectKey {});

    // Extract bid or create zero coin
    let had_bids = option::is_some(&auction.highest_bidder);
    let (bid_coin, winner) = if (had_bids) {
        // ✅ Use typed key for dynamic field access
        let coin = df::remove<AuctionBidKey, Coin<BidCoin>>(&mut auction.id, AuctionBidKey {});
        let bidder = *option::borrow(&auction.highest_bidder);
        (coin, bidder)
    } else {
        // No bids - create zero coin, creator gets object back
        (coin::zero<BidCoin>(ctx), auction.creator)
    };

    let winning_bid = auction.highest_bid;
    let auction_id = object::id(auction);

    // Decrement counter (unblocks dissolution when reaches 0)
    decrement_auction_count(account);

    // ✅ Emit event for indexing
    event::emit(AuctionFinalized {
        auction_id,
        winner,
        winning_bid,
        had_bids,
    });

    let receipt = FinalizeReceipt<BidCoin> {
        auction_id,
        winner,
        winning_bid,
    };

    (object, bid_coin, receipt)
}

/// Confirm finalization (consumes receipt)
public fun confirm_finalization<BidCoin>(receipt: FinalizeReceipt<BidCoin>): (ID, address, u64) {
    let FinalizeReceipt { auction_id, winner, winning_bid } = receipt;
    (auction_id, winner, winning_bid)
}

// === View Functions ===

/// Get auction info
public fun get_auction_info<BidCoin>(
    auction: &DissolutionAuction<BidCoin>,
): (u64, u64, Option<address>, u64, bool, bool) {
    (
        auction.minimum_bid,
        auction.highest_bid,
        auction.highest_bidder,
        auction.end_time,
        auction.has_been_extended,
        auction.finalized,
    )
}

/// Get DAO account ID
public fun get_dao_account_id<BidCoin>(auction: &DissolutionAuction<BidCoin>): ID {
    auction.dao_account_id
}

/// Get object type
public fun get_object_type<BidCoin>(auction: &DissolutionAuction<BidCoin>): TypeName {
    auction.object_type
}

/// Check if auction has been extended
public fun has_been_extended<BidCoin>(auction: &DissolutionAuction<BidCoin>): bool {
    auction.has_been_extended
}
