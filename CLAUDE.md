# Vite to Next.js Migration Plan for Dynamic OG Cards

## Current Progress (As of Phase 4 Completion)

### ✅ Completed Phases

#### Phase 1: Foundation Setup ✅
- Updated package.json with all dependencies from Vite project
- Configured next.config.ts with environment variables
- Ported styles and assets
- Created Tailwind configuration
- Added constants file with all necessary properties
- **Status**: Build successful, deployed to Railway

#### Phase 2: Component Migration ✅  
- Copied all components maintaining folder structure
- Updated imports from `@/` to relative paths
- Replaced react-router-dom with Next.js navigation
- Added "use client" directives where needed
- Fixed TypeScript errors (BigInt support, React 19 compatibility)
- **Status**: All components working, build successful

#### Phase 3: Dynamic Routes ✅
- Created dynamic route folders: `/dao/[daoId]` and `/trade/[proposalId]`
- Implemented page components with Suspense boundaries
- Fixed styling issues:
  - Removed duplicate Theme wrapper
  - Added dark background to body
  - Downgraded to Tailwind CSS v3 for compatibility
  - Fixed footer positioning with flex layout
- **Status**: Dynamic routes tested and working

#### Phase 4: Metadata & SEO ✅
- Implemented comprehensive default metadata in root layout
- Created generateMetadata functions for all pages:
  - Static metadata for create and learn pages
  - Dynamic metadata for DAO and proposal pages (fetches data server-side)
- Added structured data (JSON-LD) for all pages:
  - WebApplication schema for root
  - EducationalOrganization schema for learn page  
  - Organization schema for DAO pages
  - Article schema for proposal pages
- Fixed Next.js 15 async params compatibility
- Separated viewport configuration per Next.js 15 requirements
- Fixed API endpoint configuration to handle URLs with/without trailing slashes
- **Status**: Build successful, deployed to Railway, proposals loading correctly

### 🚧 Remaining Phases

#### Phase 5: Dynamic OG Image Generation (Next)
- Create API routes for OG image generation
- Implement image generation matching current design
- Test social media previews

#### Phase 6: Data Fetching Optimization
- Convert to server components where possible
- Implement loading states
- Optimize parallel data loading

#### Phase 7: Final Migration
- Remove Vite dependencies
- Update deployment scripts
- Final testing

## Next Immediate Steps

1. **Implement generateMetadata functions**
   - Start with static pages (home, create, learn)
   - Then dynamic pages (dao, proposal)

2. **Create API routes for OG images**
   - `/api/og/dao/[id]/route.tsx`
   - `/api/og/proposal/[id]/route.tsx`

3. **Test metadata rendering**
   - Use browser dev tools
   - Test with social media debuggers

## Known Issues to Address

1. **Styling Differences**
   - Some Radix UI components may need theme adjustments
   - Ensure all dark mode styles match Vite app

2. **Data Fetching**
   - Currently all client-side with useQuery
   - Need to implement server-side fetching for metadata

3. **Environment Variables**
   - Ensure all NEXT_PUBLIC_ prefixed vars are set in Railway
   
## Environment Variables for Railway Deployment

Set these environment variables in your Railway project settings:

```env
NEXT_PUBLIC_API_URL=https://www.govex.ai/api
NEXT_PUBLIC_NETWORK=mainnet
NEXT_PUBLIC_APP_URL=https://govex.ai
```

Note: All environment variables that need to be accessible in the browser must be prefixed with `NEXT_PUBLIC_`.

## Deployment Notes

- Railway deployments working at each checkpoint
- Using pnpm for package management
- Tailwind CSS v3 (not v4) for compatibility
- React 19 RC with some component compatibility workarounds

## Overview
Migration plan to convert the current Vite frontend to Next.js 15 (App Router) with dynamic OG card generation, while maintaining working Railway deployments throughout the process.

## Key Requirements
- **Dynamic OG Cards**: Generate dynamic Open Graph images for DAOs and proposals
- **SEO Optimization**: Maintain and enhance current SEO setup with server-side rendering
- **Incremental Migration**: Deploy and test at checkpoints to avoid breaking changes
- **Railway Compatibility**: Ensure continuous deployment works on Railway

## Current State Analysis

### Vite Frontend
- **Tech Stack**: React 18.3.1 + TypeScript + Vite
- **Routing**: React Router DOM with 5 main routes
- **SEO**: Client-side with react-helmet-async
- **Dynamic OG**: API endpoints for OG images (`/og/dao/{id}`, `/og/proposal/{id}`)
- **Blockchain**: Sui integration with @mysten/dapp-kit

### Next.js Setup
- **Version**: Next.js 15.2.0 with App Router
- **Structure**: Basic setup with placeholder pages
- **Missing**: Dynamic routes, API routes, metadata configuration

## Migration Strategy

### Phase 1: Foundation Setup (Checkpoint 1)
**Goal**: Set up Next.js project structure and basic configuration

1. **Update Dependencies**
   - Keep existing Next.js 15 and React 19 RC
   - Add missing dependencies from Vite project:
     - `lightweight-charts`, `recharts`
     - `react-router-dom` types (for migration helpers)
     - Any missing UI components

2. **Configure Next.js**
   - Set up next.config.ts with:
     - Image optimization settings
     - Environment variables
     - API proxy configuration
   - Configure TypeScript paths

3. **Port Styles and Assets**
   - Copy all CSS from frontend/src/styles
   - Copy public assets and images
   - Update Tailwind configuration

**Checkpoint 1**: Deploy to Railway and verify basic setup works

### Phase 2: Component Migration (Checkpoint 2)
**Goal**: Migrate all components without routing

1. **Copy Component Structure**
   - Create components directory in app/
   - Port all components maintaining folder structure:
     - icons/, navigation/, daos/, trade/, learn/
   - Convert imports from Vite aliases to Next.js

2. **Port Utilities and Types**
   - Copy utils/, types/, hooks/, mutations/
   - Update import paths
   - Create constants file

3. **Set Up Providers**
   - Enhance existing providers.tsx with HelmetProvider equivalent
   - Ensure all contexts work properly

**Checkpoint 2**: Deploy and verify components render in existing pages

### Phase 3: Dynamic Routes (Checkpoint 3)
**Goal**: Implement dynamic routing with proper folder structure

1. **Create Dynamic Route Folders**
   ```
   app/
   ├── trade/
   │   └── [proposalId]/
   │       └── page.tsx
   ├── dao/
   │   └── [daoId]/
   │       └── page.tsx
   ```

2. **Port Route Components**
   - Migrate ProposalView to trade/[proposalId]/page.tsx
   - Migrate DaoView to dao/[daoId]/page.tsx
   - Update data fetching to use Next.js patterns

3. **Implement Root Layout**
   - Port navigation components to layout.tsx
   - Set up consistent layout structure

**Checkpoint 3**: Deploy and test dynamic routes work correctly

### Phase 4: Metadata & SEO (Checkpoint 4)
**Goal**: Implement server-side metadata generation

1. **Dynamic Metadata Generation**
   - Convert SEOMetadata component logic to generateMetadata functions
   - Implement in each page.tsx:
     ```typescript
     export async function generateMetadata({ params }) {
       // Fetch data and return metadata
     }
     ```

2. **Static Metadata**
   - Set up default metadata in root layout
   - Configure viewport, icons, theme color

3. **Structured Data**
   - Implement JSON-LD structured data
   - Add to appropriate pages

**Checkpoint 4**: Deploy and verify SEO metadata renders server-side

### Phase 5: Dynamic OG Image Generation (Checkpoint 5)
**Goal**: Implement server-side OG image generation

1. **Create API Routes for OG Images**
   ```
   app/
   ├── api/
   │   └── og/
   │       ├── dao/
   │       │   └── [id]/
   │       │       └── route.tsx
   │       └── proposal/
   │           └── [id]/
   │               └── route.tsx
   ```

2. **Implement OG Image Generation**
   - Use @vercel/og or similar for image generation
   - Fetch data from API
   - Generate images matching current design

3. **Update Metadata**
   - Point OG image URLs to new API routes
   - Test social media previews

**Checkpoint 5**: Deploy and verify OG images generate correctly

### Phase 6: Data Fetching Optimization (Checkpoint 6)
**Goal**: Optimize for performance and UX

1. **Server Components**
   - Convert data fetching to server components where possible
   - Implement proper loading states

2. **Parallel Data Loading**
   - Optimize data fetching with parallel requests
   - Implement proper error boundaries

3. **Client-Side Features**
   - Ensure wallet connection works
   - Maintain interactive features with 'use client'

**Checkpoint 6**: Deploy and test performance improvements

### Phase 7: Final Migration (Checkpoint 7)
**Goal**: Complete migration and cleanup

1. **Remove Vite Dependencies**
   - Remove vite, vite plugins
   - Remove react-router-dom
   - Clean up package.json

2. **Update Build Scripts**
   - Ensure Railway deployment scripts work
   - Update any CI/CD configurations

3. **Final Testing**
   - Test all routes and features
   - Verify SEO and OG images
   - Check performance metrics

**Checkpoint 7**: Final deployment to Railway

## Implementation Order

1. **Start Simple**: Begin with static pages (Learn, Create)
2. **Add Complexity**: Move to dynamic routes (DAO, Trade)
3. **Server Features**: Implement SSR benefits (metadata, OG)
4. **Optimize**: Fine-tune performance and UX

## Key Considerations

### Data Fetching Pattern
```typescript
// Server Component (default)
async function DaoPage({ params }: { params: { daoId: string } }) {
  const dao = await fetch(`${API_URL}/dao/${params.daoId}`).then(r => r.json());
  return <DaoView dao={dao} />;
}

// Client Component (for interactive parts)
'use client';
function TradingInterface({ proposal }) {
  // Interactive trading logic
}
```

### Metadata Pattern
```typescript
export async function generateMetadata({ params }): Promise<Metadata> {
  const data = await fetchData(params.id);
  return {
    title: data.title,
    openGraph: {
      images: [`/api/og/${type}/${params.id}`],
    },
  };
}
```

### Environment Variables
- Rename `VITE_` prefixed vars to `NEXT_PUBLIC_`
- Server-only vars don't need prefix

## Rollback Strategy
- Keep Vite frontend unchanged as backup
- Each checkpoint should be independently deployable
- Tag each successful deployment in git

## Success Criteria
- [ ] All routes working in Next.js
- [ ] Dynamic OG cards generating
- [ ] SEO improved with SSR
- [ ] Performance equal or better
- [ ] Railway deployments successful
- [ ] No functionality lost