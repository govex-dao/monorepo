#!/bin/bash

echo "================================================"
echo "    Verifying Futarchy Package Deployments     "
echo "================================================"
echo ""
echo "Network: $(sui client active-env)"
echo ""

# Package list with addresses from Move.toml files
declare -a PACKAGES=(
    "futarchy_one_shot_utils:0x34bd77744460768abfd00692b7c40a1a09fdca117b52e7c875a1d722651850fc"
    "futarchy_core:0x9507a06101f44857b3bdd57ab9a60ffc9fc9afe23e5186f721220a1be41ca863"
    "futarchy_markets:0x6a549ebafdd9c642532e65c6a8b87a25a13bf3665ddb6c50bde48c8e0cc03964"
    "futarchy_vault:0xb360eeeb047d085e587ae609ad6113df2af0b9b1ec7448bc7ec07069a55f06db"
    "futarchy_multisig:0x6f22314d606df195552d49f415a108eb4ce760e3af7205166f938ea5bdde7c70"
    "futarchy_specialized_actions:0xfa9401996c917e62953be31177dcb83a23eb68799bacd159775f4a8e8188ba7f"
    "futarchy_lifecycle:0x9ec194f9d5bb53efd7368e3683c9e28cd126b64bda3ce4f0dd3ca904f2d16d73"
    "futarchy_actions:0xc0c3290355401394c8340da4f8ac3f122afa7331f4790ca662512bf03da00f49"
    "futarchy_dao:0x96eae499fa55b24245d02b451cb6dcdfbd8862447ac53441607543fab94dc2d4"
)

echo "Checking owned UpgradeCaps:"
echo "----------------------------"
# Get all UpgradeCaps we own
UPGRADE_CAPS=$(sui client objects --json 2>/dev/null | jq -r '.[] | select(.data.type == "0x2::package::UpgradeCap") | .data.content.fields.package')

deployed_count=0
for entry in "${PACKAGES[@]}"; do
    IFS=':' read -r name expected_addr <<< "$entry"
    
    # Check if we have an UpgradeCap for this package address
    if echo "$UPGRADE_CAPS" | grep -q "^$expected_addr$"; then
        echo "✓ $name: $expected_addr (DEPLOYED)"
        ((deployed_count++))
    else
        echo "✗ $name: $expected_addr (NOT FOUND in owned objects)"
    fi
done

echo ""
echo "Summary: $deployed_count/9 packages confirmed deployed"
echo ""

# Also show all UpgradeCaps we own
echo "All owned UpgradeCaps:"
echo "----------------------"
sui client objects --json 2>/dev/null | jq -r '.[] | select(.data.type == "0x2::package::UpgradeCap") | "Package: \(.data.content.fields.package)"' | sort -u