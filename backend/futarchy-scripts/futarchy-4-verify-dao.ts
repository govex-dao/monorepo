import { verifyDao } from '../verify-dao-utils';
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

const getVerifyDaoParams = () => {
    const futarchyPub = readJsonFile('futarchy-pub-short.json');
    const payResults = readJsonFile('create-pay-short.json');
    const daoResults = readJsonFile('create-dao-results-short.json');
    const requestResults = readJsonFile('request-dao-short.json');

    return {
        packageId: futarchyPub.packageId,
        validatorCap: futarchyPub.validatorAdminCapId,
        dao: daoResults.daoId,
        attestationUrl: 'https://upload.wikimedia.org/wikipedia/commons/d/d5/Retriever_in_water.jpg',
        verificationId: requestResults.verificationId,
        network: 'testnet' as Network
    };
};

// Combined creation function
const performVerifyDao = async () => {
    try {
        const params = getVerifyDaoParams();
        console.log('Creating DAO with parameters:', params);
        
        await verifyDao(params);
        console.log('DAO created successfully');
    } catch (error) {
        console.error('Error during DAO creation:', error);
        throw error;
    }
};

// Execute the minting
performVerifyDao();