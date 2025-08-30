# Image Service Refactoring

## Overview
This refactoring centralizes all image handling logic into a secure, maintainable service architecture that generates multiple image sizes from a single remote fetch.

## Problems Solved

### 1. **Critical Security Vulnerability**
- **Before**: `daoHandler.ts` accepted both HTTP and HTTPS URLs, creating a security hole
- **After**: All URLs must be HTTPS, enforced through centralized validation in `security.ts`

### 2. **Code Duplication & Maintenance Issues**
- **Before**: 200+ lines of image handling code duplicated in `daoHandler.ts`
- **After**: Clean separation of concerns with dedicated service modules

### 3. **Inefficient Multi-Size Generation**
- **Before**: Only generated 64x64 icons
- **After**: Generates all 3 required sizes (64x64, 256x256, 512x512) from a single fetch

## Architecture Changes

### New Files Created

#### 1. `services/ImageProcessor.ts`
- Flexible image processing with configurable dimensions
- Supports both PNG and JPEG output formats
- Handles 'contain' vs 'cover' resize strategies
- Prevents decompression bombs with input limits

#### 2. `services/ImageService.ts`
- Central orchestrator for all image operations
- Single `fetchAndCacheAllVersions()` method that:
  - Fetches image ONCE from remote server
  - Validates URL, content-type, and size
  - Generates all 3 sizes from single buffer
  - Saves to disk with consistent naming pattern
- Returns structured paths for all versions

### Modified Files

#### 1. `utils/security.ts`
- **Critical Fix**: Enforces HTTPS-only for all image URLs
- Added `validateImageSize()` helper function
- Improved content-type validation with proper MIME parsing
- Now the single source of truth for all security validation

#### 2. `indexer/dao-handler.ts`
- Removed 200+ lines of complex image handling code
- Replaced with single clean call: `imageService.fetchAndCacheAllVersions()`
- Now stores all 3 image paths in database:
  - `icon_cache_path`: 64x64 PNG
  - `icon_cache_medium`: 256x256 JPEG
  - `icon_cache_large`: 512x512 JPEG

## Image Sizes & Usage

### Database Schema (No Changes Needed)
```prisma
icon_cache_path String?    // 64x64 - Used in app UI
icon_cache_medium String?  // 256x256 - Ready for future use
icon_cache_large String?   // 512x512 - Used for OG images
```

### Current Usage
- **64x64 (`icon_cache_path`)**: All frontend UI components
- **256x256 (`icon_cache_medium`)**: Currently unused, ready for larger displays
- **512x512 (`icon_cache_large`)**: OG image generation (embedded in 1200x630 canvas)

## Performance Improvements

### Single Remote Fetch
The system now fetches each remote image **only once** and generates all sizes from that single fetch:

```typescript
// One fetch, three outputs
const response = await fetch(url);  // Only happens once!
const buffer = Buffer.from(await response.arrayBuffer());

// Generate all versions from same buffer
for (const [version, options] of IMAGE_VERSIONS) {
  const processed = await processImage(buffer, options);
  // Save each version...
}
```

### File Naming Convention
Files use a consistent pattern for easy identification:
- Pattern: `{dao_id}-{hash}-{version}.{format}`
- Example: `dao-123-a23cc84338cb-icon.png`
- The hash remains consistent across all versions

## Security Improvements

1. **HTTPS Enforcement**: No more HTTP URLs accepted
2. **Centralized Validation**: All security checks in one place
3. **No External Fetching in OG**: OG routes only use cached images
4. **Content-Type Validation**: Properly parses and validates MIME types
5. **Size Limits**: 10MB max file size enforced
6. **Input Sanitization**: Protects against decompression bombs

## Testing

The refactoring has been tested with:
- TypeScript compilation ✅
- Module loading verification ✅
- Multi-version generation ✅
- File size verification ✅
- Security validation ✅

### Test Results
```
✅ All modules loaded successfully
✅ HTTPS-only validation working
✅ Content-type validation working
✅ Size validation working
✅ Generated: 64x64 PNG (0.46 KB)
✅ Generated: 256x256 JPEG (2.92 KB)
✅ Generated: 512x512 JPEG (14.38 KB)
```

## Migration Notes

No database migration required! The schema already had all necessary fields:
- `icon_cache_path` (existing)
- `icon_cache_medium` (existing but unused)
- `icon_cache_large` (existing but unused)

This refactoring simply populates all three fields properly.

## Benefits Summary

1. **Security**: Fixed critical HTTP vulnerability
2. **Maintainability**: 200+ lines reduced to 1 service call
3. **Performance**: Single fetch for all sizes
4. **Scalability**: Easy to add new sizes or formats
5. **Testability**: Each component can be tested in isolation
6. **Reusability**: Image processing logic now available everywhere

## Future Enhancements

1. **Use 256x256 images** for medium-sized displays in the app
2. **Add WebP support** for better compression
3. **Implement responsive images** using srcset
4. **Add image optimization** pipeline for production
5. **Consider CDN integration** for cached images

## Code Quality Metrics

- **Lines removed**: ~200 from daoHandler.ts
- **Duplication eliminated**: 100%
- **Security vulnerabilities fixed**: 1 critical
- **New test coverage**: All core functions testable
- **Separation of concerns**: Complete

---

*This refactoring follows SOLID principles and creates a foundation for scalable image handling across the entire platform.*