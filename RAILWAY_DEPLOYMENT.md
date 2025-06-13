# Railway Deployment Guide

This guide explains how to deploy the Govex monorepo on Railway.

## Architecture

This monorepo contains:
- **Backend**: Express/TypeScript API with SQLite database
- **Frontend**: React/Vite application
- **Bot**: Automated trading bot for Futarchy markets

## Deployment Steps

### 1. Create Railway Project

1. Sign up at [railway.app](https://railway.app)
2. Create a new project
3. Connect your GitHub repository

### 2. Deploy Backend Service

1. Create a new service in Railway
2. Name it "backend"
3. Railway will use the nixpacks.toml automatically, or you can set:
   - Build Command: `cd backend && pnpm install && npx prisma generate && npx prisma db push`
   - Start Command: `cd backend && pnpm dev:prod`
4. Set the following environment variables:

```bash
# Required
SUI_PRIVATE_KEY=<your_base64_private_key>
PACKAGE_ID=<your_futarchy_package_id>
FEE_MANAGER_ID=<your_fee_manager_id>
NETWORK=testnet

# Optional
SUI_RPC_URL=https://fullnode.testnet.sui.io:443
POLL_INTERVAL_MS=60000
NODE_ENV=production
```

4. In Settings → General:
   - Set "Start Command" to: `cd backend && npx ts-node server.ts`
   - Or rename `nixpacks.toml` to `nixpacks-backend.toml` and upload it

5. Deploy and note the backend URL (e.g., `https://backend-production-xxxx.up.railway.app`)

### 3. Deploy Frontend Service

1. Create another service in Railway
2. Name it "frontend"
3. In Settings → Build:
   - Build Command: `cd frontend && pnpm install && pnpm vite build`
   - Start Command: `npm install -g serve && cd frontend && serve -s dist -l $PORT`
4. Set environment variable:
   - `BACKEND_URL=<your_backend_url_from_step_2>`

### 4. Deploy Bot Service (Optional)

1. Create a third service for the bot
2. Set the same environment variables as the backend
3. In Settings → Build:
   - Build Command: `cd backend && pnpm install && npx prisma generate`
   - Start Command: `cd backend && pnpm bot:prod`

## Alternative: Using Multiple nixpacks.toml Files

If you want to keep all services in one repo with different configs:

1. **Backend**: Use the default `nixpacks.toml`
2. **Frontend**: 
   - Copy `nixpacks-frontend.toml` to `nixpacks.toml` in a separate branch
   - Or set custom build command in Railway UI
3. **Bot**: Create `nixpacks-bot.toml` with bot-specific configuration

## Environment Variables Reference

### Backend/Bot Services
- `SUI_PRIVATE_KEY` (required): Your Sui wallet private key in base64
- `PACKAGE_ID` (required): Deployed Futarchy contract package ID
- `FEE_MANAGER_ID` (required): Fee manager object ID
- `NETWORK`: Network to use (testnet/devnet/mainnet)
- `SUI_RPC_URL`: Custom RPC endpoint
- `NODE_ENV`: production/development
- `PORT`: Port number (Railway provides this)

### Frontend Service
- `BACKEND_URL` (required): Full URL of your deployed backend
- `VITE_API_URL`: Will be set automatically to `${BACKEND_URL}/api`

## Database

SQLite database will be created automatically in the backend service. For production, consider:
1. Using Railway's PostgreSQL service
2. Updating Prisma schema to use PostgreSQL
3. Setting `DATABASE_URL` environment variable

## Monitoring

- Check service logs in Railway dashboard
- Backend health check: `<backend_url>/health`
- Bot health check: Port 3001 (if configured)

## Troubleshooting

1. **"Nixpacks was unable to generate a build plan"**
   - Ensure nixpacks.toml is in the root directory
   - Check that all file paths in nixpacks.toml are correct

2. **Database errors**
   - SQLite file permissions might need adjustment
   - Consider switching to PostgreSQL for production

3. **Frontend can't connect to backend**
   - Verify BACKEND_URL is set correctly
   - Check CORS settings in backend

4. **Bot not processing transactions**
   - Verify SUI_PRIVATE_KEY has funds
   - Check PACKAGE_ID and FEE_MANAGER_ID are correct
   - Review bot logs for specific errors