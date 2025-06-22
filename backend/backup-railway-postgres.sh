#!/bin/bash

# Railway PostgreSQL Backup Script
# Usage: ./backup-railway-postgres.sh [environment]

ENVIRONMENT=${1:-"mainnet"}
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_DIR="./backups"
BACKUP_FILE="${BACKUP_DIR}/railway_${ENVIRONMENT}_${TIMESTAMP}.sql"

# Create backup directory if it doesn't exist
mkdir -p "$BACKUP_DIR"

# Check if DATABASE_URL is set
if [ -z "$DATABASE_URL" ]; then
    echo "ERROR: DATABASE_URL environment variable is not set"
    echo "Please set it to your Railway PostgreSQL connection string"
    echo "Example: export DATABASE_URL='postgresql://user:pass@host:port/dbname'"
    exit 1
fi

echo "Starting backup for environment: $ENVIRONMENT"
echo "Backup file: $BACKUP_FILE"

# Create the backup using pg_dump
echo "Creating backup..."
pg_dump "$DATABASE_URL" \
    --verbose \
    --no-owner \
    --no-privileges \
    --format=plain \
    --encoding=UTF8 \
    > "$BACKUP_FILE"

if [ $? -eq 0 ]; then
    # Compress the backup
    echo "Compressing backup..."
    gzip "$BACKUP_FILE"
    BACKUP_FILE="${BACKUP_FILE}.gz"
    
    # Get file size
    SIZE=$(ls -lh "$BACKUP_FILE" | awk '{print $5}')
    
    echo "✓ Backup completed successfully!"
    echo "  File: $BACKUP_FILE"
    echo "  Size: $SIZE"
    
    # Optional: Upload to cloud storage
    # aws s3 cp "$BACKUP_FILE" "s3://your-bucket/backups/" --profile your-profile
    # gcloud storage cp "$BACKUP_FILE" "gs://your-bucket/backups/"
    
else
    echo "✗ Backup failed!"
    exit 1
fi

# Clean up old backups (keep last 7 days)
echo "Cleaning up old backups..."
find "$BACKUP_DIR" -name "railway_${ENVIRONMENT}_*.sql.gz" -mtime +7 -delete

echo "Done!"