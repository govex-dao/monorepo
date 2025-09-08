#!/bin/bash
set -e

echo "========================================"
echo "Complete deployment of all packages"
echo "========================================"
echo ""

# First, deploy Account packages
echo "========================================="
echo "Deploying Account Protocol packages..."
echo "========================================="
./deploy_account_packages.sh

echo ""
echo "========================================="
echo "Deploying Futarchy packages..."
echo "========================================="

# Now run the futarchy deployment
./fresh_deploy.sh

echo ""
echo "========================================="
echo "All packages deployed successfully!"
echo "========================================="