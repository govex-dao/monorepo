#!/usr/bin/env ts-node

import { PrismaClient } from '@prisma/client';
import Database from 'better-sqlite3';

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

async function main() {
  // Initialize SQLite connection
  const sqlite = new Database(SQLITE_PATH, { readonly: true });
  
  // Initialize PostgreSQL client
  const postgres = new PrismaClient({
    datasources: {
      db: {
        url: POSTGRES_URL
      }
    }
  });

  try {
    await postgres.$connect();
    console.log(`${colors.green}✓ Connected to PostgreSQL${colors.reset}\n`);
    
    // Migrate Cursor
    console.log(`${colors.cyan}Migrating Cursor...${colors.reset}`);
    const cursors = sqlite.prepare('SELECT * FROM Cursor').all() as any[];
    console.log(`  Found ${cursors.length} records`);
    for (const cursor of cursors) {
      await postgres.cursor.create({ data: cursor });
    }
    console.log(`  ${colors.green}✓ Done${colors.reset}\n`);
    
    // Migrate Dao
    console.log(`${colors.cyan}Migrating Dao...${colors.reset}`);
    const daos = sqlite.prepare('SELECT * FROM Dao').all() as any[];
    console.log(`  Found ${daos.length} records`);
    for (const dao of daos) {
      await postgres.dao.create({ data: dao });
    }
    console.log(`  ${colors.green}✓ Done${colors.reset}\n`);
    
    // Migrate Proposal
    console.log(`${colors.cyan}Migrating Proposal...${colors.reset}`);
    const proposals = sqlite.prepare('SELECT * FROM Proposal').all() as any[];
    console.log(`  Found ${proposals.length} records`);
    for (const proposal of proposals) {
      await postgres.proposal.create({ data: proposal });
    }
    console.log(`  ${colors.green}✓ Done${colors.reset}\n`);
    
    // Migrate ProposalStateChange
    console.log(`${colors.cyan}Migrating ProposalStateChange...${colors.reset}`);
    const stateChanges = sqlite.prepare('SELECT * FROM ProposalStateChange').all() as any[];
    console.log(`  Found ${stateChanges.length} records`);
    for (const change of stateChanges) {
      await postgres.proposalStateChange.create({ data: change });
    }
    console.log(`  ${colors.green}✓ Done${colors.reset}\n`);
    
    // Migrate ProposalTWAP
    console.log(`${colors.cyan}Migrating ProposalTWAP...${colors.reset}`);
    const twaps = sqlite.prepare('SELECT * FROM ProposalTWAP').all() as any[];
    console.log(`  Found ${twaps.length} records`);
    for (const twap of twaps) {
      await postgres.proposalTWAP.create({ data: twap });
    }
    console.log(`  ${colors.green}✓ Done${colors.reset}\n`);
    
    // Migrate ProposalResult
    console.log(`${colors.cyan}Migrating ProposalResult...${colors.reset}`);
    const results = sqlite.prepare('SELECT * FROM ProposalResult').all() as any[];
    console.log(`  Found ${results.length} records`);
    for (const result of results) {
      await postgres.proposalResult.create({ data: result });
    }
    console.log(`  ${colors.green}✓ Done${colors.reset}\n`);
    
    // Migrate SwapEvent
    console.log(`${colors.cyan}Migrating SwapEvent...${colors.reset}`);
    const swaps = sqlite.prepare('SELECT * FROM SwapEvent').all() as any[];
    console.log(`  Found ${swaps.length} records`);
    for (const swap of swaps) {
      await postgres.swapEvent.create({ data: swap });
    }
    console.log(`  ${colors.green}✓ Done${colors.reset}\n`);
    
    // Migrate ResultSigned
    console.log(`${colors.cyan}Migrating ResultSigned...${colors.reset}`);
    const signed = sqlite.prepare('SELECT * FROM ResultSigned').all() as any[];
    console.log(`  Found ${signed.length} records`);
    for (const sign of signed) {
      await postgres.resultSigned.create({ data: sign });
    }
    console.log(`  ${colors.green}✓ Done${colors.reset}\n`);
    
    // Migrate DaoVerificationRequest
    console.log(`${colors.cyan}Migrating DaoVerificationRequest...${colors.reset}`);
    const verifyReqs = sqlite.prepare('SELECT * FROM DaoVerificationRequest').all() as any[];
    console.log(`  Found ${verifyReqs.length} records`);
    for (const req of verifyReqs) {
      await postgres.daoVerificationRequest.create({ data: req });
    }
    console.log(`  ${colors.green}✓ Done${colors.reset}\n`);
    
    // Migrate DaoVerification
    console.log(`${colors.cyan}Migrating DaoVerification...${colors.reset}`);
    const verifications = sqlite.prepare('SELECT * FROM DaoVerification').all() as any[];
    console.log(`  Found ${verifications.length} records`);
    for (const verification of verifications) {
      await postgres.daoVerification.create({ data: verification });
    }
    console.log(`  ${colors.green}✓ Done${colors.reset}\n`);
    
    // Migrate ProposalLock
    console.log(`${colors.cyan}Migrating ProposalLock...${colors.reset}`);
    const locks = sqlite.prepare('SELECT * FROM ProposalLock').all() as any[];
    console.log(`  Found ${locks.length} records`);
    for (const lock of locks) {
      await postgres.proposalLock.create({ data: lock });
    }
    console.log(`  ${colors.green}✓ Done${colors.reset}\n`);
    
    console.log(`${colors.bright}${colors.green}✓ Migration completed successfully!${colors.reset}`);
    
  } catch (error) {
    console.error(`${colors.red}Migration failed:`, error);
    process.exit(1);
  } finally {
    sqlite.close();
    await postgres.$disconnect();
  }
}

// Run the migration
main().catch(console.error);