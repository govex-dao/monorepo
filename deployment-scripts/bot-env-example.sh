#!/bin/bash

# Example environment variables for the Futarchy Bot
# Copy this file to bot-env.sh and fill in your actual values

# REQUIRED - Bot wallet private key (hex format, no 0x prefix)
export SUI_PRIVATE_KEY="your_private_key_here"

# REQUIRED - Package ID from your Futarchy contract deployment
export PACKAGE_ID="0x..."

# REQUIRED - Fee Manager ID from your deployment
export FEE_MANAGER_ID="0x..."

# OPTIONAL - RPC endpoint (defaults to testnet)
# export SUI_RPC_URL="https://fullnode.testnet.sui.io:443"

# OPTIONAL - Polling interval in milliseconds (default: 60000 = 1 minute)
# export POLL_INTERVAL_MS="60000"

# OPTIONAL - Health check server port (default: 3001)
# export HEALTH_CHECK_PORT="3001"

# OPTIONAL - Discord/Slack webhook for alerts
# export ALERT_WEBHOOK_URL="https://discord.com/api/webhooks/..."

# OPTIONAL - Unique instance ID (auto-generated if not set)
# export BOT_INSTANCE_ID="bot-1"

# OPTIONAL - Environment (development/production)
# export NODE_ENV="production"

# For the backend API server:
# REQUIRED - Network configuration
export NETWORK="testnetProd"  # or "devnet" or "testnet"