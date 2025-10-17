# Launchpad DAO Init Intent Refactor — Investigation & Plan

## 1. Context & Motivation
- **Current launchpad path** (`contracts/futarchy_factory/sources/factory/launchpad.move`) pre-creates an *unshared* DAO Account plus queue/pool and stores optional `InitActionSpecs` in the `Raise` object, but we never execute those specs on-chain. Finalization still depends on a PTB calling the raw `init_actions::*` helpers before the account is shared.
- **Governance proposals** already solve a similar problem: they store `InitActionSpecs`, synthesize an executable with `futarchy_governance_actions::governance_intents::create_and_store_intent_from_spec` (see `contracts/futarchy_governance/sources/execution/ptb_executor.move#L48`), and PTBs execute that hot potato. Execution is trustless because Move validates the stored bytes against their `TypeName`.
- We want launchpad creators to enjoy the same *trustless execution* and approval pipeline: stage intents while the account is unshared, let councils/validators approve them if required, and guarantee that the finalizer cannot alter parameters.
- Long term we want the same pattern available to plain factory deployments so auditors only need to understand one intent system.

## 2. Findings from the Codebase
### Launchpad
- `Raise` keeps `init_action_specs: Option<InitActionSpecs>` (`contracts/futarchy_factory/sources/factory/launchpad.move:285`) but we only extract it in `complete_raise_internal` and call the stub `init_actions::execute_init_intent_with_resources` (`launchpad.move:1503`).
- `init_actions::execute_init_intent_with_resources` is still a placeholder that emits an event (`contracts/futarchy_factory/sources/factory/init_actions.move:176`).
- `stage_init_actions` was removed; today there is no on-chain function that appends specs or intent keys after pre-creation.

### Governance / Intent System
- `account::create_intent` and `account::insert_intent` are available to our modules as long as we supply the config witness (`contracts/move-framework/packages/protocol/sources/account.move:520`).
- `create_and_store_intent_from_spec` already loops through an `InitActionSpecs`, converts each `ActionSpec` into the typed bytes the executable expects, and registers the intent on the Account (`contracts/futarchy_governance_actions/sources/governance/governance_intents.move:244`).
- `account::create_executable` plus the PTB macros ensure the executable’s action counter prevents tampering (`contracts/move-framework/packages/protocol/sources/account.move:547`).
- Policy enforcement uses the `TypeName` stored in the proposal itself; this aligns with the TypeName usage in `InitActionSpec`.

### Account Access
- The unshared DAO Account lives as a dynamic field under the `Raise` object, so only launchpad module code that has `&mut Raise` can touch it. This gives us a hook to stage intents safely.

## 3. Requirements (from discussion)
1. **Unified pipeline**: launchpad and factory both stage `InitActionSpecs` on the unshared account and execute them in a single pattern.
2. **Reuse existing logic**: lean on the audited governance intent pipeline rather than invent new serialization.
3. **On-chain enforcement**: execution should happen while the account is still unshared so a finalizer cannot alter parameters.
4. **Cleanup hooks**: failed flows must be able to cancel staged intents and return the DAO components safely.

## 4. Proposed Architecture
### High-Level Flow
1. **Pre-create DAO (unchanged)**: `pre_create_dao_for_raise` creates the Account/Queue/Pool and keeps them unshared.
2. **Stage init intents (new)**:
   - Expose a helper (e.g. `init_actions::stage_init_intent`) that:
     - borrows the unshared `Account<FutarchyConfig>` stored under the raise,
     - uses **ConfigActionsWitness** (existing witness) to establish intent provenance (no additional witness needed),
     - calls `init_actions::stage_init_intent` to keep serialization on-chain,
     - derives a deterministic intent key from the `TypeName` + launchpad raise id (e.g. `init_intent::{RaiseID}::{TypeName}::{counter}`) and stores only the corresponding `InitActionSpec` ordering in the raise (no ad-hoc strings).
   - Provide an optional `unstage_launchpad_intent` callable only before lock for error correction.
3. **Locking**: reuse `lock_intents_and_start_raise` to prevent further staging once the raise goes live.
4. **Approval**: because the intents reside in the Account, councils/policy modules can approve them before the raise completes (same flows as governance).
5. **Finalization (new)**: replace the stub call with:
   - Extract the staged specs (ordered vector) from the raise.
   - For each spec:
     - Derive the deterministic intent key, call `account::create_executable` (just like governance), and return the executable hot potato to the PTB.
     - The PTB uses the standard macro-driven flow (`account.build_intent!` / `process_intent!` pattern) to thread the executable through module-specific `do_*` calls—dynamic-ish dispatch exactly like proposal execution today. Move-side checks (action counter + `TypeName`) keep execution trustless.
     - After the PTB finishes routing all actions, call `account::confirm_execution` within Move and clean up the staged entry.
   - Abort if any executable still has remaining actions (defensive check); on abort revert raise and call cleanup helper (below).
6. **Cleanup**: after success, share the Account/Queue/Pool as today; after failure, call `cleanup_failed_raise_intents` which removes staged specs from the raise and deletes the corresponding intents from the Account before proceeding with existing failure handling.

### Data Model Changes
- Replace `init_action_specs` with `staged_init_specs: vector<InitActionSpec>` on `Raise` (single source of truth). Ordering acts as the deterministic intent index; keys are derived from `(raise_id, index, TypeName)` when we touch the account.
- Optional future extension: add metadata struct (description, staged_at) if needed for indexers (still type-driven).

### Factory (non-launchpad)
- Defer to follow-up. Once launchpad flow ships, mirror the same staging/execution helpers inside factory to keep behavior consistent.

## 5. Implementation Plan
1. **Add data structures**
   - Replace `init_action_specs` with `staged_init_specs: vector<InitActionSpec>` (preserving order); remove the unused field.
   - Introduce events `InitIntentStaged` / `InitIntentRemoved` (plus the batch-completion event in `init_actions`).
2. **Witness strategy**
   - Reuse `config_actions::ConfigActionsWitness` (or module-specific witnesses) when dispatching to `do_*` functions.
3. **Staging helpers**
   - Entry `stage_launchpad_init_intent` wraps `init_actions::stage_init_intent`, appending each spec to `staged_init_specs`; deterministic keys are derived from `(raise_id, index)` whenever the account APIs are invoked.
   - Provide `unstage_launchpad_init_intent` callable only while `intents_locked == false`, removing by index.
   - Validate limits using `launchpad_max_init_actions()` and prevent duplicates (by TypeName + params if necessary).
4. **Finalization executor**
   - Implement `init_actions::execute_init_intents(account, owner_id, specs, clock, ctx)` that:
     - Iterates the ordered specs, derives each intent key deterministically, and calls `account::create_executable` with that key.
     - Dispatches to the existing config action `do_*` handlers to mutate the account, then destroys the empty intent for cleanliness.
   - Replace `init_actions::execute_init_intent_with_resources` call in `complete_raise_internal` with this helper.
   - Delete the old stub in `init_actions.move`.
5. **Cleanup**
   - Add `cleanup_failed_raise_intents` invoked on launchpad failure paths to remove the staged specs and delete corresponding intents (using deterministic keys) from the Account.
   - Ensure `lock_intents_and_start_raise` guards both staging/removal entries; no legacy migration required because we drop the unused specs path entirely.
6. **Frontend / PTB updates**
   - Replace usage of `stage_init_actions` with `stage_launchpad_init_intent` / `init_actions::stage_init_intent`.
   - Ensure scripts capture the staged intent keys if needed for UI and wire PTBs to `create_dao_with_init_specs` for direct factory deployments.
7. **Testing**
   - Add Move tests covering:
     - Staging multiple intents and executing them during finalization successfully.
     - Finalization abort path when an intent’s action fails.
     - Removing an intent before locking.
     - Cleanup on failed raise clearing staged intents and account state.

## 6. Open Questions for the Team
- Should staging accept raw `InitActionSpecs`, or should we expose typed entry functions per action category for better UX?
- Do we need to support non-config modules (liquidity, streams) during launchpad init, and if so, which ones?
- How many intents should we allow per raise? (Current constant is `launchpad_max_init_actions()` = 20.)
- Confirm adoption in factory (`create_dao_with_init_specs`) and plan migration away from the legacy PTB-only path.
- How should we mark staged intents so that they’re easy to audit off-chain (key prefix, event index, etc.)? (Proposal: deterministic key derived from TypeName and index, e.g., `launchpad_init::{raise_id}::{type_module}::{type_name}::{index}`.)

## 7. Risks & Mitigations
- **Risk**: An intent could become invalid between staging and finalization (e.g., dependency removed).  
  *Mitigation*: `create_executable` will abort; surface the error, revert the raise, and expose `unstage_launchpad_init_intent` prior to locking.
- **Risk**: Large batches increase finalization gas.  
  *Mitigation*: enforce the existing init action cap and encourage creators to keep init batches small; consider chunking if needed.
- **Risk**: Frontend/PTB forgetting to stage intents before locking.  
  *Mitigation*: UI guard plus clear error when finalization finds no staged intents.

## 8. Next Steps
1. Align with the wider team on the open questions above.
2. Once confirmed, implement the staging + executor helpers and remove the obsolete init-action PTB functions.
3. Update backend/frontend PTBs to target the new entry points.
