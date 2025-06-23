# Mainnet PostgreSQL Backup Guide

## Overview
This guide explains how to backup your Railway PostgreSQL mainnet database locally.

## Initial Setup

1. **Get your mainnet DATABASE_URL from Railway:**
   - Go to Railway dashboard
   - Navigate to your mainnet PostgreSQL service
   - Copy the DATABASE_URL from Variables tab
   ```bash
   export DATABASE_URL="postgresql://user:password@host.railway.app:5432/railway"
   ```

2. **Make the backup script executable:**
   ```bash
   cd backend
   chmod +x backup-postgres-local.sh
   ```

## Creating Backups

Run the backup script:
```bash
cd backend
./backup-postgres-local.sh
```

This will:
- Create a timestamped backup (e.g., `mainnet_20240122_143000.sql.gz`)
- Store it in `~/railway-mainnet-backups/` (outside your git repository)
- Create a symlink `latest-mainnet.sql.gz` pointing to the newest backup
- Automatically delete backups older than 30 days

## Backup Storage Location
```
~/railway-mainnet-backups/
├── mainnet_20240122_143000.sql.gz
├── mainnet_20240123_143000.sql.gz
└── latest-mainnet.sql.gz -> mainnet_20240123_143000.sql.gz
```

## Restoring Backups

### Restore to Railway (or any PostgreSQL):
```bash
# Set target database URL
export DATABASE_URL="postgresql://target-database-url"

# Restore latest backup
gunzip -c ~/railway-mainnet-backups/latest-mainnet.sql.gz | psql "$DATABASE_URL"

# Or restore specific backup
gunzip -c ~/railway-mainnet-backups/mainnet_20240122_143000.sql.gz | psql "$DATABASE_URL"
```

## Automated Daily Backups (Optional)

Add to crontab for automatic daily backups at 2 AM:
```bash
# Edit crontab
crontab -e

# Add this line (replace with your actual DATABASE_URL)
0 2 * * * export DATABASE_URL="postgresql://user:pass@host.railway.app:5432/railway" && /Users/admin/monorepo/backend/backup-postgres-local.sh
```

## Important Security Notes

1. **Never commit backups to git** - They contain sensitive user data
2. **Keep DATABASE_URL secret** - Don't share or commit it
3. **Backups are stored locally** - Consider encrypting your disk
4. **.gitignore is configured** - Prevents accidental commits of *.sql files

## Troubleshooting

- **"DATABASE_URL not set"**: Export the DATABASE_URL environment variable first
- **"pg_dump: command not found"**: Install PostgreSQL client tools
  - Mac: `brew install postgresql`
  - Linux: `apt-get install postgresql-client`
- **Permission denied**: Make sure the script is executable (`chmod +x`)

## Quick Commands Reference

```bash
# Backup mainnet
export DATABASE_URL="your-mainnet-url"
./backup-postgres-local.sh

# List all backups
ls -la ~/railway-mainnet-backups/

# Check latest backup
ls -la ~/railway-mainnet-backups/latest-mainnet.sql.gz

# Restore to a database
export DATABASE_URL="target-database-url"
gunzip -c ~/railway-mainnet-backups/latest-mainnet.sql.gz | psql "$DATABASE_URL"
```
