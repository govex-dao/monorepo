/// Memo intents for the account protocol
/// Provides the intent witness for memo actions
module futarchy::memo_intents;

use std::string::String;
use sui::tx_context::TxContext;
use account_protocol::{
    account::Account,
    intents,
};
use futarchy::{
    futarchy_config::FutarchyConfig,
    memo_actions::{EmitMemoAction, EmitStructuredMemoAction, EmitCommitmentAction, EmitSignalAction},
};

/// Intent witness for memo actions
public struct MemoIntent has copy, drop {}