import { Router, Request, Response } from 'express';
import { prisma } from '../../db';
import { Resvg } from '@resvg/resvg-js';
import { fetchAndEncodeImage, generateDaoSvg, generateProposalOG, generateGeneralOG } from '../../utils/dynamic-image';

const router = Router();

router.get('/dao/:daoId', async (req: Request<{ daoId: string }>, res: Response) => {
  try {
    const { daoId } = req.params;

    const dao = await prisma.dao.findUnique({
      where: { dao_id: daoId },
      select: {
        dao_name: true,
        description: true,
        icon_url: true,
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

    if (!dao)
      res.status(404).json({ error: 'DAO not found' })
    else {
      const daoImage = dao.icon_url ? await fetchAndEncodeImage(dao.icon_url) : null;

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
    }

  } catch (error) {
    console.error('Error generating DAO OG image:', error);
    res.status(500).json({ error: 'Internal server error' });
  }
});

router.get('/proposal/:propId', async (req: Request<{ propId: string }>, res: Response) => {
  try {
    const { propId } = req.params;

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
            icon_url: true
          }
        }
      }
    });

    if (!proposal)
      res.status(404).json({ error: 'Proposal not found' })
    else {
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

      console.log(Number(proposal.result?.winning_outcome));

      const svg = await generateProposalOG({
        title: proposal.title,
        daoName: proposal.dao?.dao_name || "DAO",
        daoLogo: proposal.dao?.icon_url || "placeholder",
        currentState: proposal.current_state || 0,
        winningOutcome: Number(proposal.result?.winning_outcome) || 0,
        outcomeMessages: proposal.outcome_messages ? JSON.parse(proposal.outcome_messages) : undefined,
        traders: uniqueTraders.length,
        trades: swapCount,
        tradingStartDate: new Date(Number(proposal.created_at) + Number(proposal.review_period_ms)),
        tradingPeriodMs: Number(proposal.trading_period_ms)
      });
      console.log(svg);

      const resvg = new Resvg(svg);
      const png = resvg.render().asPng();

      res.setHeader('Content-Type', 'image/png');
      res.setHeader('Cache-Control', 'public, max-age=900'); // Cache for 15 minutes
      res.send(png);
    }

  } catch (error) {
    console.error('Error generating proposal OG image:', error);
    res.status(500).json({ error: 'Internal server error' });
  }
});

router.get('/general', async (req: Request, res: Response) => {
  try {
    const svg = await generateGeneralOG();
    const resvg = new Resvg(svg);
    const png = resvg.render().asPng();

    res.setHeader('Content-Type', 'image/png');
    res.setHeader('Cache-Control', 'public, max-age=604800'); // Cache for 7 days since it's static
    res.send(png);

  } catch (error) {
    console.error('Error generating general OG image:', error);
    res.status(500).json({ error: 'Internal server error' });
  }
});

export default router;