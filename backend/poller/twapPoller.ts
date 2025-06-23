import { SuiClient, DevInspectResults } from '@mysten/sui/client';
import { Transaction } from '@mysten/sui/transactions';
import { bcs } from '@mysten/sui/bcs';
import { CONFIG } from '../config';
import { prisma } from '../db';
import { getClient, getActiveAddress } from '../sui-utils'; // Ensure getActiveAddress is exported from sui-utils

// Configuration constants
const POLLING_INTERVAL_MS = 30 * 60 * 1000; // 30 minutes
const PROPOSAL_POLL_GAP_MS = 10 * 1000; // 10 seconds between proposals
const TARGET_STATE = 1; // Only poll proposals in state 1

interface TWAPConfig {
  packageId: string;
  oracleModule: string; // module containing TWAP functions (e.g. "oracle")
  clockObjectId: string;
}

class TWAPPoller {
  private client: SuiClient;
  private config: TWAPConfig;

  constructor(config: TWAPConfig) {
    this.client = getClient(CONFIG.NETWORK);
    this.config = config;
  }

  /**
   * Constructs a transaction block that calls a Move function to get TWAP values
   * for all outcomes in a given proposal.
   *
   * @param proposalId - The Sui object ID for the proposal.
   * @param assetType - The asset type string.
   * @param stableType - The stable type string.
   * @returns The result from devInspectTransactionBlock or null on error.
   */
  private async fetchTWAPs(
    proposalId: string,
    assetType: string,
    stableType: string
  ): Promise<DevInspectResults | null> {
    try {
      const txb = new Transaction();
      txb.setGasBudget(50000000);

      console.log(
        'Fetching TWAPs for proposal',
        proposalId,
        'using package',
        this.config.packageId
      );

      txb.moveCall({
        target: `${this.config.packageId}::proposal::get_twaps_for_proposal`,
        typeArguments: [assetType, stableType],
        arguments: [
          txb.object(proposalId),
          txb.object(this.config.clockObjectId)
        ]
      });

      // Use the active sender rather than a dummy sender
      const sender = getActiveAddress();
      const result = (await this.client.devInspectTransactionBlock({
        transactionBlock: txb,
        sender
      })) as unknown as DevInspectResults;

      console.log(
        `TWAPs response for proposal ${proposalId}:`,
        JSON.stringify(result, null, 2)
      );
      return result;
    } catch (error) {
      console.error(`Error fetching TWAPs for proposal ${proposalId}:`, error);
      return null;
    }
  }

  /**
   * Upserts the TWAP value into the database.
   *
   * @param proposalId - The proposal identifier.
   * @param outcome - The outcome index.
   * @param oracleId - The oracle identifier.
   * @param twap - The TWAP value.
   */
  private async updateTWAP(
    proposalId: string,
    outcome: number,
    oracleId: string,
    twap: bigint
  ): Promise<void> {
    try {
      const timestamp = BigInt(Date.now());
      await prisma.proposalTWAP.upsert({
        where: { 
          proposalId_outcome: { proposalId, outcome }
        },
        update: { 
          twap,
          timestamp 
        },
        create: {
          proposalId,
          outcome,
          twap,
          timestamp,
          oracle_id: oracleId
        }
      });
      console.log(
        `Updated TWAP for proposal ${proposalId} outcome ${outcome}: ${twap.toString()}`
      );
    } catch (error) {
      console.error('Error updating TWAP in database:', error);
    }
  }

  /**
   * Polls a single proposal for TWAP updates across all outcomes.
   *
   * @param proposalId - The proposal's ID.
   * @param outcomeCount - The number of outcomes.
   * @param oracleIds - An array of oracle IDs corresponding to each outcome.
   * @param assetType - The asset type string.
   * @param stableType - The stable type string.
   */
  private async pollProposal(
    proposalId: string,
    outcomeCount: number,
    oracleIds: string[],
    assetType: string,
    stableType: string
  ): Promise<void> {
    const twapResponse = await this.fetchTWAPs(
      proposalId,
      assetType,
      stableType
    );
    if (!twapResponse) return;

    const results = twapResponse.results;
    if (!results || results.length === 0) {
      console.error(`No results returned for proposal ${proposalId}`);
      return;
    }
    const returnValues = results[0].returnValues;
    if (!returnValues || returnValues.length === 0) {
      console.error(`No return values found for proposal ${proposalId}`);
      return;
    }

    // Expect the first tuple element to be [dataBytes, typeString]
    const [dataBytes, typeStr] = returnValues[0];
    const bytes = new Uint8Array(dataBytes);

    console.log(`Raw bytes received for proposal ${proposalId}:`, Array.from(bytes));
    console.log(`Type string received:`, typeStr);
    const decodedTwapsRaw = bcs.vector(bcs.u128()).parse(bytes);
    // Ensure conversion from string values to bigint, if needed.
    const decodedTwaps: bigint[] = (decodedTwapsRaw as string[]).map(v => BigInt(v));
    console.log(`Converted TWAPs to bigint for proposal ${proposalId}:`, decodedTwaps.map(v => v.toString()));

    for (let outcome = 0; outcome < outcomeCount; outcome++) {
      const twapValue = decodedTwaps[outcome];
      if (twapValue === undefined) {
        console.error(`Missing TWAP value for proposal ${proposalId} outcome ${outcome}`);
        continue;
      }
      const oracleId = oracleIds[outcome] || "unknown";
      await this.updateTWAP(proposalId, outcome, oracleId, twapValue);
    }
  }

  /**
   * Retrieves active proposals from the database.
   *
   * @returns An array of proposals with TWAP history and asset/stable type info.
   */
  private async getActiveProposals(): Promise<
    Array<{
      proposal_id: string;
      outcome_count: bigint;
      asset_type: string;
      stable_type: string;
      twapHistory: Array<{ oracle_id: string }>;
    }>
  > {
    return await prisma.proposal.findMany({
      where: { 
        current_state: TARGET_STATE,
        dao: { isNot: null }
      },
      select: {
        proposal_id: true,
        outcome_count: true,
        asset_type: true,
        stable_type: true,
        twapHistory: {
          select: { oracle_id: true }
        }
      }
    });
  }

  /**
   * Iterates over active proposals and polls each for TWAP values.
   */
  public async pollTWAPs(): Promise<void> {
    try {
      const activeProposals = await this.getActiveProposals();
      console.log(`Found ${activeProposals.length} active proposals to poll`);

      for (const proposal of activeProposals) {
        const oracleIds = proposal.twapHistory.map(tw => tw.oracle_id);
        await this.pollProposal(
          proposal.proposal_id,
          Number(proposal.outcome_count),
          oracleIds,
          proposal.asset_type,
          proposal.stable_type
        );
        // Pause between proposals to manage rate limits.
        await new Promise(resolve => setTimeout(resolve, PROPOSAL_POLL_GAP_MS));
      }
    } catch (error) {
      console.error('Error in TWAP polling cycle:', error);
    }
  }

  /**
   * Starts the polling service. In devnet mode a single poll is executed.
   * Otherwise, recurring polls are scheduled.
   */
  public startPolling(): void {
    console.log('Starting TWAP polling service...');

    if (CONFIG.NETWORK === 'devnet') {
      console.log('Devnet mode: executing a single TWAP poll.');
      this.pollTWAPs().catch(console.error);
    } else {
      // Execute initial poll.
      this.pollTWAPs().catch(console.error);
      // Schedule recurring polls.
      setInterval(() => {
        this.pollTWAPs().catch(console.error);
      }, POLLING_INTERVAL_MS);
    }
  }
}

// Create and export the poller instance.
export const twapPoller = new TWAPPoller({
  packageId: CONFIG.FUTARCHY_CONTRACT.packageId,
  oracleModule: 'oracle',
  clockObjectId: '0x6' // Ensure this matches your configuration.
});

export { TWAPPoller };
