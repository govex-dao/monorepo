/// Type markers for all Futarchy actions
/// These types are used for compile-time type safety in action routing
module futarchy_core::action_types;

use std::type_name::{Self, TypeName};

// === Config Action Types ===

public struct SetProposalsEnabled has copy, drop {}
public struct UpdateName has copy, drop {}
public struct TradingParamsUpdate has copy, drop {}
public struct MetadataUpdate has copy, drop {}
public struct SetMetadata has copy, drop {
    phantom: bool,
}

public fun set_metadata(): SetMetadata {
    SetMetadata { phantom: false }
}

public struct UpdateTradingConfig has copy, drop {
    phantom: bool,
}

public fun update_trading_config(): UpdateTradingConfig {
    UpdateTradingConfig { phantom: false }
}

public struct UpdateTwapConfig has copy, drop {
    phantom: bool,
}

public fun update_twap_config(): UpdateTwapConfig {
    UpdateTwapConfig { phantom: false }
}

public struct UpdateGovernance has copy, drop {
    phantom: bool,
}

public fun update_governance(): UpdateGovernance {
    UpdateGovernance { phantom: false }
}

public struct UpdateSlashDistribution has copy, drop {
    phantom: bool,
}

public fun update_slash_distribution(): UpdateSlashDistribution {
    UpdateSlashDistribution { phantom: false }
}

public struct UpdateQueueParams has copy, drop {
    phantom: bool,
}

public fun update_queue_params(): UpdateQueueParams {
    UpdateQueueParams { phantom: false }
}

public struct TwapConfigUpdate has drop {}
public struct GovernanceUpdate has drop {}
public struct MetadataTableUpdate has drop {}
public struct SlashDistributionUpdate has drop {}
public struct QueueParamsUpdate has drop {}
public struct StorageConfigUpdate has drop {}
public struct SetQuotas has drop {}
public struct UpdateConditionalMetadata has drop {}
public struct SetOptimisticIntentChallengeEnabled has drop {}
public struct EarlyResolveConfigUpdate has drop {}

// === Liquidity Action Types ===

public struct CreatePool has drop {}
public struct UpdatePoolParams has drop {}
public struct AddLiquidity has drop {}
public struct WithdrawLpToken has drop {}
public struct RemoveLiquidity has drop {}
public struct Swap has drop {}
public struct CollectFees has drop {}
public struct SetPoolStatus has drop {}
public struct WithdrawFees has drop {}

// === Governance Action Types ===

public struct CreateProposal has drop {}
public struct ProposalReservation has drop {}
public struct PlatformFeeUpdate has drop {}
public struct PlatformFeeWithdraw has drop {}

// === Dissolution Action Types ===

public struct InitiateDissolution has drop {}
public struct CancelDissolution has drop {}
public struct DistributeAsset has drop {}
public struct CalculateProRataShares has drop {}
public struct CancelAllStreams has drop {}
public struct CreateAuction has drop {}
public struct TransferStreamsToTreasury has drop {}
public struct CancelStreamsInBag has drop {}
public struct WithdrawAllCondLiquidity has drop {}
public struct WithdrawAllSpotLiquidity has drop {}
public struct FinalizeDissolution has drop {}

// === Stream Action Types ===

public struct CreateStream has drop {}
public struct CancelStream has drop {}
public struct WithdrawStream has drop {}
public struct CreateProjectStream has drop {}

public struct UpdateStream has drop {}
public struct PauseStream has drop {}
public struct ResumeStream has drop {}
public struct CreatePayment has drop {}
public struct CancelPayment has drop {}
public struct ProcessPayment has drop {}
public struct ExecutePayment has drop {}
public struct RequestWithdrawal has drop {}
public struct ProcessPendingWithdrawal has drop {}
public struct UpdatePaymentRecipient has drop {}
public struct AddWithdrawer has drop {}
public struct RemoveWithdrawers has drop {}
public struct TogglePayment has drop {}
public struct ChallengeWithdrawals has drop {}
public struct CancelChallengedWithdrawals has drop {}

// === Dividend Action Types ===

public struct CreateDividend has drop {}

// === Oracle Action Types ===

public struct ReadOraclePrice has drop {}
// NOTE: ConditionalMint and TieredMint have been replaced by PriceBasedMintGrant shared object

// === Oracle Mint Grant Action Types (Price-Based Minting) ===

public struct CreateOracleGrant has drop {}
public struct ClaimGrantTokens has drop {}
public struct ExecuteMilestoneTier has drop {}
public struct CancelGrant has drop {}
public struct PauseGrant has drop {}
public struct UnpauseGrant has drop {}
public struct EmergencyFreezeGrant has drop {}
public struct EmergencyUnfreezeGrant has drop {}

// === DAO File Registry Action Types ===

// Registry actions
public struct CreateDaoFileRegistry has drop {}
public struct SetRegistryImmutable has drop {}

// Walrus renewal
public struct SetWalrusRenewal has drop {} // Deprecated - use intent-based WalrusRenewal
public struct WalrusRenewal has drop {} // Intent-based renewal execution

// File CRUD
public struct CreateRootFile has drop {}
public struct CreateChildFile has drop {}
public struct CreateFileVersion has drop {}
public struct DeleteFile has drop {}

// Chunk operations
public struct AddChunk has drop {}
public struct AddSunsetChunk has drop {}
public struct AddSunriseChunk has drop {}
public struct AddTemporaryChunk has drop {}
public struct AddChunkWithScheduledImmutability has drop {}
public struct UpdateChunk has drop {}
public struct RemoveChunk has drop {}

// Immutability controls
public struct SetChunkImmutable has drop {}
public struct SetFileImmutable has drop {}
public struct SetFileInsertAllowed has drop {}
public struct SetFileRemoveAllowed has drop {}

// Policy actions
public struct SetFilePolicy has drop {}

// === Custody Action Types ===

public struct CreateCustodyAccount has drop {}
public struct ApproveCustody has drop {}
public struct AcceptIntoCustody has drop {}
public struct CustodyDeposit has drop {}
public struct CustodyWithdraw has drop {}
public struct CustodyTransfer has drop {}

// === Vault Action Types ===

public struct AddCoinType has drop {}
public struct RemoveCoinType has drop {}

// === Security Council Action Types ===

public struct CreateCouncil has drop {}
public struct CreateSecurityCouncil has drop {}
public struct AddCouncilMember has drop {}
public struct RemoveCouncilMember has drop {}
public struct UpdateCouncilMembership has drop {}
public struct UpdateCouncilThreshold has drop {}
public struct ProposeCouncilAction has drop {}
public struct ApproveCouncilAction has drop {}
public struct ExecuteCouncilAction has drop {}
public struct ApproveGeneric has drop {}
public struct SweepIntents has drop {}
public struct CouncilCreateOptimisticIntent has drop {}
public struct CouncilExecuteOptimisticIntent has drop {}
public struct CouncilCancelOptimisticIntent has drop {}

// === Policy Action Types ===

public struct CreatePolicy has drop {}
public struct UpdatePolicy has drop {}
public struct RemovePolicy has drop {}
public struct SetTypePolicy has drop {}
public struct SetObjectPolicy has drop {}
public struct RegisterCouncil has drop {}

// === Memo Action Types ===

public struct Memo has drop {}

// === Protocol Admin Action Types ===

public struct SetFactoryPaused has drop {}
public struct AddStableType has drop {}
public struct RemoveStableType has drop {}
public struct UpdateDaoCreationFee has drop {}
public struct UpdateProposalFee has drop {}
public struct UpdateTreasuryAddress has drop {}
public struct WithdrawProtocolFees has drop {}

// === Verification Action Types ===

public struct UpdateVerificationFee has drop {}
public struct AddVerificationLevel has drop {}
public struct RemoveVerificationLevel has drop {}
public struct RequestVerification has drop {}
public struct ApproveVerification has drop {}
public struct RejectVerification has drop {}

// === DAO Score Action Types ===

public struct SetDaoScore has drop {}

// === Launchpad Admin Action Types ===

public struct SetLaunchpadTrustScore has drop {}

// === Fee Management Action Types ===

public struct UpdateRecoveryFee has drop {}
public struct WithdrawFeesToTreasury has drop {}

// === Coin Fee Config Action Types ===

public struct AddCoinFeeConfig has drop {}
public struct UpdateCoinCreationFee has drop {}
public struct UpdateCoinProposalFee has drop {}
public struct UpdateCoinRecoveryFee has drop {}
public struct ApplyPendingCoinFees has drop {}


// === Package Upgrade Action Types ===

public struct PackageUpgrade has drop {}

// === Vault Action Types ===

public struct VaultMint has drop {}

// === Accessor Functions ===

// Config actions
public fun set_proposals_enabled(): TypeName { type_name::with_defining_ids<SetProposalsEnabled>() }

public fun update_name(): TypeName { type_name::with_defining_ids<UpdateName>() }

public fun trading_params_update(): TypeName { type_name::with_defining_ids<TradingParamsUpdate>() }

public fun metadata_update(): TypeName { type_name::with_defining_ids<MetadataUpdate>() }

public fun twap_config_update(): TypeName { type_name::with_defining_ids<TwapConfigUpdate>() }

public fun governance_update(): TypeName { type_name::with_defining_ids<GovernanceUpdate>() }

public fun metadata_table_update(): TypeName { type_name::with_defining_ids<MetadataTableUpdate>() }

public fun slash_distribution_update(): TypeName {
    type_name::with_defining_ids<SlashDistributionUpdate>()
}

public fun queue_params_update(): TypeName { type_name::with_defining_ids<QueueParamsUpdate>() }

public fun update_conditional_metadata(): TypeName {
    type_name::with_defining_ids<UpdateConditionalMetadata>()
}

public fun set_optimistic_intent_challenge_enabled(): TypeName {
    type_name::with_defining_ids<SetOptimisticIntentChallengeEnabled>()
}

public fun early_resolve_config_update(): TypeName {
    type_name::with_defining_ids<EarlyResolveConfigUpdate>()
}

// Liquidity actions
public fun create_pool(): TypeName { type_name::with_defining_ids<CreatePool>() }

public fun update_pool_params(): TypeName { type_name::with_defining_ids<UpdatePoolParams>() }

public fun add_liquidity(): TypeName { type_name::with_defining_ids<AddLiquidity>() }

public fun withdraw_lp_token(): TypeName { type_name::with_defining_ids<WithdrawLpToken>() }

public fun remove_liquidity(): TypeName { type_name::with_defining_ids<RemoveLiquidity>() }

public fun swap(): TypeName { type_name::with_defining_ids<Swap>() }

public fun collect_fees(): TypeName { type_name::with_defining_ids<CollectFees>() }

public fun set_pool_status(): TypeName { type_name::with_defining_ids<SetPoolStatus>() }

public fun withdraw_fees(): TypeName { type_name::with_defining_ids<WithdrawFees>() }

// Governance actions
public fun create_proposal(): TypeName { type_name::with_defining_ids<CreateProposal>() }

public fun proposal_reservation(): TypeName { type_name::with_defining_ids<ProposalReservation>() }

public fun platform_fee_update(): TypeName { type_name::with_defining_ids<PlatformFeeUpdate>() }

public fun platform_fee_withdraw(): TypeName { type_name::with_defining_ids<PlatformFeeWithdraw>() }

// Dissolution actions
public fun initiate_dissolution(): TypeName { type_name::with_defining_ids<InitiateDissolution>() }

public fun cancel_dissolution(): TypeName { type_name::with_defining_ids<CancelDissolution>() }

public fun distribute_asset(): TypeName { type_name::with_defining_ids<DistributeAsset>() }

public fun calculate_pro_rata_shares(): TypeName {
    type_name::with_defining_ids<CalculateProRataShares>()
}

public fun cancel_all_streams(): TypeName { type_name::with_defining_ids<CancelAllStreams>() }

public fun create_auction(): TypeName { type_name::with_defining_ids<CreateAuction>() }

public fun transfer_streams_to_treasury(): TypeName {
    type_name::with_defining_ids<TransferStreamsToTreasury>()
}

public fun cancel_streams_in_bag(): TypeName { type_name::with_defining_ids<CancelStreamsInBag>() }

public fun withdraw_all_cond_liquidity(): TypeName {
    type_name::with_defining_ids<WithdrawAllCondLiquidity>()
}

public fun withdraw_all_spot_liquidity(): TypeName {
    type_name::with_defining_ids<WithdrawAllSpotLiquidity>()
}

public fun finalize_dissolution(): TypeName { type_name::with_defining_ids<FinalizeDissolution>() }

// Stream actions
public fun create_stream(): TypeName { type_name::with_defining_ids<CreateStream>() }

public fun cancel_stream(): TypeName { type_name::with_defining_ids<CancelStream>() }

public fun withdraw_stream(): TypeName { type_name::with_defining_ids<WithdrawStream>() }

public fun create_project_stream(): TypeName { type_name::with_defining_ids<CreateProjectStream>() }

public fun update_stream(): TypeName { type_name::with_defining_ids<UpdateStream>() }

public fun pause_stream(): TypeName { type_name::with_defining_ids<PauseStream>() }

public fun resume_stream(): TypeName { type_name::with_defining_ids<ResumeStream>() }

public fun create_payment(): TypeName { type_name::with_defining_ids<CreatePayment>() }

public fun cancel_payment(): TypeName { type_name::with_defining_ids<CancelPayment>() }

public fun process_payment(): TypeName { type_name::with_defining_ids<ProcessPayment>() }

public fun execute_payment(): TypeName { type_name::with_defining_ids<ExecutePayment>() }

public fun request_withdrawal(): TypeName { type_name::with_defining_ids<RequestWithdrawal>() }

public fun process_pending_withdrawal(): TypeName {
    type_name::with_defining_ids<ProcessPendingWithdrawal>()
}

public fun update_payment_recipient(): TypeName {
    type_name::with_defining_ids<UpdatePaymentRecipient>()
}

public fun add_withdrawer(): TypeName { type_name::with_defining_ids<AddWithdrawer>() }

public fun remove_withdrawers(): TypeName { type_name::with_defining_ids<RemoveWithdrawers>() }

public fun toggle_payment(): TypeName { type_name::with_defining_ids<TogglePayment>() }

public fun challenge_withdrawals(): TypeName {
    type_name::with_defining_ids<ChallengeWithdrawals>()
}

public fun cancel_challenged_withdrawals(): TypeName {
    type_name::with_defining_ids<CancelChallengedWithdrawals>()
}

// Oracle actions
public fun create_oracle_grant(): TypeName { type_name::with_defining_ids<CreateOracleGrant>() }

public fun claim_grant_tokens(): TypeName { type_name::with_defining_ids<ClaimGrantTokens>() }

public fun execute_milestone_tier(): TypeName {
    type_name::with_defining_ids<ExecuteMilestoneTier>()
}

public fun cancel_grant(): TypeName { type_name::with_defining_ids<CancelGrant>() }

public fun pause_grant(): TypeName { type_name::with_defining_ids<PauseGrant>() }

public fun unpause_grant(): TypeName { type_name::with_defining_ids<UnpauseGrant>() }

public fun emergency_freeze_grant(): TypeName {
    type_name::with_defining_ids<EmergencyFreezeGrant>()
}

public fun emergency_unfreeze_grant(): TypeName {
    type_name::with_defining_ids<EmergencyUnfreezeGrant>()
}

// DAO File Registry actions
public fun create_dao_file_registry(): TypeName {
    type_name::with_defining_ids<CreateDaoFileRegistry>()
}

public fun set_registry_immutable(): TypeName {
    type_name::with_defining_ids<SetRegistryImmutable>()
}

public fun create_root_file(): TypeName { type_name::with_defining_ids<CreateRootFile>() }

public fun create_child_file(): TypeName { type_name::with_defining_ids<CreateChildFile>() }

public fun create_file_version(): TypeName { type_name::with_defining_ids<CreateFileVersion>() }

public fun delete_file(): TypeName { type_name::with_defining_ids<DeleteFile>() }

public fun add_chunk(): TypeName { type_name::with_defining_ids<AddChunk>() }

public fun add_sunset_chunk(): TypeName { type_name::with_defining_ids<AddSunsetChunk>() }

public fun add_sunrise_chunk(): TypeName { type_name::with_defining_ids<AddSunriseChunk>() }

public fun add_temporary_chunk(): TypeName { type_name::with_defining_ids<AddTemporaryChunk>() }

public fun add_chunk_with_scheduled_immutability(): TypeName {
    type_name::with_defining_ids<AddChunkWithScheduledImmutability>()
}

public fun update_chunk(): TypeName { type_name::with_defining_ids<UpdateChunk>() }

public fun remove_chunk(): TypeName { type_name::with_defining_ids<RemoveChunk>() }

public fun set_chunk_immutable(): TypeName { type_name::with_defining_ids<SetChunkImmutable>() }

public fun set_file_immutable(): TypeName { type_name::with_defining_ids<SetFileImmutable>() }

public fun set_file_insert_allowed(): TypeName {
    type_name::with_defining_ids<SetFileInsertAllowed>()
}

public fun set_file_remove_allowed(): TypeName {
    type_name::with_defining_ids<SetFileRemoveAllowed>()
}

public fun set_file_policy(): TypeName { type_name::with_defining_ids<SetFilePolicy>() }

// Custody actions
public fun create_custody_account(): TypeName {
    type_name::with_defining_ids<CreateCustodyAccount>()
}

public fun custody_deposit(): TypeName { type_name::with_defining_ids<CustodyDeposit>() }

public fun custody_withdraw(): TypeName { type_name::with_defining_ids<CustodyWithdraw>() }

public fun custody_transfer(): TypeName { type_name::with_defining_ids<CustodyTransfer>() }

// Security council actions
public fun create_council(): TypeName { type_name::with_defining_ids<CreateCouncil>() }

public fun add_council_member(): TypeName { type_name::with_defining_ids<AddCouncilMember>() }

public fun remove_council_member(): TypeName { type_name::with_defining_ids<RemoveCouncilMember>() }

public fun update_council_threshold(): TypeName {
    type_name::with_defining_ids<UpdateCouncilThreshold>()
}

public fun update_council_membership(): TypeName {
    type_name::with_defining_ids<UpdateCouncilMembership>()
}

public fun propose_council_action(): TypeName {
    type_name::with_defining_ids<ProposeCouncilAction>()
}

public fun approve_council_action(): TypeName {
    type_name::with_defining_ids<ApproveCouncilAction>()
}

public fun execute_council_action(): TypeName {
    type_name::with_defining_ids<ExecuteCouncilAction>()
}

public fun approve_generic(): TypeName { type_name::with_defining_ids<ApproveGeneric>() }

public fun council_create_optimistic_intent(): TypeName {
    type_name::with_defining_ids<CouncilCreateOptimisticIntent>()
}

public fun council_execute_optimistic_intent(): TypeName {
    type_name::with_defining_ids<CouncilExecuteOptimisticIntent>()
}

public fun council_cancel_optimistic_intent(): TypeName {
    type_name::with_defining_ids<CouncilCancelOptimisticIntent>()
}

// Policy actions
public fun create_policy(): TypeName { type_name::with_defining_ids<CreatePolicy>() }

public fun update_policy(): TypeName { type_name::with_defining_ids<UpdatePolicy>() }

public fun remove_policy(): TypeName { type_name::with_defining_ids<RemovePolicy>() }

public fun set_type_policy(): TypeName { type_name::with_defining_ids<SetTypePolicy>() }

public fun set_object_policy(): TypeName { type_name::with_defining_ids<SetObjectPolicy>() }

public fun register_council(): TypeName { type_name::with_defining_ids<RegisterCouncil>() }

// Memo actions
public fun memo(): TypeName { type_name::with_defining_ids<Memo>() }

public fun emit_memo(): TypeName { type_name::with_defining_ids<Memo>() }

public fun emit_decision(): TypeName { type_name::with_defining_ids<Memo>() }

// Protocol admin actions
public fun set_factory_paused(): TypeName { type_name::with_defining_ids<SetFactoryPaused>() }

public fun add_stable_type(): TypeName { type_name::with_defining_ids<AddStableType>() }

public fun remove_stable_type(): TypeName { type_name::with_defining_ids<RemoveStableType>() }

public fun update_dao_creation_fee(): TypeName {
    type_name::with_defining_ids<UpdateDaoCreationFee>()
}

public fun update_proposal_fee(): TypeName { type_name::with_defining_ids<UpdateProposalFee>() }

public fun update_treasury_address(): TypeName {
    type_name::with_defining_ids<UpdateTreasuryAddress>()
}

public fun withdraw_protocol_fees(): TypeName {
    type_name::with_defining_ids<WithdrawProtocolFees>()
}

// Package upgrade actions
public fun package_upgrade(): TypeName { type_name::with_defining_ids<PackageUpgrade>() }

// Vault actions
public fun vault_mint(): TypeName { type_name::with_defining_ids<VaultMint>() }

// Verification actions
public fun update_verification_fee(): TypeName {
    type_name::with_defining_ids<UpdateVerificationFee>()
}

public fun add_verification_level(): TypeName {
    type_name::with_defining_ids<AddVerificationLevel>()
}

public fun remove_verification_level(): TypeName {
    type_name::with_defining_ids<RemoveVerificationLevel>()
}

public fun request_verification(): TypeName { type_name::with_defining_ids<RequestVerification>() }

public fun approve_verification(): TypeName { type_name::with_defining_ids<ApproveVerification>() }

public fun reject_verification(): TypeName { type_name::with_defining_ids<RejectVerification>() }

// DAO Score actions
public fun set_dao_score(): TypeName { type_name::with_defining_ids<SetDaoScore>() }

// Launchpad Admin actions
public fun set_launchpad_trust_score(): TypeName {
    type_name::with_defining_ids<SetLaunchpadTrustScore>()
}

// Fee Management actions
public fun update_recovery_fee(): TypeName { type_name::with_defining_ids<UpdateRecoveryFee>() }

public fun withdraw_fees_to_treasury(): TypeName {
    type_name::with_defining_ids<WithdrawFeesToTreasury>()
}

// Coin Fee Config actions
public fun add_coin_fee_config(): TypeName { type_name::with_defining_ids<AddCoinFeeConfig>() }

public fun update_coin_creation_fee(): TypeName {
    type_name::with_defining_ids<UpdateCoinCreationFee>()
}

public fun update_coin_proposal_fee(): TypeName {
    type_name::with_defining_ids<UpdateCoinProposalFee>()
}

public fun update_coin_recovery_fee(): TypeName {
    type_name::with_defining_ids<UpdateCoinRecoveryFee>()
}

public fun apply_pending_coin_fees(): TypeName {
    type_name::with_defining_ids<ApplyPendingCoinFees>()
}

// Oracle actions
public fun read_oracle_price(): TypeName { type_name::with_defining_ids<ReadOraclePrice>() }

// Walrus renewal actions
public fun set_walrus_renewal(): TypeName { type_name::with_defining_ids<SetWalrusRenewal>() }

public fun walrus_renewal(): TypeName { type_name::with_defining_ids<WalrusRenewal>() }

// Quota actions
public fun set_quotas(): TypeName { type_name::with_defining_ids<SetQuotas>() }

// Dividend actions
public fun create_dividend(): TypeName { type_name::with_defining_ids<CreateDividend>() }
