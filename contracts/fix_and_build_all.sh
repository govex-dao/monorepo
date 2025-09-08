#!/bin/bash

echo "Fixing all Move.toml files with correct addresses..."

# Standard addresses
ACCOUNT_PROTOCOL="0x3524efaf502bb2f845416b1cd73c97bd6130a6f28db9384c55c40b358cf96870"
ACCOUNT_EXTENSIONS="0x32b220eb8e08ffb4a9e946bdbdd90af6f4fe510f121fed438f3f1e6531eae7dd"
ACCOUNT_ACTIONS="0x56cdad1b3e1135d97ac713f69e3d23a7dbbcf6500711b4bb71cbdff46e274491"
FUTARCHY_ONE_SHOT_UTILS="0xb75ab3ad0f9da83d84a226e386a48bbf8ca008a52ff17a9911ee3062c6c7c992"
FUTARCHY_CORE="0xb83cf6f284ec86322d20940e02685cfdc67a1dcf0cfa5384aeebea8cd21ac041"
FUTARCHY_MARKETS="0xce09dd82dbbfda7c8b49f937ac595d1130b60c48e422cfe2d9f47d0972337b2c"
FUTARCHY_VAULT="0xb6ca67bdaf5e00e3551c1f966c8c609b3a5c2cb0b9c19b9e95bb3c088c2cf7f4"
FUTARCHY_MULTISIG="0xdc3cf6f284ec86322d20940e02685cfdc67a1dcf0cfa5384aeebea8cd21af732"
FUTARCHY_LIFECYCLE="0xec3cf6f284ec86322d20940e02685cfdc67a1dcf0cfa5384aeebea8cd21bf843"
FUTARCHY_ACTIONS="0xfc3cf6f284ec86322d20940e02685cfdc67a1dcf0cfa5384aeebea8cd21cf954"
FUTARCHY_SPECIALIZED_ACTIONS="0x0d3cf6f284ec86322d20940e02685cfdc67a1dcf0cfa5384aeebea8cd21dfa65"
FUTARCHY_DAO="0x1d3cf6f284ec86322d20940e02685cfdc67a1dcf0cfa5384aeebea8cd21efa76"

# Function to add addresses if not present
add_addresses() {
    local file=$1
    shift
    for addr_line in "$@"; do
        if ! grep -q "$(echo $addr_line | cut -d= -f1)" "$file"; then
            echo "$addr_line" >> "$file"
        fi
    done
}

# Fix futarchy_multisig
echo "Fixing futarchy_multisig..."
cat > /Users/admin/monorepo/contracts/futarchy_multisig/Move.toml << EOF
[package]
name = "futarchy_multisig"
edition = "2024.beta"
published-at = "0x0"

[dependencies]
AccountProtocol = { local = "../move-framework/packages/protocol" }
AccountExtensions = { local = "../move-framework/packages/extensions" }
futarchy_one_shot_utils = { local = "../futarchy_one_shot_utils" }
futarchy_core = { local = "../futarchy_core" }

[addresses]
futarchy_multisig = "$FUTARCHY_MULTISIG"
account_protocol = "$ACCOUNT_PROTOCOL"
account_extensions = "$ACCOUNT_EXTENSIONS"
futarchy_one_shot_utils = "$FUTARCHY_ONE_SHOT_UTILS"
futarchy_core = "$FUTARCHY_CORE"
EOF

# Fix futarchy_lifecycle
echo "Fixing futarchy_lifecycle..."
cat > /Users/admin/monorepo/contracts/futarchy_lifecycle/Move.toml << EOF
[package]
name = "futarchy_lifecycle"
edition = "2024.beta"
published-at = "0x0"

[dependencies]
AccountProtocol = { local = "../move-framework/packages/protocol" }
AccountExtensions = { local = "../move-framework/packages/extensions" }
AccountActions = { local = "../move-framework/packages/actions" }
futarchy_one_shot_utils = { local = "../futarchy_one_shot_utils" }
futarchy_core = { local = "../futarchy_core" }
futarchy_markets = { local = "../futarchy_markets" }
futarchy_vault = { local = "../futarchy_vault" }

[addresses]
futarchy_lifecycle = "$FUTARCHY_LIFECYCLE"
account_protocol = "$ACCOUNT_PROTOCOL"
account_extensions = "$ACCOUNT_EXTENSIONS"
account_actions = "$ACCOUNT_ACTIONS"
futarchy_one_shot_utils = "$FUTARCHY_ONE_SHOT_UTILS"
futarchy_core = "$FUTARCHY_CORE"
futarchy_markets = "$FUTARCHY_MARKETS"
futarchy_vault = "$FUTARCHY_VAULT"
EOF

# Fix futarchy_actions
echo "Fixing futarchy_actions..."
cat > /Users/admin/monorepo/contracts/futarchy_actions/Move.toml << EOF
[package]
name = "futarchy_actions"
edition = "2024.beta"
published-at = "0x0"

[dependencies]
AccountProtocol = { local = "../move-framework/packages/protocol" }
AccountExtensions = { local = "../move-framework/packages/extensions" }
AccountActions = { local = "../move-framework/packages/actions" }
futarchy_one_shot_utils = { local = "../futarchy_one_shot_utils" }
futarchy_core = { local = "../futarchy_core" }
futarchy_markets = { local = "../futarchy_markets" }
futarchy_multisig = { local = "../futarchy_multisig" }
futarchy_vault = { local = "../futarchy_vault" }
futarchy_lifecycle = { local = "../futarchy_lifecycle" }

[addresses]
futarchy_actions = "$FUTARCHY_ACTIONS"
account_protocol = "$ACCOUNT_PROTOCOL"
account_extensions = "$ACCOUNT_EXTENSIONS"
account_actions = "$ACCOUNT_ACTIONS"
futarchy_one_shot_utils = "$FUTARCHY_ONE_SHOT_UTILS"
futarchy_core = "$FUTARCHY_CORE"
futarchy_markets = "$FUTARCHY_MARKETS"
futarchy_multisig = "$FUTARCHY_MULTISIG"
futarchy_vault = "$FUTARCHY_VAULT"
futarchy_lifecycle = "$FUTARCHY_LIFECYCLE"
EOF

# Fix futarchy_specialized_actions
echo "Fixing futarchy_specialized_actions..."
cat > /Users/admin/monorepo/contracts/futarchy_specialized_actions/Move.toml << EOF
[package]
name = "futarchy_specialized_actions"
edition = "2024.beta"
published-at = "0x0"

[dependencies]
AccountProtocol = { local = "../move-framework/packages/protocol" }
AccountExtensions = { local = "../move-framework/packages/extensions" }
AccountActions = { local = "../move-framework/packages/actions" }
futarchy_one_shot_utils = { local = "../futarchy_one_shot_utils" }
futarchy_core = { local = "../futarchy_core" }
futarchy_markets = { local = "../futarchy_markets" }
futarchy_multisig = { local = "../futarchy_multisig" }
futarchy_vault = { local = "../futarchy_vault" }
futarchy_lifecycle = { local = "../futarchy_lifecycle" }
futarchy_actions = { local = "../futarchy_actions" }

[addresses]
futarchy_specialized_actions = "$FUTARCHY_SPECIALIZED_ACTIONS"
account_protocol = "$ACCOUNT_PROTOCOL"
account_extensions = "$ACCOUNT_EXTENSIONS"
account_actions = "$ACCOUNT_ACTIONS"
futarchy_one_shot_utils = "$FUTARCHY_ONE_SHOT_UTILS"
futarchy_core = "$FUTARCHY_CORE"
futarchy_markets = "$FUTARCHY_MARKETS"
futarchy_multisig = "$FUTARCHY_MULTISIG"
futarchy_vault = "$FUTARCHY_VAULT"
futarchy_lifecycle = "$FUTARCHY_LIFECYCLE"
futarchy_actions = "$FUTARCHY_ACTIONS"
EOF

# Fix futarchy_dao
echo "Fixing futarchy_dao..."
cat > /Users/admin/monorepo/contracts/futarchy_dao/Move.toml << EOF
[package]
name = "futarchy_dao"
edition = "2024.beta"
published-at = "0x0"

[dependencies]
AccountProtocol = { local = "../move-framework/packages/protocol" }
AccountExtensions = { local = "../move-framework/packages/extensions" }
AccountActions = { local = "../move-framework/packages/actions" }
futarchy_one_shot_utils = { local = "../futarchy_one_shot_utils" }
futarchy_core = { local = "../futarchy_core" }
futarchy_markets = { local = "../futarchy_markets" }
futarchy_multisig = { local = "../futarchy_multisig" }
futarchy_vault = { local = "../futarchy_vault" }
futarchy_lifecycle = { local = "../futarchy_lifecycle" }
futarchy_actions = { local = "../futarchy_actions" }
futarchy_specialized_actions = { local = "../futarchy_specialized_actions" }

[addresses]
futarchy_dao = "$FUTARCHY_DAO"
account_protocol = "$ACCOUNT_PROTOCOL"
account_extensions = "$ACCOUNT_EXTENSIONS"
account_actions = "$ACCOUNT_ACTIONS"
futarchy_one_shot_utils = "$FUTARCHY_ONE_SHOT_UTILS"
futarchy_core = "$FUTARCHY_CORE"
futarchy_markets = "$FUTARCHY_MARKETS"
futarchy_multisig = "$FUTARCHY_MULTISIG"
futarchy_vault = "$FUTARCHY_VAULT"
futarchy_lifecycle = "$FUTARCHY_LIFECYCLE"
futarchy_actions = "$FUTARCHY_ACTIONS"
futarchy_specialized_actions = "$FUTARCHY_SPECIALIZED_ACTIONS"
EOF

echo "Building all packages in dependency order..."

# Build packages in dependency order
packages=(
    "futarchy_multisig"
    "futarchy_lifecycle"
    "futarchy_actions"
    "futarchy_specialized_actions"
    "futarchy_dao"
)

for package in "${packages[@]}"; do
    echo ""
    echo "Building $package..."
    cd /Users/admin/monorepo/contracts/$package
    if sui move build 2>&1 | tail -5 | grep -q "Failed to build"; then
        echo "ERROR: Failed to build $package"
        sui move build 2>&1 | grep "error\[" | head -10
        exit 1
    else
        echo "✓ $package built successfully"
    fi
done

echo ""
echo "All packages built successfully!"