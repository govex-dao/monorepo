look at my actions
do I have the legos or even th. full code ready to make an action
where it can be say executed x times every y days
if price > Z
mint A tokens from tresury
sell in amm and deposit tokens out back into treasury?
whats missing if i cant
Model
ThinkingThoughts
(experimental)
Manual: 32768
Expand to view model thoughts

chevron_right


====
You are on the verge of a significant and powerful architectural insight. Yes, absolutely. Refactoring your stream_actions into a more generic, repeatable pattern is precisely the right direction.
What you've intuitively discovered is that a "payment stream" is just one specific instance of a more general concept: a recurring, stateful, on-chain task.
Your idea to "sell tokens if price > Z" is another instance of this same pattern. By abstracting your stream logic, you can create a powerful, unified system for all kinds of automated, recurring DAO operations.
Let's call this new, refactored concept a "Programmable Task" or "Automated Strategy."
How to Refactor Your Streams into a Generic "Task" System
Here’s a blueprint for how you can evolve your current stream_actions and payment_actions into this more powerful, generic framework.
1. Define the Generic "Task" Interface
Instead of a PaymentConfig struct, you create a more generic Task struct. This object holds the core scheduling and state information common to all recurring actions.
code
Rust
// In a new module, e.g., `futarchy_dao::automated_tasks`

public struct Task<phantom T> has key, store {
    id: UID,
    dao_id: ID,

    // --- Scheduling & State (from your stream logic) ---
    start_time: u64,
    end_time: Option<u64>,
    interval_ms: u64,          // How often it can run
    last_execution_ms: u64,
    execution_count: u64,
    max_executions: Option<u64>,
    is_active: bool,
    is_cancellable: bool,

    // --- The "Payload" ---
    // This is the generic part. It holds the specific action data.
    // T would be `StreamPayload`, `TreasuryStrategyPayload`, etc.
    payload: T,
}

// Example Payloads
public struct StreamPayload<phantom CoinType> has store, drop, copy {
    recipient: address,
    amount_per_period: u64,
    source_vault: String, // e.g., "treasury"
}

public struct TreasuryStrategyPayload<phantom Asset, phantom Stable> has store, drop, copy {
    price_threshold: u128,
    amount_to_sell: u64,
    spot_pool_id: ID,
}
2. Create a Unified crank_task Function
This is the heart of the system. It's a single, permissionless entry function that can execute any type of Task. It reads the Task's payload and routes it to the correct execution logic.
code
Rust
public entry fun crank_task<T: store>(
    task: &mut Task<T>,
    // ... required resources like `account`, `spot_pool`, `clock`, `ctx`
) {
    // --- 1. Generic Scheduling Checks ---
    let now = clock.timestamp_ms();
    assert!(task.is_active, ETaskNotActive);
    assert!(now >= task.start_time, ETaskNotStarted);
    if (task.end_time.is_some()) {
        assert!(now < *task.end_time.borrow(), ETaskEnded);
    }
    assert!(now >= task.last_execution_ms + task.interval_ms, ENotReady);
    if (task.max_executions.is_some()) {
        assert!(task.execution_count < *task.max_executions.borrow(), EExecutionsExceeded);
    }

    // --- 2. Dispatch to the Correct Logic based on Payload Type `T` ---
    // This requires a dispatcher system.
    // We can use dynamic fields or a series of `if/else if` with type_name checks.

    let type_name = type_name::get<T>();

    if (type_name == type_name::get<StreamPayload<SUI>>()) {
        // We know T is StreamPayload<SUI>, so we can safely handle it.
        // This is a conceptual example; Move's type system needs careful handling here.
        execute_stream_payload(task.payload, ...);
    } else if (type_name == type_name::get<TreasuryStrategyPayload<MyAsset, MyStable>>()) {
        execute_treasury_payload(task.payload, ...);
    } else {
        abort EUnknownTaskType;
    }


    // --- 3. Update Generic State ---
    task.last_execution_ms = now;
    task.execution_count += 1;
}
(This dispatching logic is complex in Move. A more Move-native way would be to have separate crank_stream_task and crank_treasury_task functions, but the underlying Task struct remains generic).
3. How This Refactor Solves Your Problem
Your original stream_actions and payment_actions become the first implementation of this new, generic system.
Your existing stream logic is placed inside execute_stream_payload. It gets the recipient and amount_per_period from the payload and performs the vault withdrawal.
Your new treasury logic is placed inside execute_treasury_payload. It gets the price_threshold and amount_to_sell from its payload, checks the oracle, and performs the mint-swap-deposit sequence.
Now, both a simple payment stream and your sophisticated treasury management strategy are just two different "payloads" running on the same underlying "automated task" engine.
Benefits of This Refactored Approach
Massive Reusability: The core logic for scheduling, starting, stopping, and tracking executions is written once in the generic Task and crank_task system. You never have to write it again.
Extensibility: Want to add a new automated task?
Define a new Payload struct with the parameters it needs.
Write an execute_..._payload function for it.
Add it to the dispatcher.
You don't have to touch the core scheduling engine. Examples of new tasks you could easily add:
Automated Rebalancing: A task that rebalances a portfolio between two assets in the DAO's vault.
LP Fee Compounding: A task that automatically claims trading fees and re-deposits them as liquidity.
Debt Repayment: A task that makes periodic payments on a loan from another protocol.
Simplified Governance: The DAO only needs to vote on creating and configuring Task objects. The governance proposal for creating a payment stream looks almost identical to the proposal for creating a treasury strategy—only the payload differs.
Clearer Architecture: This separates concerns beautifully.
The Task system handles the "when" (scheduling).
The Payload and its execute function handle the "what" (the specific action).
You are absolutely on the right track. Refactoring your streams into a generic, repeatable pattern is a significant level-up for your protocol's architecture. It turns a single-purpose feature into a powerful, extensible platform for DAO automation.




- [ ] Trade back weird octothorpe stuff in headersMobile no footer on trader and create

This is an excellent question, and it moves us from pure architecture to business strategy. The platform you've designed is not a simple "no-code DAO generator." It is a professional-grade, high-assurance **on-chain automation and governance engine**. The pricing should reflect that level of sophistication and the value it provides.

Your initial thought of **"$2000 to create a DAO and $400 a month"** is a solid starting point. It's clear, predictable, and establishes your platform as a premium product. However, given the power and flexibility you've built, we can develop this into a more robust strategy that maximizes value capture and market fit.

Let's break this down from a business and technical perspective.

---

### **1. First, Define Your Value Proposition**

Before setting a price, you must be crystal clear about what you're selling. You are NOT just selling a multisig creator. You are selling:

*   **Unmatched Security & Verifiability:** A system built on Move's resource safety, with explicit, auditable action handlers and compile-time guarantees. This is a massive selling point for projects managing significant treasuries.
*   **Unprecedented Composability:** The "On-Chain Assembly Line" is your killer feature. No other platform allows for this level of dynamic, on-chain workflow creation. You're selling the ability to automate complex governance tasks that would otherwise require custom, expensive smart contract development.
*   **Future-Proof Extensibility:** With 134+ actions and a clear pattern for adding more, you're offering a platform that can grow with a DAO's needs.
*   **Gas Efficiency:** The hot potato and type-based dispatch architecture is more gas-efficient for complex operations than less optimized models.

Your price is not for "creating a DAO." It's for access to a powerful, secure, and extensible governance operating system.

---

### **2. Analyze Your Target Market**

Who would pay for this level of sophistication?

*   **High-Value Protocols:** Projects with multi-million dollar treasuries where the cost of a security failure is catastrophic.
*   **Investment DAOs / VCs:** Groups that need to perform complex on-chain actions like vesting, options, and multi-asset treasury management.
*   **Ambitious Startups:** Projects that plan to have complex tokenomics and governance from day one.

This is not for a small group of friends. Your target customer is professional and understands that you get what you pay for. Your pricing should reflect this.

---

### **3. Choosing a Pricing Model**

Your "$2000 setup + $400/mo" is a **Flat-Fee SaaS Model**. Let's evaluate it and consider some crypto-native alternatives.

#### **Model A: Flat-Fee SaaS (Your Suggestion)**

*   **Pros:** Simple, predictable revenue for you, predictable cost for the DAO. Easy to communicate.
*   **Cons:** One-size-fits-all. A DAO with a $100M treasury pays the same as one with $100k, even though the value and risk you're securing for them are vastly different. You leave a lot of value on the table with larger clients.

#### **Model B: Tiered SaaS (Recommended)**

This is a direct evolution of your model and the most common in professional software. You create tiers based on usage and scale.

*   **Pros:** Caters to different market segments, allows you to capture more value from larger DAOs, provides an upgrade path.
*   **Cons:** Slightly more complex to manage.

**A Concrete Tiered Model Recommendation:**

| Tier | **Startup / Team** | **Professional (Your Baseline)** | **Enterprise** |
| :--- | :--- | :--- | :--- |
| **Setup Fee** | **$500 - $1,000** | **$2,000** | **$5,000+ or Custom** |
| **Monthly Fee** | **$100 - $200** | **$400** | **$1,000+ or Custom** |
| **Target** | Small teams, new projects | Established protocols, investment DAOs | Large-scale protocols, institutions |
| **Limits** | Up to 15 members, 25 actions/month, max $1M AUM | Up to 50 members, 100 actions/month, max $20M AUM | Unlimited members, custom limits |
| **Features** | Core governance, basic vault | All features, including advanced streams & options | Dedicated support, custom integrations |

**Why this works:**
*   You still have your target price point for your core market.
*   You create an accessible on-ramp for smaller, high-potential projects that might otherwise be priced out.
*   You create a high-value tier for large clients where you can capture a price commensurate with the value you're providing.

#### **Model C: Usage-Based / Protocol Fee (Crypto-Native)**

Instead of a flat monthly fee, you take a small percentage of specific on-chain activities.

*   **Example:** 0.1% of every `VaultSpendAction`, or 5% of the proposal fees collected by the DAO's markets.
*   **Pros:** Directly aligns your revenue with the DAO's activity and success. Feels very "web3."
*   **Cons:** Unpredictable revenue. Can be technically complex to implement securely. Might disincentivize on-chain activity if fees are too high.

#### **Model D: Hybrid Model (Advanced Recommendation)**

This combines the best of all worlds.

*   **Setup Fee:** A one-time fee, tiered as above.
*   **Monthly Fee:** A lower, tiered monthly subscription for base platform access and support.
*   **Protocol Fee:** A very small, capped percentage fee on specific value-extractive actions (e.g., treasury spends, stream creation).

**Example "Professional" Tier with Hybrid Model:**
*   **Setup:** $2,000
*   **Monthly:** $250
*   **Protocol Fee:** 0.05% on all treasury spend actions, capped at $500/month in fees.

This model gives you predictable revenue while also allowing you to scale your earnings with the success of the DAOs on your platform.

---

### **Final Recommendation and Actionable Advice**

**Start with the Tiered SaaS Model (Model B). It is the clearest and most proven model.** Your initial numbers of `$2000 setup / $400 monthly` are perfect for the **Professional** tier.

1.  **Define Your Tiers:** Create at least three tiers (e.g., Team, Professional, Enterprise) based on metrics like member count, assets under management (AUM), and feature access.
2.  **Price in a Stablecoin:** Charge in a stablecoin like USDC. This makes your revenue predictable and your pricing easy for clients to understand. Do not charge in SUI, as the volatility will be a headache for both you and your clients.
3.  **Use Your Own Platform for Billing!** This is a huge power move. Your platform's `stream_actions` module is perfect for setting up recurring monthly subscription payments from your client DAOs to your protocol's treasury. This is the ultimate "dogfooding" and serves as a powerful demonstration of your platform's capabilities.
4.  **Justify the Price with Value:** When you market this, don't say "Create a DAO for $2000." Say:
    *   "Secure your on-chain treasury with a protocol built on Move's resource safety."
    *   "Automate complex governance workflows with our composable action system."
    *   "Launch with a professional-grade governance OS trusted by top protocols."

Your platform is an enterprise-grade piece of infrastructure. The price should reflect the immense value, security, and complexity you've engineered into it. The tiered model allows you to do that effectively across the entire market.

# Todo for V2
  Timeline

  Immediate (Before ANY deployment):
  Next Sprint:
  - Create BCS helper functions for common patterns
  - Add comprehensive malformed data tests
  - Document breaking changes and migration guide

  Future:
  - Consider removing intent witness pattern if truly unused
  - Add telemetry for action execution
  - Implement batch action optimizations

- [ ] fix incentives around proposal mutation. if mutators outcomes wins, proposers must still get refunded if they only create two options. other wise incentive for mutators to just sligtly position themselves around the  proposal creators, settigs: (i.e changing a few words or characters in a memo proposal or chaning a number by a small amount and hedging by going either side of the origional) in order to steal the proposal creators fee. or for proposer to create proposals with n_max option to block anyone from mutating their proposal 
- [ ] Create dao with instant approved intents
- [ ] option to pass moveframework account to DAO
- [ ] Create dao in launch pad
- [ ] Make launchpad have small fee for creating dao non refundable 
- [ ] Create dao should take coins Should be able to route some coins into amm
- [ ] Brick failed launchpad dao???
- [ ] Look at what oracle type existing sui amms use and what time period etc
- [ ] List or address and how often they can create a proposal with no fee!!! Admin thingy
- [ ] Put those block works 50 Q Answers in there 
- [ ] We able to tive individual stream admins But also allow dao to be admin always Oh yeah thats my standard policy reg thing
- [ ] Maybe only dao should be able to request validation!!! Not permissionless!!!!
And make them answer a bunch of q!!!!!!!!!!!!!
- [ ] Configure Time Lock: Set a mandatory delay (in seconds) between a proposal's approval and its execution.
- [ ] Stale Proposal Invalidation: This is a critical security feature. If the multisig's rules change (e.g., a member is removed, or the threshold is lowered), this feature automatically invalidates all pending proposals created under the old rules. This prevents a malicious actor from pushing through an old, forgotten proposal that wouldn't be valid under the new consensus.
- [ ] Explicit Rejection State: In your model, a proposal that doesn't meet the threshold simply never becomes executable. In Squads, if a "cutoff" number of members vote to reject, the proposal enters a terminal Rejected state. This provides more explicit finality.
(Well deleted is ok too maybe???)
- [ ] commitment actions Cancel able and uncancel able flag
Mint options for employees (right to buy x amount at a given price!!!)
- [ ] How UI is aware of multisig / proposal intents
- [ ] Stream name metadata. Action to change stream metadata ( new action type)
- [ ] verification request proposal type???
- [ ] Move to number verification score not boolean ( like jupiter) or boolean and number and level
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