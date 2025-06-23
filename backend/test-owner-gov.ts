
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

export const govern = async () => {
    try {
        const txb = new Transaction();
        

        txb.setGasBudget(50000000);

        txb.moveCall({
            target: `0x689501ab656d11bae3bea22d128fefee97ce83b1b71bded52f71f5939f4a1d23::governance::govern`, // package_id::module::method
            typeArguments: [
                "0xf247780882cff3c36023fdc9f685effa678d82f83da3d2388fe85bb7c695c185::govex::GOVEX" // coin type
            ],
            arguments: [
                txb.object("0xb070dfec9c5e4d139ed0fd2b827844d4cc3337be83355c8bbaa4ef6990e457b0"), // Treastcap
                txb.object("0x57f6ee73839c00906f292adb0fea0f5b0f641f8bb18b75791d9229043a3efde2"), // coin
                txb.pure.string("Test governance works!"),  // message
            ],
        });
        
        const results = await signAndExecute(txb, 'mainnet' as Network);
        
        console.log('successful!');
        
        return results;

    } catch (error) {
        console.error('Creating DAO failed:', error);
        throw error;
    }
};
