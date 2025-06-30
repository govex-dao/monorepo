'use client';

import { lazy, Suspense } from 'react';

const MarketPriceChart = lazy(() => import('./MarketPriceChart'));

export default function MarketPriceChartWrapper(props: any) {
  return (
    <Suspense fallback={
      <div className="flex items-center justify-center h-[400px] bg-gray-800 rounded-lg">
        <div className="text-gray-400">Loading chart...</div>
      </div>
    }>
      <MarketPriceChart {...props} />
    </Suspense>
  );
}