// This file re-exports the Prisma client from db.ts for consistency
// The actual Prisma client is environment-specific and is generated during build

export { prisma } from '../db';
export * from '@prisma/client';