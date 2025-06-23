import { withdrawAllFees } from '../withdraw-fees';
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

const getWithdrawFeeParams = () => {
    const futarchyPub = readJsonFile('futarchy-pub-short.json');
    
    return {
        packageId: futarchyPub.packageId,
        feeManager: futarchyPub.feeManagerId,
        feeAdminCapId: futarchyPub.feeAdminCapId,
        network: 'testnet' as Network
    };
};

// Function to withdraw fees
const performFeeWithdrawal = async () => {
    try {
        const params = getWithdrawFeeParams();
        console.log('Withdrawing fees with parameters:', params);
        
        // Call the SDK-based implementation
        await withdrawAllFees(params);
        
        console.log('Fees withdrawn successfully using SDK');
    } catch (error) {
        console.error('Error withdrawing fees:', error);
        throw error;
    }
};

// Execute the withdrawal
performFeeWithdrawal();