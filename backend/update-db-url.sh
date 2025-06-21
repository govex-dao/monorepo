#!/bin/bash

# Update Prisma database URL based on environment

if [ "$NETWORK" = "testnet" ]; then
    DB_FILE="testnet.db"
elif [ "$NETWORK" = "mainnet" ]; then
    DB_FILE="mainnet.db"
else
    # Default to dev.db for local development
    DB_FILE="dev.db"
fi

# Export the DATABASE_URL for Prisma to use
export DATABASE_URL="file:./${DB_FILE}?pragma=journal_mode=WAL&pragma=synchronous=normal&pragma=busy_timeout=5000"

echo "Database URL set to: $DATABASE_URL"