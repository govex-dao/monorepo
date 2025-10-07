# Clean Decoder Architecture

## Core Principle
**Decoders are MANDATORY but DECOUPLED from the protocol layer.**

## Architecture Layers

### 1. Protocol Layer (Clean & Unaware)
- **Location**: `packages/protocol/sources/`
- **Files**: `account.move`, `intents.move`, `executable.move`
- **Characteristics**:
  - NO imports of schema or decoder modules
  - NO validation of decoder existence
  - Pure protocol logic only
  - Remains unchanged when adding new action types

### 2. Schema Layer (Registry & Types)
- **Location**: `packages/protocol/sources/schema.move`
- **Purpose**: Define decoder registry and field types
- **Key Functions**:
  - `has_decoder()` - Check if decoder exists
  - `init_registry()` - Create registry
  - Registry is a shared object with well-known address

### 3. Decoder Layer (Action-Specific)
- **Location**: `packages/actions/sources/decoders/`
- **Pattern**: One decoder module per action module
- **Requirements**:
  - Use `bcs::peel_*` functions for deserialization
  - Call `validate_all_bytes_consumed()` for security
  - Return `vector<HumanReadableField>`
  - Never reconstruct original action structs

### 4. Application Layer (Enforcement Point)
- **Location**: User-facing entry functions (e.g., DAO proposals)
- **Responsibility**: MANDATORY decoder validation
- **Pattern**:
```move
public entry fun create_proposal(
    registry: &ActionDecoderRegistry,  // MANDATORY parameter
    // ... other params
) {
    // Validate decoder exists BEFORE creating action
    assert!(schema::has_decoder(registry, action_type), EDecoderNotFound);

    // Then proceed with action creation
    intents::add_action_spec(...);
}
```

## Key Design Decisions

### ✅ DO:
- Pass `&ActionDecoderRegistry` to ALL entry functions that create actions
- Validate decoder existence at the APPLICATION layer
- Keep protocol layer completely unaware of decoders
- Use `assert!` for mandatory validation (fail fast)
- Register decoders during package initialization

### ❌ DON'T:
- Add schema imports to protocol modules
- Create validation functions in intents.move
- Make registry part of Account struct
- Allow action creation without decoder validation
- Mix protocol logic with decoder logic

## Benefits

1. **Clean Separation**: Protocol remains simple and focused
2. **Mandatory Transparency**: All actions MUST be decodeable
3. **Future-Proof**: New actions just need decoder registration
4. **Zero Protocol Overhead**: Validation only at entry points
5. **Easy Auditing**: Validation logic is explicit at application boundary
6. **No Circular Dependencies**: Clear hierarchical structure

## Example Implementation

```move
// APPLICATION LAYER (e.g., DAO module)
public entry fun create_treasury_proposal(
    registry: &ActionDecoderRegistry,  // Mandatory
    amount: u64,
    recipient: address,
    ctx: &mut TxContext,
) {
    // Step 1: Validate decoder exists
    let action_type = type_name::get<SpendAction>();
    assert!(schema::has_decoder(registry, action_type), EDecoderNotFound);

    // Step 2: Create and serialize action
    let action = create_spend_action(amount, recipient);
    let action_data = bcs::to_bytes(&action);

    // Step 3: Add to intent (protocol layer - no validation here)
    intents::add_action_spec(intent, action, action_data, witness);
}
```

## Registry Deployment

The `ActionDecoderRegistry` is deployed as a single, globally shared object:
1. Created during `decoder_registry_init::init()`
2. All decoders registered at initialization
3. Shared publicly with well-known address
4. Referenced by ALL applications that create actions

## Summary

This architecture achieves mandatory decoder validation while maintaining perfect separation of concerns. The protocol layer stays clean, the application layer enforces business rules, and transparency is guaranteed for all actions.