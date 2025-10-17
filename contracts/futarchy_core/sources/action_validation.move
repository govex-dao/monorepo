// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

/// Module for validating action types in intents
module futarchy_core::action_validation;

use account_protocol::intents::ActionSpec;
use std::type_name::{Self, TypeName};

/// Error codes
const EActionTypeMismatch: u64 = 1;

/// Assert that an action spec matches the expected action type
/// This validates that the action type in the spec matches the type T
public fun assert_action_type<T>(spec: &ActionSpec) {
    use account_protocol::intents;
    let expected_type = type_name::with_defining_ids<T>();
    let actual_type = intents::action_spec_type(spec);
    assert!(actual_type == expected_type, EActionTypeMismatch);
}
