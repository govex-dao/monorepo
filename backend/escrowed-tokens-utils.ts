
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

interface FlatEscrowResult {
    escrowId: string;
    assetType?: string;
    stableType?: string;
    conditionalTokenType?: string;
    [key: string]: string | undefined;
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
    version?: string;
    digest?: string;
    content?: {
        dataType: string;
        type: string;
        hasPublicTransfer: boolean;
        fields: {
            id: {
                id: string;
            };
            market_id: string;
            outcome: number | string;
            value: string;
            asset_type: number;
        };
    };
}

function parseEscrowResults(results: any): FlatEscrowResult {
    const objectChanges = results.objectChanges || [];
    
    // Find the TokenEscrow object
    const escrowObject = objectChanges.find((change: ObjectChange) => 
        change.type === 'mutated' && 
        change.objectType?.includes('::coin_escrow::TokenEscrow') &&
        change.owner?.Shared
    );


    // Find all ConditionalToken objects and sort them by outcome
    const conditionalTokenObjects = objectChanges.filter((change: ObjectChange) => 
        change.type === 'created' && 
        change.objectType?.includes('::conditional_token::ConditionalToken')
    );

    if (!escrowObject || conditionalTokenObjects.length === 0) {
        throw new Error('Required objects not found in transaction results');
    }

    // Extract type information from escrow object type
    const escrowType = escrowObject.objectType || '';
    const typeMatches = escrowType.match(/<(.+),\s*(.+)>/);
    const [assetType, stableType] = typeMatches ? [typeMatches[1], typeMatches[2]] : [undefined, undefined];

    // Create flat result object
    let result: FlatEscrowResult = {
        escrowId: escrowObject.objectId!,
        assetType,
        stableType,
        conditionalTokenType: conditionalTokenObjects[0]?.objectType
    };

    // Sort tokens by outcome number if possible
    let tokenIndex = 0;
    conditionalTokenObjects.forEach((token: any) => {
        // Since we don't see the outcome in the change object directly, 
        // we'll use sequential numbering for now
        result[`outcomeToken${tokenIndex}`] = token.objectId!;
        tokenIndex++;
    });

    return result;
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

export const depositAndCreateTokens = async ({
    packageId,
    escrowId,
    assetType,
    stableType,
    coinId,
    amount,
    outcomeIdx,
    network,
}: {
    packageId: string,
    escrowId: string,
    assetType: string,
    stableType: string,
    coinId: string,
    amount: number,
    outcomeIdx: number,
    network: Network
}) => {
    try {
        const txb = new Transaction();
        txb.setGasBudget(1000000000);
        
        // Split coins for deposit
        const [splitCoin] = txb.splitCoins(
            txb.object(coinId),
            [txb.pure.u64(amount)]
        );
        
        // First deposit the asset
        txb.moveCall({
            target: `${packageId}::coin_escrow::deposit_asset_entry`,
            typeArguments: [
                assetType,
                stableType
            ],
            arguments: [
                txb.object(escrowId),
                splitCoin
            ],
        });

        // Then create the tokens
        txb.moveCall({
            target: `${packageId}::coin_escrow::create_asset_tokens_entry`,
            typeArguments: [
                assetType,
                stableType
            ],
            arguments: [
                txb.object(escrowId),
                txb.pure.u64(amount),
                txb.object('0x6')  // clock
            ],
        });
        
        const results = await signAndExecute(txb, network);
        
        console.log('Creating prop successful!');
        console.log('Transaction Digest:', results.digest);

        const resultsDir = 'futarchy-results';
        const fileNames = [`escrow-deposit-short.json`, `escrow-deposit-full.json`];
        const filePaths = fileNames.map(fileName => path.join(resultsDir, fileName));

        // Delete existing files
        filePaths.forEach(filePath => {
            if (existsSync(filePath)) {
                unlinkSync(filePath);
            }
        });

        writeFileSync(
            filePaths[0],
            JSON.stringify(parseEscrowResults(results), null, 2),
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
