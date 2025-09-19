/// Type markers for all Futarchy actions
/// These types are used for compile-time type safety in action routing
module futarchy_core::action_types;

use std::type_name::{Self, TypeName};

// === Config Action Types ===

public struct SetProposalsEnabled has drop {}
public struct UpdateName has drop {}
public struct TradingParamsUpdate has drop {}
public struct MetadataUpdate has drop {}
public struct TwapConfigUpdate has drop {}
public struct GovernanceUpdate has drop {}
public struct MetadataTableUpdate has drop {}
public struct SlashDistributionUpdate has drop {}
public struct QueueParamsUpdate has drop {}

// === Liquidity Action Types ===

public struct CreatePool has drop {}
public struct UpdatePoolParams has drop {}
public struct AddLiquidity has drop {}
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
public struct CreateBudgetStream has drop {}

public struct UpdateStream has drop {}
public struct PauseStream has drop {}
public struct ResumeStream has drop {}
public struct CreatePayment has drop {}
public struct CancelPayment has drop {}
public struct ProcessPayment has drop {}

// === Oracle Action Types ===

public struct ConditionalMint has drop {}
public struct TieredMint has drop {}

// === Operating Agreement Action Types ===

public struct CreateOperatingAgreement has drop {}
public struct AddLine has drop {}
public struct RemoveLine has drop {}
public struct UpdateLine has drop {}
public struct BatchAddLines has drop {}
public struct BatchRemoveLines has drop {}
public struct LockOperatingAgreement has drop {}

// === Custody Action Types ===

public struct CreateCustodyAccount has drop {}
public struct CustodyDeposit has drop {}
public struct CustodyWithdraw has drop {}
public struct CustodyTransfer has drop {}

// === Security Council Action Types ===

public struct CreateCouncil has drop {}
public struct AddCouncilMember has drop {}
public struct RemoveCouncilMember has drop {}
public struct UpdateCouncilThreshold has drop {}
public struct ProposeCouncilAction has drop {}
public struct ApproveCouncilAction has drop {}
public struct ExecuteCouncilAction has drop {}

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
public struct UpdateMonthlyDaoFee has drop {}
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

// === Fee Management Action Types ===

public struct UpdateRecoveryFee has drop {}
public struct WithdrawFeesToTreasury has drop {}
public struct ApplyDaoFeeDiscount has drop {}

// === Coin Fee Config Action Types ===

public struct AddCoinFeeConfig has drop {}
public struct UpdateCoinMonthlyFee has drop {}
public struct UpdateCoinCreationFee has drop {}
public struct UpdateCoinProposalFee has drop {}
public struct UpdateCoinRecoveryFee has drop {}
public struct ApplyPendingCoinFees has drop {}

// === Founder Lock Action Types ===

public struct CreateFounderLock has drop {}
public struct UnlockFounderTokens has drop {}

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
public fun slash_distribution_update(): TypeName { type_name::with_defining_ids<SlashDistributionUpdate>() }
public fun queue_params_update(): TypeName { type_name::with_defining_ids<QueueParamsUpdate>() }

// Liquidity actions
public fun create_pool(): TypeName { type_name::with_defining_ids<CreatePool>() }
public fun update_pool_params(): TypeName { type_name::with_defining_ids<UpdatePoolParams>() }
public fun add_liquidity(): TypeName { type_name::with_defining_ids<AddLiquidity>() }
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
public fun transfer_streams_to_treasury(): TypeName { type_name::with_defining_ids<TransferStreamsToTreasury>() }
public fun cancel_streams_in_bag(): TypeName { type_name::with_defining_ids<CancelStreamsInBag>() }
public fun withdraw_all_cond_liquidity(): TypeName { type_name::with_defining_ids<WithdrawAllCondLiquidity>() }
public fun withdraw_all_spot_liquidity(): TypeName { type_name::with_defining_ids<WithdrawAllSpotLiquidity>() }
public fun finalize_dissolution(): TypeName { type_name::with_defining_ids<FinalizeDissolution>() }

// Stream actions
public fun create_stream(): TypeName { type_name::with_defining_ids<CreateStream>() }
public fun cancel_stream(): TypeName { type_name::with_defining_ids<CancelStream>() }
public fun withdraw_stream(): TypeName { type_name::with_defining_ids<WithdrawStream>() }
public fun create_project_stream(): TypeName { type_name::with_defining_ids<CreateProjectStream>() }
public fun create_budget_stream(): TypeName { type_name::with_defining_ids<CreateBudgetStream>() }

public fun update_stream(): TypeName { type_name::with_defining_ids<UpdateStream>() }
public fun pause_stream(): TypeName { type_name::with_defining_ids<PauseStream>() }
public fun resume_stream(): TypeName { type_name::with_defining_ids<ResumeStream>() }
public fun create_payment(): TypeName { type_name::with_defining_ids<CreatePayment>() }
public fun cancel_payment(): TypeName { type_name::with_defining_ids<CancelPayment>() }
public fun process_payment(): TypeName { type_name::with_defining_ids<ProcessPayment>() }

// Oracle actions
public fun conditional_mint(): TypeName { type_name::with_defining_ids<ConditionalMint>() }
public fun tiered_mint(): TypeName { type_name::with_defining_ids<TieredMint>() }

// Operating agreement actions
public fun create_operating_agreement(): TypeName { type_name::with_defining_ids<CreateOperatingAgreement>() }
public fun add_line(): TypeName { type_name::with_defining_ids<AddLine>() }
public fun remove_line(): TypeName { type_name::with_defining_ids<RemoveLine>() }
public fun update_line(): TypeName { type_name::with_defining_ids<UpdateLine>() }
public fun batch_add_lines(): TypeName { type_name::with_defining_ids<BatchAddLines>() }
public fun batch_remove_lines(): TypeName { type_name::with_defining_ids<BatchRemoveLines>() }
public fun lock_operating_agreement(): TypeName { type_name::with_defining_ids<LockOperatingAgreement>() }

// Custody actions
public fun create_custody_account(): TypeName { type_name::with_defining_ids<CreateCustodyAccount>() }
public fun custody_deposit(): TypeName { type_name::with_defining_ids<CustodyDeposit>() }
public fun custody_withdraw(): TypeName { type_name::with_defining_ids<CustodyWithdraw>() }
public fun custody_transfer(): TypeName { type_name::with_defining_ids<CustodyTransfer>() }

// Security council actions
public fun create_council(): TypeName { type_name::with_defining_ids<CreateCouncil>() }
public fun add_council_member(): TypeName { type_name::with_defining_ids<AddCouncilMember>() }
public fun remove_council_member(): TypeName { type_name::with_defining_ids<RemoveCouncilMember>() }
public fun update_council_threshold(): TypeName { type_name::with_defining_ids<UpdateCouncilThreshold>() }
public fun propose_council_action(): TypeName { type_name::with_defining_ids<ProposeCouncilAction>() }
public fun approve_council_action(): TypeName { type_name::with_defining_ids<ApproveCouncilAction>() }
public fun execute_council_action(): TypeName { type_name::with_defining_ids<ExecuteCouncilAction>() }

// Policy actions
public fun create_policy(): TypeName { type_name::with_defining_ids<CreatePolicy>() }
public fun update_policy(): TypeName { type_name::with_defining_ids<UpdatePolicy>() }
public fun remove_policy(): TypeName { type_name::with_defining_ids<RemovePolicy>() }
public fun set_type_policy(): TypeName { type_name::with_defining_ids<SetTypePolicy>() }
public fun set_object_policy(): TypeName { type_name::with_defining_ids<SetObjectPolicy>() }
public fun register_council(): TypeName { type_name::with_defining_ids<RegisterCouncil>() }

// Memo actions
public fun memo(): TypeName { type_name::with_defining_ids<Memo>() }

// Protocol admin actions
public fun set_factory_paused(): TypeName { type_name::with_defining_ids<SetFactoryPaused>() }
public fun add_stable_type(): TypeName { type_name::with_defining_ids<AddStableType>() }
public fun remove_stable_type(): TypeName { type_name::with_defining_ids<RemoveStableType>() }
public fun update_dao_creation_fee(): TypeName { type_name::with_defining_ids<UpdateDaoCreationFee>() }
public fun update_proposal_fee(): TypeName { type_name::with_defining_ids<UpdateProposalFee>() }
public fun update_monthly_dao_fee(): TypeName { type_name::with_defining_ids<UpdateMonthlyDaoFee>() }
public fun update_treasury_address(): TypeName { type_name::with_defining_ids<UpdateTreasuryAddress>() }
public fun withdraw_protocol_fees(): TypeName { type_name::with_defining_ids<WithdrawProtocolFees>() }

// Founder lock actions
public fun create_founder_lock(): TypeName { type_name::with_defining_ids<CreateFounderLock>() }
public fun unlock_founder_tokens(): TypeName { type_name::with_defining_ids<UnlockFounderTokens>() }

// Package upgrade actions
public fun package_upgrade(): TypeName { type_name::with_defining_ids<PackageUpgrade>() }

// Vault actions
public fun vault_mint(): TypeName { type_name::with_defining_ids<VaultMint>() }

// Verification actions
public fun update_verification_fee(): TypeName { type_name::with_defining_ids<UpdateVerificationFee>() }
public fun add_verification_level(): TypeName { type_name::with_defining_ids<AddVerificationLevel>() }
public fun remove_verification_level(): TypeName { type_name::with_defining_ids<RemoveVerificationLevel>() }
public fun request_verification(): TypeName { type_name::with_defining_ids<RequestVerification>() }
public fun approve_verification(): TypeName { type_name::with_defining_ids<ApproveVerification>() }
public fun reject_verification(): TypeName { type_name::with_defining_ids<RejectVerification>() }

// DAO Score actions
public fun set_dao_score(): TypeName { type_name::with_defining_ids<SetDaoScore>() }

// Fee Management actions
public fun update_recovery_fee(): TypeName { type_name::with_defining_ids<UpdateRecoveryFee>() }
public fun withdraw_fees_to_treasury(): TypeName { type_name::with_defining_ids<WithdrawFeesToTreasury>() }
public fun apply_dao_fee_discount(): TypeName { type_name::with_defining_ids<ApplyDaoFeeDiscount>() }

// Coin Fee Config actions
public fun add_coin_fee_config(): TypeName { type_name::with_defining_ids<AddCoinFeeConfig>() }
public fun update_coin_monthly_fee(): TypeName { type_name::with_defining_ids<UpdateCoinMonthlyFee>() }
public fun update_coin_creation_fee(): TypeName { type_name::with_defining_ids<UpdateCoinCreationFee>() }
public fun update_coin_proposal_fee(): TypeName { type_name::with_defining_ids<UpdateCoinProposalFee>() }
public fun update_coin_recovery_fee(): TypeName { type_name::with_defining_ids<UpdateCoinRecoveryFee>() }
public fun apply_pending_coin_fees(): TypeName { type_name::with_defining_ids<ApplyPendingCoinFees>() }