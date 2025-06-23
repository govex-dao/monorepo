#!/usr/bin/env ts-node

import Database from 'better-sqlite3';
import { Client } from 'pg';

// Configuration
const SQLITE_PATH = process.env.SQLITE_PATH || './backend/prisma/dev.db';
const POSTGRES_URL = process.env.DATABASE_URL;

// Colors for console output
const colors = {
  reset: '\x1b[0m',
  bright: '\x1b[1m',
  green: '\x1b[32m',
  red: '\x1b[31m',
  yellow: '\x1b[33m',
  cyan: '\x1b[36m'
};

console.log(`${colors.cyan}${colors.bright}SQLite to PostgreSQL Migration Script${colors.reset}`);
console.log('=====================================\n');

// Validate environment
if (!POSTGRES_URL) {
  console.error(`${colors.red}ERROR: DATABASE_URL environment variable is not set${colors.reset}`);
  process.exit(1);
}

console.log(`SQLite source: ${SQLITE_PATH}`);
console.log(`PostgreSQL target: ${POSTGRES_URL.substring(0, 30)}...\n`);

async function migrateTable(
  tableName: string,
  sqlite: Database.Database,
  pg: Client,
  transform?: (row: any) => any
) {
  console.log(`${colors.cyan}Migrating ${tableName}...${colors.reset}`);
  
  try {
    // Get data from SQLite
    const rows = sqlite.prepare(`SELECT * FROM ${tableName}`).all();
    console.log(`  Found ${rows.length} records`);
    
    if (rows.length === 0) {
      console.log(`  ${colors.yellow}No data to migrate${colors.reset}`);
      return;
    }
    
    // Insert into PostgreSQL
    let migrated = 0;
    for (const row of rows) {
      const data = transform ? transform(row) : row;
      const columns = Object.keys(data);
      const values = Object.values(data);
      const placeholders = values.map((_, i) => `$${i + 1}`).join(', ');
      
      const query = `INSERT INTO "${tableName}" (${columns.map(c => `"${c}"`).join(', ')}) VALUES (${placeholders})`;
      
      try {
        await pg.query(query, values);
        migrated++;
        if (migrated % 100 === 0) {
          process.stdout.write(`\r  Migrated ${migrated}/${rows.length} records`);
        }
      } catch (error: any) {
        if (error.code === '23505') { // Unique constraint violation
          console.log(`\n  ${colors.yellow}Skipping duplicate record${colors.reset}`);
        } else {
          throw error;
        }
      }
    }
    
    console.log(`\n  ${colors.green}✓ Successfully migrated ${migrated} records${colors.reset}\n`);
  } catch (error: any) {
    console.error(`\n  ${colors.red}✗ Error migrating ${tableName}:${colors.reset}`, error.message);
    throw error;
  }
}

async function main() {
  // Initialize connections
  const sqlite = new Database(SQLITE_PATH, { readonly: true });
  const pg = new Client(POSTGRES_URL);
  
  try {
    await pg.connect();
    console.log(`${colors.green}✓ Connected to PostgreSQL${colors.reset}\n`);
    
    // Clear existing data in correct order (respecting foreign keys)
    console.log(`${colors.yellow}Clearing existing PostgreSQL data...${colors.reset}`);
    await pg.query('DELETE FROM "ProposalLock"');
    await pg.query('DELETE FROM "DaoVerification"');
    await pg.query('DELETE FROM "DaoVerificationRequest"');
    await pg.query('DELETE FROM "ResultSigned"');
    await pg.query('DELETE FROM "SwapEvent"');
    await pg.query('DELETE FROM "ProposalResult"');
    await pg.query('DELETE FROM "ProposalTWAP"');
    await pg.query('DELETE FROM "ProposalStateChange"');
    await pg.query('DELETE FROM "Proposal"');
    await pg.query('DELETE FROM "Dao"');
    await pg.query('DELETE FROM "Cursor"');
    console.log(`${colors.green}✓ PostgreSQL database cleared${colors.reset}\n`);
    
    // Migrate tables in order (respecting foreign key constraints)
    await migrateTable('Cursor', sqlite, pg);
    await migrateTable('Dao', sqlite, pg);
    await migrateTable('Proposal', sqlite, pg);
    await migrateTable('ProposalStateChange', sqlite, pg);
    await migrateTable('ProposalTWAP', sqlite, pg);
    await migrateTable('ProposalResult', sqlite, pg);
    await migrateTable('SwapEvent', sqlite, pg);
    await migrateTable('ResultSigned', sqlite, pg);
    await migrateTable('DaoVerificationRequest', sqlite, pg);
    await migrateTable('DaoVerification', sqlite, pg);
    await migrateTable('ProposalLock', sqlite, pg);
    
    console.log(`\n${colors.yellow}Verifying migration...${colors.reset}\n`);
    
    // Verify counts
    const tables = [
      'Cursor', 'Dao', 'Proposal', 'ProposalStateChange', 'ProposalTWAP',
      'ProposalResult', 'SwapEvent', 'ResultSigned', 'DaoVerificationRequest',
      'DaoVerification', 'ProposalLock'
    ];
    
    for (const table of tables) {
      try {
        const sqliteCount = sqlite.prepare(`SELECT COUNT(*) as count FROM ${table}`).get() as any;
        const pgResult = await pg.query(`SELECT COUNT(*) as count FROM "${table}"`);
        const pgCount = parseInt(pgResult.rows[0].count);
        const match = sqliteCount.count === pgCount;
        
        console.log(
          `${table.padEnd(25)} SQLite: ${sqliteCount.count.toString().padEnd(6)} PostgreSQL: ${pgCount.toString().padEnd(6)} ${
            match ? colors.green + '✓' : colors.red + '✗'
          }${colors.reset}`
        );
      } catch (error) {
        console.log(`${table.padEnd(25)} ${colors.red}Error checking counts${colors.reset}`);
      }
    }
    
    console.log(`\n${colors.bright}${colors.green}✓ Migration completed successfully!${colors.reset}`);
    
  } catch (error) {
    console.error(`${colors.red}Migration failed:`, error);
    process.exit(1);
  } finally {
    sqlite.close();
    await pg.end();
  }
}

// Run the migration
main().catch(console.error);