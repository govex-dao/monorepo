// ============================================================================
// FORK MODIFICATION NOTICE - Type-Based Kiosk Management
// ============================================================================
// This module manages NFT operations in Kiosks for Account.
//
// CHANGES IN THIS FORK:
// - Actions use type markers: KioskTake, KioskList
// - Added 'drop' ability to TakeAction and ListAction structs
// - Integrated BCS validation for action deserialization
// - Actions use typed Intent system with add_typed_action()
// - Enhanced imports for better modularity (bcs::Self, executable::Self)
// - Type-safe action validation through ActionSpec comparison
// - Compile-time type safety replaces string-based descriptors
// ============================================================================
/// Authenticated users can place nfts from their kiosk into the account's without passing through the intent process.
/// Nfts can be transferred into any other Kiosk. Upon resolution, the recipient must execute the transfer.
/// The functions take the caller's kiosk and the account's kiosk to execute.
/// Nfts can be listed for sale in the kiosk, and then purchased by anyone.
/// Authorized addresses can withdraw the profits from the kiosk to the Account.

module account_actions::kiosk;

// === Imports ===

use std::string::String;
use sui::{
    coin,
    sui::SUI,
    kiosk::{Self, Kiosk, KioskOwnerCap},
    transfer_policy::{TransferPolicy, TransferRequest},
    bcs::{Self, BCS},
};
use kiosk::{kiosk_lock_rule, royalty_rule, personal_kiosk_rule};
use account_protocol::{
    account::{Account, Auth},
    intents::{Self, Expired, Intent},
    executable::{Self, Executable},
    version_witness::VersionWitness,
};
use account_actions::version;
use account_extensions::framework_action_types::{Self, KioskTake, KioskList};

// === Use Fun Aliases ===
use fun account_protocol::intents::add_typed_action as Intent.add_typed_action;

// === Errors ===

const EWrongReceiver: u64 = 0;

// === Structs ===    

/// Dynamic Object Field key for the KioskOwnerCap
public struct KioskOwnerKey(String) has copy, drop, store;

/// Action transferring nfts from the account's kiosk to another one
public struct TakeAction has store, drop {
    // name of the Kiosk
    name: String,
    // id of the nfts to transfer
    nft_id: ID,
    // owner of the receiver kiosk
    recipient: address,
}
/// Action listing nfts for purchase
public struct ListAction has store, drop {
    // name of the Kiosk
    name: String,
    // id of the nft to list
    nft_id: ID,
    // listing price of the nft
    price: u64
}

// === Public functions ===

/// Creates a new Kiosk and locks the KioskOwnerCap in the Account
#[allow(lint(share_owned))]
public fun open<Config>(
    auth: Auth,
    account: &mut Account<Config>, 
    name: String, 
    ctx: &mut TxContext
) {
    account.verify(auth);

    let (mut kiosk, kiosk_owner_cap) = kiosk::new(ctx);
    kiosk.set_owner_custom(&kiosk_owner_cap, account.addr());

    account.add_managed_asset(KioskOwnerKey(name), kiosk_owner_cap, version::current());
    transfer::public_share_object(kiosk);
}

/// Checks if a Kiosk exists for a given name.
public fun has_lock<Config>(
    account: &Account<Config>,
    name: String
): bool {
    account.has_managed_asset(KioskOwnerKey(name))
}

/// Deposits from another Kiosk, no need for intent.
/// Optional royalty, lock and personal kiosk rules are automatically resolved for the type.
/// Additional rules may be confirmed after in the PTB.
public fun place<Config, Nft: key + store>(
    auth: Auth,
    account: &mut Account<Config>, 
    account_kiosk: &mut Kiosk, 
    sender_kiosk: &mut Kiosk, 
    sender_cap: &KioskOwnerCap, 
    policy: &mut TransferPolicy<Nft>,
    name: String,
    nft_id: ID,
    ctx: &mut TxContext
): TransferRequest<Nft> {
    account.verify(auth);

    let cap: &KioskOwnerCap = account.borrow_managed_asset(KioskOwnerKey(name), version::current());

    sender_kiosk.list<Nft>(sender_cap, nft_id, 0);
    let (nft, mut request) = sender_kiosk.purchase<Nft>(nft_id, coin::zero<SUI>(ctx));

    if (policy.has_rule<Nft, kiosk_lock_rule::Rule>()) {
        account_kiosk.lock(cap, policy, nft);
        kiosk_lock_rule::prove(&mut request, account_kiosk);
    } else {
        account_kiosk.place(cap, nft);
    };

    if (policy.has_rule<Nft, royalty_rule::Rule>()) {
        // can't read royalty rule on-chain because transfer_policy::get_rule not implemented
        // so we can't throw an error if there is a minimum floor price set
        royalty_rule::pay(policy, &mut request, coin::zero<SUI>(ctx));
    }; 

    if (policy.has_rule<Nft, personal_kiosk_rule::Rule>()) {
        personal_kiosk_rule::prove(account_kiosk, &mut request);
    };
    // the request can be filled with arbitrary rules and must be confirmed afterwards
    request
}

/// Authenticated users can delist nfts
public fun delist<Config, Nft: key + store>(
    auth: Auth,
    account: &mut Account<Config>, 
    kiosk: &mut Kiosk, 
    name: String,
    nft_id: ID,
) {
    account.verify(auth);

    let cap: &KioskOwnerCap = account.borrow_managed_asset(KioskOwnerKey(name), version::current());
    kiosk.delist<Nft>(cap, nft_id);
}

/// Authenticated users can withdraw the profits to the account
public fun withdraw_profits<Config>(
    auth: Auth,
    account: &mut Account<Config>,
    kiosk: &mut Kiosk,
    name: String,
    ctx: &mut TxContext
) {
    account.verify(auth);

    let cap: &KioskOwnerCap = account.borrow_managed_asset(KioskOwnerKey(name), version::current());

    let profits_mut = kiosk.profits_mut(cap);
    let profits_value = profits_mut.value();
    let profits = profits_mut.split(profits_value);

    account.keep(coin::from_balance<SUI>(profits, ctx), ctx);
}

/// Closes the kiosk if empty
public fun close<Config>(
    auth: Auth,
    account: &mut Account<Config>,
    name: String,
    kiosk: Kiosk,
    ctx: &mut TxContext
) {
    account.verify(auth);

    let cap: KioskOwnerCap = account.remove_managed_asset(KioskOwnerKey(name), version::current());
    let profits = kiosk.close_and_withdraw(cap, ctx);
    
    account.keep(profits, ctx);
}

// Intent functions

/// Creates a new TakeAction and adds it to an intent.
public fun new_take<Outcome, IW: drop>(
    intent: &mut Intent<Outcome>,
    name: String,
    nft_id: ID,
    recipient: address,
    intent_witness: IW,
) {
    intent.add_typed_action(
        TakeAction { name, nft_id, recipient },
        framework_action_types::kiosk_take(),
        intent_witness
    );
}

/// Processes a TakeAction, resolves the rules and places the nft into the recipient's kiosk.
public fun do_take<Config, Outcome: store, Nft: key + store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<Config>,
    account_kiosk: &mut Kiosk,
    recipient_kiosk: &mut Kiosk,
    recipient_cap: &KioskOwnerCap,
    policy: &mut TransferPolicy<Nft>,
    version_witness: VersionWitness,
    _intent_witness: IW,
    ctx: &mut TxContext
): TransferRequest<Nft> {
    executable.intent().assert_is_account(account.addr());

    // Get BCS bytes from ActionSpec
    let specs = executable.intent().action_specs();
    let spec = specs.borrow(executable.action_idx());
    let action_data = intents::action_spec_data(spec);

    // Create BCS reader and deserialize
    let mut reader = bcs::new(*action_data);
    let name = bcs::peel_vec_u8(&mut reader).to_string();
    let nft_id = bcs::peel_address(&mut reader).to_id();
    let recipient = bcs::peel_address(&mut reader);

    assert!(recipient == ctx.sender(), EWrongReceiver);

    let cap: &KioskOwnerCap = account.borrow_managed_asset(KioskOwnerKey(name), version_witness);

    account_kiosk.list<Nft>(cap, nft_id, 0);
    let (nft, mut request) = account_kiosk.purchase<Nft>(nft_id, coin::zero<SUI>(ctx));

    if (policy.has_rule<Nft, kiosk_lock_rule::Rule>()) {
        recipient_kiosk.lock(recipient_cap, policy, nft);
        kiosk_lock_rule::prove(&mut request, recipient_kiosk);
    } else {
        recipient_kiosk.place(recipient_cap, nft);
    };

    if (policy.has_rule<Nft, royalty_rule::Rule>()) {
        royalty_rule::pay(policy, &mut request, coin::zero<SUI>(ctx));
    };

    if (policy.has_rule<Nft, personal_kiosk_rule::Rule>()) {
        personal_kiosk_rule::prove(account_kiosk, &mut request);
    };

    // Increment action index
    executable::increment_action_idx(executable);

    // the request can be filled with arbitrary rules and must be confirmed afterwards
    request
}

/// Deletes a TakeAction from an expired intent.
public fun delete_take(expired: &mut Expired) {
    let _spec = intents::remove_action_spec(expired);
    // ActionSpec has drop, automatically cleaned up
}

/// Creates a new ListAction and adds it to an intent.
public fun new_list<Outcome, IW: drop>(
    intent: &mut Intent<Outcome>,
    name: String,
    nft_id: ID,
    price: u64,
    intent_witness: IW,
) {
    intent.add_typed_action(
        ListAction { name, nft_id, price },
        framework_action_types::kiosk_list(),
        intent_witness
    );
}

/// Processes a ListAction and lists the nft for purchase.
public fun do_list<Config, Outcome: store, Nft: key + store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<Config>,
    kiosk: &mut Kiosk,
    version_witness: VersionWitness,
    _intent_witness: IW,
) {
    executable.intent().assert_is_account(account.addr());

    // Get BCS bytes from ActionSpec
    let specs = executable.intent().action_specs();
    let spec = specs.borrow(executable.action_idx());
    let action_data = intents::action_spec_data(spec);

    // Create BCS reader and deserialize
    let mut reader = bcs::new(*action_data);
    let name = bcs::peel_vec_u8(&mut reader).to_string();
    let nft_id = bcs::peel_address(&mut reader).to_id();
    let price = bcs::peel_u64(&mut reader);

    let cap: &KioskOwnerCap = account.borrow_managed_asset(KioskOwnerKey(name), version_witness);

    kiosk.list<Nft>(cap, nft_id, price);

    // Increment action index
    executable::increment_action_idx(executable);
}

/// Deletes a ListAction from an expired intent.
public fun delete_list(expired: &mut Expired) {
    let _spec = intents::remove_action_spec(expired);
    // ActionSpec has drop, automatically cleaned up
}
