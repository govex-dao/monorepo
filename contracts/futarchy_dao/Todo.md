- [ ] Trade back weird octothorpe stuff in headersMobile no footer on trader and create

# Todo for V2
- [ ] Create dao with instant approved intents
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