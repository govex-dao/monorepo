# Railway Deployment Guide - Multi-Service Edition

## Current Architecture: 5 Independent Services

Your application is split into 5 independent Railway services:

- **API Service**: REST API with Gemini AI integration (port 3000)
- **Bot Service**: Proposal state machine (port 3001)
- **Indexer Service**: Blockchain event listener
- **Poller Service**: TWAP price poller
- **Frontend**: React application

Service configuration files:
- `railway.api.json` - API service
- `railway.bot.json` - Bot service
- `railway.indexer.json` - Indexer service
- `railway.poller.json` - Poller service
- `frontend/nixpacks.toml` - Frontend service

## Service Architecture

```
┌─────────────┐     ┌─────────────┐     ┌─────────────┐
│   Frontend  │────▶│  API Service │     │ Bot Service │
│  (React App)│     │  (Port 3000) │     │ (Port 3001) │
└─────────────┘     └─────────────┘     └─────────────┘
                           │                     │
                           ▼                     ▼
                    ┌─────────────┐       ┌─────────────┐
                    │   Indexer   │       │   Poller    │
                    │   Service   │       │   Service   │
                    └─────────────┘       └─────────────┘
                           │                     │
                           ▼                     ▼
                    ┌─────────────────────────────┐
                    │        PostgreSQL           │
                    └─────────────────────────────┘
```

## Railway Project Structure

You need 3 separate Railway projects for different environments:

1. **govex-mainnet** (Production)
   - Branch: `main`
   - Services: api, bot, indexer, poller, frontend
   - Database: PostgreSQL (production)

2. **govex-testnet-dev** (Development)
   - Branch: `dev`
   - Services: api, bot, indexer, poller, frontend
   - Database: PostgreSQL (development)

3. **govex-testnet-branch** (PR Previews)
   - Branch: Feature branches
   - Services: api, bot, indexer, poller, frontend
   - Database: PostgreSQL (testing)

## Setting Up Multi-Service Deployment

### Step 1: Create Railway Projects

```bash
# Create 3 new Railway projects
# Name them: govex-mainnet, govex-testnet-dev, govex-testnet-branch
```

### Step 2: Create Services in Each Project

For **each** Railway project, create these services:

```bash
# API Service
railway service create api

# Bot Service  
railway service create bot

# Indexer Service
railway service create indexer

# Poller Service
railway service create poller

# Frontend Service
railway service create frontend
```

### Step 3: Configure Each Service

In Railway dashboard for each service:

1. **API Service**:
   - Connect to GitHub repo
   - Config Path: `railway.api.json`
   - Root Directory: `/`

2. **Bot Service**:
   - Connect to GitHub repo
   - Config Path: `railway.bot.json`
   - Root Directory: `/`

3. **Indexer Service**:
   - Connect to GitHub repo
   - Config Path: `railway.indexer.json`
   - Root Directory: `/`

4. **Poller Service**:
   - Connect to GitHub repo
   - Config Path: `railway.poller.json`
   - Root Directory: `/`

5. **Frontend Service**:
   - Connect to GitHub repo
   - Config Path: `/frontend/nixpacks.toml`
   - Root Directory: `/`
   - Build Command: `cd frontend && pnpm install && pnpm run build`
   - Start Command: `cd frontend && pnpm run serve`

### Step 4: Add PostgreSQL

```bash
# Add PostgreSQL to each project
railway plugin create postgresql
```

### Step 5: Configure Environment Variables

**Global Variables (Set in ALL backend services)**:
   ```env
   # Network Configuration
   NETWORK=testnet|mainnet
   DATABASE_URL=<auto-provided-by-railway>
   DB_RESET_ON_DEPLOY=true|false
   
   # Sui Configuration
   SUI_RPC_URL=<network-specific-rpc>
   SUI_WEBSOCKET_URL=<network-specific-websocket>
   ADMIN_CAP=<admin-capability>
   ADMIN_ADDRESS=<admin-address>
   PRIVATE_KEY=<encrypted-private-key>
   PACKAGE_ID=<sui-package-id>
   
   # API Configuration
   GEMINI_API_KEY=<gemini-api-key>
   GLOBAL_DAILY_LIMIT=1000
   CORS_ORIGIN=https://your-frontend.railway.app
   ```

   **Frontend Service**:
   ```env
   VITE_NETWORK=testnet|mainnet
   VITE_API_URL=https://your-backend.railway.app
   ```

**Service-Specific Variables**:

1. **API Service Additional**:
   ```env
   PORT=3000
   GEMINI_API_KEY=<your-gemini-api-key>
   GLOBAL_DAILY_LIMIT=1000
   CORS_ORIGIN=https://your-frontend.railway.app
   ```

2. **Bot Service Additional**:
   ```env
   PORT=3001
   DISCORD_WEBHOOK_URL=<optional>
   SLACK_WEBHOOK_URL=<optional>
   ```

3. **Indexer Service Additional**:
   ```env
   DB_RESET_ON_DEPLOY=false  # true for first deploy only
   ```

4. **All Services Need Database URLs**:
   - In mainnet project: Set `MAINNET_DATABASE_URL`
   - In testnet-dev project: Set `TESTNET_DATABASE_URL`
   - In testnet-branch project: Set `TESTNET_BRANCH_DATABASE_URL`

## GitHub Secrets Setup

Add these secrets to your GitHub repository (Settings → Secrets → Actions):

```
# Railway API Tokens (get from Railway dashboard)
RAILWAY_TOKEN_MAINNET=<mainnet-project-token>
RAILWAY_TOKEN_DEV=<testnet-dev-project-token>
RAILWAY_TOKEN_BRANCH=<testnet-branch-project-token>

# Database URLs (copy from Railway PostgreSQL plugins)
MAINNET_DATABASE_URL=<mainnet-postgres-url>
TESTNET_DATABASE_URL=<testnet-dev-postgres-url>
TESTNET_BRANCH_DATABASE_URL=<testnet-branch-postgres-url>
```

## Deployment Methods

### 1. Automatic Deployment
- Push to `dev` → Deploys to testnet/staging
- Push to `main` → Deploys to mainnet/production

### 2. GitHub Actions (Recommended)
```yaml
# Use the multi-service workflow
- Go to Actions → "Deploy Multi-Service to Railway"
- Select environment: mainnet|testnet-dev|testnet-branch
- Select services: all|api,bot,indexer,poller,frontend
- Optional: Reset database (indexer only)
```

### 3. Railway CLI
```bash
# Deploy all services to an environment
railway up --environment testnet-dev

# Deploy specific service
railway up --service api --environment testnet-dev --config railway.api.json
railway up --service bot --environment testnet-dev --config railway.bot.json
railway up --service indexer --environment testnet-dev --config railway.indexer.json
railway up --service poller --environment testnet-dev --config railway.poller.json
```

## Database Management

### Schema Structure
```
├── prisma/
│   ├── schema.prisma          # Main schema (simple setup)
│   ├── schema.mainnet.prisma  # Mainnet-specific
│   ├── schema.testnet-dev.prisma     # Testnet dev
│   └── schema.testnet-branch.prisma  # PR previews
```

### Database Operations
```bash
# Generate Prisma clients
pnpm db:generate:all

# Reset database (testnet only)
railway variables set DB_RESET_ON_DEPLOY=true
railway up
railway variables set DB_RESET_ON_DEPLOY=false
```

### Connection Pooling
- Not needed for <100 customers
- Consider PgBouncer when:
  - You scale API beyond 5-6 replicas
  - You see "too many clients" errors
  - You exceed 80% of PostgreSQL connection limit

## Monitoring & Health Checks

### Simple Setup
- Backend health: `GET /health`
- Frontend: Check Railway dashboard
- Logs: `railway logs`

### Multi-Service Setup
- API health: `https://api-domain/health`
- Bot health: `https://bot-domain/health`
- Service logs: `railway logs --service api`
- Follow logs: `railway logs --service indexer --follow`

## Current Service Status

Based on your configuration:
- ✅ Railway config files ready (railway.*.json)
- ✅ Deployment script supports multi-service
- ✅ Backend code already modularized
- ✅ GitHub Actions workflow created
- ⏳ Need to create Railway projects and deploy

## Deployment Order

When deploying for the first time:

1. **Deploy Indexer first** (with DB_RESET_ON_DEPLOY=true)
2. **Deploy API and Bot** (in parallel)
3. **Deploy Poller**
4. **Deploy Frontend** (update VITE_API_URL to point to API service)
5. **Set DB_RESET_ON_DEPLOY=false** after initial setup

Or simply use "all" in GitHub Actions to deploy everything at once.

## Troubleshooting

### Common Issues

1. **Database Connection Errors**
   ```
   Solution: Verify DATABASE_URL and network-specific URLs
   Check: Railway PostgreSQL plugin is added
   ```

2. **Build Failures**
   ```
   Solution: Check NETWORK env var is set
   Verify: Prisma schema files exist
   Check: pnpm-lock.yaml is committed
   ```

3. **Service Not Starting**
   ```
   Solution: Check all required env vars
   Verify: Health check endpoints accessible
   Check: Service logs for specific errors
   ```

4. **Rate Limit Errors (API)**
   ```
   Solution: Check GEMINI_API_KEY is set
   Monitor: GLOBAL_DAILY_LIMIT usage
   ```

## Best Practices

### For Your Multi-Service Setup
1. Deploy indexer before other services
2. Monitor health checks (API: :3000/health, Bot: :3001/health)
3. Keep single replicas for Bot/Indexer/Poller (they use locks)
4. Scale API replicas as needed (currently set to 2)
5. Set up alerts for service failures

### Security
- Never commit secrets or `.env` files
- Use Railway's secret management
- Rotate PRIVATE_KEY regularly
- Separate API keys per environment
- Enable 2FA on Railway account

## Quick Reference

### Essential Commands
```bash
# View logs
railway logs --environment production

# Deploy specific service
railway up -s backend -e production

# Set environment variable
railway variables set KEY=value

# Link to project
railway link <project-id>

# Run command in service
railway run "pnpm test"
```

### Service URLs
- API Service: `https://api-[env].railway.app`
- Bot Service: `https://bot-[env].railway.app` 
- Frontend: `https://frontend-[env].railway.app`
- API Health: `https://api-[env].railway.app/health`
- Bot Health: `https://bot-[env].railway.app/health`

### Environment Variables Checklist
- [ ] NETWORK (testnet/mainnet)
- [ ] DATABASE_URL (auto-provided)
- [ ] SUI_RPC_URL
- [ ] PRIVATE_KEY (encrypted)
- [ ] GEMINI_API_KEY (API service only)
- [ ] VITE_API_URL (frontend only)

## Support & Resources

- [Railway Documentation](https://docs.railway.app)
- [Railway Status](https://status.railway.app)
- GitHub Issues for project-specific problems
- Railway Discord for platform issues