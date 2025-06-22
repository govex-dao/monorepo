#!/bin/bash

# Railway build script that determines the correct build command
# based on Railway environment name or branch name

echo "Starting Railway build..."
echo "Current directory: $(pwd)"
echo "RAILWAY_ENVIRONMENT_NAME: ${RAILWAY_ENVIRONMENT_NAME}"
echo "RAILWAY_GIT_BRANCH: ${RAILWAY_GIT_BRANCH}"

# Change to backend directory if we're in the monorepo root
if [ -d "backend" ]; then
    echo "Changing to backend directory"
    cd backend
fi

# Determine which schema to use and copy it as the default
if [ "$RAILWAY_ENVIRONMENT_NAME" = "mainnet" ] || [ "$RAILWAY_GIT_BRANCH" = "main" ]; then
    echo "Using mainnet schema"
    cp prisma/schema.mainnet.prisma prisma/schema.prisma
    BUILD_CMD="pnpm build:mainnet"
else
    # Default to testnet-dev for dev branch or testnet-dev environment
    echo "Using testnet-dev schema"
    cp prisma/schema.testnet-dev.prisma prisma/schema.prisma
    BUILD_CMD="pnpm build:testnet-dev"
fi

# Generate the default Prisma client from the copied schema
echo "Generating Prisma client..."
npx prisma generate

# Run the environment-specific build
echo "Running build command: $BUILD_CMD"
$BUILD_CMD