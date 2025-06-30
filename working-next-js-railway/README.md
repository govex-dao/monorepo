# Govex - Next.js Application

This is the Next.js version of Govex, a futarchy platform on Sui.

## Tech Stack

- **Framework**: Next.js 15 (App Router)
- **UI**: Radix UI Themes + Tailwind CSS
- **Blockchain**: Sui (via @mysten/dapp-kit)
- **Data Fetching**: TanStack Query with SSR
- **Charts**: lightweight-charts, recharts
- **Deployment**: Railway

## Getting Started

### Prerequisites

- Node.js 18+ 
- pnpm (recommended) or npm

### Installation

```bash
pnpm install
```

### Development

```bash
pnpm dev
```

Open [http://localhost:3000](http://localhost:3000) to view the app.

### Build

```bash
pnpm build
```

### Production

```bash
pnpm start
```

## Environment Variables

Create a `.env.local` file with:

```env
NEXT_PUBLIC_API_URL=https://www.govex.ai/api
NEXT_PUBLIC_NETWORK=mainnet
NEXT_PUBLIC_APP_URL=https://govex.ai
```

## Project Structure

```
app/
├── components/      # Reusable UI components
├── routes/         # Page components
├── mutations/      # Sui blockchain mutations
├── hooks/          # Custom React hooks
├── utils/          # Utility functions
├── constants.ts    # App constants
├── (routes)/       # Next.js pages
└── api/            # API routes (OG image generation)
```

## Features

- Server-side rendering for better SEO and performance
- Dynamic OG image generation for social sharing
- Real-time trading interface with charts
- Futarchy DAO management
- Prediction market trading
- Wallet integration (Sui wallets)

## Migration Status

This app has been successfully migrated from Vite to Next.js 15. See CLAUDE.md for migration details.

## Deployment

The app is configured for deployment on Railway. Push to the main branch to trigger automatic deployment.

## License

See LICENSE file in the root of the monorepo.
EOF < /dev/null