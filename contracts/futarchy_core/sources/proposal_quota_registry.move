// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

/// Proposal quota registry for allowlisted addresses
/// Tracks recurring proposal quotas (N proposals per period at reduced fee)
module futarchy_core::proposal_quota_registry;

use std::string::String;
use sui::clock::Clock;
use sui::event;
use sui::table::{Self, Table};

// === Errors ===
const EInvalidQuotaParams: u64 = 0;
const EWrongDao: u64 = 1;

// === Structs ===

/// Recurring quota: N proposals per period at reduced fee
public struct QuotaInfo has copy, drop, store {
    /// Number of proposals allowed per period
    quota_amount: u64,
    /// Time period in milliseconds (e.g., 30 days = 2_592_000_000)
    quota_period_ms: u64,
    /// Reduced fee (0 for free)
    reduced_fee: u64,
    /// Period start (aligned to boundaries, not drift)
    period_start_ms: u64,
    /// Usage in current period
    used_in_period: u64,
}

/// Registry for a specific DAO's proposal quotas
public struct ProposalQuotaRegistry has key, store {
    id: UID,
    /// The DAO this registry belongs to
    dao_id: ID,
    /// Maps address to their quota info
    quotas: Table<address, QuotaInfo>,
}

// === Events ===

public struct QuotasSet has copy, drop {
    dao_id: ID,
    users: vector<address>,
    quota_amount: u64,
    quota_period_ms: u64,
    reduced_fee: u64,
    timestamp: u64,
}

public struct QuotasRemoved has copy, drop {
    dao_id: ID,
    users: vector<address>,
    timestamp: u64,
}

public struct QuotaUsed has copy, drop {
    dao_id: ID,
    user: address,
    remaining: u64,
    timestamp: u64,
}

public struct QuotaRefunded has copy, drop {
    dao_id: ID,
    user: address,
    remaining: u64,
    timestamp: u64,
    reason: String,
}

// === Public Functions ===

/// Create a new quota registry for a DAO
public fun new(dao_id: ID, ctx: &mut TxContext): ProposalQuotaRegistry {
    ProposalQuotaRegistry {
        id: object::new(ctx),
        dao_id,
        quotas: table::new(ctx),
    }
}

/// Set quotas for multiple users (batch operation)
/// Pass empty quota_amount to remove quotas
public fun set_quotas(
    registry: &mut ProposalQuotaRegistry,
    dao_id: ID,
    users: vector<address>,
    quota_amount: u64,
    quota_period_ms: u64,
    reduced_fee: u64,
    clock: &Clock,
) {
    // Verify DAO ownership
    assert!(registry.dao_id == dao_id, EWrongDao);

    // Validate params if setting (not removing)
    if (quota_amount > 0) {
        assert!(quota_period_ms > 0, EInvalidQuotaParams);
    };

    let now = clock.timestamp_ms();
    let mut i = 0;
    let len = users.length();

    while (i < len) {
        let user = *users.borrow(i);

        if (quota_amount == 0) {
            // Remove quota
            if (registry.quotas.contains(user)) {
                registry.quotas.remove(user);
            };
        } else {
            // Set/update quota
            let info = QuotaInfo {
                quota_amount,
                quota_period_ms,
                reduced_fee,
                period_start_ms: now,
                used_in_period: 0,
            };

            if (registry.quotas.contains(user)) {
                *registry.quotas.borrow_mut(user) = info;
            } else {
                registry.quotas.add(user, info);
            };
        };

        i = i + 1;
    };

    // Emit appropriate event
    if (quota_amount == 0) {
        event::emit(QuotasRemoved {
            dao_id,
            users,
            timestamp: now,
        });
    } else {
        event::emit(QuotasSet {
            dao_id,
            users,
            quota_amount,
            quota_period_ms,
            reduced_fee,
            timestamp: now,
        });
    };
}

/// Check quota availability (read-only, no state mutation)
/// Returns (has_quota, reduced_fee)
public fun check_quota_available(
    registry: &ProposalQuotaRegistry,
    dao_id: ID,
    user: address,
    clock: &Clock,
): (bool, u64) {
    // Verify DAO ownership
    assert!(registry.dao_id == dao_id, EWrongDao);

    if (!registry.quotas.contains(user)) {
        return (false, 0)
    };

    let info = registry.quotas.borrow(user);
    let now = clock.timestamp_ms();

    // Calculate periods elapsed for alignment (no drift)
    let periods_elapsed = (now - info.period_start_ms) / info.quota_period_ms;

    // If period expired, quota resets
    let used = if (periods_elapsed > 0) {
        0
    } else {
        info.used_in_period
    };

    let has_quota = used < info.quota_amount;
    (has_quota, info.reduced_fee)
}

/// Use one quota slot (called AFTER proposal succeeds)
/// This prevents quota loss if proposal creation fails
public fun use_quota(
    registry: &mut ProposalQuotaRegistry,
    dao_id: ID,
    user: address,
    clock: &Clock,
) {
    // Verify DAO ownership
    assert!(registry.dao_id == dao_id, EWrongDao);

    if (!registry.quotas.contains(user)) {
        return
    };

    let info = registry.quotas.borrow_mut(user);
    let now = clock.timestamp_ms();

    // Reset period if expired (aligned to boundaries)
    let periods_elapsed = (now - info.period_start_ms) / info.quota_period_ms;
    if (periods_elapsed > 0) {
        info.period_start_ms = info.period_start_ms + (periods_elapsed * info.quota_period_ms);
        info.used_in_period = 0;
    };

    // Use one slot (should always have quota here, but safe increment)
    if (info.used_in_period < info.quota_amount) {
        info.used_in_period = info.used_in_period + 1;

        event::emit(QuotaUsed {
            dao_id: registry.dao_id,
            user,
            remaining: info.quota_amount - info.used_in_period,
            timestamp: now,
        });
    };
}

/// Refund one quota slot (called when proposal using quota is evicted)
/// Only decrements if user has used quota in current period
public fun refund_quota(
    registry: &mut ProposalQuotaRegistry,
    dao_id: ID,
    user: address,
    clock: &Clock,
) {
    use std::string;

    // Verify DAO ownership
    assert!(registry.dao_id == dao_id, EWrongDao);

    if (!registry.quotas.contains(user)) {
        return
    };

    let info = registry.quotas.borrow_mut(user);
    let now = clock.timestamp_ms();

    // Reset period if expired (aligned to boundaries)
    let periods_elapsed = (now - info.period_start_ms) / info.quota_period_ms;
    if (periods_elapsed > 0) {
        info.period_start_ms = info.period_start_ms + (periods_elapsed * info.quota_period_ms);
        info.used_in_period = 0;

        // Emit event for period reset (no refund needed)
        event::emit(QuotaRefunded {
            dao_id: registry.dao_id,
            user,
            remaining: info.quota_amount, // Full quota available in new period
            timestamp: now,
            reason: string::utf8(b"period_expired"),
        });
        return
    };

    // Decrement usage if any quota was used
    if (info.used_in_period > 0) {
        info.used_in_period = info.used_in_period - 1;

        // Emit refund event
        event::emit(QuotaRefunded {
            dao_id: registry.dao_id,
            user,
            remaining: info.quota_amount - info.used_in_period,
            timestamp: now,
            reason: string::utf8(b"proposal_evicted"),
        });
    };
}

// === View Functions ===

/// Get quota info with remaining count
/// Returns (has_quota, remaining, reduced_fee)
public fun get_quota_status(
    registry: &ProposalQuotaRegistry,
    user: address,
    clock: &Clock,
): (bool, u64, u64) {
    if (!registry.quotas.contains(user)) {
        return (false, 0, 0)
    };

    let info = registry.quotas.borrow(user);
    let now = clock.timestamp_ms();

    let periods_elapsed = (now - info.period_start_ms) / info.quota_period_ms;
    let used = if (periods_elapsed > 0) { 0 } else { info.used_in_period };
    let remaining = info.quota_amount - used;

    (remaining > 0, remaining, info.reduced_fee)
}

/// Get DAO ID
public fun dao_id(registry: &ProposalQuotaRegistry): ID {
    registry.dao_id
}

/// Check if user has any quota
public fun has_quota(registry: &ProposalQuotaRegistry, user: address): bool {
    registry.quotas.contains(user)
}

// === Getter Functions ===

public fun quota_amount(info: &QuotaInfo): u64 { info.quota_amount }

public fun quota_period_ms(info: &QuotaInfo): u64 { info.quota_period_ms }

public fun reduced_fee(info: &QuotaInfo): u64 { info.reduced_fee }

public fun period_start_ms(info: &QuotaInfo): u64 { info.period_start_ms }

public fun used_in_period(info: &QuotaInfo): u64 { info.used_in_period }
