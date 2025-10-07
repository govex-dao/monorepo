import { imageService } from '../services/ImageService';
import { prisma } from '../db';

async function generateDaoImages(daoId: string) {
  // First, fetch the DAO to get its icon_url
  const dao = await prisma.dao.findUnique({
    where: { dao_id: daoId },
    select: { icon_url: true }
  });

  if (!dao) {
    console.error('DAO not found:', daoId);
    return;
  }

  if (!dao.icon_url) {
    console.error('DAO has no icon URL:', daoId);
    return;
  }

  console.log('Fetching and generating images for DAO:', daoId);
  console.log('Source URL:', dao.icon_url);
  
  const paths = await imageService.fetchAndCacheAllVersions(dao.icon_url, daoId);
  
  if (!paths.icon || !paths.medium || !paths.large) {
    console.error('Failed to generate one or more image versions');
    return;
  }

  console.log('Generated image paths:', paths);

  // Update the database with new paths
  try {
    await prisma.dao.update({
      where: { dao_id: daoId },
      data: {
        icon_cache_path: paths.icon,
        icon_cache_medium: paths.medium,
        icon_cache_large: paths.large
      }
    });
    console.log('Successfully updated database with new image paths');
  } catch (error) {
    console.error('Failed to update database:', error);
  }
}

// Get DAO ID from command line argument
const daoId = process.argv[2];

if (!daoId) {
  console.error('Please provide a DAO ID as argument');
  console.error('Usage: tsx generate-dao-images.ts <dao_id>');
  process.exit(1);
}

// Run the script
generateDaoImages(daoId)
  .catch(console.error)
  .finally(() => prisma.$disconnect());
