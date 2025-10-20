# Futarchy Actions Refactoring Status

## Completed Packages ✅

### 1. futarchy_stream_actions
**File**: stream_actions.move
**Types Added**: CreateStream, CancelStream, UpdateStream, PauseStream, ResumeStream, CreatePayment, CancelPayment, ProcessPayment, ExecutePayment, UpdatePaymentRecipient, AddWithdrawer, RemoveWithdrawers, TogglePayment
**Status**: ✅ Complete

### 2. futarchy_oracle_actions
**File**: oracle_actions.move
**Types Added**: ReadOraclePrice, CreateOracleGrant, ClaimGrantTokens, ExecuteMilestoneTier, CancelGrant, PauseGrant, UnpauseGrant, EmergencyFreezeGrant, EmergencyUnfreezeGrant
**Status**: ✅ Complete

### 3. futarchy_actions
**Files**: 
- config/config_actions.move
- config/quota_actions.move
- liquidity/liquidity_actions.move

**Config Types**: SetProposalsEnabled, TerminateDao, UpdateName, TradingParamsUpdate, MetadataUpdate, TwapConfigUpdate, GovernanceUpdate, MetadataTableUpdate, SlashDistributionUpdate, QueueParamsUpdate, EarlyResolveConfigUpdate, SponsorshipConfigUpdate, UpdateConditionalMetadata

**Quota Types**: SetQuotas

**Liquidity Types**: CreatePool, UpdatePoolParams, AddLiquidity, WithdrawLpToken, RemoveLiquidity, Swap, CollectFees, SetPoolStatus, WithdrawFees
**Status**: ✅ Complete

### 4. futarchy_governance_actions
**File**: protocol_admin_actions.move
**Types Added**: AddCoinFeeConfig, AddStableType, AddVerificationLevel, ApplyPendingCoinFees, ApproveVerification, DisableFactoryPermanently, RejectVerification, RemoveStableType, RemoveVerificationLevel, RequestVerification, SetFactoryPaused, SetLaunchpadTrustScore, UpdateCoinCreationFee, UpdateCoinProposalFee, UpdateCoinRecoveryFee, UpdateDaoCreationFee, UpdateProposalFee, UpdateRecoveryFee, UpdateVerificationFee, WithdrawFeesToTreasury
**Status**: ✅ Complete

### 5. Intent Files
**Files** (imports removed):
- config_intents.move
- quota_intents.move
- liquidity_intents.move
- protocol_admin_intents.move
- oracle_intents.move
- stream_intents.move
**Status**: ✅ Complete

## Remaining Packages ⚠️

### 6. v3_dissolution
**File**: dissolution_actions.move
**Types Needed**: InitiateDissolution, CancelDissolution, DistributeAsset, CalculateProRataShares, CancelAllStreams, CreateAuction, WithdrawAllSpotLiquidity, FinalizeDissolution
**Status**: ⚠️ Imports removed, types need to be added

### 7. v3_dividend
**File**: dividend_actions.move  
**Types Needed**: CreateDividend (and possibly others)
**Status**: ⚠️ Imports removed, types need to be added

### 8. v3_futarchy_legal
**File**: dao_file_actions.move, walrus_renewal.move
**Types Needed**: CreateDaoFileRegistry, SetRegistryImmutable, WalrusRenewal, CreateRootFile, CreateChildFile, CreateFileVersion, DeleteFile, AddChunk, AddSunsetChunk, AddSunriseChunk, AddTemporaryChunk, AddChunkWithScheduledImmutability, UpdateChunk, RemoveChunk, SetChunkImmutable, SetFileImmutable, SetFileInsertAllowed, SetFileRemoveAllowed, SetFilePolicy
**Status**: ⚠️ Imports removed, types need to be added

## Next Steps

For each remaining package:
1. Open the actions file
2. Add type markers section after imports:
   ```move
   // === Action Type Markers ===
   public struct TypeName has drop {}
   ```
3. Test build
4. Once all complete, delete centralized file

## Final Step

Delete centralized types file:
```bash
rm /Users/admin/monorepo/contracts/futarchy_types/sources/action_type_markers.move
```

## Summary

**Completed**: 5 packages (stream, oracle, config/quota/liquidity, governance, intents)
**Remaining**: 3 packages (dissolution, dividend, legal) 
**Total Types Migrated**: ~60+ types
**Remaining Types**: ~30 types

