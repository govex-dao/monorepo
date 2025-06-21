# Railway Deployment Guide - Simple Edition

## Overview

Super simple 2-service deployment:
- **Backend**: Everything server-side (API, Indexer, Poller, Bot)
- **Frontend**: React app

## Architecture

- **backend** - All server services (uses `backend.nixpacks.toml`)
- **frontend** - React app (uses `frontend/nixpacks.toml`)

### Database
- **Development**: SQLite (`dev.db`)
- **Production**: PostgreSQL (Railway managed)

## Environment Configuration

### Required Environment Variables

#### Backend Service
- `NETWORK`: Either `testnet` or `mainnet`
- `DATABASE_URL`: PostgreSQL connection string (provided by Railway)
- `DB_RESET_ON_DEPLOY`: `true` for testnet, `false` for mainnet
- `TESTNET_RPC_URL` / `MAINNET_RPC_URL`: Network-specific RPC endpoints
- `BOT_PRIVATE_KEY`: Bot wallet private key
- Additional configuration (see `.env.example`)

#### Frontend Service
- `VITE_NETWORK`: Either `testnet` or `mainnet`
- `VITE_API_URL`: Backend API URL

## Railway Setup

### 1. Create Railway Project

1. Create a new Railway project
2. Add PostgreSQL database to the project
3. Create two services:
   - `backend` → Set config: `/backend.nixpacks.toml`
   - `frontend` → Set config: `/frontend/nixpacks.toml`
4. Connect both services to your GitHub repo

### 2. Configure Environments

Create two environments in Railway:

#### Staging (testnet)
- Connect to `dev` branch
- Set variables:
  ```
  NETWORK=testnet
  VITE_NETWORK=testnet
  DB_RESET_ON_DEPLOY=true
  ```

#### Production (mainnet)
- Connect to `main` branch
- Set variables:
  ```
  NETWORK=mainnet
  VITE_NETWORK=mainnet
  DB_RESET_ON_DEPLOY=false
  ```

### 3. Database Configuration

- **Production**: Railway PostgreSQL (automatically provisioned)
- **Local Dev**: SQLite (`dev.db`)

The `DATABASE_URL` environment variable is automatically set by Railway when you add PostgreSQL.

## Deployment Process

### Automatic Deployment

Deployments trigger automatically on:
- Push to `dev` → Deploys to testnet/staging
- Push to `main` → Deploys to mainnet/production

### Manual Selective Deployment (GitHub Actions)

1. Go to Actions tab in GitHub
2. Select "Selective Railway Deploy"
3. Click "Run workflow"
4. Choose:
   - Environment (staging/production)
   - Which services to deploy (checkboxes)
5. Click "Run workflow"

### Manual Deployment (Railway CLI)

```bash
# Deploy all services to staging
railway up --environment staging

# Deploy all services to production
railway up --environment production

# Deploy specific service
railway up -e production -s backend
railway up -e production -s frontend
```

### Database Reset Behavior

- **Testnet**: Backend runs database reset on deploy if `DB_RESET_ON_DEPLOY=true`
- **Mainnet**: No database resets, only schema updates
- Control via GitHub Actions UI or Railway environment variables

## Service URLs

After deployment, Railway provides URLs for:
- Backend API: `https://[service-name].railway.app`
- Frontend: `https://[service-name].railway.app`

Update frontend's `VITE_API_URL` to point to the backend service URL.

## Monitoring

- Check Railway dashboard for deployment logs
- Backend health check: `GET /health`
- Database backups stored as `*.backup.[timestamp]`

## Rollback Strategy

1. Use Railway's deployment history to rollback
2. Database backups are created before resets
3. Keep Digital Ocean deployment as fallback during migration

## Migration from Digital Ocean

1. Export data from DO: `scp root@[ip]:/root/monorepo/backend/dev.db ./`
2. Rename to appropriate file (`testnet.db` or `mainnet.db`)
3. Upload to Railway volume or include in deployment
4. Update DNS records to point to Railway URLs
5. Monitor for 24-48 hours before decommissioning DO server

## Troubleshooting

### Database Issues
- Check if correct database file is being used
- Verify `DATABASE_URL` environment variable
- Look for backup files if data was lost

### Environment Variables
- Ensure all required variables are set in Railway
- Check logs for validation errors
- Variables must be set per-service in Railway

### Build Failures
- Check nixpacks.toml configuration
- Verify all dependencies in package.json
- Review build logs in Railway dashboard

## Security Notes

- Never commit `.env` files
- Use Railway's secret management for sensitive data
- Database files are not included in git
- Backups are local to the deployment instance