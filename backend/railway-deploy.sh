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
echo "Database URL: ${DATABASE_URL:-'Using default from schema.prisma'}"

# Install dependencies
pnpm install

# Generate Prisma client for PostgreSQL if DATABASE_URL is set
if [ -n "$DATABASE_URL" ]; then
    echo "Using PostgreSQL database from DATABASE_URL"
    npx prisma generate
else
    echo "No DATABASE_URL found - for local dev, create .env with:"
    echo 'DATABASE_URL="file:./dev.db"'
    exit 1
fi

# Backup database if it exists (before any operations)
if [ -f "$DB_FILE" ] && [ "$DB_RESET_ON_DEPLOY" = "true" ]; then
    BACKUP_FILE="${DB_FILE}.backup.$(date +%Y%m%d_%H%M%S)"
    echo "Creating database backup: $BACKUP_FILE"
    cp "$DB_FILE" "$BACKUP_FILE"
fi

# Conditional database setup based on environment
# Only run DB operations for indexer service or when SERVICE=all
if [ "$SERVICE" = "indexer" ] || [ "$SERVICE" = "all" ]; then
    if [ "$DB_RESET_ON_DEPLOY" = "true" ]; then
        echo "Running full database reset for indexer..."
        if [ -n "$DATABASE_URL" ]; then
            # PostgreSQL reset
            npx prisma db push --force-reset
            npx prisma db push
        else
            # SQLite reset
            pnpm fresh:db
            pnpm branch:db
        fi
    else
        echo "Skipping database reset (DB_RESET_ON_DEPLOY=false)"
        npx prisma generate
    fi
else
    echo "Skipping database operations for $SERVICE service"
    npx prisma generate
fi

# Set SQLite to WAL mode only if using SQLite
if [ -z "$DATABASE_URL" ] && [ -f "$DB_FILE" ]; then
    sqlite3 "$DB_FILE" 'PRAGMA journal_mode=WAL;' || true
fi

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