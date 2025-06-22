#!/bin/bash

# Simple frontend build script
echo "Building frontend..."

# Install dependencies
pnpm install

# Build the frontend
pnpm run build

echo "Frontend build complete"