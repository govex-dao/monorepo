import { requestTwaps  } from '../request-twaps';
import { execSync } from 'child_process';
import fs from 'fs';
import path from 'path';

export const SUI_BIN = `sui`;
export const getActiveAddress = () => {
    return execSync(`${SUI_BIN} client active-address`, { encoding: 'utf8' }).trim();
};
export type Network = 'mainnet' | 'testnet' | 'devnet' | 'localnet';
// Function to read and parse JSON file
const readJsonFile = (filename: string) => {
    const filePath = path.join(__dirname, '../futarchy-results', filename);
    try {
        const fileContent = fs.readFileSync(filePath, 'utf8');
        return JSON.parse(fileContent);
    } catch (error) {
        console.error(`Error reading ${filename}:`, error);
        throw error;
    }
};

const getRequestTwaps = () => {
    const futarchyPub = readJsonFile('futarchy-pub-short.json');
    const mint1Results = readJsonFile('mint-1-results-short.json');
    const mint2Results = readJsonFile('mint-2-results-short.json');
    const payResults = readJsonFile('create-pay-short.json');
    const assetPub = readJsonFile('futarchy-pub-asset-contract-short.json');
    const stablePub = readJsonFile('futarchy-pub-stable-contract-short.json');
    const propResults = readJsonFile('create-prop-short.json');

    // Array of possible DAO names
    const possibleDaoNames = [
        "UniswapDAO",
        "Aave",
        "JPM",
        "Apple"
    ];

    // Randomly select one name
    const randomDaoName = possibleDaoNames[Math.floor(Math.random() * possibleDaoNames.length)];

    return {
        packageId: futarchyPub.packageId,
        assetType: mint1Results.coinType,
        stableType: mint2Results.coinType,
        factoryObjectId: futarchyPub.factoryId,
        paymentCoinId: payResults.splitCoinObjectId,
        minAssetAmount: 10000,
        minStableAmount: 10000,
        daoName: randomDaoName,
        image_url: 'https://upload.wikimedia.org/wikipedia/commons/d/d5/Retriever_in_water.jpg',
        review_period_ms: 2000,    // 2 s in milliseconds
        trading_period_ms: 2000,  // 2 s in milliseconds
        asset_metadata: assetPub.metadataId,
        stable_metadata: stablePub.metadataId,
        proposalId: propResults.proposalId, 
        network: 'devnet' as Network
    };
};

// Combined creation function
const performRequestTwaps = async () => {
    try {
        const params = getRequestTwaps();
        console.log('Creating DAO with parameters:', params);
        
        await requestTwaps (params);
        console.log('DAO created successfully');
    } catch (error) {
        console.error('Error during DAO creation:', error);
        throw error;
    }
};

// Execute the minting
performRequestTwaps ();