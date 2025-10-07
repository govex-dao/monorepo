/**
 * Validates image sources to prevent XSS attacks (CWE-79)
 *
 * @param src - The image source to validate
 * @returns The validated source or null if invalid
 */
export function validateImageSource(src: string | null | undefined): string | null {
  if (!src) return null;

  const trimmedSrc = src.trim();

  // Allow data URLs for base64 images (common for our cached images)
  if (trimmedSrc.startsWith('data:image/')) {
    return trimmedSrc;
  }

  // Allow HTTP/HTTPS URLs only
  if (trimmedSrc.startsWith('https://') || trimmedSrc.startsWith('http://')) {
    try {
      // Validate it's a proper URL
      new URL(trimmedSrc);
      return trimmedSrc;
    } catch {
      // Invalid URL
      return null;
    }
  }

  // Allow relative paths (for local assets)
  if (trimmedSrc.startsWith('/')) {
    // Prevent path traversal
    if (trimmedSrc.includes('..')) {
      return null;
    }
    return trimmedSrc;
  }

  // Reject javascript:, data:text, and other dangerous protocols
  return null;
}

/**
 * React-safe image src prop validator
 * Returns a safe src or a fallback transparent pixel
 */
export function getSafeImageSrc(src: string | null | undefined): string {
  const validated = validateImageSource(src);
  if (validated) return validated;

  // Return transparent 1x1 pixel as fallback
  return 'data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7';
}
