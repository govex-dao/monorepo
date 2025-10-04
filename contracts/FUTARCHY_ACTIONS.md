# Futarchy & Move Framework Actions Reference

## Overview

This document catalogs **90+ governance actions** available in Futarchy DAOs, organized into:
- **Futarchy-Specific Actions** (19 categories) - Market-based governance, futarchy markets, DAO lifecycle
- **Move Framework Actions** (8 categories) - Treasury, tokens, transfers, upgrades, NFTs, vesting

### Key Architectural Patterns:

**1. Multi-Council Governance**
- DAOs can have specialized councils (Treasury, Technical, Legal, Emergency)
- Policy system controls which actions require which approvals
- 4 approval modes: DAO-only, Council-only, DAO-or-Council, DAO-and-Council

**2. PTB-Driven Execution**
- Actions return values (Coin<T>, objects) for composition
- No central dispatcher - PTBs orchestrate multi-step operations
- Hot potato patterns ensure atomic execution

**3. Dual-Layer Action System**
- **Construction Phase**: Build IntentSpec blueprints off-chain
- **Execution Phase**: Process actions via Executable hot potato
- Serialize-then-destroy pattern for all actions

**4. Time-Based Controls**
- Vesting schedules with cliff periods
- Streaming payments from vault
- Upgrade timelocks for security
- Policy change delays

**5. Economic Mechanisms**
- Quantum liquidity across conditional markets
- TWAP-based oracle automation (ConditionalMint, TieredMint)
- Dividend distributions with merkle trees
- Deposit escrow with refund-on-rejection

### Quick Find by Use Case:

**Treasury Management**: Vault Actions, Currency Actions, Dividend Actions
**Token Operations**: Currency Actions (mint/burn), Vesting Actions, Oracle Actions
**Payments**: Stream/Payment Actions, Dividend Distribution
**Upgrades**: Package Upgrade Actions, Policy Actions
**NFTs**: Kiosk Actions
**Legal**: DAO File System Actions, Operating Agreement Actions
**Security**: Policy Actions, Security Council Actions, Access Control Actions
**Lifecycle**: Dissolution Actions, Commitment Actions, Founder Lock Actions

---

## Configuration Actions
SetProposalsEnabled          - Toggle proposal creation on/off
UpdateName                    - Change DAO name
TradingParamsUpdate          - Modify AMM trading parameters
MetadataUpdate               - Update DAO metadata fields
TwapConfigUpdate             - Configure TWAP oracle settings
GovernanceUpdate             - Change governance parameters
MetadataTableUpdate          - Modify metadata key-value pairs
SlashDistributionUpdate      - Adjust slash fee distribution
QueueParamsUpdate            - Update proposal queue settings
ConfigAction                 - Bundle multiple config changes

## Quota Management Actions
SetQuotas                    - Set recurring proposal quotas for addresses (batch operation)
                              * quota_amount: N proposals per period (0 to remove)
                              * quota_period_ms: Period in milliseconds (e.g., 30 days)
                              * reduced_fee: Discounted fee for quota users

## Governance Actions
CreateProposal               - Create new futarchy proposal
CollectPlatformFee          - Collect fees for platform treasury

## Liquidity Actions
CreatePool                   - Create new AMM pool
AddLiquidity                 - Add tokens to AMM pool
RemoveLiquidity              - Remove tokens from AMM pool
UpdatePoolParams             - Modify pool parameters
SetPoolStatus                - Enable/disable pool trading
Swap                         - Execute AMM swap
CollectFees                  - Collect AMM trading fees
WithdrawFees                 - Withdraw collected fees

## Vault & Custody Actions
AddCoinType                  - Allow new coin in vault
RemoveCoinType               - Remove allowed coin from vault
ApproveCustody               - Approve asset custody transfer (creates custody request)
AcceptIntoCustody            - Accept asset into custody (fulfills custody request)
FulfillCustodyRequest        - Fulfill a custody resource request with actual assets

## Deposit Escrow Actions (User Deposits with Refund-on-Rejection)
AcceptDeposit                - Accept user's escrowed deposit into vault
                              * User deposits coins when creating intent (NOT an action)
                              * If proposal passes → AcceptDeposit executes → coins to vault
                              * If proposal fails → Crank function refunds depositor + gas reward to cranker
                              * Configurable gas reward by depositor
                              * Module: futarchy_vault::deposit_escrow

## Memo Actions
EmitMemo                     - Post text message on-chain
EmitDecision                 - Record governance decision

## Optimistic Actions
CreateOptimisticProposal     - Create challenge-based proposal
ChallengeOptimisticProposal  - Challenge optimistic proposal
ExecuteOptimisticProposal    - Execute after challenge period
ResolveChallenge             - Resolve challenge dispute
CreateOptimisticIntent       - Create optimistic intent
ChallengeOptimisticIntent    - Challenge optimistic intent
ExecuteOptimisticIntent      - Execute optimistic intent
CancelOptimisticIntent       - Cancel optimistic intent
CleanupExpiredIntents        - Remove expired intents

## Protocol Admin Actions
SetFactoryPaused             - Pause/unpause DAO creation
AddStableType                - Add accepted stable coin
RemoveStableType             - Remove stable coin type
UpdateDaoCreationFee         - Change DAO creation cost
UpdateProposalFee            - Change proposal cost
UpdateMonthlyDaoFee          - Update monthly maintenance fee
UpdateVerificationFee        - Change verification cost
AddVerificationLevel         - Add verification tier
RemoveVerificationLevel      - Remove verification tier
RequestVerification          - Request DAO verification
ApproveVerification          - Approve verification request
RejectVerification           - Reject verification request
SetDaoScore                  - Set DAO quality score
UpdateRecoveryFee            - Change recovery cost
WithdrawFeesToTreasury       - Collect protocol fees
ApplyDaoFeeDiscount          - Apply fee discount
AddCoinFeeConfig             - Add coin-specific fees
UpdateCoinMonthlyFee         - Change coin monthly fee
UpdateCoinCreationFee        - Change coin creation fee
UpdateCoinProposalFee        - Change coin proposal fee
UpdateCoinRecoveryFee        - Change coin recovery fee
ApplyPendingCoinFees         - Apply queued fee changes

## Founder Lock Actions (Lock Existing Tokens)
CreateFounderLockProposal          - Create token lock proposal with price tiers
ExecuteFounderLock                 - Execute lock based on market price
UpdateFounderLockRecipient         - Change lock beneficiary
WithdrawUnlockedTokens             - Claim tokens after unlock period

## Commitment Actions (Conditional Transfers)
CreateCommitmentProposal     - Create commitment to transfer assets if proposal passes
ExecuteCommitment            - Execute committed transfer after proposal passes
CancelCommitment             - Cancel commitment before execution
UpdateCommitmentRecipient    - Change commitment beneficiary
WithdrawCommitment           - Withdraw committed assets after execution

## DAO File System Actions (On-Chain Legal Documents)
CreateRegistry               - Initialize DAO file registry
SetRegistryImmutable         - Lock registry from changes
CreateRootDocument           - Create root-level document (e.g., "bylaws", "charter")
DeleteDocument               - Delete document from registry
AddChunk                     - Add content chunk to document
AddSunsetChunk               - Add chunk that expires after a date (auto-delete)
AddSunriseChunk              - Add chunk that becomes active after a date
AddTemporaryChunk            - Add chunk with both start and end dates
AddChunkWithScheduledImmutability - Add chunk that becomes immutable at a future date
UpdateChunk                  - Update existing chunk content
RemoveChunk                  - Remove chunk from document
SetChunkImmutable            - Lock chunk from changes
SetDocumentImmutable         - Lock entire document from changes
SetDocumentInsertAllowed     - Toggle chunk insertion permission
SetDocumentRemoveAllowed     - Toggle chunk removal permission

## Operating Agreement Actions (Legacy - Being Replaced by DAO File System)
CreateOperatingAgreement     - Initialize legal document
OperatingAgreement           - Process agreement changes
UpdateLine                   - Modify agreement text
InsertLineAfter              - Add line after specific line
InsertLineAtBeginning        - Add line at start
RemoveLine                   - Delete agreement line
SetLineImmutable             - Lock line from changes
SetInsertAllowed             - Toggle line insertion
SetRemoveAllowed             - Toggle line removal
SetGlobalImmutable           - Lock entire agreement
BatchOperatingAgreement      - Multiple agreement changes

## Oracle Actions (Mint New Tokens)
ConditionalMint              - Mint new tokens if price condition met (inflationary)
TieredMint                   - Milestone-based minting for founders/investors (inflationary)

## Stream/Payment Actions
CreatePayment                - Create one-time/recurring payment
CreateStream                 - Create continuous payment stream during DAO init
CreateBudgetStream           - Create budget-limited stream
CancelPayment                - Stop payment
CancelStream                 - Cancel stream
UpdatePaymentRecipient       - Change payment recipient
UpdateStream                 - Update stream parameters
AddWithdrawer                - Add payment withdrawer
AddPaymentBeneficiary        - Add additional beneficiary to payment stream
RemoveWithdrawers            - Remove payment withdrawers
TogglePayment                - Pause/resume payment
PausePayment                 - Pause payment stream
ResumePayment                - Resume paused payment stream
PauseStream                  - Pause stream temporarily
ResumeStream                 - Resume paused stream
WithdrawStream               - Withdraw from stream
RequestWithdrawal            - Request stream withdrawal
ChallengeWithdrawals         - Challenge withdrawal request
ProcessPendingWithdrawal     - Execute pending withdrawal
CancelChallengedWithdrawals  - Cancel challenged withdrawals
ExecutePayment               - Execute one-time payment
TransferPayment              - Transfer payment stream to new primary beneficiary
UpdatePaymentMetadata        - Update payment metadata
GetAllPaymentIds             - Get all payment IDs for dissolution
CancelAllPaymentsForDissolution - Cancel all payments for dissolution and return funds

## Dissolution Actions
InitiateDissolution          - Start DAO shutdown
BatchDistribute              - Distribute multiple assets
FinalizeDissolution          - Complete shutdown
CancelDissolution            - Abort shutdown process
CalculateProRataShares       - Calculate holder shares
CancelAllStreams             - Stop all payment streams
WithdrawAmmLiquidity         - Pull AMM liquidity
DistributeAssets             - Send assets to holders

## Policy Actions (Multi-Council Governance Control)

### Core Approval Modes (applies to all policy types):
- **MODE_DAO_ONLY (0)**: Only DAO governance can execute action
- **MODE_COUNCIL_ONLY (1)**: Only specified council can execute action
- **MODE_DAO_OR_COUNCIL (2)**: Either DAO or council approval works
- **MODE_DAO_AND_COUNCIL (3)**: Both DAO and council must approve (co-execution)

Each policy has TWO mode settings:
1. **Execution Mode**: Who can execute the action itself
2. **Change Mode**: Who can modify/remove this policy rule

### Policy Types:

**SetTypePolicy** - Set approval requirements for an action type (e.g., "VaultSpend requires Treasury Council")
  - *Parameters:* action_type, execution_council_id, execution_mode, change_council_id, change_mode, change_delay_ms
  - *Why useful:* Require specialized councils for sensitive operations (treasury, upgrades, legal docs)
  - *Example:* All vault spending requires Treasury Council approval (MODE_COUNCIL_ONLY)

**SetObjectPolicy** - Set approval requirements for a specific object (e.g., "this UpgradeCap requires Technical Council")
  - *Parameters:* object_id, execution_council_id, execution_mode, change_council_id, change_mode, change_delay_ms
  - *Why useful:* Object-specific controls override type-level rules, fine-grained security
  - *Example:* Main contract UpgradeCap requires Technical Council, experimental contract doesn't

**SetFilePolicy** - Set approval requirements for DAO file operations (e.g., "bylaws requires Legal Council")
  - *Parameters:* file_name (ASCII), execution_council_id, execution_mode, change_council_id, change_mode, change_delay_ms
  - *Why useful:* Protect critical legal documents from unauthorized edits
  - *Example:* Operating agreement changes require Legal Council review (MODE_DAO_AND_COUNCIL)

**RegisterCouncil** - Register new security council with the DAO
  - *Parameters:* council_id (ID of council Account)
  - *Why useful:* Add specialized councils (Treasury, Technical, Legal, Emergency) for domain expertise
  - *Example:* Add Treasury Council to review all >$10k spending proposals

**RemoveTypePolicy** - Remove type-based approval rule (reverts to default DAO-only)
  - *Parameters:* action_type
  - *Why useful:* Simplify governance by removing council requirements
  - *Validation:* Checks change_mode permissions from existing rule before removal

**RemoveObjectPolicy** - Remove object-specific approval rule (falls back to type-level or DAO-only)
  - *Parameters:* object_id
  - *Why useful:* Retire object-specific controls when no longer needed
  - *Validation:* Checks change_mode permissions from existing rule before removal

### Policy Change Authorization:
All policy changes validate permissions based on the EXISTING policy's change_mode:
- If change_mode=MODE_DAO_ONLY: Only DAO can modify/remove policy
- If change_mode=MODE_COUNCIL_ONLY: Only change_council can modify/remove policy
- If change_mode=MODE_DAO_OR_COUNCIL: Either can modify/remove policy
- If change_mode=MODE_DAO_AND_COUNCIL: Special co-execution required

### Timelock Protection:
All policy changes support `change_delay_ms` to prevent immediate malicious changes:
- Policy changes staged with delay (e.g., 7 days)
- Gives community time to review and challenge via governance
- Emergency councils can have 0 delay for rapid response

## Security Council Actions
UpdateCouncilMembership          - Change council members
UnlockAndReturnUpgradeCap        - Return upgrade capability to DAO
ApproveGeneric                   - Approve any action (OA changes, upgrade rules, policies, etc.)
SweepIntents                     - Clean expired intents from Security Council account
CouncilCreateOptimisticIntent    - Council creates optimistic intent
CouncilExecuteOptimisticIntent   - Council executes optimistic intent
CouncilCancelOptimisticIntent    - Council cancels optimistic intent

## Dividend Distribution Actions
CreateDividend               - Create dividend distribution using pre-built merkle tree
FulfillCreateDividend        - Fulfill dividend creation by providing coin from vault
ClaimMyDividend              - Individual user claims their own dividend
CrankDividend                - Anyone can call to crank out dividends to recipients
GetDividendInfo              - Get dividend distribution info
HasBeenSent                  - Check if recipient has been sent their dividend
GetAllocationAmount          - Get recipient's allocation amount

# Move Framework Actions

## Vault Actions (Treasury Management with Streaming)
**Deposit** - Deposit coins into named vault; validates amount matches intent spec (do_deposit)
  - *Why useful:* Enforce exact amounts on-chain, enable permissionless revenue deposits to existing coin types

**Spend** - Withdraw coins from vault; returns Coin<T> for PTB composition (do_spend)
  - *Why useful:* Treasury spending with governance approval, enables multi-step PTB transactions

**VaultStream** - Time-based vesting from vault with cliff/rate limits/multiple beneficiaries
  - *Why useful:* Salaries, grants, controlled withdrawals without full custody transfer

## Transfer Actions (Object Transfers)
**Transfer** - Transfer any object (key+store) to specified recipient (do_transfer)
  - *Why useful:* Move NFTs, capabilities, or any owned objects to another address

**TransferUnshared** - Transfer unshared objects during init (do_transfer_unshared)
  - *Why useful:* Distribute ClaimCaps or init artifacts to recipients atomically

**TransferToSender** - Transfer to tx sender (perfect for crank fees) (do_transfer_to_sender)
  - *Why useful:* Reward crankers who execute proposals/intents with gas reimbursement

## Currency Actions (TreasuryCap Management)
**Disable** - Permanently disable mint/burn/metadata update permissions (do_disable)
  - *Why useful:* Create fixed supply tokens, lock metadata, prevent future minting

**Mint** - Mint new tokens respecting max_supply rules; returns Coin<T> (do_mint)
  - *Why useful:* Controlled token emission, inflation schedules, rewards distribution

**Burn** - Burn tokens to reduce supply; validates amount matches coin value (do_burn)
  - *Why useful:* Deflationary mechanisms, remove tokens from circulation permanently

**Update** - Update coin metadata (symbol/name/description/icon_url) if enabled (do_update)
  - *Why useful:* Rebrand tokens, fix typos, update descriptions without redeployment

## Access Control Actions (Capability Borrowing)
**Borrow** - Temporarily borrow locked capability for use in PTB (do_borrow)
  - *Why useful:* Use admin capabilities within approved proposals without transferring ownership

**Return** - Return borrowed capability (hot potato ensures it's returned) (do_return)
  - *Why useful:* Enforced security - capability must be returned in same transaction

## Package Upgrade Actions (Smart Contract Upgrades with Timelock)
**Upgrade** - Upgrade package with digest; respects timelock delay (do_upgrade)
  - *Why useful:* Governed contract upgrades, prevent immediate malicious changes

**Commit** - Finalize upgrade after execution (do_commit)
  - *Why useful:* Complete the 2-phase upgrade process, activate new code

**Restrict** - Downgrade upgrade policy (e.g., mutable → immutable) (do_restrict)
  - *Why useful:* Progressively lock down contracts, eventual immutability

## Kiosk Actions (NFT Marketplace Primitives)
**Take** - Transfer NFT from DAO kiosk to another kiosk; returns TransferRequest (do_take)
  - *Why useful:* NFT transfers with royalty enforcement, managed NFT treasury

**List** - List NFT for sale at specified price in DAO's kiosk (do_list)
  - *Why useful:* Monetize DAO NFT holdings, automated revenue generation

## Vesting Actions (Standalone Token Locks)
**CreateVesting** - Lock tokens with cliff/vesting schedule/multiple beneficiaries (do_vesting)
  - *Why useful:* Employee vesting, investor lockups, time-based unlocks independent of vault

**CancelVesting** - Cancel vesting if cancellable; refunds unvested, pays vested
  - *Why useful:* Terminate employee vestings, recover unvested tokens for treasury

**ClaimVesting** - Withdraw vested tokens; respects rate limits and cliff periods
  - *Why useful:* Beneficiaries claim their unlocked tokens permissionlessly

**PauseVesting** - Temporarily pause vesting (extends end time by pause duration)
  - *Why useful:* Dispute resolution, investigation periods without losing tokens

**ResumeVesting** - Resume paused vesting with adjusted end time
  - *Why useful:* Continue vesting after resolving disputes or investigations

**TransferVesting** - Transfer primary beneficiary role if transferable
  - *Why useful:* Employee departures, beneficiary changes without canceling

**AddVestingBeneficiary** - Add additional withdrawal addresses (up to 100)
  - *Why useful:* Multi-signature withdrawal, team-shared vestings

**ReduceVestingAmount** - Reduce total_amount (cannot go below claimed)
  - *Why useful:* Adjust vesting schedules, correct over-allocations

## Owned Actions
*Note: Owned module provides base framework for object management - specific actions implemented in other modules*

---

## Action Index (Alphabetical)

**A**
- AcceptDeposit, AcceptIntoCustody, AddChunk, AddChunkWithScheduledImmutability, AddCoinFeeConfig, AddCoinType, AddLiquidity, AddPaymentBeneficiary, AddStableType, AddSunriseChunk, AddSunsetChunk, AddTemporaryChunk, AddVerificationLevel, AddVestingBeneficiary, AddWithdrawer, ApplyDaoFeeDiscount, ApplyPendingCoinFees, ApproveCustody, ApproveGeneric, ApproveVerification

**B**
- BatchDistribute, BatchOperatingAgreement, Borrow, Burn

**C**
- CalculateProRataShares, CancelAllPaymentsForDissolution, CancelAllStreams, CancelCommitment, CancelDissolution, CancelOptimisticIntent, CancelPayment, CancelStream, CancelVesting, ChallengeOptimisticIntent, ChallengeOptimisticProposal, ChallengeWithdrawals, ClaimMyDividend, ClaimVesting, CollectFees, CollectPlatformFee, Commit, ConditionalMint, ConfigAction, CouncilCancelOptimisticIntent, CouncilCreateOptimisticIntent, CouncilExecuteOptimisticIntent, CrankDividend, CreateBudgetStream, CreateCommitmentProposal, CreateDividend, CreateFounderLockProposal, CreateOperatingAgreement, CreateOptimisticIntent, CreateOptimisticProposal, CreatePayment, CreatePool, CreateProposal, CreateRegistry, CreateRootDocument, CreateStream, CreateVesting

**D**
- DeleteDocument, Deposit, Disable, DistributeAssets

**E**
- EmitDecision, EmitMemo, ExecuteCommitment, ExecuteFounderLock, ExecuteOptimisticIntent, ExecuteOptimisticProposal, ExecutePayment

**F**
- FinalizeDissolution, FulfillCreateDividend, FulfillCustodyRequest

**G**
- GetAllocationAmount, GetAllPaymentIds, GetDividendInfo, GovernanceUpdate

**H**
- HasBeenSent

**I**
- InitiateDissolution, InsertLineAfter, InsertLineAtBeginning

**L**
- List

**M**
- MetadataTableUpdate, MetadataUpdate, Mint

**O**
- OperatingAgreement

**P**
- PausePayment, PauseStream, PauseVesting, ProcessPendingWithdrawal

**Q**
- QueueParamsUpdate

**R**
- ReduceVestingAmount, RegisterCouncil, RejectVerification, RemoveChunk, RemoveCoinType, RemoveLine, RemoveObjectPolicy, RemoveStableType, RemoveTypePolicy, RemoveVerificationLevel, RemoveWithdrawers, RequestVerification, ResumePayment, ResumeStream, ResumeVesting, Restrict, Return

**S**
- SetChunkImmutable, SetDaoScore, SetDocumentImmutable, SetDocumentInsertAllowed, SetDocumentRemoveAllowed, SetFactoryPaused, SetFilePolicy, SetGlobalImmutable, SetInsertAllowed, SetLineImmutable, SetObjectPolicy, SetPoolStatus, SetProposalsEnabled, SetQuotas, SetRegistryImmutable, SetRemoveAllowed, SetTypePolicy, SlashDistributionUpdate, Spend, Swap, SweepIntents

**T**
- Take, TieredMint, TogglePayment, TradingParamsUpdate, Transfer, TransferPayment, TransferToSender, TransferUnshared, TransferVesting, TwapConfigUpdate

**U**
- UnlockAndReturnUpgradeCap, Update, UpdateChunk, UpdateCoinCreationFee, UpdateCoinMonthlyFee, UpdateCoinProposalFee, UpdateCoinRecoveryFee, UpdateCommitmentRecipient, UpdateCouncilMembership, UpdateDaoCreationFee, UpdateFounderLockRecipient, UpdateLine, UpdateMonthlyDaoFee, UpdateName, UpdatePaymentMetadata, UpdatePaymentRecipient, UpdatePoolParams, UpdateProposalFee, UpdateRecoveryFee, UpdateStream, UpdateVerificationFee

**V**
- Vesting

**W**
- WithdrawAmmLiquidity, WithdrawCommitment, WithdrawFeesToTreasury, WithdrawFees, WithdrawStream, WithdrawUnlockedTokens