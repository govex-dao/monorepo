# Deployment Checklist for Futarchy Protocol

## ✅ Pre-Deployment Verification

### 1. Architecture Components Complete
- [x] **Pure Configuration Pattern**
  - FutarchyConfig with `store, copy, drop` abilities
  - No object IDs or dynamic state in config
  - Dynamic fields stored via Account pattern

- [x] **Global ActionDecoderRegistry**
  - Single-transaction deployment with RegistryInfo pattern
  - All decoders registered in init function
  - No hardcoded REGISTRY_ID constants

- [x] **PTB Execution Pattern**
  - All action modules have `do_*` functions with standard signature
  - Hot potato pattern for resources (ResourceRequest/ResourceReceipt)
  - Clean Executable flow with embedded ExecutionContext

### 2. Action Modules Status

#### Core Actions (futarchy_actions)
- [x] config_actions - PTB pattern implemented
- [x] liquidity_actions - PTB pattern implemented
- [x] governance_actions - PTB pattern implemented
- [x] memo_actions - PTB pattern implemented

#### Lifecycle Actions (futarchy_lifecycle)
- [x] stream_actions - PTB pattern implemented
- [x] oracle_actions - PTB pattern implemented
- [x] dissolution_actions - PTB pattern implemented

#### Specialized Actions (futarchy_specialized_actions)
- [x] operating_agreement_actions - PTB pattern added

#### Multisig Actions (futarchy_multisig)
- [x] security_council_actions - PTB pattern implemented
- [x] policy_actions - PTB pattern implemented

#### Vault Actions (futarchy_vault)
- [x] custody_actions - PTB pattern added

### 3. Removed Components
- [x] All dispatcher modules deleted (40+ files)
- [x] action_data_structs circular dependency removed
- [x] String-based action routing eliminated

## 📋 Deployment Steps

### Phase 1: Move Framework Deployment
```bash
# 1. Deploy Move framework packages in order
cd /Users/admin/monorepo/contracts
./deploy_verified.sh

# Expected packages:
# - Kiosk
# - AccountExtensions
# - AccountProtocol (with schema.move, bcs_validation.move)
# - AccountActions (with decoder_registry_init.move)
```

### Phase 2: Futarchy Package Deployment
```bash
# 2. Deploy Futarchy packages (automated by script)
# The script handles dependency order automatically:
# - futarchy_one_shot_utils
# - futarchy_core (with futarchy_decoder_registry.move)
# - futarchy_markets
# - futarchy_vault
# - futarchy_multisig
# - futarchy_lifecycle
# - futarchy_specialized_actions
# - futarchy_actions
# - futarchy_dao
```

### Phase 3: Registry Initialization
```bash
# 3. Verify decoder registry is shared
# The registry is initialized automatically during deployment
# Check the RegistryCreated event for the registry ID
sui client events --event-type decoder_registry_init::RegistryCreated

# Verify RegistryInfo object is shared
sui client object <REGISTRY_INFO_ID>
```

## 🔍 Post-Deployment Verification

### 1. Registry Validation
```bash
# Check that all decoders are registered
sui client call \
  --package <FUTARCHY_CORE_ID> \
  --module schema \
  --function has_decoder \
  --args <REGISTRY_ID> <ACTION_TYPE_NAME>
```

### 2. DAO Creation Test
```bash
# Create a test DAO to verify all components work
sui client call \
  --package <FUTARCHY_DAO_ID> \
  --module dao_creation \
  --function create_dao \
  --args <REGISTRY_ID> <CONFIG_PARAMS>
```

### 3. Proposal Execution Test
```bash
# Test PTB execution flow
# 1. Submit proposal with intent
# 2. Execute using PTB pattern
# 3. Verify actions executed correctly
```

## ⚠️ Critical Checks

### Before Deployment
- [ ] All Move.toml files have correct dependencies
- [ ] No circular dependencies exist
- [ ] All tests pass: `sui move test`
- [ ] Build succeeds: `sui move build`

### During Deployment
- [ ] Monitor gas usage (need ~50 SUI total)
- [ ] Save all package IDs from deployment
- [ ] Verify each package deploys successfully
- [ ] Check deployment logs for errors

### After Deployment
- [ ] ActionDecoderRegistry is accessible
- [ ] RegistryInfo returns correct registry ID
- [ ] All decoders can decode their actions
- [ ] PTB execution works end-to-end

## 🚀 Production Readiness

### Security Considerations
- [x] BCS validation with `validate_all_bytes_consumed()`
- [x] Type-safe action routing via TypeName
- [x] Mandatory decoder validation at entry points
- [x] Hot potato pattern prevents resource leaks

### Performance Optimizations
- [x] O(1) type comparison for action routing
- [x] Minimal gas overhead from PTB pattern
- [x] Efficient dynamic field access patterns
- [x] Batch action support for complex operations

### Frontend Integration
- [ ] Update SDK to use new PTB pattern
- [ ] Implement action builder for IntentSpecs
- [ ] Add decoder registry client
- [ ] Update transaction builders for PTB flow

## 📝 Notes

### Key Architectural Changes
1. **No Dispatchers**: PTBs act as dispatchers, chaining `do_*` functions
2. **Registry Pattern**: Single global registry, discoverable via RegistryInfo
3. **Clean Separation**: Protocol layer (structure) vs Application layer (semantics)
4. **Type Safety**: Compile-time guarantees via TypeName routing

### Migration Guide for Existing Code
1. Replace dispatcher calls with PTB chains
2. Use `do_*` functions instead of execute functions
3. Update intent creation to use ActionSpecs
4. Add registry parameter to entry functions

### Known Limitations
- PTB gas limits may restrict very complex proposals
- Maximum 1024 operations per PTB
- Resources must be available at transaction time

## ✅ Final Checklist

- [ ] All code reviewed and tested
- [ ] Deployment script prepared and tested
- [ ] Package IDs documented
- [ ] Registry ID saved and shared
- [ ] Frontend updated to match new architecture
- [ ] Documentation updated
- [ ] Team briefed on changes

## 🎯 Success Criteria

The deployment is considered successful when:
1. All packages deploy without errors
2. Registry contains all expected decoders
3. A test DAO can be created
4. A test proposal can be executed via PTB
5. All actions execute correctly
6. No gas or resource leaks observed

---

**Last Updated**: 2025-01-14
**Status**: Ready for Deployment
**Next Steps**: Run `./deploy_verified.sh` and follow post-deployment verification