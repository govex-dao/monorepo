
import { logSecurityError, escapeXml } from './security';
import path from 'path';
import fs from 'fs/promises';

// Constants
export const OG_IMAGE_DIMENSIONS = {
  width: 1200,
  height: 630,
} as const;

export const FONT_CONFIG = {
  minSize: 24,
  defaultSize: 48,
  titleSize: 72,
  stepSize: 4,
  coeff: 0.50,
  lineSpacing: 6,
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
  daoName: string;
  daoLogo: string;
  currentState: number;
  winningOutcome?: number | null;
  outcomeMessages: string[] | undefined;
  traders?: number;
  trades?: number;
  tradingStartDate: Date;
  tradingPeriodMs: number
}

// Utility Functions
export function wrapText(
  text: string,
  maxWidth: number = 400,
  fontSize: number = FONT_CONFIG.defaultSize,
  maxHeight: number = 180
): TextWrapResult {
  let currentFontSize = fontSize;
  let lines: string[] = [];
  let totalHeight = 0;

  while (currentFontSize >= FONT_CONFIG.minSize) {
    const words = text.split(' ');
    lines = [];
    let currentLine = '';

    for (const word of words) {
      const testLine = currentLine ? `${currentLine} ${word}` : word;
      const estimatedWidth = testLine.length * currentFontSize * FONT_CONFIG.coeff;

      if (estimatedWidth <= maxWidth) {
        currentLine = testLine;
      } else {
        if (currentLine) {
          lines.push(currentLine);
          currentLine = word;
        } else {
          const maxChars = Math.floor(maxWidth / (currentFontSize * FONT_CONFIG.coeff));
          lines.push(word.substring(0, maxChars) + '...');
          break;
        }
      }
    }

    if (currentLine) {
      lines.push(currentLine);
    }

    totalHeight = lines.length * currentFontSize + (lines.length - 1) * FONT_CONFIG.lineSpacing;

    if (totalHeight <= maxHeight) {
      break;
    }

    currentFontSize -= FONT_CONFIG.stepSize;
  }

  // Truncate if still too tall
  const lineHeight = currentFontSize + FONT_CONFIG.lineSpacing;
  const maxLines = Math.floor((maxHeight + FONT_CONFIG.lineSpacing) / lineHeight);

  if (lines.length > maxLines) {
    lines = lines.slice(0, maxLines);
    if (lines.length > 0) {
      lines[lines.length - 1] += '...';
    }
  }

  return { lines, fontSize: currentFontSize, totalHeight };
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
    650, 28, 100
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
  <rect x="0" y="0" width="${width}" height="${height}" rx="24" fill="${bgColor}" stroke="${COLORS.background.quaternary}" stroke-width="2" filter="url(#cardShadow)"/>
  <rect x="2" y="2" width="${width - 4}" height="${height - 4}" rx="22" fill="none" stroke="rgba(148, 163, 184, 0.08)" stroke-width="1"/>
  ${animated ? `
  <circle cx="40" cy="45" r="8" fill="${color}">
    <animate attributeName="opacity" values="1;0.3;1" dur="2s" repeatCount="indefinite"/>
  </circle>
  <text x="70" y="52" font-family="Roboto, sans-serif" font-size="20" fill="${color}" font-weight="600" letter-spacing="0.1em">${title}</text>
  ` : `
  <text x="30" y="45" font-family="Roboto, sans-serif" font-size="20" fill="${COLORS.text.tertiary}" font-weight="500" letter-spacing="0.1em">${title}</text>
  `}
  <text x="30" y="100" font-family="Roboto, sans-serif" font-size="${value.length > 8 ? '36' : '48'}" font-weight="700" fill="${color}" letter-spacing="-0.01em">${value}</text>
  <text x="30" y="130" font-family="Roboto, sans-serif" font-size="16" fill="${COLORS.text.quaternary}" opacity="0.8">${subtitle}</text>
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
        value: 'Active Now',
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
        value: 'No Active Proposal',
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
<!-- Verified Badge - Top Right -->
<g transform="translate(${OG_IMAGE_DIMENSIONS.width - 280}, 40)">
  <rect x="0" y="0" width="220" height="50" rx="25" fill="url(#verifiedBg)" stroke="${COLORS.accent.blueDark}" stroke-width="2" filter="url(#cardShadow)"/>
  <text x="110" y="32" font-family="Roboto, sans-serif" font-size="20" font-weight="700" fill="${COLORS.accent.blue}" text-anchor="middle">✓ VERIFIED DAO</text>
</g>`;
}

export function createBranding(): string {
  return `
<text x="${OG_IMAGE_DIMENSIONS.width - 290}" y="${OG_IMAGE_DIMENSIONS.height - 30}" font-family="Roboto, sans-serif" font-size="30" fill="${COLORS.text.quaternary}" opacity="1">Powered by Govex</text>`;
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
    traders = 0,
    trades = 0,
    tradingStartDate,
    tradingPeriodMs
  } = params;

  const { width, height } = OG_IMAGE_DIMENSIONS;
  const { lines: titleLines, fontSize: titleFontSize, totalHeight } = wrapText(title, width - 96, FONT_CONFIG.titleSize, 200);

  // Get status information
  const getStatusInfo = (state: number) => {
    switch (state) {
      case 2: return { text: 'Finalized', color: COLORS.accent.green };
      case 1: return { text: 'Trading', color: COLORS.accent.blue };
      case 0: return { text: 'Pending', color: COLORS.text.tertiary };
      default: return { text: 'Unknown', color: COLORS.text.tertiary };
    }
  };

  const statusInfo = getStatusInfo(currentState);
  // ONLY use cached image - no external URL fetching
  let daoImage = null;
  if (daoLogo && daoLogo !== "placeholder" && daoLogo.startsWith('/dao-images/')) {
    try {
      const imagePath = path.join(process.cwd(), 'public', daoLogo.substring(1));
      const imageBuffer = await fs.readFile(imagePath);
      daoImage = `data:image/png;base64,${imageBuffer.toString('base64')}`;
    } catch (err) {
      logSecurityError('readCachedProposalImage', err);
    }
  }

  // Create outcome section if needed
  const createOutcomeSection = () => {
    if (currentState === 0) return '';

    const isRejected = currentState === 2 && winningOutcome === 0;
    const outcomeColor = isRejected ? COLORS.accent.red : statusInfo.color;

    // Get base outcome text
    let outcomeText = outcomeMessages?.[winningOutcome || 0] || 'Unknown';

    // Add suffixes for binary outcomes (only 2 outcomes)
    if (outcomeMessages && outcomeMessages.length === 2 && outcomeText !== 'Unknown') {
      if (currentState === 2) outcomeText += 'ed';
      else if (currentState === 1) outcomeText += 'ing';
    }

    const bgColor = isRejected ? 'rgba(239, 68, 68, 0.25)' :
      currentState === 1 ? 'rgba(96, 165, 250, 0.25)' : 'rgba(16, 185, 129, 0.25)';
    const borderColor = isRejected ? COLORS.accent.red :
      currentState === 1 ? COLORS.accent.blue : COLORS.accent.green;

    return `
<g transform="translate(32, ${180 + totalHeight})">
  <!-- Gradient background overlay -->
  <defs>
    <linearGradient id="outcomeGradient${currentState}" x1="0%" y1="0%" x2="100%" y2="100%">
      <stop offset="0%" style="stop-color:${bgColor};stop-opacity:0.3" />
      <stop offset="50%" style="stop-color:${bgColor};stop-opacity:0.8" />
      <stop offset="100%" style="stop-color:${bgColor};stop-opacity:0.3" />
    </linearGradient>
  </defs>
  
  <!-- Main background with gradient -->
  <rect x="0" y="0" width="1136" height="80" rx="20" fill="url(#outcomeGradient${currentState})" stroke="${borderColor}30"  stroke-width="2" filter="url(#cardShadow)"/>
    
  <!-- Inner glow -->
  <rect x="3" y="3" width="1130" height="74" rx="17" fill="none" stroke="${borderColor}" stroke-width="1" opacity="0.2"/>
  
  <!-- Status prefix with different styling -->
  <text x="568" y="25" font-family="Roboto, sans-serif" font-size="16" font-weight="600" fill="${outcomeColor}" text-anchor="middle" letter-spacing="0.1em" opacity="0.8">
    ${currentState === 2 ? 'PROPOSAL FINALIZED' : 'CURRENTLY WINNING'}
  </text>
  
  <!-- Large outcome text with enhanced styling -->
  <text x="568" y="62" font-family="Roboto, sans-serif" font-size="42" font-weight="800" fill="${outcomeColor}" text-anchor="middle" letter-spacing="0.02em">
    ${escapeXml(outcomeText)}
  </text>
  
  ${currentState === 1 ? `
  <!-- Enhanced pulsing animation for live state -->
  <rect x="0" y="0" width="1136" height="80" rx="20" fill="none" stroke="${borderColor}" stroke-width="2" opacity="0.7">
    <animate attributeName="opacity" values="0.7;0.3;0.7" dur="2.5s" repeatCount="indefinite"/>
    <animate attributeName="stroke-width" values="2;4;2" dur="2.5s" repeatCount="indefinite"/>
  </rect>
  ` : `
  <!-- Static glow for finalized state -->
  <rect x="0" y="0" width="1136" height="80" rx="20" fill="none" stroke="${borderColor}" stroke-width="1" opacity="0.4"/>
  `}
</g>`;
  };

  const createStatsSection = () => {
    if (currentState === 0) {
      return createInfoCard({
        x: 32,
        y: 290 + totalHeight,
        width: 1136,
        height: 120,
        title: 'TRADING STARTS',
        value: tradingStartDate.toLocaleDateString('en-US', { month: 'short', day: 'numeric', year: 'numeric' }),
        subtitle: '',
        color: COLORS.text.primary
      });
    }

    const statsY = 280;
    const baseX = 32;
    const cardWidth = 358;
    const cardHeight = 140;
    const cardSpacing = 390;

    return `
<g transform="translate(${baseX}, ${totalHeight})">
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
      value: trades.toString(),
      subtitle: '',
      color: COLORS.text.primary
    })}
  
  ${createInfoCard({
      x: cardSpacing * 2,
      y: statsY,
      width: cardWidth,
      height: cardHeight,
      title: 'UNIQUE TRADERS',
      value: traders.toString(),
      subtitle: '',
      color: COLORS.text.primary
    })}
</g>`;
  };

  return `
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
    `<text x="32" y="${160 + (index * (titleFontSize + 12))}" font-family="Roboto, sans-serif" font-size="${titleFontSize}" font-weight="700" fill="${COLORS.text.primary}" letter-spacing="-0.02em">${escapeXml(line)}</text>`
  ).join('')}
  
  <!-- Status Badge -->
  ${currentState === 1 ? `
    <g>
    <circle cx="990" cy="75" r="16" fill="rgba(96,165,250,0.15)" stroke="${COLORS.accent.blue}" stroke-width="3" filter="url(#statusGlow)"/>
    <circle cx="990" cy="75" r="10" fill="${COLORS.accent.blue}">
      <animate attributeName="opacity" values="1;0.4;1" dur="2s" repeatCount="indefinite" />
    </circle>
    <text x="1030" y="83" font-family="Roboto, sans-serif" font-size="28" fill="${statusInfo.color}" font-weight="600" alignment-baseline="middle" letter-spacing="0.08em">${statusInfo.text}</text>
    </g>
    ` : ''}
  
  ${createOutcomeSection()}
  ${createStatsSection()}
  ${createBranding()}
</svg>`;
}

// General Govex/Futarchy OG Image Generator
export async function generateGeneralOG(): Promise<string> {
  const { width, height } = OG_IMAGE_DIMENSIONS;

  const description = "Where prediction markets drive decision-making through futarchy governance";
  const { lines: descLines, fontSize: descFontSize } = wrapText(
    description,
    width - 400,
    28,
    80
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
      ${govexLogo ? `<image href="${govexLogo}" x="-68" y="-68" width="136" height="136" preserveAspectRatio="xMidYMid slice" clip-path="url(#logoClipGeneral)" />` : `<text x="0" y="15" font-family="Roboto, sans-serif" font-size="68" font-weight="800" fill="${COLORS.accent.blue}" text-anchor="middle" filter="url(#glow)">G</text>`}
      
      <!-- Subtle orbit lines -->
      <circle cx="0" cy="0" r="110" fill="none" stroke="${COLORS.accent.blue}" stroke-width="1" opacity="0.3" stroke-dasharray="4,8"/>
    </g>
    
    <!-- Content section - right aligned -->
    <g transform="translate(320, 60)">
      <!-- Brand name -->
      <text x="0" y="60" font-family="Roboto, sans-serif" font-size="110" font-weight="800" fill="${COLORS.text.primary}" letter-spacing="-0.02em" filter="url(#glow)">Govex</text>
      
      <!-- Tagline -->
      <text x="0" y="120" font-family="Roboto, sans-serif" font-size="38" font-weight="500" fill="${COLORS.accent.blue}" letter-spacing="0.04em" opacity="0.9">Futarchy on Sui</text>
      
      <!-- Description -->
      <g transform="translate(0, 160)">
        ${descLines.map((line, index) =>
    `<text x="0" y="${index * (descFontSize + 12)}" font-family="Roboto, sans-serif" font-size="${descFontSize}" font-weight="400" fill="${COLORS.text.secondary}" opacity="0.8" letter-spacing="0.01em">${line}</text>`
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
      <text x="0" y="35" font-family="Roboto, sans-serif" font-size="36" font-weight="700" fill="${COLORS.text.primary}" text-anchor="middle">Prediction Markets</text>
      <text x="0" y="65" font-family="Roboto, sans-serif" font-size="22" font-weight="400" fill="${COLORS.text.tertiary}" opacity="0.9" text-anchor="middle">Futarchy governance</text>
    </g>
    
    <g transform="translate(${width / 2}, 40)">
      <text x="0" y="35" font-family="Roboto, sans-serif" font-size="36" font-weight="700" fill="${COLORS.text.primary}" text-anchor="middle">Sui Blockchain</text>
      <text x="0" y="65" font-family="Roboto, sans-serif" font-size="22" font-weight="400" fill="${COLORS.text.tertiary}" opacity="0.9" text-anchor="middle">Fast transactions</text>
    </g>
    
    <g transform="translate(960, 40)">
      <text x="0" y="35" font-family="Roboto, sans-serif" font-size="36" font-weight="700" fill="${COLORS.text.primary}" text-anchor="middle">Multiple Outcomes</text>
      <text x="0" y="65" font-family="Roboto, sans-serif" font-size="22" font-weight="400" fill="${COLORS.text.tertiary}" opacity="0.9" text-anchor="middle">Complex decisions</text>
    </g>
  </g>
  </svg>`;
}
