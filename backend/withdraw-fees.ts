import { execSync } from 'child_process';
import { readFileSync, writeFileSync } from 'fs';
import { existsSync, unlinkSync } from 'fs';
import { homedir } from 'os';
import path from 'path';
import { getFullnodeUrl, SuiClient } from '@mysten/sui/client';
import { Ed25519Keypair } from '@mysten/sui/keypairs/ed25519';
import { Transaction } from '@mysten/sui/transactions';
import { fromBase64 } from '@mysten/sui/utils';

// Constants
export type Network = 'mainnet' | 'testnet' | 'devnet' | 'localnet';
export const ACTIVE_NETWORK = (process.env.NETWORK as Network) || 'devnet';
export const SUI_BIN = `sui`;

export const getActiveAddress = () => {
    return execSync(`${SUI_BIN} client active-address`, { encoding: 'utf8' }).trim();
};

interface WithdrawFeesResult {
    feeManager: string;
    amount: string;
    recipient: string;
}

interface ObjectChange {
    type: string;
    sender?: string;
    owner?: {
        AddressOwner?: string;
        Shared?: {
            initial_shared_version: number;
        };
    };
    objectType?: string;
    objectId?: string;
}

function parseWithdrawFeesResults(results: any): WithdrawFeesResult {
    // Extract transaction details
    const objectChanges = results.objectChanges || [];
    const txEvents = results.events || [];
    
    // Find the fee manager object
    const feeManagerObj = objectChanges.find((change: ObjectChange) => 
        change.objectType?.includes('::fee::FeeManager')
    );

    // Find the withdrawal event to get the amount
    const withdrawalEvent = txEvents.find((event: any) => 
        event.type?.includes('::fee::FeesWithdrawn')
    );

    if (!feeManagerObj || !withdrawalEvent) {
        throw new Error('Required objects or events not found in transaction results');
    }

    return {
        feeManager: feeManagerObj.objectId!,
        amount: withdrawalEvent.parsedJson?.amount || '0',
        recipient: withdrawalEvent.parsedJson?.recipient || ''
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


export const withdrawAllFees = async ({
    packageId,
    feeManager,
    feeAdminCapId,
    network,
}: {
    packageId: string,
    feeManager: string,
    feeAdminCapId: string;
    network: Network,
}) => {
    console.log("HIIII");
    console.log(    packageId,
        feeManager,
        network);
    try {
        // Find the admin cap ID

        const txb = new Transaction();
        txb.setGasBudget(10000000);

        txb.moveCall({
            target: `${packageId}::fee::withdraw_all_fees`,
            arguments: [
                txb.object(feeManager),     // fee_manager
                txb.object(feeAdminCapId),     // admin_cap
                txb.object('0x6'),          // clock
            ],
        });

        console.log('Executing transaction to withdraw all fees...');
        const results = await signAndExecute(txb, network);
        
        console.log('Fee withdrawal successful!');
        console.log('Transaction Digest:', results.digest);
        
        return results;

    } catch (error) {
        console.error('Fee withdrawal failed:', error);
        throw error;
    }
};