import { createProp } from '../create-prop-utils';
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

// Function to extract required parameters from JSON files
const getCreatePropParams = () => {
    const futarchyPub = readJsonFile('futarchy-pub-short.json');
    const mint1Results = readJsonFile('mint-1-results-short.json');
    const mint2Results = readJsonFile('mint-2-results-short.json');
    const daoResults = readJsonFile('create-dao-results-short.json');
    const payResults = readJsonFile('create-pay-short.json');

    // Array of possible titles
    const possibleTitles = [
        "Open an office in the UAE",
        "Put X% treasury in BTC",
        "Hire designers"
    ];

    // Randomly select one title
    const randomTitle = possibleTitles[Math.floor(Math.random() * possibleTitles.length)];

    return {
        packageId: futarchyPub.packageId,
        feeManager: futarchyPub.feeManagerId,
        paymentCoinId: payResults.splitCoinObjectId,
        daoObjectId: daoResults.daoId,
        assetType: mint1Results.coinType,
        stableType: mint2Results.coinType,
        assetCoinId: mint1Results.coinObjectId,
        stableCoinId: mint2Results.coinObjectId,
        title: randomTitle,
        details: "Hello",
        metadata: "",
        outcomeMessages: ["Reject", "Accept"],
        initialAmounts: [10000, 9000, 8000, 10000],
        network: 'devnet' as Network
    };
};
// Combined creation function
const performCreateProp = async () => {
    try {
        const params = getCreatePropParams();
        console.log('Creating Prop with parameters:', params);
        
        await createProp(params);
        console.log('Prop created successfully');
    } catch (error) {
        console.error('Error during prop creation:', error);
        throw error;
    }
};

// Execute
performCreateProp();