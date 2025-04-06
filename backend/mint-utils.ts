
import { execSync } from 'child_process';
import { readFileSync, writeFileSync } from 'fs';
import { existsSync, unlinkSync} from 'fs';
import { homedir } from 'os';
import path from 'path';
import { getFullnodeUrl, SuiClient } from '@mysten/sui/client';
import { Ed25519Keypair } from '@mysten/sui/keypairs/ed25519';
import { Transaction } from '@mysten/sui/transactions';
import { fromBase64 } from '@mysten/sui/utils';

// Constants


// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0


export type Network = 'mainnet' | 'testnet' | 'devnet' | 'localnet';

export const ACTIVE_NETWORK = (process.env.NETWORK as Network) || 'devnet';

export const SUI_BIN = `sui`;

export const getActiveAddress = () => {
	return execSync(`${SUI_BIN} client active-address`, { encoding: 'utf8' }).trim();
};

interface MintResult {
    coinObjectId: string;
    coinType: string;
}

interface ObjectChange {
    type: string;
    sender?: string;
    owner?: {
        AddressOwner?: string;
    };
    objectType?: string;
    objectId?: string;
    content?: {
        dataType: string;
        type: string;
        fields?: {
            balance?: string;
        };
    };
}


function parseMintResults(results: any): MintResult {
    const objectChanges = results.objectChanges || [];
    const effects = results.effects || {};
    
    // Find the created coin object
    const coinObject = objectChanges.find((change: ObjectChange) => 
        change.type === 'created' && 
        change.objectType?.includes('::coin::Coin<')
    );

    if (!coinObject) {
        throw new Error('Minted coin object not found in transaction results');
    }

    return {
        coinObjectId: coinObject.objectId!,
        coinType: coinObject.objectType.split('::coin::Coin<')[1].split('>')[0]
    };
}

/** Returns a signer based on the active address of system's sui. */
export const getSigner = () => {
	const sender = getActiveAddress();

	const keystore = JSON.parse(
		readFileSync(path.join(homedir(), '.sui', 'sui_config', 'sui.keystore'), 'utf8'),
	);

	for (const priv of keystore) {
		const raw = fromBase64(priv);
		if (raw[0] !== 0) {
			continue;
		}

		const pair = Ed25519Keypair.fromSecretKey(raw.slice(1));
		if (pair.getPublicKey().toSuiAddress() === sender) {
			return pair;
		}
	}

	throw new Error(`keypair not found for sender: ${sender}`);
};

/** Get the client for the specified network. */
export const getClient = (network: Network) => {
	return new SuiClient({ url: getFullnodeUrl(network) });
};

/** A helper to sign & execute a transaction. */
export const signAndExecute = async (txb: Transaction, network: Network) => {
	const client = getClient(network);
	const signer = getSigner();

	return client.signAndExecuteTransaction({
		transaction: txb,
		signer,
		options: {
			showEffects: true,
			showObjectChanges: true,
		},
	});
};

export const mintCoins = async ({
    amount,
    recipientAddress,
    network,
    packageId,
    treasuryCapId,
    number,
    coin_type,
}: {
    amount: number,
    recipientAddress: string,
    network: Network,
    packageId: string,
    treasuryCapId: string,
    number: number,
    coin_type: string
}) => {
    try {

        console.log("mintCoins called with arguments:");
        console.log("amount:", amount);
        console.log("recipientAddress:", recipientAddress);
        console.log("network:", network);
        console.log("packageId:", packageId);
        console.log("treasuryCapId:", treasuryCapId);
        console.log("number:", number);
        console.log("coin_type:", coin_type);

        const txb = new Transaction();
        
        // Set a sufficient gas budget for minting
        txb.setGasBudget(50000000);
        
        // Create the mint and transfer call
        txb.moveCall({
            target: `${packageId}::my_${coin_type}::mint`,
            arguments: [
                txb.object(treasuryCapId),
                txb.pure.u64(amount),
                txb.pure.address(recipientAddress)
            ],
        });

        // Sign and execute the transaction
        const results = await signAndExecute(txb, network);
        
        console.log('Minting successful!');
        console.log('Transaction Digest:', results.digest);

        const resultsDir = 'futarchy-results';
        const fileNames = [`mint-${number}-results-short.json`, `mint-${number}-results-full.json`];
        const filePaths = fileNames.map(fileName => path.join(resultsDir, fileName));

        // Delete existing files
        filePaths.forEach(filePath => {
            if (existsSync(filePath)) {
                unlinkSync(filePath);
            }
        });

        // Write new files
        writeFileSync(
            filePaths[0],
            JSON.stringify(parseMintResults(results), null, 2),
            { encoding: 'utf8', flag: 'w' }
        );

        writeFileSync(
            filePaths[1],
            JSON.stringify(results, null, 2),
            { encoding: 'utf8', flag: 'w' }
        );
        
        return results;

    } catch (error) {
        console.error('Minting failed:', error);
        throw error;
    }
};
