#[test_only]
module futarchy::coin_escrow_tests {
    use futarchy::coin_escrow;
    use futarchy::market_state::{Self};
    use futarchy::conditional_token;
    use sui::test_utils;
    use sui::tx_context;
    use sui::object;
    use sui::balance;
    use sui::coin;
    use sui::clock::{Self, Clock};

    // Define dummy types to stand in for actual asset and stable types.
    public struct DummyAsset has copy, drop, store {}
    public struct DummyStable has copy, drop, store {}

    // These are the constants defined in the coin_escrow module
    // We need to define them here since constants are internal to their module
    const TOKEN_TYPE_STABLE: u8 = 1;
    const TOKEN_TYPE_ASSET: u8 = 0;

    // Create a dummy MarketState instance for testing.
    fun create_dummy_market_state(ctx: &mut tx_context::TxContext): market_state::MarketState {
        // For simplicity, create a market with 1 outcome.
        market_state::create_for_testing(1, ctx)
    }

    // Create a dummy TxContext.
    fun create_test_context(): tx_context::TxContext {
        tx_context::dummy()
    }

    // Helper function to setup a market with multiple outcomes
    fun setup_market_with_escrow(
        outcome_count: u64, 
        ctx: &mut tx_context::TxContext
    ): (market_state::MarketState, coin_escrow::TokenEscrow<DummyAsset, DummyStable>) {
        let ms = market_state::create_for_testing(outcome_count, ctx);
        // Create a reference to ms instead of trying to copy it
        let escrow = coin_escrow::new<DummyAsset, DummyStable>(ms, ctx);

        // Create a new MarketState since the original was moved
        let ms = market_state::create_for_testing(outcome_count, ctx);
        
        (ms, escrow)
    }

    // Helper to register supplies for all outcomes
    fun register_all_supplies(
        escrow: &mut coin_escrow::TokenEscrow<DummyAsset, DummyStable>,
        outcome_count: u64,
        ctx: &mut tx_context::TxContext
    ) {
        let mut i = 0;
        while (i < outcome_count) {
            let market_state = coin_escrow::get_market_state(escrow);
            let asset_supply = conditional_token::new_supply(copy market_state, TOKEN_TYPE_ASSET, (i as u8), ctx);
            let stable_supply = conditional_token::new_supply(market_state, TOKEN_TYPE_STABLE, (i as u8), ctx);

            coin_escrow::register_supplies(escrow, i, asset_supply, stable_supply);
            i = i + 1;
        }
    }

    // Helper function to add asset balance to escrow
    #[test_only]
    fun add_asset_balance<AssetType, StableType>(
        escrow: &mut coin_escrow::TokenEscrow<AssetType, StableType>,
        amount: u64,
        ctx: &mut tx_context::TxContext
    ) {
        let coin = coin::mint_for_testing<AssetType>(amount, ctx);
        let clock = clock::create_for_testing(ctx);
        coin_escrow::mint_complete_set_asset_entry(escrow, coin, &clock, ctx);
        clock::destroy_for_testing(clock);
    }

    // Helper function to add stable balance to escrow
    #[test_only]
    fun add_stable_balance<AssetType, StableType>(
        escrow: &mut coin_escrow::TokenEscrow<AssetType, StableType>,
        amount: u64,
        ctx: &mut tx_context::TxContext
    ) {
        let coin = coin::mint_for_testing<StableType>(amount, ctx);
        let clock = clock::create_for_testing(ctx);
        coin_escrow::mint_complete_set_stable_entry(escrow, coin, &clock, ctx);
        clock::destroy_for_testing(clock);
    }

    #[test]
    fun test_register_supplies() {
        let mut ctx = create_test_context();
        let ms = create_dummy_market_state(&mut ctx);
        
        // Create a new token escrow instance
        let mut escrow = coin_escrow::new<DummyAsset, DummyStable>(ms, &mut ctx);
        
        // Create dummy supplies for testing - using our local constants
        let market_state = coin_escrow::get_market_state(&escrow);
        let asset_supply = conditional_token::new_supply(market_state, TOKEN_TYPE_ASSET, 0, &mut ctx);
        let stable_supply = conditional_token::new_supply(market_state, TOKEN_TYPE_STABLE, 0, &mut ctx);
        
        // Register the supplies
        coin_escrow::register_supplies(&mut escrow, 0, asset_supply, stable_supply);
        
        // Get separate references to avoid borrowing errors
        let asset_supply_ref = coin_escrow::get_asset_supply(&mut escrow, 0);
        
        // Verify the asset supply has expected property
        assert!(conditional_token::total_supply(asset_supply_ref) == 0, 0);
        
        // Get stable supply reference after we're done with asset supply
        let stable_supply_ref = coin_escrow::get_stable_supply(&mut escrow, 0);
        
        // Verify the stable supply has expected property
        assert!(conditional_token::total_supply(stable_supply_ref) == 0, 0);
        
        test_utils::destroy(escrow);
    }

    #[test]
    fun test_mint_and_redeem_complete_set() {
        let mut ctx = create_test_context();
        let mut ms = create_dummy_market_state(&mut ctx);
        
        // Initialize trading for the market
        market_state::init_trading_for_testing(&mut ms);
        
        // Create a new token escrow instance
        let mut escrow = coin_escrow::new<DummyAsset, DummyStable>(ms, &mut ctx);
        
        // Create dummy supplies for testing - using our local constants
        let market_state = coin_escrow::get_market_state(&escrow);
        let asset_supply = conditional_token::new_supply(market_state, TOKEN_TYPE_ASSET, 0, &mut ctx);
        let stable_supply = conditional_token::new_supply(market_state, TOKEN_TYPE_STABLE, 0, &mut ctx);
        
        // Register the supplies
        coin_escrow::register_supplies(&mut escrow, 0, asset_supply, stable_supply);
        
        // Create a dummy clock
        let clock = sui::clock::create_for_testing(&mut ctx);
        
        // Create a dummy asset coin with a value of 100
        let asset_coin = sui::coin::mint_for_testing<DummyAsset>(100, &mut ctx);
        
        // Mint a complete set of tokens
        let tokens = coin_escrow::mint_complete_set_asset(
            &mut escrow,
            asset_coin,
            &clock,
            &mut ctx
        );
        
        // Verify we received the expected number of tokens (1 in this case for a single outcome)
        assert!(vector::length(&tokens) == 1, 0);
        
        // Check balances after minting
        let (asset_balance, _) = coin_escrow::get_balances(&escrow);
        assert!(asset_balance == 100, 0);
        
        // Redeem the complete set of tokens
        let redeemed_balance = coin_escrow::redeem_complete_set_asset(
            &mut escrow,
            tokens,
            &clock,
            &mut ctx
        );
        
        // Verify redeemed amount matches the original deposit
        assert!(balance::value(&redeemed_balance) == 100, 0);
        
        // Check escrow balances after redemption
        let (asset_balance_after, _) = coin_escrow::get_balances(&escrow);
        assert!(asset_balance_after == 0, 0);
        
        // Clean up resources
        balance::destroy_for_testing(redeemed_balance);
        sui::clock::destroy_for_testing(clock);
        test_utils::destroy(escrow);
    }

    #[test]
    fun test_deposit_initial_liquidity() {
        let mut ctx = create_test_context();
        let outcome_count = 2;
        let (ms, mut escrow) = setup_market_with_escrow(outcome_count, &mut ctx);
        
        // Register supplies for all outcomes
        register_all_supplies(&mut escrow, outcome_count, &mut ctx);
        
        // Create initial balances to deposit
        let initial_asset = balance::create_for_testing<DummyAsset>(1000);
        let initial_stable = balance::create_for_testing<DummyStable>(2000);
        
        // Create asset and stable amounts vectors for each outcome
        let mut asset_amounts = vector::empty<u64>();
        let mut stable_amounts = vector::empty<u64>();
        
        // Configure different amounts per outcome
        vector::push_back(&mut asset_amounts, 500); // Outcome 0 asset amount
        vector::push_back(&mut asset_amounts, 1000); // Outcome 1 asset amount
        
        vector::push_back(&mut stable_amounts, 2000); // Outcome 0 stable amount
        vector::push_back(&mut stable_amounts, 1000); // Outcome 1 stable amount
        
        // Create clock for timestamp
        let clock = clock::create_for_testing(&mut ctx);
        
        // Initialize trading for the market
        market_state::init_trading_for_testing(coin_escrow::get_market_state_mut(&mut escrow));
        
        // Deposit initial liquidity
        coin_escrow::deposit_initial_liquidity(
            &mut escrow,
            outcome_count,
            &asset_amounts,
            &stable_amounts,
            initial_asset,
            initial_stable,
            &clock,
            &mut ctx
        );
        
        // Check balances after deposit
        let (asset_balance, stable_balance) = coin_escrow::get_balances(&escrow);
        assert!(asset_balance == 1000, 0);
        assert!(stable_balance == 2000, 1);
        
        // Clean up
        clock::destroy_for_testing(clock);
        market_state::destroy_for_testing(ms);
        test_utils::destroy(escrow);
    }

    #[test]
    fun test_remove_liquidity() {
        let mut ctx = create_test_context();
        let outcome_count = 1;
        let (ms, mut escrow) = setup_market_with_escrow(outcome_count, &mut ctx);
        
        // Register supplies for all outcomes
        register_all_supplies(&mut escrow, outcome_count, &mut ctx);
        
        // Add some initial liquidity to the escrow

        let market_state = coin_escrow::get_market_state_mut(&mut escrow);
        
        // Setup empty vectors since we're not using deposit_initial_liquidity
        // Just directly joining the balances for simplicity
        // Add initial balances using the entry functions as workaround
        add_asset_balance(&mut escrow, 1000, &mut ctx);
        add_stable_balance(&mut escrow, 2000, &mut ctx);

        // Now test removal
        coin_escrow::remove_liquidity(
            &mut escrow,
            500, // asset amount to remove
            1000, // stable amount to remove
            &mut ctx
        );
        
        // Verify balances after removal
        let (asset_balance, stable_balance) = coin_escrow::get_balances(&escrow);
        assert!(asset_balance == 500, 0); // 1000 - 500 = 500
        assert!(stable_balance == 1000, 1); // 2000 - 1000 = 1000
        market_state::destroy_for_testing(ms);
        test_utils::destroy(escrow);
    }

    #[test]
    fun test_mint_and_redeem_complete_set_stable() {
        let mut ctx = create_test_context();
        let outcome_count = 1;
        let (ms, mut escrow) = setup_market_with_escrow(outcome_count, &mut ctx);
        
        // Register supplies for the outcome
        register_all_supplies(&mut escrow, outcome_count, &mut ctx);
        
        // Initialize trading for the market
        market_state::init_trading_for_testing(coin_escrow::get_market_state_mut(&mut escrow));
        
        // Create clock for timestamps
        let clock = clock::create_for_testing(&mut ctx);
        
        // Create a stable coin to mint tokens
        let stable_coin = coin::mint_for_testing<DummyStable>(500, &mut ctx);
        
        // Mint complete set of stable tokens
        let tokens = coin_escrow::mint_complete_set_stable(
            &mut escrow,
            stable_coin,
            &clock,
            &mut ctx
        );
        
        // Verify we received the right number of tokens
        assert!(vector::length(&tokens) == outcome_count, 0);
        
        // Check escrow balances
        let (_, stable_balance) = coin_escrow::get_balances(&escrow);
        assert!(stable_balance == 500, 1);
        
        // Redeem the complete set
        let redeemed_balance = coin_escrow::redeem_complete_set_stable(
            &mut escrow,
            tokens,
            &clock,
            &mut ctx
        );
        
        // Verify redeemed amount
        assert!(balance::value(&redeemed_balance) == 500, 2);
        
        // Verify escrow balance is back to zero
        let (_, stable_balance_after) = coin_escrow::get_balances(&escrow);
        assert!(stable_balance_after == 0, 3);
        
        // Clean up
        balance::destroy_for_testing(redeemed_balance);
        clock::destroy_for_testing(clock);
        market_state::destroy_for_testing(ms);
        test_utils::destroy(escrow);
    }

    #[test]
    fun test_extract_stable_fees() {
        let mut ctx = create_test_context();
        let outcome_count = 1;
        let (ms, mut escrow) = setup_market_with_escrow(outcome_count, &mut ctx);
        
        // Register supplies
        register_all_supplies(&mut escrow, outcome_count, &mut ctx);
        
        // Add stable coins to the escrow
        add_stable_balance(&mut escrow, 1000, &mut ctx);
        
        // Extract fees
        let fees = coin_escrow::extract_stable_fees(&mut escrow, 200);
        
        // Verify fee amount
        assert!(balance::value(&fees) == 200, 0);
        
        // Verify remaining escrow balance
        let (_, stable_balance_after) = coin_escrow::get_balances(&escrow);
        assert!(stable_balance_after == 800, 1); // 1000 - 200 = 800
        
        // Clean up
        balance::destroy_for_testing(fees);
        market_state::destroy_for_testing(ms);
        test_utils::destroy(escrow);
    }
}