# Futarchy & Move Framework Actions Reference

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
ConfigBatch                  - Bundle multiple config changes

## Governance Actions
CreateProposal               - Create new futarchy proposal
CollectPlatformFee          - Collect fees for platform treasury

## Liquidity Actions
AddLiquidity                 - Add tokens to AMM pool
RemoveLiquidity              - Remove tokens from AMM pool
CreatePool                   - Create new AMM pool
UpdatePoolParams             - Modify pool parameters
SetPoolStatus                - Enable/disable pool trading

## Vault Actions
AddCoinType                  - Allow new coin in vault
RemoveCoinType               - Remove allowed coin from vault

## Memo Actions
EmitMemo                     - Post text message on-chain
EmitDecision                 - Record accept/reject decision

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

## Operating Agreement Actions
CreateOperatingAgreement     - Initialize legal document
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
ReadOraclePrice              - Get TWAP price from oracle
ConditionalMint              - Mint new tokens if price condition met (inflationary)
TieredMint                   - Milestone-based minting for founders/investors (inflationary)

## Stream/Payment Actions
CreatePayment                - Create one-time/recurring payment
CreateBudgetStream           - Create budget-limited stream
CancelPayment                - Stop payment stream
UpdatePaymentRecipient       - Change payment recipient
AddWithdrawer                - Add payment withdrawer
RemoveWithdrawers            - Remove payment withdrawers
TogglePayment                - Pause/resume payment
RequestWithdrawal            - Request stream withdrawal
ChallengeWithdrawals         - Challenge withdrawal request
ProcessPendingWithdrawal     - Execute pending withdrawal
CancelChallengedWithdrawals  - Cancel challenged withdrawals
ExecutePayment               - Execute one-time payment

## Dissolution Actions
InitiateDissolution          - Start DAO shutdown
BatchDistribute              - Distribute multiple assets
FinalizeDissolution          - Complete shutdown
CancelDissolution            - Abort shutdown process
CalculateProRataShares       - Calculate holder shares
CancelAllStreams             - Stop all payment streams
WithdrawAmmLiquidity         - Pull AMM liquidity
DistributeAssets             - Send assets to holders

## Policy Actions
SetPatternPolicy             - Set pattern-based rule
SetObjectPolicy              - Set object-specific rule
RegisterCouncil              - Register security council
SetTypePolicy                - Set type-based rule
PackageUpgrade               - Upgrade package code
VaultMint                    - Mint from vault
RemovePatternPolicy          - Remove pattern rule
RemoveObjectPolicy           - Remove object rule

## Security Council Actions
CreateSecurityCouncil        - Create council account
ApproveOAChange              - Approve agreement change
UpdateUpgradeRules           - Modify upgrade policy
UpdateCouncilMembership      - Change council members
UnlockAndReturnUpgradeCap    - Return upgrade capability
ApproveGeneric               - Approve any action
SweepIntents                 - Clean expired intents
CouncilCreateOptimisticIntent    - Council creates optimistic intent
CouncilExecuteOptimisticIntent   - Council executes optimistic intent
CouncilCancelOptimisticIntent    - Council cancels optimistic intent

## Custody Actions
ApproveCustody               - Approve custody transfer
AcceptIntoCustody            - Accept asset custody

## Dispatcher Registry Actions
RegisterActionType           - Register action handler
UnregisterActionType         - Remove action handler
BatchRegisterActionTypes     - Register multiple handlers
UpdateHandlerConfig          - Update handler settings

# Move Framework Actions

## Vault Actions
VaultDeposit                 - Deposit coins into vault
VaultSpend                   - Spend coins from vault

## Transfer Actions
TransferObject               - Transfer object ownership

## Currency Actions
CurrencyLockCap              - Lock treasury cap for future use
CurrencyDisable              - Disable currency operations
CurrencyMint                 - Mint new currency
CurrencyBurn                 - Burn currency
CurrencyUpdate               - Update currency metadata

## Access Control Actions
AccessControlStore           - Store/lock capability
AccessControlBorrow          - Borrow capability
AccessControlReturn          - Return borrowed capability

## Package Upgrade Actions
PackageUpgrade               - Upgrade package
PackageCommit                - Commit upgrade
PackageRestrict              - Restrict upgrade policy

## Kiosk Actions
KioskTake                    - Take item from kiosk
KioskList                    - List item in kiosk

## Vesting Actions
VestingCreate                - Create vesting schedule
VestingCancel                - Cancel vesting schedule

## Configuration Actions
ConfigUpdateDeps             - Update account dependencies
ConfigToggleUnverified       - Toggle unverified packages allowed
ConfigUpdateMetadata         - Update account metadata
ConfigUpdateDeposits         - Configure object deposit settings
ConfigManageWhitelist        - Manage type whitelist for deposits

## Owned Actions
OwnedWithdraw                - Withdraw owned object