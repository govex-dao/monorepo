// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

import cors from 'cors';
import express from 'express';
import fs from 'fs/promises';
import path from 'path';
import { processAndGetBase64Icon } from './imageUtils';


import { prisma } from './db';
import {
	formatPaginatedResponse,
	parsePaginationForQuery,
	parseWhereStatement,
	WhereParam,
	WhereParamTypes,
} from './utils/api-queries';
import { swapCache, SWAP_CACHE_TTL, cleanupExpiredCache, getCacheStats } from './cache-utils';

// Clean up expired cache entries every minute
setInterval(() => {
    cleanupExpiredCache();
}, 10000); 

const app = express();
app.use(cors());

app.use(express.json());

app.get('/', async (req, res) => {
	res.send({ message: '🚀 API is functional 🚀' });
});

app.get('/cache-stats', async (req, res) => {
	const stats = getCacheStats();
	res.send({
		cache: {
			swap: stats
		}
	});
});

function serializeAllBigInts(obj: any): any {  
    if (typeof obj === 'bigint') {
      return obj.toString();
    }
    
    if (Array.isArray(obj)) {
      return obj.map(serializeAllBigInts);
    }
    
    if (obj && typeof obj === 'object') {
      return Object.fromEntries(
        Object.entries(obj).map(([k, v]) => [k, serializeAllBigInts(v)])
      );
    }
    
    return obj;
  }
  

app.get('/dao/:daoId/verification-requests', async (req, res) => {
    try {
        const { daoId } = req.params;

        const requests = await prisma.daoVerificationRequest.findMany({
            where: {
                dao_id: daoId
            },
            select: {
                attestation_url: true,
                timestamp: true,
                status: true,
                verification_id: true,
                dao: {
                    select: {
                        verification: {
                            select: {
                                reject_reason: true
                            }
                        }
                    }
                }
            },
            orderBy: {
                timestamp: 'desc'
            }
        });

        // Transform the data to handle BigInt and include reject reason when status is 'rejected'
        const transformedRequests = requests.map(request => ({
            attestation_url: request.attestation_url,
            timestamp: request.timestamp.toString(),
            status: request.status,
            verification_id: request.verification_id,
            reject_reason: request.status === 'rejected' ? 
                request.dao?.verification?.reject_reason || null : 
                null
        }));

        res.json(transformedRequests);
        
    } catch (e) {
        console.error('Error fetching verification requests:', e);
        res.status(500).json({
            error: e instanceof Error ? e.message : 'Unknown error'
        });
    }
});

app.get('/daos', async (req, res) => {
    console.log('Received DAO search request:', req.query);
    const { dao_id } = req.query;

    try {
        const daos = await prisma.dao.findMany({
            where: {
                OR: [
                    {
                        dao_id: {
                            contains: dao_id as string,
                        }
                    },
                    {
                        dao_name: {
                            contains: dao_id as string,
                        }
                    }
                ]
            },
            select: {
                id: true,
                dao_id: true,
                minAssetAmount: true,
                minStableAmount: true,
                timestamp: true,
                assetType: true,
                stableType: true,
                dao_name: true,
                icon_url: true,
                icon_cache_path: true,
                review_period_ms: true, 
                trading_period_ms: true,
                asset_decimals: true,
                stable_decimals: true,
                asset_name: true,
                stable_name: true,
                asset_icon_url: true,
                stable_icon_url: true,
                asset_symbol: true,
                stable_symbol: true,
                description:true,
                amm_twap_initial_observation: true,
                amm_twap_start_delay: true,
                amm_twap_step_max: true,
                twap_threshold:true,
                verificationRequests: true,
                verification: {
                        select: {
                            verified: true
                        }
                    }
            },
            orderBy: [
                {
                    dao_name: 'asc'
                },
                {
                    id: 'desc'
                }
            ],
            take: 10
        });


               
        // Convert BigInt values to strings, add base64 icons, and format the response
        const serializedDaos = await Promise.all(daos.map(async dao => {

            return {
            ...dao,
            dao_icon: await processAndGetBase64Icon(dao.icon_cache_path, dao.dao_id),
            minAssetAmount: dao.minAssetAmount.toString(),
            minStableAmount: dao.minStableAmount.toString(),
            timestamp: dao.timestamp.toString(),
            review_period_ms: dao.review_period_ms.toString(),
            trading_period_ms: dao.trading_period_ms.toString(),
            amm_twap_initial_observation: dao.amm_twap_initial_observation.toString(),
            amm_twap_start_delay: dao.amm_twap_start_delay.toString(),
            amm_twap_step_max: dao.amm_twap_step_max.toString(),
            twap_threshold: dao.twap_threshold.toString(),
            };
        }));

        // Sort results to prioritize name matches
        const searchTerm = (dao_id as string).toLowerCase();
        const sortedDaos = serializedDaos.sort((a, b) => {
            const aNameMatch = a.dao_name.toLowerCase().includes(searchTerm);
            const bNameMatch = b.dao_name.toLowerCase().includes(searchTerm);
            
            // Prioritize name matches
            if (aNameMatch && !bNameMatch) return -1;
            if (!aNameMatch && bNameMatch) return 1;
            
            return 0;
        });

        res.json({ 
            data: sortedDaos,
            pagination: {
                hasMore: false
            }
        });
    } catch (e) {
        console.error('DAO search error:', e);
        res.status(400).json({
            error: e instanceof Error ? e.message : 'Unknown error'
        });
    }
});

app.get('/dao/:daoId/proposals', async (req, res) => {
    try {
        const { daoId } = req.params;
        const proposals = await prisma.proposal.findMany({
            where: {
                dao_id: daoId
            },
            include: {
                state_history: {
                    orderBy: {
                        timestamp: 'desc'
                    }
                },
                dao: {
                    select: {
                        dao_name: true,
                        icon_url: true,
                        icon_cache_path: true,
                        assetType: true,
                        stableType: true
                    }
                }
            },
            orderBy: {
                created_at: 'desc'
            }
        });

        const transformedProposals = await Promise.all(proposals.map(async proposal => {

            return {
                id: proposal.id,
                proposal_id: proposal.proposal_id,
                dao_id: proposal.dao_id,
                dao_name: proposal.dao?.dao_name,
                dao_icon: await processAndGetBase64Icon(proposal.dao?.icon_cache_path || null, proposal.dao_id),
                asset_type: proposal.dao?.assetType,
                stable_type: proposal.dao?.stableType,
                proposer: proposal.proposer,
                title: proposal.title,
                created_at: proposal.created_at.toString(),
                state_history_count: proposal.state_history?.length || 0,
                current_state: proposal.current_state,
                market_state_id: proposal.market_state_id,
                asset_value: proposal.asset_value.toString(),
                stable_value: proposal.stable_value.toString(),
            };
        }));

        res.json(formatPaginatedResponse(transformedProposals));
    } catch (e) {
        console.error('Error fetching DAO proposals:', e);
        res.status(500).json({
            error: e instanceof Error ? e.message : 'Unknown error'
        });
    }
});

app.get('/search', async (req, res) => {
    console.log('Received search request:', req.query);
    const { query } = req.query;

    if (!query) {
        res.json({ data: [] });
    }

    try {
        // Search DAOs
        const daos = await prisma.dao.findMany({
            where: {
                OR: [
                    {
                        dao_name: {
                            contains: query as string,
                        }
                    },
                    {
                        dao_id: {
                            contains: query as string,
                        }
                    }
                ]
            },
            select: {
                id: true,
                dao_id: true,
                dao_name: true,
                icon_url: true,
                icon_cache_path: true,
                verification: {
                    select: {
                        verified: true
                    }
                }
            },
            take: 5
        });

        // Process DAOs with icon handling
        const processedDaos = await Promise.all(daos.map(async dao => {

            return {
                type: 'dao',
                ...dao,
                dao_icon: await processAndGetBase64Icon(dao.icon_cache_path, dao.dao_id)
            };
        }));

        // Search Proposals
        const proposals = await prisma.proposal.findMany({
            where: {
                title: {
                    contains: query as string,
                }
            },
            select: {
                id: true,
                proposal_id: true,
                market_state_id: true,
                title: true,
                dao: {
                    select: {
                        dao_id: true,
                        dao_name: true,
                        icon_cache_path: true,
                        verification: {
                            select: { verified: true }
                        }
                    }
                }
            },
            take: 5
        });

        // Format and combine results
        const formattedResults = {
            daos: processedDaos,
            proposals: await Promise.all(proposals.map(async proposal => ({
                type: 'proposal',
                ...proposal,
                dao: proposal.dao ? {
                    ...proposal.dao,
                    dao_icon: await processAndGetBase64Icon(
                        proposal.dao.icon_cache_path || null, 
                        proposal.dao.dao_id
                    )
                } : null
            }))),  // Added missing comma here
        };
        

        res.json({ data: formattedResults });
    } catch (e) {
        console.error('Search error:', e);
        res.status(400).json({
            error: e instanceof Error ? e.message : 'Unknown error'
        });
    }
});


app.get('/proposals/search', async (req, res) => {
    try {
        const { proposal_id, market_state_id } = req.query;

        if (!proposal_id && !market_state_id) {
            res.status(400).send({ 
                message: 'Either proposal_id or market_state_id must be provided' 
            });
            return;
        }

        // Build the where clause based on provided parameters
        const where: any = {};
        if (proposal_id) {
            where.proposal_id = proposal_id as string;
        } else if (market_state_id) {
            where.market_state_id = market_state_id as string;
        }

        const proposal = await prisma.proposal.findUnique({
            where,
            include: {
                state_history: {
                    orderBy: {
                        timestamp: 'desc'
                    }
                }
            }
        });

        if (!proposal) {
            res.status(404).send({ 
                message: 'Proposal not found' 
            });
            return;
        }

        res.send(proposal);
    } catch (e) {
        console.error('Error searching proposals:', e);
        res.status(500).send({ 
            message: 'Internal server error',
            error: e 
        });
    }
});


app.get('/proposals', async (req, res) => {
    try {
        const proposals = await prisma.proposal.findMany({
            include: {
                state_history: {
                    orderBy: {
                        timestamp: 'desc'
                    }
                },
                dao: {
                    select: {
                        dao_name: true,
                        icon_url: true,
                        icon_cache_path: true,
                        assetType: true,
                        stableType: true,
                        verification: {
                            select: {
                                verified: true
                            }
                        }
                    }
                }
            },
            orderBy: {
                created_at: 'desc'
            }
        });

        // Transform the data to include the count of state changes and DAO information
        const transformedProposals = await Promise.all(proposals.map(async proposal => {

            return {
                id: proposal.id,
                proposal_id: proposal.proposal_id,
                dao_id: proposal.dao_id,
                dao_name: proposal.dao?.dao_name,
                dao_icon: await processAndGetBase64Icon(proposal.dao?.icon_cache_path || null, proposal.dao_id),
                asset_type: proposal.dao?.assetType,
                stable_type: proposal.dao?.stableType,
                proposer: proposal.proposer,
                title: proposal.title,
                created_at: proposal.created_at.toString(),
                state_history_count: proposal.state_history?.length || 0,
                current_state: proposal.current_state,
                market_state_id: proposal.market_state_id,
                asset_value: proposal.asset_value.toString(),
                stable_value: proposal.stable_value.toString(),
                dao_verified: proposal.dao?.verification?.verified || false,
            };
        }));

        res.send(formatPaginatedResponse(transformedProposals));
    } catch (e) {
        console.error('Error fetching proposals:', e);
        res.status(500).send({ 
            message: 'Internal server error',
            error: e instanceof Error ? e.message : 'Unknown error'
        });
    }
});


app.get('/proposals/:id', async (req, res) => {
    try {
      // First, try to find by proposal_id
      let proposal = await prisma.proposal.findUnique({
        where: {
          proposal_id: req.params.id
        },
        include: {
          state_history: {
            distinct: ['new_state'],
            orderBy: [{ new_state: 'desc' }],
            select: {
              new_state: true,
              timestamp: true
            }
          },
          dao: {
            select: {
              dao_name: true,
              icon_url: true,
              icon_cache_path: true,
              assetType: true,
              stableType: true,
              minAssetAmount: true,
              minStableAmount: true,
              asset_symbol: true,
              stable_symbol: true,
              asset_decimals: true,  
              stable_decimals: true, 
              verification: {
                select: {
                  verified: true
                }
              }
            }
          },
          twapHistory: {
            orderBy: { outcome: 'asc' }
          },
          result: {
            select: {
              winning_outcome: true
            }
          }
        }
      });
  
      // If not found, try using market_state_id
      if (!proposal) {
        proposal = await prisma.proposal.findUnique({
          where: {
            market_state_id: req.params.id
          },
          include: {
            state_history: {
              distinct: ['new_state'],
              orderBy: [{ new_state: 'desc' }],
              select: {
                new_state: true,
                timestamp: true
              }
            },
            dao: {
              select: {
                dao_name: true,
                icon_url: true,
                icon_cache_path: true,
                assetType: true,
                stableType: true,
                minAssetAmount: true,
                minStableAmount: true,
                asset_symbol: true,
                stable_symbol: true,
                asset_decimals: true, 
                stable_decimals: true,
                verification: {
                  select: {
                    verified: true
                  }
                }
              }
            },
            twapHistory: {
              orderBy: { outcome: 'asc' }
            },
            result: {
              select: {
                winning_outcome: true
              }
            }
          }
        });
      }
  
      if (!proposal) {
        res.status(404).send({ message: 'Proposal not found' });
        return;
      }
  
      // Helper function to serialize BigInt values
      const serializeBigInt = (value: any): any =>
        typeof value === 'bigint' ? value.toString() : value;
  
      // Build the transformed proposal,
      // manually converting necessary fields to ensure JSON compatibility.
      const transformedProposal: any = {
          ...proposal,
          dao: proposal.dao
            ? {
                ...proposal.dao,
                minAssetAmount: serializeBigInt(proposal.dao.minAssetAmount),
                minStableAmount: serializeBigInt(proposal.dao.minStableAmount)
              }
            : null,
          dao_icon: await processAndGetBase64Icon(
            proposal.dao?.icon_cache_path || null,
            proposal.dao_id
          ),
          winning_outcome: proposal.result ? serializeBigInt(proposal.result.winning_outcome) : null,
          dao_name: proposal.dao?.dao_name || null,
          dao_verified: proposal.dao?.verification?.verified || false,
          // Ensure explicit inclusion of fields like title
          title: proposal.title,
          package_id: proposal.package_id,
          outcome_count: serializeBigInt(proposal.outcome_count),
          created_at: serializeBigInt(proposal.created_at),
          asset_value: serializeBigInt(proposal.asset_value),
          stable_value: serializeBigInt(proposal.stable_value),
          review_period_ms: serializeBigInt(proposal.review_period_ms),
          trading_period_ms: serializeBigInt(proposal.trading_period_ms),
          twap_initial_observation: serializeBigInt(proposal.twap_initial_observation),
          twap_start_delay: serializeBigInt(proposal.twap_start_delay),
          twap_step_max: serializeBigInt(proposal.twap_step_max),
          twap_threshold: serializeBigInt(proposal.twap_threshold),
          state_history: proposal.state_history.map((history: any) => ({
            new_state: history.new_state,
            timestamp: serializeBigInt(history.timestamp)
          })),
          initial_outcome_amounts: JSON.parse(proposal.initial_outcome_amounts || '[]'),
          outcome_messages: JSON.parse(proposal.outcome_messages || '[]')
        };
  
      // Process TWAP history: sort by outcome and serialize values.
      const twapRecords = proposal.twapHistory ? [...proposal.twapHistory] : [];
      const expectedCount = Number(proposal.outcome_count);
      if (
        twapRecords.length !== expectedCount ||
        twapRecords.some((record: any) => record.twap === null)
      ) {
        transformedProposal.twaps = null;
      } else {
        transformedProposal.twaps = twapRecords.map((record: any) =>
          record.twap.toString()
        );
      }
  
      // Custom replacer for JSON.stringify to convert any remaining BigInt values.
      const replacer = (key: string, value: any) =>
        typeof value === 'bigint' ? value.toString() : value;
  
      res.send(JSON.parse(JSON.stringify(transformedProposal, replacer)));
    } catch (e) {
      console.error('Error fetching proposal:', e);
      res.status(500).send({
        message: 'Internal server error',
        error: e instanceof Error ? e.message : 'Unknown error'
      });
    }
  });
  
  

// Search by proposal_id
// fetch('/proposals/search?proposal_id=123')
// Search by market_state_id
// fetch('/proposals/search?market_state_id=456')
// Direct lookup (tries both)
//fetch('/proposals/123')

app.get('/proposals/:proposalId/state-history', async (req, res) => {
    try {
        const stateHistory = await prisma.proposalStateChange.findMany({
            where: {
                proposal_id: req.params.proposalId
            },
            orderBy: {
                timestamp: 'desc'
            }
        });

        // Transform the BigInt values to strings before sending
        const transformedHistory = stateHistory.map(history => ({
            ...history,
            timestamp: history.timestamp.toString()
        }));

        res.send(formatPaginatedResponse(transformedHistory));
    } catch (e) {
        console.error('Error fetching state history:', e);
        res.status(400).json({
            error: e instanceof Error ? e.message : 'Unknown error'
        });
    }
});


app.get('/swaps', async (req, res) => {
    const acceptedQueries: WhereParam[] = [
        {
            key: 'market_id',
            type: WhereParamTypes.STRING,
        },
        {
            key: 'outcome',
            type: WhereParamTypes.NUMBER,
        },
        {
            key: 'is_buy',
            type: WhereParamTypes.BOOLEAN,
        },
        {
            key: 'sender',
            type: WhereParamTypes.STRING,
        }
    ];

    try {
        // Create cache key based on query parameters
        const marketId = req.query.market_id as string;
        
        // Only cache if we have a market_id (proposal-level caching)
        if (marketId) {
            const cacheKey = `swaps:${marketId}:${JSON.stringify(req.query)}`;
            const cached = swapCache.get(cacheKey);
            
            // Check if cache is valid (within 5 seconds)
            if (cached && (Date.now() - cached.timestamp < SWAP_CACHE_TTL)) {
                console.log(`Cache hit for proposal ${marketId}`);
                res.send(cached.data);
                return;
            }
        }

        // Cache miss or no market_id - fetch from database
        const pagination = parsePaginationForQuery(req.query);
        const swaps = await prisma.swapEvent.findMany({
            where: parseWhereStatement(req.query, acceptedQueries)!,
            ...pagination,
            orderBy: [
                { timestamp: 'desc' },
                ...(pagination.orderBy ? [pagination.orderBy] : [])
            ]
        });

        // Convert BigInt values to strings
        const serializedSwaps = swaps.map(swap => ({
            ...swap,
            amount_in: swap.amount_in.toString(),
            amount_out: swap.amount_out.toString(),
            price_impact: swap.price_impact.toString(),
            price: swap.price.toString(),
            timestamp: swap.timestamp.toString(),
            asset_reserve: swap.asset_reserve.toString(),    // Added
            stable_reserve: swap.stable_reserve.toString()   // Added
        }));

        const response = formatPaginatedResponse(serializedSwaps);
        
        // Cache the response if we have a market_id
        if (marketId) {
            const cacheKey = `swaps:${marketId}:${JSON.stringify(req.query)}`;
            swapCache.set(cacheKey, {
                data: response,
                timestamp: Date.now()
            });
            console.log(`Cache set for proposal ${marketId}`);
        }

        res.send(response);
    } catch (e) {
        console.error('Error fetching swaps:', e);
        res.status(400).json({
            error: e instanceof Error ? e.message : 'Unknown error'
        });
    }
});

app.get('/results/:proposalId', async (req, res) => {
    try {
        const result = await prisma.resultSigned.findUnique({
            where: {
                proposal_id: req.params.proposalId
            }
        });

        if (!result) {
            res.status(404).send({ 
                message: 'Result not found for this proposal' 
            });
        }

        res.send(result);
    } catch (e) {
        console.error('Error fetching result:', e);
        res.status(500).send({ 
            message: 'Internal server error',
            error: e 
        });
    }
});

const server = app.listen(3000, () => console.log(`🚀 Server ready at: http://localhost:3000`));
