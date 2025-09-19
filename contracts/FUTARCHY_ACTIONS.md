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
ConfigAction                 - Bundle multiple config changes

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

## Vault Actions
AddCoinType                  - Allow new coin in vault
RemoveCoinType               - Remove allowed coin from vault
ApproveCustody               - Approve asset custody transfer
AcceptIntoCustody            - Accept asset into custody

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

## Operating Agreement Actions
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
CreateStream                 - Create continuous payment stream
CreateBudgetStream           - Create budget-limited stream
CancelPayment                - Stop payment
CancelStream                 - Cancel stream
UpdatePaymentRecipient       - Change payment recipient
UpdateStream                 - Update stream parameters
AddWithdrawer                - Add payment withdrawer
RemoveWithdrawers            - Remove payment withdrawers
TogglePayment                - Pause/resume payment
PauseStream                  - Pause stream temporarily
ResumeStream                 - Resume paused stream
WithdrawStream               - Withdraw from stream
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
SetTypePolicy                - Set type-based rule
SetObjectPolicy              - Set object-specific rule
RegisterCouncil              - Register security council
RemoveTypePolicy             - Remove type-based rule
RemoveObjectPolicy           - Remove object-specific rule

## Security Council Actions
UpdateCouncilMembership      - Change council members
UnlockAndReturnUpgradeCap    - Return upgrade capability to DAO
ApproveGeneric               - Approve any action (OA changes, upgrade rules, policies, etc.)
SweepIntents                 - Clean expired intents
CouncilCreateOptimisticIntent    - Council creates optimistic intent
CouncilExecuteOptimisticIntent   - Council executes optimistic intent
CouncilCancelOptimisticIntent    - Council cancels optimistic intent

# Move Framework Actions

## Vault Actions
Deposit                      - Deposit coins into vault
Spend                        - Spend coins from vault

## Transfer Actions
Transfer                     - Transfer object ownership
TransferToSender             - Transfer object to sender

## Currency Actions
Disable                      - Disable currency (coin / token) operations
Mint                         - Mint new currency (coin / token)
Burn                         - Burn currency (coin / token)
Update                       - Update currency (coin / token) metadata

## Access Control Actions
Borrow                       - Borrow capability (safely use admin object)
Return                       - Return borrowed capability (safely use admin object)

## Package Upgrade Actions
Upgrade                      - Upgrade package
Commit                       - Commit upgrade
Restrict                     - Restrict upgrade policy

## Kiosk Actions
Take                         - Take item from kiosk (onchain selling primative)
List                         - List item in kiosk (onchain selling primative)

## Vesting Actions
CreateVesting                - Create vesting schedule
CancelVesting                - Cancel vesting schedule

## Configuration Actions
ConfigDeps                   - Update account dependencies
ToggleUnverifiedAllowed      - Toggle unverified packages allowed
ConfigureDeposits            - Configure object deposit settings
ManageWhitelist              - Manage type whitelist for deposits

## Owned Actions
Withdraw                     - Withdraw owned object