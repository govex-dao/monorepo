module futarchy::custody_actions;

use std::string::String;
use sui::object::ID;
use account_protocol::intents::Expired;

/// DAO-side approval to accept an object R into council custody.
public struct ApproveCustodyAction<phantom R> has store {
    dao_id: ID,
    object_id: ID,
    resource_key: String,
    context: String,
    expires_at: u64,
}

/// Council action to accept an object R into custody.
public struct AcceptIntoCustodyAction<phantom R> has store {
    object_id: ID,
    resource_key: String,
    context: String,
}

// Constructors

public fun new_approve_custody<R>(
    dao_id: ID,
    object_id: ID,
    resource_key: String,
    context: String,
    expires_at: u64,
): ApproveCustodyAction<R> {
    ApproveCustodyAction<R> { dao_id, object_id, resource_key, context, expires_at }
}

public fun new_accept_into_custody<R>(
    object_id: ID,
    resource_key: String,
    context: String,
): AcceptIntoCustodyAction<R> {
    AcceptIntoCustodyAction<R> { object_id, resource_key, context }
}

// Getters

public fun get_approve_custody_params<R>(
    a: &ApproveCustodyAction<R>
): (ID, ID, &String, &String, u64) {
    (a.dao_id, a.object_id, &a.resource_key, &a.context, a.expires_at)
}

public fun get_accept_params<R>(
    a: &AcceptIntoCustodyAction<R>
): (ID, &String, &String) {
    (a.object_id, &a.resource_key, &a.context)
}

// Cleanup

public fun delete_approve_custody<R>(expired: &mut Expired) {
    let ApproveCustodyAction<R> {
        dao_id: _,
        object_id: _,
        resource_key: _,
        context: _,
        expires_at: _
    } = expired.remove_action();
}

public fun delete_accept_into_custody<R>(expired: &mut Expired) {
    let AcceptIntoCustodyAction<R> {
        object_id: _,
        resource_key: _,
        context: _
    } = expired.remove_action();
}