Engineering Plan: Finalizing the Futarchy Governance Action & Intent Architecture
Document Version: 1.0
Date: 2023-10-27
Author: AI Assistant (based on discussion with project lead)
1. Executive Summary
This plan outlines a series of refactors to unify the project's governance action and intent system into a cohesive, scalable, and secure architecture. The goal is to eliminate inconsistencies and formally adopt a dual-pattern approach that leverages the strengths of our existing components.
The final architecture will be:
IntentSpec as the Universal Blueprint: A lightweight, serializable struct used for all "draft" or "pre-approval" stages, including DAO initialization and live proposals before they are approved.
Intent as the Live, Executable Contract: A stateful object stored in an Account's intents bag, representing a fully approved, executable, or recurring action.
A Table-Based Dispatcher for Initialization: The init_actions flow will be refactored to use our existing dispatcher_registry (a sui::table), creating a highly extensible "plugin" system for DAO creation.
A Hierarchical Dispatcher for Runtime Governance: The main_dispatcher will remain the entry point for executing approved proposals, as its if/else structure is necessary to handle the varied resource and generic type requirements of live actions.
This refactor will significantly reduce on-chain state bloat, improve gas efficiency, enhance security by enforcing proposal immutability, and create a much cleaner and more maintainable codebase.
2. Background & Motivation
Our initial development has produced a powerful but inconsistent set of tools for handling governance actions. A review of the codebase revealed several architectural conflicts:
Dueling Definitions: Two different IntentSpec structs exist, one lightweight and type-safe (account_protocol::intent_spec), the other a remnant of a string-based system (futarchy_actions::intent_spec).
Legacy Patterns: Some modules still reference a string-based action_descriptor system, which has been correctly superseded by a TypeName-based system in our core account_protocol::intents module.
Inconsistent Dispatcher Usage: We have two powerful dispatcher patterns—a hierarchical if/else chain and a table-based handler registry—but they are not being used in their ideal contexts. Specifically, the atomic, fixed-resource context of init_actions is a perfect fit for the table-based dispatcher it currently isn't using.
State Bloat Risk: Storing full, stateful Intent objects for every proposal (even those that will fail) creates significant, unnecessary on-chain storage overhead and complicates garbage collection.
This plan addresses these issues by standardizing on our best patterns, clarifying the role of each component, and ensuring a clean, logical flow from a proposal's draft stage to its final execution.
3. Proposed Architecture: A Dual-Pattern System
We will formalize a two-part system that distinguishes between the lifecycle of an action before and after formal governance approval.
### Proposed Architecture: A Dual-Pattern System

| Component           | Role                  | Description                                                                                              | On-Chain State                                                              | Dispatcher Used                                                      |
| :------------------ | :-------------------- | :------------------------------------------------------------------------------------------------------- | :-------------------------------------------------------------------------- | :------------------------------------------------------------------- |
| **`IntentSpec`**    | **The Blueprint**     | A lightweight, immutable, serializable description of actions. It is a plan.                             | Stored inside `Raise` objects (for init) and `Proposal` objects (for governance). | **Builder Dispatcher** (Off-chain SDK) to create the spec.         |
| **`Intent`**        | **The Contract**      | A live, stateful object inside an `Account`. Represents an approved, executable plan or a recurring task. | Stored in the `Account`'s `intents` `Bag`. Not used for unapproved proposals. | N/A (It's the *result* of a successful proposal).                    |
| **`init_actions`**  | **The Constructor**   | Executes a set of `IntentSpec` blueprints to atomically configure a new DAO using "hot potato" resources.    | Runs once at DAO creation.                                                  | **Table-Based Dispatcher** (`dispatcher_registry`).                    |
| **`main_dispatcher`** | **The Executor**      | Executes actions from an `Executable` that was created from an approved `Intent` or `IntentSpec`.        | Runs whenever a live DAO proposal is executed.                              | **Hierarchical `if/else` Dispatcher**.                             |
4. Implementation Plan
This refactor should be executed in the following sequence to ensure a smooth transition.
Standardize IntentSpec:
Action: Delete the file futarchy_actions::intent_spec.move.
Action: Refactor futarchy_actions::intent_spec_builder to use and produce account_protocol::intent_spec::ActionSpec and account_protocol::intent_spec::IntentSpec objects. All functions within will now use type_name::get<T>() and bcs::to_bytes().
Reason: Establish a single, consistent "blueprint" object for the entire system.
Purge Legacy action_descriptor:
Action: Perform a codebase search for action_descriptor.
Action: Remove all references and logic related to it, particularly in do_* execution functions like the one in futarchy_lifecycle::stream_actions.
Reason: Eliminate a stale pattern that conflicts with the TypeName-based system and would cause compilation failures.
Modify Proposal Structs to Use IntentSpec:
Action: In futarchy_markets::proposal.move, change the Proposal struct to store an IntentSpec instead of linking to an Intent via a key.
code
Move
// Before
// intent_key: Option<String>

// After
use account_protocol::intent_spec::IntentSpec;
intent_spec: IntentSpec,
Action: Do the same for futarchy_actions::optimistic_proposal::OptimisticProposal.
Reason: This is the core change to reduce state bloat and enforce immutability. The proposal now contains its own immutable blueprint, rather than pointing to a mutable object in the main Account.
Adapt Proposal Execution Flow:
Action: Refactor futarchy_specialized_actions::governance_intents::execute_proposal_intent.
Details: This function will no longer fetch an Intent from the Account. Instead, it will:
a. Read the intent_spec from the &Proposal object.
b. Use the futarchy_actions::intent_factory module to convert the IntentSpec into a temporary, in-memory Executable.
c. Return this Executable to the caller.
Reason: This adapts the execution flow to the new "blueprint" model, deferring object creation until the moment it's needed.
Refactor init_actions to Use the Table-Based Dispatcher:
Action: Modify the signature of futarchy_lifecycle::init_actions::execute_specs_with_resources to accept registry: &mut DispatcherRegistry.
Action: Replace the entire if/else chain inside this function with the table lookup pattern:
let handler_id = dispatcher_registry::get_handler_id(...)
let handler = sui::dynamic_object_field::borrow_mut(...)
Call a generic handler interface function, e.g., my_handler_module::execute(...).
Reason: This aligns the init_actions module with its ideal purpose as an extensible "plugin" system for DAO creation, leveraging the powerful table-based dispatcher.
Implement ActionHandler Modules:
Action: For each action that can be used at initialization (e.g., UpdateName, AddLiquidity), create a small corresponding handler module (e.g., config_handler, liquidity_handler).
Action: Each handler module must implement a public execute function that matches the signature in action_handler_interface. This function will contain the logic to deserialize action_data and call the internal do_* function.
Reason: This is the required implementation for the table-based dispatcher pattern. It makes each action's initialization logic self-contained.
5. Pros and Cons Analysis
Pros:
Massively Reduced State Bloat: The primary Account object will no longer store an Intent for every single proposal, only for approved, recurring, or special cases. This is a huge win for on-chain storage costs and scalability.
Improved Gas Efficiency: Gas for creating action objects is deferred until execution, meaning failed proposals have a much lower on-chain footprint.
Enhanced Security & Clarity: Proposal actions (IntentSpec) become provably immutable once on-chain, eliminating "bait-and-switch" risks. The roles of all components become clearer.
Simplified Cleanup: Garbage collection for failed proposals is eliminated. The IntentSpec is simply destroyed with its parent Proposal object.
Superior Extensibility: The init_actions flow becomes a true plugin system. New initialization actions can be added by deploying a new handler and registering it, with zero changes to the core init_actions or factory code.
Cons:
Upfront Refactoring Effort: This is a significant architectural refactor that will touch many parts of the codebase, including proposals, dispatchers, and execution entry points. It will require careful planning and testing.
Minor Execution Overhead: There is a small, one-time gas cost to deserialize action_data from an IntentSpec at the moment of execution. This is a negligible trade-off for the massive storage savings and architectural clarity gained.
6. Future Considerations
SDK Development: This clarified architecture makes building a client-side SDK much simpler. The SDK can have a "builder" that constructs IntentSpec objects, mirroring the on-chain intent_spec_builder module.
Dynamic Action Registration: The refactored init_actions system opens the door for a future where third-party developers can deploy their own ActionHandler objects and register them with the factory's DispatcherRegistry, allowing DAOs to be created with custom, third-party initialization steps.


1. Executive Summary & Architectural Vision
This plan details a strategic refactor of our governance system to a fully composable, PTB-driven architecture. We will eliminate centralized on-chain dispatchers in favor of promoting individual, category-level modules to public entry functions. The Programmable Transaction Block (PTB) itself will become the primary dispatcher, orchestrated by off-chain SDKs and clients.
This "Hot Potato Composition" pattern, where stateful objects are passed between entry functions within a single atomic transaction, is a highly idiomatic and powerful Sui design. It will make our protocol more modular, extensible, secure, and easier for third parties to integrate with.
The final architecture will consist of three distinct, cleanly separated systems:
The Off-Chain Builder: An SDK that uses an off-chain table/map to find and call on-chain "builder" functions. Its sole purpose is to construct IntentSpec objects.
The On-Chain Blueprint (IntentSpec): A single, canonical, and immutable IntentSpec struct will serve as the lightweight blueprint for all actions, whether for DAO initialization or live proposals.
The On-Chain Execution Toolkit: A suite of modular, public entry functions (our former "hierarchical dispatchers") that accept "hot potato" objects like the Executable and perform specific tasks (e.g., executing config actions, liquidity actions). The main_dispatcher module will be removed.
This refactor will resolve all identified inconsistencies and position our protocol as a leading example of sophisticated, composable on-chain governance.
2. Core Architectural Principles
Immutability for Proposals: Actions defined in a proposal (IntentSpec) are immutable once on-chain. There is no on-chain "draft" stage for live proposals.
Separation of Concerns:
Blueprint vs. Contract: IntentSpec is the plan. Intent is the live, approved contract.
Framework vs. Application: account_protocol is the generic "OS." futarchy is the specific "application."
Construction vs. Execution: Building an IntentSpec is separate from executing its actions.
PTB as the Orchestrator: Complex workflows like DAO creation, proposal execution, and dissolution will be composed of multiple entry function calls within a single PTB, orchestrated by the client.
Lean On-Chain State: We will aggressively avoid storing unnecessary state. Full Intent objects will not be created for unapproved proposals, drastically reducing state bloat on the core Account object.
3. Detailed Implementation Plan
This is a multi-phase refactor. Each phase builds upon the last and should be completed in order.
Objective: Establish a single, canonical IntentSpec and purge all legacy patterns.
Standardize IntentSpec:
Action: Delete the file futarchy_actions/intent_spec.move.
Action: Refactor the futarchy_actions::intent_spec_builder module.
All new_*_spec functions must now return an account_protocol::intent_spec::ActionSpec.
Inside each function, serialize the corresponding action data struct (e.g., UpdateNameAction) to vector<u8> using sui::bcs::to_bytes().
Pair the serialized data with the TypeName of the corresponding action type marker (e.g., type_name::get<action_types::UpdateName>()).
Verification: Confirm that the only IntentSpec struct in the codebase is the one defined in account_protocol::intent_spec.
Purge Legacy action_descriptor:
Action: Perform a global search for action_descriptor.
Action: Remove all logic that uses or references this concept, especially from do_* execution functions. The sole mechanism for action identification at runtime will be TypeName comparison.
Verification: The codebase should no longer contain the string action_descriptor in any functional capacity.
Objective: Modify Proposal objects to store the lightweight IntentSpec blueprint instead of a full Intent, and adapt the execution flow.
Update Proposal Structs:
Action: In futarchy_markets::proposal.move, modify the Proposal struct. Replace the field that links to an Intent (e.g., intent_key) with intent_spec: IntentSpec.
Action: Perform the same modification for futarchy_actions::optimistic_proposal::OptimisticProposal.
Verification: Proposal objects no longer hold state related to a live Intent. They are now self-contained blueprints.
Adapt the execute Entry Point:
Action: Create a new top-level entry function, futarchy_dao::execute::start_proposal_execution.
Details: This function will:
a. Accept the &mut Account and &Proposal.
b. Verify the proposal was approved (winning outcome is YES).
c. Read the intent_spec from the Proposal.
d. Use futarchy_actions::intent_factory to convert the IntentSpec into a temporary Executable hot potato.
e. Crucially, it transfers this Executable to the sender.
Verification: This function becomes the single starting point for executing an approved proposal via a PTB.
Objective: Decommission the on-chain main_dispatcher and empower category-level dispatchers as composable entry functions.
Delete main_dispatcher:
Action: Delete the file futarchy_actions/main_dispatcher.move.
Reason: Its role as an on-chain router is now fulfilled by the PTB itself.
Refactor Category-Level Dispatchers:
Action: For each *_dispatcher module (e.g., config_dispatcher, liquidity_dispatcher):
a. Promote its main function (e.g., try_execute_config_action) to a public entry function (e.g., execute_config_actions).
b. Change its signature to accept the Executable hot potato as its first argument.
c. Implement a loop inside the function. In each iteration, it should peek at the next action's TypeName. If it's a type this dispatcher handles, it executes it and continues the loop. If not, it breaks the loop.
d. The function must transfer the Executable (now partially or fully processed) back to the sender at the end.
Verification: Each dispatcher is now an independent, composable entry function.
Create the Finalizer Function:
Action: In futarchy_dao::execute, create a public entry fun confirm_and_cleanup.
Details: This function accepts the final Executable hot potato and the &mut Account. It calls account::confirm_execution and then triggers the garbage collection (gc_janitor) for any one-shot intents.
Verification: This provides a secure endpoint to finalize the PTB chain and ensures no Executable is left unconsumed.
Objective: Extend this composable pattern to other complex, multi-step processes for consistency and modularity.
Refactor DAO Initialization (init_actions):
Action: Deconstruct the monolithic init_actions module into smaller, specialized entry functions (e.g., init_config_actions, init_liquidity_actions).
Action: Create a new entry point in the factory module: create_dao_unshared. This function creates the Account, Queue, and SpotAMM but returns them as unshared hot potatoes.
Action: Create a finalizer entry function: factory::finalize_and_share_dao that takes the configured hot potatoes and shares them publicly.
Verification: DAO creation is now a fully composable PTB flow, allowing for custom initialization steps.
(Future) Refactor Proposal Finalization & Dissolution:
Action: Plan a future refactor for proposal_lifecycle and dissolution_actions to follow the same pattern, breaking down their complex functions into a chain of composable entry functions that pass a stateful hot potato (FinalizationReceipt, DissolutionTicket).
Reason: This will bring the entire protocol into alignment with this powerful architectural pattern.
4. SDK and Client-Side Implications
The off-chain SDK will become more critical. It must be responsible for orchestrating the correct sequence of entry function calls in the PTB.
The SDK should be designed with a "fluent" builder pattern. Example:
code
TypeScript
const builder = new ProposalExecutor(txb, accountId, proposalId);
await builder
  .start() // Calls execute_approved_proposal
  .withConfigActions() // Calls config_dispatcher
  .withLiquidityActions(spotAmmId) // Calls liquidity_dispatcher
  .finalize(); // Calls confirm_and_cleanup
This shifts complexity from on-chain (rigid) to off-chain (flexible), which is a significant advantage.
This comprehensive plan will result in a state-of-the-art, highly composable, and scalable governance protocol.




- ptb stuff
Of course. Here is a revised and comprehensive engineering plan that incorporates the "PTB as a Dispatcher" architecture. This plan is designed to be a clear, actionable guide for your development team.
Engineering Plan: A Composable, PTB-Driven Governance Architecture
Document Version: 2.0
Date: 2023-10-27
Author: AI Assistant (based on discussion with project lead)
1. Executive Summary & Architectural Vision
This plan details a strategic refactor of our governance system to a fully composable, PTB-driven architecture. We will eliminate centralized on-chain dispatchers in favor of promoting individual, category-level modules to public entry functions. The Programmable Transaction Block (PTB) itself will become the primary dispatcher, orchestrated by off-chain SDKs and clients.
This "Hot Potato Composition" pattern, where stateful objects are passed between entry functions within a single atomic transaction, is a highly idiomatic and powerful Sui design. It will make our protocol more modular, extensible, secure, and easier for third parties to integrate with.
The final architecture will consist of three distinct, cleanly separated systems:
The Off-Chain Builder: An SDK that uses an off-chain table/map to find and call on-chain "builder" functions. Its sole purpose is to construct IntentSpec objects.
The On-Chain Blueprint (IntentSpec): A single, canonical, and immutable IntentSpec struct will serve as the lightweight blueprint for all actions, whether for DAO initialization or live proposals.
The On-Chain Execution Toolkit: A suite of modular, public entry functions (our former "hierarchical dispatchers") that accept "hot potato" objects like the Executable and perform specific tasks (e.g., executing config actions, liquidity actions). The main_dispatcher module will be removed.
This refactor will resolve all identified inconsistencies and position our protocol as a leading example of sophisticated, composable on-chain governance.
2. Core Architectural Principles
Immutability for Proposals: Actions defined in a proposal (IntentSpec) are immutable once on-chain. There is no on-chain "draft" stage for live proposals.
Separation of Concerns:
Blueprint vs. Contract: IntentSpec is the plan. Intent is the live, approved contract.
Framework vs. Application: account_protocol is the generic "OS." futarchy is the specific "application."
Construction vs. Execution: Building an IntentSpec is separate from executing its actions.
PTB as the Orchestrator: Complex workflows like DAO creation, proposal execution, and dissolution will be composed of multiple entry function calls within a single PTB, orchestrated by the client.
Lean On-Chain State: We will aggressively avoid storing unnecessary state. Full Intent objects will not be created for unapproved proposals, drastically reducing state bloat on the core Account object.
3. Detailed Implementation Plan
This is a multi-phase refactor. Each phase builds upon the last and should be completed in order.
Objective: Establish a single, canonical IntentSpec and purge all legacy patterns.
Standardize IntentSpec:
Action: Delete the file futarchy_actions/intent_spec.move.
Action: Refactor the futarchy_actions::intent_spec_builder module.
All new_*_spec functions must now return an account_protocol::intent_spec::ActionSpec.
Inside each function, serialize the corresponding action data struct (e.g., UpdateNameAction) to vector<u8> using sui::bcs::to_bytes().
Pair the serialized data with the TypeName of the corresponding action type marker (e.g., type_name::get<action_types::UpdateName>()).
Verification: Confirm that the only IntentSpec struct in the codebase is the one defined in account_protocol::intent_spec.
Purge Legacy action_descriptor:
Action: Perform a global search for action_descriptor.
Action: Remove all logic that uses or references this concept, especially from do_* execution functions. The sole mechanism for action identification at runtime will be TypeName comparison.
Verification: The codebase should no longer contain the string action_descriptor in any functional capacity.
Objective: Modify Proposal objects to store the lightweight IntentSpec blueprint instead of a full Intent, and adapt the execution flow.
Update Proposal Structs:
Action: In futarchy_markets::proposal.move, modify the Proposal struct. Replace the field that links to an Intent (e.g., intent_key) with intent_spec: IntentSpec.
Action: Perform the same modification for futarchy_actions::optimistic_proposal::OptimisticProposal.
Verification: Proposal objects no longer hold state related to a live Intent. They are now self-contained blueprints.
Adapt the execute Entry Point:
Action: Create a new top-level entry function, futarchy_dao::execute::start_proposal_execution.
Details: This function will:
a. Accept the &mut Account and &Proposal.
b. Verify the proposal was approved (winning outcome is YES).
c. Read the intent_spec from the Proposal.
d. Use futarchy_actions::intent_factory to convert the IntentSpec into a temporary Executable hot potato.
e. Crucially, it transfers this Executable to the sender.
Verification: This function becomes the single starting point for executing an approved proposal via a PTB.
Objective: Decommission the on-chain main_dispatcher and empower category-level dispatchers as composable entry functions.
Delete main_dispatcher:
Action: Delete the file futarchy_actions/main_dispatcher.move.
Reason: Its role as an on-chain router is now fulfilled by the PTB itself.
Refactor Category-Level Dispatchers:
Action: For each *_dispatcher module (e.g., config_dispatcher, liquidity_dispatcher):
a. Promote its main function (e.g., try_execute_config_action) to a public entry function (e.g., execute_config_actions).
b. Change its signature to accept the Executable hot potato as its first argument.
c. Implement a loop inside the function. In each iteration, it should peek at the next action's TypeName. If it's a type this dispatcher handles, it executes it and continues the loop. If not, it breaks the loop.
d. The function must transfer the Executable (now partially or fully processed) back to the sender at the end.
Verification: Each dispatcher is now an independent, composable entry function.
Create the Finalizer Function:
Action: In futarchy_dao::execute, create a public entry fun confirm_and_cleanup.
Details: This function accepts the final Executable hot potato and the &mut Account. It calls account::confirm_execution and then triggers the garbage collection (gc_janitor) for any one-shot intents.
Verification: This provides a secure endpoint to finalize the PTB chain and ensures no Executable is left unconsumed.
Objective: Extend this composable pattern to other complex, multi-step processes for consistency and modularity.
Refactor DAO Initialization (init_actions):
Action: Deconstruct the monolithic init_actions module into smaller, specialized entry functions (e.g., init_config_actions, init_liquidity_actions).
Action: Create a new entry point in the factory module: create_dao_unshared. This function creates the Account, Queue, and SpotAMM but returns them as unshared hot potatoes.
Action: Create a finalizer entry function: factory::finalize_and_share_dao that takes the configured hot potatoes and shares them publicly.
Verification: DAO creation is now a fully composable PTB flow, allowing for custom initialization steps.
(Future) Refactor Proposal Finalization & Dissolution:
Action: Plan a future refactor for proposal_lifecycle and dissolution_actions to follow the same pattern, breaking down their complex functions into a chain of composable entry functions that pass a stateful hot potato (FinalizationReceipt, DissolutionTicket).
Reason: This will bring the entire protocol into alignment with this powerful architectural pattern.
4. SDK and Client-Side Implications
The off-chain SDK will become more critical. It must be responsible for orchestrating the correct sequence of entry function calls in the PTB.
The SDK should be designed with a "fluent" builder pattern. Example:
code
TypeScript
const builder = new ProposalExecutor(txb, accountId, proposalId);
await builder
  .start() // Calls execute_approved_proposal
  .withConfigActions() // Calls config_dispatcher
  .withLiquidityActions(spotAmmId) // Calls liquidity_dispatcher
  .finalize(); // Calls confirm_and_cleanup
This shifts complexity from on-chain (rigid) to off-chain (flexible), which is a significant advantage.
This comprehensive plan will result in a state-of-the-art, highly composable, and scalable governance protocol.



# Todo for V2
- [ ] Look at what oracle type existing sui amms use and what time period etc

- [ ] List or address and how often they can create a proposal with no fee!!! Admin thingy

- [ ] Put those block works 50 Q Answers in there 

- [ ] We able to tive individual stream admins But also allow dao to be admin always Oh yeah thats my standard policy reg thing

- [ ]  Dao be able to pause its self action type???? For buys outs. Any other dao futarchy config actions??? Probably action to do this tbf.

- [ ] Maybe only dao should be able to request validation!!! Not permissionless!!!!
And make them answer a bunch of q!!!!!!!!!!!!!

- [ ] https://aistudio.google.com/prompts/1my89HlGFhJe4CaN1EA5JaUJlxHIbKEep?save=true
- [ ] Configure Time Lock: Set a mandatory delay (in seconds) between a proposal's approval and its execution.
- [ ] Stale Proposal Invalidation: This is a critical security feature. If the multisig's rules change (e.g., a member is removed, or the threshold is lowered), this feature automatically invalidates all pending proposals created under the old rules. This prevents a malicious actor from pushing through an old, forgotten proposal that wouldn't be valid under the new consensus.
- [ ] Explicit Rejection State: In your model, a proposal that doesn't meet the threshold simply never becomes executable. In Squads, if a "cutoff" number of members vote to reject, the proposal enters a terminal Rejected state. This provides more explicit finality.
(Well deleted is ok too maybe???)
- [ ] Draft State: Squads allows proposals to be created as a Draft. This is crucial for complex batches, allowing the proposer to add, remove, and review transactions before officially opening the proposal to a vote. Your Intent is effectively "active" as soon as it's created.
- [ ] commitment actions Cancel able and uncancel able flag
Mint options for employees (right to buy x amount at a given price!!!)
Order hetro geniuus bag for intents / fix bsc
- [ ] Intents drafting using launchpad constructor?
- [ ] Proposal / intent drafting
- [ ] Why not use in constructors everywhere instead of intents ( until execution needed)
- [ ] All policy actions should be dao only by default 
- [ ] How UI is aware of multisig / proposal intents
- [ ] Stream name metadata. Action to change stream metadata ( new action type)
- [ ]  Actually list out all my actions in a docs
- [ ]  DAO Policy ie 2 of 2 stuff needs to be discoverable offchain
- [ ] Move to number verification score not boolean ( like jupiter) or boolean and number and level
- [ ] Multisig fee / Fee to create multig / agree not to use for a prediction market or futarchy protocol without first getting prior agreement.
- [ ] Employee as onchain resource???
- [ ]  move framework And full fork notes in readme and files
- [ ] Get summary of each file and make sure AIs stop getting tripped up
- [ ] Get actions and proposal flow into seperate packages.
maybe DAO and proposal ( with markets) and actions seperate and maybe mutlsig stuff???

- [X] Compare to other large quality move packages
like walrus deep book and leading lending protocols etc
main ones on defi lama that are new! Deepbook, walrus, jose, account tech, big ones on defillama


# Consider for V3
- [ ] Should operating agreements or another object e.g registry be able to make policy rules regarding actions types e.g. preventing them or setting what authority they need
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