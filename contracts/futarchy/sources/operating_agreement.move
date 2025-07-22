module futarchy::operating_agreement;

use std::string::String;
use sui::table::{Self, Table};

// === Errors ===
const ELineNotFound: u64 = 0;
const EIncorrectLengths: u64 = 1;

// === Structs ===

/// Represents one line of the operating agreement with its associated change difficulty.
public struct AgreementLine has store, key {
    id: UID,
    text: String,
    /// The basis points gap the 'accept' outcome's price must have over the 'reject'
    /// outcome's price for a change to this line to be approved.
    /// E.g., a difficulty of 50000 means the accept price must be >1.5x the reject price.
    difficulty: u64,
}

/// The main object storing the DAO's operating agreement.
public struct OperatingAgreement has key, store {
    id: UID,
    dao_id: ID,
    /// Maps a unique line ID to the AgreementLine object.
    lines: Table<ID, AgreementLine>,
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
        lines: table::new(ctx),
    };

    let mut i = 0;
    while (i < initial_lines.length()) {
        let text = *initial_lines.borrow(i);
        let difficulty = *initial_difficulties.borrow(i);
        let line = AgreementLine {
            id: object::new(ctx),
            text,
            difficulty,
        };
        agreement.lines.add(object::id(&line), line);
        i = i + 1;
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
    assert!(agreement.lines.contains(line_id), ELineNotFound);
    let line = agreement.lines.borrow_mut(line_id);
    line.text = new_text;
}

// === View Functions ===

/// Retrieves the difficulty for a specific line.
public fun get_difficulty(agreement: &OperatingAgreement, line_id: ID): u64 {
    assert!(agreement.lines.contains(line_id), ELineNotFound);
    agreement.lines.borrow(line_id).difficulty
}

/// Retrieves the text for a specific line.
public fun get_line_text(agreement: &OperatingAgreement, line_id: ID): String {
    assert!(agreement.lines.contains(line_id), ELineNotFound);
    agreement.lines.borrow(line_id).text
}

/// Retrieves the DAO ID associated with this agreement.
public fun get_dao_id(agreement: &OperatingAgreement): ID {
    agreement.dao_id
}