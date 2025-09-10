# Todo for V2

### 🔴 Major Issues with Current Structure:

1. **`futarchy_governance` is still too large (31 files)**
   - This is a red flag - it's doing too much
   - Should be broken into at least 2-3 packages:
     - `futarchy_intents` - All intent builders/dispatchers (15+ files)
     - `futarchy_proposals` - Proposal types (commitment, optimistic)
     - `futarchy_governance` - Just core governance logic

2. **`futarchy_shared` is a dumping ground (14 files)**
   - Mixed concerns: factory, vault, security, oracle actions
   - "Shared" is a code smell - packages should have clear purposes
   - Should be split:
     - `futarchy_factory` - Factory and launchpad (3 files)
     - `futarchy_vault` - Vault operations (4 files)
     - `futarchy_security` - Security council + multisig (2 files)

3. **Dependency clarity is poor**
   - `futarchy_shared` depends on `futarchy_markets` AND vice versa (potential circular dependency risk)
   - The main `futarchy` package has factory logic that should be separate

### 🟡 Architectural Concerns:

4. **Action/Dispatcher pattern is scattered**
   - Each package has its own `*_actions`, `*_dispatcher`, `*_intents` files
   - This creates 3 files per feature - could be cleaner
   - Consider: One file per feature with clear sections

5. **Version files everywhere**
   - 4 packages have their own `version.move`
   - This suggests poor version management strategy
   - Should have one version source of truth
   - **SOLUTION: THE version file should live ONLY in `futarchy_core`**
     - It's the foundational package that everything depends on
     - Core already has the version file that others are using
     - Creates clean dependency hierarchy: everyone depends on core → gets version
     - All other packages just import `use futarchy_core::version`

6. **The main `futarchy` package is confused**
   - Has factory files (should be in factory package)
   - Has coexec (should be with security)
   - Should ONLY orchestrate, not implement

### 🔴 Critical Naming Issues:

1. **`futarchy` (main package) - TERRIBLE NAME**
   - Everything is "futarchy" - this tells us nothing
   - Should be: **`futarchy_coordinator`** or **`futarchy_engine`**
   - Shows it's the orchestration layer

2. **`futarchy_shared` - MEANINGLESS**
   - "Shared" = "I didn't know where to put this"
   - Should be broken up, NOT renamed

3. **`futarchy_governance` - TOO GENERIC**
   - Everything is governance in a DAO
   - Should be: **`futarchy_decisions`** or **`futarchy_voting`**

### 🟡 Recombination Opportunities:

#### **COMBINE: Streams + Operating Agreement → `futarchy_operations`**
```
Current: 9 files across 2 packages
Combine into: futarchy_operations/
  ├── payments/     (was streams)
  ├── legal/        (was operating_agreement)
  └── version.move
```
**Rationale**: Both are operational concerns of a running DAO. 9 files is perfect size.

#### **COMBINE: All the scattered "intents" → `futarchy_intents`**
```
Currently scattered across 4+ packages
Combine into: futarchy_intents/
  ├── builders/     (all intent builders)
  ├── dispatchers/  (all dispatchers)
  └── witnesses/    (all intent witnesses)
```
**Rationale**: The intent pattern is cross-cutting. Having 3 files per feature (_intents, _actions, _dispatcher) is insane.

#### **SPLIT BUT RECOMBINE: Factory/Launchpad files → `futarchy_lifecycle`**
```
Currently in 3 places (!!)
Combine into: futarchy_lifecycle/
  ├── factory/
  ├── launchpad/
  ├── dissolution/  (from governance)
  └── janitor/      (garbage collection)
```
**Rationale**: These all handle DAO lifecycle - birth, funding, death, cleanup.

### 📊 Critical Simplification:

**KILL the Action/Dispatcher/Intent pattern repetition:**

Instead of:
```
config_actions.move
config_dispatcher.move  
config_intents.move
```

Have:
```
config.move (with clear sections)
```

This alone would reduce file count by ~40%!

### 🚨 Most Critical Fixes:

1. **Rename `futarchy` → `futarchy_engine`** immediately
2. **Delete `futarchy_shared`** - it's architectural debt
3. **Combine streams + operating_agreement** - they're both small operational concerns
4. **Extract `futarchy_lifecycle`** - factory/launchpad/dissolution belong together
5. **Consolidate the intent pattern** - 3 files per feature is madness

### 💀 What Should Die:

- The `futarchy_shared` package name
- Having 4 separate `version.move` files
- The _actions/_dispatcher/_intents file explosion
- Artificial separation of tiny packages (4-5 files each)

### ✅ Final Architecture (9 packages):

1. futarchy_one_shot_utils (7 files) - one-shot utilities for math/vectors/heap
2. futarchy_core (8 files) - types/config **[CONTAINS THE ONLY VERSION FILE]**
3. futarchy_markets (16 files) - AMM logic (oracle coupled with AMMs as per user preference)
4. futarchy_vault (5 files) - treasury management
5. futarchy_multisig (8 files) - weighted multisig/security council/coexec patterns
6. futarchy_lifecycle (12 files) - factory/launch/dissolve/garbage-collection
7. futarchy_actions (~25 files) - core actions + intent lifecycle management
8. futarchy_specialized_actions (~15 files) - complex domain-specific actions (streams/legal/governance)
9. futarchy_dao (5 files) - main DAO orchestration only

This is cleaner, clearer, and each package has a single clear purpose. No "shared", no
confusion about what goes where, no artificial splitting of related code.

### 📊 Clean Dependency Hierarchy:

```
futarchy_one_shot_utils (standalone)
    ↓
futarchy_core (has THE version file - all others import from here)
    ↓
futarchy_markets
    ↓
futarchy_vault → futarchy_multisig
    ↓                     ↓
futarchy_lifecycle → futarchy_actions (core actions + intent lifecycle)
                        ↓
                futarchy_specialized_actions (complex: streams/legal/governance)
                        ↓
                futarchy_dao (orchestrator only)
```

### 📁 Package Contents Breakdown:

**futarchy_actions** (core actions + intent lifecycle):
- Core action types (config, liquidity, dissolution, memo, policy)
- Intent lifecycle management (commitment/optimistic proposals)
- Resource request pattern (hot potato)
- Action dispatchers

**futarchy_specialized_actions** (complex domain-specific):
- Payment streams (recurring payments with cliffs)
- Legal/Operating agreements (on-chain legal docs)
- Governance actions (second-order proposals, requires ProposalQueue)
- All need complex external resources

# Todo for V2
- [ ] Get summary of each file and make sure AIs stop getting tripped up

- [ ] Get actions and proposal flow into seperate packages.
maybe DAO and proposal ( with markets) and actions seperate and maybe mutlsig stuff???


- [X] Compare to other large quality move packages
like walrus deep book and leading lending protocols etc
main ones on defi lama that are new! Deepbook, walrus, jose, account tech, big ones on defillama

- [X]  Make sure owner dao and its secuity council can control admin thingy to change platform fees / fee collector

- [x] Optional Security council with optimisitic proosal action creation, can be challenged with X period like how stream sub actions work

- [X] Way to create double memo proposal or proposal that requires x% increase to pass not just dao threshold %. So founder agree to lock tokens if increases price of stock… either need profile for that founder to act as their own ado or something else???

- [x] Need deposit revenue endpoint for daos



- [x] Collect fee require admin cap and be able to only take less than max so can give discounts 



- [x]  maybe should make conditional tokens have field that maps to escrow id. so can autoreclaim those without needing to index anything else. Can a single move fuction take conditional tokens and handle the auto reclaim? not sure thats possible in sui move? but still add that field.
- [x] Spot conditional amm router and quoter! Routes spot swap and quote through conditional tokens, auto recombines full set and also returns and excess conditional tokens left over
- [x] Make sure sequrity council have way to clean up account memory for intnets. Maybe should have sweep of delete intents thing they can sign????? idk come up with solutions for this, idealy hot path like with dao. but thing is security council are not foreced into proposasl like dao is, security counicil can kinda ignore stuff.

V2 hard bit:
- [x] Add in oracle to spot. Make it read able eg have proposal action / intent type to read oracle and if above certain price mint tokens to an address. Should be simple uniswap style oracle. need to somehow integrate with conditional amm winning market TWAP. As if we have back to back propoals using dao liquidity there is not spot price. Means winning market TWAP must be TWAP initialization price for next market otherwise need to twap or TWAP is biased.
OK lets have a TWAP oracle but for time when proposal was live fill in using my winning outcome twap. twap initialization price should be taking by reading spot TWAP!!!! Use uni v2 style twap for spot where spot trading is live. I already have conditonal twap fully working. Must wait 1 hour after lauching before first proposal to aoid twap manipulation too much!! Use simple uniswap or raydium AMM TWAP
- [x]  add ability launchpad and code to create dao with this rule embeded e.g mint Y tokens to z address if after X time, price or amm ratio > x. This gives founder option to get shae while still have saftey of 100% raise for launhcapd investors. Maybe this is a long lived pre approved intent that doesnt have a single execution intent can be retried multiple times.
- [x] make twap step cap at % of twap initialization price




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