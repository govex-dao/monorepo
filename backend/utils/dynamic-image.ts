
import { logSecurityError, escapeXml } from './security';
import path from 'path';
import fs from 'fs/promises';
import { Response } from 'express';
import { Resvg } from '@resvg/resvg-js';

// Image rendering helpers
export interface RenderOptions {
  dpi?: number;
  shapeRendering?: 0 | 1 | 2;
  textRendering?: 0 | 1 | 2;
  imageRendering?: 0 | 1;
}

export function renderSvgToPng(svg: string, options: RenderOptions = {}) {
  const resvg = new Resvg(svg, { font: FONT_FAMILY, ...options });
  return resvg.render().asPng();
}

export function sendPngResponse(res: Response, png: Buffer, cacheControl: string = CACHE_DURATION.image) {
  res.setHeader('Content-Type', 'image/png');
  res.setHeader('Cache-Control', cacheControl);
  res.send(png);
}

export function sendErrorResponse(res: Response, error: any, message = 'Internal server error') {
  console.error(message, error);
  res.status(500).json({ error: message });
}

// Image loading helper
export async function loadCachedImage(imagePath: string): Promise<string | null> {
  try {
    if (!imagePath.startsWith('/')) {
      imagePath = '/' + imagePath;
    }
    const fullPath = path.join(process.cwd(), 'public', imagePath.substring(1));
    const imageBuffer = await fs.readFile(fullPath);
    return `data:image/png;base64,${imageBuffer.toString('base64')}`;
  } catch (err) {
    logSecurityError('loadCachedImage', err);
    return null;
  }
}

// Constants
export const OG_IMAGE_DIMENSIONS = {
  width: 1200,
  height: 630,
} as const;

// Utility function to format large numbers
function formatNumber(num: number): string {
  const absNum = Math.abs(num);
  if (absNum >= 1_000_000_000) {
    return (num / 1_000_000_000).toFixed(1) + 'B';
  }
  if (absNum >= 1_000_000) {
    return (num / 1_000_000).toFixed(1) + 'M';
  }
  if (absNum >= 1_000) {
    return (num / 1_000).toFixed(1) + 'K';
  }
  // For numbers less than 1000, show at most 2 decimal places
  return Number(num.toFixed(2)).toString();
}

export const FONT_CONFIG = {
  minSize: 24,
  defaultSize: 48,
  titleSize: 72,
  stepSize: 4,
  coeff: 0.5, // Increased from 0.50 to better estimate text width
  lineSpacing: 6,
} as const;

// Configuration
export const FONT_FAMILY = {
  loadSystemFonts: true,
  defaultFontFamily: 'DejaVu Sans',
  sansSerifFamily: 'DejaVu Sans',
  serifFamily: 'DejaVu Serif',
  monospaceFamily: 'DejaVu Sans Mono'
} as const;

export const CACHE_DURATION = {
  image: process.env.NODE_ENV === 'development' ? 'no-store, no-cache, must-revalidate' : 'public, max-age=900', // 15 minutes in prod, no cache in dev
  static: process.env.NODE_ENV === 'development' ? 'no-store, no-cache, must-revalidate' : 'public, max-age=604800' // 7 days in prod, no cache in dev
} as const;

export const COLORS = {
  background: {
    primary: '#0F172A',
    secondary: '#1E293B',
    tertiary: '#334155',
    quaternary: '#475569',
  },
  text: {
    primary: '#F8FAFC',
    secondary: '#CBD5E1',
    tertiary: '#94A3B8',
    quaternary: '#64748B',
  },
  accent: {
    blue: '#60A5FA',
    blueDark: '#3B82F6',
    blueDeep: '#1D4ED8',
    green: '#10B981',
    greenDark: '#059669',
    red: '#EF4444',
    redDark: '#DC2626',
    gray: '#374151',
  },
} as const;

// Types
export interface TextWrapResult {
  lines: string[];
  fontSize: number;
  totalHeight: number;
}

export interface DaoOgParams {
  name: string;
  description: string;
  logo: string;
  proposalCount: number;
  hasLiveProposal: boolean;
  isVerified: boolean;
}

export interface ProposalOgParams {
  title: string;
  description: string;
  daoName: string;
  daoLogo: string;
  currentState: number;
  winningOutcome?: number | null;
  outcomeMessages: string[] | undefined;
  traders?: number;
  trades?: number;
  volume?: number;
  tradingStartDate: Date;
  tradingPeriodMs: number
}

export function calculateVolumeInUSDC(
  amountIn: string,
  amountOut: string,
  isBuy: boolean,
  stableScale: number,
): number {
  // For buys: amount_in is USDC
  // For sells: amount_out is USDC
  const usdcAmount = isBuy ? amountIn : amountOut;
  return Number(usdcAmount) / stableScale;
}

// type TextWrapResult = { lines: string[]; fontSize: number; totalHeight: number };
type MeasureCtx = { font: string; measureText: (t: string) => { width: number } };

let ctx: MeasureCtx | null = null;

function getCtx(): MeasureCtx {
  if (ctx) return ctx;
  if (typeof document !== 'undefined') {
    const c = document.createElement('canvas');
    ctx = c.getContext('2d') as unknown as MeasureCtx;
  } else {
    const { createCanvas } = require('@napi-rs/canvas');
    ctx = createCanvas(1, 1).getContext('2d') as unknown as MeasureCtx;
  }
  return ctx!;
}

export function measure(
  text: string,
  px: number,
  family = 'DejaVu Sans',   // system font available from fonts-dejavu-core
  weight = 400
): number {
  const c = getCtx();
  c!.font = `${weight} ${px}px "${family}"`;
  return c!.measureText(text).width;
}

export function wrapText(
  text: string,
  maxWidth: number,
  fontSize: number,
  {
    family = 'sans-serif',
    maxHeight = Infinity,
    minFontSize = 10,
    lineHeight = 1.2,
    maxLines = 4
  } = {}
): TextWrapResult {
  const words = text.split(/\s+/);
  let fs = fontSize;

  const buildLines = () => {
    const out: string[] = [];
    let line = '';
    for (const w of words) {
      const test = line ? line + ' ' + w : w;
      if (measure(test, fs, family) <= maxWidth) {
        line = test;
      } else {
        if (line) out.push(line);
        // handle ultra-long words
        if (!line && measure(w, fs, family) > maxWidth) {
          let chunk = '';
          for (const ch of w) {
            const t = chunk + ch;
            if (measure(t, fs, family) <= maxWidth) chunk = t;
            else { out.push(chunk); chunk = ch; }
          }
          line = chunk;
        } else {
          line = w;
        }
      }
      if (out.length === maxLines) break;
    }
    if (line && out.length < maxLines) out.push(line);
    return out;
  };

  let lines = buildLines();
  let totalHeight = lines.length * fs * lineHeight;

  // shrink font until both constraints satisfied
  while ((lines.length > maxLines || totalHeight > maxHeight) && fs > minFontSize) {
    fs = Math.max(minFontSize, Math.floor(fs - 1));
    lines = buildLines();
    totalHeight = lines.length * fs * lineHeight;
  }

  // if still overflowing in line count, truncate last line with fitted ellipsis
  if (lines.length > maxLines) {
    lines = lines.slice(0, maxLines);
  }
  const last = lines[lines.length - 1] ?? '';
  if (lines.length === maxLines && (words.join(' ') !== lines.join(' '))) {
    let ell = last;
    while (ell && measure(ell + '…', fs, family) > maxWidth) ell = ell.slice(0, -1);
    lines[lines.length - 1] = (ell || '').replace(/\s+$/,'') + '…';
  }

  totalHeight = lines.length * fs * lineHeight;
  return { lines, fontSize: fs, totalHeight };
}

// Note: fetchAndEncodeImage removed - we only use cached images now
// This completely eliminates SSRF risk in OG image generation

export const svgDefs = `
<defs>
  <!-- Background gradients -->
  <linearGradient id="bg" x1="0%" y1="0%" x2="100%" y2="100%">
    <stop offset="0%" style="stop-color:${COLORS.background.primary};stop-opacity:1" />
    <stop offset="100%" style="stop-color:#111113;stop-opacity:1" />
  </linearGradient>
  
  <!-- Logo gradient -->
  <linearGradient id="logoRing" x1="0%" y1="0%" x2="100%" y2="100%">
    <stop offset="0%" style="stop-color:${COLORS.accent.blue};stop-opacity:1" />
    <stop offset="50%" style="stop-color:${COLORS.accent.blueDark};stop-opacity:0.8" />
    <stop offset="100%" style="stop-color:${COLORS.accent.blueDeep};stop-opacity:1" />
    </linearGradient>
    
    <!-- Avatar gradient -->
    <linearGradient id="avatarGradient" x1="0%" y1="0%" x2="100%" y2="100%">
    <stop offset="0%" style="stop-color:${COLORS.background.quaternary};stop-opacity:1" />
    <stop offset="100%" style="stop-color:${COLORS.text.quaternary};stop-opacity:1" />
    </linearGradient>
    
  <!-- Card solid colors -->
  <!-- No gradients needed for cards anymore -->
  
  <linearGradient id="verifiedBg" x1="0%" y1="0%" x2="100%" y2="100%">
    <stop offset="0%" style="stop-color:rgba(59, 130, 246, 0.2);stop-opacity:1" />
    <stop offset="100%" style="stop-color:rgba(37, 99, 235, 0.15);stop-opacity:1" />
    </linearGradient>
    
  <!-- Outcome gradients removed - using solid colors now -->
  
  <!-- Filters -->
    <filter id="glow">
      <feGaussianBlur stdDeviation="4" result="coloredBlur"/>
      <feMerge> 
        <feMergeNode in="coloredBlur"/>
        <feMergeNode in="SourceGraphic"/>
      </feMerge>
    </filter>
    
  <filter id="statusGlow" x="-50%" y="-50%" width="200%" height="200%">
      <feGaussianBlur stdDeviation="3" result="coloredBlur"/>
      <feMerge>
        <feMergeNode in="coloredBlur"/>
        <feMergeNode in="SourceGraphic"/>
      </feMerge>
    </filter>
    
  <filter id="cardShadow" x="-20%" y="-20%" width="140%" height="140%">
    <feDropShadow dx="0" dy="6" stdDeviation="10" flood-color="#000000" flood-opacity="0.3"/>
    </filter>
  
  <!-- Clip paths -->
  <clipPath id="logoClip">
    <circle cx="80" cy="80" r="75" />
  </clipPath>
  
  <clipPath id="avatarClip">
    <circle cx="80" cy="60" r="28" />
  </clipPath>
</defs>`;

export function createDaoLogo(logo: string, name: string): string {
  return `
<g transform="translate(20, 20)">
  <!-- Outer glow ring -->
  <circle cx="80" cy="80" r="85" fill="none" stroke="url(#logoRing)" stroke-width="3" opacity="0.6" filter="url(#glow)"/>
  <circle cx="80" cy="80" r="80" fill="url(#logoRing)" opacity="0.1"/>
  
  ${createAvatar({
    x: 80,
    y: 80,
    size: 150,
    image: logo && logo !== "placeholder" ? logo : null,
    fallbackText: name.charAt(0),
    clipId: 'logoClip'
  })}
</g>`;
}

export function createDaoMainContent(name: string, description: string): string {
  const { lines: descLines, fontSize: descFontSize } = wrapText(
    description || "A futarchy-governed DAO where prediction markets drive decision-making",
    650, 28, { maxHeight: 100 }
  );

  // Sanitize user input
  const safeName = escapeXml(name);
  const safeDescLines = descLines.map(line => escapeXml(line));

  return `
<g transform="translate(220, 50)">
  <!-- DAO Name -->
  <text x="0" y="40" font-family="Roboto, sans-serif" font-size="80" font-weight="700" fill="${COLORS.text.primary}" letter-spacing="-0.02em">${safeName}</text>
  
  <!-- Description -->
  <g transform="translate(0, 90)">
    ${safeDescLines.map((line, index) =>
    `<text x="0" y="${index * (descFontSize + 8)}" font-family="Roboto, sans-serif" font-size="${descFontSize}" font-weight="400" fill="${COLORS.text.secondary}" opacity="0.9" letter-spacing="0.01em">${line}</text>`
  ).join('')}
  </g>
</g>`;
}

// Unified card creation function
export function createInfoCard({
  x,
  y,
  width,
  height,
  title,
  value,
  subtitle,
  color = COLORS.text.tertiary,
  bgColor = COLORS.background.secondary,
  animated = false
}: {
  x: number;
  y: number;
  width: number;
  height: number;
  title: string;
  value: string;
  subtitle: string;
  color?: string;
  bgColor?: string;
  animated?: boolean;
}): string {
  return `
<g transform="translate(${x}, ${y})">
  <rect x="0" y="0" width="${width}" height="${height}" rx="24" fill="${bgColor + "60"}" stroke="${COLORS.background.quaternary + "40"}" stroke-width="2" filter="url(#cardShadow)"/>
  <rect x="2" y="2" width="${width - 4}" height="${height - 4}" rx="22" fill="none" stroke="rgba(148, 163, 184, 0.08)" stroke-width="1"/>
  ${animated ? `
  <circle cx="40" cy="45" r="8" fill="${color}">
    <animate attributeName="opacity" values="1;0.3;1" dur="2s" repeatCount="indefinite"/>
  </circle>
  <text x="70" y="52" font-family="Arial, Helvetica, sans-serif" font-size="28" fill="${COLORS.text.secondary}" font-weight="500" letter-spacing="0.05em">${title}</text>
  ` : `
  <text x="30" y="45" font-family="Arial, Helvetica, sans-serif" font-size="28" fill="${COLORS.text.secondary}" font-weight="500" letter-spacing="0.05em">${title}</text>
  `}
  <text x="30" y="105" font-family="Arial, Helvetica, sans-serif" font-size="46" font-weight="600" fill="${COLORS.text.primary}" letter-spacing="-0.01em">${value}</text>
</g>`;
}

export function createStatsCards(proposalCount: number, hasLiveProposal: boolean): string {
  const cardWidth = 480;
  const cardHeight = 150;
  const cardSpacing = 520;
  const baseX = (OG_IMAGE_DIMENSIONS.width - 1000) / 2;

  return `
<g transform="translate(${baseX}, 380)">
  ${createInfoCard({
    x: 0,
    y: 0,
    width: cardWidth,
    height: cardHeight,
    title: 'TOTAL PROPOSALS',
    value: proposalCount.toString(),
    subtitle: 'Created by the community',
    color: COLORS.text.primary
  })}
  
  ${hasLiveProposal
      ? createInfoCard({
        x: cardSpacing,
        y: 0,
        width: cardWidth,
        height: cardHeight,
        title: 'LIVE PROPOSALS',
        value: 'Trading Now',
        subtitle: 'Markets are trading',
        color: COLORS.accent.green,
        bgColor: 'rgba(16, 185, 129, 0.15)',
        animated: true
      })
      : createInfoCard({
        x: cardSpacing,
        y: 0,
        width: cardWidth,
        height: cardHeight,
        title: 'ACTIVITY STATUS',
        value: 'Not trading',
        subtitle: 'Create one to get started',
        color: COLORS.text.tertiary,
        bgColor: 'rgba(71, 85, 105, 0.4)'
      })
    }
</g>`;
}

export function createAvatar({ x, y, size, image, fallbackText, clipId = 'avatarClip', showGlow = false
}: { x: number; y: number; size: number; image?: string | null; fallbackText: string; clipId?: string; showGlow?: boolean; }): string {
  const radius = size / 2;
  const glowRadius = radius + 8;
  const glowBgRadius = radius + 4;

  return `
<g transform="translate(${x - radius}, ${y - radius})">
  ${showGlow ? `
  <!-- Outer glow ring -->
  <circle cx="${radius}" cy="${radius}" r="${glowRadius}" fill="none" stroke="url(#logoRing)" stroke-width="3" opacity="0.6" filter="url(#glow)"/>
  <circle cx="${radius}" cy="${radius}" r="${glowBgRadius}" fill="url(#logoRing)" opacity="0.1"/>
  ` : ''}
  <circle cx="${radius}" cy="${radius}" r="${radius}" fill="${COLORS.accent.gray}" opacity="0.8"/>
  
  ${image ? `
  <clipPath id="${clipId}">
    <circle cx="${radius}" cy="${radius}" r="${radius}" />
  </clipPath>
  <image href="${image}" x="0" y="0" width="${size}" height="${size}" preserveAspectRatio="xMidYMid slice" clip-path="url(#${clipId})" />
  ` : `
  <text x="${radius}" y="${radius + 8}" font-family="Roboto, sans-serif" font-size="${size * 0.4}" font-weight="700" fill="${COLORS.text.tertiary}" text-anchor="middle">${escapeXml(fallbackText)}</text>
  `}
</g>`;
}

export function createVerifiedBadge(isVerified: boolean): string {
  if (!isVerified) return '';

  return `
<!-- Verified Badge - Below "Powered by Govex" -->
<g transform="translate(${OG_IMAGE_DIMENSIONS.width - 280}, 100)">
  <rect x="0" y="0" width="220" height="50" rx="25" fill="url(#verifiedBg)" stroke="${COLORS.accent.blueDark}" stroke-width="2" filter="url(#cardShadow)"/>
  <text x="110" y="32" font-family="Arial, Helvetica, sans-serif" font-size="20" font-weight="700" fill="${COLORS.accent.blue}" text-anchor="middle">✓ VERIFIED DAO</text>
</g>`;
}

export function createBranding(): string {
  return `
<text x="${OG_IMAGE_DIMENSIONS.width - 300}" y="60" font-family="Arial, Helvetica, sans-serif" font-size="30" fill="${COLORS.text.quaternary}" opacity="1">Powered by Govex</text>`;
}

// Main DAO SVG Generator
export function generateDaoSvg(params: DaoOgParams): string {
  const { name, description, logo, proposalCount, hasLiveProposal, isVerified } = params;

  return `
<svg width="${OG_IMAGE_DIMENSIONS.width}" height="${OG_IMAGE_DIMENSIONS.height}" viewBox="0 0 ${OG_IMAGE_DIMENSIONS.width} ${OG_IMAGE_DIMENSIONS.height}" xmlns="http://www.w3.org/2000/svg">
  ${svgDefs}
  
  <!-- Background -->
  <rect width="${OG_IMAGE_DIMENSIONS.width}" height="${OG_IMAGE_DIMENSIONS.height}" fill="url(#bg)"/>

  <!-- Header Section -->
  <g transform="translate(60, 80)">
    ${createDaoLogo(logo, name)}
    ${createDaoMainContent(name, description)}
  </g>
   
  ${createStatsCards(proposalCount, hasLiveProposal)}
  ${createVerifiedBadge(isVerified)}
  ${createBranding()}
</svg>`;
}

// Proposal SVG Generator (simplified structure)
export async function generateProposalOG(params: ProposalOgParams): Promise<string> {
  let {
    title,
    daoName,
    daoLogo,
    currentState,
    winningOutcome,
    outcomeMessages,
    trades = 0,
    volume = 0,
    tradingStartDate,
    tradingPeriodMs
  } = params;

  // Debug log to confirm volume is received
  console.log(`[DEBUG] generateProposalOG received - volume: ${volume}, trades: ${trades}`);

  const { width, height } = OG_IMAGE_DIMENSIONS;

  // Sanitize and limit description
  const sanitizeText = (text: string) => {
    return text
      .replace(/[^\x20-\x7E]/g, '') // Remove non-printable characters
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .slice(0, 500); // Limit length
  };

  title = title ? sanitizeText(title) : 'No title provided';
  const { lines: titleLines, fontSize: titleFontSize } = wrapText(title, width - 96, 103, { maxHeight: height - 252 });
  // ONLY use cached image - no external URL fetching
  let daoImage = null;
  console.log(daoLogo)
  if (daoLogo && daoLogo !== "placeholder" && daoLogo.startsWith('/dao-images/')) {
    try {
      console.log(daoLogo)
      const imagePath = path.join(process.cwd(), 'public', daoLogo.substring(1));
      const imageBuffer = await fs.readFile(imagePath);
      daoImage = `data:image/png;base64,${imageBuffer.toString('base64')}`;
      console.log(daoImage)
    } catch (err) {
      console.log(err)
      logSecurityError('readCachedProposalImage', err);
    }
  }

  // Create outcome tag if needed
  const createOutcomeSection = () => {
    if (currentState === 0) return '';
    const isRejected = currentState === 2 && winningOutcome === 0;

    // Get base outcome text
    let outcomeText = outcomeMessages?.[winningOutcome || 0] || 'Unknown';

    // Add suffixes for binary outcomes (only 2 outcomes)
    if (outcomeMessages && outcomeMessages.length === 2 && outcomeText !== 'Unknown') {
      if (currentState === 2) outcomeText += 'ed';
      else if (currentState === 1) outcomeText += 'ing';
    }

    const bgColor = isRejected ? COLORS.accent.red :
      currentState === 1 ? COLORS.accent.blueDark : COLORS.accent.greenDark;

    // Calculate width based on text length with minimum width
    const minWidth = 120; // Minimum width to prevent collapse
    const textWidth = Math.max(outcomeText.length * 18 + 64, minWidth);
    const height = 56;

    return `
  <g transform="translate(${width - textWidth - 40},32)">
    <!-- Tag background -->
    <rect 
      x="0" 
      y="0" 
      width="${textWidth}" 
      height="${height}" 
      rx="16" 
      fill="${bgColor}50" 
      stroke="${bgColor}"
      stroke-width="2"
      filter="url(#cardShadow)"
    />
  
    <!-- Outcome text -->
    <text 
      x="${textWidth / 2}" 
      y="${height / 2 + 2}" 
      font-family="Arial, Helvetica, sans-serif" 
      font-size="32" 
      font-weight="600" 
      fill="${COLORS.text.primary}" 
      text-anchor="middle"
      dominant-baseline="middle"
      letter-spacing="0.02em"
    >${escapeXml(outcomeText)}</text>

    ${currentState === 1 ? `
    <!-- Pulsing animation for live state -->
    <rect 
      x="0" 
      y="0" 
      width="${textWidth}" 
      height="${height}" 
      rx="16" 
      fill="${bgColor}" 
      opacity="0.7"
    >
      <animate attributeName="opacity" values="0.7;0.3;0.7" dur="2s" repeatCount="indefinite"/>
    </rect>
    ` : ''}
  </g>`;
  };

  const createStatsSection = () => {
    const cardWidth = 358;
    const cardHeight = 140;
    const cardSpacing = 390;
    const statsY = height - cardHeight - 32; // Position from bottom

    if (currentState === 0) {
      return createInfoCard({
        x: 32,
        y: statsY,
        width: 1136,
        height: cardHeight,
        title: 'TRADING STARTS',
        value: tradingStartDate.toLocaleDateString('en-US', { month: 'short', day: 'numeric', year: 'numeric' }),
        subtitle: '',
        color: COLORS.text.primary
      });
    }

    return `
<g transform="translate(32, 0)">
  ${createInfoCard({
      x: 0,
      y: statsY,
      width: cardWidth,
      height: cardHeight,
      title: currentState === 2 ? 'PROPOSAL ENDED' : 'TRADING STARTED',
      value: currentState === 2
        ? new Date(tradingStartDate.getTime() + tradingPeriodMs).toLocaleDateString('en-US', { month: 'short', day: 'numeric', year: 'numeric' })
        : tradingStartDate.toLocaleDateString('en-US', { month: 'short', day: 'numeric', year: 'numeric' }),
      subtitle: '',
      color: COLORS.text.primary
    })}
  
  ${createInfoCard({
      x: cardSpacing,
      y: statsY,
      width: cardWidth,
      height: cardHeight,
      title: 'TOTAL TRADES',
      value: formatNumber(trades),
      subtitle: '',
      color: COLORS.text.primary
    })}
  
  ${createInfoCard({
      x: cardSpacing * 2,
      y: statsY,
      width: cardWidth,
      height: cardHeight,
      title: 'VOLUME',
      value: (() => {
        const formatted = "$" + formatNumber(volume);
        console.log(`[DEBUG] In SVG creation - raw volume: ${volume}, formatted: ${formatted}`);
        return formatted;
      })(),
      subtitle: '',
      color: COLORS.text.primary
    })}
</g>`;
  };

  const svg = `
<svg width="${width}" height="${height}" viewBox="0 0 ${width} ${height}" xmlns="http://www.w3.org/2000/svg">
  ${svgDefs}

  <!-- Background -->
  <rect width="${width}" height="${height}" fill="url(#bg)"/>

      <!-- DAO Avatar -->
  ${createAvatar({
    x: 56,
    y: 64,
    size: 40,
    image: daoImage,
    fallbackText: daoName.charAt(0),
    clipId: 'daoLogoClip',
    showGlow: true
  })}

  <!-- DAO Name -->
  <text x="110" y="75" font-family="Roboto, sans-serif" font-size="32" font-weight="600" fill="${COLORS.text.primary}" letter-spacing="0.02em">${escapeXml(daoName)}</text>

  <!-- Proposal Title -->
  ${titleLines.map((line, index) =>
    `<text x="32" width="${width - 96}" y="${200 + (index * (titleFontSize + 12))}" font-family="Arial, Helvetica, sans-serif" font-size="${titleFontSize}" font-weight="700" fill="${COLORS.text.primary}" letter-spacing="-0.02em">${escapeXml(line)}</text>`
  ).join('')}

  ${createOutcomeSection()}
  ${createStatsSection()}
  <!-- DEBUG: volume=${volume} -->
</svg>`;

  console.log(`[DEBUG] FINAL SVG about to be returned - volume in SVG comment: ${volume}`);
  console.log(`[DEBUG] SVG stats section includes: ${svg.includes('VOLUME')}`);

  return svg;
}

// General Govex/Futarchy OG Image Generator
export async function generateGeneralOG(): Promise<string> {
  const { width, height } = OG_IMAGE_DIMENSIONS;

  const description = "Where prediction markets drive decision-making through futarchy governance";
  const { lines: descLines, fontSize: descFontSize } = wrapText(
    description,
    width - 400,
    40,
    { maxHeight: 200 }
  );

  // Use a hardcoded base64 logo or cached version for Govex
  // This avoids any external fetches
  const govexLogo = null; // Will use fallback letter 'G' in SVG

  return `
<svg width="${width}" height="${height}" viewBox="0 0 ${width} ${height}" xmlns="http://www.w3.org/2000/svg">
  ${svgDefs}
  
  <!-- Clean background with subtle gradient -->
  <rect width="${width}" height="${height}" fill="url(#bg)"/>
  
  <!-- Subtle geometric accents -->
  <g opacity="0.08">
    <circle cx="150" cy="120" r="80" fill="none" stroke="${COLORS.accent.blue}" stroke-width="1"/>
    <circle cx="${width - 150}" cy="${height - 120}" r="60" fill="none" stroke="${COLORS.accent.blue}" stroke-width="1"/>
    <polygon points="100,${height - 100} 200,${height - 200} 300,${height - 100}" fill="none" stroke="${COLORS.accent.blue}" stroke-width="1"/>
  </g>
  
  <!-- Futuristic grid pattern -->
  <defs>
    <pattern id="futuristicGrid" patternUnits="userSpaceOnUse" width="60" height="60">
      <path d="M 60 0 L 0 0 0 60" fill="none" stroke="rgba(96, 165, 250, 0.06)" stroke-width="1"/>
      <circle cx="0" cy="0" r="1" fill="rgba(96, 165, 250, 0.1)"/>
    </pattern>
  </defs>
  <rect width="${width}" height="${height}" fill="url(#futuristicGrid)" opacity="0.7"/>
  
  <!-- Optimized hero layout -->
  <g transform="translate(100, 120)">
    <!-- Logo section -->
    <g transform="translate(120, 120)">
      <!-- Outer glow ring -->
      <circle cx="0" cy="0" r="90" fill="none" stroke="url(#logoRing)" stroke-width="4" opacity="0.6" filter="url(#glow)"/>
      <circle cx="0" cy="0" r="82" fill="url(#logoRing)" opacity="0.1"/>
      
      <!-- Logo background -->
      <circle cx="0" cy="0" r="75" fill="${COLORS.background.primary}" stroke="${COLORS.accent.blue}" stroke-width="2" opacity="0.95"/>
      
      <!-- Govex Logo -->
      <clipPath id="logoClipGeneral">
        <circle cx="0" cy="0" r="68" />
      </clipPath>
      ${govexLogo ? `<image href="${govexLogo}" x="-68" y="-68" width="136" height="136" preserveAspectRatio="xMidYMid slice" clip-path="url(#logoClipGeneral)" />` : `<text x="0" y="15" font-family="Arial, Helvetica, sans-serif" font-size="68" font-weight="800" fill="${COLORS.accent.blue}" text-anchor="middle" filter="url(#glow)">G</text>`}
      
      <!-- Subtle orbit lines -->
      <circle cx="0" cy="0" r="110" fill="none" stroke="${COLORS.accent.blue}" stroke-width="1" opacity="0.3" stroke-dasharray="4,8"/>
    </g>
    
    <!-- Content section - right aligned -->
    <g transform="translate(320, 60)">
      <!-- Brand name -->
      <text x="0" y="20" font-family="Arial, Helvetica, sans-serif" font-size="110" font-weight="800" fill="${COLORS.text.primary}" letter-spacing="-0.02em" filter="url(#glow)">Govex</text>
      
      <!-- Tagline -->
      <text x="0" y="80" font-family="Arial, Helvetica, sans-serif" font-size="52" font-weight="500" fill="${COLORS.accent.blue}" letter-spacing="0.04em" opacity="0.9">DAO governance on SUI</text>
      
      <!-- Description -->
      <g transform="translate(0, 160)">
        ${descLines.map((line, index) =>
    `<text x="0" y="${index * (descFontSize + 12)}" font-family="Arial, Helvetica, sans-serif" font-size="${descFontSize}" font-weight="400" fill="${COLORS.text.secondary}" opacity="0.8" letter-spacing="0.01em">${line}</text>`
  ).join('')}
      </g>
    </g>
  </g>
  
  <!-- Info strip -->
  <g transform="translate(0, ${height - 140})">
    <!-- Background strip -->
    <rect x="0" y="0" width="${width}" height="140" fill="rgba(30, 41, 59, 0.4)" opacity="0.9"/>
    <rect x="0" y="0" width="${width}" height="3" fill="${COLORS.accent.blue}" opacity="0.6"/>
    
    <!-- Feature items with balanced positioning -->
    <g transform="translate(240, 40)">
      <text x="0" y="35" font-family="Arial, Helvetica, sans-serif" font-size="36" font-weight="700" fill="${COLORS.text.primary}" text-anchor="middle">Prediction Markets</text>
    </g>
    
    <g transform="translate(${width / 2}, 40)">
      <text x="0" y="35" font-family="Arial, Helvetica, sans-serif" font-size="36" font-weight="700" fill="${COLORS.text.primary}" text-anchor="middle">Built on SUI</text>
    </g>
    
    <g transform="translate(960, 40)">
      <text x="0" y="35" font-family="Arial, Helvetica, sans-serif" font-size="36" font-weight="700" fill="${COLORS.text.primary}" text-anchor="middle">Multiple Outcomes</text>
    </g>
  </g>
  </svg>`;
}
