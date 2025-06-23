import { execSync } from 'child_process';
import { readFileSync, writeFileSync } from 'fs';
import { homedir } from 'os';
import path from 'path';
import { getFullnodeUrl, SuiClient } from '@mysten/sui/client';
import { Ed25519Keypair } from '@mysten/sui/keypairs/ed25519';
import { Transaction } from '@mysten/sui/transactions';
import { fromBase64 } from '@mysten/sui/utils';

export type Network = 'mainnet' | 'testnet' | 'devnet' | 'localnet';
export type CustomNetwork = 'mainnet' | 'testnet' | 'devnet' | 'localnet';
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
export const getClient = (network: CustomNetwork) => {

    if (!process.env.TESTNET_RPC_URL && !process.env.MAINNET_RPC_URL) {
        throw new Error('one of TESTNET_RPC_URL or MAINNET_RPC_URL is required in the environment variables');
    }
    const urls: Record<CustomNetwork, string> = {
        mainnet: process.env.MAINNET_RPC_URL as string,
        testnet: process.env.TESTNET_RPC_URL as string,
        devnet: getFullnodeUrl('devnet' as Network),
        localnet: getFullnodeUrl('localnet' as Network)
    };

    return new SuiClient({ url: urls[network] });
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
    exportFileName = 'contract',
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

    const cap = txb.publish({
        modules,
        dependencies,
    });

    // Transfer the upgrade capability to the sender so they can upgrade the package later if they want.
    txb.transferObjects([cap], getActiveAddress());

    const results = await signAndExecute(txb, network);

    // @ts-ignore-next-line
    const packageId = results.objectChanges?.find((x) => x.type === 'published')?.packageId;

    // save to an env file
    writeFileSync(
        `${exportFileName}.json`,
        JSON.stringify({
            packageId,
        }),
        { encoding: 'utf8', flag: 'w' },
    );
};