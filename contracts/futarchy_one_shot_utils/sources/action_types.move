/// Pure type definitions for all Futarchy action types
/// This module has NO dependencies and defines ONLY types (no logic)
/// Both Move Framework and Futarchy packages can import these types
module futarchy_utils::action_types {
    // NO IMPORTS - This is critical to avoid circular dependencies
    
    // ======== Configuration Actions ========
    
    /// Enable or disable proposal creation
    public struct SetProposalsEnabled has drop {}
    
    /// Update DAO name
    public struct UpdateName has drop {}
    
    /// Update trading parameters
    public struct TradingParamsUpdate has drop {}
    
    /// Update DAO metadata
    public struct MetadataUpdate has drop {}
    
    /// Update TWAP configuration
    public struct TwapConfigUpdate has drop {}
    
    /// Update governance settings
    public struct GovernanceUpdate has drop {}
    
    /// Update metadata table entries
    public struct MetadataTableUpdate has drop {}
    
    /// Update slash distribution percentages
    public struct SlashDistributionUpdate has drop {}
    
    /// Update queue parameters
    public struct QueueParamsUpdate has drop {}
    
    /// Batch config action wrapper
    public struct ConfigBatch has drop {}
    
    // ======== Governance Actions ========
    
    /// Create a new proposal
    public struct CreateProposal has drop {}
    
    /// Collect platform fees
    public struct CollectPlatformFee has drop {}
    
    // ======== Liquidity Actions ========
    
    /// Add liquidity to AMM pool
    public struct AddLiquidity has drop {}
    
    /// Remove liquidity from AMM pool
    public struct RemoveLiquidity has drop {}
    
    /// Create new AMM pool
    public struct CreatePool has drop {}
    
    /// Update pool parameters
    public struct UpdatePoolParams has drop {}
    
    /// Set pool status (active/paused)
    public struct SetPoolStatus has drop {}
    
    // ======== Vault Governance Actions ========
    
    /// Add allowed coin type to vault
    public struct AddCoinType has drop {}
    
    /// Remove allowed coin type from vault
    public struct RemoveCoinType has drop {}
    
    // ======== Memo Actions ========

    /// Emit simple text memo
    public struct EmitMemo has drop {}

    /// Emit accept/reject decision with reason
    public struct EmitDecision has drop {}
    
    // ======== Optimistic Actions ========
    
    /// Create optimistic proposal
    public struct CreateOptimisticProposal has drop {}
    
    /// Challenge optimistic proposal
    public struct ChallengeOptimisticProposal has drop {}
    
    /// Execute optimistic proposal
    public struct ExecuteOptimisticProposal has drop {}
    
    /// Resolve challenge
    public struct ResolveChallenge has drop {}
    
    /// Create optimistic intent
    public struct CreateOptimisticIntent has drop {}
    
    /// Challenge optimistic intent
    public struct ChallengeOptimisticIntent has drop {}
    
    /// Execute optimistic intent
    public struct ExecuteOptimisticIntent has drop {}
    
    /// Cancel optimistic intent
    public struct CancelOptimisticIntent has drop {}
    
    /// Cleanup expired intents
    public struct CleanupExpiredIntents has drop {}
    
    // ======== Protocol Admin Actions ========
    
    /// Pause/unpause factory
    public struct SetFactoryPaused has drop {}
    
    /// Add stable type to factory
    public struct AddStableType has drop {}
    
    /// Remove stable type from factory
    public struct RemoveStableType has drop {}
    
    /// Update DAO creation fee
    public struct UpdateDaoCreationFee has drop {}
    
    /// Update proposal creation fee
    public struct UpdateProposalFee has drop {}
    
    /// Update monthly DAO fee
    public struct UpdateMonthlyDaoFee has drop {}
    
    /// Update verification fee
    public struct UpdateVerificationFee has drop {}
    
    /// Add verification level
    public struct AddVerificationLevel has drop {}
    
    /// Remove verification level
    public struct RemoveVerificationLevel has drop {}

    /// Request verification for DAO
    public struct RequestVerification has drop {}

    /// Approve DAO verification
    public struct ApproveVerification has drop {}

    /// Reject DAO verification
    public struct RejectVerification has drop {}

    /// Update recovery fee
    public struct UpdateRecoveryFee has drop {}
    
    /// Withdraw fees to treasury
    public struct WithdrawFeesToTreasury has drop {}
    
    /// Apply DAO fee discount
    public struct ApplyDaoFeeDiscount has drop {}
    
    /// Add coin-specific fee config
    public struct AddCoinFeeConfig has drop {}
    
    /// Update coin monthly fee
    public struct UpdateCoinMonthlyFee has drop {}
    
    /// Update coin creation fee
    public struct UpdateCoinCreationFee has drop {}
    
    /// Update coin proposal fee
    public struct UpdateCoinProposalFee has drop {}
    
    /// Update coin recovery fee
    public struct UpdateCoinRecoveryFee has drop {}
    
    /// Apply pending coin fees
    public struct ApplyPendingCoinFees has drop {}
    
    // ======== Founder Lock Actions ========

    /// Create founder lock proposal
    public struct CreateFounderLockProposal has drop {}

    /// Execute founder lock
    public struct ExecuteFounderLock has drop {}

    /// Update founder lock recipient
    public struct UpdateFounderLockRecipient has drop {}

    /// Withdraw unlocked tokens
    public struct WithdrawUnlockedTokens has drop {}
    
    // ======== Operating Agreement Actions ========
    
    /// Create operating agreement
    public struct CreateOperatingAgreement has drop {}
    
    /// Update operating agreement line
    public struct UpdateLine has drop {}
    
    /// Insert line after specific line
    public struct InsertLineAfter has drop {}
    
    /// Insert line at beginning
    public struct InsertLineAtBeginning has drop {}
    
    /// Remove line from agreement
    public struct RemoveLine has drop {}
    
    /// Set line as immutable
    public struct SetLineImmutable has drop {}
    
    /// Set whether inserts are allowed
    public struct SetInsertAllowed has drop {}
    
    /// Set whether removals are allowed
    public struct SetRemoveAllowed has drop {}
    
    /// Set entire agreement as immutable
    public struct SetGlobalImmutable has drop {}
    
    /// Batch operating agreement actions
    public struct BatchOperatingAgreement has drop {}
    
    // ======== Oracle Actions ========

    /// Read oracle price
    public struct ReadOraclePrice has drop {}

    /// Conditional mint based on oracle
    public struct ConditionalMint has drop {}

    /// Tiered mint based on milestones
    public struct TieredMint has drop {}

    // ======== Option Grant Actions ========

    /// Create option grant with strike price
    public struct CreateOptionGrant has drop {}

    /// Create token grant with vesting
    public struct CreateTokenGrant has drop {}

    /// Exercise vested options
    public struct ExerciseOptions has drop {}

    /// Claim vested tokens
    public struct ClaimVestedTokens has drop {}

    /// Cancel grant (by DAO)
    public struct CancelGrant has drop {}
    
    // ======== Stream/Payment Actions ========
    
    /// Create one-time or recurring payment
    public struct CreatePayment has drop {}
    
    /// Create budget stream
    public struct CreateBudgetStream has drop {}
    
    /// Cancel payment
    public struct CancelPayment has drop {}
    
    /// Update payment recipient
    public struct UpdatePaymentRecipient has drop {}
    
    /// Add withdrawer to payment
    public struct AddWithdrawer has drop {}
    
    /// Remove withdrawers from payment
    public struct RemoveWithdrawers has drop {}
    
    /// Toggle payment active status
    public struct TogglePayment has drop {}
    
    /// Request withdrawal from stream
    public struct RequestWithdrawal has drop {}
    
    /// Challenge withdrawals
    public struct ChallengeWithdrawals has drop {}
    
    /// Process pending withdrawal
    public struct ProcessPendingWithdrawal has drop {}
    
    /// Cancel challenged withdrawals
    public struct CancelChallengedWithdrawals has drop {}
    
    /// Execute payment
    public struct ExecutePayment has drop {}
    
    // ======== Dissolution Actions ========
    
    /// Initiate DAO dissolution
    public struct InitiateDissolution has drop {}
    
    /// Batch distribute assets
    public struct BatchDistribute has drop {}
    
    /// Finalize dissolution
    public struct FinalizeDissolution has drop {}
    
    /// Cancel dissolution
    public struct CancelDissolution has drop {}
    
    /// Calculate pro-rata shares
    public struct CalculateProRataShares has drop {}
    
    /// Cancel all active streams
    public struct CancelAllStreams has drop {}
    
    /// Withdraw AMM liquidity
    public struct WithdrawAmmLiquidity has drop {}
    
    /// Distribute assets to holders
    public struct DistributeAssets has drop {}
    
    // ======== Policy Actions ========
    
    /// Set pattern-based policy rule
    public struct SetPatternPolicy has drop {}
    
    /// Set object-specific policy rule
    public struct SetObjectPolicy has drop {}
    
    /// Register security council
    public struct RegisterCouncil has drop {}
    
    /// Set a type-based policy
    public struct SetTypePolicy has drop {}
    
    /// Package upgrade action
    public struct PackageUpgrade has drop {}
    
    /// Vault mint action
    public struct VaultMint has drop {}
    
    /// Remove pattern policy
    public struct RemovePatternPolicy has drop {}
    
    /// Remove object policy
    public struct RemoveObjectPolicy has drop {}
    
    // ======== Security Council Actions ========
    
    /// Create security council
    public struct CreateSecurityCouncil has drop {}
    
    /// Approve operating agreement change
    public struct ApproveOAChange has drop {}
    
    /// Update upgrade rules
    public struct UpdateUpgradeRules has drop {}
    
    /// Update council membership
    public struct UpdateCouncilMembership has drop {}
    
    /// Unlock and return upgrade capability
    public struct UnlockAndReturnUpgradeCap has drop {}
    
    /// Approve generic action
    public struct ApproveGeneric has drop {}
    
    /// Sweep expired intents
    public struct SweepIntents has drop {}
    
    /// Council create optimistic intent
    public struct CouncilCreateOptimisticIntent has drop {}
    
    /// Council execute optimistic intent
    public struct CouncilExecuteOptimisticIntent has drop {}
    
    /// Council cancel optimistic intent
    public struct CouncilCancelOptimisticIntent has drop {}
    
    // ======== Custody Actions ========
    
    /// Approve custody transfer
    public struct ApproveCustody has drop {}
    
    /// Accept into custody
    public struct AcceptIntoCustody has drop {}
    
    // ======== Dispatcher Registry Actions ========
    
    /// Register a new action type handler
    public struct RegisterActionType has drop {}
    
    /// Unregister an action type handler
    public struct UnregisterActionType has drop {}
    
    /// Batch register multiple action types
    public struct BatchRegisterActionTypes has drop {}
    
    /// Update handler configuration
    public struct UpdateHandlerConfig has drop {}
    
    // === Constructor functions for witness types ===
    // These are needed for external modules to instantiate witness types
    
    /// Create CancelDissolution witness
    public fun cancel_dissolution(): CancelDissolution { CancelDissolution {} }
    
    /// Create SetObjectPolicy witness
    public fun set_object_policy(): SetObjectPolicy { SetObjectPolicy {} }
    
    /// Create RegisterCouncil witness
    public fun register_council(): RegisterCouncil { RegisterCouncil {} }
    
    /// Create SetTypePolicy witness
    public fun set_type_policy(): SetTypePolicy { SetTypePolicy {} }
    
    /// Create PackageUpgrade witness
    public fun package_upgrade(): PackageUpgrade { PackageUpgrade {} }
    
    /// Create VaultMint witness
    public fun vault_mint(): VaultMint { VaultMint {} }
    
    /// Create RemoveObjectPolicy witness
    public fun remove_object_policy(): RemoveObjectPolicy { RemoveObjectPolicy {} }
    
    /// Create UpdateCouncilMembership witness
    public fun update_council_membership(): UpdateCouncilMembership { UpdateCouncilMembership {} }
    
    /// Create CreateSecurityCouncil witness
    public fun create_security_council(): CreateSecurityCouncil { CreateSecurityCouncil {} }
    
    /// Create ApproveGeneric witness
    public fun approve_generic(): ApproveGeneric { ApproveGeneric {} }
    
    /// Create ApproveCustody witness
    public fun approve_custody(): ApproveCustody { ApproveCustody {} }
    
    /// Create AcceptIntoCustody witness
    public fun accept_into_custody(): AcceptIntoCustody { AcceptIntoCustody {} }
    
    /// Create SweepIntents witness
    public fun sweep_intents(): SweepIntents { SweepIntents {} }
    
    /// Create CouncilCreateOptimisticIntent witness
    public fun council_create_optimistic_intent(): CouncilCreateOptimisticIntent { CouncilCreateOptimisticIntent {} }
    
    /// Create CouncilExecuteOptimisticIntent witness  
    public fun council_execute_optimistic_intent(): CouncilExecuteOptimisticIntent { CouncilExecuteOptimisticIntent {} }
    
    /// Create CouncilCancelOptimisticIntent witness
    public fun council_cancel_optimistic_intent(): CouncilCancelOptimisticIntent { CouncilCancelOptimisticIntent {} }
    
    // Additional constructors for all action types
    public fun add_coin_type(): AddCoinType { AddCoinType {} }
    public fun add_liquidity(): AddLiquidity { AddLiquidity {} }
    public fun batch_distribute(): BatchDistribute { BatchDistribute {} }
    public fun batch_operating_agreement(): BatchOperatingAgreement { BatchOperatingAgreement {} }
    public fun conditional_mint(): ConditionalMint { ConditionalMint {} }
    public fun create_founder_lock_proposal(): CreateFounderLockProposal { CreateFounderLockProposal {} }
    public fun create_operating_agreement(): CreateOperatingAgreement { CreateOperatingAgreement {} }
    public fun execute_founder_lock(): ExecuteFounderLock { ExecuteFounderLock {} }
    public fun finalize_dissolution(): FinalizeDissolution { FinalizeDissolution {} }
    public fun governance_update(): GovernanceUpdate { GovernanceUpdate {} }
    public fun initiate_dissolution(): InitiateDissolution { InitiateDissolution {} }
    public fun insert_line_after(): InsertLineAfter { InsertLineAfter {} }
    public fun insert_line_at_beginning(): InsertLineAtBeginning { InsertLineAtBeginning {} }
    public fun metadata_update(): MetadataUpdate { MetadataUpdate {} }
    public fun queue_params_update(): QueueParamsUpdate { QueueParamsUpdate {} }
    public fun read_oracle_price(): ReadOraclePrice { ReadOraclePrice {} }
    public fun remove_coin_type(): RemoveCoinType { RemoveCoinType {} }
    public fun remove_line(): RemoveLine { RemoveLine {} }
    public fun remove_liquidity(): RemoveLiquidity { RemoveLiquidity {} }
    public fun set_proposals_enabled(): SetProposalsEnabled { SetProposalsEnabled {} }
    public fun slash_distribution_update(): SlashDistributionUpdate { SlashDistributionUpdate {} }
    public fun tiered_mint(): TieredMint { TieredMint {} }
    public fun trading_params_update(): TradingParamsUpdate { TradingParamsUpdate {} }
    public fun twap_config_update(): TwapConfigUpdate { TwapConfigUpdate {} }
    public fun update_founder_lock_recipient(): UpdateFounderLockRecipient { UpdateFounderLockRecipient {} }
    public fun update_line(): UpdateLine { UpdateLine {} }
    public fun update_name(): UpdateName { UpdateName {} }
    public fun withdraw_unlocked_tokens(): WithdrawUnlockedTokens { WithdrawUnlockedTokens {} }

    /// Create RequestVerification witness
    public fun request_verification(): RequestVerification { RequestVerification {} }

    /// Create ApproveVerification witness
    public fun approve_verification(): ApproveVerification { ApproveVerification {} }

    /// Create RejectVerification witness
    public fun reject_verification(): RejectVerification { RejectVerification {} }

    /// Create CreatePayment witness
    public fun create_payment(): CreatePayment { CreatePayment {} }
    
    /// Create CreateBudgetStream witness
    public fun create_budget_stream(): CreateBudgetStream { CreateBudgetStream {} }
    
    /// Create CancelPayment witness
    public fun cancel_payment(): CancelPayment { CancelPayment {} }

    /// Create EmitMemo witness
    public fun emit_memo(): EmitMemo { EmitMemo {} }

    /// Create EmitDecision witness
    public fun emit_decision(): EmitDecision { EmitDecision {} }

    /// Create CreateOptionGrant witness
    public fun create_option_grant(): CreateOptionGrant { CreateOptionGrant {} }

    /// Create CreateTokenGrant witness
    public fun create_token_grant(): CreateTokenGrant { CreateTokenGrant {} }

    /// Create ExerciseOptions witness
    public fun exercise_options(): ExerciseOptions { ExerciseOptions {} }

    /// Create ClaimVestedTokens witness
    public fun claim_vested_tokens(): ClaimVestedTokens { ClaimVestedTokens {} }

    /// Create CancelGrant witness
    public fun cancel_grant(): CancelGrant { CancelGrant {} }
}