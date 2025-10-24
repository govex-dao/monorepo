// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

/// Intent builders for NAV market making actions
module futarchy_actions::nav_market_making_intents;

use account_protocol::intents::{Self, Intent};
use futarchy_actions::nav_market_making_actions;
use std::string::String;
use std::type_name;
use sui::bcs;
use sui::clock::Clock;
use sui::object::ID;

use fun account_protocol::intents::add_typed_action as Intent.add_typed_action;

// === Witness ===

/// Witness type for NAV market making intents
public struct NavMarketMakingIntent has copy, drop {}

/// Create a NavMarketMakingIntent witness
public fun witness(): NavMarketMakingIntent {
    NavMarketMakingIntent {}
}

// === Intent Builder Functions ===

/// Add create NAV market making capability action to an intent
/// Creates fixed-rate buyback/sell capability with time limit
public fun create_nav_market_making_in_intent<Outcome: store, AssetType, StableType, IW: drop>(
    intent: &mut Intent<Outcome>,
    nav_per_token: u64,
    vault_name: String,
    buyback_discount_bps: u64,
    buyback_enabled: bool,
    max_buyback_stable: u64,
    sell_premium_bps: u64,
    sell_enabled: bool,
    max_sell_stable: u64,
    expiry_time_ms: u64,
    cancel_cap_recipient: address,
    intent_witness: IW,
) {
    let action = nav_market_making_actions::new_create_nav_market_making<AssetType, StableType>(
        nav_per_token,
        vault_name,
        buyback_discount_bps,
        buyback_enabled,
        max_buyback_stable,
        sell_premium_bps,
        sell_enabled,
        max_sell_stable,
        expiry_time_ms,
        cancel_cap_recipient,
    );
    let action_data = bcs::to_bytes(&action);
    intent.add_typed_action(
        type_name::with_defining_ids<nav_market_making_actions::CreateNavMarketMaking>().into_string().to_string(),
        action_data,
        intent_witness,
    );
    // Action struct has drop ability, will be automatically dropped
}

/// Add cancel NAV market making capability action to an intent
public fun cancel_nav_market_making_in_intent<Outcome: store, IW: drop>(
    intent: &mut Intent<Outcome>,
    capability_id: ID,
    intent_witness: IW,
) {
    let action = nav_market_making_actions::new_cancel_nav_market_making(capability_id);
    let action_data = bcs::to_bytes(&action);
    intent.add_typed_action(
        type_name::with_defining_ids<nav_market_making_actions::CancelNavMarketMaking>().into_string().to_string(),
        action_data,
        intent_witness,
    );
    // Action struct has drop ability, will be automatically dropped
}

// === Helper Functions ===

/// Create a unique key for a NAV market making intent
public fun create_nav_market_making_key(operation: String, clock: &Clock): String {
    let mut key = b"nav_market_making_".to_string();
    key.append(operation);
    key.append(b"_".to_string());
    key.append(clock.timestamp_ms().to_string());
    key
}
