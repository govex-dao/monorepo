SUBJECT: Architectural Proposal for V4: Implementing a Per-DAO Action Registry for True Composability
1. Executive Summary
This document proposes a core architectural evolution for Futarchy V4: the introduction of a per-DAO, governance-controlled Action Registry. This change will transition our system from a powerful, feature-complete product into a thriving, extensible platform.
The V2 architecture, with its statically-defined action_dispatcher, was the correct choice for its lifecycle. It prioritized a minimal audit surface area and rapid delivery of a core, known feature set, allowing us to establish a competitive lead. However, this design has a deliberate architectural ceiling.
For V4, our strategic imperative must shift from feature delivery to ecosystem growth. The proposed Action Registry directly serves this goal by creating a secure, on-chain mechanism for DAOs to whitelist and integrate third-party actions permissionlessly. This will unlock network effects, foster innovation on our platform, and significantly reduce the development burden on the core team. This is not a refactor of the existing dispatcher, but a new, parallel system for extensibility.
2. Context: The Success and Intentional Limitations of the V2 Dispatcher
The V2 action_dispatcher is a simple, robust, and highly secure component. Its design is a hardcoded, linear scan of all internal futarchy action types.
What V2 Did Right:
Minimal Attack Surface: By explicitly defining every possible action, the dispatcher is easy to reason about and audit. There is no dynamic dispatch, which eliminates a whole class of potential vulnerabilities.
Met Product Goals: It successfully handles the complete, known set of actions required for the Futarchy protocol's core functionality. For the 80/20 of user needs, it is sufficient.
Development Velocity: It allowed the core team to ship a stable, feature-rich product quickly without the added complexity of a dynamic registration system.
Its Deliberate Limitation:
The V2 dispatcher is fundamentally a closed system. It is aware of its own actions and nothing else. While the account_protocol allows for composability at the language level, V2 lacks a mechanism to make the Account object itself aware of new, external actions. This forces third-party developers who wish to integrate their own governance actions to either fork our execution logic or create fragmented, parallel execution entrypoints, undermining the unity of the platform.
3. The V4 Imperative: Evolving From a Product to a Platform
The primary driver for this architectural evolution is the need to move beyond a "walled garden" and cultivate an "app store." The long-term success of Futarchy will be measured not by the features we build, but by the value the ecosystem builds on top of our primitives.
To achieve this, we must solve the core composability challenge: How does a DAO give on-chain, governable permission for its Account to execute new, third-party code?
The Action Registry is the answer. It acts as a governable, on-chain allow-list, turning the abstract promise of composability into a concrete, secure feature.
4. Proposed Architecture: The Per-DAO Action Registry
We will introduce a new, optional component to each DAO Account: an ActionRegistry stored in its managed data. This registry will not replace the existing V2 dispatcher; the V2 dispatcher will continue to handle core futarchy actions efficiently. The registry is exclusively for extending the DAO's capabilities with external actions.
Core Components:
ActionRegistry Object: A new struct stored within the DAO Account's managed data. It will contain a Table<String, address> mapping a unique action TypeName string to the on-chain address of the module that contains its execution logic.
registry_actions Module: A new module defining:
RegisterActionHandlerAction & UnregisterActionHandlerAction: These are new, governable actions that allow a DAO to vote on adding or removing a third-party action from its registry.
is_handler_authorized(...): A public view function that any module can call to verify if its action is currently whitelisted by a specific DAO.
registry_intents Module: A corresponding module for creating proposals to register/unregister handlers.
factory Update: The DAO factory will be updated to initialize an empty ActionRegistry for every newly created V4 DAO.
The Third-Party Developer Workflow:
This architecture creates a simple, secure, and powerful workflow for ecosystem developers:
BUILD: An external team develops a new Move module, cool_protocol::actions, containing their custom CoolAction struct and its execution function, do_cool_action(...).
PROPOSE: The team (or a DAO member) creates a Futarchy proposal. The intent for this proposal uses our new registry_intents::create_register_handler_intent function. The proposal asks the DAO to whitelist CoolAction by registering its TypeName with the on-chain address of the cool_protocol::actions module.
GOVERN: The DAO votes. If the proposal passes, the RegisterActionHandlerAction is executed, and an entry is added to that DAO's private ActionRegistry. CoolAction is now officially an approved action for that DAO.
COMPOSE: Anyone can now create new Futarchy proposals that include CoolAction in their intents.
EXECUTE: When such a proposal passes, the third-party protocol must provide its own public entrypoint for execution. Crucially, this entrypoint will begin with a security check:
code
Move
// In cool_protocol::execution.move
public entry fun execute_our_proposal(
    dao: &mut Account<FutarchyConfig>,
    executable: &mut Executable<FutarchyOutcome>,
    ...
) {
    // First, check the on-chain "guest list"
    assert!(
        registry_actions::is_handler_authorized(
            dao,
            type_name::get<cool_protocol::actions::CoolAction>(),
            @cool_protocol
        ),
        EUnauthorizedAction
    );

    // If authorized, proceed with execution
    let action: &CoolAction = executable.next_action(...);
    cool_protocol::actions::do_cool_action(action, ...);
    
    // NOTE: They CANNOT confirm execution. Only the final caller can.
}
5. Strategic Benefits of the V4 Architecture
Unlocks Permissionless Innovation: We move from being gatekeepers of functionality to enablers of an ecosystem. Any developer can build a governance-gated action for any purpose, from advanced DeFi strategies to NFT collection management.
Creates Powerful Network Effects: As more third-party actions are developed, our platform becomes exponentially more valuable to new and existing DAOs, creating a strong competitive moat.
Reduces Core Team Burden: The core team is no longer responsible for building every conceivable feature. We can focus on the stability and performance of the core protocol, while the community builds out the long tail of functionality.
Enhances Security and Clarity: Instead of implicit social consensus, authorization is now explicit, on-chain, and controlled by DAO governance on a per-action basis.
6. Addressing V2 Concerns: Why Now?
The decision to omit this in V2 was correct. The concerns at the time were valid:
Audit Surface Area: The registry is a new, critical component. In V2, minimizing this surface area was paramount to shipping a secure initial product. For V4, the protocol will be mature, and we will have the resources to properly audit this contained, well-understood addition.
Premature Optimization: Building a platform before having a successful product is a classic mistake. V2 focused on proving the product first. The success of V2 is what creates the demand for V4 to become a platform.
7. Conclusion
The V2 architecture was designed to win the initial battle. The proposed V4 architecture is designed to win the war. By adding a per-DAO Action Registry, we empower our community, scale our development beyond the core team, and transform Futarchy from a powerful tool into an essential piece of on-chain infrastructure. This is the logical and necessary next step in our evolution.