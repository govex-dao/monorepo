# Railway Multi-Service 3-Project Setup Guide

This guide explains how to set up your Govex backend as 4 separate services (API, Bot, Indexer, Poller) across 3 Railway projects with complete isolation between all environments.

## Architecture Overview

The backend is split into 4 independent services:

1. **API Service** (port 3000)
   - REST API server with health check at `/health`
   - Contains Google Gemini LLM integration for proposal reviews
   - Handles all HTTP requests from frontend

2. **Bot Service** (port 3001)
   - Advances proposals through state machine
   - Executes finalized proposals on-chain
   - Has circuit breaker and retry logic

3. **Indexer Service**
   - Listens to Sui blockchain events
   - Updates database with on-chain state
   - Critical for data consistency

4. **Poller Service**
   - Polls TWAP price data every 30 minutes
   - Only processes proposals in trading state
   - Lightweight periodic job

## Project Structure

### 1. **Mainnet** (Production)
- **Branch**: `main`
- **Services**: govex-api, govex-bot, govex-indexer, govex-poller
- **Database**: Separate PostgreSQL instance
- **Environment Variables**:
  ```
  NETWORK=mainnet
  MAINNET_DATABASE_URL=<Railway-provided PostgreSQL URL>
  DB_RESET_ON_DEPLOY=false
  ```
- **Schema**: `prisma/schema.mainnet.prisma`
- **Purpose**: Production mainnet deployment

### 2. **Testnet Dev**
- **Branch**: `dev`
- **Services**: govex-api, govex-bot, govex-indexer, govex-poller
- **Database**: Separate PostgreSQL instance
- **Environment Variables**:
  ```
  NETWORK=testnet
  TESTNET_DEV_DATABASE_URL=<Railway-provided PostgreSQL URL>
  DB_RESET_ON_DEPLOY=true
  RAILWAY_ENVIRONMENT_NAME=testnet-dev
  ```
- **Schema**: `prisma/schema.testnet-dev.prisma`
- **Purpose**: Development environment for testnet

### 3. **Testnet Branch** (PR Previews)
- **Branch**: Feature branches / PR previews
- **Services**: govex-api, govex-bot, govex-indexer, govex-poller
- **Database**: Separate PostgreSQL instance
- **Environment Variables**:
  ```
  NETWORK=testnet
  TESTNET_BRANCH_DATABASE_URL=<Railway-provided PostgreSQL URL>
  DB_RESET_ON_DEPLOY=true
  RAILWAY_ENVIRONMENT_NAME=testnet-branch
  ```
- **Schema**: `prisma/schema.testnet-branch.prisma`
- **Purpose**: Testing feature branches and PR previews

## Step-by-Step Setup

### Step 1: Create Railway Projects

1. Go to [Railway Dashboard](https://railway.app/dashboard)
2. Create three new projects:
   - `govex-mainnet`
   - `govex-testnet-dev`
   - `govex-testnet-branch`

### Step 2: Create Services in Each Project

For **each** project, create 4 services:

```bash
# 1. API Service
railway service create govex-api

# 2. Bot Service  
railway service create govex-bot

# 3. Indexer Service
railway service create govex-indexer

# 4. Poller Service
railway service create govex-poller
```

### Step 3: Add PostgreSQL to Each Project

```bash
railway plugin create postgresql
```

### Step 4: Configure Service Settings

In each service's Railway dashboard settings:

1. **API Service**:
   - Source: GitHub repo
   - Root Directory: `/`
   - Config Path: `railway.api.json`
   - Watch Paths: `backend/**`

2. **Bot Service**:
   - Source: GitHub repo
   - Root Directory: `/`
   - Config Path: `railway.bot.json`
   - Watch Paths: `backend/**`

3. **Indexer Service**:
   - Source: GitHub repo
   - Root Directory: `/`
   - Config Path: `railway.indexer.json`
   - Watch Paths: `backend/**`

4. **Poller Service**:
   - Source: GitHub repo
   - Root Directory: `/`
   - Config Path: `railway.poller.json`
   - Watch Paths: `backend/**`

## Key Benefits

1. **Service Isolation**: Each service can be deployed/scaled independently
2. **Complete Environment Isolation**: Each environment has its own database
3. **Schema Flexibility**: Mainnet and testnet can have different schemas
4. **Safe Testing**: Test features on testnet without affecting mainnet
5. **PR Previews**: Test branches before merging to dev

## Environment Variables Setup

### Global Variables (Set in all services):

```env
# Sui Configuration
SUI_RPC_URL=<your-sui-rpc-url>
SUI_WEBSOCKET_URL=<your-sui-websocket-url>
ADMIN_CAP=<admin-capability-id>
ADMIN_ADDRESS=<admin-address>
PRIVATE_KEY=<encrypted-private-key>
PACKAGE_ID=<sui-package-id>
CLOCK_ID=0x6
```

### Database URLs

Each Railway project automatically provides a `DATABASE_URL`. You need to:

1. **In Mainnet project**: 
   - Copy `DATABASE_URL` value
   - Create `MAINNET_DATABASE_URL` with same value
   - Set in all 4 services

2. **In Testnet Dev project**:
   - Copy `DATABASE_URL` value
   - Create `TESTNET_DEV_DATABASE_URL` with same value
   - Set in all 4 services

3. **In Testnet Branch project**:
   - Copy `DATABASE_URL` value
   - Create `TESTNET_BRANCH_DATABASE_URL` with same value
   - Set in all 4 services

### Service-Specific Variables:

**API Service only**:
```env
# Google Gemini API
GEMINI_API_KEY=<your-gemini-api-key>
GLOBAL_DAILY_LIMIT=1000

# CORS
CORS_ORIGIN=https://your-frontend.com
```

**Bot Service only**:
```env
# Webhooks (optional)
DISCORD_WEBHOOK_URL=<discord-webhook>
SLACK_WEBHOOK_URL=<slack-webhook>
```

**Indexer Service only**:
```env
# Set to true only for initial deployment or resets
DB_RESET_ON_DEPLOY=false
```

## GitHub Actions Setup

### Add Repository Secrets:

```
# Railway API Tokens
RAILWAY_TOKEN_MAINNET=<mainnet-project-token>
RAILWAY_TOKEN_DEV=<testnet-dev-project-token>
RAILWAY_TOKEN_BRANCH=<testnet-branch-project-token>

# Database URLs
MAINNET_DATABASE_URL=<mainnet-postgres-url>
TESTNET_DEV_DATABASE_URL=<testnet-dev-postgres-url>
TESTNET_BRANCH_DATABASE_URL=<testnet-branch-postgres-url>
```

### Deployment Workflows:

1. **Automatic Deployments**:
   - Push to `main` → All 4 services deploy to mainnet
   - Push to `dev` → All 4 services deploy to testnet-dev
   - Open PR → All 4 services deploy to testnet-branch

2. **Manual Deployments**:
   - Go to Actions → "Deploy Multi-Service to Railway"
   - Select environment and services
   - Optionally reset database (indexer only)

## Deployment Flow

1. **Feature Development**:
   - Create feature branch
   - Push to trigger Testnet Branch deployment
   - All 4 services deploy automatically
   - Test in isolated environment

2. **Testnet Integration**:
   - Merge to `dev` branch
   - All 4 services automatically deploy to Testnet Dev
   - Monitor logs across services

3. **Mainnet Deployment**:
   - Merge to `main` branch
   - All 4 services automatically deploy to Mainnet
   - Verify health checks

## Service Management

### Viewing Logs:

```bash
# All services in a project
railway logs --environment testnet-dev

# Specific service
railway logs --service govex-api --environment testnet-dev

# Follow logs
railway logs --service govex-indexer --environment testnet-dev --follow
```

### Restarting Services:

```bash
# Restart specific service
railway restart --service govex-bot --environment testnet-dev

# Restart all services
railway restart --environment testnet-dev
```

### Health Monitoring:

- **API**: `https://<api-domain>/health`
- **Bot**: `https://<bot-domain>/health`
- **Indexer**: No health endpoint (check logs)
- **Poller**: No health endpoint (check logs)

## Troubleshooting

### Common Issues:

1. **Database Connection Errors**:
   - Verify all services have correct DATABASE_URL
   - Check if <NETWORK>_DATABASE_URL is set
   - Ensure PostgreSQL plugin is added

2. **Build Failures**:
   - Check NETWORK env var is set
   - Verify Prisma schema files exist
   - Ensure pnpm-lock.yaml is committed

3. **Service Not Starting**:
   - Check logs for specific error
   - Verify all required env vars
   - Check health check is accessible

4. **Indexer Issues**:
   - May need DB_RESET_ON_DEPLOY=true for first deploy
   - Check WebSocket connection to Sui
   - Verify event types match contract

### Database Reset (Emergency):

```bash
# Only for indexer service
railway variables set DB_RESET_ON_DEPLOY=true --service govex-indexer --environment testnet-dev
railway restart --service govex-indexer --environment testnet-dev
# Reset back immediately
railway variables set DB_RESET_ON_DEPLOY=false --service govex-indexer --environment testnet-dev
```

## Best Practices

1. **Deployment Order**:
   - Deploy indexer first (manages database schema)
   - Then API and Bot services
   - Poller last (depends on data)

2. **Scaling**:
   - API: 2+ replicas for high availability
   - Bot: Always 1 replica (uses locks)
   - Indexer: Always 1 replica (sequential)
   - Poller: Always 1 replica (periodic)

3. **Monitoring**:
   - Set up alerts for service failures
   - Monitor Gemini API usage (API service)
   - Track database connections
   - Watch for WebSocket disconnections (Indexer)

4. **Security**:
   - Rotate PRIVATE_KEY regularly
   - Use encrypted secrets
   - Separate API keys per environment
   - Restrict database access

## Schema Management

The deployment script automatically selects the correct schema:

```bash
# Mainnet uses schema.mainnet.prisma
# Testnet Dev uses schema.testnet-dev.prisma  
# Testnet Branch uses schema.testnet-branch.prisma
```

This allows you to:
- Test new database features on testnet branch first
- Promote tested features to testnet dev
- Keep mainnet schema stable
- Have environment-specific tables for testing

## Generating Prisma Clients

Before deploying, generate all Prisma clients locally:

```bash
pnpm db:generate:all
```

Or generate individually:
```bash
pnpm db:generate:mainnet
pnpm db:generate:testnet-dev
pnpm db:generate:testnet-branch
```