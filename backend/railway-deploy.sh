#!/bin/bash

# Railway deployment script with conditional DB reset
# This script checks environment variables to determine deployment behavior

SERVICE=${1:-"all"}
echo "Railway deployment starting for service: $SERVICE"

# Validate required environment variables
if [ -z "$NETWORK" ]; then
    echo "ERROR: NETWORK environment variable is required"
    exit 1
fi

if [ -z "$DB_RESET_ON_DEPLOY" ]; then
    echo "WARNING: DB_RESET_ON_DEPLOY not set, defaulting to false"
    DB_RESET_ON_DEPLOY="false"
fi

echo "Network: ${NETWORK}"
echo "DB Reset on Deploy: ${DB_RESET_ON_DEPLOY}"

# Set the appropriate database URL and schema based on network and environment
# Support for 3 Railway projects: mainnet, testnet-dev, testnet-branch
if [ "$NETWORK" = "mainnet" ]; then
    export DATABASE_URL="$MAINNET_DATABASE_URL"
    PRISMA_SCHEMA="prisma/schema.mainnet.prisma"
    echo "Using Mainnet database"
elif [ "$RAILWAY_ENVIRONMENT_NAME" = "testnet-branch" ] || [ "$ENVIRONMENT" = "testnet-branch" ]; then
    # Testnet branch environment (PR previews)
    export DATABASE_URL="$TESTNET_BRANCH_DATABASE_URL"
    PRISMA_SCHEMA="prisma/schema.testnet-branch.prisma"
    echo "Using Testnet Branch database"
else
    # Default to testnet-dev
    export DATABASE_URL="$TESTNET_DATABASE_URL"
    PRISMA_SCHEMA="prisma/schema.testnet-dev.prisma"
    echo "Using Testnet Dev database"
fi

# Log environment details
if [ -n "$RAILWAY_ENVIRONMENT_NAME" ]; then
    echo "Railway environment: $RAILWAY_ENVIRONMENT_NAME"
fi

echo "Database URL: ${DATABASE_URL:-'No database URL set'}"

# Install dependencies
pnpm install

# Generate Prisma client for PostgreSQL if DATABASE_URL is set
if [ -n "$DATABASE_URL" ]; then
    echo "Using PostgreSQL database from DATABASE_URL"
    echo "Generating Prisma client with schema: $PRISMA_SCHEMA"
    npx prisma generate --schema="$PRISMA_SCHEMA"
else
    echo "No DATABASE_URL found - please set MAINNET_DATABASE_URL or TESTNET_DATABASE_URL"
    exit 1
fi

# No SQLite backup needed for PostgreSQL deployments

# Conditional database setup based on environment
# Only run DB operations for indexer service or when SERVICE=all
if [ "$SERVICE" = "indexer" ] || [ "$SERVICE" = "all" ]; then
    if [ "$DB_RESET_ON_DEPLOY" = "true" ]; then
        echo "Running full database reset for indexer..."
        if [ -n "$DATABASE_URL" ]; then
            # PostgreSQL reset
            npx prisma db push --force-reset --schema="$PRISMA_SCHEMA"
            npx prisma db push --schema="$PRISMA_SCHEMA"
        fi
    else
        echo "Skipping database reset (DB_RESET_ON_DEPLOY=false)"
        npx prisma generate --schema="$PRISMA_SCHEMA"
    fi
else
    echo "Skipping database operations for $SERVICE service"
    npx prisma generate --schema="$PRISMA_SCHEMA"
fi

# PostgreSQL deployment - no SQLite configuration needed

echo "Database setup complete"

# Start the appropriate service
case "$SERVICE" in
    "api")
        echo "Starting API service..."
        pnpm api:prod
        ;;
    "indexer")
        echo "Starting Indexer service..."
        pnpm indexer:prod
        ;;
    "poller")
        echo "Starting Poller service..."
        pnpm poll:prod
        ;;
    "bot")
        echo "Starting Bot service..."
        pnpm bot:prod
        ;;
    "all")
        echo "Starting all services..."
        pnpm dev:prod
        ;;
    *)
        echo "ERROR: Unknown service: $SERVICE"
        exit 1
        ;;
esac