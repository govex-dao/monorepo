# V2 Large
- [ ] Get code building / fix circular dependancies
- [ ] Add correct cross package security capaility / requirements
- [ ] Get specs for https://github.com/MetaLex-Tech/RicardianTriplerDoubleTokenLeXscroW and add any missing things to this protocol
- [ ] Clean up dao configuration / bootstrapping / creation to redice bioler plate and be readable
- [ ] Fix current build errors 
(base) admin@Admins-iMac contracts % for pkg in */; do [ -f "$pkg/Move.toml" ] && (cd "$pkg" && output=$(sui move build --silence-warnings 2>&1 || true) && error_count=$(echo "$output" | grep -c -i "error") && echo "Errors in $pkg: $error_count"); done
Errors in futarchy_dao/: 530
Errors in futarchy_decoders/: 233
Errors in futarchy_lifecycle/: 236
Errors in futarchy_specialized_actions/: 448

 
# V2 economic incenitves etc
- [ ] commitment actions Cancel able and uncancel able flag
Mint options for employees (right to buy x amount at a given price!!!)
- [ ] remove founder rewards module from launchapd it should now be a preapproved intent spec??
- [ ] Make launchpad have small fee for creating dao non refundable 
- [ ] fix incentives around proposal mutation. if mutators outcomes wins, proposers must still get refunded if they only create two options. other wise incentive for mutators to just sligtly position themselves around the  proposal creators, settigs: (i.e changing a few words or characters in a memo proposal or chaning a number by a small amount and hedging by going either side of the origional) in order to steal the proposal creators fee. or for proposer to create proposals with n_max option to block anyone from mutating their proposal 
- [ ] List or address and how often they can create a proposal with no fee!!! Admin thingy
- [ ] DAO successful speedy proposal challenge, refund amount as futarchy config
- [X] verification request proposal type???
- [ ] check new account tech message about new locking implmentation

# V2 multisig
- [ ] How UI is aware of multisig / proposal intents
- [ ] make sure fees can be required to be collected in USDC? dont accept sui??? mybae need to be careful how new coins are added
- [ ] Multi sig inherit dao level configs like is paused
- [ ] Multisig must check that dead man switch is the daos futacrhy or another multisig with same dao id
- [ ] Can create futarchy first dao defaults to futarchy only policy or multisig first dao Or    Both.   Or either poliicy 
- [ ] seperate out just multsig???? as have leading multisig implementation???
- [ ] multisig Stale Proposal Invalidation: This is a critical security feature. If the multisig's rules change (e.g., a member is removed, or the threshold is lowered), this feature automatically invalidates all pending proposals created under the old rules. This prevents a malicious actor from pushing through an old, forgotten proposal that wouldn't be valid under the new consensus.
- [ ] fully seperate dao and account and futarchy configs
- [ ] Configure Time Lock: Set a mandatory delay (in seconds) between a proposal's approval and its execution.


# Clean up
  2. Stream/Payment Actions - Overlapping Cancel/Pause ⚠️

  - CancelPayment - Stop payment
  - CancelStream - Cancel stream
  - TogglePayment - Pause/resume payment
  - PauseStream - Pause stream temporarily
  - ResumeStream - Resume paused stream

  Why have both Cancel and Pause/Resume? And why separate actions for Payment vs Stream?

  3. Optimistic Actions - Too Many Variants ⚠️

  - Optimistic Proposals (Create, Challenge, Execute, Resolve)
  - Optimistic Intents (Create, Challenge, Execute, Cancel)
  - Council Optimistic Intents (Create, Execute, Cancel)

  Three different optimistic systems seems excessive.

  4. Protocol Admin Fee Actions - Too Granular ⚠️

  Multiple fee update actions that could be one configurable action:
  - UpdateDaoCreationFee
  - UpdateProposalFee
  - UpdateMonthlyDaoFee
  - UpdateVerificationFee
  - UpdateRecoveryFee
  - UpdateCoinMonthlyFee
  - UpdateCoinCreationFee
  - UpdateCoinProposalFee
  - UpdateCoinRecoveryFee

  Could be: UpdateProtocolFee(fee_type, amount)

  5. Verification Actions - Could Be Simplified ⚠️

  - RequestVerification
  - ApproveVerification
  - RejectVerification

  Could be: ProcessVerification(approve: bool)

  6. Memo Actions - EmitMemo vs EmitDecision ⚠️

  - EmitMemo - Post text message on-chain
  - EmitDecision - Record governance decision

  A decision is just a specific type of memo. Could use EmitMemo(type, content).

  7. Dissolution Actions - Some Overlap ⚠️

  - BatchDistribute - Distribute multiple assets
  - DistributeAssets - Send assets to holders

  These sound very similar.

  Most Redundant Actions:

  1. SetPoolStatus vs SetPoolEnabled - Definitely redundant
  2. Payment vs Stream actions - Should be unified
  3. Protocol fee updates - Should be one parameterized action
  4. EmitMemo vs EmitDecision - Decision is just a memo type

  Recommendations (without removing code):
  2. UNIFY: Payment and Stream actions (they're both payment flows)
  3. PARAMETERIZE: All protocol fee updates into UpdateProtocolFee(type, amount)
  4. SIMPLIFY: Verification into ProcessVerification(approve/reject)
  5. MERGE: EmitDecision into EmitMemo with a type field


# Macros to use?

2. Action Execution and Deserialization (Strong Candidate)
Safely deserializing an action from an Executable also follows a highly repetitive pattern.
The Pattern:
code
Move
// From account_protocol::owned::do_withdraw
// 1. Get the action specs
let specs = executable.intent().action_specs();
let spec = specs.borrow(executable.action_idx());

// 2. CRITICAL: Assert the action type
action_validation::assert_action_type<framework_action_types::OwnedWithdraw>(spec);

// 3. Get the raw data
let action_data = intents::action_spec_data(spec);

// 4. Create a BCS reader and deserialize
let mut reader = bcs::new(*action_data);
let object_id = object::id_from_bytes(bcs::peel_vec_u8(&mut reader));

// 5. CRITICAL: Validate all bytes consumed
bcs_validation::validate_all_bytes_consumed(reader);

// ... (rest of the function logic) ...

// 6. Increment action index
executable::increment_action_idx(executable);
The Problem:
This is a lot of security-critical boilerplate that must be done correctly every time. It's easy to forget validate_all_bytes_consumed or the assert_action_type check.
The Macro Solution:
A macro could handle the entire validation and deserialization process.
code
Move
// In a new macro utility module
public macro fun take_action<$Outcome: store, $Action: store>(
    $executable: &mut Executable<$Outcome>,
    $action_type_marker: drop // Pass the type marker struct as an argument
): $Action {
    let specs = $executable.intent().action_specs();
    let spec = specs.borrow($executable.action_idx());

    // Macro automatically handles type assertion
    account_protocol::action_validation::assert_action_type<$action_type_marker>(spec);

    let action_data = account_protocol::intents::action_spec_data(spec);
    let mut reader = sui::bcs::new(*action_data);
    
    // The macro returns the deserialized action struct
    let action: $Action = sui::bcs::peel(&mut reader);

    // Macro automatically handles validation
    account_protocol::bcs_validation::validate_all_bytes_consumed(reader);
    
    // Macro automatically increments the index
    account_protocol::executable::increment_action_idx($executable);

    action
}
Usage Example (Before vs. After):
Before: (as above, 6+ lines)
After:
code
Move
// In account_protocol::owned::do_withdraw
let WithdrawAction { object_id } = utils::take_action!(
    executable,
    framework_action_types::owned_withdraw()
);

// now use object_id in the rest of the function...
Benefits:
Drastically Reduces Boilerplate: Condenses ~7 lines of critical checks into one.
Enhances Security: Ensures that type validation, full byte consumption, and index incrementing are never forgotten.
Improves Focus: Allows the developer to focus on the business logic of the action, not the deserialization ceremony.
3. Decoder Registration (Good Candidate)
The registration of decoders is identical for every single one.
The Pattern:
code
Move
// From account_actions::vault_decoder
fun register_spend_decoder(registry: &mut ActionDecoderRegistry, ctx: &mut TxContext) {
    let decoder = SpendActionDecoder { id: object::new(ctx) };
    let type_key = type_name::with_defining_ids<SpendAction<CoinPlaceholder>>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}
The Macro Solution:
code
Move
// In a new macro utility module
public macro fun register_decoder(
    $registry: &mut ActionDecoderRegistry,
    $ctx: &mut TxContext,
    $DecoderStruct: has key + store,
    $ActionStruct: drop + store,
) {
    let decoder = $DecoderStruct { id: sui::object::new($ctx) };
    let type_key = std::type_name::with_defining_ids<$ActionStruct>();
    sui::dynamic_object_field::add(
        account_protocol::schema::registry_id_mut($registry),
        type_key,
        decoder
    );
}
Note: A placeholder type like CoinPlaceholder would need to be handled, possibly by passing the full generic type to the macro.
Usage Example (Before vs. After):
Before: 3 lines inside a dedicated function.
After:
code
Move
// In account_actions::vault_decoder::register_decoders
utils::register_decoder!(registry, ctx, SpendActionDecoder, SpendAction<CoinPlaceholder>);
utils::register_decoder!(registry, ctx, DepositActionDecoder, DepositAction<CoinPlaceholder>);
Benefits:
Reduces Code Duplication: Eliminates the need for a separate registration function for every single decoder.
Simplifies Maintenance: Adding a new decoder becomes a single, clear macro call.
Conclusion
The codebase is already of very high quality, and its existing use of macros is thoughtful. However, adopting macros for the three patterns above would elevate it further by:
Reducing Boilerplate: Making the code more concise and focused on its core logic.
Enforcing Security Patterns: Automatically including critical checks (assert_action_type, validate_all_bytes_consumed, destroy_*_action) in every use, reducing the chance of human error.
Improving Consistency: Ensuring that actions are created, executed, and registered in a uniform way across the entire project.



# Consider for v2
- [ ] Put those blockworks 50 Q Answers in there 
- [ ] Trade back weird octothorpe stuff in headersMobile no footer on trader and create
for V2
- [ ] Create dao with instant approved intents
- [ ] option to pass moveframework account to DAO
- [ ] Create dao in launch pad
- [ ] Look at what oracle type existing sui amms use and what time period etc
- [ ] We able to tive individual stream admins But also allow dao to be admin always Oh yeah thats my standard policy reg thing
And make them answer a bunch of q!!!!!!!!!!!!!
- [ ] Explicit Rejection State: In your model, a proposal that doesn't meet the threshold simply never becomes executable. In Squads, if a "cutoff" number of members vote to reject, the proposal enters a terminal Rejected state. This provides more explicit finality.
(Well deleted is ok too maybe???)

- [ ] Multisig fee / Fee to create multig / agree not to use for a prediction market or futarchy protocol without first getting prior agreement.
- [ ] Get summary of each file and make sure AIs stop getting tripped up
- [ ] Compare to other large quality move packages
like walrus deep book and leading lending protocols etc
main ones on defi lama that are new! Deepbook, walrus, jose, account tech, big ones on defillama

# Consider for V3
- [ ] Should operating agreements or another object e.g registry be able to make policy rules regarding actions types e.g. preventing them or setting what authority they need
- [ ] Draft State: Squads allows proposals to be created as a Draft. This is crucial for complex batches, allowing the proposer to add, remove, and review transactions before officially opening the proposal to a vote. Your Intent is effectively "active" as soon as it's created.
- [ ] Employee as onchain resource???
- [X] Sort out twap i itializatkon prices and handle spot oracle given 24 7 proposals if no spot trading dueot back to back proposals
- [ ] multiverse finance Token splitting? https://www.paradigm.xyz/2025/05/multiverse-finance
- [X] Amm routing abstraction Redeeming condition toke redeem type dispatcher for burn or redeem winning
- [ ] Also maybe shard all daos based on number e.g give certain dao number label to admins
- [ ]  Way to generate dao onchain spending data?
- [ ]  Make whole code not rely so much on off chain indexing, like keep last n proposals discoverable from dao and every other object properly discoverable
- [ ] Procurement proposal type
- [ ] The Automated Cash Flow Statement (The "Must-Have")- [ ] Change opperating agreement to make line by line require multiple coex or and OR et 
Income Statement
What it answers: Are we profitable?
Simple Idea: Incomes - Expenses = Profit
Balance Sheet
What it answers: What do we own and owe?
Simple Idea: Resources = What You Owe (Liabilities + Equity)
Statement of Cash Flows
What it answers: Where did our cash go?
Simple Idea: Cash In - Cash Out = Change in Cash
- [ ] dao level resources list with catagory that can be added to and altered. Liabilities & Equity and assets and employees. Maybe tie to spending code in transfers or steams.
I already have a way to make streams require spending codes
I think about a resources object is good
like current employees of offices etc and code bases
also being able to autogenerate dao expenses and liabilitirs is clean
could have security council with right to remove things from resurces list??
like if brought 5k film equipment and it broke or whatever

```
What about employee numbers?
The number of employees is not a financial figure and does not appear on any of the three core statements. It is considered non-financial data. You would typically find this information in the company's Annual Report, often in the introductory sections or in the "Management's Discussion & Analysis" (MD&A).

Balance Sheet: This is its primary home. It's listed as an Asset, often under a category called "Property, Plant, and Equipment" (PP&E). It represents a store of value.

Statement of Stockholders' Equity: Explains the changes in the owners' portion of the company during the year (e.g., from profits, paying out dividends, or issuing new stock).
```