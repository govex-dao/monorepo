import fs from 'fs';
import path from 'path';
import { execSync } from 'child_process';
import { homedir } from 'os';

// SUI client & crypto imports
import { getFullnodeUrl, SuiClient } from '@mysten/sui/client';
import { Ed25519Keypair } from '@mysten/sui/keypairs/ed25519';
import { Transaction } from '@mysten/sui/transactions';
import { fromBase64 } from '@mysten/sui/utils';

// -----------------------
// Constants & Type Definitions
// -----------------------

type Network = 'mainnet' | 'testnet' | 'devnet' | 'localnet'

// SUI_BIN is the binary name used to call the move build command.
const SUI_BIN = 'sui';

export interface CoinDeploymentResult {
  packageId: string;
  treasuryCapId: string;
  metadataId: string;
  upgradeCapId: string;
  transactionDigest: string;
  coinType: string;
}

// -----------------------
// Utility Functions
// -----------------------

// Simple delay helper
const delay = (ms: number) => new Promise(resolve => setTimeout(resolve, ms));

const getActiveAddress = (): string => {
  // Capture active address from sui cli; trim whitespace
  return execSync(`${SUI_BIN} client active-address`, { encoding: 'utf8' }).trim();
};

const getSigner = (): Ed25519Keypair => {
  const sender = getActiveAddress();
  const keystorePath = path.join(homedir(), '.sui', 'sui_config', 'sui.keystore');
  const keystore = JSON.parse(fs.readFileSync(keystorePath, 'utf8'));

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
  throw new Error(`Keypair not found for sender: ${sender}`);
};

const getClient = (network: Network): SuiClient => {
  return new SuiClient({ url: getFullnodeUrl(network) });
};

const signAndExecute = async (txb: Transaction, network: Network) => {
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

/**
 * Parse deployment results for multiple publish commands.
 * Assumes that the events from the transaction occur in order.
 */
function parseCoinDeploymentResultsMultiple(results: any): CoinDeploymentResult[] {
  const objectChanges = results.objectChanges || [];
  // Gather events for each type
  const publishedEvents = objectChanges.filter((change: any) => change.type === 'published');
  const treasuryCaps = objectChanges.filter((change: any) =>
    change.objectType?.includes('::coin::TreasuryCap') &&
    change.owner?.Shared !== undefined
  );
  const metadataEvents = objectChanges.filter((change: any) =>
    change.objectType?.includes('::coin::CoinMetadata')
  );
  const upgradeCaps = objectChanges.filter((change: any) =>
    change.objectType === '0x2::package::UpgradeCap'
  );

  const digest = results.digest;
  if (
    publishedEvents.length !== treasuryCaps.length ||
    publishedEvents.length !== metadataEvents.length ||
    publishedEvents.length !== upgradeCaps.length
  ) {
    throw new Error('Mismatch in deployment events count');
  }

  return publishedEvents.map((pub: any, idx: number) => {
    const treasuryCap = treasuryCaps[idx];
    const metadata = metadataEvents[idx];
    const upgradeCap = upgradeCaps[idx];
    const coinType = treasuryCap.objectType?.match(/<(.+)>/)?.[1];
    if (!pub.packageId) throw new Error('Package ID not found in deployment results');
    if (!treasuryCap.objectId) throw new Error('Treasury Cap ID not found in deployment results');
    if (!metadata.objectId) throw new Error('Metadata ID not found in deployment results');
    if (!upgradeCap.objectId) throw new Error('UpgradeCap ID not found in deployment results');
    if (!digest) throw new Error('Transaction digest not found');
    if (!coinType) throw new Error('Coin type not found in deployment results');

    return {
      packageId: pub.packageId,
      treasuryCapId: treasuryCap.objectId,
      metadataId: metadata.objectId,
      upgradeCapId: upgradeCap.objectId,
      transactionDigest: digest,
      coinType,
    };
  });
}

// -----------------------
// Main Publish Functionality
// -----------------------

interface CoinInfo {
  packagePath: string;
  network: Network;
  exportFileName: string;
}

/**
 * Clean up a contract directory by removing its build folder and Move.lock file.
 */
function cleanupContractDir(contractPath: string, coinLabel: string): void {
  const buildDir = path.join(contractPath, 'build');
  if (fs.existsSync(buildDir)) {
    fs.rmSync(buildDir, { recursive: true });
    console.log(`Removed old build directory for ${coinLabel}`);
  }
  const lockFile = path.join(contractPath, 'Move.lock');
  if (fs.existsSync(lockFile)) {
    fs.unlinkSync(lockFile);
    console.log(`Removed Move.lock file for ${coinLabel}`);
  }
}

/**
 * Publishes both coin packages in one transaction.
 */
async function publishBothPackages(coins: CoinInfo[]): Promise<void> {
  // Create a new transaction builder.
  const txb = new Transaction();

  // To preserve the order of coins for later result file generation,
  // store build info for each coin.
  const coinBuilds: Array<{ exportFileName: string; modules: any; dependencies: any }> = [];

  for (const coin of coins) {
    const contractPath = path.resolve(__dirname, '../../contracts', path.basename(coin.packagePath));
    cleanupContractDir(contractPath, coin.exportFileName);

    // Build the package; the command outputs a JSON with modules and dependencies.
    const buildCmd = `${SUI_BIN} move build --dump-bytecode-as-base64 --path ${contractPath}`;
    const buildOutput = execSync(buildCmd, { encoding: 'utf8' });
    const { modules, dependencies } = JSON.parse(buildOutput);

    coinBuilds.push({ exportFileName: coin.exportFileName, modules, dependencies });
    // Publish and capture the returned upgrade capability.
    const cap = txb.publish({ modules, dependencies });
    // Transfer the upgrade capability to the active address.
    txb.transferObjects([cap], getActiveAddress());
  }

  // Set an appropriate gas budget (adjust as needed).
  txb.setGasBudget(300000000);

  // Execute the transaction on the network of the first coin (assumed same for both).
  console.log('Publishing both packages in one transaction...');
  const results = await signAndExecute(txb, coins[0].network);
  console.log('Transaction executed. Processing results...');

  // Parse the results into one deployment result per publish command.
  const deployments = parseCoinDeploymentResultsMultiple(results);

  // Write results to files for each coin.
  // For each coin, we write:
  //   1. futarchy-pub-<exportFileName>-short.json  (parsed results)
  //   2. futarchy-pub-<exportFileName>-full.json   (full results)
  //   3. <exportFileName>.json                     (parsed results)
  const resultsDir = 'futarchy-results';
  if (!fs.existsSync(resultsDir)) {
    fs.mkdirSync(resultsDir);
  }

  // Assume the order of deployments matches the order of coins.
  for (let i = 0; i < coins.length; i++) {
    const coin = coins[i];
    const deployment = deployments[i];

    const fileConfigs = [
      {
        filePath: path.join(resultsDir, `futarchy-pub-${coin.exportFileName}-short.json`),
        content: deployment,
      },
      {
        filePath: path.join(resultsDir, `futarchy-pub-${coin.exportFileName}-full.json`),
        content: results,
      },
      {
        filePath: `${coin.exportFileName}.json`,
        content: deployment,
      },
    ];

    for (const { filePath } of fileConfigs) {
      if (fs.existsSync(filePath)) {
        fs.unlinkSync(filePath);
      }
    }
    for (const { filePath, content } of fileConfigs) {
      fs.writeFileSync(filePath, JSON.stringify(content, null, 2), { encoding: 'utf8', flag: 'w' });
    }
    console.log(`Deployment files written for ${coin.exportFileName}`);
  }
}

// -----------------------
// Main Deployment Function
// -----------------------

async function deployContracts(): Promise<void> {
  try {
    // Define the coins to publish.
    // The packagePath is relative to ../../contracts and here we use folder names.
    const coins: CoinInfo[] = [
      {
        packagePath: 'asset', // corresponds to ../../contracts/asset
        network: 'devnet',
        exportFileName: 'asset-contract',
      },
      {
        packagePath: 'stable', // corresponds to ../../contracts/stable
        network: 'devnet',
        exportFileName: 'stable-contract',
      },
    ];

    await publishBothPackages(coins);
    console.log('Both packages published successfully in one transaction.');
  } catch (error) {
    console.error('Error during contract deployment:', error);
    throw error;
  }
}

// Execute deployment
deployContracts();
