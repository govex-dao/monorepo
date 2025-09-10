module account_actions::vault_intents;

// === Imports ===

use std::string::String;
use account_protocol::{
    account::{Account, Auth},
    executable::Executable,
    intents::Params,
    intent_interface,
};
use account_actions::{
    transfer as acc_transfer,
    vault,
    version,
};

// === Aliases ===

use fun intent_interface::build_intent as Account.build_intent;
use fun intent_interface::process_intent as Account.process_intent;

// === Errors ===

const ENotSameLength: u64 = 0;
const EInsufficientFunds: u64 = 1;
const ECoinTypeDoesntExist: u64 = 2;

// === Structs ===

/// Intent Witness defining the vault spend and transfer intent, and associated role.
public struct SpendAndTransferIntent() has copy, drop;

// === Public Functions ===

/// Creates a SpendAndTransferIntent and adds it to an Account.
public fun request_spend_and_transfer<Config, Outcome: store, CoinType: drop>(
    auth: Auth,
    account: &mut Account<Config>, 
    params: Params,
    outcome: Outcome,
    vault_name: String,
    amounts: vector<u64>,
    recipients: vector<address>,
    ctx: &mut TxContext
) {
    account.verify(auth);
    assert!(amounts.length() == recipients.length(), ENotSameLength);
    
    let vault = vault::borrow_vault(account, vault_name);
    assert!(vault.coin_type_exists<CoinType>(), ECoinTypeDoesntExist);
    assert!(
        amounts.fold!(0u64, |sum, amount| sum + amount) <= vault.coin_type_value<CoinType>(), 
        EInsufficientFunds
    );
    
    account.build_intent!(
        params,
        outcome,
        vault_name,
        version::current(),
        SpendAndTransferIntent(),
        ctx,
        |intent, iw| amounts.zip_do!(recipients, |amount, recipient| {
            vault::new_spend<_, CoinType, _>(intent, vault_name, amount, iw);
            acc_transfer::new_transfer(intent, recipient, iw);
        })
    );
}

/// Executes a SpendAndTransferIntent, transfers coins from the vault to the recipients. Can be looped over.
public fun execute_spend_and_transfer<Config, Outcome: store, CoinType: drop>(
    executable: &mut Executable<Outcome>, 
    account: &mut Account<Config>, 
    ctx: &mut TxContext
) {
    account.process_intent!(
        executable,
        version::current(),
        SpendAndTransferIntent(),
        |executable, iw| {
            let coin = vault::do_spend<_, _, CoinType, _>(executable, account, version::current(), iw, ctx);
            acc_transfer::do_transfer(executable, coin, iw);
        }
    );
}

