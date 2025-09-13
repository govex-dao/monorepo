/// Shared action data structures to avoid circular dependencies
/// These structs define the data for actions but not the execution logic
module futarchy_utils::action_data_structs;

use std::string::{Self, String};
use std::option::{Self, Option};
use sui::object::{Self, ID};
use sui::bcs::{Self, BCS};

// ============= Payment/Stream Actions =============

/// Action to create any type of payment (stream, recurring, etc.)
public struct CreatePaymentAction<phantom CoinType> has store, drop, copy {
    payment_type: u8,
    source_mode: u8,
    recipient: address,
    amount: u64,
    start_timestamp: u64,
    end_timestamp: u64,
    interval_or_cliff: Option<u64>,
    total_payments: u64,
    cancellable: bool,
    description: String,
    max_per_withdrawal: u64,
    min_interval_ms: u64,
    max_beneficiaries: u64,
}

/// Constructor for CreatePaymentAction
public fun new_create_payment_action<CoinType>(
    payment_type: u8,
    source_mode: u8,
    recipient: address,
    amount: u64,
    start_timestamp: u64,
    end_timestamp: u64,
    interval_or_cliff: Option<u64>,
    total_payments: u64,
    cancellable: bool,
    description: String,
    max_per_withdrawal: u64,
    min_interval_ms: u64,
    max_beneficiaries: u64,
): CreatePaymentAction<CoinType> {
    CreatePaymentAction {
        payment_type,
        source_mode,
        recipient,
        amount,
        start_timestamp,
        end_timestamp,
        interval_or_cliff,
        total_payments,
        cancellable,
        description,
        max_per_withdrawal,
        min_interval_ms,
        max_beneficiaries,
    }
}

// Getters for CreatePaymentAction
public fun payment_type<CoinType>(action: &CreatePaymentAction<CoinType>): u8 { action.payment_type }
public fun source_mode<CoinType>(action: &CreatePaymentAction<CoinType>): u8 { action.source_mode }
public fun recipient<CoinType>(action: &CreatePaymentAction<CoinType>): address { action.recipient }
public fun amount<CoinType>(action: &CreatePaymentAction<CoinType>): u64 { action.amount }
public fun start_timestamp<CoinType>(action: &CreatePaymentAction<CoinType>): u64 { action.start_timestamp }
public fun end_timestamp<CoinType>(action: &CreatePaymentAction<CoinType>): u64 { action.end_timestamp }
public fun interval_or_cliff<CoinType>(action: &CreatePaymentAction<CoinType>): Option<u64> { action.interval_or_cliff }
public fun total_payments<CoinType>(action: &CreatePaymentAction<CoinType>): u64 { action.total_payments }
public fun cancellable<CoinType>(action: &CreatePaymentAction<CoinType>): bool { action.cancellable }
public fun description<CoinType>(action: &CreatePaymentAction<CoinType>): &String { &action.description }
public fun max_per_withdrawal<CoinType>(action: &CreatePaymentAction<CoinType>): u64 { action.max_per_withdrawal }
public fun min_interval_ms<CoinType>(action: &CreatePaymentAction<CoinType>): u64 { action.min_interval_ms }
public fun max_beneficiaries<CoinType>(action: &CreatePaymentAction<CoinType>): u64 { action.max_beneficiaries }

/// Action to cancel a payment
public struct CancelPaymentAction has store, drop, copy {
    payment_id: String,
}

public fun new_cancel_payment_action(payment_id: String): CancelPaymentAction {
    CancelPaymentAction { payment_id }
}

public fun payment_id(action: &CancelPaymentAction): &String { &action.payment_id }

// ============= Security Council Actions =============

/// Action to create a security council
public struct CreateSecurityCouncilAction has store, drop, copy {
    members: vector<address>,
    weights: vector<u64>,
    threshold: u64,
}

public fun new_create_security_council_action(
    members: vector<address>,
    weights: vector<u64>,
    threshold: u64,
): CreateSecurityCouncilAction {
    CreateSecurityCouncilAction { members, weights, threshold }
}

public fun council_members(action: &CreateSecurityCouncilAction): &vector<address> { &action.members }
public fun council_weights(action: &CreateSecurityCouncilAction): &vector<u64> { &action.weights }
public fun council_threshold(action: &CreateSecurityCouncilAction): u64 { action.threshold }

// ============= Operating Agreement Actions =============

/// Action to create an operating agreement
public struct CreateOperatingAgreementAction has store, drop, copy {
    agreement_lines: vector<String>,
    difficulties: vector<u64>,
}

public fun new_create_operating_agreement_action(
    agreement_lines: vector<String>,
    difficulties: vector<u64>,
): CreateOperatingAgreementAction {
    CreateOperatingAgreementAction { agreement_lines, difficulties }
}

public fun agreement_lines(action: &CreateOperatingAgreementAction): &vector<String> { &action.agreement_lines }
public fun agreement_difficulties(action: &CreateOperatingAgreementAction): &vector<u64> { &action.difficulties }

// ============= Liquidity Actions =============

/// Action to add liquidity to a pool
public struct AddLiquidityAction<phantom AssetType, phantom StableType> has store, drop, copy {
    pool_id: ID,
    asset_amount: u64,
    stable_amount: u64,
    min_lp_out: u64,
}

public fun new_add_liquidity_action<AssetType, StableType>(
    pool_id: ID,
    asset_amount: u64,
    stable_amount: u64,
    min_lp_out: u64,
): AddLiquidityAction<AssetType, StableType> {
    AddLiquidityAction { pool_id, asset_amount, stable_amount, min_lp_out }
}

public fun pool_id<AssetType, StableType>(action: &AddLiquidityAction<AssetType, StableType>): ID { action.pool_id }
public fun asset_amount<AssetType, StableType>(action: &AddLiquidityAction<AssetType, StableType>): u64 { action.asset_amount }
public fun stable_amount<AssetType, StableType>(action: &AddLiquidityAction<AssetType, StableType>): u64 { action.stable_amount }
public fun min_lp_out<AssetType, StableType>(action: &AddLiquidityAction<AssetType, StableType>): u64 { action.min_lp_out }

// ============= Commitment Actions =============

/// Price tier for commitment proposals
public struct PriceTier has store, copy, drop {
    price: u64,
    allocation: u64,
}

public fun new_price_tier(price: u64, allocation: u64): PriceTier {
    PriceTier { price, allocation }
}

// Accessor functions for PriceTier
public fun price(tier: &PriceTier): u64 { tier.price }
public fun allocation(tier: &PriceTier): u64 { tier.allocation }

/// Action to create a founder lock proposal
public struct CreateFounderLockProposalAction<phantom AssetType> has store, drop, copy {
    committed_amount: u64,
    tiers: vector<PriceTier>,
    proposal_id: ID,
    trading_start: u64,
    trading_end: u64,
    description: String,
}

public fun new_create_founder_lock_proposal_action<AssetType>(
    committed_amount: u64,
    tiers: vector<PriceTier>,
    proposal_id: ID,
    trading_start: u64,
    trading_end: u64,
    description: String,
): CreateFounderLockProposalAction<AssetType> {
    CreateFounderLockProposalAction {
        committed_amount,
        tiers,
        proposal_id,
        trading_start,
        trading_end,
        description,
    }
}

// Accessor functions for CreateFounderLockProposalAction
public fun committed_amount<AssetType>(action: &CreateFounderLockProposalAction<AssetType>): u64 { action.committed_amount }
public fun tiers<AssetType>(action: &CreateFounderLockProposalAction<AssetType>): &vector<PriceTier> { &action.tiers }
public fun proposal_id<AssetType>(action: &CreateFounderLockProposalAction<AssetType>): ID { action.proposal_id }
public fun trading_start<AssetType>(action: &CreateFounderLockProposalAction<AssetType>): u64 { action.trading_start }
public fun trading_end<AssetType>(action: &CreateFounderLockProposalAction<AssetType>): u64 { action.trading_end }
public fun founder_lock_description<AssetType>(action: &CreateFounderLockProposalAction<AssetType>): &String { &action.description }


// ============= Deserialization Functions =============

/// Deserialize CreatePaymentAction from bytes
public fun create_payment_action_from_bytes<CoinType>(bytes: vector<u8>): CreatePaymentAction<CoinType> {
    let mut bcs = bcs::new(bytes);
    CreatePaymentAction {
        payment_type: bcs.peel_u8(),
        source_mode: bcs.peel_u8(),
        recipient: bcs.peel_address(),
        amount: bcs.peel_u64(),
        start_timestamp: bcs.peel_u64(),
        end_timestamp: bcs.peel_u64(),
        interval_or_cliff: if (bcs.peel_bool()) {
            option::some(bcs.peel_u64())
        } else {
            option::none()
        },
        total_payments: bcs.peel_u64(),
        cancellable: bcs.peel_bool(),
        description: string::utf8(bcs.peel_vec_u8()),
        max_per_withdrawal: bcs.peel_u64(),
        min_interval_ms: bcs.peel_u64(),
        max_beneficiaries: bcs.peel_u64(),
    }
}

/// Deserialize CreateSecurityCouncilAction from bytes
public fun create_security_council_action_from_bytes(bytes: vector<u8>): CreateSecurityCouncilAction {
    let mut bcs = bcs::new(bytes);
    CreateSecurityCouncilAction {
        members: bcs.peel_vec_address(),
        weights: bcs.peel_vec_u64(),
        threshold: bcs.peel_u64(),
    }
}

/// Deserialize CreateOperatingAgreementAction from bytes
public fun create_operating_agreement_action_from_bytes(bytes: vector<u8>): CreateOperatingAgreementAction {
    let mut bcs = bcs::new(bytes);
    let mut agreement_lines = vector::empty<String>();
    let lines_count = bcs.peel_vec_length();
    let mut i = 0;
    while (i < lines_count) {
        vector::push_back(&mut agreement_lines, string::utf8(bcs.peel_vec_u8()));
        i = i + 1;
    };
    
    CreateOperatingAgreementAction {
        agreement_lines,
        difficulties: bcs.peel_vec_u64(),
    }
}

/// Deserialize AddLiquidityAction from bytes
public fun add_liquidity_action_from_bytes<AssetType, StableType>(bytes: vector<u8>): AddLiquidityAction<AssetType, StableType> {
    let mut bcs = bcs::new(bytes);
    AddLiquidityAction {
        pool_id: object::id_from_bytes(bcs.peel_vec_u8()),
        asset_amount: bcs.peel_u64(),
        stable_amount: bcs.peel_u64(),
        min_lp_out: bcs.peel_u64(),
    }
}

/// Deserialize CreateFounderLockProposalAction from bytes
public fun create_founder_lock_proposal_action_from_bytes<AssetType>(bytes: vector<u8>): CreateFounderLockProposalAction<AssetType> {
    let mut bcs = bcs::new(bytes);
    
    // Deserialize price tiers
    let tier_count = bcs.peel_vec_length();
    let mut tiers = vector::empty<PriceTier>();
    let mut i = 0;
    while (i < tier_count) {
        vector::push_back(&mut tiers, PriceTier {
            price: bcs.peel_u64(),
            allocation: bcs.peel_u64(),
        });
        i = i + 1;
    };
    
    CreateFounderLockProposalAction {
        committed_amount: bcs.peel_u64(),
        tiers,
        proposal_id: object::id_from_bytes(bcs.peel_vec_u8()),
        trading_start: bcs.peel_u64(),
        trading_end: bcs.peel_u64(),
        description: string::utf8(bcs.peel_vec_u8()),
    }
}