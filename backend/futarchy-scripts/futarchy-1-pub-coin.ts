import { publishPackage } from '../publish-coin-utils';
import fs from 'fs';
import path from 'path';

// Add delay function
const delay = (ms: number) => new Promise(resolve => setTimeout(resolve, ms));

// Convert to async function for better error handling
async function deployContracts() {
    try {
        console.log('Starting contract deployment process...');

        // --- Deploy asset contract ---
        const assetPath = path.resolve(__dirname, '../../contracts/test_asset');
        
        // Remove the build directory if it exists
        const assetBuildPath = path.join(assetPath, 'build');
        if (fs.existsSync(assetBuildPath)) {
            fs.rmSync(assetBuildPath, { recursive: true });
            console.log('Removed old build directory for asset');
        }

        // Remove Move.lock if it exists
        const assetLockPath = path.join(assetPath, 'Move.lock');
        if (fs.existsSync(assetLockPath)) {
            fs.unlinkSync(assetLockPath);
            console.log('Removed Move.lock file for asset');
        }

        console.log('Publishing asset contract...');
        const assetResults = await publishPackage({
            packagePath: assetPath,
            network: 'testnet',
            exportFileName: 'asset-contract', // This will result in futarchy-pub-asset-contract-short.json etc.
        });
        console.log('Asset package published successfully. Transaction Digest:', assetResults.digest);
        console.log('Waiting 10 seconds before publishing next package...');
        await delay(10000); // 10 second delay

        // --- Deploy stable contract ---
        const stablePath = path.resolve(__dirname, '../../contracts/test_stable');
        
        // Remove the build directory if it exists
        const stableBuildPath = path.join(stablePath, 'build');
        if (fs.existsSync(stableBuildPath)) {
            fs.rmSync(stableBuildPath, { recursive: true });
            console.log('Removed old build directory for stable');
        }

        // Remove Move.lock if it exists
        const stableLockPath = path.join(stablePath, 'Move.lock');
        if (fs.existsSync(stableLockPath)) {
            fs.unlinkSync(stableLockPath);
            console.log('Removed Move.lock file for stable');
        }

        console.log('Publishing stable contract...');
        const stableResults = await publishPackage({
            packagePath: stablePath,
            network: 'testnet',
            exportFileName: 'stable-contract', // This will result in futarchy-pub-stable-contract-short.json etc.
        });
        console.log('Stable package published successfully. Transaction Digest:', stableResults.digest);
        console.log('All contracts deployed successfully.');

    } catch (error) {
        console.error('Error during contract deployment:', error);
        // Re-throw to ensure the promise is rejected and outer catch can handle it
        throw error; 
    }
}

// Execute the deployment and handle any uncaught errors
deployContracts().catch(error => {
    console.error('Deployment script failed:', error);
    process.exit(1); // Exit with a non-zero code to indicate failure
});