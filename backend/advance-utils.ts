
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

export const advanceState = async ({
    packageId,
    feeManagerId,
    assetType,
    stableType,
    proposalId,
    escrowId,
    network,
    daoId,
}: {
    packageId: string,
    feeManagerId: string,
    assetType: string,
    stableType: string,
    proposalId: string,
    escrowId: string,
    network: Network,
    daoId: string,
}) => {
    try {
        const txb = new Transaction();
        txb.setGasBudget(50000000);

        console.log(packageId,
            assetType,
            stableType,
            proposalId,
            escrowId,
            daoId)

        txb.moveCall({
            target: `${packageId}::advance_stage::try_advance_state_entry`,
            typeArguments: [
                assetType,
                stableType
            ],
            arguments: [
                txb.object(proposalId),
                txb.object(escrowId),
                txb.object(feeManagerId),
                txb.object('0x6')
            ],
        });
        
        const results = await signAndExecute(txb, network);
        
        console.log('Creating Dao successful!');
        console.log('Transaction Digest:', results.digest);

        const resultsDir = 'futarchy-results';
        const fileNames = [`advance-short.json`, `advance-full.json`, `market-state.json`];
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
            JSON.stringify(results, null, 2),
            { encoding: 'utf8', flag: 'w' }
        );

        // parseCreateDaoResults(results), null, 2
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
