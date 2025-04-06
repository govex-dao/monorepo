#!/bin/bash

# Exit on error
set -e

echo "Preparing fresh db..."

# Install dependencies once
pnpm install --ignore-workspace

# Remove existing Prisma files/folders
rm -rf node_modules/.prisma
rm -rf node_modules/@prisma
rm -rf prisma/migrations

# Remove SQLite database files
rm -f prisma/dev.db
rm -f prisma/dev.db-shm
rm -f prisma/dev.db-wal

# Install Prisma dependencies once
pnpm add -D prisma @prisma/client

# Run database setup with migrations
# This will:
# 1. Create the database
# 2. Create and apply migrations
# 3. Generate Prisma Client
pnpm db:setup:dev

# Configure SQLite WAL mode
cd prisma
sqlite3 dev.db "PRAGMA journal_mode=WAL;"
cd ..