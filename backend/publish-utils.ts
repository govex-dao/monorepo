// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

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

interface DeploymentResult {
	packageId: string;
	upgradeCapId: string;
	factoryId: string;
	factoryOwnerCapId: string;
	validatorAdminCapId: string;
	feeAdminCapId: string;
	feeManagerId: string;
	transactionDigest: string;
}
  
interface ObjectChange {
	type: string;
	packageId?: string;
	objectType?: string;
	objectId?: string;
}
  
function parseDeploymentResults(results: any): DeploymentResult {
	const objectChanges = results.objectChanges || [];
  
	// Find specific objects by their types, using more precise type matching
	const published = objectChanges.find((change: ObjectChange) => 
	  change.type === 'published'
	);
  
	const factory = objectChanges.find((change: ObjectChange) => 
	  change.objectType?.includes('::factory::Factory') &&
	  !change.objectType?.includes('FactoryOwnerCap')
	);
  
	const upgradeCap = objectChanges.find((change: ObjectChange) => 
	  change.objectType === '0x2::package::UpgradeCap'
	);
  
	const factoryOwnerCap = objectChanges.find((change: ObjectChange) => 
	  change.objectType?.includes('::factory::FactoryOwnerCap')
	);
  
	const validatorAdminCap = objectChanges.find((change: ObjectChange) => 
	  change.objectType?.includes('::factory::ValidatorAdminCap')
	);
  
	// New code to find FeeAdminCap
	const feeAdminCap = objectChanges.find((change: ObjectChange) => 
	  change.objectType?.includes('::fee::FeeAdminCap')
	);
  
	// New code to find FeeManager
	const feeManager = objectChanges.find((change: ObjectChange) => 
	  change.objectType?.includes('::fee::FeeManager')
	);
  
	// Add error checking for required fields
	if (!published?.packageId) throw new Error('Package ID not found in deployment results');
	if (!factory?.objectId) throw new Error('Factory ID not found in deployment results');
	if (!upgradeCap?.objectId) throw new Error('UpgradeCap ID not found in deployment results');
	if (!factoryOwnerCap?.objectId) throw new Error('FactoryOwnerCap ID not found in deployment results');
	if (!validatorAdminCap?.objectId) throw new Error('ValidatorAdminCap ID not found in deployment results');
	if (!feeAdminCap?.objectId) throw new Error('FeeAdminCap ID not found in deployment results');
	if (!feeManager?.objectId) throw new Error('FeeManager ID not found in deployment results');
  
	return {
	  packageId: published.packageId,
	  upgradeCapId: upgradeCap.objectId,
	  factoryId: factory.objectId,
	  factoryOwnerCapId: factoryOwnerCap.objectId,
	  validatorAdminCapId: validatorAdminCap.objectId,
	  feeAdminCapId: feeAdminCap.objectId,    // New field
	  feeManagerId: feeManager.objectId,      // New field
	  transactionDigest: results.digest
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

/** Publishes a package and saves the package id to a specified json file. */
export const publishPackage = async ({
	packagePath,
	network,
	exportFileName = 'futarchy',
}: {
	packagePath: string;
	network: Network;
	exportFileName: string;
}) => {
	const txb = new Transaction();

	const { modules, dependencies } = JSON.parse(
		execSync(`${SUI_BIN} move build --dump-bytecode-as-base64 --path ${packagePath}`, {
			encoding: 'utf-8',
		}),
	);

	txb.setGasBudget(500000000);
	const cap = txb.publish({
		modules,
		dependencies,
	});

	// Transfer the upgrade capability to the sender so they can upgrade the package later if they want.
	txb.transferObjects([cap], getActiveAddress());

	const results = await signAndExecute(txb, network);

	// Single write operation that replaces your previous two writes

	const resultsDir = 'futarchy-results';
	const fileConfigs = [
	  { path: path.join(resultsDir, 'futarchy-pub-short.json'), content: parseDeploymentResults(results) },
	  { path: path.join(resultsDir, 'futarchy-pub-full.json'), content: results },
	  { path: 'dao-contract.json', content: parseDeploymentResults(results) }
	];
	
	// Delete existing files
	fileConfigs.forEach(({ path: filePath }) => {
	  if (existsSync(filePath)) {
		unlinkSync(filePath);
	  }
	});
	
	// Write all files
	fileConfigs.forEach(({ path: filePath, content }) => {
	  writeFileSync(filePath, JSON.stringify(content, null, 2), { encoding: 'utf8', flag: 'w' });
	});

	return results;

};
