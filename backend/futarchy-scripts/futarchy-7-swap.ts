import { SwapTokens } from '../deposit-and-swap-utils';
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

// Function to extract required parametexrs from JSON files
const getSwapTokensParams = () => {
    const futarchyPub = readJsonFile('futarchy-pub-short.json');
    const mint1Results = readJsonFile('mint-1-results-short.json');
    const mint2Results = readJsonFile('mint-2-results-short.json');
    const daoResults = readJsonFile('create-dao-results-short.json');
    const propResults = readJsonFile('create-prop-short.json');


    return {
        packageId: futarchyPub.packageId,
        escrowId: propResults.escrowId,
        assetType: mint1Results.coinType,
        stableType: mint2Results.coinType,
        coinId: mint2Results.coinObjectId,
        amount: 100,
        outcomeIdx: 0,
        proposalId: propResults.proposalId,
        minAmountOut: 10,
        network: 'devnet' as Network
    };
};

// Combined creation function
const performaSwapTokens = async () => {
    try {
        const params = getSwapTokensParams();
        console.log('Creating deposit and coin:', params);
        
        await SwapTokens(params);
        console.log('deposit and coin created successfully');
    } catch (error) {
        console.error('Error during deposit or coin:', error);
        throw error;
    }
};

// Execute
performaSwapTokens();