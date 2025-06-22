#!/bin/bash

# Mainnet PostgreSQL backup script - stores OUTSIDE the repository
# Usage: ./backup-postgres-local.sh

TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# Store backups in home directory, NOT in repo
BACKUP_DIR="$HOME/railway-mainnet-backups"
BACKUP_FILE="${BACKUP_DIR}/mainnet_${TIMESTAMP}.sql"

# Create backup directory if it doesn't exist
mkdir -p "$BACKUP_DIR"

# Check if DATABASE_URL is set
if [ -z "$DATABASE_URL" ]; then
    echo "ERROR: DATABASE_URL environment variable is not set"
    echo "Get it from Railway dashboard > PostgreSQL > Variables"
    exit 1
fi

echo "Starting MAINNET backup..."
echo "Backup location: $BACKUP_FILE (outside repository)"

# Create the backup
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
    echo ""
    echo "IMPORTANT: This backup is stored OUTSIDE your git repository"
    echo "Location: $BACKUP_DIR"
    echo ""
    echo "To list all backups:"
    echo "  ls -la $BACKUP_DIR"
    
    # Create a symlink for convenience (but don't commit it)
    ln -sf "$BACKUP_FILE" "$BACKUP_DIR/latest-mainnet.sql.gz"
    
else
    echo "✗ Backup failed!"
    exit 1
fi

# Clean up old backups (keep last 30 days)
echo "Cleaning up backups older than 30 days..."
find "$BACKUP_DIR" -name "mainnet_*.sql.gz" -mtime +30 -delete

echo "Done!"