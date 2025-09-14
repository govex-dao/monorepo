# On-Chain Schema System Implementation Guide

## Overview

This guide documents the on-chain schema system that makes Move framework actions self-describing. This solves the "Decoder Maintenance Problem" where every new action type breaks all downstream tools.

## Design Principles

### Complete Decoupling
Schema registration is **completely separate** from action creation:
- Schemas are registered **once** during protocol initialization
- Action creation remains simple and unchanged
- No need to pass registry references through the call stack

### Handling Generics
The registry uses a **placeholder type** for generic actions:
- Generic actions like `SpendAction<CoinType>` are registered as `SpendAction<GenericPlaceholder>`
- Clients strip type parameters to find the base schema
- One schema serves all instances of a generic type

### Single Source of Truth
The `ActionSchemaRegistry` is the **only** source of truth for schemas:
- No redundant flags or duplicate state
- TypeName in ActionSpec is the lookup key
- Registry provides the decode instructions

### Clean Architecture
- **ActionSpec**: Unchanged - stores action type and data
- **ActionSchemaRegistry**: Shared object with all schemas
- **Protocol Init**: One-time schema registration
- **Clients**: Smart enough to handle generic type lookups

## The Problem We're Solving

### Before: The Decoder Maintenance Problem

```typescript
// Every wallet/SDK needs hardcoded knowledge of every action type
function decodeAction(spec: ActionSpec): any {
  switch(spec.action_type) {
    case "0xabc::vault::SpendAction":
      // Hardcoded: We "know" this has String + u64
      return {
        vault_name: bcs.readString(),
        amount: bcs.readU64()
      };
    case "0xdef::new_module::NewAction":
      // Unknown action = can't decode
      return { error: "Unknown action type" };
  }
}
```

**Problems:**
- Every new action breaks all clients
- Centralized SDK dependency
- Users can't verify what they're signing
- Third-party tools can't integrate

### After: Self-Describing Actions

```typescript
// Universal decoder that never needs updates
async function decodeAction(spec: ActionSpec, registry: SchemaRegistry): any {
  const schema = await registry.getSchema(spec.action_type);
  return universalDecode(spec.action_data, schema);
}
```

## Architecture

### 1. Core Components

#### ActionSchemaRegistry (Shared Object)
```move
public struct ActionSchemaRegistry has key {
    schemas: Table<TypeName, ActionSchema>,
}
```
- Globally accessible registry of all action schemas
- Anyone can read schemas to decode actions
- Only action modules can register their schemas

#### ActionSchema
```move
public struct ActionSchema has store, copy, drop {
    action_type: TypeName,
    fields: vector<FieldSchema>,
    description: String,
}
```
- Complete schema for one action type
- Describes field names, types, and meanings
- Human-readable description

#### FieldSchema
```move
public struct FieldSchema has store, copy, drop {
    name: String,           // "recipient"
    description: String,    // "Address to receive tokens"
    type_info: TypeInfo,   // address_type()
    optional: bool,        // false
}
```

#### TypeInfo
```move
public struct TypeInfo has store, copy, drop {
    base_type: String,              // "u64", "vector", "struct"
    type_params: vector<TypeInfo>,  // For vector<T>, Option<T>
    struct_path: Option<String>,    // For custom structs
}
```

### 2. Clean Integration with ActionSpec

```move
public struct ActionSpec has store, copy, drop {
    version: u8,
    action_type: TypeName,      // This IS the key to lookup schemas
    action_data: vector<u8>,    // BCS-serialized action
}
```

**Key Design Principle**: ActionSpec remains unchanged. The `action_type` field is already the perfect key for schema lookups. No redundant flags or modifications needed.

## Implementation Steps

### Step 1: Protocol Initialization

```move
// In protocol_schema_init module - called once during deployment
fun init(ctx: &mut TxContext) {
    // Create registry
    let mut registry = schema::init_registry(ctx);

    // Register all schemas
    schema_registry::register_all_schemas(&mut registry);

    // Share for public access
    transfer::share_object(registry);
}
```

### Step 2: Register Schemas for Generic Actions

```move
module account_actions::vault_schemas;

use account_protocol::schema;
use account_actions::vault::{SpendAction, DepositAction};

public fun register_schemas(registry: &mut ActionSchemaRegistry) {
    // For generic types, use GenericPlaceholder
    register_spend_schema(registry);
    register_deposit_schema(registry);
}

fun register_spend_schema(registry: &mut ActionSchemaRegistry) {
    let fields = vector[
        schema::new_field_schema(
            b"name".to_string(),
            b"Vault name".to_string(),
            schema::string_type(),
            false,
        ),
        schema::new_field_schema(
            b"amount".to_string(),
            b"Amount to withdraw".to_string(),
            schema::u64_type(),
            false,
        ),
    ];

    // Register with placeholder for ALL coin types
    let schema_obj = schema::new_action_schema(
        type_name::get<SpendAction<schema::GenericPlaceholder>>(),
        fields,
        b"Withdraw from vault".to_string(),
    );

    schema::register_schema(registry, schema_obj);
}
```

### Step 3: Action Creation Remains Simple

```move
public fun add_spend_action<Outcome, IW: drop>(
    intent: &mut Intent<Outcome>,
    vault_name: String,
    amount: u64,
    recipient: address,
    witness: IW,
) {
    let action = SpendAction { vault_name, amount, recipient };
    let action_bytes = bcs::to_bytes(&action);

    // Just use the standard add_action_spec - no changes needed!
    intents::add_action_spec(
        intent,
        SpendActionType {},
        action_bytes,
        witness,
    );
}
```

**Clean Architecture**: The action module's responsibility is to:
1. Register its schema once during initialization
2. Use the standard `add_action_spec` API

The client's responsibility is to:
1. Look up schemas in the registry using `action_type`
2. Decode if schema exists, show "Unknown Action" if not

## Client Implementation

### TypeScript Universal Decoder

```typescript
interface DecodedAction {
  type: string;
  description: string;
  fields: Record<string, any>;
}

class UniversalActionDecoder {
  constructor(
    private suiClient: SuiClient,
    private registryAddress: string
  ) {}

  async decodeAction(spec: ActionSpec): Promise<DecodedAction> {
    // 1. Handle generic types by stripping type parameters
    const baseType = this.getBaseType(spec.action_type);
    // e.g., "vault::SpendAction<0x2::sui::SUI>" -> "vault::SpendAction<GenericPlaceholder>"

    // 2. Fetch schema from registry using base type
    const schema = await this.fetchSchema(baseType);

    // 3. If no schema exists, fallback to showing raw type
    if (!schema) {
      return this.fallbackDecode(spec);
    }

    // 3. Decode using schema
    const reader = new BCSReader(spec.action_data);
    const fields: Record<string, any> = {};

    for (const field of schema.fields) {
      try {
        fields[field.name] = await this.decodeField(
          reader,
          field.type_info
        );
      } catch (e) {
        if (!field.optional) throw e;
        fields[field.name] = null;
      }
    }

    return {
      type: spec.action_type,
      description: schema.description,
      fields
    };
  }

  private async decodeField(
    reader: BCSReader,
    typeInfo: TypeInfo
  ): Promise<any> {
    switch (typeInfo.base_type) {
      // Primitives
      case "u8": return reader.readU8();
      case "u16": return reader.readU16();
      case "u32": return reader.readU32();
      case "u64": return reader.readU64();
      case "u128": return reader.readU128();
      case "u256": return reader.readU256();
      case "bool": return reader.readBool();
      case "address": return reader.readAddress();
      case "string": return reader.readString();

      // Containers
      case "vector": {
        const length = reader.readULEB128();
        const elements = [];
        for (let i = 0; i < length; i++) {
          elements.push(
            await this.decodeField(reader, typeInfo.type_params[0])
          );
        }
        return elements;
      }

      case "option": {
        const hasValue = reader.readBool();
        if (!hasValue) return null;
        return await this.decodeField(reader, typeInfo.type_params[0]);
      }

      // Structs
      case "struct": {
        return await this.decodeStruct(
          reader,
          typeInfo.struct_path!
        );
      }

      default:
        throw new Error(`Unknown type: ${typeInfo.base_type}`);
    }
  }

  private async decodeStruct(
    reader: BCSReader,
    structPath: string
  ): Promise<any> {
    // Handle known Sui types
    switch (structPath) {
      case "0x2::object::ID":
        return reader.readAddress(); // IDs are 32-byte addresses

      case "0x2::type_name::TypeName":
        return reader.readString(); // TypeNames serialize as strings

      default:
        // For custom structs, fetch their schema
        const structSchema = await this.fetchSchema(structPath);
        if (!structSchema) {
          throw new Error(`No schema for struct: ${structPath}`);
        }
        return this.decodeWithSchema(reader, structSchema);
    }
  }

  private async fetchSchema(typeName: string): Promise<Schema | null> {
    const registry = await this.suiClient.getObject({
      id: this.registryAddress,
      options: { showContent: true }
    });

    // Extract schema from registry's Table
    // Implementation depends on Sui SDK version
    return this.extractSchemaFromRegistry(registry, typeName);
  }
}
```

### Rust Universal Decoder

```rust
use sui_sdk::types::base_types::ObjectID;
use move_core_types::account_address::AccountAddress;
use bcs;

pub struct UniversalDecoder {
    registry: ActionSchemaRegistry,
}

impl UniversalDecoder {
    pub fn decode_action(&self, spec: &ActionSpec) -> Result<DecodedAction> {
        // Get schema from registry using action_type as key
        let schema = match self.registry.get_schema(&spec.action_type) {
            Some(s) => s,
            None => return Ok(DecodedAction::Unknown(spec.action_type.clone())),
        };

        // Decode fields
        let mut reader = bcs::Deserializer::new(&spec.action_data);
        let mut fields = HashMap::new();

        for field in &schema.fields {
            match self.decode_field(&mut reader, &field.type_info) {
                Ok(value) => {
                    fields.insert(field.name.clone(), value);
                }
                Err(e) if !field.optional => return Err(e),
                Err(_) => {
                    fields.insert(field.name.clone(), Value::Null);
                }
            }
        }

        Ok(DecodedAction::Decoded {
            action_type: spec.action_type.clone(),
            description: schema.description.clone(),
            fields,
        })
    }

    fn decode_field(
        &self,
        reader: &mut bcs::Deserializer,
        type_info: &TypeInfo,
    ) -> Result<Value> {
        match type_info.base_type.as_str() {
            "u8" => Ok(Value::U8(bcs::from_bytes(reader)?)),
            "u64" => Ok(Value::U64(bcs::from_bytes(reader)?)),
            "bool" => Ok(Value::Bool(bcs::from_bytes(reader)?)),
            "address" => Ok(Value::Address(bcs::from_bytes(reader)?)),
            "string" => Ok(Value::String(bcs::from_bytes(reader)?)),

            "vector" => {
                let len: u64 = bcs::from_bytes(reader)?;
                let mut elements = Vec::new();
                for _ in 0..len {
                    elements.push(
                        self.decode_field(reader, &type_info.type_params[0])?
                    );
                }
                Ok(Value::Vector(elements))
            }

            "option" => {
                let has_value: bool = bcs::from_bytes(reader)?;
                if has_value {
                    Ok(Value::Some(Box::new(
                        self.decode_field(reader, &type_info.type_params[0])?
                    )))
                } else {
                    Ok(Value::None)
                }
            }

            "struct" => self.decode_struct(reader, type_info.struct_path.as_ref().unwrap()),

            _ => Err(format!("Unknown type: {}", type_info.base_type))
        }
    }
}
```

## Benefits Analysis

### 1. Future-Proofing
- **Before**: Every new action breaks all clients
- **After**: New actions automatically decodeable

### 2. Decentralization
- **Before**: Everyone depends on centralized SDK
- **After**: Self-sufficient on-chain data

### 3. Security & Transparency
- **Before**: Users trust wallet's interpretation
- **After**: Users see exact on-chain schema

### 4. Developer Experience
- **Before**: Maintain action decoders forever
- **After**: Write schema once, works everywhere

### 5. Ecosystem Growth
- **Before**: High barrier for third-party tools
- **After**: Anyone can build compatible tools

## Storage Cost Analysis

### Per-Action Overhead
```
Without schema: ~50 bytes (version + type + data)
With schema flag: ~51 bytes (+1 byte for has_schema bool)
```

### Registry Storage (One-Time)
```
Per action type: ~200-500 bytes (depending on field count)
Example DAO with 50 action types: ~10-25 KB total
```

### Cost-Benefit
- **Cost**: ~2% overhead per action + one-time registry storage
- **Benefit**: Eliminates ongoing maintenance burden for entire ecosystem

## Migration Strategy

### Phase 1: Deploy Infrastructure
1. Deploy schema registry as shared object
2. Update ActionSpec to include has_schema flag
3. Deploy universal decoder libraries

### Phase 2: Register Core Schemas
1. Register schemas for all standard actions
2. Update action creation to use schema-aware functions
3. Test with universal decoder

### Phase 3: Ecosystem Adoption
1. Document schema registration process
2. Provide decoder implementations in multiple languages
3. Encourage third-party action modules to register schemas

### Phase 4: Deprecate Legacy
1. Mark non-schema actions as deprecated
2. Provide migration tools
3. Eventually require schemas for new actions

## Best Practices

### 1. Schema Design
- Use descriptive field names
- Provide clear descriptions
- Keep schemas stable (versioning for changes)
- Validate schemas before registration

### 2. Type Modeling
- Prefer simple types when possible
- Document complex struct schemas separately
- Use optional fields for backwards compatibility

### 3. Client Implementation
- Cache schemas locally for performance
- Handle missing schemas gracefully
- Provide human-readable fallbacks
- Validate decoded data against business rules

## Example: Complete Integration

### Move Module
```move
module my_dao::advanced_actions;

use account_protocol::{intents, schema};

public struct ComplexAction has drop {
    operation: u8,
    targets: vector<address>,
    amounts: vector<u64>,
    metadata: Option<Metadata>,
}

public struct Metadata has drop, store {
    timestamp: u64,
    initiator: address,
    notes: String,
}

public fun init(registry: &mut ActionSchemaRegistry) {
    register_complex_action_schema(registry);
}

fun register_complex_action_schema(registry: &mut ActionSchemaRegistry) {
    let fields = vector[
        schema::new_field_schema(
            b"operation".to_string(),
            b"Operation code (1=transfer, 2=stake, 3=burn)".to_string(),
            schema::u8_type(),
            false,
        ),
        schema::new_field_schema(
            b"targets".to_string(),
            b"Target addresses for the operation".to_string(),
            schema::vector_type(schema::address_type()),
            false,
        ),
        schema::new_field_schema(
            b"amounts".to_string(),
            b"Amounts corresponding to each target".to_string(),
            schema::vector_type(schema::u64_type()),
            false,
        ),
        schema::new_field_schema(
            b"metadata".to_string(),
            b"Optional metadata about the operation".to_string(),
            schema::option_type(
                schema::struct_type(b"my_dao::advanced_actions::Metadata".to_string())
            ),
            true,
        ),
    ];

    schema::register_schema(
        registry,
        schema::new_action_schema(
            type_name::get<ComplexAction>(),
            fields,
            b"Execute complex multi-target operation".to_string(),
        )
    );
}
```

### Client Usage
```typescript
// Initialize decoder once
const decoder = new UniversalActionDecoder(
  suiClient,
  SCHEMA_REGISTRY_ADDRESS
);

// Decode any action automatically
const intent = await fetchIntent(intentId);
for (const spec of intent.action_specs) {
  const decoded = await decoder.decodeAction(spec);
  console.log(`Action: ${decoded.description}`);
  console.log(`Fields:`, decoded.fields);

  // Display to user
  displayActionToUser(decoded);
}

// User sees:
// "Execute complex multi-target operation"
// - operation: 1 (transfer)
// - targets: [0x123..., 0x456...]
// - amounts: [1000, 2000]
// - metadata: { timestamp: 1234567890, ... }
```

## Conclusion

The on-chain schema system transforms the Move framework from "extensible in theory" to "extensible in practice". By making action data self-describing, we eliminate the decoder maintenance problem and enable a truly decentralized, scalable ecosystem.

### Key Takeaways
1. **One-time setup**: Register schema once, works forever
2. **Universal compatibility**: Any client can decode any action
3. **Future-proof**: New actions don't break existing tools
4. **Transparent**: Users know exactly what they're signing
5. **Decentralized**: No dependency on centralized SDKs

This infrastructure investment is critical for building protocols that scale beyond a single team's maintenance capacity.