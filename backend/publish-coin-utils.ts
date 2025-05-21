// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

import { execSync } from 'child_process';
import { readFileSync, writeFileSync, existsSync, unlinkSync, mkdirSync } from 'fs';
import { homedir } from 'os';
import path from 'path';
import { 
    getFullnodeUrl, 
    SuiClient, 
    SuiTransactionBlockResponse, 
    SuiObjectChange 
} from '@mysten/sui/client'; // Use client from @mysten/sui/client
import { Ed25519Keypair } from '@mysten/sui/keypairs/ed25519';
import { Transaction } from '@mysten/sui/transactions'; // Use Transaction from @mysten/sui/transactions
import { fromBase64, isValidSuiAddress } from '@mysten/sui/utils'; // Added isValidSuiAddress

export type Network = 'mainnet' | 'testnet' | 'devnet' | 'localnet';

export const ACTIVE_NETWORK = (process.env.NETWORK as Network) || 'devnet';

export const SUI_BIN = `sui`;

export const getActiveAddress = () => {
	return execSync(`${SUI_BIN} client active-address`, { encoding: 'utf8' }).trim();
};

interface CoinDeploymentResult {
	packageId: string;
	treasuryCapId: string;
	metadataId: string;
	upgradeCapId: string;
	transactionDigest: string;
	coinType: string; 
}
  
function parseCoinDeploymentResults(results: SuiTransactionBlockResponse): CoinDeploymentResult {
	const objectChanges = results.objectChanges || [];
  
	let newPackageId: string | undefined;
	let treasuryCapId: string | undefined;
	let metadataId: string | undefined;
	let upgradeCapId: string | undefined;
	let actualCoinType: string | undefined; // Renamed for clarity
	let actualModuleName: string | undefined;
	let actualCoinName: string | undefined;

	const publishedChange = objectChanges.find(
	  (change): change is Extract<SuiObjectChange, { type: 'published' }> => 
		change.type === 'published'
	);
  
	if (!publishedChange || !publishedChange.packageId || !publishedChange.modules || publishedChange.modules.length === 0) {
	  throw new Error('Published package ID or module name not found in deployment results.');
	}
	newPackageId = publishedChange.packageId;
	actualModuleName = publishedChange.modules[0]; // Assuming one module defining the coin
  
	// Find the TreasuryCap first to determine the actual coin name
	objectChanges.forEach(change => {
		if (change.type === 'created') {
			if (change.objectType.startsWith(`0x2::coin::TreasuryCap<${newPackageId}::${actualModuleName}::`)) {
				const match = change.objectType.match(/0x2::coin::TreasuryCap<([^:]+)::([^:]+)::([^>]+)>/);
				if (match) {
					actualCoinName = match[3];
					actualCoinType = `${newPackageId}::${actualModuleName}::${actualCoinName}`;
					treasuryCapId = change.objectId;
				}
			} else if (change.objectType === '0x2::package::UpgradeCap') {
				upgradeCapId = change.objectId;
			}
		}
	});

	if (!actualCoinType || !actualCoinName) {
		throw new Error(`Could not determine coin type for package ${newPackageId} and module ${actualModuleName}. TreasuryCap not found or malformed.`);
	}

	// Now find CoinMetadata using the determined actualCoinType
	objectChanges.forEach(change => {
		if (change.type === 'created') {
			if (change.objectType === `0x2::coin::CoinMetadata<${actualCoinType}>`) {
				metadataId = change.objectId;
			}
		}
	});
  
	if (!treasuryCapId) {
	  throw new Error(`Treasury Cap object (expected pattern: 0x2::coin::TreasuryCap<${newPackageId}::${actualModuleName}::COIN_NAME>) not found in created objects.`);
	}
	if (!metadataId) {
	  throw new Error(`Coin Metadata object (type: 0x2::coin::CoinMetadata<${actualCoinType}>) not found in created objects.`);
	}
	if (!upgradeCapId) {
	  throw new Error('UpgradeCap object (type: 0x2::package::UpgradeCap) not found in created objects.');
	}
	if (!results.digest) {
	  throw new Error('Transaction digest not found in results.');
	}
  
	return {
	  packageId: newPackageId,
	  treasuryCapId: treasuryCapId,
	  metadataId: metadataId,
	  upgradeCapId: upgradeCapId,
	  transactionDigest: results.digest,
	  coinType: actualCoinType,
	};
  }

export const getSigner = (): Ed25519Keypair => {
	const sender = getActiveAddress();
	const keystorePath = path.join(homedir(), '.sui', 'sui_config', 'sui.keystore');
    if (!existsSync(keystorePath)) {
        throw new Error(`Keystore file not found at: ${keystorePath}. Please ensure the Sui CLI is configured.`);
    }
	const keystore = JSON.parse(readFileSync(keystorePath, 'utf8'));

	if (!Array.isArray(keystore)) {
        throw new Error('Invalid keystore format. Expected an array of keys.');
    }

	for (const priv of keystore) {
        if (typeof priv !== 'string') continue; // Ensure priv is a string
		const raw = fromBase64(priv);
		if (raw[0] !== 0) {
			continue;
		}
		const pair = Ed25519Keypair.fromSecretKey(raw.slice(1));
		if (pair.getPublicKey().toSuiAddress() === sender) {
			return pair;
		}
	}
	throw new Error(`Keypair not found for sender address: ${sender} in keystore. Make sure the active address has a corresponding key.`);
};

export const getClient = (network: Network): SuiClient => {
	return new SuiClient({ url: getFullnodeUrl(network) });
};

// Reverted to signAndExecuteTransaction and adjusted parameters for older SDK
export const signAndExecute = async (txb: Transaction, network: Network): Promise<SuiTransactionBlockResponse> => {
	const client = getClient(network);
	const signer = getSigner();

	// For older SDKs that use signAndExecuteTransaction with Transaction objects
	return client.signAndExecuteTransaction({ // Reverted to this method name
		transaction: txb, // 'transaction' instead of 'transactionBlock'
		signer,
		options: {
			showEffects: true,
			showObjectChanges: true, 
		},
	});
};

export const publishPackage = async ({
	packagePath,
	network,
	exportFileName,
}: {
	packagePath: string;
	network: Network;
	exportFileName: string;
}): Promise<SuiTransactionBlockResponse> => {
	const txb = new Transaction();

	const { modules, dependencies } = JSON.parse(
		execSync(`${SUI_BIN} move build --dump-bytecode-as-base64 --path ${packagePath}`, {
			encoding: 'utf-8',
		}),
	);

	txb.setGasBudget(200000000); 
	const cap = txb.publish({
		modules,
		dependencies,
	});

	txb.transferObjects([cap], getActiveAddress());


	const results = await signAndExecute(txb, network);
	console.log(JSON.stringify(results, null, 2)); 

	const resultsDir = 'futarchy-results';
	if (!existsSync(resultsDir)) {
		mkdirSync(resultsDir, { recursive: true });
		console.log(`Created directory: ${resultsDir}`);
	}
	
	const parsedDeploymentResults = parseCoinDeploymentResults(results); 
	
	const fileConfigs = [
	  { path: path.join(resultsDir, `futarchy-pub-${exportFileName}-short.json`), content: parsedDeploymentResults },
	  { path: path.join(resultsDir, `futarchy-pub-${exportFileName}-full.json`), content: results },
	  { path: `${exportFileName}.json`, content: parsedDeploymentResults } 
	];

	fileConfigs.forEach(({ path: filePath }) => {
	  if (existsSync(filePath)) {
		unlinkSync(filePath);
	  }
	});
	
	fileConfigs.forEach(({ path: filePath, content }) => {
	  writeFileSync(filePath, JSON.stringify(content, null, 2), { encoding: 'utf8', flag: 'w' });
	  console.log(`Written results to: ${filePath}`);
	});

	return results;
};