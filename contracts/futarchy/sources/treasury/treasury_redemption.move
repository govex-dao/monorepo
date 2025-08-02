/// Treasury redemption module - handles typed redemption operations
/// This module provides type-safe redemption functions that work with Move's type system
module futarchy::treasury_redemption;

use futarchy::treasury::{Self, Treasury};
use futarchy::math;
use sui::coin::{Self, Coin};
use sui::clock::Clock;
use sui::event;
use sui::transfer;
use sui::object;
use sui::tx_context::{Self, TxContext};

// === Errors ===
const ETreasuryNotInRedemptionState: u64 = 0;
const EAssetNotRedeemable: u64 = 1;
const EInsufficientTokensForRedemption: u64 = 2;
const EMaxRedemptionExceeded: u64 = 3;

// === Events ===

public struct AssetRedeemed<phantom CoinType> has copy, drop {
    treasury_id: ID,
    redeemer: address,
    dao_tokens_burned: u64,
    asset_amount_redeemed: u64,
    fee_amount: u64,
}

// === Public Functions ===

/// Redeem a specific coin type from treasury during dissolution
/// This function must be called with the exact coin type as a generic parameter
public entry fun redeem_coins<DAOAssetType: drop, RedeemableCoinType: drop>(
    treasury: &mut Treasury,
    dao_tokens: Coin<DAOAssetType>,
    dao_treasury_cap: &mut coin::TreasuryCap<DAOAssetType>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Verify treasury is in redemption state
    assert!(
        treasury::get_state(treasury) == treasury::state_redemption_active(),
        ETreasuryNotInRedemptionState
    );
    
    let dao_token_amount = dao_tokens.value();
    let dao_total_supply = dao_treasury_cap.total_supply();
    
    // Calculate share of treasury this represents
    let treasury_balance = treasury::get_balance<RedeemableCoinType>(treasury);
    let redeemable_amount = if (treasury_balance > 0 && dao_total_supply > 0) {
        math::mul_div_to_64(treasury_balance, dao_token_amount, dao_total_supply)
    } else {
        0
    };
    
    // Apply redemption fee
    let fee_bps = treasury::get_redemption_fee_bps(treasury);
    let fee_amount = math::mul_div_to_64(redeemable_amount, fee_bps, 10000);
    let amount_after_fee = redeemable_amount - fee_amount;
    
    // Burn the DAO tokens
    dao_treasury_cap.burn(dao_tokens);
    
    // Withdraw and transfer the redeemed coins
    if (amount_after_fee > 0) {
        let redeemed_coins = treasury::withdraw_for_redemption<RedeemableCoinType>(
            treasury,
            amount_after_fee,
            clock,
            ctx
        );
        transfer::public_transfer(redeemed_coins, ctx.sender());
    };
    
    // Emit event
    event::emit(AssetRedeemed<RedeemableCoinType> {
        treasury_id: object::id(treasury),
        redeemer: ctx.sender(),
        dao_tokens_burned: dao_token_amount,
        asset_amount_redeemed: amount_after_fee,
        fee_amount,
    });
}

/// Helper function to split DAO tokens for batch redemption
/// This should be called via a PTB that invokes redeem_coins for each type
public fun split_for_batch_redemption<DAOAssetType: drop>(
    dao_tokens: Coin<DAOAssetType>,
    amount_per_type: u64,
    ctx: &mut TxContext,
): vector<Coin<DAOAssetType>> {
    let total_amount = dao_tokens.value();
    let mut tokens = vector::empty();
    let mut remaining = dao_tokens;
    
    // Split the DAO tokens for each redemption
    while (total_amount >= amount_per_type && remaining.value() >= amount_per_type) {
        tokens.push_back(remaining.split(amount_per_type, ctx));
    };
    
    // Add any remaining amount
    if (remaining.value() > 0) {
        tokens.push_back(remaining);
    } else {
        remaining.destroy_zero();
    };
    
    tokens
}

// === Helper Functions ===

/// Check if a specific coin type can be redeemed
/// Returns the total redeemable amount for the given DAO token amount
public fun calculate_redeemable_amount<DAOAssetType, RedeemableCoinType>(
    treasury: &Treasury,
    dao_treasury_cap: &coin::TreasuryCap<DAOAssetType>,
    dao_token_amount: u64,
): u64 {
    let dao_total_supply = dao_treasury_cap.total_supply();
    let treasury_balance = treasury::get_balance<RedeemableCoinType>(treasury);
    
    if (treasury_balance > 0 && dao_total_supply > 0) {
        let redeemable = math::mul_div_to_64(treasury_balance, dao_token_amount, dao_total_supply);
        let fee_bps = treasury::get_redemption_fee_bps(treasury);
        let fee = math::mul_div_to_64(redeemable, fee_bps, 10000);
        redeemable - fee
    } else {
        0
    }
}