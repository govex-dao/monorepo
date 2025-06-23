import { addCoin } from '../add-stable-coin';
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

const getAddCoinParams = () => {
    const futarchyPub = readJsonFile('futarchy-pub-short.json');
    const mint1Results = readJsonFile('mint-1-results-short.json');
    const mint2Results = readJsonFile('mint-2-results-short.json');
    const payResults = readJsonFile('create-pay-short.json');
    const assetPub = readJsonFile('futarchy-pub-asset-contract-short.json');
    const stablePub = readJsonFile('futarchy-pub-stable-contract-short.json');

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
        stableType: "0xdba34672e30cb065b1f93e3ab55318768fd6fef66c15942c9f7cb846e2f900e7::usdc::USDC",
        factoryObjectId: futarchyPub.factoryId,
        factoryOwnerObj: futarchyPub.factoryOwnerCapId,
        network: 'mainnet' as Network
    };
};

// Combined creation function
const performAddCoin = async () => {
    try {
        const params = getAddCoinParams();
        console.log('Creating DAO with parameters:', params);
        
        await addCoin(params);
        console.log('DAO created successfully');
    } catch (error) {
        console.error('Error during DAO creation:', error);
        throw error;
    }
};

// Execute the minting
performAddCoin();