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

# Set the appropriate schema based on Railway environment
# DATABASE_URL is already set by Railway
# NETWORK is for Sui blockchain (mainnet/testnet)
# RAILWAY_ENVIRONMENT_NAME is for deployment environment (mainnet/testnet-dev/testnet-branch)

if [ "$RAILWAY_ENVIRONMENT_NAME" = "mainnet" ]; then
    PRISMA_SCHEMA="prisma/schema.mainnet.prisma"
    echo "Using Mainnet schema for Railway environment: $RAILWAY_ENVIRONMENT_NAME"
elif [ "$RAILWAY_ENVIRONMENT_NAME" = "testnet-branch" ]; then
    PRISMA_SCHEMA="prisma/schema.testnet-branch.prisma"
    echo "Using Testnet Branch schema for Railway environment: $RAILWAY_ENVIRONMENT_NAME"
elif [ "$RAILWAY_ENVIRONMENT_NAME" = "testnet-dev" ]; then
    PRISMA_SCHEMA="prisma/schema.testnet-dev.prisma"
    echo "Using Testnet Dev schema for Railway environment: $RAILWAY_ENVIRONMENT_NAME"
else
    # Default to testnet-dev if RAILWAY_ENVIRONMENT_NAME is not set
    PRISMA_SCHEMA="prisma/schema.testnet-dev.prisma"
    echo "Using default Testnet Dev schema (RAILWAY_ENVIRONMENT_NAME not set)"
fi

echo "Sui Network: ${NETWORK}"
echo "Railway Environment: ${RAILWAY_ENVIRONMENT_NAME}"

# Log environment details
if [ -n "$RAILWAY_ENVIRONMENT_NAME" ]; then
    echo "Railway environment: $RAILWAY_ENVIRONMENT_NAME"
fi

echo "Database URL: ${DATABASE_URL:0:20}..." # Show first 20 chars for security

# Install dependencies
pnpm install

# Generate Prisma client for PostgreSQL if DATABASE_URL is set
if [ -n "$DATABASE_URL" ]; then
    echo "Using PostgreSQL database from DATABASE_URL"
    echo "Generating Prisma client with schema: $PRISMA_SCHEMA"
    npx prisma generate --schema="$PRISMA_SCHEMA"
else
    echo "No DATABASE_URL found - please set DATABASE_URL environment variable"
    exit 1
fi

# No SQLite backup needed for PostgreSQL deployments

# Handle database operations for migrator service
if [ "$SERVICE" = "migrator" ]; then
    echo "Running database migration service..."
    if [ "$DB_RESET_ON_DEPLOY" = "true" ]; then
        echo "Running full database reset..."
        npx prisma db push --force-reset --schema="$PRISMA_SCHEMA"
        npx prisma db push --schema="$PRISMA_SCHEMA"
    else
        echo "Running database migrations..."
        npx prisma migrate deploy --schema="$PRISMA_SCHEMA"
    fi
    echo "Migration complete"
    exit 0
fi

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
    "migrator")
        echo "ERROR: Migrator should have exited earlier"
        exit 1
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