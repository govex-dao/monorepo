module futarchy::proposal_fee_manager;

use sui::{
    coin::{Self, Coin},
    balance::{Self, Balance},
    sui::SUI,
    bag::{Self, Bag}
};

// === Errors ===
const EInvalidFeeAmount: u64 = 0;
const EProposalFeeNotFound: u64 = 1;

// === Constants ===
const FIXED_ACTIVATOR_REWARD: u64 = 1_000_000; // 0.001 SUI fixed reward for activators

// === Structs ===

/// Manages proposal submission fees and activator rewards
public struct ProposalFeeManager has key, store {
    id: UID,
    /// Stores fees paid for proposals waiting in the queue
    /// Key is the proposal ID, value is the SUI Balance
    pending_proposal_fees: Bag,
    /// Total fees collected by the protocol from evicted/slashed proposals
    protocol_revenue: Balance<SUI>,
}

// === Public Functions ===

/// Creates a new ProposalFeeManager
public fun new(ctx: &mut TxContext): ProposalFeeManager {
    ProposalFeeManager {
        id: object::new(ctx),
        pending_proposal_fees: bag::new(ctx),
        protocol_revenue: balance::zero(),
    }
}

/// Called by the DAO when a proposal is submitted to the queue
public fun deposit_proposal_fee(
    manager: &mut ProposalFeeManager, 
    proposal_id: ID, 
    fee_coin: Coin<SUI>
) {
    assert!(fee_coin.value() > 0, EInvalidFeeAmount);
    let fee_balance = fee_coin.into_balance();
    manager.pending_proposal_fees.add(proposal_id, fee_balance);
}

/// Called by the DAO when activating a proposal
/// Returns a fixed reward to the activator and keeps the rest as protocol revenue
public fun take_activator_reward(
    manager: &mut ProposalFeeManager, 
    proposal_id: ID, 
    ctx: &mut TxContext
): Coin<SUI> {
    assert!(manager.pending_proposal_fees.contains(proposal_id), EProposalFeeNotFound);
    
    let mut fee_balance: Balance<SUI> = manager.pending_proposal_fees.remove(proposal_id);
    let total_fee = fee_balance.value();
    
    if (total_fee == 0) {
        return coin::from_balance(fee_balance, ctx)
    };

    // Give fixed reward to activator, rest goes to protocol
    let reward_amount = if (total_fee >= FIXED_ACTIVATOR_REWARD) {
        manager.protocol_revenue.join(fee_balance.split(total_fee - FIXED_ACTIVATOR_REWARD));
        FIXED_ACTIVATOR_REWARD
    } else {
        // If fee is less than fixed reward, give entire fee to activator
        total_fee
    };
    
    coin::from_balance(fee_balance, ctx)
}

/// Called by the DAO when a proposal is evicted from the queue
/// The entire fee is contributed to the protocol revenue
public fun slash_proposal_fee(
    manager: &mut ProposalFeeManager, 
    proposal_id: ID
) {
    if (manager.pending_proposal_fees.contains(proposal_id)) {
        let mut fee_balance: Balance<SUI> = manager.pending_proposal_fees.remove(proposal_id);
        manager.protocol_revenue.join(fee_balance);
    };
}

/// Gets the current protocol revenue
public fun protocol_revenue(manager: &ProposalFeeManager): u64 {
    manager.protocol_revenue.value()
}

/// Withdraws accumulated protocol revenue to the main fee manager
public(package) fun withdraw_protocol_revenue(
    manager: &mut ProposalFeeManager,
    amount: u64,
    ctx: &mut TxContext
): Coin<SUI> {
    coin::from_balance(manager.protocol_revenue.split(amount), ctx)
}

/// Check if a proposal fee exists
public fun has_proposal_fee(manager: &ProposalFeeManager, proposal_id: ID): bool {
    manager.pending_proposal_fees.contains(proposal_id)
}

/// Get the fee amount for a proposal
public fun get_proposal_fee(manager: &ProposalFeeManager, proposal_id: ID): u64 {
    if (manager.pending_proposal_fees.contains(proposal_id)) {
        let balance: &Balance<SUI> = &manager.pending_proposal_fees[proposal_id];
        balance.value()
    } else {
        0
    }
}