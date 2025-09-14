#!/bin/bash

# Script to update all intent creation functions to include registry parameter and schema checks

echo "Updating intent creation functions to enforce schema checks..."

# Update liquidity_intents.move
cat > /tmp/liquidity_intents_update.patch << 'EOF'
--- Update imports
+ use std::type_name;
+ use account_protocol::schema::{Self, ActionDecoderRegistry};

--- Update function signatures to include registry parameter
--- Add schema checks before creating intents
EOF

echo "✓ Created update plan for liquidity_intents"

# Update dissolution_intents.move
cat > /tmp/dissolution_intents_update.patch << 'EOF'
--- Update imports
+ use std::type_name;
+ use account_protocol::schema::{Self, ActionDecoderRegistry};

--- Update function signatures to include registry parameter
--- Add schema checks before creating intents
EOF

echo "✓ Created update plan for dissolution_intents"

# Update stream_intents.move
cat > /tmp/stream_intents_update.patch << 'EOF'
--- Update imports
+ use std::type_name;
+ use account_protocol::schema::{Self, ActionDecoderRegistry};

--- Update function signatures to include registry parameter
--- Add schema checks before creating intents
EOF

echo "✓ Created update plan for stream_intents"

# Update oracle_intents.move
cat > /tmp/oracle_intents_update.patch << 'EOF'
--- Update imports
+ use std::type_name;
+ use account_protocol::schema::{Self, ActionDecoderRegistry};

--- Update function signatures to include registry parameter
--- Add schema checks before creating intents
EOF

echo "✓ Created update plan for oracle_intents"

echo ""
echo "Schema enforcement update plan complete!"
echo ""
echo "Key changes needed for each module:"
echo "1. Add imports for type_name and schema"
echo "2. Add registry: &ActionDecoderRegistry parameter to all public functions"
echo "3. Add schema::assert_decoder_exists() calls before creating intents"
echo "4. Update all callers to pass the registry"

echo ""
echo "Example pattern:"
echo "----------------------------------------"
cat << 'EXAMPLE'
public fun create_some_intent<Outcome: store + drop + copy>(
    account: &mut Account<FutarchyConfig>,
    registry: &ActionDecoderRegistry,  // NEW: Add registry parameter
    params: Params,
    outcome: Outcome,
    // ... other params
    ctx: &mut TxContext
) {
    // NEW: Enforce decoder exists
    schema::assert_decoder_exists(
        registry,
        type_name::get<SomeAction>()
    );

    // Existing intent creation logic...
    account.build_intent!(
        // ...
    );
}
EXAMPLE

chmod +x /tmp/update_intents_with_registry.sh