
import { execSync } from 'child_process';
import { readFileSync, writeFileSync } from 'fs';
import { existsSync, unlinkSync} from 'fs';
import { homedir } from 'os';
import path from 'path';
import { getFullnodeUrl, SuiClient } from '@mysten/sui/client';
import { Ed25519Keypair } from '@mysten/sui/keypairs/ed25519';
import { Transaction } from '@mysten/sui/transactions';
import { fromBase64 } from '@mysten/sui/utils';

export type Network = 'mainnet' | 'testnet' | 'devnet' | 'localnet';

export const ACTIVE_NETWORK = (process.env.NETWORK as Network) || 'devnet';

export const SUI_BIN = `sui`;

export const getActiveAddress = () => {
	return execSync(`${SUI_BIN} client active-address`, { encoding: 'utf8' }).trim();
};

interface ConditionalTokenResult {
    conditionalTokenId: string;
    conditionalTokenType: string;
}

interface ObjectChange {
    type: string;
    objectType?: string;
    objectId?: string;
}

function parseConditionalToken(results: any): ConditionalTokenResult {
    const objectChanges = results.objectChanges || [];

    // Find the created ConditionalToken object
    const conditionalTokenObject = objectChanges.find((change: ObjectChange) => 
        change.type === 'created' && 
        change.objectType?.includes('::conditional_token::ConditionalToken')
    );

    if (!conditionalTokenObject) {
        throw new Error('Conditional token object not found in transaction results');
    }

    return {
        conditionalTokenId: conditionalTokenObject.objectId!,
        conditionalTokenType: conditionalTokenObject.objectType!
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

export const swapAssetToStable = async ({
    packageId,
    proposalId,
    escrowId,
    assetType,
    stableType,
    outcomeIdx,
    tokenToSwap,
    minAmountOut,
    network,
}: {
    packageId: string,
    proposalId: string,
    escrowId: string,
    assetType: string,
    stableType: string,
    outcomeIdx: number,
    tokenToSwap: string,  // ConditionalToken object ID
    minAmountOut: number,
    network: Network
}) => {
    try {

        console.log({
            proposalId,
            escrowId,
            outcomeIdx,
            tokenToSwap,
            minAmountOut
        });
        
        const txb = new Transaction();
        txb.setGasBudget(1000000000);
        
        txb.moveCall({
            target: `${packageId}::proposal::swap_asset_to_stable_entry`,
            typeArguments: [assetType, stableType],
            arguments: [
                txb.object(proposalId),      // &mut Proposal
                txb.object(escrowId),        // &mut TokenEscrow
                txb.pure.u64(outcomeIdx),    // outcome_idx: u64
                txb.object(tokenToSwap),     // token_to_swap: ConditionalToken
                txb.pure.u64(minAmountOut),  // min_amount_out: u64
                txb.object('0x6')            // clock: &Clock
            ],
        });
        
        const results = await signAndExecute(txb, network);
        
        console.log('Creating prop successful!');
        console.log('Transaction Digest:', results.digest);

        const resultsDir = 'futarchy-results';
        const fileNames = [`swap-a-to-s-short.json`, `swap-a-to-s-full.json`];
        const filePaths = fileNames.map(fileName => path.join(resultsDir, fileName));

        // Delete existing files
        filePaths.forEach(filePath => {
            if (existsSync(filePath)) {
                unlinkSync(filePath);
            }
        });

        writeFileSync(
            filePaths[0],
            JSON.stringify(parseConditionalToken(results), null, 2),
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
