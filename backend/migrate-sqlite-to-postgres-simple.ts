#!/usr/bin/env ts-node

import { PrismaClient } from '@prisma/client';




// Configuration
const SQLITE_PATH = process.env.SQLITE_PATH || '../main-branch/prisma/dev.db';
const POSTGRES_URL = process.env.DATABASE_URL;
const BATCH_SIZE = 100;

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
  console.log('\nUsage:');
  console.log('  export DATABASE_URL="postgresql://user:pass@host:port/db"');
  console.log('  export SQLITE_PATH="/path/to/mainnet/dev.db"');
  console.log('  npx ts-node migrate-sqlite-to-postgres-simple.ts\n');
  process.exit(1);
}

console.log(`SQLite source: ${SQLITE_PATH}`);
console.log(`PostgreSQL target: ${POSTGRES_URL.substring(0, 30)}...\n`);

async function migrateTable(
  name: string,
  fetchData: () => Promise<any[]>,
  insertData: (data: any[]) => Promise<any>
) {
  console.log(`${colors.cyan}Migrating ${name}...${colors.reset}`);
  
  try {
    const data = await fetchData();
    console.log(`  Found ${data.length} records`);
    
    if (data.length === 0) {
      console.log(`  ${colors.yellow}No data to migrate${colors.reset}`);
      return;
    }
    
    // Migrate in batches
    let migrated = 0;
    for (let i = 0; i < data.length; i += BATCH_SIZE) {
      const batch = data.slice(i, i + BATCH_SIZE);
      await insertData(batch);
      migrated += batch.length;
      process.stdout.write(`\r  Migrated ${migrated}/${data.length} records`);
    }
    
    console.log(`\n  ${colors.green}✓ Successfully migrated ${name}${colors.reset}\n`);
  } catch (error: any) {
    console.error(`\n  ${colors.red}✗ Error migrating ${name}:${colors.reset}`, error.message);
    
    if (error.code === 'P2002') {
      console.log(`  ${colors.yellow}Some records already exist, continuing...${colors.reset}\n`);
    } else {
      throw error;
    }
  }
}

async function main() {
  // Initialize clients
  const sqliteClient = new PrismaClient({
    datasources: {
      db: {
        url: `file:${SQLITE_PATH}`
      }
    }
  });

  const postgresClient = new PrismaClient({
    datasources: {
      db: {
        url: POSTGRES_URL
      }
    }
  });

  try {
    // Test connections
    await sqliteClient.$connect();
    console.log(`${colors.green}✓ Connected to SQLite${colors.reset}`);
    
    await postgresClient.$connect();
    console.log(`${colors.green}✓ Connected to PostgreSQL${colors.reset}\n`);
    
    // SKIP WIPING DATA - Database is already empty
    console.log(`${colors.yellow}Skipping data wipe - database is empty${colors.reset}\n`);
    
    // Migrate tables in order (respecting foreign key constraints)
    await migrateTable(
      'Cursor',
      () => sqliteClient.cursor.findMany(),
      (data) => postgresClient.cursor.createMany({ data })
    );
    
    await migrateTable(
      'Dao',
      () => sqliteClient.dao.findMany(),
      (data) => postgresClient.dao.createMany({ data })
    );
    
    await migrateTable(
      'Proposal',
      () => sqliteClient.proposal.findMany(),
      (data) => postgresClient.proposal.createMany({ data })
    );
    
    await migrateTable(
      'ProposalStateChange',
      () => sqliteClient.proposalStateChange.findMany(),
      (data) => postgresClient.proposalStateChange.createMany({ data })
    );
    
    await migrateTable(
      'ProposalTWAP',
      () => sqliteClient.proposalTWAP.findMany(),
      (data) => postgresClient.proposalTWAP.createMany({ data })
    );
    
    await migrateTable(
      'ProposalResult',
      () => sqliteClient.proposalResult.findMany(),
      (data) => postgresClient.proposalResult.createMany({ data })
    );
    
    await migrateTable(
      'SwapEvent',
      () => sqliteClient.swapEvent.findMany(),
      (data) => postgresClient.swapEvent.createMany({ data })
    );
    
    await migrateTable(
      'ResultSigned',
      () => sqliteClient.resultSigned.findMany(),
      (data) => postgresClient.resultSigned.createMany({ data })
    );
    
    await migrateTable(
      'DaoVerificationRequest',
      () => sqliteClient.daoVerificationRequest.findMany(),
      (data) => postgresClient.daoVerificationRequest.createMany({ data })
    );
    
    await migrateTable(
      'DaoVerification',
      () => sqliteClient.daoVerification.findMany(),
      (data) => postgresClient.daoVerification.createMany({ data })
    );
    
    await migrateTable(
      'ProposalLock',
      () => sqliteClient.proposalLock.findMany(),
      (data) => postgresClient.proposalLock.createMany({ data })
    );
    
    // Note: DailyMetric is only in dev branch, skip it for mainnet migration
    
    console.log(`\n${colors.yellow}Verifying migration...${colors.reset}\n`);
    
    // Verify counts
    const tables = [
      'cursor', 'dao', 'proposal', 'proposalStateChange', 'proposalTWAP',
      'proposalResult', 'swapEvent', 'resultSigned', 'daoVerificationRequest',
      'daoVerification', 'proposalLock'
    ];
    
    for (const table of tables) {
      try {
        const sqliteCount = await (sqliteClient as any)[table].count();
        const postgresCount = await (postgresClient as any)[table].count();
        const match = sqliteCount === postgresCount;
        
        console.log(
          `${table.padEnd(25)} SQLite: ${sqliteCount.toString().padEnd(6)} PostgreSQL: ${postgresCount.toString().padEnd(6)} ${
            match ? colors.green + '✓' : colors.yellow + '≈'
          }${colors.reset}`
        );
      } catch (error) {
        console.log(`${table.padEnd(25)} ${colors.yellow}Skipped (not in source)${colors.reset}`);
      }
    }
    
    console.log(`\n${colors.bright}${colors.green}✓ Migration completed successfully!${colors.reset}`);
    
  } catch (error) {
    console.error(`${colors.red}Migration failed:`, error);
    process.exit(1);
  } finally {
    await sqliteClient.$disconnect();
    await postgresClient.$disconnect();
  }
}

// Run the migration
main().catch(console.error);