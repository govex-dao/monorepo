# Approval System Implementation Status

## ✅ Completed Core Infrastructure

### 1. Action Descriptor Module
**Location**: `move-framework/packages/extensions/sources/action_descriptor.move`
- Simple descriptor with category, action_type, and optional target_object
- Uses vector<u8> for efficiency
- Pattern generation for matching policies

### 2. Intent Updates
**Location**: `move-framework/packages/protocol/sources/types/intents.move`
- Added `action_descriptors: vector<ActionDescriptor>` field
- Added `add_action_with_descriptor()` function
- Added `descriptors()` getter

### 3. Policy Registry Multi-Council Support
**Location**: `futarchy_multisig/sources/policy/policy_registry.move`
- Added `PolicyRule` struct with council_id and mode
- Pattern-based policies: `b"treasury/mint"` → specific council ID + mode
- Object-specific policies: object_id → specific council ID + mode
- Approval modes: DAO_ONLY, COUNCIL_ONLY, DAO_OR_COUNCIL, DAO_AND_COUNCIL

### 4. Descriptor Analyzer
**Location**: `futarchy_multisig/sources/policy/descriptor_analyzer.move`
- Analyzes all descriptors in an intent
- Returns which specific council ID is needed
- Returns approval mode (DAO, council, both, either)

### 5. Action Dispatcher with Approval Gate
**Location**: `futarchy_actions/sources/action_dispatcher.move`
- `execute_with_approvals()` function checks approvals before execution
- Takes vector of council Accounts that have approved
- Verifies the specific required council is present
- Atomic execution - all actions or none

## ⏳ Remaining Work

### Add Descriptors to All Actions

#### Move Framework Actions
- [✅] Vault: `new_spend_with_descriptor`, `new_deposit_with_descriptor`
- [ ] Currency: mint, burn actions
- [ ] Owned: transfer ownership actions
- [ ] Package upgrade actions

#### Futarchy Actions
- [ ] Governance: create_proposal, update_config
- [ ] Liquidity: create_pool, update_parameters
- [ ] Oracle: conditional_mint, tiered_mint
- [ ] Dissolution: initiate, distribute
- [ ] Stream: create_stream, cancel_stream
- [ ] Operating Agreement: update_terms
- [ ] Commitment: create, execute, withdraw

### Example Policies for a DAO

```move
// Treasury Council (ID: 0x123abc...)
set_pattern_policy(registry, b"treasury/spend", some(0x123abc), MODE_DAO_AND_COUNCIL);
set_pattern_policy(registry, b"treasury/mint", some(0x123abc), MODE_DAO_AND_COUNCIL);

// Technical Council (ID: 0x456def...)
set_pattern_policy(registry, b"upgrade/package", some(0x456def), MODE_DAO_AND_COUNCIL);
set_pattern_policy(registry, b"config/update", some(0x456def), MODE_DAO_OR_COUNCIL);

// Legal Council (ID: 0x789ghi...)
set_pattern_policy(registry, b"legal/operating_agreement", some(0x789ghi), MODE_COUNCIL_ONLY);

// Emergency Council (ID: 0xabcdef...)
set_pattern_policy(registry, b"emergency/pause", some(0xabcdef), MODE_COUNCIL_ONLY);
```

## How It Works

1. **Proposal Creation**: Actions are added with descriptors
2. **Voting**: DAO votes on the proposal
3. **Council Approval**: Required councils review and approve
4. **Execution**: 
   - Check all descriptors to determine requirements
   - Verify DAO approved (winning outcome)
   - Verify specific required councils approved
   - Execute all actions atomically

## Key Design Features

- **Multiple Councils**: Each DAO can have many specialized councils
- **Specific Council IDs**: Policies specify WHICH council must approve
- **Flexible Modes**: DAO only, Council only, Both, Either
- **Pattern Matching**: `b"treasury/*"` can match all treasury actions
- **Object-Specific**: Can require approval for specific objects (e.g., specific UpgradeCap)
- **Atomic Execution**: All actions execute or none - no partial execution

## Testing Needed

1. Test pattern matching for different action categories
2. Test multiple councils with different responsibilities
3. Test all four approval modes
4. Test object-specific policies
5. Test atomic execution with missing approvals