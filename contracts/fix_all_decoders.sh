#!/bin/bash

echo "Fixing all decoder files to remove deprecated type_name APIs..."

# List of decoder files to fix
DECODERS=(
    "/Users/admin/monorepo/contracts/futarchy_lifecycle/sources/payments/payment_decoder.move"
    "/Users/admin/monorepo/contracts/futarchy_lifecycle/sources/payments/stream_decoder.move"
    "/Users/admin/monorepo/contracts/futarchy_lifecycle/sources/dissolution/dissolution_decoder.move"
    "/Users/admin/monorepo/contracts/futarchy_lifecycle/sources/oracle/oracle_decoder.move"
    "/Users/admin/monorepo/contracts/futarchy_specialized_actions/sources/legal/operating_agreement_decoder.move"
    "/Users/admin/monorepo/contracts/futarchy_actions/sources/intent_lifecycle/founder_lock_decoder.move"
    "/Users/admin/monorepo/contracts/futarchy_actions/sources/intent_lifecycle/protocol_admin_decoder.move"
    "/Users/admin/monorepo/contracts/futarchy_actions/sources/liquidity/liquidity_decoder.move"
    "/Users/admin/monorepo/contracts/futarchy_actions/sources/governance/governance_decoder.move"
    "/Users/admin/monorepo/contracts/futarchy_actions/sources/governance/platform_fee_decoder.move"
    "/Users/admin/monorepo/contracts/futarchy_actions/sources/memo/memo_decoder.move"
    "/Users/admin/monorepo/contracts/futarchy_actions/sources/config/config_decoder.move"
    "/Users/admin/monorepo/contracts/futarchy_multisig/sources/security_council_decoder.move"
    "/Users/admin/monorepo/contracts/futarchy_multisig/sources/policy/policy_decoder.move"
    "/Users/admin/monorepo/contracts/futarchy_vault/sources/custody_decoder.move"
)

for FILE in "${DECODERS[@]}"; do
    if [ -f "$FILE" ]; then
        echo "Fixing: $FILE"

        # Replace deprecated type_name::get with type_name::with_defining_ids
        sed -i '' 's/type_name::get</type_name::with_defining_ids</g' "$FILE"

        # Replace deprecated type_name::get_address with type_name::address_string
        sed -i '' 's/type_name::get_address(/type_name::address_string(/g' "$FILE"

        # Replace deprecated type_name::get_module with type_name::module_string
        sed -i '' 's/type_name::get_module(/type_name::module_string(/g' "$FILE"

        echo "  ✓ Fixed $FILE"
    else
        echo "  ⚠ File not found: $FILE"
    fi
done

echo ""
echo "All decoder files have been updated!"
echo "Deprecated APIs replaced:"
echo "  - type_name::get → type_name::with_defining_ids"
echo "  - type_name::get_address → type_name::address_string"
echo "  - type_name::get_module → type_name::module_string"