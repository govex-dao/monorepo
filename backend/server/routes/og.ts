import { Router, Request, Response } from 'express';
import { prisma } from '../../db';
import { generateDaoSvg, generateProposalOG, generateGeneralOG, calculateVolumeInUSDC, renderSvgToPng, sendPngResponse, sendErrorResponse, loadCachedImage } from '../../utils/dynamic-image';
import { validateId, logSecurityError } from '../../utils/security';
import path from 'path';
import fs from 'fs/promises';

const router = Router();

// Get dao data or image by ID
router.get('/dao/:daoId', async (req: Request<{ daoId: string }>, res: Response): Promise<void> => {
  try {
    const { daoId } = req.params;
    const returnJson = req.query.format === 'json';

    // Validate input
    if (!validateId(daoId)) {
      res.status(400).json({ error: 'Invalid DAO ID format' });
      return;
    }

    const dao = await prisma.dao.findUnique({
      where: { dao_id: daoId },
      select: {
        dao_id: true,
        dao_name: true,
        description: true,
        icon_url: true,
        icon_cache_large: true,
        asset_symbol: true,
        stable_symbol: true,
        verification: {
          select: { verified: true }
        },
        proposals: {
          select: {
            id: true,
            current_state: true
          }
        }
      }
    });

    if (!dao) {
      res.status(404).json({ error: 'DAO not found' });
      return;
    }

    // Return JSON if requested
    if (returnJson) {
      res.json({
        dao_id: dao.dao_id,
        dao_name: dao.dao_name,
        description: dao.description,
        icon_url: dao.icon_url,
        asset_symbol: dao.asset_symbol,
        stable_symbol: dao.stable_symbol,
        verified: dao.verification?.verified ?? false,
        proposal_count: dao.proposals.length,
        has_live_proposal: dao.proposals.some(proposal => (proposal.current_state || 0) === 0)
      });
      return;
    }

    // ONLY use cached image - no fallback to external URLs
    // deepcode ignore PathTraversal: Path validated in loadCachedImage via validateImagePath() before fs.readFile()
    const daoImage = dao.icon_cache_large ? await loadCachedImage(dao.icon_cache_large) : null;

    const svg = generateDaoSvg({
      name: dao.dao_name,
      description: dao.description,
      logo: daoImage || "placeholder",
      proposalCount: dao.proposals.length,
      hasLiveProposal: dao.proposals.some(proposal => (proposal.current_state || 0) === 0),
      isVerified: dao.verification?.verified ?? false
    });
  
    const png = renderSvgToPng(svg);
    sendPngResponse(res, png);

  } catch (error) {
    logSecurityError('generateDaoOG', error);
    res.status(500).json({ error: 'Failed to generate image' });
  }
});

// Get proposal data or image by ID
router.get('/proposal/:propId', async (req: Request<{ propId: string }>, res: Response) => {
  try {
    const { propId } = req.params;
    const returnJson = req.query.format === 'json';

    // Validate input
    if (!validateId(propId)) {
      res.status(400).json({ error: 'Invalid proposal ID format' });
      return;
    }

    const proposal = await prisma.proposal.findFirst({
      where: {
        OR: [
          { market_state_id: propId },
          { proposal_id: propId }
        ]
      },
      select: {
        proposal_id: true,
        title: true,
        details: true,
        created_at: true,
        current_state: true,
        outcome_messages: true,
        trading_period_ms: true,
        review_period_ms: true,
        market_state_id: true,
        result: {
          select: { winning_outcome: true }
        },
        dao: {
          select: {
            dao_name: true,
            icon_url: true,
            icon_cache_path: true
          }
        }
      }
    });

    if (!proposal) return res.status(404).json({ error: 'Proposal not found' });

    // Get trading statistics
    const [swapCount, uniqueTraders, swapEvents] = await Promise.all([
      prisma.swapEvent.count({
        where: { market_id: proposal.proposal_id }
      }),
      prisma.swapEvent.groupBy({
        by: ['sender'],
        where: { market_id: proposal.proposal_id },
        _count: { sender: true }
      }),
      // Get all swap events to calculate volume
      prisma.swapEvent.findMany({
        where: { market_id: proposal.proposal_id },
        select: {
          amount_in: true,
          amount_out: true,
          is_buy: true
        }
      })
    ]);

    // Parse outcome messages safely
    let outcomeMessages: string[] | undefined;
    try {
      outcomeMessages = proposal.outcome_messages ? JSON.parse(proposal.outcome_messages) : undefined;
    } catch (parseError) {
      logSecurityError('parseOutcomeMessages', parseError);
      outcomeMessages = undefined;
    }

    // Calculate total volume in USDC using the utility function
    const totalVolume = swapEvents.reduce((acc, event) => {
      return acc + calculateVolumeInUSDC(
        event.amount_in.toString(),
        event.amount_out.toString(),
        event.is_buy,
        1e6 // USDC scale
      );
    }, 0);

    // Return JSON if requested
    if (returnJson) {
      return res.json({
        id: proposal.proposal_id,
        title: proposal.title,
        details: proposal.details,
        dao_name: proposal.dao?.dao_name || "DAO",
        dao_icon_url: proposal.dao?.icon_cache_path,
        current_state: proposal.current_state || 0,
        winning_outcome: Number(proposal.result?.winning_outcome) || 0,
        outcome_messages: outcomeMessages,
        traders: uniqueTraders.length,
        trades: swapCount,
        volume: totalVolume,
        created_at: proposal.created_at?.toString(),
        trading_period_ms: proposal.trading_period_ms?.toString(),
        review_period_ms: proposal.review_period_ms?.toString()
      });
    }


    // deepcode ignore PathTraversal: Path validated in generateProposalOG->loadCachedImage via validateImagePath() before fs.readFile()
    const svg = await generateProposalOG({
      title: proposal.title,
      description: proposal.details || "",
      daoName: proposal.dao?.dao_name || "DAO",
      daoLogo: proposal.dao?.icon_cache_path || "placeholder",
      currentState: proposal.current_state || 0,
      winningOutcome: Number(proposal.result?.winning_outcome) || 0,
      outcomeMessages,
      traders: uniqueTraders.length,
      trades: swapCount,
      volume: totalVolume,
      tradingStartDate: new Date(Number(proposal.created_at) + Number(proposal.review_period_ms)),
      tradingPeriodMs: Number(proposal.trading_period_ms)
    });

    const png = renderSvgToPng(svg);
    sendPngResponse(res, png);
  } catch (error) {
    logSecurityError('generateProposalOG', error);
    res.status(500).json({ error: 'Failed to generate image' });
  }
});

// Generate general OG image
router.get('/general', async (_req: Request, res: Response) => {
  try {
    const svg = await generateGeneralOG();
    const png = renderSvgToPng(svg);
    sendPngResponse(res, png);
  } catch (error) {
    logSecurityError('generateGeneralOG', error);
    res.status(500).json({ error: 'Failed to generate image' });
  }
});

export default router;