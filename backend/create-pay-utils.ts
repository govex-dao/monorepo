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

export const getClient = (network: Network) => {
    return new SuiClient({ url: getFullnodeUrl(network) });
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

interface SplitResult {
  splitCoinObjectId: string;
  originalCoinObjectId: string;
  splitAmount?: string;
}

interface ObjectChange {
  type: string;
  sender?: string;
  owner?: {
      AddressOwner?: string;
  };
  objectType?: string;
  objectId?: string;
  version?: string;
  previousVersion?: string;
  digest?: string;
}

function parseSplitResults(results: any): SplitResult {
  const objectChanges = results.objectChanges || [];
  
  // Find the newly created coin from the split
  const splitCoin = objectChanges.find((change: ObjectChange) => 
      change.type === 'created' && 
      change.objectType?.includes('0x2::coin::Coin<0x2::sui::SUI>')
  );

  // Find the original coin that was split
  const originalCoin = objectChanges.find((change: ObjectChange) => 
      change.type === 'mutated' && 
      change.objectType?.includes('0x2::coin::Coin<0x2::sui::SUI>')
  );

  if (!splitCoin || !originalCoin) {
      throw new Error('Split coin objects not found in transaction results');
  }

  return {
      splitCoinObjectId: splitCoin.objectId!,
      originalCoinObjectId: originalCoin.objectId!,
  };
}

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

export const getLargestSuiCoin = async ({
    address,
    network,
}: {
    address: string,
    network: Network,
}) => {
    try {
        const client = getClient(network);
        
        const { data: coins } = await client.getCoins({
            owner: address,
            coinType: '0x2::sui::SUI'
        });

        if (!coins || coins.length === 0) {
            throw new Error('No SUI coins found for address');
        }

        const largestCoin = coins.reduce((max, current) => {
            return BigInt(current.balance) > BigInt(max.balance) ? current : max;
        });

        return largestCoin.coinObjectId;

    } catch (error) {
        console.error('Failed to get largest SUI coin:', error);
        throw error;
    }
};

export const splitCoin = async ({
    amount,
    network,
}: {
    amount: number,
    network: Network,
}) => {
    try {
      const txb = new Transaction();
      txb.setGasBudget(10000000);
      
      // Split the coin and get the split result
      const [splitCoin] = txb.splitCoins(txb.gas, [txb.pure.u64(amount)]);
      
      // Transfer the split coin back to the same address
      const sender = getActiveAddress();
      txb.transferObjects([splitCoin], txb.pure.address(sender));
      
      const results = await signAndExecute(txb, network);
      
      console.log('Split successful!');
      console.log('Transaction Digest:', results.digest);

      

      const resultsDir = 'futarchy-results';
      const fileNames = [`create-pay-short.json`, `create-pay-full.json`];
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
          JSON.stringify(parseSplitResults(results), null, 2),
          { encoding: 'utf8', flag: 'w' }
      );

      writeFileSync(
          filePaths[1],
          JSON.stringify(results, null, 2),
          { encoding: 'utf8', flag: 'w' }
      );

      return results;

    } catch (error) {
        console.error('Split failed:', error);
        throw error;
    }
};