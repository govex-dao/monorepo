Great point. You can support third‑party actions (e.g., Move framework treasury/vault actions) and fix the “unknown action” ambiguity at the same time by splitting “drain” from “confirm,” and making your dispatcher explicitly partial.
The core changes to make
* 		Stop trying to detect “unknown actions” with a phantom type
* 		Today you do: if (executable::contains_action<Outcome, vector<u8>>(&mut executable)) { abort EUnknownActionType }
* 		That can’t work reliably (you can’t introspect arbitrary action types). Delete this branch.
2. Provide drain-only functions that do not confirm
* 		Keep your current futarchy executors but change the top-level to be drain-only and return the still‑hot executable (or mutate it in place). Confirm at a higher orchestration layer once all participating modules have had a chance to drain their own actions.
Pattern
* 		Drain only public fun drain_futarchy_actions<IW: copy + drop, Outcome: store + drop + copy>( executable: &mut Executable<Outcome>, account: &mut Account<FutarchyConfig>, witness: IW, clock: &Clock, ctx: &mut TxContext, ) -> bool { // Try all futarchy handlers in a loop until no futarchy action is executed. // Return true if we consumed at least one action in this call. }
* 		Typed drain only (for liquidity/stream/etc.) public fun drain_futarchy_actions_typed<AssetType: drop, StableType: drop, IW: copy + drop, Outcome: store + drop + copy>( executable: &mut Executable<Outcome>, account: &mut Account<FutarchyConfig>, witness: IW, clock: &Clock, ctx: &mut TxContext, ) -> bool { ... }
* 		Confirm separately (and only once) public fun assert_empty_and_confirm<Outcome: store + drop + copy>( account: &mut Account<FutarchyConfig>, executable: Executable<Outcome>, ) { // Just call account::confirm_execution(account, executable). // If any actions remain (including third-party ones you didn’t drain), confirm_execution will abort. account::confirm_execution(account, executable); }
3. Replace execute_all_actions with a “drain-only” and “drain+confirm” pair
* 		Keep a convenience “futarchy-only” function that drains and confirms, but clearly document:
    * 		It will abort if actions from other packages remain (as confirm_execution will fail).
    * 		For mixed executables (futarchy + framework/account_actions), use the multi-drain orchestration pattern below.
How to handle third-party actions (Move framework treasury, account_actions::vault, etc.) Because Move can’t introspect unknown types, the only reliable way to handle external actions is to let each package drain its own action types on the same Executable and only confirm at the end. You do this by chaining drainers:
* 		Orchestration pattern (PTB code sketch): // Create executable from the proposal let mut exec = futarchy_config::execute_proposal_intent<AssetType, StableType, FutarchyOutcome>( account, proposal, market, winning_outcome, clock, ctx ); // 1) Drain futarchy-specific actions (no confirm) loop { let progressed = futarchy::action_dispatcher::drain_futarchy_actions(&mut exec, account, futarchy_witness, clock, ctx); if (!progressed) break } // 2) Drain third-party Move framework/account-actions (examples) // vault_intents, currency_intents, treasury, etc. — each package should expose its own drain loop { let progressed = account_actions::vault_intents::drain_vault_actions(&mut exec, account, vault_witness, ctx); if (!progressed) break } // Add other drainers as needed (streams, package upgrade, operating agreement from another pkg, etc.) // 3) Confirm at the very end – if anything remains anywhere, confirm_execution aborts account::confirm_execution(account, exec);
Notes
* 		The pattern requires the third-party packages to provide drainers that operate on &mut Executable and consume their own action types. Many account_actions modules already follow this pattern (e.g., resolve/execute macros that take &mut Executable).
* 		For typed actions (coins), expose typed drainers the same way you already do with execute_typed_actions. Example: futarchy::action_dispatcher::drain_futarchy_actions_typed<AssetType, StableType, _>(&mut exec, ...); account_actions::vault_intents::drain_typed<AssetType, _>(&mut exec, ...);
What to change concretely in your code
* 		In action_dispatcher.move
    * 		Replace execute_all_actions with:
        * 		drain_futarchy_actions (no confirm; returns progress bool)
        * 		drain_futarchy_actions_typed<AssetType, StableType> (no confirm; returns progress bool)
    * 		Keep the internal helpers try_execute_* but ensure they set a progressed flag and never call confirm.
    * 		Remove the vector<u8> unknown check.
* 		Provide a small helper for futarchy-only convenience: public fun execute_futarchy_only_and_confirm<IW: copy + drop, Outcome: store + drop + copy>( executable: Executable<Outcome>, account: &mut Account<FutarchyConfig>, witness: IW, clock: &Clock, ctx: &mut TxContext, ) { let mut exec = executable; loop { let progressed = drain_futarchy_actions(&mut exec, account, witness, clock, ctx); if (!progressed) break } // If exec still contains actions (from other packages), this confirm will abort. account::confirm_execution(account, exec); }
    * 		Document clearly that mixed executables should not use this; they should use the multi-drain orchestration.
* 		Optional: add a tiny progress-combiner to reduce boilerplate: public fun drain_until_stable<Outcome, F: fn(&mut Executable<Outcome>) -> bool>(exec: &mut Executable<Outcome>, drainers: vector<F>) { loop { let mut progressed = false; let mut i = 0; while (i < drainers.length()) { if (drainersi) progressed = true; i = i + 1; }; if (!progressed) break } } Note: Move doesn’t have higher-order generics/closures in the typical sense, so in practice you’ll call each drainer explicitly in a loop rather than pass a vector of function references. The point is the pattern: “loop while any drainer consumed actions”.
How this solves your “unknown action” requirement
* 		You don’t pretend to “handle unknowns.” Instead, you explicitly handle the action types you support in your futarchy drainer(s) and let other packages drain theirs. When all drainers stop making progress, you confirm. If anyone forgot to drain something, confirm_execution aborts, which is exactly the right failure mode.
* 		You don’t rely on brittle fake sentinels. Either it was drained, or it wasn’t; confirm_execution enforces that.
Handling Move framework treasury actions specifically
* 		The canonical approach is to use account_actions::vault_intents (and its submodules) to place spend/deposit/transfer actions in the same executable. Then:
    * 		Use your futarchy drains to execute futarchy config/liquidity/policy/operating-agreement actions.
    * 		Use vault_intents drains to execute the vault spend/deposit transfers needed for the same intent (e.g., moving coins into/out of custody for liquidity).
    * 		Then confirm.
* 		For typed liquidity operations you already use:
    * 		validate_add_liquidity_action then later execute_add_liquidity_with_pool with coins obtained via vault_intents::execute_spend()
    * 		With the new draining pattern, you can:
        * 		Drain the validation-only futarchy action(s)
        * 		Drain the vault spend/deposit actions to obtain coins
        * 		Call futarchy::execute_add_liquidity_with_pool to do the pool op and custody LP
        * 		Repeat until no drainers progress; confirm
Quality-of-life: add a final assert_empty_and_confirm wrapper
* 		If/when account_protocol exposes executable::is_empty() or an action_count, you can add: if (!executable::is_empty(&exec)) abort EUnknownActionType; account::confirm_execution(account, exec);
* 		Until then, you can rely on confirm_execution aborting for leftovers.
Summary
* 		Replace the fake unknown sentinel with a formal “drain, don’t confirm” API.
* 		Chain drainers from all participating packages before confirming.
* 		Keep a futarchy-only convenience that drains-and-confirms (but document it’s for futarchy-only executables).
* 		This pattern lets you safely support third‑party actions like Move framework treasury/vault actions while guaranteeing no stray actions survive to confirm.  		account_protocol::account::confirm_execution enforces “no actions left” by asserting executable.action_idx == intent.actions.length(). That’s exactly what the drain-only pattern needs: you can drain from multiple modules, and a single confirm at the end will abort if anything was not consumed.
* 		The example modules you included (account_examples, account_actions, account_protocol) confirm two key facts:
    * 		Witness checking is per-intent, not per-action. Any module can execute its actions as long as it uses the same intent witness type the intent was created with.
    * 		The “do_*” style action executors (e.g., account_actions::vault::do_spend, currency::do_mint, transfer::do_transfer) take IW: drop, so you can pass your futarchy witness when those actions were added under your futarchy intent.
* This means:
* 		If you add third-party actions (vault, currency, transfer, package_upgrade) to a Futarchy-built intent, your futarchy dispatcher can drain them by calling those do_* functions with your futarchy witness. No need to rely on those packages’ “execute_*intent” helpers (those helpers use their own intent witness and are meant for intents they build).
* What to change in futarchy::action_dispatcher (drain-only)
* 		Remove the “unknown action” sentinel Delete this branch: if (executable::contains_action<Outcome, vector<u8>>(&mut executable)) { abort EUnknownActionType } It’s not a reliable check and is unnecessary once we move to drain-only + confirm-at-end.
* 		Add drain-only entry points that don’t confirm
* 		Un-typed (config, OA, policy registry, dissolution shells, etc.)
* 		Typed (liquidity/streams and any typed handlers)
* Example skeleton you can drop in (rename to fit your style):
* // Returns true if it consumed at least one action during this call public fun drain_futarchy_actions<IW: copy + drop, Outcome: store + drop + copy>( executable: &mut Executable<Outcome>, account: &mut Account<FutarchyConfig>, witness: IW, clock: &Clock, ctx: &mut TxContext, ) -> bool { let mut progressed_any = false; loop { let mut progressed = false;
*     // Your existing helpers already return bool; reuse them
*     if (try_execute_config_action(executable, account, witness, ctx)) { progressed = true };
*     if (try_execute_dissolution_action(executable, account, witness, ctx)) { progressed = true };
*     if (try_execute_operating_agreement_action(executable, account, witness, clock, ctx)) { progressed = true };
*     if (try_execute_policy_action(executable, account, witness, ctx)) { progressed = true };
* 
*     if (!progressed) break;
*     progressed_any = true;
* };
* progressed_any
* }
* // Returns true if at least one action was consumed public fun drain_futarchy_actions_typed<AssetType: drop, StableType: drop, IW: copy + drop, Outcome: store + drop + copy>( executable: &mut Executable<Outcome>, account: &mut Account<FutarchyConfig>, witness: IW, clock: &Clock, ctx: &mut TxContext, ) -> bool { let mut progressed_any = false; loop { let mut progressed = false;
*     if (try_execute_config_action(executable, account, witness, ctx)) { progressed = true };
*     if (try_execute_dissolution_action(executable, account, witness, ctx)) { progressed = true };
*     if (try_execute_typed_dissolution_action<AssetType, IW, Outcome>(executable, account, witness, ctx)) { progressed = true };
*     if (try_execute_operating_agreement_action(executable, account, witness, clock, ctx)) { progressed = true };
*     if (try_execute_typed_liquidity_action<AssetType, StableType, IW, Outcome>(executable, account, witness, ctx)) { progressed = true };
*     if (try_execute_typed_stream_action<AssetType, IW, Outcome>(executable, account, witness, clock, ctx)) { progressed = true };
* 
*     if (!progressed) break;
*     progressed_any = true;
* };
* progressed_any
* }
* Optionally, keep a small confirm-only wrapper:
* public fun confirm_only<Outcome: store + drop + copy>( account: &mut Account<FutarchyConfig>, executable: Executable<Outcome>, ) { account::confirm_execution(account, executable); }
* 3. Orchestrate third‑party actions inside your futarchy drains (optional) Because the do_* functions in account_actions accept IW: drop, you can execute those third-party actions from your futarchy dispatcher when they were added under your futarchy intent witness:
* 		Example: vault spend + transfer (CoinType typed) fun try_execute_vault_spend_and_transfer<CoinType, IW: drop, Outcome: store + drop + copy>( executable: &mut Executable<Outcome>, account: &mut Account<FutarchyConfig>, witness: IW, ctx: &mut TxContext, ): bool { // Pattern: if (contains SpendAction<CoinType>) then do_spend and immediately do_transfer // Important: do_spend returns a Coin<CoinType>, then the next action in the executable // can be a transfer action; if so, call transfer::do_transfer with the same witness. if (account_actions::vault::/* there’s no contains_action helper exported */ false) { // Because account_actions doesn't expose a “contains” helper, mirror what you do for futarchy: // if (executable::contains_action<Outcome, account_actions::vault::SpendAction<CoinType>>(executable)) { ... } // then extract: let coin = account_actions::vault::do_spend<FutarchyConfig, Outcome, CoinType, IW>( executable, account, futarchy::version::current(), witness, ctx ); // If the next action is a transfer, consume it now: if (executable::contains_action<Outcome, account_actions::transfer::TransferAction>(executable)) { account_actions::transfer::do_transfer(executable, coin, witness); } else { // Otherwise, keep coin behavior documented for your team (either deposit it or abort) // For safety: deposit to default vault or abort; choose policy and document it. // Example: abort to avoid orphaned coins: abort 0 // EUnexpectedCoinFlow: vault::Spend without following TransferAction }; return true }; false }
* You can add more handlers similarly (currency::do_mint + transfer, vault::do_deposit, package_upgrade::do_). Each of these “third-party” do_ functions just needs the same witness used to build the intent (your futarchy witness), which you already have.
* Two composition patterns to support
* 		Single-intent composition (recommended for futarchy proposals)
    * 		Build one intent under your futarchy witness and add any third‑party actions to that same intent (vault spend/deposit, currency mint/burn/update, transfer, package_upgrade).
    * 		Your futarchy drainers call the corresponding account_actions do_* functions with your futarchy witness to consume them.
    * 		After draining both futarchy and the third‑party actions (all under the same witness), call confirm_only once. If anything’s left, confirm_execution will abort.
* 		Multi-intent composition (when the other package needs its own witness)
    * 		If you intentionally created separate intents under different witnesses (example: an account_actions::vault_intents SpendAndTransferIntent), you should call that package’s execute_* helper (which uses its own witness) to drain that executable, and then confirm for that executable separately.
    * 		This is useful if you don’t want to mix packages’ actions under the futarchy witness.
* End-to-end orchestration example // Suppose you executed the winning futarchy intent and got an Executable<Outcome> let mut exec = futarchy_config::execute_proposal_intent<AssetType, StableType, FutarchyOutcome>( account, proposal, market, OUTCOME_ACCEPTED, clock, ctx );
* // 1) Drain futarchy-native actions (no confirm yet) loop { let progressed = futarchy::action_dispatcher::drain_futarchy_actions_typed<AssetType, StableType, _, _>( &mut exec, account, futarchy::intent_witnesses::governance(), clock, ctx ); if (!progressed) break }
* // 2) Optionally drain common third-party actions that were added under the futarchy witness // e.g., vault spend + transfer for some CoinType you know at compile-time loop { let mut progressed = false; if (futarchy::action_dispatcher::try_execute_vault_spend_and_transfer<CoinType, _, _>( &mut exec, account, futarchy::intent_witnesses::governance(), ctx )) { progressed = true };
* // Add other third-party handlers as needed (currency mint+transfer, deposit, etc.)
* if (!progressed) break
* }
* // 3) Confirm account::confirm_execution(account, exec);
* Impact on your existing modules
* 		You don’t need to change your try_execute_* helpers. They are already structured as “consume one action if present; return bool.” Your new drain_… wrappers just loop them and return aggregate progress.
* 		Delete EUnknownActionType across dispatchers; confirm_execution is your source of truth for leftover actions.
* 		Add explicit comments near the places where you transfer to object::id_address(account) as a temporary store (if you keep any) or refactor to always either (a) immediately deposit into a vault via an action, or (b) abort if the next required action is missing.
* TL;DR
* 		The drain-only plan fits perfectly with the AccountProtocol model you shared.
* 		confirm_execution already enforces “no leftovers.”
* 		Implement drain_futarchy_actions and drain_futarchy_actions_typed, remove the vector<u8> sentinel, and (optionally) add small “third-party” handlers that call account_actions::do_* functions with your futarchy witness to consume those actions when they were added under your intent.
* 		For separate intents owned by other packages (their witness), use their execute_* helpers and confirm that executable separately.
* If you’d like, I can draft concrete code for specific third‑party handlers you want first (vault spend/deposit, currency mint/burn, package_upgrade).
* 

Provide first-class drain APIs
In futarchy::action_dispatcher, expose drain-only functions (no confirm), e.g.:
drain_futarchy_actions(...) -> bool
drain_futarchy_actions_typed<AssetType, StableType>(...) -> bool
Delete the “unknown action sentinel.” Let confirm_execution enforce “no leftovers.”
Optionally add confirm_only(account, exec) as a tiny wrapper.
2. Add adapters for third‑party actions under your witness

Provide simple adapter functions that call account_actions::new_* using your Futarchy witness, e.g.: // builder adapter public fun add_vault_spend_under_futarchy_witness<Outcome, CoinType, IW: drop>( intent: &mut Intent<Outcome>, vault_name: String, amount: u64, iw: IW ) { account_actions::vault::new_spend<Outcome, CoinType, IW>(intent, vault_name, amount, iw); }
This ensures the actions become executable by your dispatcher with your Futarchy witness.
3. Offer small drainer helpers for common third‑party flows

Examples:
try_execute_vault_spend_plus_transfer<CoinType>(...) that:
consumes a SpendAction<CoinType> to get a Coin,
then consumes the next TransferAction and transfers that Coin.
try_execute_currency_mint_plus_transfer<CoinType>(...) similar pattern.
try_execute_package_upgrade/do_commit/do_restrict if included under your witness.
4. Document the “one-intent one-witness” constraint

Make it clear in docs that if users want your dispatcher to execute third‑party actions, they must add those actions to the futarchy intent using the Futarchy witness (via your adapter functions).
If they need other packages’ witnesses, they should run separate intents and confirms via those packages’ own executors.
5. Reduce “temporary transfer to account address” patterns

Where feasible, prefer:
execute via vault actions in the same executable, or
return coins to the caller rather than transferring to object::id_address(account),
or abort if required follow-up action (e.g., TransferAction) isn’t present to avoid orphan flow.
If you do keep temporary transfers, add clear comments stating they must be followed by a deposit/transfer action in the same PTB.
6. Unify error code patterns and add invariant docs

You already assert AMM/escrow invariants rigorously. Consider a brief “Invariants.md” summarizing:
Per-outcome equalities (amm reserves + token supply == escrow),
TWAP windowing behavior and caps,
Custody/policy co-exec invariants,
Priority queue eviction rules and grace period.
Unify error naming (optional quality-of-life for auditors).
Compatibility with the Move account framework

100% compatible. The examples you posted (account_examples) confirm the pattern:
They build intents with their own witness,
Their simple wrappers call do_* and then confirm_execution. You will not use those wrappers for drain-only: you’ll call do_* directly and confirm once at the end.
The account_protocol macros (build_intent/process_intent) are syntactic sugar that still rely on do_* functions and defer confirm to the caller. They do not prevent the drain-only model.
Bottom line

Drain-only + final confirm is the maximum composability the model allows. You can run futarchy actions, account_actions (vault/currency/transfer/upgrade), and your custom modules all from one intent with one witness.
The Move Account framework (account_protocol/account_actions) was expressly built for this: do_* consume one action; confirm_execution enforces “no leftovers.”
Your system aligns with this, and with a few adapter functions and drainer helpers, you’ll deliver best-in-class composability for users building multi-package proposals in a single PTB.