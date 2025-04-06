
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

interface CreateProposalResult {
    proposalId: string;
    proposalInfoId: string;
    escrowId: string;
}

interface ObjectChange {
    type: string;
    sender?: string;
    owner?: {
        AddressOwner?: string;
        Shared?: {
            initial_shared_version: number;
        };
        ObjectOwner?: string;
    };
    objectType?: string;
    objectId?: string;
}

function parseCreateProposalResults(results: any): CreateProposalResult {
    const objectChanges = results.objectChanges || [];
    
    // Find the Proposal object - note the generic type parameters
    const proposalObject = objectChanges.find((change: ObjectChange) => 
        change.type === 'created' && 
        change.objectType?.includes('::proposal::Proposal<') &&
        change.owner?.Shared
    );

    // Find the ProposalInfo object - note it's wrapped in a dynamic field
    const proposalInfoObject = objectChanges.find((change: ObjectChange) => 
        change.type === 'created' && 
        change.objectType?.includes('dynamic_field::Field') &&
        change.objectType?.includes('ProposalInfo') &&
        change.owner?.ObjectOwner
    );

    // Find the TokenEscrow object - note the generic type parameters
    const escrowObject = objectChanges.find((change: ObjectChange) => 
        change.type === 'created' && 
        change.objectType?.includes('::coin_escrow::TokenEscrow<') &&
        change.owner?.Shared
    );

    if (!proposalObject || !proposalInfoObject || !escrowObject) {
        throw new Error(`Required objects not found in transaction results:
            Proposal (${proposalObject?.objectType}): ${!!proposalObject}
            ProposalInfo (${proposalInfoObject?.objectType}): ${!!proposalInfoObject}
            Escrow (${escrowObject?.objectType}): ${!!escrowObject}`);
    }

    return {
        proposalId: proposalObject.objectId!,
        proposalInfoId: proposalInfoObject.objectId!,
        escrowId: escrowObject.objectId!
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

export const createProp = async ({
    packageId,
    feeManager,
    paymentCoinId,
    daoObjectId,
    assetType,
    stableType,
    assetCoinId,
    stableCoinId,
    title,
    details,
    metadata,
    outcomeMessages,
    initialAmounts, 
    network,
}: {
    packageId: string,
    feeManager: string,
    paymentCoinId: string,
    daoObjectId: string,
    assetType: string,
    stableType: string,
    assetCoinId: string,
    stableCoinId: string,
    title: string,
    details: string,
    metadata: string,
    outcomeMessages: string[],
    initialAmounts: number[],
    network: Network
}) => {
    try {
        const txb = new Transaction();
        
        txb.setGasBudget(100000000);
    
        txb.moveCall({
            target: `${packageId}::dao::create_proposal`,
            typeArguments: [
                assetType,    // <ASSET_TYPE>
                stableType    // <STABLE_TYPE>
            ],
            arguments: [
                txb.object(daoObjectId),                // dao object
                txb.object(feeManager),
                txb.object(paymentCoinId),       // <PAYMENT_COIN_ID>
                txb.pure.u64(outcomeMessages.length),   // outcome_count
                txb.object(assetCoinId),               // asset_coin
                txb.object(stableCoinId),              // stable_coin
                txb.pure.string(title),                // title as string
                txb.pure.string(details),              // description as string
                txb.pure.string(metadata),             // metadata as string
                txb.pure.vector("string", outcomeMessages), // outcome messages as vec<string>
                txb.pure.option('vector<u64>', initialAmounts),
                txb.object('0x6')                      // clock
            ],
        });
        
        const results = await signAndExecute(txb, network);
        
        console.log('Creating prop successful!');
        console.log('Transaction Digest:', results.digest);

        const resultsDir = 'futarchy-results';
        const fileNames = [`create-prop-short.json`, `create-prop-full.json`];
        const filePaths = fileNames.map(fileName => path.join(resultsDir, fileName));

        // Delete existing files
        filePaths.forEach(filePath => {
            if (existsSync(filePath)) {
                unlinkSync(filePath);
            }
        });

        writeFileSync(
            filePaths[0],
            JSON.stringify(parseCreateProposalResults(results), null, 2),
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
