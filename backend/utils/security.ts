import { URL } from 'url';

// Allowed image hosting domains
const ALLOWED_IMAGE_DOMAINS = [
  'raw.githubusercontent.com',
  'github.com',
  'avatars.githubusercontent.com',
  'ipfs.io',
  'gateway.pinata.cloud',
  'cloudflare-ipfs.com',
  'imgur.com',
  'i.imgur.com',
  // Add more trusted domains as needed
];

// Blocked protocols and patterns
const BLOCKED_PROTOCOLS = ['file:', 'ftp:', 'gopher:', 'data:', 'javascript:', 'vbscript:'];
const PRIVATE_IP_RANGES = [
  /^127\./,                    // Loopback
  /^10\./,                     // Private network
  /^172\.(1[6-9]|2[0-9]|3[0-1])\./, // Private network
  /^192\.168\./,               // Private network
  /^169\.254\./,               // Link-local
  /^::1$/,                     // IPv6 loopback
  /^fe80:/i,                   // IPv6 link-local
  /^fc00:/i,                   // IPv6 private
  /^fd00:/i,                   // IPv6 private
];

// Cloud metadata endpoints to block
const BLOCKED_METADATA_URLS = [
  '169.254.169.254',           // AWS metadata
  'metadata.google.internal',   // GCP metadata
  'metadata.azure.com',         // Azure metadata
  'metadata',                   // Generic metadata
];

export interface ValidationResult {
  isValid: boolean;
  error?: string;
}

/**
 * Validates if a URL is safe to fetch
 */
export function validateImageUrl(urlString: string): ValidationResult {
  try {
    const url = new URL(urlString);

    // Check protocol
    if (!['http:', 'https:'].includes(url.protocol)) {
      return { isValid: false, error: `Invalid protocol: ${url.protocol}` };
    }

    // Block dangerous protocols
    if (BLOCKED_PROTOCOLS.includes(url.protocol)) {
      return { isValid: false, error: `Blocked protocol: ${url.protocol}` };
    }

    // Check for localhost and similar
    const hostname = url.hostname.toLowerCase();
    if (['localhost', '0.0.0.0', '127.0.0.1', '::1'].includes(hostname)) {
      return { isValid: false, error: 'Localhost access is not allowed' };
    }

    // Check for private IP ranges
    const ipMatch = hostname.match(/^(\d{1,3}\.){3}\d{1,3}$/);
    if (ipMatch) {
      for (const range of PRIVATE_IP_RANGES) {
        if (range.test(hostname)) {
          return { isValid: false, error: 'Private IP addresses are not allowed' };
        }
      }
    }

    // Check for metadata endpoints
    if (BLOCKED_METADATA_URLS.includes(hostname)) {
      return { isValid: false, error: 'Cloud metadata endpoints are not allowed' };
    }

    // Check against allowlist
    if (!ALLOWED_IMAGE_DOMAINS.includes(hostname)) {
      return { isValid: false, error: `Domain not in allowlist: ${hostname}` };
    }

    return { isValid: true };
  } catch (error) {
    return { isValid: false, error: 'Invalid URL format' };
  }
}

/**
 * Escapes HTML/XML special characters to prevent XSS in SVG
 */
export function escapeXml(unsafe: string): string {
  return unsafe
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#x27;')
    .replace(/\//g, '&#x2F;');
}

/**
 * Validates content type is an allowed image format
 */
export function validateImageContentType(contentType: string | null): boolean {
  if (!contentType) return false;
  
  const allowedTypes = [
    'image/jpeg',
    'image/jpg',
    'image/png',
    'image/gif',
    'image/webp',
    'image/svg+xml',
  ];
  
  return allowedTypes.includes(contentType.toLowerCase());
}

/**
 * Validates ID format (alphanumeric with dashes/underscores)
 */
export function validateId(id: string): boolean {
  // Allow alphanumeric, dashes, underscores, max 100 chars
  const idRegex = /^[a-zA-Z0-9_-]{1,100}$/;
  return idRegex.test(id);
}

/**
 * Structured error logging that doesn't leak sensitive info
 */
export function logSecurityError(context: string, error: any): void {
  console.error(`[Security] ${context}:`, {
    message: error?.message || 'Unknown error',
    timestamp: new Date().toISOString(),
    // Don't log stack traces or sensitive details
  });
}