import { Router, Request, Response } from 'express';
import { prisma } from '../../db';
import { Resvg } from '@resvg/resvg-js';
import { generateDaoSvg, generateProposalOG, generateGeneralOG } from '../../utils/dynamic-image';
import { validateId, logSecurityError } from '../../utils/security';
import path from 'path';
import fs from 'fs/promises';

const router = Router();

router.get('/dao/:daoId', async (req: Request<{ daoId: string }>, res: Response): Promise<void> => {
  try {
    const { daoId } = req.params;
    
    // Validate input
    if (!validateId(daoId)) {
      res.status(400).json({ error: 'Invalid DAO ID format' });
      return;
    }

    const dao = await prisma.dao.findUnique({
      where: { dao_id: daoId },
      select: {
        dao_name: true,
        description: true,
        icon_url: true,
        icon_cache_large: true, // Use 512x512 cached image
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
    
    // ONLY use cached image - no fallback to external URLs
    let daoImage = null;
    if (dao.icon_cache_large) {
      try {
        const imagePath = path.join(process.cwd(), 'public', dao.icon_cache_large.substring(1));
        const imageBuffer = await fs.readFile(imagePath);
        daoImage = `data:image/png;base64,${imageBuffer.toString('base64')}`;
      } catch (err) {
        logSecurityError('readCachedImage', err);
      }
    }

    const svg = generateDaoSvg({
      name: dao.dao_name,
      description: dao.description,
      logo: daoImage || "placeholder",
      proposalCount: dao.proposals.length,
      hasLiveProposal: dao.proposals.some(proposal => (proposal.current_state || 0) === 0),
      isVerified: dao.verification?.verified ?? false
    });
    const resvg = new Resvg(svg);
    const png = resvg.render().asPng();

    res.setHeader('Content-Type', 'image/png');
    res.setHeader('Cache-Control', 'public, max-age=900'); // Cache for 15 minutes
    res.send(png);

  } catch (error) {
    logSecurityError('generateDaoOG', error);
    res.status(500).json({ error: 'Failed to generate image' });
  }
});

router.get('/proposal/:propId', async (req: Request<{ propId: string }>, res: Response): Promise<void> => {
  try {
    const { propId } = req.params;
    
    // Validate input
    if (!validateId(propId)) {
      res.status(400).json({ error: 'Invalid proposal ID format' });
      return;
    }

    const proposal = await prisma.proposal.findUnique({
      where: { proposal_id: propId },
      select: {
        proposal_id: true,
        title: true,
        created_at: true,
        current_state: true,
        outcome_messages: true,
        trading_period_ms: true,
        review_period_ms: true,
        result: {
          select: { winning_outcome: true }
        },
        dao: {
          select: {
            dao_name: true,
            icon_url: true,
            icon_cache_large: true // Use 512x512 cached image
          }
        }
      }
    });

    if (!proposal) {
      res.status(404).json({ error: 'Proposal not found' });
      return;
    }
    
    const [swapCount, uniqueTraders] = await Promise.all([
      prisma.swapEvent.count({
        where: { market_id: proposal.proposal_id }
      }),
      prisma.swapEvent.groupBy({
        by: ['sender'],
        where: { market_id: proposal.proposal_id },
        _count: { sender: true }
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

    const svg = await generateProposalOG({
      title: proposal.title,
      daoName: proposal.dao?.dao_name || "DAO",
      daoLogo: proposal.dao?.icon_cache_large || proposal.dao?.icon_url || "placeholder",
      currentState: proposal.current_state || 0,
      winningOutcome: Number(proposal.result?.winning_outcome) || 0,
      outcomeMessages,
      traders: uniqueTraders.length,
      trades: swapCount,
      tradingStartDate: new Date(Number(proposal.created_at) + Number(proposal.review_period_ms)),
      tradingPeriodMs: Number(proposal.trading_period_ms)
    });

    const resvg = new Resvg(svg);
    const png = resvg.render().asPng();

    res.setHeader('Content-Type', 'image/png');
    res.setHeader('Cache-Control', 'public, max-age=900'); // Cache for 15 minutes
    res.send(png);

  } catch (error) {
    logSecurityError('generateProposalOG', error);
    res.status(500).json({ error: 'Failed to generate image' });
  }
});

router.get('/general', async (req: Request, res: Response): Promise<void> => {
  try {
    const svg = await generateGeneralOG();
    const resvg = new Resvg(svg);
    const png = resvg.render().asPng();

    res.setHeader('Content-Type', 'image/png');
    res.setHeader('Cache-Control', 'public, max-age=604800'); // Cache for 7 days since it's static
    res.send(png);

  } catch (error) {
    logSecurityError('generateGeneralOG', error);
    res.status(500).json({ error: 'Failed to generate image' });
  }
});

export default router;