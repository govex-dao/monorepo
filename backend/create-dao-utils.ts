
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

interface CreateDaoResult {
    daoId: string;
}

interface ObjectChange {
    type: string;
    sender?: string;
    owner?: {
        AddressOwner?: string;
        Shared?: {
            initial_shared_version: number;
        };
    };
    objectType?: string;
    objectId?: string;
}

function parseCreateDaoResults(results: any): CreateDaoResult {
    const objectChanges = results.objectChanges || [];


    // Find the DAO object (shared)
    const daoObject = objectChanges.find((change: ObjectChange) => 
        change.type === 'created' && 
        change.objectType?.includes('::dao::DAO') &&
        change.owner?.Shared
    );

    if (!daoObject) {
        throw new Error('Required objects not found in transaction results');
    }

    return {
        daoId: daoObject.objectId!
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

export const createDao = async ({
    packageId,
    feeManager,
    assetType,
    stableType,
    factoryObjectId,
    paymentCoinId,
    minAssetAmount,
    minStableAmount,
    daoName,
    image_url,
    review_period_ms, 
    trading_period_ms,
    asset_metadata,
    stable_metadata, 
    network,
}: {
    packageId: string,
    feeManager: string,
    assetType: string,
    stableType: string,
    factoryObjectId: string,
    paymentCoinId: string,
    minAssetAmount: number,
    minStableAmount: number,
    daoName: string,
    image_url: string,
    review_period_ms: number,
    trading_period_ms: number,
    asset_metadata: string,
    stable_metadata: string, 
    network: Network,
}) => {
    try {
        const txb = new Transaction();
        

        txb.setGasBudget(50000000);

        txb.moveCall({
            target: `${packageId}::factory::create_dao`,
            typeArguments: [
                assetType,    // <ASSET_TYPE>
                stableType    // <STABLE_TYPE>
            ],
            arguments: [
                txb.object(factoryObjectId),     // <FACTORY_OBJECT_ID>
                txb.object(feeManager),
                txb.object(paymentCoinId),       // <PAYMENT_COIN_ID>
                txb.pure.u64(minAssetAmount),    // <MIN_ASSET_AMOUNT>
                txb.pure.u64(minStableAmount),   // <MIN_STABLE_AMOUNT>
                txb.pure.string(daoName), 
                txb.pure.string(image_url),
                txb.pure.u64(review_period_ms),  // New argument
                txb.pure.u64(trading_period_ms), // New argument
                txb.object(asset_metadata),
                txb.object(stable_metadata),
                txb.pure.u64(60_000),
                txb.pure.u128(100),
                txb.pure.u64(50),
                txb.object('0x6')        // <CLOCK_OBJECT_ID>
            ],
        });
        
        const results = await signAndExecute(txb, network);
        
        console.log('Creating Dao successful!');
        console.log('Transaction Digest:', results.digest);

        const resultsDir = 'futarchy-results';
        const fileNames = [`create-dao-results-short.json`, `create-dao-results-full.json`];
        const filePaths = fileNames.map(fileName => path.join(resultsDir, fileName));

        // Delete existing files
        filePaths.forEach(filePath => {
            if (existsSync(filePath)) {
                unlinkSync(filePath);
            }
        });

        // 
        writeFileSync(
            filePaths[0],
            JSON.stringify(parseCreateDaoResults(results), null, 2),
            { encoding: 'utf8', flag: 'w' }
        );

        // Write new files
        writeFileSync(
            filePaths[1],
            JSON.stringify(results, null, 2),
            { encoding: 'utf8', flag: 'w' }
        );

        
        return results;

    } catch (error) {
        console.error('Creating DAO failed:', error);
        throw error;
    }
};
