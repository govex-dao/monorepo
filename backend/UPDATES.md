# Updates to Dynamic OG Image Generation

## Overview
This document summarizes all security fixes and caching improvements applied to the dynamic OG image generation feature introduced in commit `49841d03a1374d1af7447f774fe42f0d3094be9b`.

## Critical Security Fixes

### 1. **SSRF (Server-Side Request Forgery) - ELIMINATED**
- **Problem**: `fetchAndEncodeImage()` fetched arbitrary URLs from `dao.icon_url` 
- **Solution**: Removed ALL external URL fetching from OG generation
- **Impact**: OG images now ONLY use pre-cached images from filesystem

### 2. **Rate Limiting - ADDED**
- **Problem**: No limits on OG image requests (DoS vulnerability)
- **Solution**: Applied express-rate-limit: 50 requests/15 min/IP
- **File**: `server/index.ts`

### 3. **Input Validation & Sanitization - ADDED**
- **Problem**: Unvalidated route params, raw user input in SVG
- **Solution**: 
  - Route parameter validation (alphanumeric + dash/underscore)
  - XML escaping for all user content in SVGs
- **Files**: `utils/security.ts` (new), `server/routes/og.ts`

## Image Caching Improvements

### Multi-Size Caching
- **Before**: Only cached 64x64 images
- **After**: Cache 3 sizes: 64x64, 256x256, 512x512
- **Benefit**: OG images use 512x512 for better quality. 256 for DAO page later?

### Database Schema Changes
```prisma
model Dao {
  icon_cache_path String?      // 64x64 (existing)
  icon_cache_medium String?    // 256x256 (NEW)
  icon_cache_large String?     // 512x512 (NEW)
}
```

## Breaking Changes

⚠️ **IMPORTANT**: OG images will ONLY work for DAOs with cached images
- No fallback to `icon_url` 
- If `icon_cache_large` is missing, placeholder is used
- This is intentional for security (prevents SSRF)

## Files Changed

1. **New Files**:
   - `utils/security.ts` - Security validation functions

2. **Modified Files**:
   - `server/routes/og.ts` - No external fetching, only cached images
   - `utils/dynamic-image.ts` - Removed `fetchAndEncodeImage()`, added sanitization
   - `server/index.ts` - Added rate limiting middleware
   - `prisma/schema.prisma` - Added cache fields

3. **Removed Functions**:
   - `fetchAndEncodeImage()` - Completely removed from OG generation

## Required Actions

1. **Run Migration**:
   ```bash
   npx prisma migrate dev --name add-multiple-image-cache-sizes
   ```

2. **Optional**: Generate larger sizes for existing DAOs
   - Current DAOs only have 64x64 cached
   - May want to regenerate with new sizes

## Security Summary

| Vulnerability | Status | Solution |
|--------------|--------|----------|
| SSRF | ✅ FIXED | No external URL fetching |
| DoS | ✅ FIXED | Rate limiting added |
| XSS in SVG | ✅ FIXED | Input sanitization |
| Info Leakage | ✅ FIXED | Generic error messages |
| Input Validation | ✅ FIXED | ID format validation |

## Performance Notes

- Current implementation (reading cached files) is efficient for your use case
- OS file caching handles frequently accessed images
- No additional caching layer needed given paid DAO model