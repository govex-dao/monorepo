import { PrismaClient as PrismaClientMainnet } from '.prisma/client-mainnet';
import { PrismaClient as PrismaClientTestnetDev } from '.prisma/client-testnet-dev';
import { PrismaClient as PrismaClientTestnetBranch } from '.prisma/client-testnet-branch';

// Re-export all types from testnet-dev client (they should be the same structure across all schemas)
export * from '.prisma/client-testnet-dev';

// Determine which client to use based on environment variables
const network = process.env.NETWORK || 'testnet';
const environment = process.env.RAILWAY_ENVIRONMENT_NAME || process.env.ENVIRONMENT || '';

// Select the appropriate PrismaClient
let prismaInstance;
if (network === 'mainnet') {
  prismaInstance = new PrismaClientMainnet({
    log: process.env.NODE_ENV === 'development' ? ['query', 'error', 'warn'] : ['error'],
  });
  console.log('Using Mainnet Prisma client');
} else if (environment === 'testnet-branch') {
  prismaInstance = new PrismaClientTestnetBranch({
    log: process.env.NODE_ENV === 'development' ? ['query', 'error', 'warn'] : ['error'],
  });
  console.log('Using Testnet Branch Prisma client');
} else {
  // Default to testnet-dev
  prismaInstance = new PrismaClientTestnetDev({
    log: process.env.NODE_ENV === 'development' ? ['query', 'error', 'warn'] : ['error'],
  });
  console.log('Using Testnet Dev Prisma client');
}

export const prisma = prismaInstance;

// Ensure proper cleanup on exit
process.on('beforeExit', async () => {
  await prisma.$disconnect();
});