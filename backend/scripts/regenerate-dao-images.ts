#!/usr/bin/env tsx
/**
 * Regenerate all DAO image caches from the database
 * This script fetches all DAOs and regenerates their cached images
 * using the ImageService
 */

import { prisma } from '../db';
import { imageService } from '../services/ImageService';

async function regenerateDaoImages() {
  console.log('Starting DAO image cache regeneration...');

  try {
    // Fetch all DAOs from database
    const daos = await prisma.dao.findMany({
      select: {
        dao_id: true,
        dao_name: true,
        icon_url: true,
        icon_cache_path: true,
        icon_cache_medium: true,
        icon_cache_large: true,
      }
    });

    console.log(`Found ${daos.length} DAOs to process`);

    let successCount = 0;
    let skipCount = 0;
    let errorCount = 0;

    for (const dao of daos) {
      console.log(`\nProcessing DAO: ${dao.dao_name} (${dao.dao_id})`);

      if (!dao.icon_url) {
        console.log(`  ⚠️  Skipping - no icon_url`);
        skipCount++;
        continue;
      }

      try {
        // Generate all image versions
        const cachedPaths = await imageService.fetchAndCacheAllVersions(
          dao.icon_url,
          dao.dao_id
        );

        // Update database with new cache paths
        await prisma.dao.update({
          where: { dao_id: dao.dao_id },
          data: {
            icon_cache_path: cachedPaths.icon,
            icon_cache_medium: cachedPaths.medium,
            icon_cache_large: cachedPaths.large,
          }
        });

        console.log(`  ✅ Success`);
        console.log(`     Icon:   ${cachedPaths.icon}`);
        console.log(`     Medium: ${cachedPaths.medium}`);
        console.log(`     Large:  ${cachedPaths.large}`);
        successCount++;
      } catch (error) {
        console.error(`  ❌ Error:`, error instanceof Error ? error.message : error);
        errorCount++;
      }
    }

    console.log('\n' + '='.repeat(60));
    console.log('Image cache regeneration complete!');
    console.log(`Total DAOs: ${daos.length}`);
    console.log(`✅ Success: ${successCount}`);
    console.log(`⚠️  Skipped: ${skipCount}`);
    console.log(`❌ Errors:  ${errorCount}`);
    console.log('='.repeat(60));

  } catch (error) {
    console.error('Fatal error during regeneration:', error);
    process.exit(1);
  } finally {
    await prisma.$disconnect();
  }
}

// Run the script
regenerateDaoImages().catch(console.error);
