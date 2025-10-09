# V2 Large
- [ ] Add correct cross package security capaility / requirements
- [ ] Get specs for https://github.com/MetaLex-Tech/RicardianTriplerDoubleTokenLeXscroW and add any missing things to this protocol
- [X] we were in the process of migrationd dao doc registyry and associated files to use ID for chunks instead of indexer. then when done ask chtp5 pro chat for any missing against old OA file
- [X] Change dao doc registry to dao file registry
- [X] Change mf new auto withdraw coin pattern to registry use cap owned by that file module and intent to add or removed coin type to approved list for withdraw by that cap
also befroe mergin get ai to review patern used in new changee to move framework and add to fork notes
- [X] make cardinality 1 dao to n operating agreements and give each of them a name
- [X] bascicaly changes you deleted in poperating agreement was\
- [X]named lines to chunks everywhere\
- [X]each chunk either had onchain sui string or walrus blob id (never both)\
- [X]changed dao to doc cardinality from 1 to 1 to 1 to n\
- [X]had like registr table of docs with name\
- [X]and new imuntability level at doc level\
- [X] Dao doc level change policy. as some are random some could be operating agreement 
- [X] for launchpad allow anyone ot crank raise to anyone else
- [X] wait i thought i had a minimum in my launchpad doule chekc that doesnt clash with max. like cant accept over X seperate participants etc
- [X] Action control policy level policy setting. Instead of policy set of global change any actions policy
- [X] Optional amm registry to leave conditional tokens in a registry with a small fee where they can be cranked to people later. Token has escrow. So either burn or withdraw : to owner
- [X] removing line difficulty thing from dao files
- [X] # time delay changes to policies
    should make time delay configurable per policy!
    futarchy being able to instantly change policy is dangerous
    allow for proposal to cancel policy change
- [X]  instead of my conditinoal tokens could have existing registry of empty coins and allow proposal 
creators to pay to take some from there and I can keep it stocked up so only takes one transaction
store coin meta data cap and trasury cap and assert no supply and name is short and entirely numerical and 
no metadata and then rename and go on my way??? 
- [X] look at mf changes from my fork


# V2 economic incenitves etc
 - [X] get doc fiels reg to proffesional standard
- [X] commitment actions Cancel able and uncancel able flag
Mint options for employees (right to buy x amount at a given price!!!)
- [x] remove founder rewards module from launchapd it should now be a preapproved intent spec??
- [X] Make launchpad have small fee 
- [X] fix incentives around proposal mutation. if mutators outcomes wins, proposers must still get refunded if they only create two options. other wise incentive for mutators to just sligtly position themselves around the  proposal creators, settigs: (i.e changing a few words or characters in a memo proposal or chaning a number by a small amount and hedging by going either side of the origional) in order to steal the proposal creators fee. or for proposer to create proposals with n_max option to block anyone from mutating their proposal.
- [X] List or address and how often they can create a proposal with no fee!!! Admin thingy
- [X] DAO successful speedy proposal challenge, refund amount as futarchy config
- [X] verification request proposal type???
- [X] make sure conditional token holder can set their liqudiity to with draw only and dont auto put it in the next proposal
- [X] Allow dao to ave seperate consitional amm fee and spot amm fee
- [X] Make protocol take 20% of prioirty quue fees

- [X] Add note to amm thing that proposal can only be cranked into starting if commit reveal actually passes!!!
- [X] Need way or time out to delete proposl affer short time e.g 24 hours if dao doesnt have enough funds for buy back say
So cant be added atomically created
- [X] Extract out commit reveal logic to own module
- [X] Dao config max percent amm reserves can be auto swapped per proposal default 10%
- [X] Make sure read current state skips chunk yet to sunrise in docs or that have sunsetted. And then have view all chunk for full????
- [X] Each launchpad raise should have an admin trust score int. And a text field. And cap to review it basically. So need new intents for that cap
- [X] Dividends, use mainly use to create a list. But figure out correct owner through conditional token. Create this action type will need sui and a data structure of all accounts and amount and amount and ability to batch crank. If censored send to object that only they can withdraw from they go get uncensored. I could be on their multisig and their security team and also require their futarchy approval!


# V2 multisig
- [X] compare to account tech multisig
- [X] How UI is aware of multisig / proposal intents
- [IP] make sure fees can be required to be collected in USDC? dont accept sui??? mybae need to be careful how new coins are added
- [X] Multi sig inherit dao level configs like is paused
- [X] Multisig must check that dead man switch is the daos futacrhy or another multisig with same dao id
- [ ] Can create futarchy first dao defaults to futarchy only policy or multisig first dao Or    Both.   Or either poliicy 
- [IP] multisig Stale Proposal Invalidation: This is a critical security feature. If the multisig's rules change (e.g., a member is removed, or the threshold is lowered), this feature automatically invalidates all pending proposals created under the old rules. This prevents a malicious actor from pushing through an old, forgotten proposal that wouldn't be valid under the new consensus.
- [X] fully seperate dao and account and futarchy configs
- [X] Configure Time Lock: Set a mandatory delay (in seconds) between a proposal's approval and its execution.
- [X] Your Account<WeightedMultisig> has the same capabilities as any other Account. But from a design pattern and security perspective, they should not. wait look at my multisigs
do I need a dead man switch can my multisigs actually hold objects?
I am not sure they should hmmm
or should have a type that doesnt and type that does?
!!!!! maybe I want both types of multisigs


# today
- [X] Only allow founder mint or other stuff 4x above launchpad price ( make those configurable)
- [NAH] Bring this into my code https://x.com/themoveguy/status/1968372304544706598?s=46
- [X] Dao file walrus chink should have config about how far ahead the can be renuewed or prepaid for 
- [X] Merge PR
- [X] Merge in to main
- [X] Fix front end cache bug
- [X] Fix front end github bugs
- [X] Fix front end snyk integration

- [X] make launchpad just allow creator to set cap as they see fit (above minimum) if they dont come back default goes pro rata!!!! have 1 day to do this ( compare to other launchpad)
- [X] check does my policy actually work / enfore for move framework actions
- [X] or make proposal time depend on actions and have custom proposal fee depending on market time
- [X] compare geometric mean oracle to twap oracle to ring buffer
- [ ] Error Codes: While consistent, the use of raw u64 constants for errors is a bit dated. Modern Sui Move often uses custom structs or std::errors for more descriptive, on-chain error reporting, although this is a stylistic choice and doesn't affect correctness.
- [X] allow founder to come in and set launchpad cap on execution not before
- [X] maybe dont make launchpad run full time no matter what if cap reached
- [ ] AMM INTEGRATION
- [ ] DAO LEVEL CONFIG TO TOGGLE HOW MUCH FOUNDERS CAN MINT FOR THEMSLEVES AT START?
- [ ] migrate coin metadata 

- [ ]set up multisig


ter
- [X]Write proposal to lock me up
- [x]Get all events in db
- [ ]Correct witness patterns cross package
- [ ]Correct public function modifier
- [ ]Correct  instance of type many places
- [ ]Check for Move 2024 correct everywhere
- [ ]Unit test coverage improve
- [ ]Figure out ptb logic in tests??? Or integration tests of scripts for devnet integration tests
- [ ]Unit Test coverage in pipeline
- [ ]Linting in pipeline
- [ ]Merge into develop branch
- [ ]Make develop branch main one of repo
- [ ]Do a weekly update
- [ ]Write up amm paper
- [ ]Build sdk
- [ ]Make audit bot
- [ ]Start using codex and gemini cli tools




# Look at jose seperate packages for each module kinda thing to make upgrades easy

# get all constants and magic number in constants files (accont framework has its own)

# upgrade to move 2024

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
- [ ] set proposal time by policy / action and proposal fee proportoonal to proposal time
- [ ] FLASH LOANS FROM LAUNHPAD. 1% OF LAUNCHPAD ALLOCATION GOES TO A PERP 1X LONG OR SHORT, HELPS PRICE DISCOVERY, CAN SHORT
- [ ] seperate out just multsig???? as have leading multisig implementation???
- [ ] dont charge dao fee for frist X proposal / multsig votes
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

==== V3=====

Would be nice if also could have to pass govex futarchy but not our main one like a secondary pool but we own the pool

So need concept of owned amm that doesnt policy authorty in its dao

But other daos can use it to approve stuff

But then this is extra token liquidity 

Will want the atomic market buy back feature etc

So will create arbitrage oportunity. But cant interfere with what othee daos are using it for. So wait until sode pool and main pool are free to do cross pool atmic dao buy back or mint and sell raise


Dont store stable asset type hard coded at dao level just at dao level

Dont hard code asset meta data etc just hard in dao pit them in vec 

Allow dao to delete an amm( withdraw only for lps)

Policy by amm id not general futarchy



Consider way to dynamically add more dao configs?????


Cross dao proposals, blocking out propsal slots on calander say 3 ahead.

Schronous or a sychrnous

Oohh need new action type that have policy of cross dao. Kinda ruins vode reuse tho oooh or have build that takes intents into mera intent
In v3 all dao to change is stable and asset and spin up multiple amm each with own id that approves some stuff maybe multiple to approve a policy


have seperate proposal pools with small liquidity. e.g 1 minute for onchain actions

e.g for self protocol management

and then larger pools for main dao mangement

