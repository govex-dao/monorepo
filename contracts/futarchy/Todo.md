# Todo for V2
- [ ] Get summary of each file and make sure AIs stop getting tripped up
- [ ] Compare to other large quality move packages
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
- [ ] Sort out twap i itializatkon prices and handle spot oracle given 24 7 proposals if no spot trading dueot back to back proposals
- [ ] multiverse finance Token splitting? https://www.paradigm.xyz/2025/05/multiverse-finance
- [ ] Amm routing abstraction Redeeming condition toke redeem type dispatcher for burn or redeem winning
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