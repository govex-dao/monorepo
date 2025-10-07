/**
 * TypeScript SDK Example: SEAL-Based Hidden Fundraising Caps
 *
 * This file demonstrates how to use SEAL time-lock encryption to hide
 * fundraising caps during a launchpad raise, preventing oversubscription gaming.
 *
 * ARCHITECTURE:
 * 1. Founder generates random 32-byte salt off-chain
 * 2. Computes commitment = hash(max_raise || salt)
 * 3. Encrypts BOTH max_raise AND salt with SEAL (identity = deadline)
 * 4. Uploads encrypted blob to Walrus
 * 5. Stores only blob_id and commitment_hash on-chain
 * 6. After deadline, ANYONE can decrypt SEAL blob and reveal max_raise
 * 7. Chain verifies hash(decrypted_max_raise || decrypted_salt) == commitment
 */

import { Transaction } from '@mysten/sui/transactions';
import { SuiClient } from '@mysten/sui/client';
import { bcs } from '@mysten/sui/bcs';
import { keccak256 } from '@noble/hashes/sha3';
import * as crypto from 'crypto';

// PLACEHOLDER IMPORTS - Update when SEAL SDK is available
// import { seal } from '@mysten/seal-sdk';
// import { walrus } from '@walrus/sdk';

// ============================================================================
// STEP 1: CREATE RAISE WITH SEALED CAP (Founder calls this)
// ============================================================================

interface CreateRaiseWithSealedCapParams {
    // Raise parameters
    raiseToken: string;
    stableCoin: string;
    treasuryCap: string;
    tokensForRaise: string;
    minRaiseAmount: bigint;
    maxRaiseAmount: bigint;  // This will be hidden!
    allowedCaps: bigint[];
    description: string;

    // DAO parameters
    daoName: string;
    daoDescription: string;
    iconUrl: string;
    reviewPeriodMs: bigint;
    tradingPeriodMs: bigint;
    ammTwapStartDelay: bigint;
    ammTwapStepMax: bigint;
    ammTwapInitialObservation: bigint;
    twapThreshold: bigint;
    maxOutcomes: bigint;
    agreementLines: string[];
    agreementDifficulties: bigint[];

    // Other
    factory: string;
    clock: string;
    deadline_ms: bigint;
}

async function createRaiseWithSealedCap(
    client: SuiClient,
    params: CreateRaiseWithSealedCapParams
): Promise<{ txDigest: string; raiseId: string }> {

    // ========================================================================
    // STEP 1.1: Generate random 32-byte salt (entropy for security)
    // ========================================================================
    const salt = crypto.randomBytes(32);
    console.log('Generated salt (keep this secure during testing):', salt.toString('hex'));

    // ========================================================================
    // STEP 1.2: Compute commitment hash(max_raise || salt)
    // ========================================================================
    // Serialize max_raise as u64 in BCS format
    const maxRaiseBytes = bcs.u64().serialize(params.maxRaiseAmount).toBytes();

    // Concatenate: max_raise_bytes || salt_bytes
    const combinedData = new Uint8Array([...maxRaiseBytes, ...salt]);

    // Hash with keccak256 (same as Sui's hash function)
    const commitmentHash = keccak256(combinedData);

    console.log('Commitment hash:', Buffer.from(commitmentHash).toString('hex'));

    // ========================================================================
    // STEP 1.3: Encrypt BOTH max_raise AND salt with SEAL
    // ========================================================================

    // Create the data structure to encrypt
    interface SealEncryptedData {
        max_raise: bigint;
        salt: Uint8Array;
    }

    const dataToEncrypt: SealEncryptedData = {
        max_raise: params.maxRaiseAmount,
        salt: salt,
    };

    // Serialize to bytes (using BCS or JSON depending on SEAL SDK)
    // NOTE: This is placeholder code - update when SEAL SDK is available
    const serializedData = Buffer.from(JSON.stringify({
        max_raise: params.maxRaiseAmount.toString(),
        salt: Array.from(salt),
    }));

    console.log('Data to encrypt (size):', serializedData.length, 'bytes');

    // SEAL encryption with time-lock identity = deadline_ms
    // The key servers will only release decryption keys after this time
    const identityBytes = bcs.u64().serialize(params.deadline_ms).toBytes();

    console.log('SEAL identity (deadline):', params.deadline_ms.toString());

    // PLACEHOLDER: Replace with actual SEAL SDK call when available
    /*
    const encryptedBlob = await seal.encrypt({
        data: serializedData,
        identity: identityBytes,
        // Additional SEAL parameters TBD when SDK is documented
    });
    */

    // For now, simulate encrypted blob structure
    const encryptedBlob = {
        data: serializedData,  // In production, this would be encrypted
        identity: identityBytes,
    };

    // ========================================================================
    // STEP 1.4: Upload encrypted blob to Walrus
    // ========================================================================

    console.log('Uploading encrypted blob to Walrus...');

    // PLACEHOLDER: Replace with actual Walrus SDK call when available
    /*
    const walrusUploadResult = await walrus.upload({
        data: encryptedBlob.data,
        epochs: 52,  // Store for ~1 year (52 epochs * 14 days)
    });
    const blobId = walrusUploadResult.blobId;
    */

    // For now, simulate blob ID
    const blobId = new Uint8Array(32);  // Placeholder
    crypto.randomFillSync(blobId);

    console.log('Walrus blob ID:', Buffer.from(blobId).toString('hex'));

    // ========================================================================
    // STEP 1.5: Build transaction to create raise on-chain
    // ========================================================================

    const tx = new Transaction();

    tx.moveCall({
        target: `${process.env.PACKAGE_ID}::launchpad::create_raise_with_sealed_cap`,
        arguments: [
            tx.object(params.factory),
            tx.object(params.treasuryCap),
            tx.object(params.tokensForRaise),
            tx.pure(bcs.u64().serialize(params.minRaiseAmount)),
            tx.pure(bcs.vector(bcs.u64()).serialize(params.allowedCaps)),
            tx.pure(bcs.vector(bcs.u8()).serialize(Array.from(blobId))),  // Walrus blob ID
            tx.pure(bcs.vector(bcs.u8()).serialize(Array.from(commitmentHash))),  // Commitment hash
            tx.pure(bcs.string().serialize(params.description)),
            // DAO parameters...
            tx.pure(bcs.string().serialize(params.daoName)),
            tx.pure(bcs.string().serialize(params.daoDescription)),
            tx.pure(bcs.string().serialize(params.iconUrl)),
            tx.pure(bcs.u64().serialize(params.reviewPeriodMs)),
            tx.pure(bcs.u64().serialize(params.tradingPeriodMs)),
            tx.pure(bcs.u64().serialize(params.ammTwapStartDelay)),
            tx.pure(bcs.u64().serialize(params.ammTwapStepMax)),
            tx.pure(bcs.u128().serialize(params.ammTwapInitialObservation)),
            tx.pure(bcs.u64().serialize(params.twapThreshold)),
            tx.pure(bcs.u64().serialize(params.maxOutcomes)),
            tx.pure(bcs.vector(bcs.string()).serialize(params.agreementLines)),
            tx.pure(bcs.vector(bcs.u64()).serialize(params.agreementDifficulties)),
            tx.object(params.clock),
        ],
        typeArguments: [params.raiseToken, params.stableCoin],
    });

    // Execute transaction
    const result = await client.signAndExecuteTransaction({
        transaction: tx,
        // signer: keypair,  // Add signer from wallet
    });

    console.log('Raise created! Transaction:', result.digest);

    // Extract raise object ID from transaction effects
    const raiseId = '0x...';  // Extract from result.effects.created

    console.log('Raise ID:', raiseId);
    console.log('\n⚠️  IMPORTANT: Founder can now forget max_raise and salt!');
    console.log('They are encrypted in SEAL and will auto-decrypt after deadline.');

    return {
        txDigest: result.digest,
        raiseId,
    };
}

// ============================================================================
// STEP 2: REVEAL MAX RAISE (Anyone can call this after deadline)
// ============================================================================

interface RevealMaxRaiseParams {
    raiseId: string;
    clock: string;
}

async function revealMaxRaise(
    client: SuiClient,
    params: RevealMaxRaiseParams
): Promise<{ txDigest: string; revealedMaxRaise: bigint }> {

    // ========================================================================
    // STEP 2.1: Fetch raise object to get blob_id and deadline
    // ========================================================================

    console.log('Fetching raise object...');

    const raiseObject = await client.getObject({
        id: params.raiseId,
        options: { showContent: true },
    });

    if (!raiseObject.data?.content || raiseObject.data.content.dataType !== 'moveObject') {
        throw new Error('Raise object not found');
    }

    const raiseFields = raiseObject.data.content.fields as any;
    const blobId = raiseFields.max_raise_sealed_blob_id;
    const deadlineMs = BigInt(raiseFields.deadline_ms);

    console.log('Blob ID:', blobId);
    console.log('Deadline:', new Date(Number(deadlineMs)).toISOString());

    // Check if deadline has passed
    const now = Date.now();
    if (now < Number(deadlineMs)) {
        throw new Error(`Cannot reveal yet! Deadline is ${new Date(Number(deadlineMs)).toISOString()}`);
    }

    // ========================================================================
    // STEP 2.2: Decrypt SEAL blob (anyone can do this after deadline)
    // ========================================================================

    console.log('Decrypting SEAL blob...');

    // SEAL decryption with time-lock identity = deadline_ms
    const identityBytes = bcs.u64().serialize(deadlineMs).toBytes();

    // PLACEHOLDER: Replace with actual SEAL SDK call when available
    /*
    const decryptedData = await seal.decrypt({
        blobId: blobId,
        identity: identityBytes,
        // Additional SEAL parameters TBD
    });
    */

    // For now, simulate decrypted data (in production, SEAL returns this)
    const decryptedData = Buffer.from(JSON.stringify({
        max_raise: '10000000000',  // Example: $10M
        salt: Array.from(crypto.randomBytes(32)),
    }));

    // ========================================================================
    // STEP 2.3: Parse decrypted data
    // ========================================================================

    interface DecryptedData {
        max_raise: string;
        salt: number[];
    }

    const parsed: DecryptedData = JSON.parse(decryptedData.toString());
    const maxRaise = BigInt(parsed.max_raise);
    const salt = new Uint8Array(parsed.salt);

    console.log('Decrypted max_raise:', maxRaise.toString());
    console.log('Decrypted salt:', Buffer.from(salt).toString('hex'));

    // ========================================================================
    // STEP 2.4: Verify commitment hash (optional sanity check)
    // ========================================================================

    const maxRaiseBytes = bcs.u64().serialize(maxRaise).toBytes();
    const combinedData = new Uint8Array([...maxRaiseBytes, ...salt]);
    const computedHash = keccak256(combinedData);

    const storedCommitment = raiseFields.max_raise_commitment_hash;

    console.log('Computed hash:', Buffer.from(computedHash).toString('hex'));
    console.log('Stored commitment:', storedCommitment);

    // Note: On-chain verification is mandatory, this is just a sanity check

    // ========================================================================
    // STEP 2.5: Call reveal_and_begin_settlement on-chain
    // ========================================================================

    const tx = new Transaction();

    tx.moveCall({
        target: `${process.env.PACKAGE_ID}::launchpad::reveal_and_begin_settlement`,
        arguments: [
            tx.object(params.raiseId),
            tx.pure(bcs.u64().serialize(maxRaise)),              // Decrypted max_raise
            tx.pure(bcs.vector(bcs.u8()).serialize(Array.from(salt))),  // Decrypted salt (32 bytes)
            tx.object(params.clock),
        ],
        typeArguments: ['RaiseToken', 'StableCoin'],  // Update with actual types
    });

    // Execute transaction
    const result = await client.signAndExecuteTransaction({
        transaction: tx,
        // signer: keypair,
    });

    console.log('Max raise revealed! Transaction:', result.digest);
    console.log('Revealed max_raise:', maxRaise.toString());

    return {
        txDigest: result.digest,
        revealedMaxRaise: maxRaise,
    };
}

// ============================================================================
// STEP 3: INDEXER AUTO-REVEAL (Automated backend service)
// ============================================================================

/**
 * This is an example of how your indexer/backend would automatically
 * reveal max_raise for all raises that reach their deadline.
 *
 * Run this as a cron job every minute or listen to blockchain events.
 */
async function indexerAutoRevealService(client: SuiClient) {
    console.log('Starting auto-reveal service...');

    // Query all raises that:
    // 1. Have sealed max_raise (max_raise_sealed_blob_id is Some)
    // 2. Reached deadline (deadline_ms < now)
    // 3. Not yet revealed (max_raise_revealed is None)

    // PLACEHOLDER: Replace with actual query
    const raisesNeedingReveal = [
        // { raiseId: '0x...', deadline_ms: 123456789, blob_id: '0x...' }
    ];

    console.log(`Found ${raisesNeedingReveal.length} raises needing reveal`);

    for (const raise of raisesNeedingReveal) {
        try {
            console.log(`\nRevealing raise ${raise.raiseId}...`);

            const result = await revealMaxRaise(client, {
                raiseId: raise.raiseId,
                clock: '0x6',  // Sui Clock object
            });

            console.log(`✅ Successfully revealed: $${result.revealedMaxRaise}`);

        } catch (error) {
            console.error(`❌ Failed to reveal raise ${raise.raiseId}:`, error);

            // Retry logic
            // If SEAL is down, schedule retry in 5 minutes
        }
    }
}

// ============================================================================
// USAGE EXAMPLES
// ============================================================================

async function main() {
    const client = new SuiClient({ url: 'https://fullnode.testnet.sui.io' });

    // Example 1: Founder creates raise with hidden cap
    console.log('=== Example 1: Create Raise with Sealed Cap ===\n');

    const createResult = await createRaiseWithSealedCap(client, {
        raiseToken: '0x...::token::TOKEN',
        stableCoin: '0x...::usdc::USDC',
        treasuryCap: '0x...',
        tokensForRaise: '0x...',
        minRaiseAmount: 1_000_000n,  // $1M minimum
        maxRaiseAmount: 10_000_000n, // $10M maximum (HIDDEN)
        allowedCaps: [5_000_000n, 10_000_000n, 20_000_000n],
        description: 'Revolutionary DAO for...',
        daoName: 'MyDAO',
        daoDescription: 'A DAO for...',
        iconUrl: 'https://...',
        reviewPeriodMs: 7n * 24n * 60n * 60n * 1000n,  // 7 days
        tradingPeriodMs: 7n * 24n * 60n * 60n * 1000n,
        ammTwapStartDelay: 3600n * 1000n,
        ammTwapStepMax: 60n * 1000n,
        ammTwapInitialObservation: 1_000_000_000_000n,
        twapThreshold: 10_000n,
        maxOutcomes: 10n,
        agreementLines: ['Article 1: Purpose...', 'Article 2: Governance...'],
        agreementDifficulties: [5000n, 7500n],
        factory: '0x...',
        clock: '0x6',
        deadline_ms: BigInt(Date.now() + 14 * 24 * 60 * 60 * 1000),  // 14 days from now
    });

    console.log('\n✅ Raise created successfully!');
    console.log('Raise ID:', createResult.raiseId);
    console.log('Max raise is now HIDDEN from contributors');

    // Example 2: Anyone reveals after deadline (automated)
    console.log('\n=== Example 2: Auto-Reveal After Deadline ===\n');

    // Wait for deadline... (in production, run as cron job)
    // await new Promise(resolve => setTimeout(resolve, 14 * 24 * 60 * 60 * 1000));

    // Auto-reveal service kicks in
    // await indexerAutoRevealService(client);
}

// Uncomment to run examples
// main().catch(console.error);

export {
    createRaiseWithSealedCap,
    revealMaxRaise,
    indexerAutoRevealService,
};
