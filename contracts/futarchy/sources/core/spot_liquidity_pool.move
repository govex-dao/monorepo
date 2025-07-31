module futarchy::spot_liquidity_pool;

use sui::balance::{Self, Balance};
use sui::coin::{Self, Coin, TreasuryCap};
use sui::clock::Clock;
use sui::event;
use sui::table::{Self, Table};

use futarchy::dao::{Self, DAO};
use futarchy::proposal::{Self, Proposal};
use futarchy::coin_escrow::{Self, TokenEscrow};
use futarchy::amm;
use futarchy::math;
use futarchy::conditional_token::{Self, ConditionalToken};

// === Errors ===
/// Amount must be greater than zero
const EZeroAmount: u64 = 106;
/// Insufficient liquidity in the pool to complete this operation
const EInsufficientLiquidity: u64 = 107;
/// Slippage exceeded: actual output is less than minimum required
const EExcessiveSlippage: u64 = 108;
/// Arithmetic overflow: calculation result exceeds maximum value
const EOverflow: u64 = 111;
/// No LP tokens found for this proposal
const ENoLPAllocation: u64 = 112;
/// Invalid admin capability
const EInvalidAdminCap: u64 = 113;

// === Constants ===
const MINIMUM_LIQUIDITY: u64 = 1000;

// === Structs ===

/// LP token for the spot AMM
public struct LP<phantom Asset, phantom Stable> has drop {}

/// Admin capability for protocol fee collection
public struct ProtocolAdminCap has key, store {
    id: UID,
}

/// Spot liquidity pool with AMM functionality
public struct SpotLiquidityPool<phantom Asset, phantom Stable> has key, store {
    id: UID,
    dao_id: ID,
    protocol_admin_cap_id: ID,
    asset_vault: Balance<Asset>,
    stable_vault: Balance<Stable>,
    lp_supply: TreasuryCap<LP<Asset, Stable>>,
    min_liquidity_stable: u64,
    lp_fee_bps: u16,
    protocol_fee_bps: u16,
    accumulated_protocol_fees: Balance<Stable>,
    k_last: u128, // For fee calculations
    // Store AMM LP tokens for each outcome when proposal is active
    amm_lp_tokens: Table<ID, vector<ConditionalToken>>, // proposal_id -> LP tokens per outcome
}

// === Events ===

public struct PoolCreated has copy, drop {
    pool_id: ID,
    dao_id: ID,
    min_liquidity_stable: u64,
    initial_asset: u64,
    initial_stable: u64,
}

public struct LiquidityAdded has copy, drop {
    pool_id: ID,
    provider: address,
    asset_added: u64,
    stable_added: u64,
    lp_minted: u64,
    new_asset_reserve: u64,
    new_stable_reserve: u64,
}

public struct WithdrawalProcessed has copy, drop {
    pool_id: ID,
    provider: address,
    lp_amount: u64,
    asset_out: u64,
    stable_out: u64,
}

public struct SpotSwap has copy, drop {
    pool_id: ID,
    trader: address,
    amount_in: u64,
    amount_out: u64,
    is_asset_in: bool,
    fee_amount: u64,
    new_asset_reserve: u64,
    new_stable_reserve: u64,
}

public struct ProtocolFeesCollected has copy, drop {
    pool_id: ID,
    amount: u64,
    collector: address,
}

// === Public Functions ===

/// Creates a new spot liquidity pool for a DAO
public fun create_pool<Asset, Stable>(
    dao: &DAO<Asset, Stable>,
    initial_asset: Coin<Asset>,
    initial_stable: Coin<Stable>,
    lp_fee_bps: u16,
    protocol_fee_bps: u16,
    ctx: &mut TxContext,
): (SpotLiquidityPool<Asset, Stable>, Coin<LP<Asset, Stable>>, ProtocolAdminCap) {
    // Get minimum liquidity from DAO configuration
    let (_min_asset_amount, min_liquidity_stable) = dao::get_min_amounts(dao);
    let initial_asset_val = initial_asset.value();
    let initial_stable_val = initial_stable.value();
    
    // Create LP token
    let (mut treasury_cap, metadata) = coin::create_currency<LP<Asset, Stable>>(
        LP<Asset, Stable> {},
        9,
        b"FUT-LP",
        b"Futarchy LP Token",
        b"LP token for Futarchy spot AMM",
        option::none(),
        ctx
    );
    
    // Calculate initial LP tokens using sqrt(k)
    let k = math::mul_div_to_128(initial_asset_val, initial_stable_val, 1);
    let sqrt_k = math::sqrt_u128(k);
    assert!(sqrt_k <= (0xFFFFFFFFFFFFFFFFu64 as u128), EOverflow);
    
    let initial_lp = (sqrt_k as u64);
    assert!(initial_lp >= MINIMUM_LIQUIDITY, EInsufficientLiquidity);
    
    // Mint initial LP tokens
    let lp_tokens = coin::mint(&mut treasury_cap, initial_lp, ctx);
    
    let k_initial = (initial_asset_val as u128) * (initial_stable_val as u128);
    
    // Create protocol admin cap
    let protocol_admin_cap = ProtocolAdminCap {
        id: object::new(ctx),
    };
    
    let pool = SpotLiquidityPool<Asset, Stable> {
        id: object::new(ctx),
        dao_id: object::id(dao),
        protocol_admin_cap_id: object::id(&protocol_admin_cap),
        asset_vault: initial_asset.into_balance(),
        stable_vault: initial_stable.into_balance(),
        lp_supply: treasury_cap,
        min_liquidity_stable,
        lp_fee_bps,
        protocol_fee_bps,
        accumulated_protocol_fees: balance::zero(),
        k_last: k_initial,
        amm_lp_tokens: table::new(ctx),
    };
    
    event::emit(PoolCreated {
        pool_id: object::id(&pool),
        dao_id: object::id(dao),
        min_liquidity_stable,
        initial_asset: initial_asset_val,
        initial_stable: initial_stable_val,
    });
    
    transfer::public_freeze_object(metadata);
    
    (pool, lp_tokens, protocol_admin_cap)
}

/// Add liquidity to the spot AMM when no proposal is active
public entry fun add_liquidity<Asset, Stable>(
    pool: &mut SpotLiquidityPool<Asset, Stable>,
    asset_coin: Coin<Asset>,
    stable_coin: Coin<Stable>,
    min_lp_out: u64,
    ctx: &mut TxContext
) {
    let lp_tokens = add_liquidity_spot_only(pool, asset_coin, stable_coin, min_lp_out, ctx);
    transfer::public_transfer(lp_tokens, ctx.sender());
}

/// Add liquidity to the spot AMM when a proposal is active
public entry fun add_liquidity_with_proposal<Asset, Stable>(
    pool: &mut SpotLiquidityPool<Asset, Stable>,
    proposal: &mut Proposal<Asset, Stable>,
    escrow: &mut TokenEscrow<Asset, Stable>,
    asset_coin: Coin<Asset>,
    stable_coin: Coin<Stable>,
    min_lp_out: u64,
    clock: &Clock,
    ctx: &mut TxContext
) {
    let asset_amount = asset_coin.value();
    let stable_amount = stable_coin.value();
    assert!(asset_amount > 0 || stable_amount > 0, EZeroAmount);

    // 1. Mint complete sets of conditional tokens
    let mut new_asset_tokens = coin_escrow::mint_complete_set_asset(escrow, asset_coin, clock, ctx);
    let mut new_stable_tokens = coin_escrow::mint_complete_set_stable(escrow, stable_coin, clock, ctx);

    // 2. Calculate spot LP tokens to mint
    // Spot LP tokens represent proportional ownership of the spot pool
    let total_lp = pool.lp_supply.total_supply();
    let lp_to_mint = if (total_lp == 0) {
        // First liquidity - use sqrt(k) like Uniswap V2
        let k = math::sqrt_u128(math::mul_div_to_128(asset_amount, stable_amount, 1));
        (k as u64)
    } else {
        // Mint proportionally based on the asset ratio (could also use stable or min)
        math::mul_div_to_64(asset_amount, total_lp, pool.asset_vault.value())
    };

    // 3. Loop and deposit into each AMM
    let mut i = 0;
    let outcome_count = proposal::outcome_count(proposal);
    while (i < outcome_count) {
        let asset_tkn = new_asset_tokens.pop_back();
        let stable_tkn = new_stable_tokens.pop_back();

        let amm_pool = proposal::get_pool_mut_by_outcome(proposal, (i as u8));
        // Add liquidity proportionally - LP tokens are returned as conditional tokens
        // Use 0 as min_lp_out for individual AMMs since slippage protection is at the spot pool level
        let lp_token = amm::add_liquidity_proportional(amm_pool, escrow, asset_tkn, stable_tkn, 0, clock, ctx);
        
        // Store the LP token instead of sending to black hole
        let proposal_id = proposal::get_id(proposal);
        if (!table::contains(&pool.amm_lp_tokens, proposal_id)) {
            table::add(&mut pool.amm_lp_tokens, proposal_id, vector::empty());
        };
        let lp_tokens_vec = table::borrow_mut(&mut pool.amm_lp_tokens, proposal_id);
        vector::push_back(lp_tokens_vec, lp_token);
        i = i + 1;
    };
    
    // Destroy empty vectors
    new_asset_tokens.destroy_empty();
    new_stable_tokens.destroy_empty();
    
    // Note: When there's an active proposal, the actual assets are held by the escrow,
    // not the spot pool. The spot pool tracks LP ownership via the amm_lp_tokens table.
    
    // Mint spot LP tokens representing ownership of the AMM LP token basket
    let lp_tokens = coin::mint(&mut pool.lp_supply, lp_to_mint, ctx);
    assert!(lp_to_mint >= min_lp_out, EExcessiveSlippage);
    
    transfer::public_transfer(lp_tokens, ctx.sender());
}

/// Remove liquidity from the spot AMM when no proposal is active
public entry fun remove_liquidity<Asset, Stable>(
    pool: &mut SpotLiquidityPool<Asset, Stable>,
    lp_coin: Coin<LP<Asset, Stable>>,
    min_asset_out: u64,
    min_stable_out: u64,
    ctx: &mut TxContext
) {
    let (asset_coin, stable_coin) = remove_liquidity_spot_only(pool, lp_coin, min_asset_out, min_stable_out, ctx);
    transfer::public_transfer(asset_coin, ctx.sender());
    transfer::public_transfer(stable_coin, ctx.sender());
}

/// Remove liquidity from the spot AMM when a proposal is active
public entry fun remove_liquidity_with_proposal<Asset, Stable>(
    pool: &mut SpotLiquidityPool<Asset, Stable>,
    proposal: &mut Proposal<Asset, Stable>,
    escrow: &mut TokenEscrow<Asset, Stable>,
    lp_coin: Coin<LP<Asset, Stable>>,
    min_asset_out: u64,
    min_stable_out: u64,
    clock: &Clock,
    ctx: &mut TxContext
) {
    let lp_amount = lp_coin.value();
    let total_lp = pool.lp_supply.total_supply();
    coin::burn(&mut pool.lp_supply, lp_coin);

    // Baskets to hold withdrawn conditional tokens
    let mut asset_tokens = vector::empty();
    let mut stable_tokens = vector::empty();

    let mut i = 0;
    let outcome_count = proposal::outcome_count(proposal);
    while (i < outcome_count) {
        // Get proposal ID before borrowing pool mutably
        let proposal_id = proposal::get_id(proposal);
        let amm_pool = proposal::get_pool_mut_by_outcome(proposal, (i as u8));
        assert!(table::contains(&pool.amm_lp_tokens, proposal_id), ENoLPAllocation);
        let stored_lp_tokens = table::borrow_mut(&mut pool.amm_lp_tokens, proposal_id);
        
        // Calculate proportional share of this outcome's LP tokens
        let outcome_lp_token = vector::borrow_mut(stored_lp_tokens, i);
        let outcome_lp_balance = outcome_lp_token.value();
        let lp_to_withdraw = math::mul_div_to_64(lp_amount, outcome_lp_balance, total_lp);
        
        // Split the required amount from stored LP token
        let lp_for_withdrawal = if (lp_to_withdraw == outcome_lp_balance) {
            vector::swap_remove(stored_lp_tokens, i)
        } else {
            // Split the token using the new function that returns the split token
            let mut temp_token = vector::swap_remove(stored_lp_tokens, i);
            let split_token = conditional_token::split_and_return(&mut temp_token, lp_to_withdraw, clock, ctx);
            vector::push_back(stored_lp_tokens, temp_token);
            split_token
        };
        
        let (asset_tkn, stable_tkn) = amm::remove_liquidity_proportional(amm_pool, escrow, lp_for_withdrawal, clock, ctx);
        asset_tokens.push_back(asset_tkn);
        stable_tokens.push_back(stable_tkn);
        i = i + 1;
    };

    // Recombine into spot tokens
    let asset_balance = coin_escrow::redeem_complete_set_asset(escrow, asset_tokens, clock, ctx);
    let stable_balance = coin_escrow::redeem_complete_set_stable(escrow, stable_tokens, clock, ctx);

    let asset_coin = coin::from_balance(asset_balance, ctx);
    let stable_coin = coin::from_balance(stable_balance, ctx);
    
    assert!(asset_coin.value() >= min_asset_out, EExcessiveSlippage);
    assert!(stable_coin.value() >= min_stable_out, EExcessiveSlippage);

    transfer::public_transfer(asset_coin, ctx.sender());
    transfer::public_transfer(stable_coin, ctx.sender());
}

public(package) fun add_liquidity_spot_only<Asset, Stable>(
    pool: &mut SpotLiquidityPool<Asset, Stable>,
    asset_coin: Coin<Asset>,
    stable_coin: Coin<Stable>,
    min_lp_out: u64,
    ctx: &mut TxContext,
): Coin<LP<Asset, Stable>> {
    let asset_amount = asset_coin.value();
    let stable_amount = stable_coin.value();
    assert!(asset_amount > 0 && stable_amount > 0, EZeroAmount);
    
    let asset_reserve = pool.asset_vault.value();
    let stable_reserve = pool.stable_vault.value();
    let total_supply = pool.lp_supply.total_supply();
    
    // Calculate optimal amounts based on current ratio with overflow protection
    let optimal_stable = math::mul_div_to_64(asset_amount, stable_reserve, asset_reserve);
    let optimal_asset = math::mul_div_to_64(stable_amount, asset_reserve, stable_reserve);
    
    let (actual_asset, actual_stable);
    if (optimal_stable <= stable_amount) {
        actual_asset = asset_amount;
        actual_stable = optimal_stable;
    } else {
        actual_asset = optimal_asset;
        actual_stable = stable_amount;
    };
    
    // Calculate LP tokens to mint with overflow protection
    let lp_asset_ratio = math::mul_div_to_64(actual_asset, total_supply, asset_reserve);
    let lp_stable_ratio = math::mul_div_to_64(actual_stable, total_supply, stable_reserve);
    let lp_to_mint = math::min(lp_asset_ratio, lp_stable_ratio);
    
    assert!(lp_to_mint >= min_lp_out, EExcessiveSlippage);
    
    // Update reserves
    pool.asset_vault.join(asset_coin.into_balance());
    pool.stable_vault.join(stable_coin.into_balance());
    
    // Mint LP tokens
    let lp_tokens = coin::mint(&mut pool.lp_supply, lp_to_mint, ctx);
    
    event::emit(LiquidityAdded {
        pool_id: object::id(pool),
        provider: ctx.sender(),
        asset_added: asset_amount,
        stable_added: stable_amount,
        lp_minted: lp_to_mint,
        new_asset_reserve: pool.asset_vault.value(),
        new_stable_reserve: pool.stable_vault.value(),
    });
    
    lp_tokens
}

public(package) fun remove_liquidity_spot_only<Asset, Stable>(
    pool: &mut SpotLiquidityPool<Asset, Stable>,
    lp_coin: Coin<LP<Asset, Stable>>,
    min_asset_out: u64,
    min_stable_out: u64,
    ctx: &mut TxContext,
): (Coin<Asset>, Coin<Stable>) {
    let lp_amount = lp_coin.value();
    assert!(lp_amount > 0, EZeroAmount);
    
    let total_supply = pool.lp_supply.total_supply();
    let asset_reserve = pool.asset_vault.value();
    let stable_reserve = pool.stable_vault.value();
    
    // Calculate proportional amounts with overflow protection
    let asset_out = math::mul_div_to_64(lp_amount, asset_reserve, total_supply);
    let stable_out = math::mul_div_to_64(lp_amount, stable_reserve, total_supply);

    assert!(asset_out >= min_asset_out, EExcessiveSlippage);
    assert!(stable_out >= min_stable_out, EExcessiveSlippage);

    let asset_balance = pool.asset_vault.split(asset_out);
    let stable_balance = pool.stable_vault.split(stable_out);

    coin::burn(&mut pool.lp_supply, lp_coin);
    

    (coin::from_balance(asset_balance, ctx), coin::from_balance(stable_balance, ctx))
}

/// Swap assets for stable coins in the spot AMM
public fun swap_asset_to_stable<Asset, Stable>(
    pool: &mut SpotLiquidityPool<Asset, Stable>,
    asset_in: Coin<Asset>,
    min_stable_out: u64,
    ctx: &mut TxContext
) {
    let swap_result = swap_asset_to_stable_internal(pool, asset_in, min_stable_out, ctx);
    let output_coin = get_output_coin(swap_result);
    transfer::public_transfer(output_coin, ctx.sender());
}

/// Swap stable coins for assets in the spot AMM
public fun swap_stable_to_asset<Asset, Stable>(
    pool: &mut SpotLiquidityPool<Asset, Stable>,
    stable_in: Coin<Stable>,
    min_asset_out: u64,
    ctx: &mut TxContext
) {
    let swap_result = swap_stable_to_asset_internal(pool, stable_in, min_asset_out, ctx);
    let output_coin = get_output_coin(swap_result);
    transfer::public_transfer(output_coin, ctx.sender());
}

/// Swap result struct to return multiple values
public struct SwapResult<T> {
    output_coin: Coin<T>,
    fee_amount: u64,
}

/// Get the output coin from SwapResult
public fun get_output_coin<T>(result: SwapResult<T>): Coin<T> {
    let SwapResult { output_coin, fee_amount: _ } = result;
    output_coin
}

/// Get the fee amount from SwapResult
public fun get_fee_amount<T>(result: &SwapResult<T>): u64 {
    result.fee_amount
}

/// Internal swap function that returns coins instead of transferring
public(package) fun swap_stable_to_asset_internal<Asset, Stable>(
    pool: &mut SpotLiquidityPool<Asset, Stable>,
    stable_in: Coin<Stable>,
    min_asset_out: u64,
    ctx: &mut TxContext
): SwapResult<Asset> {
    let amount_in = stable_in.value();
    assert!(amount_in > 0, EZeroAmount);
    
    let asset_reserve = pool.asset_vault.value();
    let stable_reserve = pool.stable_vault.value();
    
    // Calculate fees with overflow protection
    let total_fee_bps = (pool.lp_fee_bps + pool.protocol_fee_bps) as u64;
    let fee_amount = math::mul_div_to_64(amount_in, total_fee_bps, 10000);
    let amount_in_after_fee = amount_in - fee_amount;
    
    // Calculate output using constant product formula with overflow protection
    let amount_out = math::mul_div_to_64(
        amount_in_after_fee,
        asset_reserve,
        stable_reserve + amount_in_after_fee
    );
    
    assert!(amount_out >= min_asset_out, EExcessiveSlippage);
    
    // Calculate protocol fee with overflow protection
    let protocol_fee = math::mul_div_to_64(fee_amount, (pool.protocol_fee_bps as u64), total_fee_bps);
    let mut stable_balance = stable_in.into_balance();
    pool.accumulated_protocol_fees.join(balance::split(&mut stable_balance, protocol_fee));
    
    // Update pool state
    pool.stable_vault.join(stable_balance);
    let asset_out = pool.asset_vault.split(amount_out);
    
    event::emit(SpotSwap {
        pool_id: object::id(pool),
        trader: ctx.sender(),
        amount_in,
        amount_out,
        is_asset_in: false,
        fee_amount,
        new_asset_reserve: pool.asset_vault.value(),
        new_stable_reserve: pool.stable_vault.value(),
    });
    
    SwapResult {
        output_coin: coin::from_balance(asset_out, ctx),
        fee_amount,
    }
}

/// Internal swap function that returns coins instead of transferring
public(package) fun swap_asset_to_stable_internal<Asset, Stable>(
    pool: &mut SpotLiquidityPool<Asset, Stable>,
    asset_in: Coin<Asset>,
    min_stable_out: u64,
    ctx: &mut TxContext
): SwapResult<Stable> {
    let amount_in = asset_in.value();
    assert!(amount_in > 0, EZeroAmount);
    
    let asset_reserve = pool.asset_vault.value();
    let stable_reserve = pool.stable_vault.value();
    
    // Calculate fees with overflow protection
    let total_fee_bps = (pool.lp_fee_bps + pool.protocol_fee_bps) as u64;
    let fee_amount = math::mul_div_to_64(amount_in, total_fee_bps, 10000);
    let amount_in_after_fee = amount_in - fee_amount;
    
    // Calculate output using constant product formula with overflow protection
    let amount_out = math::mul_div_to_64(
        amount_in_after_fee,
        stable_reserve,
        asset_reserve + amount_in_after_fee
    );
    
    assert!(amount_out >= min_stable_out, EExcessiveSlippage);
    
    // Calculate protocol fee portion with overflow protection
    let protocol_fee = math::mul_div_to_64(fee_amount, (pool.protocol_fee_bps as u64), total_fee_bps);
    
    // Update pool state
    pool.asset_vault.join(asset_in.into_balance());
    let stable_out = pool.stable_vault.split(amount_out);
    
    // Track protocol fees (converted to stable value) with overflow protection
    let protocol_fee_stable = math::mul_div_to_64(protocol_fee, amount_out, amount_in_after_fee);
    pool.accumulated_protocol_fees.join(pool.stable_vault.split(protocol_fee_stable));
    
    event::emit(SpotSwap {
        pool_id: object::id(pool),
        trader: ctx.sender(),
        amount_in,
        amount_out,
        is_asset_in: true,
        fee_amount,
        new_asset_reserve: pool.asset_vault.value(),
        new_stable_reserve: pool.stable_vault.value(),
    });
    
    SwapResult {
        output_coin: coin::from_balance(stable_out, ctx),
        fee_amount,
    }
}


// === View Functions ===

public fun get_reserves<Asset, Stable>(pool: &SpotLiquidityPool<Asset, Stable>): (u64, u64) {
    (pool.asset_vault.value(), pool.stable_vault.value())
}

public fun get_spot_price<Asset, Stable>(pool: &SpotLiquidityPool<Asset, Stable>): u128 {
    let asset_reserve = pool.asset_vault.value();
    let stable_reserve = pool.stable_vault.value();
    
    // Price = stable_reserve / asset_reserve (scaled by 1e9 for precision)
    ((stable_reserve as u128) * 1_000_000_000) / (asset_reserve as u128)
}

public fun total_lp_supply<Asset, Stable>(pool: &SpotLiquidityPool<Asset, Stable>): u64 {
    pool.lp_supply.total_supply()
}

public fun pool_id<Asset, Stable>(pool: &SpotLiquidityPool<Asset, Stable>): ID {
    object::id(pool)
}

public fun min_liquidity<Asset, Stable>(pool: &SpotLiquidityPool<Asset, Stable>): u64 {
    pool.min_liquidity_stable
}


// === Admin Functions ===

/// Collect accumulated protocol fees
public fun collect_protocol_fees<Asset, Stable>(
    pool: &mut SpotLiquidityPool<Asset, Stable>,
    admin_cap: &ProtocolAdminCap,
    ctx: &mut TxContext
) {
    // Verify the admin cap belongs to this pool
    assert!(object::id(admin_cap) == pool.protocol_admin_cap_id, EInvalidAdminCap);
    let fee_amount = pool.accumulated_protocol_fees.value();
    if (fee_amount > 0) {
        let fees = coin::from_balance(
            pool.accumulated_protocol_fees.split(fee_amount),
            ctx
        );
        
        transfer::public_transfer(fees, ctx.sender());
        
        event::emit(ProtocolFeesCollected {
            pool_id: object::id(pool),
            amount: fee_amount,
            collector: ctx.sender(),
        });
    }
}

/// Update fee parameters
public fun update_fees<Asset, Stable>(
    pool: &mut SpotLiquidityPool<Asset, Stable>,
    new_lp_fee_bps: u16,
    new_protocol_fee_bps: u16,
    _ctx: &mut TxContext
) {
    assert!(new_lp_fee_bps + new_protocol_fee_bps < 1000, EInsufficientLiquidity); // Max 10% total
    
    pool.lp_fee_bps = new_lp_fee_bps;
    pool.protocol_fee_bps = new_protocol_fee_bps;
}