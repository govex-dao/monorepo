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
        dao: '0xb8462b88af6e5fe74bda7c936eba012a32a4ec6c2dc69000dfc607918d26a42c',
        attestationUrl: 'https://discord.com/channels/1314531947590193212/1314531948772720642/1375105404089929890',
        verificationId: '0xf41cc798452fc30761ab4b980f1e7bc62900b124948f72a28589fb7106b12d34',
        network: 'mainnet' as Network
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