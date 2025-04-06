import { publishPackage } from '../publish-coin-utils';
import fs from 'fs';
import path from 'path';

// Add delay function
const delay = (ms: number) => new Promise(resolve => setTimeout(resolve, ms));

// Convert to async function for better error handling
async function deployContracts() {
    try {
        // Deploy asset contract
        const assetPath = path.resolve(__dirname + '/../../contracts/asset');
        
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

        // Publish first contract
        await publishPackage({
            packagePath: __dirname + '/../../contracts/asset',
            network: 'testnet',
            exportFileName: 'asset-contract',
        });

        console.log('First package published. Waiting 10 seconds...');
        await delay(10000); // 10 second delay

        // Deploy stable contract
        const stablePath = path.resolve(__dirname + '/../../contracts/stable');
        
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

        // Publish second contract
        await publishPackage({
            packagePath: __dirname + '/../../contracts/stable',
            network: 'testnet',
            exportFileName: 'stable-contract',
        });

        console.log('Second package published successfully.');
    } catch (error) {
        console.error('Error during contract deployment:', error);
        throw error;
    }
}

// Execute the deployment
deployContracts().catch(console.error);