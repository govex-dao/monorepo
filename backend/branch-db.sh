#!/bin/bash

# Exit on error
set -e

echo "Preparing branch db..."

# Install dependencies ignoring workspace
pnpm install --ignore-workspace

# Remove existing Prisma files/folders
rm -rf node_modules/.prisma
rm -rf node_modules/@prisma
rm -rf prisma/migrations

# Reinstall Prisma dependencies
pnpm add -D prisma
pnpm add @prisma/client

pnpm exec prisma generate
