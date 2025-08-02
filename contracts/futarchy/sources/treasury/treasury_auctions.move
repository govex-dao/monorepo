/// Treasury auctions module for handling non-fungible asset liquidation during DAO dissolution
module futarchy::treasury_auctions;

// === Imports ===
use std::type_name::{Self, TypeName};
use std::option::{Self, Option};
use sui::{
    balance::{Self, Balance},
    coin::{Self, Coin},
    transfer,
    object::{Self, ID, UID},
    clock::{Self, Clock},
    event,
    tx_context::{Self, TxContext},
};
use futarchy::{
    treasury::{Self, Treasury},
};

// === Errors ===
const E_AUCTION_ENDED: u64 = 0;
const E_BID_TOO_LOW: u64 = 1;
const E_AUCTION_NOT_ENDED: u64 = 2;
const E_NOT_WINNER: u64 = 3;
const E_TREASURY_NOT_LIQUIDATING: u64 = 4;
const E_ASSET_NOT_MANAGED: u64 = 5;
const E_MIN_BID_INCREMENT_NOT_MET: u64 = 6;
const E_INVALID_AUCTION_STATE: u64 = 7;
const E_AUCTION_ALREADY_CLAIMED: u64 = 8;

// === Constants ===
const AUCTION_DURATION_MS: u64 = 604_800_000; // 7 days
const MIN_BID_INCREMENT_BPS: u64 = 100; // 1% minimum bid increment

// === Structs ===

/// Auction for a non-fungible asset during treasury liquidation
public struct Auction<phantom BidCoin> has key {
    id: UID,
    treasury_id: ID,
    asset_id: ID,
    asset_type: TypeName,
    start_time: u64,
    end_time: u64,
    highest_bid: Balance<BidCoin>,
    highest_bidder: address,
    min_bid: u64,
    claimed: bool,
}

// === Events ===

public struct AuctionCreated has copy, drop {
    auction_id: ID,
    treasury_id: ID,
    asset_id: ID,
    asset_type: TypeName,
    start_time: u64,
    end_time: u64,
    min_bid: u64,
}

public struct BidPlaced has copy, drop {
    auction_id: ID,
    bidder: address,
    bid_amount: u64,
    previous_bidder: address,
    previous_bid: u64,
}

public struct AuctionCompleted has copy, drop {
    auction_id: ID,
    winner: address,
    winning_bid: u64,
    asset_id: ID,
}

// === Public Functions ===

/// Start an auction for a non-fungible asset
public entry fun start_auction<BidCoin: drop>(
    treasury: &mut Treasury,
    asset_id: ID,
    initial_bid: Coin<BidCoin>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // 1. Verify treasury is in liquidating state
    assert!(treasury::get_state(treasury) == treasury::state_liquidating(), E_TREASURY_NOT_LIQUIDATING);
    
    // 2. Verify asset is managed by treasury
    let asset_type = treasury::get_managed_asset_type(treasury, asset_id);
    assert!(option::is_some(&asset_type), E_ASSET_NOT_MANAGED);
    
    let bid_amount = coin::value(&initial_bid);
    let current_time = clock::timestamp_ms(clock);
    let end_time = current_time + AUCTION_DURATION_MS;
    
    // 3. Create the auction object
    let auction_id = object::new(ctx);
    let auction_id_copy = object::uid_to_inner(&auction_id);
    
    let auction = Auction<BidCoin> {
        id: auction_id,
        treasury_id: object::id(treasury),
        asset_id,
        asset_type: option::destroy_some(asset_type),
        start_time: current_time,
        end_time,
        highest_bid: coin::into_balance(initial_bid),
        highest_bidder: ctx.sender(),
        min_bid: bid_amount,
        claimed: false,
    };
    
    // 4. Emit event
    event::emit(AuctionCreated {
        auction_id: auction_id_copy,
        treasury_id: object::id(treasury),
        asset_id,
        asset_type: option::destroy_some(treasury::get_managed_asset_type(treasury, asset_id)),
        start_time: current_time,
        end_time,
        min_bid: bid_amount,
    });
    
    // 5. Share the auction object
    transfer::share_object(auction);
}

/// Place a bid on an ongoing auction
public entry fun bid<BidCoin: drop>(
    auction: &mut Auction<BidCoin>,
    bid_coin: Coin<BidCoin>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let current_time = clock::timestamp_ms(clock);
    assert!(current_time < auction.end_time, E_AUCTION_ENDED);
    assert!(!auction.claimed, E_AUCTION_ALREADY_CLAIMED);
    
    let bid_amount = coin::value(&bid_coin);
    let current_highest = balance::value(&auction.highest_bid);
    
    // Calculate minimum required bid (current + increment)
    let min_required_bid = current_highest + (current_highest * MIN_BID_INCREMENT_BPS / 10000);
    assert!(bid_amount >= min_required_bid, E_BID_TOO_LOW);
    
    // Store previous bidder info for event
    let previous_bidder = auction.highest_bidder;
    let previous_bid = current_highest;
    
    // Refund the previous bidder
    if (current_highest > 0) {
        let refund_coin = coin::from_balance(
            balance::split(&mut auction.highest_bid, current_highest),
            ctx
        );
        transfer::public_transfer(refund_coin, auction.highest_bidder);
    };
    
    // Update auction state
    balance::join(&mut auction.highest_bid, coin::into_balance(bid_coin));
    auction.highest_bidder = ctx.sender();
    
    // Emit bid event
    event::emit(BidPlaced {
        auction_id: object::id(auction),
        bidder: ctx.sender(),
        bid_amount,
        previous_bidder,
        previous_bid,
    });
}

/// Claim the asset after auction ends
public entry fun claim_asset<BidCoin: drop>(
    auction: &mut Auction<BidCoin>,
    treasury: &mut Treasury,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let current_time = clock::timestamp_ms(clock);
    assert!(current_time >= auction.end_time, E_AUCTION_NOT_ENDED);
    assert!(ctx.sender() == auction.highest_bidder, E_NOT_WINNER);
    assert!(!auction.claimed, E_AUCTION_ALREADY_CLAIMED);
    
    // Mark as claimed to prevent double claiming
    auction.claimed = true;
    
    // Get the winning bid amount
    let winning_bid_amount = balance::value(&auction.highest_bid);
    
    // Transfer the winning bid to the treasury
    let winning_bid = balance::split(&mut auction.highest_bid, winning_bid_amount);
    treasury::deposit_coin_type_balance<BidCoin>(treasury, winning_bid);
    
    // Release the asset from the treasury
    // NOTE: The auction winner must claim the asset through a type-specific function
    // since Sui Move requires knowing the exact type at compile time.
    // The treasury will need type-specific claim functions for each asset type.
    // For now, we just emit the completion event and the asset remains in treasury
    // until claimed through the appropriate typed function.
    
    // Emit completion event
    event::emit(AuctionCompleted {
        auction_id: object::id(auction),
        winner: auction.highest_bidder,
        winning_bid: winning_bid_amount,
        asset_id: auction.asset_id,
    });
}

/// Claim a specific type of asset after winning an auction
/// This function must be called after claim_asset to actually transfer the asset
public entry fun claim_typed_asset<BidCoin: drop, AssetType: key + store>(
    auction: &Auction<BidCoin>,
    treasury: &mut Treasury,
    ctx: &mut TxContext,
) {
    // Verify the auction has been claimed and caller is the winner
    assert!(auction.claimed, E_INVALID_AUCTION_STATE);
    assert!(ctx.sender() == auction.highest_bidder, E_NOT_WINNER);
    
    // Release the typed asset from treasury and transfer to winner
    let asset = treasury::release_managed_asset<AssetType>(treasury, auction.asset_id, ctx);
    transfer::public_transfer(asset, auction.highest_bidder);
}

/// Cancel an auction if no bids have been placed (only treasury admin)
public entry fun cancel_auction<BidCoin: drop>(
    auction: Auction<BidCoin>,
    treasury: &Treasury,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Only allow cancellation if caller is treasury admin
    assert!(treasury::is_admin(treasury, ctx.sender()), E_INVALID_AUCTION_STATE);
    
    let Auction { 
        id, 
        treasury_id: _, 
        asset_id: _, 
        asset_type: _, 
        start_time: _, 
        end_time: _, 
        highest_bid, 
        highest_bidder, 
        min_bid: _, 
        claimed 
    } = auction;
    
    assert!(!claimed, E_AUCTION_ALREADY_CLAIMED);
    
    // Refund any bid if exists
    let bid_amount = balance::value(&highest_bid);
    if (bid_amount > 0) {
        let refund_coin = coin::from_balance(highest_bid, ctx);
        transfer::public_transfer(refund_coin, highest_bidder);
    } else {
        balance::destroy_zero(highest_bid);
    };
    
    object::delete(id);
}

// === View Functions ===

/// Get auction details
public fun get_auction_info<BidCoin>(auction: &Auction<BidCoin>): (
    ID,      // treasury_id
    ID,      // asset_id
    TypeName, // asset_type
    u64,     // end_time
    u64,     // current_bid
    address, // highest_bidder
    bool     // claimed
) {
    (
        auction.treasury_id,
        auction.asset_id,
        auction.asset_type,
        auction.end_time,
        balance::value(&auction.highest_bid),
        auction.highest_bidder,
        auction.claimed
    )
}

/// Check if auction has ended
public fun is_ended<BidCoin>(auction: &Auction<BidCoin>, clock: &Clock): bool {
    clock::timestamp_ms(clock) >= auction.end_time
}

/// Get minimum next bid amount
public fun get_min_next_bid<BidCoin>(auction: &Auction<BidCoin>): u64 {
    let current_bid = balance::value(&auction.highest_bid);
    current_bid + (current_bid * MIN_BID_INCREMENT_BPS / 10000)
}