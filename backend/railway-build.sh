#!/bin/bash

# Railway build script that determines the correct build command
# based on Railway environment name or branch name

echo "Starting Railway build..."
echo "RAILWAY_ENVIRONMENT_NAME: ${RAILWAY_ENVIRONMENT_NAME}"
echo "RAILWAY_GIT_BRANCH: ${RAILWAY_GIT_BRANCH}"

# Determine which build script to run
if [ "$RAILWAY_ENVIRONMENT_NAME" = "mainnet" ]; then
    echo "Building for mainnet environment"
    pnpm build:mainnet
elif [ "$RAILWAY_ENVIRONMENT_NAME" = "testnet-dev" ]; then
    echo "Building for testnet-dev environment"
    pnpm build:testnet-dev
elif [ "$RAILWAY_ENVIRONMENT_NAME" = "testnet-branch" ]; then
    echo "Building for testnet-branch environment"
    pnpm build:testnet-branch
elif [ "$RAILWAY_GIT_BRANCH" = "main" ]; then
    echo "Building for main branch (mainnet)"
    pnpm build:mainnet
elif [ "$RAILWAY_GIT_BRANCH" = "dev" ]; then
    echo "Building for dev branch (testnet-dev)"
    pnpm build:testnet-dev
else
    # For PR branches or other cases
    echo "Building for branch environment (testnet-branch)"
    pnpm build:testnet-branch
fi