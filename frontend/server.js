import express from "express";
import { createServer as createViteServer } from "vite";
import fs from "fs";
import path from "path";
import { fileURLToPath } from "url";
import { loadEnv } from "vite";

// Configuration
const __dirname = path.dirname(fileURLToPath(import.meta.url));
const isProduction = process.env.NODE_ENV === "production";
const PORT = process.env.PORT || 5173;
const HOST = "0.0.0.0";

// Load environment variables
const env = loadEnv(
  isProduction ? "production" : "development",
  process.cwd(),
  "",
);
Object.keys(env).forEach((key) => {
  process.env[key] = env[key];
});

const API_URL = process.env.VITE_API_URL ? `https://${process.env.VITE_API_URL}/` : "http://localhost:3000/";
console.log('Environment API URL:', process.env.VITE_API_URL);
console.log('Constructed API URL:', API_URL);

// Helper Functions
async function fetchDaoData(daoId) {
  try {
    const response = await fetch(`${API_URL}og/dao/${daoId}`, {
      headers: { Accept: "application/json" },
    });
    if (response.ok) {
      return await response.json();
    }
  } catch (error) {
    console.error("Error fetching DAO data:", error);
  }
  return null;
}

async function fetchProposalData(proposalId) {
  try {
    const response = await fetch(`${API_URL}og/proposal/${proposalId}`, {
      headers: { Accept: "application/json" },
    });
    if (response.ok) {
      return await response.json();
    }
  } catch (error) {
    console.error("Error fetching proposal data:", error);
  }
  return null;
}

function buildDaoOgData(dao, apiUrl) {
  const ogImageParams = new URLSearchParams({
    name: dao.dao_name,
    description: dao.description || "",
    proposalCount: dao.proposal_count.toString(),
    hasLiveProposal: dao.has_live_proposal.toString(),
    isVerified: dao.verified.toString(),
    logoUrl: dao.icon_url || "",
  });

  return {
    title:
      dao.dao_name !== "Govex"
        ? `${dao.dao_name} - Powered by Govex`
        : dao.dao_name,
    description: `${dao.description || `${dao.dao_name} on Govex • Futarchy governance on Sui`} • ${dao.proposal_count} proposal${dao.proposal_count !== 1 ? "s" : ""}`,
    keywords: `${dao.dao_name}, ${dao.asset_symbol || ""}, ${dao.stable_symbol || ""}, futarchy, DAO, Sui, governance, decentralized organization`,
    image: `${apiUrl}og/dao-image?${ogImageParams.toString()}`,
  };
}

function generateOgMetaTags(ogData, canonicalUrl) {
  if (!ogData.title) return "";
  
  return [
    // Basic SEO
    `<title>${ogData.title}</title>`,
    `<meta name="description" content="${ogData.description}" />`,
    `<meta name="keywords" content="${ogData.keywords}" />`,
    `<meta name="author" content="${ogData.author}" />`,
    `<meta name="robots" content="index, follow, max-image-preview:large, max-snippet:-1, max-video-preview:-1" />`,
    `<meta name="googlebot" content="index, follow" />`,
    `<link rel="canonical" href="${canonicalUrl}" />`,

    // Geo tags
    `<meta name="geo.region" content="Global" />`,
    `<meta name="geo.placename" content="Global" />`,

    // Open Graph
    `<meta property="og:title" content="${ogData.title}" />`,
    `<meta property="og:description" content="${ogData.description}" />`,
    `<meta property="og:image" content="${ogData.image}" />`,
    `<meta property="og:image:width" content="1200" />`,
    `<meta property="og:image:height" content="630" />`,
    `<meta property="og:image:alt" content="${ogData.title}" />`,
    `<meta property="og:url" content="${canonicalUrl}" />`,
    `<meta property="og:type" content="${ogData.type}" />`,
    `<meta property="og:site_name" content="Govex" />`,
    `<meta property="og:locale" content="en_US" />`,

    // Twitter Card
    `<meta name="twitter:card" content="summary_large_image" />`,
    `<meta name="twitter:title" content="${ogData.title}" />`,
    `<meta name="twitter:description" content="${ogData.description}" />`,
    `<meta name="twitter:image" content="${ogData.image}" />`,
    `<meta name="twitter:image:alt" content="${ogData.title}" />`,
    `<meta name="twitter:site" content="@govexdotai" />`,
    `<meta name="twitter:creator" content="@govexdotai" />`,
    `<meta name="twitter:domain" content="govex.ai" />`,

    // Mobile and viewport
    `<meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=5.0" />`,
    `<meta name="mobile-web-app-capable" content="yes" />`,
    `<meta name="apple-mobile-web-app-capable" content="yes" />`,
    `<meta name="apple-mobile-web-app-status-bar-style" content="black-translucent" />`,
    `<meta name="apple-mobile-web-app-title" content="Govex" />`,

    // Favicon and theme color
    `<link rel="icon" href="/favicon.ico" />`,
    `<link rel="apple-touch-icon" href="/images/govex-icon.png" />`,
    `<meta name="theme-color" content="#1f2937" />`,
    `<meta name="msapplication-TileColor" content="#1f2937" />`,

    // Preconnect to external domains for performance
    `<link rel="preconnect" href="https://fonts.googleapis.com" />`,
    `<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin="anonymous" />`,
  ].join("\n");
}

function buildProposalOgData(proposal, apiUrl) {
  const proposalId = proposal.proposal_id || proposal.market_state_id;

  // Calculate trading status
  let tradingStatus = "";
  if (proposal.created_at && proposal.trading_period_ms) {
    const now = Date.now();
    const startTime = parseInt(proposal.created_at);
    const endTime = startTime + parseInt(proposal.trading_period_ms);

    if (now < startTime) {
      tradingStatus = "Trading starts: " + new Date(startTime).toLocaleDateString();
    } else if (now < endTime) {
      tradingStatus = "Trading ends: " + new Date(endTime).toLocaleDateString();
    } else {
      tradingStatus = "Trading ended";
    }
  }

  // Add winning outcome information
  let outcomeInfo = "";
  if (proposal.winning_outcome !== undefined && proposal.outcome_messages) {
    const winningMessage = proposal.outcome_messages[proposal.winning_outcome];
    if (winningMessage && winningMessage !== "") {
      const now = Date.now();
      const startTime = parseInt(proposal.created_at);
      const endTime = startTime + parseInt(proposal.trading_period_ms);
      const hasEnded = now >= endTime;

      outcomeInfo = hasEnded
        ? ` • Won: ${winningMessage}`
        : ` • Currently winning: ${winningMessage}`;
    }
  }

  // Add current trades and trader information
  let priceInfo = "";
  if (proposal.trades !== undefined && proposal.traders !== undefined) {
    priceInfo = ` • ${proposal.trades} trades by ${proposal.traders} traders`;
  }

  // Add volume information if available
  if (proposal.volume !== undefined && proposal.volume > 0) {
    priceInfo += ` • Volume: $${proposal.volume.toFixed(2)}`;
  }

  return {
    title: `${proposal.title} - ${proposal.dao_name}`,
    description: tradingStatus + outcomeInfo + priceInfo,
    keywords: `${proposal.dao_name}, ${proposal.outcome_messages?.slice(0, 2).join(", ")}, ${proposal.title}, futarchy, prediction market, trade, vote, AMM`,
    image: `${apiUrl}og/proposal/${proposalId}`,
    type: "article",
  };
}

// Constants
const DEFAULT_OG_DATA = {
  title: "Govex - Futarchy on Sui",
  description:
    "Discover and trade on futarchy proposals. Explore DAOs, prediction markets, and governance on Govex, the leading futarchy platform on Sui.",
  keywords:
    "futarchy, prediction markets, trade, DAOs, governance, Sui, Govex",
  author: "Govex",
  type: "website",
};

const PAGE_OG_DATA = {
  "/create": {
    title: "Create - Govex",
    description:
      "Create new proposals or DAOs on Govex. Launch your own futarchy markets and participate in decentralized governance on Sui.",
    keywords:
      "create DAO, create proposal, futarchy, governance, Sui, Govex",
  },
  "/learn": {
    title: "Learn - Govex",
    description:
      "Learn about futarchy, prediction markets, and how Govex empowers decentralized governance on Sui. Educational resources and guides.",
    keywords:
      "futarchy education, prediction markets guide, DAO governance, blockchain education, Sui tutorial",
  },
};

// Initialize server
async function createServer() {
  const app = express();

  // Setup Vite in development or static files in production
  let vite;
  if (!isProduction) {
    vite = await createViteServer({
      server: { middlewareMode: true },
      appType: "custom",
    });
    app.use(vite.middlewares);
  } else {
    app.use(
      express.static(path.join(__dirname, "dist/client"), {
        index: false, // Prevent serving index.html for directory requests
      }),
    );
  }

  // Main route handler
  app.get("*", async (req, res) => {
    const url = req.originalUrl;
    
    console.log(req.get("host"))
    console.log(API_URL)
    try {
      let template, render;

      if (!isProduction) {
        // Load and transform HTML template
        template = fs.readFileSync(path.join(__dirname, "index.html"), "utf-8");
        template = await vite.transformIndexHtml(url, template);

        // Load the server entry point
        render = (await vite.ssrLoadModule("/src/entry-server.tsx")).render;
      } else {
        // In production, use pre-built files
        try {
          template = fs.readFileSync(
            path.join(__dirname, "dist/client/index.html"),
            "utf-8",
          );
          render = (await import("./dist/server/entry-server.js")).render;
        } catch (error) {
          console.error("Failed to load production files:", error);
          throw new Error(`Failed to load production files: ${error.message}`);
        }
      }


      // Initialize OG data
      let ogData = {
        ...DEFAULT_OG_DATA,
        image: `https://${req.get("host")}/images/og.png`,
      };

      // Override with page-specific data if available
      if (PAGE_OG_DATA[url]) {
        ogData = { ...ogData, ...PAGE_OG_DATA[url] };
      }

      // Handle dynamic routes
      const daoMatch = url.match(/^\/dao\/(.+)$/);
      const proposalMatch = url.match(/^\/trade\/(.+)$/);

      console.log("PROPOSAL MATCH", proposalMatch)
      if (daoMatch) {
        const dao = await fetchDaoData(daoMatch[1]);
        if (dao) {
          ogData = { ...ogData, ...buildDaoOgData(dao, API_URL) };
        }
      } else if (proposalMatch) {
        const proposal = await fetchProposalData(proposalMatch[1]);
        console.log(proposal)
        if (proposal) {
          console.error("Proposal data:", JSON.stringify(proposal, null, 2));
          console.error("Trades and traders:", proposal.trades, proposal.traders);
          ogData = { ...ogData, ...buildProposalOgData(proposal, API_URL) };
        }
      }

      // Handle SSR (development only for now)
      let html = "";
      let helmetTags = "";
      
      if (!isProduction) {
        try {
          const helmetContext = {};
          const { html: ssrHtml, helmet } = render(url, helmetContext);
          html = ssrHtml;
          helmetTags = [
            helmet?.title?.toString() || "",
            helmet?.meta?.toString() || "",
            helmet?.link?.toString() || "",
          ].filter(Boolean).join("\n");
        } catch (error) {
          console.error("SSR failed:", error.message);
          // Continue with client-side rendering
        }
      }

      // Generate OG meta tags
      const canonicalUrl = `${req.protocol}://${req.get("host")}${req.originalUrl}`;
      const ogMetaTags = generateOgMetaTags(ogData, canonicalUrl);

      // Replace placeholders in template
      const finalHtml = template
        .replace(`<!--app-html-->`, html)
        .replace(`<!--app-head-->`, [ogMetaTags, helmetTags].filter(Boolean).join("\n"));

      res.status(200).set({ "Content-Type": "text/html" }).send(finalHtml);
    } catch (error) {
      if (!isProduction && vite) {
        vite.ssrFixStacktrace(error);
      }
      console.error("Server error:", error);
      res.status(500).send(error.message);
    }
  });

  app.listen(PORT, HOST, () => {
    console.log(
      `[${new Date().toISOString()}] Server running at http://${HOST}:${PORT}`,
    );
  });
}

createServer();
