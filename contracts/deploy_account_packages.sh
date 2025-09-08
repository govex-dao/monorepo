#!/bin/bash
set -e

echo "========================================"
echo "Deploying Account Protocol packages"
echo "========================================"
echo ""

# Deploy AccountExtensions first (no dependencies)
echo "1. Deploying AccountExtensions..."
cd /Users/admin/monorepo/contracts/move-framework/packages/extensions

# Reset address to 0x0
sed -i '' 's/account_extensions = "0x[^"]*"/account_extensions = "0x0"/' Move.toml

# Build and deploy
sui move build --skip-fetch-latest-git-deps
OUTPUT=$(sui client publish --gas-budget 5000000000 2>&1)
EXTENSIONS_ID=$(echo "$OUTPUT" | grep -oE "PackageID: 0x[a-f0-9]{64}" | head -1 | cut -d' ' -f2)

if [ -z "$EXTENSIONS_ID" ]; then
    EXTENSIONS_ID=$(echo "$OUTPUT" | grep -A5 "Published Objects" | grep -oE "0x[a-f0-9]{64}" | head -1)
fi

if [ -z "$EXTENSIONS_ID" ]; then
    echo "❌ Failed to deploy AccountExtensions"
    echo "$OUTPUT" | tail -30
    exit 1
fi

echo "✅ AccountExtensions deployed: $EXTENSIONS_ID"

# Update AccountExtensions address in all Move.toml files
cd /Users/admin/monorepo/contracts
find . -name "Move.toml" -exec sed -i '' "s/account_extensions = \"0x[^\"]*\"/account_extensions = \"${EXTENSIONS_ID}\"/" {} \;

echo ""

# Deploy AccountProtocol (depends on Extensions)
echo "2. Deploying AccountProtocol..."
cd /Users/admin/monorepo/contracts/move-framework/packages/protocol

# Reset address to 0x0
sed -i '' 's/account_protocol = "0x[^"]*"/account_protocol = "0x0"/' Move.toml

# Build and deploy
sui move build --skip-fetch-latest-git-deps
OUTPUT=$(sui client publish --gas-budget 5000000000 2>&1)
PROTOCOL_ID=$(echo "$OUTPUT" | grep -oE "PackageID: 0x[a-f0-9]{64}" | head -1 | cut -d' ' -f2)

if [ -z "$PROTOCOL_ID" ]; then
    PROTOCOL_ID=$(echo "$OUTPUT" | grep -A5 "Published Objects" | grep -oE "0x[a-f0-9]{64}" | head -1)
fi

if [ -z "$PROTOCOL_ID" ]; then
    echo "❌ Failed to deploy AccountProtocol"
    echo "$OUTPUT" | tail -30
    exit 1
fi

echo "✅ AccountProtocol deployed: $PROTOCOL_ID"

# Update AccountProtocol address in all Move.toml files
cd /Users/admin/monorepo/contracts
find . -name "Move.toml" -exec sed -i '' "s/account_protocol = \"0x[^\"]*\"/account_protocol = \"${PROTOCOL_ID}\"/" {} \;

echo ""

# Deploy AccountActions (depends on Protocol and Extensions)
echo "3. Deploying AccountActions..."
cd /Users/admin/monorepo/contracts/move-framework/packages/actions

# Reset address to 0x0
sed -i '' 's/account_actions = "0x[^"]*"/account_actions = "0x0"/' Move.toml

# Build and deploy
sui move build --skip-fetch-latest-git-deps
OUTPUT=$(sui client publish --gas-budget 5000000000 2>&1)
ACTIONS_ID=$(echo "$OUTPUT" | grep -oE "PackageID: 0x[a-f0-9]{64}" | head -1 | cut -d' ' -f2)

if [ -z "$ACTIONS_ID" ]; then
    ACTIONS_ID=$(echo "$OUTPUT" | grep -A5 "Published Objects" | grep -oE "0x[a-f0-9]{64}" | head -1)
fi

if [ -z "$ACTIONS_ID" ]; then
    echo "❌ Failed to deploy AccountActions"
    echo "$OUTPUT" | tail -30
    exit 1
fi

echo "✅ AccountActions deployed: $ACTIONS_ID"

# Update AccountActions address in all Move.toml files
cd /Users/admin/monorepo/contracts
find . -name "Move.toml" -exec sed -i '' "s/account_actions = \"0x[^\"]*\"/account_actions = \"${ACTIONS_ID}\"/" {} \;

echo ""
echo "========================================"
echo "Account Protocol packages deployed!"
echo "========================================"
echo ""
echo "AccountExtensions: $EXTENSIONS_ID"
echo "AccountProtocol: $PROTOCOL_ID"
echo "AccountActions: $ACTIONS_ID"