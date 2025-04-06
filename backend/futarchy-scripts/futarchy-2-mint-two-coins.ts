// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

import { mintCoins } from '../mint-utils';
import { execSync } from 'child_process';
import fs from 'fs';
import path from 'path';

export const SUI_BIN = `sui`;
export const getActiveAddress = () => {
	return execSync(`${SUI_BIN} client active-address`, { encoding: 'utf8' }).trim();
};

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

const assetPub = readJsonFile('futarchy-pub-asset-contract-short.json');
const stablePub = readJsonFile('futarchy-pub-stable-contract-short.json');


const delay = (ms: number) => new Promise(resolve => setTimeout(resolve, ms));

// Combined minting function with delay
const performMinting = async (amount: number) => {
    try {
        // First mint
        await mintCoins({
            amount: amount,
            recipientAddress: getActiveAddress(),
            network: 'devnet',
            packageId: assetPub.packageId,
            treasuryCapId: assetPub.treasuryCapId,
            number: 1,
            coin_type: 'asset'
        });

        console.log('First mint completed. Waiting 10 seconds...');
        await delay(10000); // 10 second delay

        // Second mint
        await mintCoins({
            amount: amount,
            recipientAddress: getActiveAddress(),
            network: 'devnet',
            packageId: stablePub.packageId,
            treasuryCapId: stablePub.treasuryCapId,
            number: 2,
            coin_type: 'stable'
        });
        
        console.log('Second mint completed.');
    } catch (error) {
        console.error('Error during minting:', error);
    }
};

// Execute the minting
const amount = parseInt(process.argv[2]) || 5000;
performMinting(amount);