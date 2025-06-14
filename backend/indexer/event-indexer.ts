import { EventId, SuiClient, SuiEvent, SuiEventFilter } from '@mysten/sui/client';
import { CONFIG } from '../config';
import { prisma } from '../db';
import { getClient } from '../sui-utils';
import { handleProposalObjects } from './proposal-handler';
import { handleDAOObjects } from './dao-handler';
import { handleSwapEvents } from './swap-handler';
import { handleProposalStateChanges } from './state-handler';
import { handleVerificationRequests } from './verification-request-handler';
import { handleVerifications } from './verification-handler';
import { handleProposalResults } from './results-handler';

// Configuration
const INDEXER_CONFIG = {
    BATCH_SIZE: 50,
    DELAY_BETWEEN_REQUESTS: 500, // 1 second between requests
    DELAY_BETWEEN_EVENT_TYPES: 1000, // 5 seconds before switching to next event type
};

type EventTracker = {
    type: string;
    filter: SuiEventFilter;
    callback: (events: SuiEvent[], type: string) => Promise<void>;
};

// Event configuration
const EVENTS_TO_TRACK: EventTracker[] = [
    {
        type: `${CONFIG.FUTARCHY_CONTRACT.packageId}::proposal::ProposalCreated`,
        filter: {
            MoveEventModule: {
                module: 'proposal',
                package: CONFIG.FUTARCHY_CONTRACT.packageId,
            },
        },
        callback: handleProposalObjects,
    },
    {
        type: `${CONFIG.FUTARCHY_CONTRACT.packageId}::dao::DAOCreated`,
        filter: {
            MoveEventModule: {
                module: 'dao',
                package: CONFIG.FUTARCHY_CONTRACT.packageId,
            },
        },
        callback: handleDAOObjects,
    },
    {
        type: `${CONFIG.FUTARCHY_CONTRACT.packageId}::dao::ResultSigned`,
        filter: {
            MoveEventModule: {
                module: 'dao',
                package: CONFIG.FUTARCHY_CONTRACT.packageId,
            },
        },
        callback: handleProposalResults,
    },
    {
        type: `${CONFIG.FUTARCHY_CONTRACT.packageId}::amm::SwapEvent`,
        filter: {
            MoveEventModule: {
                module: 'amm',
                package: CONFIG.FUTARCHY_CONTRACT.packageId,
            },
        },
        callback: handleSwapEvents,
    },
    {
        type: `${CONFIG.FUTARCHY_CONTRACT.packageId}::advance_stage::ProposalStateChanged`,
        filter: {
            MoveEventModule: {
                module: 'advance_stage',
                package: CONFIG.FUTARCHY_CONTRACT.packageId,
            },
        },
        callback: handleProposalStateChanges,
    },
    {
        type: `${CONFIG.FUTARCHY_CONTRACT.packageId}::factory::VerificationRequested`,
        filter: {
            MoveEventModule: {
                module: 'factory',
                package: CONFIG.FUTARCHY_CONTRACT.packageId,
            },
        },
        callback: handleVerificationRequests,
    },
    {
        type: `${CONFIG.FUTARCHY_CONTRACT.packageId}::factory::DAOReviewed`,
        filter: {
            MoveEventModule: {
                module: 'factory',
                package: CONFIG.FUTARCHY_CONTRACT.packageId,
            },
        },
        callback: handleVerifications,
    }
];

class SequentialEventProcessor {
    private isRunning = false;
    private currentTrackerIndex = 0;

    constructor(
        private readonly client: SuiClient,
        private readonly trackers: EventTracker[]
    ) {}

    private async delay(ms: number): Promise<void> {
        await new Promise(resolve => setTimeout(resolve, ms));
    }

    private async getLatestCursor(tracker: EventTracker): Promise<EventId | undefined> {
        const cursor = await prisma.cursor.findUnique({
            where: { id: tracker.type }
        });
        return cursor ? { eventSeq: cursor.eventSeq, txDigest: cursor.txDigest } : undefined;
    }

    private async saveLatestCursor(tracker: EventTracker, cursor: EventId): Promise<void> {
        await prisma.cursor.upsert({
            where: { id: tracker.type },
            update: {
                eventSeq: cursor.eventSeq,
                txDigest: cursor.txDigest,
            },
            create: {
                id: tracker.type,
                eventSeq: cursor.eventSeq,
                txDigest: cursor.txDigest,
            },
        });
    }

    private async processEventType(tracker: EventTracker): Promise<void> {
        try {
            console.log(`Processing events for ${tracker.type}`);
            let cursor = await this.getLatestCursor(tracker);
            let hasMore = true;

            while (hasMore && this.isRunning) {
                try {
                    const response = await this.client.queryEvents({
                        query: tracker.filter,
                        cursor,
                        order: 'ascending',
                        limit: INDEXER_CONFIG.BATCH_SIZE,
                    });

                    if (response.data.length > 0) {
                        console.log(`Found ${response.data.length} events for ${tracker.type}`);
                        await tracker.callback(response.data, tracker.type);
                        
                        if (response.nextCursor) {
                            await this.saveLatestCursor(tracker, response.nextCursor);
                            cursor = response.nextCursor;
                        }
                    }

                    hasMore = response.hasNextPage;
                    
                    // Always wait between requests, even if no events found
                    await this.delay(INDEXER_CONFIG.DELAY_BETWEEN_REQUESTS);

                } catch (error) {
                    console.error(`Error processing ${tracker.type}:`, error);
                    hasMore = false;
                }
            }

            console.log(`Completed processing for ${tracker.type}`);

        } catch (error) {
            console.error(`Failed to process event type ${tracker.type}:`, error);
        }
    }

    private async processNextEventType(): Promise<void> {
        if (!this.isRunning) return;

        const tracker = this.trackers[this.currentTrackerIndex];
        await this.processEventType(tracker);

        // Move to next tracker
        this.currentTrackerIndex = (this.currentTrackerIndex + 1) % this.trackers.length;
        
        // Delay before starting next event type
        await this.delay(INDEXER_CONFIG.DELAY_BETWEEN_EVENT_TYPES);
        
        // Schedule next event type
        if (this.isRunning) {
            this.processNextEventType();
        }
    }

    public async start(): Promise<void> {
        if (this.isRunning) {
            console.log('Processor is already running');
            return;
        }

        console.log('Starting sequential event processor...');
        this.isRunning = true;
        await this.processNextEventType();
    }

    public async stop(): Promise<void> {
        console.log('Stopping event processor...');
        this.isRunning = false;
    }
}

export const setupListeners = async () => {
    const processor = new SequentialEventProcessor(
        getClient(CONFIG.NETWORK),
        EVENTS_TO_TRACK
    );

    // Handle shutdown gracefully
    process.on('SIGINT', async () => {
        console.log('Received shutdown signal');
        await processor.stop();
        await prisma.$disconnect();
        process.exit(0);
    });

    process.on('SIGTERM', async () => {
        console.log('Received shutdown signal');
        await processor.stop();
        await prisma.$disconnect();
        process.exit(0);
    });

    await processor.start();
};