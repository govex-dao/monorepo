module futarchy::liquidity_interact;

use futarchy::amm;
use futarchy::coin_escrow::{Self, TokenEscrow};
use futarchy::market_state;
use futarchy::proposal::{Self, Proposal};
use sui::clock::Clock;

// === Introduction ===
// Methods to interact with AMM liquidity

// ====== Error Codes ======
const EINVALID_OUTCOME: u64 = 0;
const EINVALID_LIQUIDITY_TRANSFER: u64 = 1;
const EWRONG_OUTCOME: u64 = 2;
const EINVALID_STATE: u64 = 3;

// ====== States ======
const STATE_FINALIZED: u8 = 2;

public entry fun empty_all_amm_liquidity<AssetType, StableType>(
    proposal: &mut Proposal<AssetType, StableType>,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    outcome_idx: u64,
    _clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(outcome_idx < proposal::outcome_count(proposal), EINVALID_OUTCOME);
    assert!(proposal::get_state(proposal) == STATE_FINALIZED, EINVALID_STATE);
    assert!(ctx.sender() == proposal::proposer(proposal), EINVALID_LIQUIDITY_TRANSFER);
    assert!(outcome_idx == proposal::get_winning_outcome(proposal), EWRONG_OUTCOME);

    let market_state = coin_escrow::get_market_state(escrow);
    market_state::assert_market_finalized(market_state);

    let pool = proposal::get_pool_mut_by_outcome(proposal, (outcome_idx as u8));
    let (asset_out, stable_out) = amm::empty_all_amm_liquidity(pool, ctx);

    // Handle tokens separately
    coin_escrow::remove_liquidity(
        escrow,
        asset_out,
        stable_out,
        ctx,
    );
}

public fun get_liquidity_for_proposal<AssetType, StableType>(
    proposal: &Proposal<AssetType, StableType>,
): vector<u64> {
    let pools = proposal.get_amm_pools();
    let mut liquidity = vector<u64>[];

    pools.length().do!(|i| {
        let pool = &pools[i];
        let (asset, stable) = pool.get_reserves();
        liquidity.push_back(asset);
        liquidity.push_back(stable);
    });
    liquidity
}
