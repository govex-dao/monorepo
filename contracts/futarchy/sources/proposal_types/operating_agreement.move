module futarchy::operating_agreement;

use std::string::String;
use sui::clock::{Self, Clock};
use sui::event;
use sui::dynamic_field as df;

// === Type Key for Dynamic Fields ===
/// Typed wrapper for line IDs to prevent key collisions
public struct LineKey has copy, drop, store {
    id: ID,
}

// === Errors ===
const ELineNotFound: u64 = 0;
const EIncorrectLengths: u64 = 1;
const ETooManyLines: u64 = 2;

// === Constants ===
const MAX_LINES_PER_AGREEMENT: u64 = 1000; // Maximum number of lines to prevent excessive gas consumption
const MAX_TRAVERSAL_LIMIT: u64 = 1000; // Maximum iterations when traversing linked list

// === Structs ===

/// Represents one line of the operating agreement with its associated change difficulty.
public struct AgreementLine has store, drop {
    text: String,
    /// The basis points gap the 'accept' outcome's price must have over the 'reject'
    /// outcome's price for a change to this line to be approved.
    /// E.g., a difficulty of 50000 means the accept price must be >1.5x the reject price.
    difficulty: u64,
    // Pointers for the doubly linked list to maintain order.
    prev: Option<ID>,
    next: Option<ID>,
}

/// The main object storing the DAO's operating agreement.
public struct OperatingAgreement has key, store {
    id: UID,
    dao_id: ID,
    // Pointers to the start and end of the linked list of lines.
    head: Option<ID>,
    tail: Option<ID>,
}

// === Events ===

/// Emitted when the full content of the operating agreement is read or changed.
public struct AgreementRead has copy, drop {
    dao_id: ID,
    line_ids: vector<ID>,
    texts: vector<String>,
    difficulties: vector<u64>,
    timestamp_ms: u64,
}


// === Public Functions ===

/// Initializes a new OperatingAgreement object for a DAO.
/// This should be called once per DAO.
public(package) fun new(
    dao_id: ID,
    initial_lines: vector<String>,
    initial_difficulties: vector<u64>,
    ctx: &mut TxContext
): OperatingAgreement {
    assert!(initial_lines.length() == initial_difficulties.length(), EIncorrectLengths);

    let mut agreement = OperatingAgreement {
        id: object::new(ctx),
        dao_id,
        head: option::none(),
        tail: option::none(),
    };

    let mut i = 0;
    let mut prev_id: Option<ID> = option::none();
    
    // Validate initial lines don't exceed maximum
    assert!(initial_lines.length() <= MAX_LINES_PER_AGREEMENT, ETooManyLines);
    
    while (i < initial_lines.length()) {
        let text = *initial_lines.borrow(i);
        let difficulty = *initial_difficulties.borrow(i);
        let line_id = object::new(ctx);
        let line_id_inner = object::uid_to_inner(&line_id);
        
        let line = AgreementLine {
            text,
            difficulty,
            prev: prev_id,
            next: option::none(),
        };
        
        // Store line as dynamic field with typed key to avoid collisions
        df::add(&mut agreement.id, LineKey { id: line_id_inner }, line);
        
        // Update the previous line's next pointer
        if (prev_id.is_some()) {
            let prev_line = df::borrow_mut<LineKey, AgreementLine>(&mut agreement.id, LineKey { id: *prev_id.borrow() });
            prev_line.next = option::some(line_id_inner);
        } else {
            // This is the first line
            agreement.head = option::some(line_id_inner);
        };
        
        prev_id = option::some(line_id_inner);
        object::delete(line_id);
        i = i + 1;
    };
    
    // Set tail to the last line
    if (prev_id.is_some()) {
        agreement.tail = prev_id;
    };

    agreement
}

/// Updates the text of a specific line in the agreement.
/// This is package-private and should only be called by the authorized execution logic.
public(package) fun update_line(
    agreement: &mut OperatingAgreement,
    line_id: ID,
    new_text: String
) {
    assert!(df::exists_<LineKey>(&agreement.id, LineKey { id: line_id }), ELineNotFound);
    let line: &mut AgreementLine = df::borrow_mut(&mut agreement.id, LineKey { id: line_id });
    line.text = new_text;
}

/// Inserts a new line *after* a specified existing line.
/// This is package-private and should only be called by the authorized execution logic.
public(package) fun insert_line_after(
    agreement: &mut OperatingAgreement,
    prev_line_id: ID, // The ID of the line to insert after.
    new_text: String,
    new_difficulty: u64,
    ctx: &mut TxContext,
): ID {
    assert!(df::exists_<LineKey>(&agreement.id, LineKey { id: prev_line_id }), ELineNotFound);
    
    // Check we haven't exceeded maximum lines
    let current_line_count = get_all_line_ids_ordered(agreement).length();
    assert!(current_line_count < MAX_LINES_PER_AGREEMENT, ETooManyLines);

    // 1. Create the new line object.
    let line_uid = object::new(ctx);
    let new_line_id = object::uid_to_inner(&line_uid);
    
    // Get the next pointer from the previous line before modifying
    let prev_line_next;
    {
        let prev_line: &AgreementLine = df::borrow(&agreement.id, LineKey { id: prev_line_id });
        prev_line_next = prev_line.next;
    };
    
    let new_line = AgreementLine {
        text: new_text,
        difficulty: new_difficulty,
        prev: option::some(prev_line_id),
        next: prev_line_next, // It points to whatever the previous line was pointing to.
    };

    // 2. Update the `next` line's `prev` pointer, if it exists.
    if (prev_line_next.is_some()) {
        let next_line_id = *prev_line_next.borrow();
        let next_line: &mut AgreementLine = df::borrow_mut(&mut agreement.id, LineKey { id: next_line_id });
        next_line.prev = option::some(new_line_id);
    };

    // 3. Update the `prev` line's `next` pointer.
    let prev_line: &mut AgreementLine = df::borrow_mut(&mut agreement.id, LineKey { id: prev_line_id });
    prev_line.next = option::some(new_line_id);

    // 4. If we inserted after the tail, the new line is the new tail.
    if (agreement.tail.is_some() && *agreement.tail.borrow() == prev_line_id) {
        agreement.tail = option::some(new_line_id);
    };

    // 5. Add the new line as a dynamic field to the agreement object.
    df::add(&mut agreement.id, LineKey { id: new_line_id }, new_line);
    object::delete(line_uid);
    
    new_line_id
}

/// Inserts a new line at the beginning of the agreement.
/// This is package-private and should only be called by the authorized execution logic.
public(package) fun insert_line_at_beginning(
    agreement: &mut OperatingAgreement,
    new_text: String,
    new_difficulty: u64,
    ctx: &mut TxContext,
): ID {
    // Check we haven't exceeded maximum lines
    let current_line_count = get_all_line_ids_ordered(agreement).length();
    assert!(current_line_count < MAX_LINES_PER_AGREEMENT, ETooManyLines);
    let line_uid = object::new(ctx);
    let new_line_id = object::uid_to_inner(&line_uid);
    
    let new_line = AgreementLine {
        text: new_text,
        difficulty: new_difficulty,
        prev: option::none(),
        next: agreement.head,
    };

    // Update the current head's prev pointer if it exists
    if (agreement.head.is_some()) {
        let current_head_id = *agreement.head.borrow();
        let current_head: &mut AgreementLine = df::borrow_mut(&mut agreement.id, LineKey { id: current_head_id });
        current_head.prev = option::some(new_line_id);
    } else {
        // This is the first line, so it's also the tail
        agreement.tail = option::some(new_line_id);
    };

    // Update head to point to the new line
    agreement.head = option::some(new_line_id);

    // Add the new line as a dynamic field to the agreement object
    df::add(&mut agreement.id, LineKey { id: new_line_id }, new_line);
    object::delete(line_uid);
    
    new_line_id
}

/// Removes a line from the agreement.
/// This is package-private and should only be called by the authorized execution logic.
public(package) fun remove_line(
    agreement: &mut OperatingAgreement,
    line_id: ID,
) {
    assert!(df::exists_<LineKey>(&agreement.id, LineKey { id: line_id }), ELineNotFound);
    let line_to_remove: AgreementLine = df::remove(&mut agreement.id, LineKey { id: line_id });

    // 1. Update the `next` pointer of the previous line.
    if (line_to_remove.prev.is_some()) {
        let prev_id = *line_to_remove.prev.borrow();
        let prev_line: &mut AgreementLine = df::borrow_mut(&mut agreement.id, LineKey { id: prev_id });
        prev_line.next = line_to_remove.next;
    } else {
        // This was the head, so the next line becomes the new head.
        agreement.head = line_to_remove.next;
    };

    // 2. Update the `prev` pointer of the next line.
    if (line_to_remove.next.is_some()) {
        let next_id = *line_to_remove.next.borrow();
        let next_line: &mut AgreementLine = df::borrow_mut(&mut agreement.id, LineKey { id: next_id });
        next_line.prev = line_to_remove.prev;
    } else {
        // This was the tail, so the previous line becomes the new tail.
        agreement.tail = line_to_remove.prev;
    };

    // 3. Destroy the removed line object.
    let AgreementLine { text: _, difficulty: _, prev: _, next: _ } = line_to_remove;
}

// === View Functions ===

/// Retrieves the difficulty for a specific line.
public fun get_difficulty(agreement: &OperatingAgreement, line_id: ID): u64 {
    assert!(df::exists_<LineKey>(&agreement.id, LineKey { id: line_id }), ELineNotFound);
    df::borrow<LineKey, AgreementLine>(&agreement.id, LineKey { id: line_id }).difficulty
}

/// Retrieves the text for a specific line.
public fun get_line_text(agreement: &OperatingAgreement, line_id: ID): String {
    assert!(df::exists_<LineKey>(&agreement.id, LineKey { id: line_id }), ELineNotFound);
    df::borrow<LineKey, AgreementLine>(&agreement.id, LineKey { id: line_id }).text
}

/// Retrieves the DAO ID associated with this agreement.
public fun get_dao_id(agreement: &OperatingAgreement): ID {
    agreement.dao_id
}

/// Retrieves all line IDs in their correct order by traversing the linked list.
public fun get_all_line_ids_ordered(agreement: &OperatingAgreement): vector<ID> {
    let mut lines = vector[];
    let mut current_id_opt = agreement.head;
    let mut iterations = 0;
    while (current_id_opt.is_some() && iterations < MAX_TRAVERSAL_LIMIT) {
        let current_id = *current_id_opt.borrow();
        lines.push_back(current_id);
        let current_line: &AgreementLine = df::borrow(&agreement.id, LineKey { id: current_id });
        current_id_opt = current_line.next;
        iterations = iterations + 1;
    };
    assert!(iterations < MAX_TRAVERSAL_LIMIT, ETooManyLines);
    lines
}

/// Public entry function to read and emit the entire operating agreement content on demand.
/// This allows off-chain services to easily synchronize with the current state.
public entry fun read_agreement(agreement: &OperatingAgreement, clock: &Clock) {
    emit_current_state_event(agreement, clock);
}

/// Emits an event with the full, current, ordered content of the agreement.
/// This is a package-private helper called after any successful state change or by the public read function.
public(package) fun emit_current_state_event(agreement: &OperatingAgreement, clock: &Clock) {
    let ordered_ids = get_all_line_ids_ordered(agreement);

    let mut texts = vector[];
    let mut difficulties = vector[];

    let mut i = 0;
    while (i < ordered_ids.length()) {
        let line_id = *ordered_ids.borrow(i);
        // Since we already asserted existence in the traversal, this is safe.
        let line: &AgreementLine = df::borrow(&agreement.id, LineKey { id: line_id });
        texts.push_back(line.text);
        difficulties.push_back(line.difficulty);
        i = i + 1;
    };

    event::emit(AgreementRead {
        dao_id: agreement.dao_id,
        line_ids: ordered_ids,
        texts,
        difficulties,
        timestamp_ms: clock::timestamp_ms(clock),
    });
}