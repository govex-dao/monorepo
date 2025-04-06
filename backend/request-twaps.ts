
import { execSync } from 'child_process';
import { readFileSync, writeFileSync } from 'fs';
import { existsSync, unlinkSync} from 'fs';
import { homedir } from 'os';
import path from 'path';
import { getFullnodeUrl, SuiClient } from '@mysten/sui/client';
import { Ed25519Keypair } from '@mysten/sui/keypairs/ed25519';
import { Transaction } from '@mysten/sui/transactions';
import { fromBase64 } from '@mysten/sui/utils';
import { bcs } from '@mysten/sui/bcs';

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
    const sender = getActiveAddress(); // Retrieve the active address

    return client.devInspectTransactionBlock({
        transactionBlock: txb, // Matches the interface's property name
        sender,              // Matches the interface's property name
    });
};

export const requestTwaps = async ({
    packageId,
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
    proposalId, 
    network,
}: {
    packageId: string,
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
    proposalId: string, 
    network: Network,
}) => {
    try {
        const txb = new Transaction();
        

        txb.setGasBudget(50000000);

        txb.moveCall({
            target: `${packageId}::proposal::get_twaps_for_proposal`,
            typeArguments: [
                assetType,    // <ASSET_TYPE>
                stableType    // <STABLE_TYPE>
            ],
            arguments: [
                txb.object(proposalId),
                txb.object('0x6')
              ]
        });
    
        
        const inspectResult = await signAndExecute(txb, network);
        console.log("Full result:", JSON.stringify(inspectResult, null, 2));
        
        console.log('Creating Dao successful!');
        console.log('Transaction Digest:', inspectResult);

        if (inspectResult.results && inspectResult.results.length > 0) {
            const twapRaw = inspectResult.results[0].returnValues;
            console.log("Raw TWAP values:", twapRaw);


        // Assume inspectResult is the result from devInspectTransactionBlock
            const rawTwapValues = inspectResult.results[0].returnValues;

            // rawTwapValues is expected to be an array where the first element is a tuple:
            // [ dataBytes, typeString ]
            if (rawTwapValues && rawTwapValues.length > 0) {
                const [dataBytes, typeStr] = rawTwapValues[0];
                const bytes = new Uint8Array(dataBytes);
                
                // Use parse instead of deserialize
                const decodedTwaps = bcs.vector(bcs.u64()).parse(bytes);
                
                console.log("Decoded TWAP values:", decodedTwaps);
            }
        }
        
        const resultsDir = 'futarchy-results';
        const fileNames = [ `request-twap-full.json`];
        const filePaths = fileNames.map(fileName => path.join(resultsDir, fileName));

        // Delete existing files
        filePaths.forEach(filePath => {
            if (existsSync(filePath)) {
                unlinkSync(filePath);
            }
        });

        writeFileSync(
            filePaths[0],
            JSON.stringify(inspectResult, null, 2),
            { encoding: 'utf8', flag: 'w' }
        );
        

        return inspectResult;

    } catch (error) {
        console.error('Creating DAO failed:', error);
        throw error;
    }
};
