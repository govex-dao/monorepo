
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

interface RequestVerificationResult {
    verificationId: string;
    daoId: string;
    requester: string;
}

// Add this parser function
function parseRequestVerificationResults(results: any): RequestVerificationResult {
    const events = results.events || [];
    
    // Find the VerificationRequested event
    const verificationEvent = events.find((event: any) => 
        event.type?.includes('::factory::VerificationRequested')
    );

    if (!verificationEvent || !verificationEvent.parsedJson) {
        throw new Error('VerificationRequested event not found in transaction results');
    }

    const { verification_id, dao_id, requester } = verificationEvent.parsedJson;

    return {
        verificationId: verification_id,
        daoId: dao_id,
        requester: requester
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
            showEvents: true,
		},
	});
};

export const requestDao = async ({
    packageId,
    feeManager,
    paymentCoinId,
    dao,
    attestationUrl,
    network,
}: {
    packageId: string,
    feeManager: string,
    paymentCoinId: string,
    dao: string,
    attestationUrl: string,
    network: Network,
}) => {
    try {
        const txb = new Transaction();
        

        txb.setGasBudget(50000000);

        txb.moveCall({
            target: `${packageId}::factory::request_verification`,
            arguments: [
                txb.object(feeManager),         // factory: &mut Factory
                txb.object(paymentCoinId),           // payment: Coin<SUI>
                txb.object(dao),             // dao: &mut dao::DAO
                txb.pure.string(attestationUrl),      // attestation_url: UTF8String
                txb.object('0x6'),                   // clock: &Clock - system clock object
            ],
        });
        
        const results = await signAndExecute(txb, network);
        
        console.log('Requesting Dao successful!');
        console.log('Transaction Digest:', results.digest);

        const resultsDir = 'futarchy-results';
        const fileNames = [`request-dao-short.json`, `request-dao-full.json`];
        const filePaths = fileNames.map(fileName => path.join(resultsDir, fileName));

        // Delete existing files
        filePaths.forEach(filePath => {
            if (existsSync(filePath)) {
                unlinkSync(filePath);
            }
        });

        // Write both short and full results
        writeFileSync(
            filePaths[0],
            JSON.stringify(parseRequestVerificationResults(results), null, 2),
            { encoding: 'utf8', flag: 'w' }
        );

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
