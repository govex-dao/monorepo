#!/bin/bash

# Script to add destruction functions and new_ functions to operating_agreement_actions.move

echo "Adding destruction functions to operating_agreement_actions.move..."

FILE="/Users/admin/monorepo/contracts/futarchy_specialized_actions/sources/legal/operating_agreement_actions.move"

# Add destruction functions before the getter functions
cat >> "$FILE" << 'EOF'

// === Destruction Functions ===

public fun destroy_create_operating_agreement(action: CreateOperatingAgreementAction) {
    let CreateOperatingAgreementAction {
        allow_insert: _,
        allow_remove: _
    } = action;
}

public fun destroy_update_line(action: UpdateLineAction) {
    let UpdateLineAction {
        line_id: _,
        new_text: _
    } = action;
}

public fun destroy_insert_line_after(action: InsertLineAfterAction) {
    let InsertLineAfterAction {
        prev_line_id: _,
        text: _,
        difficulty: _
    } = action;
}

public fun destroy_insert_line_at_beginning(action: InsertLineAtBeginningAction) {
    let InsertLineAtBeginningAction {
        text: _,
        difficulty: _
    } = action;
}

public fun destroy_remove_line(action: RemoveLineAction) {
    let RemoveLineAction {
        line_id: _
    } = action;
}

public fun destroy_set_line_immutable(action: SetLineImmutableAction) {
    let SetLineImmutableAction {
        line_id: _
    } = action;
}

public fun destroy_set_insert_allowed(action: SetInsertAllowedAction) {
    let SetInsertAllowedAction {
        allowed: _
    } = action;
}

public fun destroy_set_remove_allowed(action: SetRemoveAllowedAction) {
    let SetRemoveAllowedAction {
        allowed: _
    } = action;
}

public fun destroy_set_global_immutable(action: SetGlobalImmutableAction) {
    let SetGlobalImmutableAction {} = action;
}

public fun destroy_batch_operating_agreement(action: BatchOperatingAgreementAction) {
    let BatchOperatingAgreementAction {
        batch_id: _,
        actions: _
    } = action;
}

public fun destroy_operating_agreement_action(action: OperatingAgreementAction) {
    let OperatingAgreementAction {
        action_type: _,
        line_id: _,
        text: _,
        difficulty: _
    } = action;
}

// === New Functions (Serialize-Then-Destroy Pattern) ===

public fun new_create_operating_agreement<Outcome, IW: drop>(
    intent: &mut Intent<Outcome>,
    allow_insert: bool,
    allow_remove: bool,
    intent_witness: IW,
) {
    let action = CreateOperatingAgreementAction { allow_insert, allow_remove };
    let action_data = bcs::to_bytes(&action);
    protocol_intents::add_typed_action(
        intent,
        action_types::create_operating_agreement(),
        action_data,
        intent_witness
    );
    destroy_create_operating_agreement(action);
}

public fun new_update_line<Outcome, IW: drop>(
    intent: &mut Intent<Outcome>,
    line_id: ID,
    new_text: String,
    intent_witness: IW,
) {
    let action = UpdateLineAction { line_id, new_text };
    let action_data = bcs::to_bytes(&action);
    protocol_intents::add_typed_action(
        intent,
        action_types::update_line(),
        action_data,
        intent_witness
    );
    destroy_update_line(action);
}

public fun new_insert_line_after<Outcome, IW: drop>(
    intent: &mut Intent<Outcome>,
    prev_line_id: ID,
    text: String,
    difficulty: u64,
    intent_witness: IW,
) {
    let action = InsertLineAfterAction { prev_line_id, text, difficulty };
    let action_data = bcs::to_bytes(&action);
    protocol_intents::add_typed_action(
        intent,
        action_types::add_line(),
        action_data,
        intent_witness
    );
    destroy_insert_line_after(action);
}

public fun new_remove_line<Outcome, IW: drop>(
    intent: &mut Intent<Outcome>,
    line_id: ID,
    intent_witness: IW,
) {
    let action = RemoveLineAction { line_id };
    let action_data = bcs::to_bytes(&action);
    protocol_intents::add_typed_action(
        intent,
        action_types::remove_line(),
        action_data,
        intent_witness
    );
    destroy_remove_line(action);
}

public fun new_set_line_immutable<Outcome, IW: drop>(
    intent: &mut Intent<Outcome>,
    line_id: ID,
    intent_witness: IW,
) {
    let action = SetLineImmutableAction { line_id };
    let action_data = bcs::to_bytes(&action);
    protocol_intents::add_typed_action(
        intent,
        action_types::lock_operating_agreement(),
        action_data,
        intent_witness
    );
    destroy_set_line_immutable(action);
}

// === Delete Functions ===

public fun delete_create_operating_agreement(expired: &mut Expired) {
    let _spec = protocol_intents::remove_action_spec(expired);
}

public fun delete_update_line(expired: &mut Expired) {
    let _spec = protocol_intents::remove_action_spec(expired);
}

public fun delete_insert_line_after(expired: &mut Expired) {
    let _spec = protocol_intents::remove_action_spec(expired);
}

public fun delete_remove_line(expired: &mut Expired) {
    let _spec = protocol_intents::remove_action_spec(expired);
}

public fun delete_set_line_immutable(expired: &mut Expired) {
    let _spec = protocol_intents::remove_action_spec(expired);
}

EOF

echo "Done adding functions to operating_agreement_actions.move"