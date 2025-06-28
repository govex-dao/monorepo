# Vite to Next.js Migration Plan for Dynamic OG Cards

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