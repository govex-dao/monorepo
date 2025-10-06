#[test_only]
module futarchy_oracle::oracle_helpers_tests;

use futarchy_oracle::oracle_actions;

// === Helper Function Tests ===

#[test]
fun test_relative_price_condition() {
    let condition = oracle_actions::relative_price_condition(
        3_000_000_000,  // 3x multiplier
        true            // above threshold
    );

    // Just verify it compiles and doesn't abort
    let _ = condition;
}

#[test]
fun test_absolute_price_condition() {
    let condition = oracle_actions::absolute_price_condition(
        1_000_000_000_000,  // 1.0 price (scaled 1e12)
        false                // below threshold
    );

    let _ = condition;
}

#[test]
fun test_repeat_config() {
    let config = oracle_actions::repeat_config(
        86_400_000,  // 1 day cooldown
        10           // max 10 executions
    );

    let _ = config;
}

#[test]
fun test_new_recipient_mint() {
    let recipient_mint = oracle_actions::new_recipient_mint(
        @0xB0B,   // recipient
        100_000   // amount
    );

    let _ = recipient_mint;
}

// === Action Constructor Tests ===

#[test]
fun test_new_create_employee_option() {
    public struct ASSET has drop {}
    public struct STABLE has drop {}

    let action = oracle_actions::new_create_employee_option<ASSET, STABLE>(
        @0xB0B,         // recipient
        100_000,        // total_amount
        1_000_000_000,  // strike_price
        3,              // cliff_months
        4,              // total_vesting_years
        3_000_000_000,  // launchpad_multiplier
        10              // expiry_years
    );

    let _ = action;
}

#[test]
fun test_new_create_vesting_grant() {
    public struct ASSET has drop {}
    public struct STABLE has drop {}

    let action = oracle_actions::new_create_vesting_grant<ASSET, STABLE>(
        @0xB0B,   // recipient
        50_000,   // total_amount
        6,        // cliff_months
        2         // total_vesting_years
    );

    let _ = action;
}

#[test]
fun test_new_create_conditional_mint() {
    public struct ASSET has drop {}
    public struct STABLE has drop {}

    let action = oracle_actions::new_create_conditional_mint<ASSET, STABLE>(
        @0xB0B,              // recipient
        1_000,               // mint_amount
        2_000_000_000_000,   // price_threshold
        true,                // is_above_threshold
        3_600_000,           // cooldown_ms (1 hour)
        5                    // max_executions
    );

    let _ = action;
}

#[test]
fun test_new_cancel_grant() {
    use sui::object;

    let grant_id = object::id_from_address(@0xGRANT);
    let action = oracle_actions::new_cancel_grant(grant_id);

    let _ = action;
}

#[test]
fun test_new_pause_grant() {
    use sui::object;

    let grant_id = object::id_from_address(@0xGRANT);
    let action = oracle_actions::new_pause_grant(grant_id, 86_400_000); // 1 day

    let _ = action;
}

#[test]
fun test_new_unpause_grant() {
    use sui::object;

    let grant_id = object::id_from_address(@0xGRANT);
    let action = oracle_actions::new_unpause_grant(grant_id);

    let _ = action;
}

#[test]
fun test_new_emergency_freeze_grant() {
    use sui::object;

    let grant_id = object::id_from_address(@0xGRANT);
    let action = oracle_actions::new_emergency_freeze_grant(grant_id);

    let _ = action;
}

#[test]
fun test_new_emergency_unfreeze_grant() {
    use sui::object;

    let grant_id = object::id_from_address(@0xGRANT);
    let action = oracle_actions::new_emergency_unfreeze_grant(grant_id);

    let _ = action;
}
