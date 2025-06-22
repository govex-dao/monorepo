import { PrismaClient, Proposal, Dao, Prisma } from '@prisma/client';
import { getFullnodeUrl, SuiClient } from '@mysten/sui/client';
import { Ed25519Keypair } from '@mysten/sui/keypairs/ed25519';
import { Transaction } from '@mysten/sui/transactions';
import express from 'express';
import crypto from 'crypto';
import { readFileSync } from 'fs';

/// We assume our config files are in the format: { "packageId": "0x..." }
const parseConfigurationFile = (fileName: string) => {
	try {
		return JSON.parse(readFileSync(`${fileName}.json`, 'utf8'));
	} catch (e) {
		throw new Error(`Missing config file ${fileName}.json`);
	}
};


// --- Configuration ---
const FUTARCHY_CONTRACT = parseConfigurationFile(`deployments/futarchy-${process.env.NETWORK}`)
const SUI_PRIVATE_KEY = process.env.SUI_PRIVATE_KEY;
const SUI_RPC_URL = process.env.MAINNET_RPC_URL || process.env.TESTNET_RPC_URL || (() => { throw new Error('Neither MAINNET_RPC_URL nor TESTNET_RPC_URL environment variable is set'); })();
const PACKAGE_ID = FUTARCHY_CONTRACT.packageId;
const FEE_MANAGER_ID = FUTARCHY_CONTRACT.feeManagerId;
const POLL_INTERVAL_MS = parseInt(process.env.POLL_INTERVAL_MS || '60000', 10);
const MAX_RETRIES = 3;
const RETRY_DELAY_MS = 5000;
const HEALTH_CHECK_PORT = parseInt(process.env.PORT || process.env.HEALTH_CHECK_PORT || '3001', 10);
const ALERT_WEBHOOK_URL = process.env.ALERT_WEBHOOK_URL; // Discord/Slack webhook URL
const LOCK_TIMEOUT_MS = 30000; // 30 seconds lock timeout
const BOT_INSTANCE_ID = process.env.BOT_INSTANCE_ID || crypto.randomBytes(8).toString('hex');

// --- Setup ---
const prisma = new PrismaClient();
let suiClient: SuiClient;
let keypair: Ed25519Keypair;
let healthCheckServer: any;

// Bot instance identification
console.log(`Bot instance ID: ${BOT_INSTANCE_ID}`);

// Circuit breaker state
interface CircuitBreakerState {
    failures: number;
    lastFailureTime: number;
    state: 'CLOSED' | 'OPEN' | 'HALF_OPEN';
}

const circuitBreaker: CircuitBreakerState = {
    failures: 0,
    lastFailureTime: 0,
    state: 'CLOSED'
};

const CIRCUIT_BREAKER_THRESHOLD = 5;
const CIRCUIT_BREAKER_TIMEOUT = 60000; // 1 minute

// Health check state
let lastSuccessfulPoll = Date.now();
let totalTransactions = 0;
let failedTransactions = 0;
let isHealthy = true;

// --- Helper Functions ---

async function sleep(ms: number) {
    return new Promise(resolve => setTimeout(resolve, ms));
}

// Alert function for critical failures
async function sendAlert(message: string, error?: any) {
    const alertMessage = {
        content: `🚨 **Futarchy Bot Alert**\n${message}${error ? `\n\`\`\`${error.message || error}\`\`\`` : ''}`,
        username: 'Futarchy Bot',
        avatar_url: 'https://avatars.githubusercontent.com/u/158837'
    };

    if (ALERT_WEBHOOK_URL) {
        try {
            await fetch(ALERT_WEBHOOK_URL, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify(alertMessage)
            });
        } catch (err) {
            console.error('Failed to send alert:', err);
        }
    }
    
    console.error(`ALERT: ${message}`, error);
}

// Circuit breaker functions
function isCircuitOpen(): boolean {
    if (circuitBreaker.state === 'OPEN') {
        const timeSinceLastFailure = Date.now() - circuitBreaker.lastFailureTime;
        if (timeSinceLastFailure > CIRCUIT_BREAKER_TIMEOUT) {
            circuitBreaker.state = 'HALF_OPEN';
            console.log('Circuit breaker moving to HALF_OPEN state');
        }
    }
    return circuitBreaker.state === 'OPEN';
}

function recordSuccess() {
    if (circuitBreaker.state === 'HALF_OPEN') {
        circuitBreaker.state = 'CLOSED';
        circuitBreaker.failures = 0;
        console.log('Circuit breaker CLOSED - service recovered');
    }
}

function recordFailure() {
    circuitBreaker.failures++;
    circuitBreaker.lastFailureTime = Date.now();
    
    if (circuitBreaker.failures >= CIRCUIT_BREAKER_THRESHOLD) {
        circuitBreaker.state = 'OPEN';
        console.error('Circuit breaker OPEN - too many failures');
        sendAlert(`Circuit breaker opened after ${circuitBreaker.failures} consecutive failures`);
    }
}

async function initializeSuiClient() {
    if (!SUI_PRIVATE_KEY || !PACKAGE_ID || !FEE_MANAGER_ID) {
        throw new Error("Missing required environment variables: SUI_PRIVATE_KEY, PACKAGE_ID, or FEE_MANAGER_ID");
    }

    try {
        suiClient = new SuiClient({ url: SUI_RPC_URL });
        
        // Decode the full 33-byte key from Base64
        const fullDecodedKey = Buffer.from(SUI_PRIVATE_KEY, 'base64');

        // Slice it to get only the 32-byte secret part (skipping the first byte)
        const secretKey32Bytes = fullDecodedKey.slice(1);

        // Create the keypair from the 32-byte key
        keypair = Ed25519Keypair.fromSecretKey(secretKey32Bytes);
        
        const address = keypair.getPublicKey().toSuiAddress();
        console.log(`Bot initialized with address: ${address}`);
        
        // Check balance
        const balance = await suiClient.getBalance({ owner: address });
        console.log(`Bot balance: ${balance.totalBalance} MIST`);
        
        if (BigInt(balance.totalBalance) < BigInt(100000000)) { // 0.1 SUI
            console.warn('WARNING: Bot balance is low. Please add more SUI for gas fees.');
        }
    } catch (error) {
        console.error('Failed to initialize Sui client:', error);
        throw error;
    }
}

// --- Main Logic ---

// Clean up expired locks before processing
async function cleanupExpiredLocks() {
    const currentTime = BigInt(Date.now());
    try {
        const deleted = await prisma.proposalLock.deleteMany({
            where: {
                expires_at: {
                    lt: currentTime
                }
            }
        });
        if (deleted.count > 0) {
            console.log(`Cleaned up ${deleted.count} expired locks`);
        }
    } catch (error) {
        console.error('Error cleaning up expired locks:', error);
    }
}

// Try to acquire a lock for a proposal
async function acquireLock(proposalId: string): Promise<boolean> {
    const currentTime = BigInt(Date.now());
    const expiresAt = currentTime + BigInt(LOCK_TIMEOUT_MS);
    
    try {
        await prisma.proposalLock.create({
            data: {
                proposal_id: proposalId,
                locked_at: currentTime,
                locked_by: BOT_INSTANCE_ID,
                expires_at: expiresAt
            }
        });
        return true;
    } catch (error: any) {
        // P2002 is Prisma's unique constraint violation error
        if (error.code === 'P2002') {
            // Check if the existing lock is expired
            const existingLock = await prisma.proposalLock.findUnique({
                where: { proposal_id: proposalId }
            });
            
            if (existingLock && existingLock.expires_at < currentTime) {
                // Try to update the expired lock
                try {
                    await prisma.proposalLock.update({
                        where: { proposal_id: proposalId },
                        data: {
                            locked_at: currentTime,
                            locked_by: BOT_INSTANCE_ID,
                            expires_at: expiresAt
                        }
                    });
                    return true;
                } catch {
                    return false;
                }
            }
            return false;
        }
        throw error;
    }
}

// Release a lock after processing
async function releaseLock(proposalId: string) {
    try {
        await prisma.proposalLock.delete({
            where: {
                proposal_id: proposalId,
                locked_by: BOT_INSTANCE_ID
            }
        });
    } catch (error) {
        // Lock might have been cleaned up already, that's okay
        console.log(`Lock already released for proposal ${proposalId}`);
    }
}

async function advanceReviewToTrading() {
    try {
        const currentTime = BigInt(Date.now());
        
        // Clean up expired locks first
        await cleanupExpiredLocks();
        
        // Get locked proposal IDs
        const lockedProposals = await prisma.proposalLock.findMany({
            where: {
                expires_at: { gte: currentTime }
            },
            select: { proposal_id: true }
        });
        const lockedProposalIds = lockedProposals.map(lock => lock.proposal_id);
        
        // Query for proposals in Review state using Prisma's type-safe query
        const proposals = await prisma.proposal.findMany({
            where: {
                current_state: 0,
                created_at: { gt: 0 },
                proposal_id: { notIn: lockedProposalIds }
            },
            include: {
                dao: true
            }
        });

        // Filter proposals that have passed their review period
        const readyProposals = proposals.filter(proposal => 
            proposal.created_at + proposal.review_period_ms <= currentTime
        );

        if (readyProposals.length === 0) {
            console.log('No proposals ready to advance from Review to Trading');
            return;
        }

        console.log(`Found ${readyProposals.length} proposals ready to advance from Review to Trading`);

        for (const proposal of readyProposals) {
            // Type-safe access to dao through the included relation
            if (!proposal.dao) {
                console.error(`No DAO found for proposal ${proposal.proposal_id}`);
                continue;
            }
            
            // Try to acquire lock before processing
            const locked = await acquireLock(proposal.proposal_id);
            if (!locked) {
                console.log(`Proposal ${proposal.proposal_id} is locked by another instance. Skipping.`);
                continue;
            }
            
            try {
                await executeTransaction(proposal, proposal.dao, 'Review->Trading');
            } finally {
                // Always release the lock
                await releaseLock(proposal.proposal_id);
            }
        }
    } catch (error) {
        console.error('Error in advanceReviewToTrading:', error);
    }
}

async function advanceTradingToFinalized() {
    try {
        const currentTime = BigInt(Date.now());
        
        // Clean up expired locks first
        await cleanupExpiredLocks();
        
        // Get locked proposal IDs
        const lockedProposals = await prisma.proposalLock.findMany({
            where: {
                expires_at: { gte: currentTime }
            },
            select: { proposal_id: true }
        });
        const lockedProposalIds = lockedProposals.map(lock => lock.proposal_id);
        
        // Find proposals in Trading state (current_state = 1)
        const proposals = await prisma.proposal.findMany({
            where: {
                current_state: 1,
                created_at: { gt: 0 },
                proposal_id: { notIn: lockedProposalIds }
            },
            include: {
                dao: true,
                state_history: {
                    where: { new_state: 1 },
                    orderBy: { timestamp: 'desc' },
                    take: 1
                }
            }
        });

        // Filter proposals that have completed their trading period
        const readyProposals = proposals.filter(proposal => {
            // Get the trading start time from state history
            const tradingStateChange = proposal.state_history[0];
            if (!tradingStateChange) return false;
            
            const tradingEndTime = tradingStateChange.timestamp + proposal.trading_period_ms;
            return tradingEndTime <= currentTime;
        });

        if (readyProposals.length === 0) {
            console.log('No proposals ready to advance from Trading to Finalized');
            return;
        }

        console.log(`Found ${readyProposals.length} proposals ready to advance from Trading to Finalized`);

        for (const proposal of readyProposals) {
            if (!proposal.dao) {
                console.error(`No DAO found for proposal ${proposal.proposal_id}`);
                continue;
            }
            
            // Try to acquire lock before processing
            const locked = await acquireLock(proposal.proposal_id);
            if (!locked) {
                console.log(`Proposal ${proposal.proposal_id} is locked by another instance. Skipping.`);
                continue;
            }
            
            try {
                await executeTransaction(proposal, proposal.dao, 'Trading->Finalized');
            } finally {
                // Always release the lock
                await releaseLock(proposal.proposal_id);
            }
        }
    } catch (error) {
        console.error('Error in advanceTradingToFinalized:', error);
    }
}

async function executeFinalizedProposals() {
    try {
        // Query for proposals in Finalized state that haven't been executed
        const proposals = await prisma.proposal.findMany({
            where: {
                current_state: 2, // STATE_FINALIZED
                result: null // Not yet executed
            },
            include: {
                dao: true
            }
        });

        if (proposals.length === 0) {
            console.log('No finalized proposals ready for execution');
            return;
        }

        console.log(`Found ${proposals.length} finalized proposals ready for execution`);

        for (const proposal of proposals) {
            if (!proposal.dao) {
                console.error(`No DAO found for proposal ${proposal.proposal_id}`);
                continue;
            }

            // Try to acquire lock before processing
            const locked = await acquireLock(proposal.proposal_id);
            if (!locked) {
                console.log(`Proposal ${proposal.proposal_id} is locked by another instance. Skipping.`);
                continue;
            }

            try {
                await executeProposal(proposal, proposal.dao);
            } finally {
                // Always release the lock
                await releaseLock(proposal.proposal_id);
            }
        }
    } catch (error) {
        console.error('Error in executeFinalizedProposals:', error);
    }
}

async function executeTransaction(proposal: Proposal, dao: Dao, transition: string) {
    // Check circuit breaker
    if (isCircuitOpen()) {
        console.log(`Circuit breaker is OPEN. Skipping transaction for proposal ${proposal.proposal_id}`);
        return;
    }

    let retries = 0;

    while (retries < MAX_RETRIES) {
        try {
            console.log(`[${transition}] Advancing proposal: ${proposal.proposal_id} (attempt ${retries + 1}/${MAX_RETRIES})`);
            
            // Debug logging
            console.log(`[${transition}] Debug info:`, {
                proposalId: proposal.proposal_id,
                escrowId: proposal.escrow_id,
                packageId: PACKAGE_ID,
                feeManagerId: FEE_MANAGER_ID,
                assetType: dao.assetType,
                stableType: dao.stableType,
                daoId: dao.dao_id
            });

            const txb = new Transaction();
            txb.setGasBudget(50000000);

            // First advance the state
            txb.moveCall({
                target: `${PACKAGE_ID}::advance_stage::try_advance_state_entry`,
                typeArguments: ["0x" + dao.assetType, "0x" + dao.stableType],
                arguments: [
                    txb.object(proposal.proposal_id),
                    txb.object(proposal.escrow_id),
                    txb.object(FEE_MANAGER_ID!),
                    txb.object('0x6'), // Clock object
                ],
            });

            // If advancing to Finalized, also execute the proposal in the same transaction
            if (transition === 'Trading->Finalized') {
                console.log(`[${transition}] Adding sign_result_entry to the same transaction`);
                txb.moveCall({
                    target: `${PACKAGE_ID}::dao::sign_result_entry`,
                    typeArguments: ["0x" + dao.assetType, "0x" + dao.stableType],
                    arguments: [
                        txb.object(dao.dao_id),
                        txb.pure.id(proposal.proposal_id),
                        txb.object(proposal.escrow_id),
                        txb.object('0x6'), // Clock object
                    ],
                });
            }

            // Execute the transaction
            const result = await suiClient.signAndExecuteTransaction({
                signer: keypair,
                transaction: txb,
                options: {
                    showEffects: true,
                    showEvents: true,
                }
            });

            // Wait for transaction confirmation
            await suiClient.waitForTransaction({
                digest: result.digest,
                options: {
                    showEffects: true,
                }
            });

            console.log(`[${transition}] Transaction successful for proposal ${proposal.proposal_id}:`, result.digest);
            
            // Log any events
            if (result.events && result.events.length > 0) {
                console.log(`[${transition}] Events emitted:`, result.events.map(e => e.type));
            }

            // Record success for circuit breaker and metrics
            recordSuccess();
            totalTransactions++;
            lastSuccessfulPoll = Date.now();

            break; // Success, exit retry loop

        } catch (error: any) {
            retries++;
            failedTransactions++;
            console.error(`[${transition}] Failed to advance proposal ${proposal.proposal_id} (attempt ${retries}/${MAX_RETRIES}):`, error.message);
            
            if (error.message?.includes('already in the correct state') || 
                error.message?.includes('not ready to advance')) {
                console.log(`[${transition}] Proposal ${proposal.proposal_id} cannot be advanced yet. Skipping.`);
                break; // Don't retry for logical errors
            }

            // Record failure for circuit breaker
            recordFailure();

            if (retries >= MAX_RETRIES) {
                await sendAlert(
                    `Failed to advance proposal ${proposal.proposal_id} after ${MAX_RETRIES} attempts`,
                    error
                );
            } else if (retries < MAX_RETRIES) {
                console.log(`Retrying in ${RETRY_DELAY_MS}ms...`);
                await sleep(RETRY_DELAY_MS);
            }
        }
    }
}

async function executeProposal(proposal: Proposal, dao: Dao) {
    // Check circuit breaker
    if (isCircuitOpen()) {
        console.log(`Circuit breaker is OPEN. Skipping execution for proposal ${proposal.proposal_id}`);
        return;
    }

    let retries = 0;

    while (retries < MAX_RETRIES) {
        try {
            console.log(`[Execute] Executing proposal: ${proposal.proposal_id} (attempt ${retries + 1}/${MAX_RETRIES})`);

            const txb = new Transaction();
            txb.setGasBudget(50000000);

            // Execute the proposal
            txb.moveCall({
                target: `${PACKAGE_ID}::dao::sign_result_entry`,
                typeArguments: ["0x" + dao.assetType, "0x" + dao.stableType],
                arguments: [
                    txb.object(dao.dao_id),
                    txb.pure.id(proposal.proposal_id),
                    txb.object(proposal.escrow_id),
                    txb.object('0x6'), // Clock object
                ],
            });

            const result = await suiClient.signAndExecuteTransaction({
                signer: keypair,
                transaction: txb,
                options: {
                    showEffects: true,
                    showEvents: true,
                }
            });

            // Wait for transaction confirmation
            await suiClient.waitForTransaction({
                digest: result.digest,
                options: {
                    showEffects: true,
                }
            });

            console.log(`[Execute] Transaction successful for proposal ${proposal.proposal_id}:`, result.digest);
            
            // Log any events
            if (result.events && result.events.length > 0) {
                console.log(`[Execute] Events emitted:`, result.events.map(e => e.type));
            }

            // Record success for circuit breaker and metrics
            recordSuccess();
            totalTransactions++;
            lastSuccessfulPoll = Date.now();

            break; // Success, exit retry loop

        } catch (error: any) {
            retries++;
            failedTransactions++;
            console.error(`[Execute] Failed to execute proposal ${proposal.proposal_id} (attempt ${retries}/${MAX_RETRIES}):`, error.message);
            
            if (error.message?.includes('already executed') || 
                error.message?.includes('EALREADY_EXECUTED')) {
                console.log(`[Execute] Proposal ${proposal.proposal_id} was already executed. Skipping.`);
                break; // Don't retry for already executed proposals
            }

            // Record failure for circuit breaker
            recordFailure();

            if (retries >= MAX_RETRIES) {
                await sendAlert(
                    `Failed to execute proposal ${proposal.proposal_id} after ${MAX_RETRIES} attempts`,
                    error
                );
            } else if (retries < MAX_RETRIES) {
                console.log(`Retrying in ${RETRY_DELAY_MS}ms...`);
                await sleep(RETRY_DELAY_MS);
            }
        }
    }
}

async function poll() {
    console.log(`\n--- Polling at ${new Date().toISOString()} ---`);
    
    try {
        await advanceReviewToTrading();
        await advanceTradingToFinalized();
        await executeFinalizedProposals();
        isHealthy = true;
    } catch (error) {
        console.error('Error during polling cycle:', error);
        isHealthy = false;
        await sendAlert('Polling cycle failed', error);
    }
    
    console.log('--- Polling complete ---\n');
}

// Health check endpoint
function startHealthCheckServer() {
    const app = express();
    
    app.get('/health', (req, res) => {
        const timeSinceLastSuccess = Date.now() - lastSuccessfulPoll;
        const healthStatus = {
            status: isHealthy && timeSinceLastSuccess < POLL_INTERVAL_MS * 2 ? 'healthy' : 'unhealthy',
            lastSuccessfulPoll: new Date(lastSuccessfulPoll).toISOString(),
            timeSinceLastSuccess: timeSinceLastSuccess,
            totalTransactions,
            failedTransactions,
            circuitBreakerState: circuitBreaker.state,
            uptime: process.uptime(),
            botInstanceId: BOT_INSTANCE_ID
        };
        
        res.status(healthStatus.status === 'healthy' ? 200 : 503).json(healthStatus);
    });
    
    app.get('/metrics', (req, res) => {
        res.json({
            totalTransactions,
            failedTransactions,
            successRate: totalTransactions > 0 ? 
                ((totalTransactions - failedTransactions) / totalTransactions * 100).toFixed(2) + '%' : 
                'N/A',
            circuitBreaker: {
                state: circuitBreaker.state,
                failures: circuitBreaker.failures,
                lastFailureTime: circuitBreaker.lastFailureTime ? 
                    new Date(circuitBreaker.lastFailureTime).toISOString() : 
                    null
            }
        });
    });
    
    const server = app.listen(HEALTH_CHECK_PORT, () => {
        console.log(`Health check server running on port ${HEALTH_CHECK_PORT}`);
    });
    
    return server;
}

async function gracefulShutdown() {
    console.log('\nShutting down gracefully...');
    
    // Close health check server
    if (healthCheckServer) {
        await new Promise<void>((resolve) => {
            healthCheckServer.close(() => {
                console.log('Health check server closed.');
                resolve();
            });
        });
    }
    
    // Clean up any locks held by this instance
    try {
        const deleted = await prisma.proposalLock.deleteMany({
            where: {
                locked_by: BOT_INSTANCE_ID
            }
        });
        if (deleted.count > 0) {
            console.log(`Released ${deleted.count} locks held by this instance`);
        }
    } catch (error) {
        console.error('Error releasing locks during shutdown:', error);
    }
    
    await prisma.$disconnect();
    process.exit(0);
}

// --- Start the Bot ---
async function main() {
    console.log("Starting Futarchy Proposal Advancement Bot...");
    console.log(`Poll interval: ${POLL_INTERVAL_MS}ms`);
    console.log(`Environment: ${process.env.NODE_ENV || 'development'}`);
    console.log(`RPC URL: ${SUI_RPC_URL}`);
    console.log(`Health check port: ${HEALTH_CHECK_PORT}`);
    console.log(`Alerts: ${ALERT_WEBHOOK_URL ? 'Enabled' : 'Disabled'}`);
    console.log(`Bot instance ID: ${BOT_INSTANCE_ID}`);

    // Initialize Sui client and check configuration
    await initializeSuiClient();
    
    // Start health check server
    healthCheckServer = startHealthCheckServer();

    // Register shutdown handlers
    process.on('SIGINT', gracefulShutdown);
    process.on('SIGTERM', gracefulShutdown);

    // Initial run
    await poll();

    // Set up interval for continuous polling
    setInterval(poll, POLL_INTERVAL_MS);

    console.log('Bot is running. Press Ctrl+C to stop.');
}

// Error handling for uncaught exceptions
process.on('uncaughtException', (error) => {
    console.error('Uncaught Exception:', error);
    process.exit(1);
});

process.on('unhandledRejection', (reason, promise) => {
    console.error('Unhandled Rejection at:', promise, 'reason:', reason);
    process.exit(1);
});

// Start the bot
main().catch((error) => {
    console.error('Fatal error:', error);
    process.exit(1);
});
